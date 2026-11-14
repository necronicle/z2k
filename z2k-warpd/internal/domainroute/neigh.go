package domainroute

import (
	"bufio"
	"bytes"
	"context"
	"net/netip"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Таблица соседей связывает три имени одного устройства. Маршрутизация по
// доменам ведёт наборы на устройство по его IPv4; спросившее DNS по IPv6
// узнаём по таблице соседей (IPv6 → MAC → IPv4 того же MAC). IPv6-трафик
// устройства метится по MAC (IPv4 → MAC): временные IPv6-адреса меняются.
//
// Таблицу перечитываем, только когда адреса в ней нет, и не чаще раза в
// neighRetry: промах на каждом ответе DNS не должен превращаться в запуск
// `ip` на каждом пакете. Через neighMaxAge перечитываем и при попадании —
// адрес мог перейти к другому устройству.
const (
	neighRetry  = 2 * time.Second
	neighMaxAge = time.Minute
)

type neighbors struct {
	mu     sync.Mutex
	v4     map[netip.Addr]netip.Addr // IPv6 устройства → его IPv4
	mac    map[netip.Addr]string     // IPv4 устройства → его MAC
	loaded time.Time
	read   func() (v6, v4 []byte)
}

func newNeighbors() *neighbors { return &neighbors{read: readNeighTables} }

// lookup — общий порядок перечитывания для обоих вопросов.
func (n *neighbors) lookup(now time.Time, find func() bool) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	ok := find()
	stale := now.Sub(n.loaded) >= neighMaxAge
	if (ok && !stale) || (!ok && now.Sub(n.loaded) < neighRetry) {
		return ok
	}
	n.v4, n.mac = mapNeighbors(n.read())
	n.loaded = now
	return find()
}

func (n *neighbors) ipv4For(client netip.Addr, now time.Time) (netip.Addr, bool) {
	var ip netip.Addr
	ok := n.lookup(now, func() bool {
		var hit bool
		ip, hit = n.v4[client]
		return hit
	})
	return ip, ok
}

func (n *neighbors) macFor(client netip.Addr, now time.Time) (string, bool) {
	var mac string
	ok := n.lookup(now, func() bool {
		var hit bool
		mac, hit = n.mac[client]
		return hit
	})
	return mac, ok
}

func readNeighTables() (v6, v4 []byte) {
	run := func(family string) []byte {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		out, _ := exec.CommandContext(ctx, "ip", family, "neigh", "show").Output()
		return out
	}
	return run("-6"), run("-4")
}

// mapNeighbors сводит вывод `ip -6 neigh` и `ip -4 neigh`. Строка без lladdr
// (FAILED, INCOMPLETE) пропускается; IPv4 берётся только из локальной сети —
// как и у наборов на устройство (clientSet).
func mapNeighbors(v6, v4 []byte) (map[netip.Addr]netip.Addr, map[netip.Addr]string) {
	byMAC := make(map[string]netip.Addr)
	macs := make(map[netip.Addr]string)
	eachNeighbor(v4, func(ip netip.Addr, mac string) {
		if _, err := clientSet(ip); err == nil {
			byMAC[mac] = ip
			macs[ip] = mac
		}
	})
	result := make(map[netip.Addr]netip.Addr)
	eachNeighbor(v6, func(ip netip.Addr, mac string) {
		if v4, ok := byMAC[mac]; ok && ip.Is6() {
			result[ip] = v4
		}
	})
	return result, macs
}

func eachNeighbor(table []byte, fn func(netip.Addr, string)) {
	sc := bufio.NewScanner(bytes.NewReader(table))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 3 {
			continue
		}
		ip, err := netip.ParseAddr(f[0])
		if err != nil {
			continue
		}
		for i := 1; i+1 < len(f); i++ {
			if f[i] == "lladdr" {
				fn(ip.WithZone("").Unmap(), strings.ToLower(f[i+1]))
				break
			}
		}
	}
}
