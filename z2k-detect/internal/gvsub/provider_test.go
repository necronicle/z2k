package gvsub

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"
)

func TestProviderClassification(t *testing.T) {
	if len(googleNetworks) != 148 {
		t.Fatal("incomplete Google snapshot")
	}
	for _, p := range googleNetworks {
		if !isGoogle(p.Addr()) {
			t.Fatalf("snapshot prefix omitted: %s", p)
		}
	}
	for _, addr := range []string{"88.87.65.140", "88.87.65.141", "88.87.65.142", "188.234.130.206", "2a02:2698:c00:fc00::c", "2a02:2698:c00:fc00::d", "2a02:2698:c00:fc00::e", "2a02:2698:a100:3::e"} {
		for _, name := range []string{"rr2---sn-xguxaxjvh-8vbs.googlevideo.com", "r3---sn-xguxaxjvh-bvwe.googlevideo.com", "rr1.sn-test.c.youtube.com", "RR1---SN-TEST.GVT1.COM."} {
			if !providerCache(name, netip.MustParseAddr(addr)) {
				t.Fatalf("provider cache missed: %s %s", name, addr)
			}
		}
	}
	for _, addr := range []string{"74.125.110.70", "173.194.176.83", "142.250.0.1", "2a00:1450::7", "2607:f8b0::1", "::ffff:74.125.110.70"} {
		if !isGoogle(netip.MustParseAddr(addr)) || providerCache(gvName, netip.MustParseAddr(addr)) {
			t.Fatalf("Google classified as provider: %s", addr)
		}
	}
	for _, name := range []string{"googlevideo.com", "redirector.googlevideo.com", "rr1---sn-test.googlevideo.com.evil", "rr1---sn-test.example.com", "gvt1.com", "c.youtube.com"} {
		if providerCache(name, netip.MustParseAddr("88.87.65.141")) {
			t.Fatalf("non-cache classified: %s", name)
		}
	}
}

func TestProviderLifecycle(t *testing.T) {
	for _, pair := range [][2]string{{"88.87.65.141", "74.125.110.38"}, {"2a02:2698:c00:fc00::d", "2a00:1450::7"}} {
		t.Run(pair[0], func(t *testing.T) {
			s, n, r, c := newSvc()
			s.Resolver = nil
			provider, google := netip.MustParseAddr(pair[0]), netip.MustParseAddr(pair[1])
			n.state[google.String()] = Good
			wait(t, s.OnDNS(gvName, []netip.Addr{provider}))
			assert := func(want bool) {
				t.Helper()
				if r.rejects(provider) != want || r.rejectsTCP(provider) != want {
					t.Fatalf("provider %s: TCP=%v UDP=%v want=%v", provider, r.rejectsTCP(provider), r.rejects(provider), want)
				}
				if r.rejects(google) || r.rejectsTCP(google) || len(s.Mappings()) != 0 {
					t.Fatal("provider mapped or Google rejected")
				}
			}
			assert(false) // no evidence: provider is the only possible path
			wait(t, s.OnDNS(gvName, []netip.Addr{google}))
			assert(true) // previously seen provider becomes rejected
			wait(t, s.OnDNS("rr2---sn-test.gvt1.com", []netip.Addr{provider}))
			assert(true)
			r.mu.Lock()
			r.recreate = true
			r.mu.Unlock()
			s.Tick()
			assert(true)
			s.Reapply() // HUP, exact desired addresses
			assert(true)
			c.add(CacheTTL + time.Second)
			s.Reapply()
			assert(false) // stale health never authorizes rejection
			n.mu.Lock()
			n.state[google.String()] = Dead
			n.mu.Unlock()
			wait(t, s.OnDNS(gvName, []netip.Addr{google}))
			assert(false)
			n.mu.Lock()
			n.state[google.String()] = Good
			n.mu.Unlock()
			c.add(CacheTTL + time.Second)
			wait(t, s.OnDNS(gvName, []netip.Addr{google}))
			assert(true)
			c.add(IdleDrop + time.Second)
			s.Tick()
			assert(false)
			wait(t, s.OnDNS(gvName, []netip.Addr{google, provider}))
			assert(true)
			s.Shutdown()
			s.Reapply()
			assert(false)
			n.mu.Lock()
			defer n.mu.Unlock()
			for _, checked := range n.checked {
				if checked == provider {
					t.Fatal("provider cache entered TLS probe/sibling search")
				}
			}
		})
	}
}

