package domainroute

import (
	"errors"
	"fmt"
	"net/netip"
	"os/exec"
	"strings"
	"time"
)

// Наборы адресов доменов на устройство: IPv4 — z2kd_<IPv4 устройства>, IPv6 —
// z2kd6_<IPv4 устройства>. Устройство в обоих случаях названо своим IPv4: по
// нему спрашивающий сопоставляется и для ответов по IPv6 (таблица соседей).
const (
	clientSetPrefix  = "z2kd_"
	clientSet6Prefix = "z2kd6_"
)

// PairSet uses one supported hash:ip set per LAN client and address family.
// Keenetic's userspace advertises hash:net,net, but its 4.9 kernel lacks that
// set type.
type PairSet struct {
	Binary, IPTablesBinary, IP6TablesBinary string
	// MACOf — MAC устройства по его IPv4. IPv6-трафик устройства метится по
	// MAC: временные IPv6-адреса меняются, MAC — нет. Нет MAC — правило IPv6
	// не ставится до следующего прохода таймера.
	MACOf func(client netip.Addr) (string, bool)
}

// markKey — правило метки устройства в одном семействе.
type markKey struct {
	client netip.Addr
	v6     bool
}

// marks — правила, уже проверенные в этой жизни наблюдателя (см. apply).
type marks map[markKey]bool

// errMarkLater — правило IPv6 пока не поставить: MAC устройства неизвестен
// или цепочки Z2K_WARP в ip6tables ещё нет (скрипт заводит её, когда
// включает IPv6). Не ошибка: следующий проход таймера попробует снова.
var errMarkLater = errors.New("IPv6 mark deferred")

func (s PairSet) ipset(args ...string) ([]byte, error) {
	bin := s.Binary
	if bin == "" {
		bin = "ipset"
	}
	return exec.Command(bin, args...).CombinedOutput()
}

// restore пишет строки одним запуском ipset: запуск на роутере ~10 мс, и
// ответ DNS ждёт записи, а таймер переписывает все адреса раз в 5 с.
func (s PairSet) restore(lines []string) ([]byte, error) {
	bin := s.Binary
	if bin == "" {
		bin = "ipset"
	}
	cmd := exec.Command(bin, "restore", "-exist")
	cmd.Stdin = strings.NewReader(strings.Join(lines, "\n") + "\n")
	return cmd.CombinedOutput()
}
func (s PairSet) iptables(args ...string) ([]byte, error) {
	bin := s.IPTablesBinary
	if bin == "" {
		bin = "iptables"
	}
	return exec.Command(bin, args...).CombinedOutput()
}
func (s PairSet) ip6tables(args ...string) ([]byte, error) {
	bin := s.IP6TablesBinary
	if bin == "" {
		bin = "ip6tables"
	}
	return exec.Command(bin, args...).CombinedOutput()
}
func clientSet(client netip.Addr) (string, error) {
	if !client.Is4() || !(client.IsPrivate() || carrierNAT.Contains(client)) {
		return "", errors.New("not a LAN client")
	}
	return clientSetPrefix + client.String(), nil
}

// pairSetName — набор пары по семейству адреса назначения.
func pairSetName(client netip.Addr, v6 bool) string {
	if v6 {
		return clientSet6Prefix + client.String()
	}
	return clientSetPrefix + client.String()
}

// setClient — устройство и семейство по имени набора; только канонические
// имена: чужие наборы с похожим префиксом не трогаем.
func setClient(name string) (netip.Addr, bool, bool) {
	prefix, v6 := clientSetPrefix, false
	if strings.HasPrefix(name, clientSet6Prefix) {
		prefix, v6 = clientSet6Prefix, true
	} else if !strings.HasPrefix(name, clientSetPrefix) {
		return netip.Addr{}, false, false
	}
	ip, err := netip.ParseAddr(strings.TrimPrefix(name, prefix))
	if err != nil {
		return netip.Addr{}, false, false
	}
	if _, ce := clientSet(ip); ce != nil || pairSetName(ip, v6) != name {
		return netip.Addr{}, false, false
	}
	return ip, v6, true
}
func markArgs(action string, client netip.Addr, name string) []string {
	return []string{"-w", "-t", "mangle", action, "PREROUTING", "-s", client.String() + "/32", "-m", "set", "--match-set", name, "dst", "-j", "Z2K_WARP"}
}
func mark6Args(action, mac, name string) []string {
	return []string{"-w", "-t", "mangle", action, "PREROUTING", "-m", "mac", "--mac-source", mac, "-m", "set", "--match-set", name, "dst", "-j", "Z2K_WARP"}
}
func (s PairSet) ensureMark(client netip.Addr, name string) error {
	if _, err := s.iptables(markArgs("-C", client, name)...); err == nil {
		return nil
	}
	if out, err := s.iptables(markArgs("-A", client, name)...); err != nil {
		return fmt.Errorf("add WARP DNS mark: %w: %s", err, out)
	}
	return nil
}

