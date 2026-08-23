// Package nat — FORWARD-accept, MASQUERADE и MSS-clamp для z2ktunN.
//
// Интерфейс не зарегистрирован в NDM, поэтому NDM его не NAT-ит, MSS не
// режет и — главное — не пропускает на него форвард: политика FORWARD у
// NDM DROP, а _NDM_FORWARD принимает только свои интерфейсы (измерено: все
// помеченные пакеты легли в policy DROP). Обратный путь покрыт правилом
// RELATED,ESTABLISHED в начале цепочки. Делаем сами, через -A: после цепочек
// NDM, чтобы ACL юзера продолжали действовать. Правила NDM сносит на каждом регене netfilter; их
// возвращает хук /opt/etc/ndm/netfilter.d/93-z2k-warp.sh — той же формы,
// что здесь. Всегда `iptables -w`: без него гонка с churn'ом NDM молча
// роняет вставку.
package nat

import (
	"fmt"
	"strings"
)

// Runner — как в tundev; принимает "iptables" и аргументы.
type Runner func(name string, args ...string) (string, error)

// Rules — правила для iface: [таблица, цепочка, аргументы...].
func Rules(iface string) [][]string {
	return [][]string{
		{"filter", "FORWARD", "-o", iface, "-j", "ACCEPT"},
		{"nat", "POSTROUTING", "-o", iface, "-j", "MASQUERADE"},
		{"mangle", "FORWARD", "-o", iface, "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--clamp-mss-to-pmtu"},
	}
}

func args(op string, r []string) []string {
	return append([]string{"-w", "-t", r[0], op, r[1]}, r[2:]...)
}

// Ensure ставит недостающие правила (-C || -A).
func Ensure(run Runner, iface string) error {
	for _, r := range Rules(iface) {
		if _, err := run("iptables", args("-C", r)...); err == nil {
			continue
		}
		if out, err := run("iptables", args("-A", r)...); err != nil {
			return fmt.Errorf("iptables -t %s -A %s: %s", r[0], r[1], strings.TrimSpace(out))
		}
	}
	return nil
}

// Remove удаляет правила, пока -C их находит (дубликаты от старых запусков).
func Remove(run Runner, iface string) error {
	for _, r := range Rules(iface) {
		for i := 0; i < 16; i++ {
			if _, err := run("iptables", args("-C", r)...); err != nil {
				break
			}
			if _, err := run("iptables", args("-D", r)...); err != nil {
				break
			}
		}
	}
	return nil
}
