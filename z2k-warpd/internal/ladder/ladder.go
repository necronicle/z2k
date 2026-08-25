// Package ladder — порядок, в котором движок пробует транспорты.
//
// WG :2408 → WG по каждому запасному порту из регистрации → MASQUE-h2 :443.
// Чистый автомат без горутин и часов: время приходит аргументом, поэтому
// тесты детерминированы. Запасные порты — от Cloudflare (их ~50), не хардкод:
// это встроенный обход 5-tuple-блоков.
package ladder

import (
	"net"
	"fmt"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

const (
	// Cooldown — пауза между полными проходами лестницы: на провайдере с
	// полным блоком не молотить.
	Cooldown = 5 * time.Minute
	// ProbeUpEvery — как часто, сидя на h2, пробовать вернуться на WG.
	ProbeUpEvery = 10 * time.Minute

	defaultWGPort = 2408
	h2Port        = 443
	// earlyWG — сколько WG-шагов пробовать до h2. Портов у регистрации ~50,
	// по 5 с на каждый — h2 наступал бы через четыре минуты, а enable ждёт
	// две. h2 встаёт после первых шагов, остальные WG-порты — после него.
	earlyWG = 5
)

// Ladder — текущая позиция и память о проходах.
type Ladder struct {
	steps     []account.Step
	idx       int
	tried     int       // ступеней опробовано с последнего успеха/кулдауна
	passStart time.Time // начало текущего круга; zero = ещё не начинался
}

// fallbackHosts — известные адреса WARP-эндпоинтов из ДРУГИХ диапазонов.
//
// Нужны ровно для случая, когда весь выданный диапазон режут: адреса
// взаимозаменяемы, любой узел принимает ту же регистрацию. Список короткий и
// из разных сетей нарочно — смысл не в переборе, а в том, чтобы не зависеть от
// одного блока. Проверены с роутера владельца 2026-08-25; 162.159.193.x и
// 162.159.195.x в список НЕ входят: там рукопожатия нет (первый, по сообщениям,
// перестал работать ещё в конце 2024).
var builtinFallbackHosts = []string{
	"8.6.112.1",
	"8.47.69.1",
	"188.114.96.1",
	"188.114.97.1",
}

// fallbackHosts — действующий список. Совпадает со встроенным, пока никто не
// задал свой.
var fallbackHosts = builtinFallbackHosts

// hostsPerNet — сколько адресов брать из сети.
//
// ОДНОЙ ПРОБЫ МАЛО: она не отличает мёртвую СЕТЬ от мёртвого адреса, а нам
// важно первое — блокируют сетями. Двух хватает, чтобы не путать одно с другим,
// и лестница не разрастается: каждая лишняя ступень стоит пять секунд ожидания.
const hostsPerNet = 2

// expandFallback — превращает список в адреса. Строка вида «1.2.3.0/24»
// раскрывается в несколько адресов внутри сети, обычный адрес берётся как есть.
//
// СЕТИ, А НЕ АДРЕСА, и это ответ на возражение из поля: четыре адреса,
// измеренные на одной линии, — догадка. У другого провайдера их может резать, и
// человек вернётся с той же жалобой. Блокируют сетями, поэтому хранить надо
// сети, а адреса из них роутер подбирает сам — тем же перебором, которым он и
// так проверяет каждую ступень.
//
// Адреса берём с шагом, а не подряд: соседние часто уходят на один и тот же
// узел, и две пробы рядом отвечают на один вопрос дважды.
func expandFallback(list []string) []string {
	var out []string
	for _, item := range list {
		_, nw, err := net.ParseCIDR(item)
		if err != nil {
			out = append(out, item)
			continue
		}
		ones, bits := nw.Mask.Size()
		size := 1 << uint(bits-ones)
		if size <= 2 {
			continue
		}
		step := size / (hostsPerNet + 1)
		if step < 1 {
			step = 1
		}
		base := nw.IP.To4()
		if base == nil {
			continue
		}
		for i := 1; i <= hostsPerNet; i++ {
			off := step * i
			if off >= size {
				break
			}
			ip := make(net.IP, 4)
			copy(ip, base)
			v := uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
			v += uint32(off)
			ip[0], ip[1], ip[2], ip[3] = byte(v>>24), byte(v>>16), byte(v>>8), byte(v)
			out = append(out, ip.String())
		}
	}
	return out
}

// SetFallbackHosts заменяет список запасных адресов.
//
// СПИСОК — ДАННЫЕ, А НЕ КОД, и это не вкусовщина. Зашитый в бинарник он
// стареет: 162.159.193.x работал, а к концу 2024 перестал — и остался бы
// навсегда, пока кто-нибудь не выпустит релиз с пересборкой под пять арок.
// Адреса обязаны обновляться как список.
//
// Пустой список возвращает встроенный: свежая установка, где файла ещё нет, не
// должна остаться вообще без запасных адресов.
func SetFallbackHosts(hosts []string) {
	if len(hosts) == 0 {
		fallbackHosts = builtinFallbackHosts
		return
	}
	fallbackHosts = hosts
}

// New строит лестницу: первичный WG-хост по всем портам, затем запасные
// хосты по своим портам, затем h2. start — last_good; если его нет в
// лестнице (эндпоинты обновились), начинаем с вершины.
func New(ep account.Endpoint, start *account.Step) *Ladder {
	var steps []account.Step
	// Хост, уже попавший в лестницу, второй раз не добавляем: иначе запасной
	// адрес, который Cloudflare и так выдал этому устройству, пробовался бы
	// дважды подряд.
	haveHost := map[string]bool{}
	addHost := func(host string, ports []int) {
		if host == "" || haveHost[host] {
			return
		}
		haveHost[host] = true
		seen := map[int]bool{}
		for _, p := range append([]int{defaultWGPort}, ports...) {
			if p <= 0 || p > 65535 || seen[p] {
				continue
			}
			seen[p] = true
			steps = append(steps, account.Step{Transport: "wg", Host: host, Port: p})
		}
	}
	addHost(ep.V4, ep.Ports)
	for _, a := range ep.Alt {
		if a.Host != ep.V4 {
			addHost(a.Host, a.Ports)
		}
	}
	// ЗАПАСНЫЕ ЭНДПОИНТЫ — ПОСЛЕ ВЫДАННЫХ, НО ДО ТОГО, КАК СДАТЬСЯ.
	//
	// Поле 2026-08-25: Cloudflare выдал устройству ТОЛЬКО 162.159.192.4 —
	// диапазон, который режут целиком, — и WARP не поднимался вовсе.
	// Перерегистрация не спасла: со второй попытки пришёл другой адрес из того
	// же блока. Допущение «новая регистрация плохого диапазона не содержит»
	// оказалось неверным.
	//
	// Ключ к выданному адресу НЕ привязан — замер на роутере владельца с его
	// регистрацией (выдан 8.6.112.0, запасной 162.159.192.10):
	//
	//	8.6.112.1      handshake ok   (устройству не выдавался)
	//	8.47.69.1      handshake ok   (другой диапазон)
	//	188.114.96.1   handshake ok
	//	188.114.97.1   handshake ok
	//	162.159.195.1  no handshake
	//	162.159.192.10 no handshake   (СВОЙ запасной — диапазон режут)
	//
	// Порядок важен: сперва то, что выдали нам (там ближайший узел и меньше
	// задержка), и только потом общие адреса.
	for _, h := range expandFallback(fallbackHosts) {
		addHost(h, ep.Ports)
	}
	// MASQUE-h2 — ПОСЛЕДНЯЯ СТУПЕНЬ, И ЕЁ ОТСЮДА УБИРАТЬ НЕЛЬЗЯ.
	//
	// 2026-08-24 она была снята: на роутере владельца h2 поднимается,
	// рапортует готовность и не возит ничего (ICMP 100% потерь, TCP 000,
	// rx=895 при tx=2617; тот же бинарник с VPS возит всё — глушит сеть, а не
	// реализация). Снятие обосновывалось тем, что шаг работает ловушкой:
	// движок падает на него, объявляет готовность, а человек остаётся без
	// интернета на всём, что завёрнуто в WARP.
	//
	// ОБОСНОВАНИЕ БЫЛО НЕГОДНЫМ, и это стоило поля. Ловушка закрыта монитором
	// живости ЗАДОЛГО до этого: health.TraceProbe гонит пробу в интерфейс через
	// SO_BINDTODEVICE (не просто адресом источника) и требует в ответе warp=on,
	// а два провала подряд означают Dead — см. TestTwoProbeFailuresAreDead.
	// Чёрная дыра живёт до полуминуты, потом лестница идёт дальше и срабатывает
	// fail-open.
	//
	// Ценой снятия стали те, у кого WG не работает В ПРИНЦИПЕ: Cloudflare
	// выдал первичный эндпоинт из блокируемого целиком диапазона, запасных
	// хостов нет, и вся лестница мертва от рождения. Для них h2 — единственный
	// транспорт, и p-79.13 отключил им WARP целиком. Замер на ОДНОЙ линии был
	// перенесён на весь флот: на линии владельца h2 глушат, у других нет.
	h2 := account.Step{Transport: "h2", Port: h2Port}
	if len(steps) > earlyWG {
		rest := append([]account.Step{}, steps[earlyWG:]...)
		steps = append(append(steps[:earlyWG], h2), rest...)
	} else {
		steps = append(steps, h2)
	}
	l := &Ladder{steps: steps}
	if start != nil {
		for i, s := range steps {
			if s == *start {
				l.idx = i
				break
			}
		}
	}
	return l
}

// Current — шаг, который движок должен пробовать сейчас.
func (l *Ladder) Current() account.Step { return l.steps[l.idx] }

// Len — сколько ступеней в лестнице.
func (l *Ladder) Len() int { return len(l.steps) }

// Index — номер шага (для статуса).
func (l *Ladder) Index() int { return l.idx }

// OnH2 — стоим ли на h2.
func (l *Ladder) OnH2() bool { return l.steps[l.idx].Transport == "h2" }

// Next переходит к следующему шагу. После h2 — обратно на вершину, и тогда
// wait говорит, сколько ещё ждать до начала нового прохода.
func (l *Ladder) Next(now time.Time) (account.Step, time.Duration) {
	if l.passStart.IsZero() {
		l.passStart = now
	}
	// Считаем ОПРОБОВАННЫЕ ступени, а не позицию в списке. Старт с last_good
	// (память об удачном транспорте) может прийтись на последнюю ступень —
	// и тогда позиционная проверка объявляла «полный проход провален» после
	// одной-единственной попытки, уходя на пятиминутный кулдаун и не пробуя
	// остальные ступени НИ РАЗУ (поле r-79.4).
	l.tried++
	l.idx = (l.idx + 1) % len(l.steps)
	if l.tried < len(l.steps) {
		return l.steps[l.idx], 0
	}
	// Круг пройден целиком и безрезультатно. Следующий — не раньше Cooldown
	// от начала этого: быстрый провал всей лестницы ждёт, медленный — нет.
	l.tried = 0
	var wait time.Duration
	if elapsed := now.Sub(l.passStart); elapsed < Cooldown {
		wait = Cooldown - elapsed
	}
	l.passStart = now.Add(wait)
	return l.steps[l.idx], wait
}

// Good фиксирует текущий шаг как рабочий и возвращает его для last_good.
func (l *Ladder) Good() account.Step {
	l.passStart = time.Time{}
	l.tried = 0
	return l.steps[l.idx]
}

// Top возвращает лестницу на вершину (после успешного возврата на WG).
func (l *Ladder) Top() { l.idx = 0 }

// Label — "wg:8.6.112.0:2408" / "h2:443" для логов и статуса.
func Label(s account.Step) string {
	if s.Host != "" {
		return fmt.Sprintf("%s:%s:%d", s.Transport, s.Host, s.Port)
	}
	return fmt.Sprintf("%s:%d", s.Transport, s.Port)
}

// NewFixed — лестница из одного шага (--force-transport): Next всегда
// возвращает тот же шаг с кулдауном.
func NewFixed(s account.Step) *Ladder { return &Ladder{steps: []account.Step{s}} }