// ensureMark6 — правило IPv6 устройства по его текущему MAC. Правило со
// старым MAC (адрес перешёл к другому устройству) снимается.
func (s PairSet) ensureMark6(client netip.Addr) error {
	if s.MACOf == nil {
		return errMarkLater
	}
	mac, ok := s.MACOf(client)
	if !ok {
		return errMarkLater
	}
	name := pairSetName(client, true)
	if _, err := s.ip6tables(mark6Args("-C", mac, name)...); err == nil {
		return nil
	}
	s.removeMark6(name)
	if out, err := s.ip6tables(mark6Args("-A", mac, name)...); err != nil {
		if strings.Contains(string(out), "No chain") {
			return errMarkLater
		}
		return fmt.Errorf("add WARP DNS mark6: %w: %s", err, out)
	}
	return nil
}
func (s PairSet) removeMark(client netip.Addr, name string) {
	// Remove both generations before destroying the set. An upgrade can start
	// the observer before shell selfheal has removed the old direct marks.
	for _, target := range [][]string{{"Z2K_WARP"}, {"MARK", "--set-xmark", "0x989/0x989"}} {
		args := markArgs("-D", client, name)
		args = append(args[:len(args)-1], target...)
		_, _ = s.iptables(args...)
		for i := 0; i < 8; i++ {
			args[3] = "-C"
			if _, err := s.iptables(args...); err != nil {
				break
			}
			args[3] = "-D"
			if _, err := s.iptables(args...); err != nil {
				break
			}
		}
	}
}

// removeMark6 снимает все правила набора, с каким бы MAC они ни стояли.
func (s PairSet) removeMark6(name string) {
	out, err := s.ip6tables("-w", "-t", "mangle", "-S", "PREROUTING")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 || f[0] != "-A" || !strings.Contains(" "+line+" ", " --match-set "+name+" dst ") {
			continue
		}
		f[0] = "-D"
		_, _ = s.ip6tables(append([]string{"-w", "-t", "mangle"}, f...)...)
	}
}
func (s PairSet) Apply(changes []Change, now time.Time) error {
	return s.apply(changes, now, make(marks))
}

// apply: marked — правила метки, уже проверенные. Apply проверяет каждое
// устройство пачки; ответ DNS, который ждёт клиент, передаёт общую память на
// всё время наблюдателя: проверка — запуск iptables, ~100 мс. Правило, снятое
// пересборкой файрвола, вернёт ближайший проход таймера через Apply.
func (s PairSet) apply(changes []Change, now time.Time, marked marks) error {
	var lines []string
	var fresh []markKey
	created := make(map[string]bool)
	flush := func() error {
		if len(lines) > 0 {
			if out, err := s.restore(lines); err != nil {
				return fmt.Errorf("add WARP DNS addresses: %w: %s", err, out)
			}
			lines = lines[:0]
		}
		for _, k := range fresh {
			var err error
			if k.v6 {
				err = s.ensureMark6(k.client)
			} else {
				name, _ := clientSet(k.client)
				err = s.ensureMark(k.client, name)
			}
			if errors.Is(err, errMarkLater) {
				continue
			}
			if err != nil {
				return err
			}
			marked[k] = true
		}
		fresh = fresh[:0]
		return nil
	}
	for _, ch := range changes {
		if _, err := clientSet(ch.Client); err != nil || !EligibleDestination(ch.Dest) {
			return errors.New("invalid WARP DNS pair")
		}
		v6 := ch.Dest.Is6()
		name, key := pairSetName(ch.Client, v6), markKey{ch.Client, v6}
		if ch.Delete {
			if err := flush(); err != nil {
				return err
			}
			delete(created, name)
			_, _ = s.ipset("del", name, ch.Dest.String(), "-exist")
			saved, err := s.ipset("save", name)
			if err == nil && !strings.Contains(string(saved), "\nadd ") {
				if v6 {
					s.removeMark6(name)
				} else {
					s.removeMark(ch.Client, name)
				}
				delete(marked, key)
				_, _ = s.ipset("destroy", name)
			}
			continue
		}
		if !created[name] {
			family := "inet"
			if v6 {
				family = "inet6"
			}
			lines = append(lines, fmt.Sprintf("create %s hash:ip family %s timeout 3600 maxelem 8192 -exist", name, family))
			created[name] = true
			if !marked[key] {
				fresh = append(fresh, key)
			}
		}
		lines = append(lines, fmt.Sprintf("add %s %s timeout %d -exist", name, ch.Dest, timeoutSeconds(ch.Expiry, now)))
	}
	return flush()
}
func (s PairSet) ReplaceAll(changes []Change, now time.Time) error {
	return s.replaceAll(changes, now, make(marks))
}

