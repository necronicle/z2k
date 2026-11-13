package gvsub

import (
	"net/netip"
	"os"
	"strings"
	"testing"
)

func TestPlayDNSAndPreflight(t *testing.T) {
	for _, host := range []string{"rr4---sn-example-a.gvt1.com", "r4.sn-example-b.gvt1.com", "RR4---SN-EXAMPLE-A.GVT1.COM."} {
		for _, ip := range []string{"74.125.99.1", "2a00:1450:4001:44::4"} {
			t.Run(host+ip, func(t *testing.T) {
				a := netip.MustParseAddr(ip)
				typ := uint16(1)
				if a.Is6() {
					typ = 28
				}
				ans, ok := ParseReply(ipv4udp(dnsReply(strings.TrimSuffix(host, "."), rr{typ, a.AsSlice()})))
				if !ok {
					t.Fatal("gvt1 DNS ignored")
				}
				s, _, _, _ := newSvc()
				s.IPFile = t.TempDir() + "/ips"
				s.OnDNS(ans.Name, ans.Addrs)
				b, err := os.ReadFile(s.IPFile)
				if err != nil || !strings.Contains(string(b), ip+"\n") {
					t.Fatalf("not published before DNS release: %q %v", b, err)
				}
			})
		}
	}
	for _, host := range []string{"gvt1.com", "evilgvt1.com", "not-cache.gvt1.com", "rr4---sn-test.gvt1.com.evil"} {
		if IsTarget(host) {
			t.Errorf("unexpected target %s", host)
		}
	}
}

func TestProviderNeverInPreflight(t *testing.T) {
	for _, host := range []string{"rr2---sn-example-node.googlevideo.com", "rr2---sn-example-node.gvt1.com", "r2.sn-example-node.c.youtube.com"} {
		t.Run(host, func(t *testing.T) {
			s, _, _, _ := newSvc()
			s.IPFile = t.TempDir() + "/ips"
			for _, ip := range []string{"192.0.2.141", "2001:db8::d"} {
				s.OnDNS(host, []netip.Addr{netip.MustParseAddr(ip)})
			}
			b, e := os.ReadFile(s.IPFile)
			if e != nil {
				t.Fatal(e)
			}
			if string(b) != ipFileSentinels {
				t.Fatalf("provider in preflight: %q", b)
			}
		})
	}
}

func TestPlayWantedIgnoresRetiredKey(t *testing.T) {
	p := t.TempDir() + "/config"
	for _, old := range []string{"0", "1", ""} {
		for _, reply := range []string{"0", "1"} {
			for _, provider := range []string{"0", "1"} {
				body := "Z2K_GV_SERVER_REPLY2=" + reply + "\nZ2K_PROVIDER_CACHE=" + provider + "\n"
				if old != "" {
					body += "Z2K_GV_SUBST=" + old + "\n"
				}
				if err := os.WriteFile(p, []byte(body), 0600); err != nil {
					t.Fatal(err)
				}
				if got := wanted(Config{ConfigPath: p}); got != (reply == "1") {
					t.Errorf("%s wanted=%t", body, got)
				}
			}
		}
	}
}

func TestServerReplyProbesDNSAddress(t *testing.T) {
	s, n, _, _ := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	n.mu.Lock()
	calls := n.calls
	n.mu.Unlock()
	if calls != 1 {
		t.Fatalf("DNS address probes=%d, want 1", calls)
	}
}

func TestProviderObservationPublishedBeforeDNSRelease(t *testing.T) {
	s, _, _, _ := newSvc()
	s.StatusPath = t.TempDir() + "/status"
	s.IPFile = t.TempDir() + "/ips"
	s.OnDNS("rr2---sn-cache.gvt1.com", []netip.Addr{netip.MustParseAddr("192.0.2.141")})
	b, e := os.ReadFile(s.StatusPath + ".neutral")
	if e != nil || !strings.Contains(string(b), "provider c000028d") {
		t.Fatalf("provider observation not synchronous: %q %v", b, e)
	}
}

func TestTeardownRemovesLegacyDNSRules(t *testing.T) {
	var calls []string
	r := IPTables{Run: func(bin string, args ...string) error {
		calls = append(calls, bin+" "+strings.Join(args, " "))
		return os.ErrNotExist
	}}
	r.Teardown()
	for _, bin := range []string{"iptables", "ip6tables"} {
		for _, kind := range []string{"video", "cache", "gvt1"} {
			rule := strings.Join(r.dnsRule(kind), " ")
			old := strings.ReplaceAll(rule, "--icase ", "")
			if !strings.Contains(strings.Join(calls, "\n"), bin+" -w -t mangle -D OUTPUT "+old) {
				t.Fatalf("legacy %s/%s DNS rule not removed", bin, kind)
			}
		}
	}
}
