package gvsub

// Правила подмены. Цепочки Z2K_GVSUB в nat и mangle создаёт и подвешивает
// первыми в PREROUTING init-скрипт z2k; служба только добавляет и снимает
// строки под каждую пару «плохой → сосед».
// 10.11.2026: служба также держит filter/Z2K_GVSUB_Q, чтобы браузер
// не ждал QUIC к подтверждённо плохому адресу без работающей подмены.
//
// Почему не один DNAT. z2k обрабатывает пакеты на выходе (mangle POSTROUTING),
// то есть уже после переадресации, и свои куски ClientHello шлёт на новый
// адрес. Ядро не узнаёт их как пакеты переадресованного соединения и не
// подменяет адрес отправителя: на стенде 09.11 они уходили наружу с адресом
// из локальной сети. Поэтому подменённые соединения обрабатываются раньше, в
// mangle PREROUTING, пока адрес ещё исходный: пакеты движка тогда идут на
// исходный адрес, совпадают с записью conntrack, и ядро само делает и DNAT, и
// SNAT. Метка 0x20000000 в connmark — штатное исключение z2k: на выходе такие
// соединения повторно не обрабатываются.

import (
	"fmt"
	"net/netip"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	Chain       = "Z2K_GVSUB"
	QUICChain   = "Z2K_GVSUB_Q"
	ExcludeMark = "0x20000000"
	EngineQueue = "200"
)

// Rules ставит и снимает правила одной пары и держит каркас.
type Rules interface {
	Add(bad, good netip.Addr) error
	Del(bad, good netip.Addr) error
	RejectQUIC(addr netip.Addr) error
	AllowQUIC(addr netip.Addr) error
	// 10.11.2026: Ensure держит цепочки первыми в PREROUTING/FORWARD, чтобы
	// ранние правила не обходили подмену и отказ QUIC; держит очередь DNS.
	// true — цепочки пересозданы пустыми, подмены и отказы надо вернуть.
	Ensure() (bool, error)
	// Teardown снимает каркас целиком.
	Teardown()
}

// IPTables — правила через iptables/ip6tables.
type IPTables struct {
	Queue string                                           // очередь ответов DNS
	NoV6  bool                                             // IPv6 выключен в z2k: ip6tables не трогаем
	Run   func(bin string, args ...string) error           // подменяется в тестах
	Out   func(bin string, args ...string) (string, error) // то же, с выводом
}

