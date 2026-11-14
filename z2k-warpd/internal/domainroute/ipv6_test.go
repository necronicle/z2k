package domainroute

import (
	"encoding/binary"
	"net/netip"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Замер 14.11 на Mac в сети с IPv6: все запросы DNS, включая A, идут к
// fe80::…:53 роутера. Такие ответы обязаны учить и исключения, и маршруты.
var (
	router6 = netip.MustParseAddr("fe80::1")
	mac6    = netip.MustParseAddr("fe80::2")
)

// answerA — ответ на вопрос A о name с одним адресом.
func answerA(t *testing.T, name string, ip [4]byte) []byte {
	t.Helper()
	m := dnsmessage.Message{Header: dnsmessage.Header{Response: true},
		Questions: []dnsmessage.Question{{Name: dnsName(name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
		Answers:   []dnsmessage.Resource{aRecord(name, ip, 30)}}
	b, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func ipv6Packet(proto byte, src, dst netip.Addr, transport []byte) []byte {
	b := make([]byte, 40+len(transport))
	b[0] = 0x60
	binary.BigEndian.PutUint16(b[4:6], uint16(len(transport)))
	b[6] = proto
	b[7] = 64
	s, d := src.As16(), dst.As16()
	copy(b[8:24], s[:])
	copy(b[24:40], d[:])
	copy(b[40:], transport)
	return b
}

func TestPacketDecoderAcceptsIPv6ReplyToLANClient(t *testing.T) {
	d := NewPacketDecoder()
	dns := answerA(t, "2ip.io", [4]byte{188, 40, 167, 81})
	client, got, transport := d.Push(ipv6Packet(17, router6, mac6, udpDNS(dns)), time.Unix(100, 0))
	if client != mac6 || transport != TransportUDP || string(got) != string(dns) {
		t.Fatalf("client=%v transport=%v bytes=%d", client, transport, len(got))
	}
	framed := make([]byte, 2+len(dns))
	binary.BigEndian.PutUint16(framed, uint16(len(dns)))
	copy(framed[2:], dns)
	if _, got, _ := d.Push(ipv6Packet(6, router6, mac6, tcpDNS(7, framed[:5])), time.Unix(100, 0)); got != nil {
		t.Fatal("partial TCP frame emitted")
	}
	client, got, transport = d.Push(ipv6Packet(6, router6, mac6, tcpDNS(12, framed[5:])), time.Unix(100, 0))
	if client != mac6 || transport != TransportTCP || string(got) != string(framed) {
		t.Fatalf("TCP over IPv6: client=%v transport=%v bytes=%d", client, transport, len(got))
	}
}

func TestPacketDecoderRejectsMalformedOrNonLANIPv6(t *testing.T) {
	dns := answerA(t, "2ip.io", [4]byte{188, 40, 167, 81})
	for name, frame := range map[string][]byte{
		"multicast receiver": ipv6Packet(17, router6, netip.MustParseAddr("ff02::1"), udpDNS(dns)),
		"loopback receiver":  ipv6Packet(17, router6, netip.IPv6Loopback(), udpDNS(dns)),
		"fragment header":    ipv6Packet(44, router6, mac6, udpDNS(dns)),
		"length mismatch":    append(ipv6Packet(17, router6, mac6, udpDNS(dns)), 0),
	} {
		if _, got, _ := NewPacketDecoder().Push(frame, time.Unix(100, 0)); got != nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestObserverLearnsExclusionFromIPv6Reply(t *testing.T) {
	none, _ := ParseRules([]byte("v1\n"))
	excl, _ := ParseRules([]byte("v1\n2ip.io\n"))
	o := NewObserver(none)
	o.ReplaceExclusions(excl, time.Unix(100, 0))
	dns := answerA(t, "2ip.io", [4]byte{188, 40, 167, 81})
	_, exclude := o.ProcessAll(ipv6Packet(17, router6, mac6, udpDNS(dns)), time.Unix(100, 0))
	if len(exclude) != 1 || exclude[0].Dest != netip.MustParseAddr("188.40.167.81") || exclude[0].Client != networkWide {
		t.Fatalf("exclusion not learned from IPv6 reply: %+v", exclude)
	}
}

func TestObserverRoutesIPv6AskerByItsIPv4(t *testing.T) {
	r, _ := ParseRules([]byte("v1\nselected.example\n"))
	o := NewObserver(r)
	reads := 0
	o.neigh.read = func() ([]byte, []byte) {
		reads++
		return []byte("fe80::2 dev br0 lladdr 02:00:00:00:00:A9 REACHABLE\n" +
				"fe80::dead dev br0  used 0/0/0 probes 3 FAILED\n"),
			[]byte("192.168.1.20 dev br0 lladdr 02:00:00:00:00:a9 ref 1 used 0/0/0 probes 1 REACHABLE\n")
	}
	dns := answerA(t, "selected.example", [4]byte{8, 8, 8, 8})
	now := time.Unix(100, 0)
	include, _ := o.ProcessAll(ipv6Packet(17, router6, mac6, udpDNS(dns)), now)
	if len(include) != 1 || include[0].Client != netip.MustParseAddr("192.168.1.20") || include[0].Dest != netip.MustParseAddr("8.8.8.8") {
		t.Fatalf("IPv6 asker not routed by its IPv4: %+v", include)
	}
	// Неизвестное устройство: маршрута нет, счётчик растёт, таблица не
	// перечитывается на каждом ответе.
	stranger := netip.MustParseAddr("fe80::dead")
	for i := 0; i < 3; i++ {
		if got, _ := o.ProcessAll(ipv6Packet(17, router6, stranger, udpDNS(dns)), now.Add(time.Second)); len(got) != 0 {
			t.Fatalf("unmapped asker routed: %+v", got)
		}
	}
	if s := o.status(); s.Unmapped != 3 {
		t.Fatalf("unmapped = %d", s.Unmapped)
	}
	if reads != 1 {
		t.Fatalf("neighbour table read %d times within retry window", reads)
	}
	// Не из списков — соседей не спрашиваем вовсе.
	other := answerA(t, "other.example", [4]byte{9, 9, 9, 9})
	o.ProcessAll(ipv6Packet(17, router6, stranger, udpDNS(other)), now.Add(5*time.Second))
	if reads != 1 {
		t.Fatalf("neighbour table read for an unlisted name")
	}
}

func TestMapNeighborsKeepsOnlyLANIPv4(t *testing.T) {
	m, macs := mapNeighbors(
		[]byte("2001:db8:5d0b::b286 lladdr 02:00:00:00:00:cf ref 1 used 0/0/0 probes 1 REACHABLE\n"+
			"fe80::1 dev br0 lladdr aa:aa:aa:aa:aa:aa STALE\n"),
		[]byte("192.168.1.79 lladdr 02:00:00:00:00:cf REACHABLE\n"+
			"8.8.8.8 dev eth3 lladdr aa:aa:aa:aa:aa:aa STALE\n"))
	if got := m[netip.MustParseAddr("2001:db8:5d0b::b286")]; got != netip.MustParseAddr("192.168.1.79") {
		t.Fatalf("global IPv6 not mapped: %v", got)
	}
	if _, ok := m[netip.MustParseAddr("fe80::1")]; ok {
		t.Fatal("public IPv4 accepted as a LAN device")
	}
	if macs[netip.MustParseAddr("192.168.1.79")] != "02:00:00:00:00:cf" || len(macs) != 1 {
		t.Fatalf("MAC of LAN IPv4: %v", macs)
	}
}
