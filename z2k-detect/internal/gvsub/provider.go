package gvsub

import (
	_ "embed"
	"encoding/json"
	"net/netip"
)

// Official Google networks, https://www.gstatic.com/ipranges/goog.json.
// Snapshot fetched 2026-11-11, creationTime 2026-11-11T00:09:06.01548,
// syncToken 1794384546015 (148 prefixes). Keep the complete list: cloud.json
// covers only Google Cloud, and a cache's sn-X name does not identify its owner.
// No network refresh on the router. Refresh this snapshot with code releases.
//
//go:embed goog.json
var googleSnapshot []byte

var googleNetworks = func() []netip.Prefix {
	var doc struct {
		Prefixes []struct {
			V4 string `json:"ipv4Prefix"`
			V6 string `json:"ipv6Prefix"`
		} `json:"prefixes"`
	}
	if err := json.Unmarshal(googleSnapshot, &doc); err != nil {
		panic(err) // invalid built-in data is a build/release error
	}
	var nets []netip.Prefix
	for _, p := range doc.Prefixes {
		cidr := p.V4
		if cidr == "" {
			cidr = p.V6
		}
		nets = append(nets, netip.MustParsePrefix(cidr))
	}
	return nets
}()

func isGoogle(a netip.Addr) bool {
	a = a.Unmap()
	for _, p := range googleNetworks {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

// Only a DNS-observed cache name qualifies; other googlevideo services and
// arbitrary non-Google destinations must never become rejection candidates.
func providerCache(name string, a netip.Addr) bool {
	_, _, cache := ParseCluster(name)
	return cache && a.IsValid() && a.IsGlobalUnicast() && !isGoogle(a)
}

// providerReadyLocked is deliberately conservative: a fresh TLS response from
// a DNS-observed Google video node in this address family is required. Neither
// an old saved verdict nor working IPv4 proves IPv6 is usable. This is node
// reachability, not proof that Google can serve every individual video.
func (s *Service) providerReadyLocked() map[bool]bool {
	ready := map[bool]bool{}
	now := s.Now()
	for a, e := range s.known {
		if isGoogle(a) && e.verdict == Good && now.Sub(e.checked) < CacheTTL {
			ready[a.Is6()] = true
		}
	}
	return ready
}
