package gvsub

import (
	"context"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"sync"
	"testing"
)

func TestCYouTubeNamesAndDNS(t *testing.T) {
	for _, q := range []string{"rr1---sn-4g5e6nss.c.youtube.com", "RR17.SN-4G5E6NSS.C.YOUTUBE.COM."} {
		c, n, ok := ParseCluster(q)
		if !ok || c != "sn-4g5e6nss" || n < 1 {
			t.Fatalf("cluster %s: %s/%d/%v", q, c, n, ok)
		}
		gc, _, _ := ParseCluster("rr1---sn-4g5e6nss.googlevideo.com")
		if c != gc {
			t.Fatal("different logical cluster")
		}
		for _, wrap := range []func([]byte) []byte{ipv4udp, ipv6udp} {
			msg := dnsReply(strings.TrimSuffix(q, "."), rr{5, name("rr1.sn-4g5e6nss.c.youtube.com")}, rr{1, []byte{173, 194, 182, 198}}, rr{28, netip.MustParseAddr("2a00:1450:4001:5e::6").AsSlice()})
			a, ok := ParseReply(wrap(msg))
			if !ok || len(a.Addrs) != 2 {
				t.Fatalf("DNS %s: %+v/%v", q, a, ok)
			}
		}
	}
	for _, q := range []string{"youtube.com", "www.youtube.com", "c.youtube.com", "other.c.youtube.com", "rr1---sn-x.c.youtube.com.evil", "rr1---sn-x.evilc.youtube.com", "sub.rr1---sn-x.c.youtube.com"} {
		if IsTarget(q) {
			t.Fatalf("unrelated target: %s", q)
		}
		if _, ok := ParseReply(ipv4udp(dnsReply(q, rr{1, bad.AsSlice()}))); ok {
			t.Fatalf("unrelated DNS: %s", q)
		}
		s, _, _, _ := newSvc()
		select {
		case <-s.OnDNS(q, []netip.Addr{bad}):
		default:
			t.Fatal("unrelated name held")
		}
		if len(s.known) != 0 {
			t.Fatal("unrelated name registered")
		}
	}
}

type cacheResolver struct{}

func (cacheResolver) Siblings(_ context.Context, cluster string, v6 bool) []netip.Addr {
	if cluster != "sn-test/c.youtube.com" {
		return nil
	}
	if v6 {
		return []netip.Addr{netip.MustParseAddr("2a00:1450:4001:5e::7")}
	}
	return []netip.Addr{netip.MustParseAddr("74.125.110.38")}
}
func TestCYouTubeService(t *testing.T) {
	for _, q := range []string{"rr1---sn-test.c.youtube.com", "rr1.sn-test.c.youtube.com"} {
		t.Run(q, func(t *testing.T) {
			s, _, r, _ := newSvc()
			s.Resolver = cacheResolver{}
			s.IPFile = t.TempDir() + "/ips"
			done := s.OnDNS(q, []netip.Addr{bad})
			b, err := os.ReadFile(s.IPFile)
			if err != nil || !strings.Contains(string(b), bad.String()+"\n") {
				t.Fatalf("IPFile before release: %s/%v", b, err)
			}
			wait(t, done)
			if g, _ := r.get(bad.String()); g != "74.125.110.38" {
				t.Fatalf("substitution: %s", g)
			}
			if !r.rejects(bad) {
				t.Fatal("no QUIC reject")
			}
			s.Shutdown()
		})
	}
	for _, wl := range []string{"youtube.com", "c.youtube.com", "rr1---sn-test.c.youtube.com"} {
		s, n, r, _ := newSvc()
		s.Whitelist, s.IPFile = t.TempDir()+"/whitelist", t.TempDir()+"/ips"
		putWhitelist(t, s.Whitelist, wl+"\n")
		wait(t, s.OnDNS("rr1---sn-test.c.youtube.com", []netip.Addr{bad}))
		if n.calls != 0 || r.adds != 0 || len(s.known) != 0 {
			t.Fatalf("whitelist %s ignored", wl)
		}
		if _, err := os.Stat(s.IPFile); !os.IsNotExist(err) {
			t.Fatal("whitelisted IP published")
		}
	}
}