func TestProviderFamiliesAndWhitelist(t *testing.T) {
	s, _, r, _ := newSvc()
	s.Resolver = nil
	p4 := netip.MustParseAddr("88.87.65.141")
	p6 := netip.MustParseAddr("2a02:2698:c00:fc00::d")
	wait(t, s.OnDNS(gvName, []netip.Addr{netip.MustParseAddr("74.125.110.38"), p4, p6}))
	if !r.rejectsTCP(p4) || r.rejectsTCP(p6) || r.rejects(p6) {
		t.Fatal("IPv4 evidence incorrectly authorizes IPv6")
	}
	// Whitelist is already exercised by whitelist_test.go; a non-target name
	// must not publish or reject any arbitrary destination even with Google up.
	other := netip.MustParseAddr("188.234.130.206")
	wait(t, s.OnDNS("rr1---sn-test.example.com", []netip.Addr{other}))
	if r.rejectsTCP(other) || r.rejects(other) {
		t.Fatal("non-target rejected")
	}
	s.Whitelist = t.TempDir() + "/whitelist"
	putWhitelist(t, s.Whitelist, "gvt1.com\n")
	wait(t, s.OnDNS("rr1---sn-test.gvt1.com", []netip.Addr{other}))
	if r.rejectsTCP(other) || r.rejects(other) {
		t.Fatal("whitelisted provider rejected")
	}
}

func TestProviderLateGoogleVerdict(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		s, n, r, c := newSvc()
		s.Resolver = nil
		provider := netip.MustParseAddr("88.87.65.141")
		google := netip.MustParseAddr("74.125.110.38")
		wait(t, s.OnDNS(gvName, []netip.Addr{provider}))
		gate := make(chan struct{})
		s.Checker = gatedNet{inner: n, gate: gate}
		done := s.OnDNS(gvName, []netip.Addr{google})
		if shutdown {
			s.Shutdown()
		} else {
			c.add(IdleDrop + time.Second)
			s.Tick()
		}
		close(gate)
		wait(t, done)
		if r.rejects(provider) || r.rejectsTCP(provider) {
			t.Fatal("late Google verdict restored removed provider rejection")
		}
	}
}

func TestProviderStatus(t *testing.T) {
	s, _, r, _ := newSvc()
	s.Resolver = nil
	s.StatusPath = t.TempDir() + "/status.json"
	provider := netip.MustParseAddr("88.87.65.141")
	wait(t, s.OnDNS(gvName, []netip.Addr{provider, netip.MustParseAddr("74.125.110.38")}))
	if !r.rejects(provider) || !r.rejectsTCP(provider) {
		t.Fatal("provider rules missing")
	}
	s.writeStatus()
	var st statusFile
	b, err := os.ReadFile(s.StatusPath)
	if err != nil || json.Unmarshal(b, &st) != nil || st.ProviderRejected != 1 {
		t.Fatalf("provider count: %s %v", b, err)
	}
	s.Shutdown()
	b, err = os.ReadFile(s.StatusPath)
	if err != nil || json.Unmarshal(b, &st) != nil || st.ProviderRejected != 0 {
		t.Fatalf("provider count after shutdown: %s %v", b, err)
	}
}

func TestProviderRuleCommands(t *testing.T) {
	for _, addr := range []string{"88.87.65.141", "2a02:2698:c00:fc00::d"} {
		a := netip.MustParseAddr(addr)
		bin, udp := "iptables", "icmp-port-unreachable"
		if a.Is6() {
			bin, udp = "ip6tables", "icmp6-port-unreachable"
		}
		state := map[string]bool{}
		r := IPTables{Run: func(b string, args ...string) error {
			if b != bin {
				t.Fatalf("wrong family %s", b)
			}
			key := strings.Join(args[4:], " ")
			op := args[3]
			if op == "-C" && !state[key] {
				return fmt.Errorf("absent")
			}
			if op == "-A" {
				state[key] = true
			}
			if op == "-D" {
				delete(state, key)
			}
			return nil
		}}
		for i := 0; i < 2; i++ {
			if err := r.RejectTCP(a); err != nil {
				t.Fatal(err)
			}
			if err := r.RejectQUIC(a); err != nil {
				t.Fatal(err)
			}
		}
		for proto, reject := range map[string]string{"tcp": "tcp-reset", "udp": udp} {
			key := "Z2K_GVSUB_Q -d " + addr + " -p " + proto + " --dport 443 -j REJECT --reject-with " + reject
			if !state[key] {
				t.Fatalf("missing %s", key)
			}
		}
		for i := 0; i < 2; i++ {
			if err := r.AllowTCP(a); err != nil {
				t.Fatal(err)
			}
			if err := r.AllowQUIC(a); err != nil {
				t.Fatal(err)
			}
		}
		if len(state) != 0 {
			t.Fatal("rules left after removal", state)
		}
	}
}
