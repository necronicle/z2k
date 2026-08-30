// Package sniwl подбирает имя из белого списка провайдерской коробки DPI —
// то, которое подставляется в ФЕЙКОВЫЙ ClientHello профиля nfqws2.
//
// # Что за класс блокировки
//
// Есть класс, который наши детекторы не видят и никогда не увидят: рукопожатие
// проходит, первые килобайты идут, поток встаёт на 16–20 КБ и висит до
// таймаута. Замер на линии владельца 2026-08-29 (hetzner.com, AS24940): 200 OK
// и ровно 15994 байта, дальше тишина. Тот же адрес с фейковым ClientHello,
// несущим sni=disk.rzd.ru, — 163654 байта за 0.64 с, полная страница.
// Несущая часть здесь ИМЯ, а не разрез: работает и с hostfakesplit, и с
// multisplit:seqovl=1.
//
// Ротация страт на этом классе бессильна по построению: 400 обращений
// детекторов за три зависших захода дали ноль событий. Ловить обрыв нечем —
// prober.probeHTTPStaged честно переводит read-timeout в «неубедительно»
// (markHTTPInconclusive), и для СВОЕЙ задачи это верно: медленный аплинк не
// блокировка. Поэтому здесь отдельная проба с ПРОТИВОПОЛОЖНОЙ политикой:
// стойка после накопленных ≥12 КБ АПЛИНКА — положительный сигнал.
//
// # Почему аплинк, а не даунлинк
//
// Триггер у коробки — объём, который мы отправили, а не который скачали.
// Поэтому проба гонит мусор НАРУЖУ: десять HEAD-запросов по одному keep-alive
// соединению, начиная со второго — с заголовком X-Pad на 4000 байт. Тело
// ответа не читается вообще, код ответа не важен (400/405 на HEAD — успех:
// важен сам факт полного ответа). Метод взят из dpi-detector
// (github.com/runnin4ik/dpi-detector, MIT, (c) 2026 Runnin4ik) и портирован
// с поправками на слабый роутер — см. Config.
//
// # Единица учёта — СЕТЬ, а не домен
//
// Кампания 507 замеров по 412 сетям /16: коробка привязана к СЕТИ назначения,
// согласие вердиктов внутри /16 — 81.3%. Поэтому ключ здесь — a.b.0.0/16, и
// характеризация живёт СБОКУ от decision.Classify: её контракт Hot/Watch/
// Ignore прибит тестами и говорит про домен, а не про сеть.
package sniwl

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strings"
)

// Status — исход одной пробы одного имени.
//
// Разделение StatusBreak и StatusDetected делает НОМЕР КУСКА, на котором
// оборвалось, а не тип ошибки: до детект-окна обрыв — это шум линии, после —
// работа коробки. Ошибка на самом первом (беспэдовом) запросе — вообще не
// вердикт о блокировке, а провал пробы, и его нельзя путать с двумя первыми,
// иначе перебор сорока имён пойдёт по мёртвому адресу.
type Status string

const (
	// StatusOK — все куски прошли. Имя пробивает коробку.
	StatusOK Status = "OK"
	// StatusDetected — оборвалось на куске >= MinDetectChunk. Коробка сработала.
	StatusDetected Status = "DETECTED"
	// StatusBreak — оборвалось раньше детект-окна. Не блокировка, шум.
	StatusBreak Status = "BREAK"
	// StatusFail — проба не состоялась (не дозвонились, рукопожатие,
	// обрыв на нулевом куске, сервер не держит keep-alive). Про коробку
	// не говорит НИЧЕГО и служит детектором бана/рейт-лимита.
	StatusFail Status = "FAIL"
)

// Valid reports whether the status is a measurement of the box at all.
// Только OK и DETECTED — измерения; остальное про линию и про сервер.
func (s Status) Valid() bool { return s == StatusOK || s == StatusDetected }

// Candidate — одно имя из файла кандидатов вместе с номером строки.
// Номер печатается в отчётах и в провенансе, чтобы человек мог открыть файл
// и увидеть ровно ту строку, а не искать имя глазами.
type Candidate struct {
	Name string
	Line int
}

// ParseCandidates разбирает файл кандидатов.
//
// ПОРЯДОК ФАЙЛА = ПРИОРИТЕТ и НЕ пересортировывается: победителем считается
// первое прошедшее имя. Сортировка «под нашу единственную проверенную линию»
// была бы подгонкой под один замер, поэтому её здесь нет.
//
// Формат: одно имя в строке, пустые строки и строки на '#' игнорируются,
// хвостовой комментарий после '#' отрезается. Дубли схлопываются по первому
// вхождению — иначе одно и то же имя съело бы два слота из лимита прогона.
func ParseCandidates(r io.Reader) []Candidate {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	var out []Candidate
	seen := make(map[string]struct{})
	for n := 1; sc.Scan(); n++ {
		line := sc.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		name := strings.ToLower(strings.TrimSpace(line))
		if name == "" || !validHostname(name) {
			continue
		}
		if _, dup := seen[name]; dup {
			continue
		}
		seen[name] = struct{}{}
		out = append(out, Candidate{Name: name, Line: n})
	}
	return out
}

// LoadCandidates читает файл кандидатов с диска.
func LoadCandidates(path string) ([]Candidate, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	c := ParseCandidates(f)
	if len(c) == 0 {
		return nil, fmt.Errorf("sniwl: %s: ни одного кандидата", path)
	}
	return c, nil
}

