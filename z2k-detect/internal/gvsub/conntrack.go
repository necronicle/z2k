package gvsub

// Детектор по conntrack: соединение, в котором клиент уже отправил данные
// (ClientHello), а от сервера пришли только служебные пакеты без данных
// (SYN,ACK и подтверждения кусков ClientHello). Это ровно картина блока по
// ответу сервера, и видна она для всех устройств сети сразу, без участия
// движка. Ловит смену состояния адреса между ответами DNS.
//
// Заодно conntrack показывает, какие адреса в ходу: устройство берёт адрес из
// своего кэша DNS и ходит на него, не спрашивая роутер. Подмену такого адреса
// снимать нельзя (10.11.2026: снятая подмена — и видео на Mac встало).

import (
	"bufio"
	"io"
	"net/netip"
	"strconv"
	"strings"
)

// Flow — запись conntrack, нужная детектору.
type Flow struct {
	Key       string // src:sport>dst:dport — для отслеживания между опросами
	Proto     string // tcp или udp
	Src       netip.Addr
	Dst       netip.Addr
	Sport     uint16
	Dport     uint16
	ReplySrc  netip.Addr // отправитель ответа: не Dst — соединение переадресовано
	OrigBytes int
	ReplyPkts int
	Stuck     bool // TCP: данные клиента ушли, данных сервера нет
}

// Порог данных клиента: заголовки SYN и ACK занимают 40–60 байт на пакет у
// IPv4 и 60–80 у IPv6, ClientHello — от 200 байт. Три служебных пакета
// клиента дают меньше 300 байт, с ClientHello — больше.
const minClientBytes = 300

// Пакет сервера без данных — не длиннее заголовков: IPv6 40 + TCP с
// параметрами до 60 байт. Сервер подтверждает каждый кусок разрезанного
// ClientHello, поэтому пустых пакетов в ответе бывает 5–6 (замер 10.11:
// 6 пакетов / 440 байт, 5 / 368), а ServerHello один длиннее 1000 байт.
const maxEmptyPacket = 100

// ParseConntrack читает /proc/net/nf_conntrack и возвращает соединения TCP и
// UDP к порту 443. Stuck — TCP, где клиент передал данные, а сервер не
// прислал ни байта данных.
func ParseConntrack(r io.Reader) []Flow {
	var out []Flow
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 6 || (f[2] != "tcp" && f[2] != "udp") {
			continue
		}
		var src, dst, sport, dport, rsrc string
		var obytes, rpkts, rbytes int
		seen := map[string]int{}
		for _, kv := range f[5:] {
			k, v, ok := strings.Cut(kv, "=")
			if !ok {
				continue
			}
			seen[k]++
			first := seen[k] == 1
			switch k {
			case "src":
				if first {
					src = v
				} else if seen[k] == 2 {
					rsrc = v
				}
			case "dst":
				if first {
					dst = v
				}
			case "sport":
				if first {
					sport = v
				}
			case "dport":
				if first {
					dport = v
				}
			case "bytes":
				if first {
					obytes, _ = strconv.Atoi(v)
				}
			case "packets":
				if !first {
					rpkts, _ = strconv.Atoi(v)
				}
			}
			if k == "bytes" && !first {
				rbytes, _ = strconv.Atoi(v)
			}
		}
		if dport != "443" || seen["packets"] < 2 {
			continue
		}
		a, err := netip.ParseAddr(dst)
		if err != nil {
			continue
		}
		sa, _ := netip.ParseAddr(src)
		ra, _ := netip.ParseAddr(rsrc)
		sp, _ := strconv.ParseUint(sport, 10, 16)
		dp, _ := strconv.ParseUint(dport, 10, 16)
		out = append(out, Flow{Key: src + ":" + sport + ">" + dst + ":" + dport, Proto: f[2],
			Src: sa.Unmap(), Dst: a.Unmap(), Sport: uint16(sp), Dport: uint16(dp), ReplySrc: ra.Unmap(),
			OrigBytes: obytes, ReplyPkts: rpkts,
			Stuck: f[2] == "tcp" && obytes >= minClientBytes && rbytes <= rpkts*maxEmptyPacket})
	}
	return out
}