func (s PairSet) replaceAll(changes []Change, now time.Time, marked marks) error {
	output, err := s.ipset("list", "-n")
	if err != nil {
		return fmt.Errorf("list WARP DNS sets: %w: %s", err, output)
	}
	for _, name := range strings.Fields(string(output)) {
		client, v6, ok := setClient(name)
		if !ok {
			continue
		}
		if v6 {
			s.removeMark6(name)
		} else {
			s.removeMark(client, name)
		}
		if out, err := s.ipset("destroy", name); err != nil {
			return fmt.Errorf("destroy stale WARP DNS set: %w: %s", err, out)
		}
	}
	return s.apply(changes, now, marked)
}

// timeoutSeconds — остаток жизни записи для ipset: вверх до целой секунды,
// в пределах 1..3600 (таймаут набора).
func timeoutSeconds(expiry, now time.Time) int {
	seconds := int(expiry.Sub(now).Seconds())
	if expiry.After(now.Add(time.Duration(seconds) * time.Second)) {
		seconds++
	}
	if seconds < 1 {
		seconds = 1
	}
	if seconds > 3600 {
		seconds = 3600
	}
	return seconds
}

// ExclSetName / ExclSet6Name — наборы адресов доменов-исключений. Совпадение с
// ними проверяют постоянные правила цепочки Z2K_WARP (files/z2k-warp.sh) в
// iptables и ip6tables, поэтому здесь нет правил на клиента; параметры
// создания обязаны совпадать с warp_excl_sets_ensure, иначе -exist откажет
// одному из двух.
const (
	ExclSetName  = "z2k_warp_xdns"
	ExclSet6Name = "z2k_warp_xdns6"
)

// ExclSet пишет адреса доменов-исключений в общие наборы, по семейству.
// NoV6 — ядро без IPv6: набора IPv6 нет и не будет.
type ExclSet struct {
	Binary string
	NoV6   bool
}

func (s ExclSet) ipset(args ...string) ([]byte, error) {
	return PairSet{Binary: s.Binary}.ipset(args...)
}

func exclCreate(name, family string) string {
	return fmt.Sprintf("create %s hash:ip family %s timeout 3600 maxelem 8192 -exist", name, family)
}

func (s ExclSet) Apply(changes []Change, now time.Time) error {
	var v4, v6 []string
	flush := func() error {
		var lines []string
		if len(v4) > 0 {
			lines = append(append(lines, exclCreate(ExclSetName, "inet")), v4...)
		}
		if len(v6) > 0 {
			lines = append(append(lines, exclCreate(ExclSet6Name, "inet6")), v6...)
		}
		v4, v6 = v4[:0], v6[:0]
		if len(lines) == 0 {
			return nil
		}
		if out, err := (PairSet{Binary: s.Binary}).restore(lines); err != nil {
			return fmt.Errorf("add WARP exclusion addresses: %w: %s", err, out)
		}
		return nil
	}
	for _, ch := range changes {
		if !EligibleDestination(ch.Dest) {
			return errors.New("invalid WARP exclusion address")
		}
		name := ExclSetName
		if ch.Dest.Is6() {
			name = ExclSet6Name
		}
		if ch.Delete {
			if err := flush(); err != nil {
				return err
			}
			_, _ = s.ipset("del", name, ch.Dest.String(), "-exist")
			continue
		}
		line := fmt.Sprintf("add %s %s timeout %d -exist", name, ch.Dest, timeoutSeconds(ch.Expiry, now))
		if ch.Dest.Is6() {
			v6 = append(v6, line)
		} else {
			v4 = append(v4, line)
		}
	}
	return flush()
}

// ReplaceAll — наборы целиком из кэша: после рестарта демона в них не должно
// остаться адресов доменов, которые человек уже убрал из исключений.
func (s ExclSet) ReplaceAll(changes []Change, now time.Time) error {
	sets := []struct{ name, family string }{{ExclSetName, "inet"}, {ExclSet6Name, "inet6"}}
	if s.NoV6 {
		sets = sets[:1]
	}
	for _, set := range sets {
		if out, err := (PairSet{Binary: s.Binary}).restore([]string{exclCreate(set.name, set.family)}); err != nil {
			return fmt.Errorf("create WARP exclusion set: %w: %s", err, out)
		}
		if out, err := s.ipset("flush", set.name); err != nil {
			return fmt.Errorf("flush WARP exclusion set: %w: %s", err, out)
		}
	}
	return s.Apply(changes, now)
}
