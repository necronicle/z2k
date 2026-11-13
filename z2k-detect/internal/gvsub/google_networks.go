package gvsub

import (
	_ "embed"
	"encoding/json"
	"net/netip"
	"os"
	"strings"
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
// arbitrary non-Google destinations must not be classified as cache nodes.
func providerCache(name string, a netip.Addr) bool {
	_, _, cache := ParseCluster(name)
	return cache && a.IsValid() && a.IsGlobalUnicast() && !isGoogle(a)
}

func serverReplyConfigured(path string) bool { return configured(path, "Z2K_GV_SERVER_REPLY2", "1") }
func configured(path, key, def string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	v := def
	for _, line := range strings.Split(string(b), "\n") {
		if value, ok := strings.CutPrefix(line, key+"="); ok {
			v = strings.Trim(strings.TrimSpace(value), "\"'")
		}
	}
	return v == "1"
}
