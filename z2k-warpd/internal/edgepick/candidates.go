package edgepick

import (
	"bufio"
	"io"
	"math/rand"
	"net/netip"
	"os"
	"strings"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

const maxPoolFile = 16 << 10

var excludedPools = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"), netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"), netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.2.0/24"), netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"), netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

// ReadPools loads a small, curated file of candidate /24s. Connectivity is
// still verified by a real WARP handshake; a prefix alone proves nothing.
func ReadPools(path string) []netip.Prefix {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var pools []netip.Prefix
	seen := map[netip.Prefix]bool{}
	sc := bufio.NewScanner(io.LimitReader(f, maxPoolFile))
	for sc.Scan() && len(pools) < 64 {
		line := strings.TrimSpace(strings.SplitN(sc.Text(), "#", 2)[0])
		p, err := netip.ParsePrefix(line)
		if err != nil || !p.Addr().Is4() || p.Bits() != 24 || p != p.Masked() || seen[p] {
			continue
		}
		bad := false
		for _, x := range excludedPools {
			if x.Contains(p.Addr()) {
				bad = true
				break
			}
		}
		if bad {
			continue
		}
		seen[p] = true
		pools = append(pools, p)
	}
	return pools
}

// Candidates samples different known networks without expanding a whole pool.
// Registration and the existing fallback addresses retain first priority.
func Candidates(ep account.Endpoint, fallback []string, pools []netip.Prefix, limit int, seed uint64) []account.Step {
	if limit <= 0 {
		return nil
	}
	var result []account.Step
	seen := map[string]bool{}
	add := func(host string) {
		a, err := netip.ParseAddr(host)
		if err != nil || !a.Is4() || seen[host] || len(result) >= limit {
			return
		}
		seen[host] = true
		result = append(result, account.Step{Transport: "wg", Host: host, Port: 2408})
	}
	add(ep.V4)
	for _, alt := range ep.Alt {
		add(alt.Host)
	}
	for _, host := range fallback {
		add(host)
	}
	rng := rand.New(rand.NewSource(int64(seed)))
	// One sample per pool before any second sample keeps a small scan diverse.
	perms := make([][]int, len(pools))
	for i := range pools {
		perms[i] = rng.Perm(254)
	}
	for round := 0; round < 2 && len(result) < limit; round++ {
		for i, p := range pools {
			if len(result) >= limit || !p.IsValid() || !p.Addr().Is4() || p.Bits() != 24 {
				continue
			}
			a := p.Masked().Addr().As4()
			a[3] = byte(perms[i][round] + 1)
			add(netip.AddrFrom4(a).String())
		}
	}
	return result
}
