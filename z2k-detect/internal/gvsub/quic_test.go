package gvsub

import (
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func TestQUICVerdicts(t *testing.T) {
	for _, neighbor := range []bool{false, true} {
		for _, next := range []Verdict{Good, Dead} {
			t.Run(fmt.Sprintf("neighbor=%v/next=%v", neighbor, next), func(t *testing.T) {
				s, n, r, c := newSvc()
				if !neighbor {
					s.Resolver = nil
				}
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if !r.rejects(bad) {
					t.Fatal("Bad не получил отказ QUIC")
				}
				n.mu.Lock()
				n.state[bad.String()] = next
				n.mu.Unlock()
				c.add(SearchPause)
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if r.rejects(bad) {
					t.Fatal("Good/Dead сохранил отказ QUIC")
				}
			})
		}
	}
}

func TestQUICCleanup(t *testing.T) {
	for _, neighbor := range []bool{false, true} {
		for _, shutdown := range []bool{false, true} {
			t.Run(fmt.Sprintf("neighbor=%v/shutdown=%v", neighbor, shutdown), func(t *testing.T) {
				s, _, r, c := newSvc()
				if !neighbor {
					s.Resolver = nil
				}
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if !r.rejects(bad) {
					t.Fatal("Bad не получил отказ QUIC")
				}
				if shutdown {
					s.Shutdown()
				} else {
					c.add(IdleDrop + 1)
					s.Tick()
				}
				if r.rejects(bad) {
					t.Fatal("после уборки остался отказ QUIC")
				}
			})
		}
	}
}

func TestQUICReapply(t *testing.T) {
	for _, neighbor := range []bool{false, true} {
		for _, tick := range []bool{false, true} {
			t.Run(fmt.Sprintf("neighbor=%v/tick=%v", neighbor, tick), func(t *testing.T) {
				s, _, r, _ := newSvc()
				if !neighbor {
					s.Resolver = nil
				}
				wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
				if !r.rejects(bad) {
					t.Fatal("Bad не получил отказ QUIC")
				}
				good := netip.MustParseAddr("74.125.110.38")
				wait(t, s.OnDNS(gvName, []netip.Addr{good}))
				r.mu.Lock()
				r.rejected = nil
				r.recreate = tick
				r.mu.Unlock()
				if tick {
					s.Tick()
				} else {
					s.Reapply()
				}
				if !r.rejects(bad) {
					t.Fatal("отказ QUIC не восстановлен")
				}
				if r.rejects(good) {
					t.Fatal("Reapply запретил QUIC для Good")
				}
				s.Shutdown()
				s.Reapply()
				if r.rejects(bad) {
					t.Fatal("Reapply вернул отказ после Shutdown")
				}
			})
		}
	}
}

func TestQUICNoLateVerdict(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(fmt.Sprint(shutdown), func(t *testing.T) {
			s, n, r, c := newSvc()
			s.Resolver = nil
			wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
			if !r.rejects(bad) {
				t.Fatal("Bad не получил отказ QUIC")
			}
			gate := make(chan struct{})
			s.Checker = gatedNet{inner: n, gate: gate}
			c.add(SearchPause)
			done := s.OnDNS(gvName, []netip.Addr{bad})
			if shutdown {
				s.Shutdown()
			} else {
				c.add(IdleDrop + 1)
				s.Tick()
			}
			close(gate)
			wait(t, done)
			if r.rejects(bad) {
				t.Fatal("запоздалая проверка вернула отказ QUIC")
			}
		})
	}
}

func TestQUICRuleCommands(t *testing.T) {
	for _, tc := range []struct{ addr, bin, reject string }{
		{"74.125.110.70", "iptables", "icmp-port-unreachable"},
		{"2a00:1450::7", "ip6tables", "icmp6-port-unreachable"},
	} {
		t.Run(tc.bin, func(t *testing.T) {
			var calls []string
			exists := false
			r := IPTables{Run: func(bin string, args ...string) error {
				cmd := bin + " " + strings.Join(args, " ")
				calls = append(calls, cmd)
				switch args[3] {
				case "-C":
					if !exists {
						return fmt.Errorf("нет")
					}
				case "-A":
					exists = true
				case "-D":
					exists = false
				}
				return nil
			}}
			q, ok := any(r).(interface {
				RejectQUIC(netip.Addr) error
				AllowQUIC(netip.Addr) error
			})
			if !ok {
				t.Fatal("нет методов управления QUIC")
			}
			a := netip.MustParseAddr(tc.addr)
			for i := 0; i < 2; i++ {
				if err := q.RejectQUIC(a); err != nil {
					t.Fatal(err)
				}
			}
			for i := 0; i < 2; i++ {
				if err := q.AllowQUIC(a); err != nil {
					t.Fatal(err)
				}
			}
			prefix := tc.bin + " -w -t filter "
			suffix := " Z2K_GVSUB_Q -d " + tc.addr + " -p udp --dport 443 -j REJECT --reject-with " + tc.reject
			want := []string{prefix + "-C" + suffix, prefix + "-A" + suffix, prefix + "-C" + suffix, prefix + "-C" + suffix, prefix + "-D" + suffix, prefix + "-C" + suffix}
			if strings.Join(calls, "\n") != strings.Join(want, "\n") {
				t.Fatalf("команды %v, ждали %v", calls, want)
			}
		})
	}
}

