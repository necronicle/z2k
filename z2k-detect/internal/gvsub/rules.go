package gvsub

// DNS interception only; no address substitution.
import (
	"fmt"
	"os/exec"
	"strings"
)

type Rules interface {
	Ensure() (bool, error)
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

func (r IPTables) dnsRule(kind string) []string {
	q := r.Queue
	if q == "" {
		q = "210"
	}
	// ! -o lo: ответы на собственные запросы службы (имена машин кластера)
	// идут через lo и придерживаться не должны.
	match, value := "--string", "googlevideo"
	if kind == "cache" {
		match, value = "--hex-string", cacheDNSHex
	} else if kind == "gvt1" {
		match, value = "--hex-string", "|046776743103636f6d00|"
	}
	return []string{"!", "-o", "lo", "-p", "udp", "--sport", "53", "-m", "string", "--algo", "bm", "--icase", match, value,
		"-j", "NFQUEUE", "--queue-num", q, "--queue-bypass"}
}

// Old hooks are removed on upgrade/stop; never created again.
var legacyHooks = [...]struct{ table, parent, chain string }{
	{"nat", "PREROUTING", "Z2K_GVSUB"}, {"mangle", "PREROUTING", "Z2K_GVSUB"}, {"filter", "FORWARD", "Z2K_GVSUB_Q"},
}

func (r IPTables) Ensure() (bool, error) {
	recreated := false
	var firstErr error
	for _, bin := range r.bins() {
		for _, kind := range []string{"video", "cache", "gvt1"} {
			check := append([]string{"-w", "-t", "mangle", "-C", "OUTPUT"}, r.dnsRule(kind)...)
			if r.run(bin, check...) != nil {
				ins := append([]string{"-w", "-t", "mangle", "-I", "OUTPUT", "1"}, r.dnsRule(kind)...)
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
		for _, kind := range []string{"video", "cache", "gvt1"} {
			rule := r.dnsRule(kind)
			legacy := make([]string, 0, len(rule))
			for _, arg := range rule {
				if arg != "--icase" {
					legacy = append(legacy, arg)
				}
			}
			for _, shape := range [][]string{rule, legacy} {
				del := append([]string{"-w", "-t", "mangle", "-D", "OUTPUT"}, shape...)
				for i := 0; i < 8 && r.run(bin, del...) == nil; i++ {
				}
			}
		}
		for _, h := range legacyHooks {
			t, parent, chain := h.table, h.parent, h.chain
			for i := 0; i < 8 && r.run(bin, "-w", "-t", t, "-D", parent, "-j", chain) == nil; i++ {
			}
			_ = r.run(bin, "-w", "-t", t, "-F", chain)
			_ = r.run(bin, "-w", "-t", t, "-X", chain)
		}
	}
}
