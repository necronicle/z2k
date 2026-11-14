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

// Сайты с IPv6 устройство открывает по IPv6 (замер 14.11: Mac в сети с IPv6
// шёл к домену из списка по IPv6 мимо WARP). Ответы AAAA обязаны учить те же
// наборы, что и A, — в своём семействе.

func aaaaRecord(name string, ip string, ttl uint32) dnsmessage.Resource {
	return dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsName(name), Class: dnsmessage.ClassINET, TTL: ttl},
		Body: &dnsmessage.AAAAResource{AAAA: netip.MustParseAddr(ip).As16()}}
}

func answerAAAA(t *testing.T, name string, answers ...dnsmessage.Resource) []byte {
	t.Helper()
	m := dnsmessage.Message{Header: dnsmessage.Header{Response: true},
		Questions: []dnsmessage.Question{{Name: dnsName(name), Type: dnsmessage.TypeAAAA, Class: dnsmessage.ClassINET}},
		Answers:   answers}
	b, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParseReplyAAAAFollowsCNAME(t *testing.T) {
	b := answerAAAA(t, "selected.example",
		cnameRecord("selected.example", "cdn.example", 20),
		aaaaRecord("cdn.example", "2606:4700::6810:b9f1", 40),
		aaaaRecord("cdn.example", "fd00::1", 40))
	name, got, err := ParseReply(b, TransportUDP)
	if err != nil {
		t.Fatal(err)
	}
	if name != "selected.example" || len(got) != 1 || got[0].IP != netip.MustParseAddr("2606:4700::6810:b9f1") || got[0].TTL != 20*time.Second {
		t.Fatalf("name=%q answers=%+v", name, got)
	}
}

func TestEligibleIPv6Destinations(t *testing.T) {
	for addr, want := range map[string]bool{
		"2606:4700::6810:b9f1": true, "2a00:1450:4010::64": true,
		"fd00::1": false, "fe80::1": false, "ff02::1": false, "::1": false, "::": false,
		"2001:db8::1": false, "2001:0:4136::1": false, "2002:c000:204::1": false,
		"2001:2::c633:640b": false, "::ffff:8.8.8.8": false, "64:ff9b::808:808": false,
	} {
		if got := EligibleDestination(netip.MustParseAddr(addr)); got != want {
			t.Errorf("%s: eligible=%v, want %v", addr, got, want)
		}
	}
}

func TestObserverLearnsIPv6RoutesAndExclusions(t *testing.T) {
	r, _ := ParseRules([]byte("v1\nselected.example\n"))
	excl, _ := ParseRules([]byte("v1\nbank.example\n"))
	o := NewObserver(r)
	o.ReplaceExclusions(excl, time.Unix(100, 0))
	o.SetLocalAddresses([]netip.Addr{netip.MustParseAddr("2a05:d014:1:2::fa91")})
	now := time.Unix(100, 0)
	lan := netip.MustParseAddr("192.168.1.20")
	// IPv4-спросивший, вопрос AAAA: маршрут IPv6-адреса на устройство.
	dns := answerAAAA(t, "selected.example", aaaaRecord("selected.example", "2606:4700::6810:b9f1", 60),
		aaaaRecord("selected.example", "2a05:d014:1:2::fa91", 60))
	include, _ := o.ProcessAll(ipv4Packet(17, [4]byte{192, 168, 1, 1}, lan.As4(), udpDNS(dns)), now)
	if len(include) != 1 || include[0].Client != lan || include[0].Dest != netip.MustParseAddr("2606:4700::6810:b9f1") {
		t.Fatalf("IPv6 route not learned (router's own address must be skipped): %+v", include)
	}
	// Исключение по AAAA — на всю сеть.
	dns = answerAAAA(t, "bank.example", aaaaRecord("bank.example", "2a00:1450:4010::64", 60))
	_, exclude := o.ProcessAll(ipv6Packet(17, router6, mac6, udpDNS(dns)), now)
	if len(exclude) != 1 || exclude[0].Client != networkWide || exclude[0].Dest != netip.MustParseAddr("2a00:1450:4010::64") {
		t.Fatalf("IPv6 exclusion not learned: %+v", exclude)
	}
}

// Стабы ipset/iptables/ip6tables: команды в журнал, -S ip6tables отдаёт
// $Z2K_IP6_RULES.
func pairSet6Stubs(t *testing.T) (PairSet, string) {
	t.Helper()
	s, log := pairSetStubs(t, "")
	ip6 := filepath.Join(filepath.Dir(s.Binary), "ip6tables")
	script := "#!/bin/sh\necho \"ip6tables $*\" >> \"$Z2K_PAIR_LOG\"\n" +
		"case \"$*\" in *' -S '*) printf '%s\\n' \"$Z2K_IP6_RULES\"; exit 0 ;; *' -C '*) exit 1 ;; esac\n"
	if err := os.WriteFile(ip6, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	s.IP6TablesBinary = ip6
	return s, log
}

func TestPairSetIPv6MarksDeviceByMAC(t *testing.T) {
	s, log := pairSet6Stubs(t)
	client := netip.MustParseAddr("192.168.1.20")
	mac := ""
	s.MACOf = func(c netip.Addr) (string, bool) { return mac, mac != "" && c == client }
	t.Setenv("Z2K_IP6_RULES", "-A PREROUTING -m mac --mac-source AA:AA:AA:AA:AA:AA -m set --match-set z2kd6_192.168.1.20 dst -j Z2K_WARP")
	now := time.Unix(100, 0)
	ch := []Change{{Client: client, Dest: netip.MustParseAddr("2606:4700::6810:b9f1"), Expiry: now.Add(30 * time.Second)}}
	// MAC ещё неизвестен: адрес записан, правила нет, ошибки нет.
	if err := s.Apply(ch, now); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	got := string(b)
	for _, want := range []string{
		"ipset create z2kd6_192.168.1.20 hash:ip family inet6 timeout 3600 maxelem 8192 -exist",
		"ipset add z2kd6_192.168.1.20 2606:4700::6810:b9f1 timeout 30 -exist",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "ip6tables -w -t mangle -A") || strings.Contains(got, "iptables -w") {
		t.Fatalf("mark without a known MAC or in iptables:\n%s", got)
	}
	// MAC известен: старое правило (другой MAC) снимается, ставится новое.
	mac = "02:00:00:00:00:14"
	if err := s.Apply(ch, now); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(log)
	got = string(b)
	for _, want := range []string{
		"ip6tables -w -t mangle -D PREROUTING -m mac --mac-source AA:AA:AA:AA:AA:AA -m set --match-set z2kd6_192.168.1.20 dst -j Z2K_WARP",
		"ip6tables -w -t mangle -A PREROUTING -m mac --mac-source 02:00:00:00:00:14 -m set --match-set z2kd6_192.168.1.20 dst -j Z2K_WARP",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in:\n%s", want, got)
		}
	}
	// Удаление последнего адреса: правила и набор уходят.
	if err := s.Apply([]Change{{Client: client, Dest: ch[0].Dest, Delete: true}}, now); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(log)
	if !strings.Contains(string(b), "ipset destroy z2kd6_192.168.1.20") {
		t.Fatalf("empty IPv6 set not destroyed:\n%s", b)
	}
}

func TestPairSetReplaceAllDropsStaleIPv6Sets(t *testing.T) {
	s, log := pairSet6Stubs(t)
	t.Setenv("Z2K_STALE_SET", "z2kd6_192.168.1.99")
	t.Setenv("Z2K_IP6_RULES", "-A PREROUTING -m mac --mac-source AA:AA:AA:AA:AA:AA -m set --match-set z2kd6_192.168.1.99 dst -j Z2K_WARP")
	if err := s.ReplaceAll(nil, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	for _, want := range []string{"ip6tables -w -t mangle -D PREROUTING -m mac --mac-source AA:AA:AA:AA:AA:AA -m set --match-set z2kd6_192.168.1.99 dst -j Z2K_WARP", "ipset destroy z2kd6_192.168.1.99"} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("missing %q in:\n%s", want, b)
		}
	}
}

func TestExclSetWritesIPv6ToItsOwnSet(t *testing.T) {
	s, log := pairSetStubs(t, "")
	x := ExclSet{Binary: s.Binary}
	now := time.Unix(100, 0)
	if err := x.Apply([]Change{
		{Dest: netip.MustParseAddr("2a00:1450:4010::64"), Expiry: now.Add(20 * time.Second)},
		{Dest: netip.MustParseAddr("213.59.254.7"), Expiry: now.Add(20 * time.Second)},
	}, now); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	for _, want := range []string{
		"ipset create z2k_warp_xdns6 hash:ip family inet6 timeout 3600 maxelem 8192 -exist",
		"ipset add z2k_warp_xdns6 2a00:1450:4010::64 timeout 20 -exist",
		"ipset add z2k_warp_xdns 213.59.254.7 timeout 20 -exist",
	} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("missing %q in:\n%s", want, b)
		}
	}
}