func TestQUICFramework(t *testing.T) {
	for _, noV6 := range []bool{false, true} {
		t.Run(fmt.Sprint(noV6), func(t *testing.T) {
			var calls []string
			first := false
			recreate := false
			r := IPTables{NoV6: noV6, Run: func(bin string, args ...string) error {
				calls = append(calls, bin+" "+strings.Join(args, " "))
				if recreate && args[2] == "filter" && args[3] == "-N" {
					return nil
				}
				if args[3] == "-D" || args[3] == "-C" || args[3] == "-N" {
					return fmt.Errorf("нет/есть")
				}
				return nil
			}, Out: func(bin string, args ...string) (string, error) {
				if args[4] == "FORWARD" && first {
					return "-P FORWARD ACCEPT\n-A FORWARD -j Z2K_GVSUB_Q\n", nil
				}
				return "-P " + args[4] + " ACCEPT\n-A " + args[4] + " -j OTHER\n", nil
			}}
			_, err := r.Ensure()
			if err != nil {
				t.Fatal(err)
			}
			all := strings.Join(calls, "\n")
			if !strings.Contains(all, "iptables -w -t filter -I FORWARD 1 -j Z2K_GVSUB_Q") {
				t.Fatal("крючок QUIC не поставлен первым")
			}
			bins := []string{"iptables"}
			if !noV6 {
				bins = append(bins, "ip6tables")
			}
			for _, bin := range bins {
				for _, cmd := range []string{"-N Z2K_GVSUB_Q", "-I FORWARD 1 -j Z2K_GVSUB_Q"} {
					if !strings.Contains(all, bin+" -w -t filter "+cmd) {
						t.Fatalf("нет %s: %s", cmd, all)
					}
				}
			}
			if noV6 && strings.Contains(all, "ip6tables") {
				t.Fatal("Ensure трогает выключенный IPv6")
			}
			first = true
			calls = nil
			r.Ensure()
			if strings.Contains(strings.Join(calls, "\n"), "-t filter -I") {
				t.Fatal("первый крючок переставлен")
			}
			recreate = true
			rec, err := r.Ensure()
			if err != nil || !rec {
				t.Fatalf("пустая filter-цепочка: recreated=%v err=%v", rec, err)
			}
			calls = nil
			r.Teardown()
			all = strings.Join(calls, "\n")
			for _, bin := range bins {
				for _, cmd := range []string{"-D FORWARD -j Z2K_GVSUB_Q", "-F Z2K_GVSUB_Q", "-X Z2K_GVSUB_Q"} {
					if !strings.Contains(all, bin+" -w -t filter "+cmd) {
						t.Fatalf("нет %s: %s", cmd, all)
					}
				}
			}
			if noV6 && strings.Contains(all, "ip6tables") {
				t.Fatal("NoV6 трогает IPv6")
			}
		})
	}
}

// Команды iptables идут вне общей блокировки: под ней служба принимает ответы
// DNS, и восстановление правил по сигналу хука держало бы DNS секундами.
type slowRules struct{ *fakeRules }

func (r slowRules) RejectQUIC(a netip.Addr) error {
	time.Sleep(200 * time.Millisecond)
	return r.fakeRules.RejectQUIC(a)
}

func TestQUICRulesOutsideLock(t *testing.T) {
	s, _, r, _ := newSvc()
	s.Resolver = nil
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	s.Rules = slowRules{r}
	go s.Reapply()
	time.Sleep(20 * time.Millisecond)
	start := time.Now()
	s.OnDNS("rr2---sn-test.googlevideo.com", []netip.Addr{netip.MustParseAddr("74.125.110.38")})
	if d := time.Since(start); d > 100*time.Millisecond {
		t.Fatalf("приём ответа DNS ждал iptables %v", d)
	}
}