func runCmd(bin string, args ...string) error {
	out, err := exec.Command(bin, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", bin, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func outCmd(bin string, args ...string) (string, error) {
	out, err := exec.Command(bin, args...).Output()
	return string(out), err
}

func (r IPTables) run(bin string, args ...string) error {
	if r.Run != nil {
		return r.Run(bin, args...)
	}
	return runCmd(bin, args...)
}

func (r IPTables) out(bin string, args ...string) (string, error) {
	if r.Out != nil {
		return r.Out(bin, args...)
	}
	return outCmd(bin, args...)
}

func (r IPTables) bins() []string {
	if r.NoV6 {
		return []string{"iptables"}
	}
	return []string{"iptables", "ip6tables"}
}

// dnsRule — очередь ответов DNS роутера устройствам (те же аргументы, что в
// S99zapret2, z2k_gvsub_dns_rule).
// DNS wire suffix: c.youtube.com, including label lengths and root terminator.
const cacheDNSHex = "|016307796f757475626503636f6d00|"

func (r IPTables) dnsRule(cache bool) []string {
	q := r.Queue
	if q == "" {
		q = "210"
	}
	// ! -o lo: ответы на собственные запросы службы (имена машин кластера)
	// идут через lo и придерживаться не должны.
	match, value := "--string", "googlevideo"
	if cache {
		match, value = "--hex-string", cacheDNSHex
	}
	return []string{"!", "-o", "lo", "-p", "udp", "--sport", "53", "-m", "string", "--algo", "bm", match, value,
		"-j", "NFQUEUE", "--queue-num", q, "--queue-bypass"}
}

// 10.11.2026: REJECT нужен до остальных правил FORWARD, иначе ранний ACCEPT
// оставит браузер ждать QUIC к адресу, который не отвечает.
var chainHooks = [...]struct{ table, parent, chain string }{
	{"nat", "PREROUTING", Chain},
	{"mangle", "PREROUTING", Chain},
	{"filter", "FORWARD", QUICChain},
}

// Ensure — см. интерфейс. Хук NDM (000-zapret2.sh) переставляет правила z2k,
// только если пропали правила очереди в mangle; когда Keenetic перестраивает
// одну таблицу nat, наша цепочка там исчезала навсегда (ночь на 10.11.2026:
// служба до утра не могла поставить ни одной подмены). Поэтому каркас служба
// держит сама.
func (r IPTables) Ensure() (bool, error) {
	recreated := false
	var firstErr error
	for _, bin := range r.bins() {
		for _, h := range chainHooks {
			t, parent, chain := h.table, h.parent, h.chain
			if r.run(bin, "-w", "-t", t, "-N", chain) == nil {
				recreated = true // цепочки не было — она пустая
			}
			s, err := r.out(bin, "-w", "-t", t, "-S", parent)
			if err != nil {
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			lines := strings.Split(strings.TrimSpace(s), "\n")
			if len(lines) > 1 && strings.TrimSpace(lines[1]) == "-A "+parent+" -j "+chain {
				continue
			}
			for i := 0; i < 8 && r.run(bin, "-w", "-t", t, "-D", parent, "-j", chain) == nil; i++ {
			}
			if err := r.run(bin, "-w", "-t", t, "-I", parent, "1", "-j", chain); err != nil && firstErr == nil {
				firstErr = err
			}
		}
		for _, cache := range []bool{false, true} {
			check := append([]string{"-w", "-t", "mangle", "-C", "OUTPUT"}, r.dnsRule(cache)...)
			if r.run(bin, check...) != nil {
				ins := append([]string{"-w", "-t", "mangle", "-I", "OUTPUT", "1"}, r.dnsRule(cache)...)
				if err := r.run(bin, ins...); err != nil && firstErr == nil {
					firstErr = err
				}
			}
		}
	}
	return recreated, firstErr
}

// Teardown — каркас целиком: очередь DNS, крючки и цепочки.
func (r IPTables) Teardown() {
	for _, bin := range r.bins() {
		for _, cache := range []bool{false, true} {
			del := append([]string{"-w", "-t", "mangle", "-D", "OUTPUT"}, r.dnsRule(cache)...)
			for i := 0; i < 8 && r.run(bin, del...) == nil; i++ {
			}
		}
		for _, h := range chainHooks {
			t, parent, chain := h.table, h.parent, h.chain
			for i := 0; i < 8 && r.run(bin, "-w", "-t", t, "-D", parent, "-j", chain) == nil; i++ {
			}
			_ = r.run(bin, "-w", "-t", t, "-F", chain)
			_ = r.run(bin, "-w", "-t", t, "-X", chain)
		}
	}
}

// ruleSet — строки одной пары: таблица и аргументы после имени цепочки.
// Порядок: сначала mangle, потом DNAT. Строки ставятся отдельными командами,
// и новое соединение между ними получило бы DNAT без обработки z2k до
// переадресации — а это ломает соединение (стенд 09.11). Наоборот (метка без
// DNAT) соединение просто идёт на плохой адрес, как без подмены.
func ruleSet(bad, good netip.Addr) [][]string {
	b, g := bad.String(), good.String()
	var mangle, nat [][]string
	for _, proto := range []string{"tcp", "udp"} {
		pkts := "0:20"
		if proto == "udp" {
			pkts = "0:8"
		}
		mangle = append(mangle,
			// Метка — только первому пакету соединения, тому, что видит и nat:
			// NEW без CONFIRMED. Ответ DNS не придерживается, подмена встаёт,
			// когда первое соединение к плохому адресу уже идёт через пробу z2k
			// на выходе, и метка увела бы его мимо пробы посреди обмена. Просто
			// NEW мало: повтор SYN и UDP без ответа тоже NEW (ревью 10.11).
			[]string{"mangle", "-d", b, "-p", proto, "--dport", "443",
				"-m", "conntrack", "--ctstate", "NEW", "!", "--ctstatus", "CONFIRMED",
				"-j", "CONNMARK", "--or-mark", ExcludeMark},
			[]string{"mangle", "-d", b, "-p", proto, "--dport", "443",
				"-m", "connmark", "--mark", ExcludeMark + "/" + ExcludeMark,
				"-m", "connbytes", "--connbytes", pkts, "--connbytes-mode", "packets", "--connbytes-dir", "original",
				"-j", "NFQUEUE", "--queue-num", EngineQueue, "--queue-bypass"},
		)
		nat = append(nat, []string{"nat", "-d", b, "-p", proto, "--dport", "443", "-j", "DNAT", "--to-destination", g})
	}
	return append(mangle, nat...)
}

func (r IPTables) apply(op string, bad, good netip.Addr) error {
	run := r.run
	bin := "iptables"
	if bad.Is6() {
		bin = "ip6tables"
	}
	var firstErr error
	set := ruleSet(bad, good)
	if op == "-D" {
		// Снимать в обратном порядке: сначала DNAT.
		for i, j := 0, len(set)-1; i < j; i, j = i+1, j-1 {
			set[i], set[j] = set[j], set[i]
		}
	}
	for _, rs := range set {
		if op == "-A" {
			// Повторная установка (SIGHUP после перестройки таблиц) не должна
			// дублировать строки: есть — пропускаем.
			check := append([]string{"-w", "-t", rs[0], "-C", Chain}, rs[1:]...)
			if run(bin, check...) == nil {
				continue
			}
		}
		args := append([]string{"-w", "-t", rs[0], op, Chain}, rs[1:]...)
		if err := run(bin, args...); err != nil && firstErr == nil {
			firstErr = err
			if op == "-A" {
				// Половина пары хуже, чем ничего: DNAT без обработки до
				// переадресации ломает соединение. Откатываем.
				_ = r.apply("-D", bad, good)
				return firstErr
			}
		}
	}
	return firstErr
}

func (r IPTables) Add(bad, good netip.Addr) error { return r.apply("-A", bad, good) }
func (r IPTables) Del(bad, good netip.Addr) error { return r.apply("-D", bad, good) }

// 10.11.2026: DNAT меняет адрес до FORWARD, поэтому сосед продолжает получать
// QUIC, а неподменённый Bad сразу получает отказ и браузер переходит на TCP.
func (r IPTables) quic(op string, addr netip.Addr) error {
	bin, reject := "iptables", "icmp-port-unreachable"
	if addr.Is6() {
		bin, reject = "ip6tables", "icmp6-port-unreachable"
	}
	rule := []string{"-d", addr.String(), "-p", "udp", "--dport", "443", "-j", "REJECT", "--reject-with", reject}
	check := append([]string{"-w", "-t", "filter", "-C", QUICChain}, rule...)
	exists := r.run(bin, check...) == nil
	if op == "-A" && exists || op == "-D" && !exists {
		return nil
	}
	return r.run(bin, append([]string{"-w", "-t", "filter", op, QUICChain}, rule...)...)
}

func (r IPTables) RejectQUIC(addr netip.Addr) error { return r.quic("-A", addr) }
func (r IPTables) AllowQUIC(addr netip.Addr) error  { return r.quic("-D", addr) }

// ResetHold — сколько держится правило сброса одного соединения: клиент
// повторяет неподтверждённые данные через 1, 2, 4 с, и повтор должен попасть
// под правило.
const ResetHold = 15 * time.Second

// Reset обрывает соединение клиента сбросом TCP: ближайший его повтор
// получает RST от имени сервера, браузер сразу открывает новое соединение, и
// оно уходит на соседа. Одно удаление записи conntrack клиента не будит:
// повтор пересоздаёт запись мимо nat, и соединение висит дальше (10.11.2026:
// одно и то же соединение «сброшено» трижды за 8 с).
func (r IPTables) Reset(f Flow) error {
	if f.Proto != "tcp" {
		return nil
	}
	bin := "iptables"
	if f.Dst.Is6() {
		bin = "ip6tables"
	}
	rule := []string{"-s", f.Src.String(), "-d", f.Dst.String(), "-p", "tcp",
		"--sport", strconv.Itoa(int(f.Sport)), "--dport", strconv.Itoa(int(f.Dport)),
		"-j", "REJECT", "--reject-with", "tcp-reset"}
	if err := r.run(bin, append([]string{"-w", "-I", "FORWARD", "1"}, rule...)...); err != nil {
		return err
	}
	time.AfterFunc(ResetHold, func() {
		_ = r.run(bin, append([]string{"-w", "-D", "FORWARD"}, rule...)...)
	})
	return nil
}