// OrderWithIncumbent ставит действующее имя первым.
//
// Имя в файле имени уже проверено на другой сети этого же провайдера, и
// коробка у него одна. Проверить его первым — это одна проба вместо сорока в
// типичном случае, и это единственная причина, по которой перебор вообще
// можно позволить себе на домашней линии повторно.
func OrderWithIncumbent(cands []Candidate, incumbent string) []Candidate {
	incumbent = strings.ToLower(strings.TrimSpace(incumbent))
	if incumbent == "" {
		return cands
	}
	out := make([]Candidate, 0, len(cands)+1)
	rest := make([]Candidate, 0, len(cands))
	found := false
	for _, c := range cands {
		if c.Name == incumbent {
			out = append(out, c)
			found = true
			continue
		}
		rest = append(rest, c)
	}
	if !found {
		// Имя пришло не из файла (оператор вписал руками) — всё равно
		// пробуем его первым, номер строки неизвестен.
		out = append(out, Candidate{Name: incumbent, Line: 0})
	}
	return append(out, rest...)
}

// validHostname — проверка имени, ДОСЛОВНО совпадающая с той, что делает
// генератор конфига над файлом имени (lib/config_official.sh, профиль sni_wl):
// `*[!A-Za-z0-9.-]*|.*|-*|*.|*-|*..*` плюс предел 253.
//
// Совпадение обязательное, а не косметическое. Имя уезжает в командную строку
// nfqws2, где разделители ':' и ',': пропущенный сюда посторонний символ — это
// не «фейк без имени», это не стартовавший демон, то есть обход, лежащий
// целиком. Поэтому подчёркивание здесь ЗАПРЕЩЕНО, хотя в DNS оно встречается:
// его не пропустит генератор, и записать такое имя значило бы своими руками
// сделать файл, от которого профиль молча не соберётся.
func validHostname(d string) bool {
	if len(d) == 0 || len(d) > 253 {
		return false
	}
	if !strings.Contains(d, ".") {
		return false
	}
	if strings.HasPrefix(d, ".") || strings.HasPrefix(d, "-") ||
		strings.HasSuffix(d, ".") || strings.HasSuffix(d, "-") ||
		strings.Contains(d, "..") {
		return false
	}
	for i := 0; i < len(d); i++ {
		c := d[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '.', c == '-':
		default:
			return false
		}
	}
	return true
}

// NetMask16 — маска ключа сети. /16 выбран не на глаз: согласие вердиктов
// внутри /16 замерено и равно 81.3% на 412 сетях.
const NetMask16 uint32 = 0xFFFF0000

// NetKey возвращает ключ /16 для IPv4-адреса.
//
// Второе значение false означает «этот адрес характеризовать нельзя»: не IPv4,
// приватный, loopback, link-local, multicast, CGNAT или зарезервированный.
// Публиковать такую сеть в ipset профиля — значит натравить фейковый
// ClientHello на локальную сеть пользователя.
func NetKey(ip net.IP) (uint32, bool) {
	v4 := ip.To4()
	if v4 == nil {
		return 0, false
	}
	if !routable4(v4) {
		return 0, false
	}
	u := uint32(v4[0])<<24 | uint32(v4[1])<<16 | uint32(v4[2])<<8 | uint32(v4[3])
	return u & NetMask16, true
}

// NetKeyString — то же по строковому адресу.
func NetKeyString(s string) (uint32, bool) {
	ip := net.ParseIP(strings.TrimSpace(s))
	if ip == nil {
		return 0, false
	}
	return NetKey(ip)
}

// CIDR печатает ключ сети в форме a.b.0.0/16.
func CIDR(key uint32) string {
	return fmt.Sprintf("%d.%d.0.0/16", byte(key>>24), byte(key>>16))
}

// ParseCIDR16 разбирает строку файла сетей обратно в ключ. Принимает и голый
// адрес: оператор мог вписать 1.2.3.4 руками, и это тоже про сеть 1.2.0.0/16.
func ParseCIDR16(s string) (uint32, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	if strings.Contains(s, "/") {
		ip, _, err := net.ParseCIDR(s)
		if err != nil {
			return 0, false
		}
		return NetKey(ip)
	}
	return NetKeyString(s)
}

func routable4(v4 net.IP) bool {
	switch {
	case v4.IsLoopback(), v4.IsPrivate(), v4.IsLinkLocalUnicast(),
		v4.IsLinkLocalMulticast(), v4.IsMulticast(), v4.IsUnspecified():
		return false
	}
	switch {
	case v4[0] == 0: // 0.0.0.0/8
		return false
	case v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127: // CGNAT 100.64/10
		return false
	case v4[0] == 127: // на всякий, если IsLoopback не сработал
		return false
	case v4[0] >= 224: // multicast + 240/4 reserved + broadcast
		return false
	}
	return true
}

// FirstRoutable выбирает первый адрес, по которому есть смысл мерить сеть.
func FirstRoutable(ips []string) (string, uint32, bool) {
	for _, s := range ips {
		if key, ok := NetKeyString(s); ok {
			return strings.TrimSpace(s), key, true
		}
	}
	return "", 0, false
}

// sortedKeys — детерминированный порядок записи файла сетей.
func sortedKeys(m map[uint32]string) []uint32 {
	out := make([]uint32, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
