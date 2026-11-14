// Package nat — FORWARD-accept, MASQUERADE и MSS-clamp для z2ktunN.
//
// Интерфейс не зарегистрирован в NDM, поэтому NDM его не NAT-ит, MSS не
// режет и — главное — не пропускает на него форвард. На некоторых прошивках
// ранний CONNNDMMARK REJECT стоит перед штатным ESTABLISHED ACCEPT: SYN-ACK
// приходит из TUN, но до LAN не доходит. Два узких правила для помеченного
// исходящего трафика и ответа существующего соединения вставляем в начало
// FORWARD. Правила NDM сносит на каждом регене netfilter; их
// возвращает хук /opt/etc/ndm/netfilter.d/93-z2k-warp.sh — той же формы,
// что здесь. Всегда `iptables -w`: без него гонка с churn'ом NDM молча
// роняет вставку.
package nat

import (
	"fmt"
	"strconv"
	"strings"
)

// Runner — как в tundev; принимает "iptables" и аргументы.
type Runner func(name string, args ...string) (string, error)

// Rules — правила для iface: [таблица, цепочка, аргументы...].
//
// MSS ЗАЖИМАЕТСЯ В ОБЕ СТОРОНЫ, И ВТОРОЕ ПРАВИЛО НЕ ЗЕРКАЛЬНОЕ ПЕРВОМУ.
//
// Замер на роутере владельца 2026-08-25, живой трафик телефона через туннель:
//
//	SYN     клиент -> в туннель   : mss 1240   (140 из 140 — зажат)
//	SYN-ACK сервер -> из туннеля  : mss 1460   (140 из 140 — НЕ зажат)
//
// То есть клиенту разрешалось слать в туннель с MTU 1280 сегменты по 1460.
// Скачивание при этом шло — 156 МБ за прогон, — а всё, что клиент ОТПРАВЛЯЕТ
// крупнее mss байт, обрывалось. В поле это звучало как «карты не грузятся, hh
// падает»: рушится не интернет, а страницы, где клиент много отправляет.
//
// Зеркальное правило не годится: SYN-ACK уходит через мост с MTU 1500, и
// --clamp-mss-to-pmtu дал бы там те же 1460. Нужен явный --set-mss по MTU
// туннеля. Прошивка для своего аплинка ppp0 ставит зажим в обе стороны — мы
// делали в одну.
//
// После починки замер повторён на том же телефоне: 176 из 176 соединений
// видят mss 1240.
func Rules(iface string, mss int) [][]string {
	return [][]string{
		{"filter", "FORWARD", "-o", iface, "-m", "mark", "--mark", "0x989/0x989", "-j", "ACCEPT"},
		{"filter", "FORWARD", "-i", iface, "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"},
		{"nat", "POSTROUTING", "-o", iface, "-j", "MASQUERADE"},
		{"mangle", "FORWARD", "-o", iface, "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--clamp-mss-to-pmtu"},
		{"mangle", "FORWARD", "-i", iface, "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--set-mss", strconv.Itoa(mss)},
	}
}

// Rules6 — то же для IPv6: WARP даёт аккаунту один адрес /128, поэтому
// устройства выходят через NAT66 (MASQUERADE), как на OpenWrt и MikroTik.
// mss6 — MTU туннеля минус 40 байт IPv6 и 20 TCP.
func Rules6(iface string, mss6 int) [][]string { return Rules(iface, mss6) }

func args(op string, r []string) []string {
	return append([]string{"-w", "-t", r[0], op, r[1]}, r[2:]...)
}

func insertArgs(r []string) []string {
	return append([]string{"-w", "-t", r[0], "-I", r[1], "1"}, r[2:]...)
}

// Ensure ставит недостающие правила (-C || -A).
func Ensure(run Runner, iface string, mss int) error {
	return ensure(run, "iptables", Rules(iface, mss))
}

// Ensure6 — правила IPv6 (ip6tables).
func Ensure6(run Runner, iface string, mss6 int) error {
	return ensure(run, "ip6tables", Rules6(iface, mss6))
}

func ensure(run Runner, bin string, rules [][]string) error {
	for _, r := range rules {
		if _, err := run(bin, args("-C", r)...); err == nil {
			continue
		}
		add := args("-A", r)
		if r[0] == "filter" {
			add = insertArgs(r)
		}
		if out, err := run(bin, add...); err != nil {
			return fmt.Errorf("%s -t %s %s %s: %s", bin, r[0], add[3], r[1], strings.TrimSpace(out))
		}
	}
	return nil
}

// Remove удаляет правила, пока -C их находит (дубликаты от старых запусков).
func Remove(run Runner, iface string, mss int) error {
	return remove(run, "iptables", Rules(iface, mss))
}

// Remove6 — то же для IPv6.
func Remove6(run Runner, iface string, mss6 int) error {
	return remove(run, "ip6tables", Rules6(iface, mss6))
}

func remove(run Runner, bin string, rules [][]string) error {
	for _, r := range rules {
		for i := 0; i < 16; i++ {
			if _, err := run(bin, args("-C", r)...); err != nil {
				break
			}
			if _, err := run(bin, args("-D", r)...); err != nil {
				break
			}
		}
	}
	return nil
}
