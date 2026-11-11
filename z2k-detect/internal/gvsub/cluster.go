package gvsub

// Соседи плохого адреса — только машины того же кэша.
//
// Имя rrN---sn-XXXX.googlevideo.com — это машина N кластера sn-XXXX, и адреса
// машин кластера разные (замер 10.11.2026: sn-n8v7kn7z, rr1..rr17 =
// 173.194.176.83..99, плохие и рабочие вперемешку). Первая версия брала
// соседа вслепую из /24 и попадала в чужой кластер (.83 → .68): на проверку
// он отвечал, а видео этого кэша у него нет — телевизор Марка буферизовал
// ролики, пока служба не была остановлена. Поэтому кандидаты — только адреса
// других машин того же кластера, по их собственным именам из DNS.

import (
	"context"
	"net"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// MaxMachines — сколько машин кластера опрашивать (rr1..rrN). В замере
// 10.11 у кластеров было 5 и 17 машин; запас сверху.
const MaxMachines = 24

var clusterRe = regexp.MustCompile(`^rr([0-9]+)(?:---|\.)(sn-[a-z0-9-]+)\.(?:googlevideo\.com|c\.youtube\.com)$`)

// ParseCluster — логический кластер и машина в googlevideo.com/c.youtube.com.
func ParseCluster(name string) (cluster string, machine int, ok bool) {
	m := clusterRe.FindStringSubmatch(strings.TrimSuffix(strings.ToLower(name), "."))
	if m == nil {
		return "", 0, false
	}
	n, _ := strconv.Atoi(m[1])
	return m[2], n, true
}

// siblingKey keeps the logical sn-X cluster but isolates DNS families.
// A shared IP in a capture does not guarantee identical DNS answers forever.
func siblingKey(name, cluster string) string {
	if strings.HasSuffix(strings.TrimSuffix(strings.ToLower(name), "."), ".c.youtube.com") {
		return cluster + "/c.youtube.com"
	}
	return cluster
}

// Resolver — адреса машин кластера (ключ siblingKey, с семейством имён).
type Resolver interface {
	Siblings(ctx context.Context, cluster string, v6 bool) []netip.Addr
}

// DNSResolver спрашивает имена машин у DNS самого роутера. Ответы идут через
// lo, и очередь подмены их не трогает (правило с ! -o lo), иначе служба
// придерживала бы собственные запросы.
type DNSResolver struct {
	Server string // адрес:порт; пусто — 127.0.0.1:53

	lookup func(context.Context, string, string) ([]netip.Addr, error) // DNS boundary in tests

	mu    sync.Mutex
	cache map[string]cachedSiblings
}

type cachedSiblings struct {
	addrs []netip.Addr
	at    time.Time
}

// Срок кэша адресов машин: запись googlevideo живёт 1800 с.
const siblingsTTL = 30 * time.Minute

func (r *DNSResolver) Siblings(ctx context.Context, cluster string, v6 bool) []netip.Addr {
	key := cluster
	if v6 {
		key += "/6"
	}
	r.mu.Lock()
	if r.cache == nil {
		r.cache = map[string]cachedSiblings{}
	}
	if c, ok := r.cache[key]; ok && time.Since(c.at) < siblingsTTL {
		r.mu.Unlock()
		return c.addrs
	}
	r.mu.Unlock()

	server := r.Server
	if server == "" {
		server = "127.0.0.1:53"
	}
	res := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, network, server)
	}}
	domain := Suffix
	if c, family, ok := strings.Cut(cluster, "/"); ok {
		cluster, domain = c, family
	}
	network := "ip4"
	if v6 {
		network = "ip6"
	}
	lookup := r.lookup
	if lookup == nil {
		lookup = res.LookupNetIP
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	found := make([]netip.Addr, MaxMachines)
	var wg sync.WaitGroup
	for i := 1; i <= MaxMachines; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ips, err := lookup(ctx, network, "rr"+strconv.Itoa(i)+"---"+cluster+"."+domain)
			if err == nil && len(ips) > 0 {
				found[i-1] = ips[0].Unmap()
			}
		}(i)
	}
	wg.Wait()
	var out []netip.Addr
	seen := map[netip.Addr]bool{}
	for _, a := range found {
		if a.IsValid() && !seen[a] {
			seen[a] = true
			out = append(out, a)
		}
	}
	r.mu.Lock()
	r.cache[key] = cachedSiblings{addrs: out, at: time.Now()}
	r.mu.Unlock()
	return out
}
