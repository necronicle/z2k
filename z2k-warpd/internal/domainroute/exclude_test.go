package domainroute

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Исключения действуют на всю сеть: адрес домена-исключения, который спросил
// любой клиент, идёт мимо WARP для всех. Поэтому в кэше исключений одна пара на
// адрес, а не на (клиент, адрес): иначе удаление пары одного клиента вынуло бы
// адрес из общего набора, пока у другого клиента он ещё действует.
func TestExclusionCacheIsNetworkWide(t *testing.T) {
	r, _ := ParseRules([]byte("v1\ngosuslugi.ru\n"))
	c := NewExclusionCache(r)
	now := time.Unix(100, 0)
	ip := netip.MustParseAddr("213.59.254.7")
	a := netip.MustParseAddr("192.168.1.10")
	b := netip.MustParseAddr("192.168.1.11")
	if got := c.Observe(a, "gosuslugi.ru", []Answer{{ip, 20 * time.Second}}, now); len(got) != 1 || got[0].Dest != ip {
		t.Fatalf("first exclusion: %+v", got)
	}
	// Второй клиент спросил то же имя: пара та же, срок — по свежему ответу.
	if got := c.Observe(b, "gosuslugi.ru", []Answer{{ip, 10 * time.Second}}, now); len(got) != 1 || got[0].Client != networkWide {
		t.Fatalf("second client must update the shared entry: %+v", got)
	}
	if c.Len() != 1 {
		t.Fatalf("want one network-wide pair, got %d", c.Len())
	}
	if got := c.Observe(netip.MustParseAddr("8.8.8.8"), "gosuslugi.ru", []Answer{{ip, time.Minute}}, now); len(got) != 0 {
		t.Fatalf("non-LAN receiver must be ignored: %+v", got)
	}
}

func TestExclusionCacheSnapshotRoundTrip(t *testing.T) {
	r, _ := ParseRules([]byte("v1\ngosuslugi.ru\n"))
	c := NewExclusionCache(r)
	now := time.Unix(100, 0)
	ip := netip.MustParseAddr("213.59.254.7")
	c.Observe(netip.MustParseAddr("192.168.1.10"), "gosuslugi.ru", []Answer{{ip, time.Minute}}, now)
	path := filepath.Join(t.TempDir(), "excl.v1")
	if err := c.Save(path); err != nil {
		t.Fatal(err)
	}
	d := NewExclusionCache(r)
	if err := d.Load(path, now); err != nil {
		t.Fatal(err)
	}
	if all := d.All(now); len(all) != 1 || all[0].Dest != ip {
		t.Fatalf("snapshot lost exclusion: %+v", all)
	}
}

func TestObserverFeedsExclusionsSeparately(t *testing.T) {
	inc, _ := ParseRules([]byte("v1\nselected.example\n"))
	exc, _ := ParseRules([]byte("v1\ngosuslugi.ru\n"))
	o := NewObserver(inc)
	o.ReplaceExclusions(exc, time.Unix(99, 0))
	// reply() задаёт вопрос про selected.example, здесь нужен свой.
	m := dnsmessage.Message{Header: dnsmessage.Header{Response: true},
		Questions: []dnsmessage.Question{{Name: dnsName("gosuslugi.ru"), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
		Answers:   []dnsmessage.Resource{aRecord("gosuslugi.ru", [4]byte{213, 59, 254, 7}, 30)}}
	dns, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	frame := ipv4Packet(17, [4]byte{192, 168, 1, 1}, [4]byte{192, 168, 1, 10}, udpDNS(dns))
	include, exclude := o.ProcessAll(frame, time.Unix(100, 0))
	if len(include) != 0 {
		t.Fatalf("excluded domain must not route into WARP: %+v", include)
	}
	if len(exclude) != 1 || exclude[0].Dest != netip.MustParseAddr("213.59.254.7") {
		t.Fatalf("excluded domain address not learned: %+v", exclude)
	}
}

func TestExclSetWritesSharedSetWithTimeoutAndNoRules(t *testing.T) {
	s, log := pairSetStubs(t, "")
	x := ExclSet{Binary: s.Binary}
	now := time.Unix(100, 0)
	dest := netip.MustParseAddr("213.59.254.7")
	if err := x.Apply([]Change{{Dest: dest, Expiry: now.Add(20 * time.Second)}}, now); err != nil {
		t.Fatal(err)
	}
	if err := x.Apply([]Change{{Dest: dest, Delete: true}}, now); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	got := string(b)
	for _, want := range []string{
		"ipset create z2k_warp_xdns hash:ip family inet timeout 3600 maxelem 8192 -exist",
		"ipset add z2k_warp_xdns 213.59.254.7 timeout 20 -exist",
		"ipset del z2k_warp_xdns 213.59.254.7 -exist",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "iptables") {
		t.Fatalf("exclusions are matched by a fixed shell rule, not per-client rules:\n%s", got)
	}
}