func TestCYouTubeIPv6Service(t *testing.T) {
	s, n, r, _ := newSvc()
	bad6 := netip.MustParseAddr("2a00:1450:4001:5e::6")
	good6 := netip.MustParseAddr("2a00:1450:4001:5e::7")
	n.mu.Lock()
	n.state[bad6.String()] = Bad
	n.state[good6.String()] = Good
	n.mu.Unlock()
	s.Resolver = cacheResolver{}
	s.IPFile = t.TempDir() + "/ips"
	done := s.OnDNS("rr1---sn-test.c.youtube.com", []netip.Addr{bad6})
	b, err := os.ReadFile(s.IPFile)
	if err != nil || !strings.Contains(string(b), bad6.String()+"\n") {
		t.Fatalf("AAAA not published: %s/%v", b, err)
	}
	wait(t, done)
	if g, _ := r.get(bad6.String()); g != good6.String() {
		t.Fatalf("IPv6 substitution: %s", g)
	}
	if !r.rejects(bad6) {
		t.Fatal("IPv6 QUIC not rejected")
	}
	s.Shutdown()
}

// Exercise neighbour lookup, concurrent enumeration and namespace/family caches.
// Only DNS transport is replaced: sandbox does not permit binding local sockets.
func TestCYouTubeSiblingDNS(t *testing.T) {
	var mu sync.Mutex
	queries := map[string]int{}
	r := &DNSResolver{lookup: func(_ context.Context, network, q string) ([]netip.Addr, error) {
		mu.Lock()
		queries[q]++
		mu.Unlock()
		a := netip.MustParseAddr("173.194.182.198")
		if strings.HasSuffix(q, ".c.youtube.com") {
			a = netip.MustParseAddr("173.194.10.103")
		}
		if network == "ip6" {
			a = netip.MustParseAddr("2a00:1450:4001:5e::6")
		}
		return []netip.Addr{a}, nil
	}}
	for _, tc := range []struct {
		key  string
		v6   bool
		want string
	}{
		{"sn-test", false, "173.194.182.198"}, {"sn-test/c.youtube.com", false, "173.194.10.103"}, {"sn-test/c.youtube.com", true, "2a00:1450:4001:5e::6"},
	} {
		for i := 0; i < 2; i++ {
			got := r.Siblings(context.Background(), tc.key, tc.v6)
			if len(got) != 1 || got[0].String() != tc.want {
				t.Fatalf("%s/%v: %v", tc.key, tc.v6, got)
			}
		}
	}
	mu.Lock()
	defer mu.Unlock()
	for i := 1; i <= MaxMachines; i++ {
		for _, suffix := range []string{"googlevideo.com", "c.youtube.com"} {
			q := fmt.Sprintf("rr%d---sn-test.%s", i, suffix)
			want := 1
			if suffix == "c.youtube.com" {
				want = 2
			}
			if queries[q] != want {
				t.Fatalf("query/cache %s: %d, want %d", q, queries[q], want)
			}
		}
	}
}
func TestCYouTubeDNSRules(t *testing.T) {
	var calls []string
	r := IPTables{Run: func(bin string, args ...string) error {
		line := bin + " " + strings.Join(args, " ")
		calls = append(calls, line)
		if strings.Contains(line, " -C ") || strings.Contains(line, " -D ") {
			return fmt.Errorf("missing")
		}
		return nil
	}, Out: func(string, ...string) (string, error) { return "", nil }}
	if _, err := r.Ensure(); err != nil {
		t.Fatal(err)
	}
	r.Teardown()
	all := strings.Join(calls, "\n")
	for _, bin := range []string{"iptables", "ip6tables"} {
		for _, op := range []string{"-I OUTPUT 1", "-D OUTPUT"} {
			for _, match := range []string{"--string googlevideo", "--hex-string " + cacheDNSHex} {
				want := bin + " -w -t mangle " + op + " ! -o lo -p udp --sport 53 -m string --algo bm " + match + " -j NFQUEUE --queue-num 210 --queue-bypass"
				if !strings.Contains(all, want) {
					t.Fatalf("missing %s", want)
				}
			}
		}
	}
}
