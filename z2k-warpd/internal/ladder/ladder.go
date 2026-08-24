// Package ladder — порядок, в котором движок пробует транспорты.
//
// WG :2408 → WG по каждому запасному порту из регистрации → MASQUE-h2 :443.
// Чистый автомат без горутин и часов: время приходит аргументом, поэтому
// тесты детерминированы. Запасные порты — от Cloudflare (их ~50), не хардкод:
// это встроенный обход 5-tuple-блоков.
package ladder

import (
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

// New строит лестницу: первичный WG-хост по всем портам, затем запасные
// хосты по своим портам, затем h2. start — last_good; если его нет в
// лестнице (эндпоинты обновились), начинаем с вершины.
func New(ep account.Endpoint, start *account.Step) *Ladder {
	var steps []account.Step
	addHost := func(host string, ports []int) {
		if host == "" {
			return
		}
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
