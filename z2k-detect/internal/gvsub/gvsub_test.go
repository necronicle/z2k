package gvsub

import (
	"context"
	"encoding/binary"
	"fmt"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"
)

func name(n string) []byte {
	var b []byte
	for _, l := range strings.Split(n, ".") {
		b = append(b, byte(len(l)))
		b = append(b, l...)
	}
	return append(b, 0)
}

type rr struct {
	typ  uint16
	data []byte
}

// dnsReply: вопрос qname, ответы — первая запись CNAME на имя через сжатие
// (указатель на вопрос), дальше A/AAAA.
func dnsReply(qname string, rrs ...rr) []byte {
	m := make([]byte, 12)
	binary.BigEndian.PutUint16(m[2:4], 0x8180)
	binary.BigEndian.PutUint16(m[4:6], 1)
	binary.BigEndian.PutUint16(m[6:8], uint16(len(rrs)))
	m = append(m, name(qname)...)
	m = append(m, 0, 1, 0, 1)
	for _, r := range rrs {
		m = append(m, 0xc0, 12) // имя записи — указатель на вопрос
		h := make([]byte, 10)
		binary.BigEndian.PutUint16(h[0:2], r.typ)
		binary.BigEndian.PutUint16(h[2:4], 1)
		binary.BigEndian.PutUint32(h[4:8], 300)
		binary.BigEndian.PutUint16(h[8:10], uint16(len(r.data)))
		m = append(m, h...)
		m = append(m, r.data...)
	}
	return m
}

func ipv4udp(payload []byte) []byte {
	p := make([]byte, 28)
	p[0] = 0x45
	p[9] = 17
	return append(p, payload...)
}

func ipv6udp(payload []byte) []byte {
	p := make([]byte, 48)
	p[0] = 0x60
	p[6] = 17
	return append(p, payload...)
}

func TestParseReplyGooglevideo(t *testing.T) {
	msg := dnsReply("rr1---sn-example-a.googlevideo.com",
		rr{5, name("rr1.sn-example-a.googlevideo.com")},
		rr{1, []byte{74, 125, 110, 70}},
		rr{28, netip.MustParseAddr("2a00:1450:4005:2::7").AsSlice()},
	)
	for _, pkt := range [][]byte{ipv4udp(msg), ipv6udp(msg)} {
		a, ok := ParseReply(pkt)
		if !ok {
			t.Fatal("ответ про googlevideo не распознан")
		}
		want := "74.125.110.70 2a00:1450:4005:2::7"
		got := fmt.Sprint(a.Addrs[0], " ", a.Addrs[1])
		if len(a.Addrs) != 2 || got != want {
			t.Fatalf("адреса: %v, ждали %s", a.Addrs, want)
		}
	}
}

func TestParseReplyIgnoresOthers(t *testing.T) {
	cases := map[string][]byte{
		"чужое имя":        ipv4udp(dnsReply("www.youtube.com", rr{1, []byte{1, 2, 3, 4}})),
		"похожее имя":      ipv4udp(dnsReply("notgooglevideo.com", rr{1, []byte{1, 2, 3, 4}})),
		"без адресов":      ipv4udp(dnsReply("rr1---sn-x.googlevideo.com")),
		"обрезанный пакет": ipv4udp(dnsReply("rr1---sn-x.googlevideo.com", rr{1, []byte{1, 2, 3, 4}}))[:40],
		"TCP вместо UDP": func() []byte {
			p := ipv4udp(dnsReply("a.googlevideo.com", rr{1, []byte{1, 2, 3, 4}}))
			p[9] = 6
			return p
		}(),
		"мусор": {0xff, 0, 1},
	}
	for what, pkt := range cases {
		if _, ok := ParseReply(pkt); ok {
			t.Errorf("%s: принято за ответ про googlevideo", what)
		}
	}
	// Петля указателей сжатия не должна вешать разбор.
	loop := dnsReply("a.googlevideo.com", rr{1, []byte{1, 2, 3, 4}})
	loop = append(loop[:12], 0xc0, 12)
	if _, ok := parseDNS(loop); ok {
		t.Error("петля сжатия принята")
	}
}

// --- имена кэшей -----------------------------------------------------------

func TestParseCluster(t *testing.T) {
	for name, want := range map[string]string{
		"rr1---sn-example-b.googlevideo.com":   "sn-example-b/1",
		"rr17.sn-example-b.googlevideo.com.":   "sn-example-b/17",
		"RR3---SN-EXAMPLE-C.googlevideo.com":   "sn-example-c/3",
		"redirector.googlevideo.com":           "",
		"manifest.googlevideo.com":             "",
		"rr1---sn-example-b.googlevideo.com.x": "",
	} {
		c, n, ok := ParseCluster(name)
		got := ""
		if ok {
			got = fmt.Sprintf("%s/%d", c, n)
		}
		if got != want {
			t.Errorf("%s: %q, ждали %q", name, got, want)
		}
	}
}

type fakeNet struct {
	mu      sync.Mutex
	state   map[string]Verdict
	calls   int
	checked []netip.Addr
}

func (f *fakeNet) Check(_ context.Context, a netip.Addr) Verdict {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.checked = append(f.checked, a)
	if v, ok := f.state[a.String()]; ok {
		return v
	}
	return Dead
}

// The service only manages the DNS interception lifecycle.
type fakeRules struct{}

func (r *fakeRules) Ensure() (bool, error) { return false, nil }
func (r *fakeRules) Teardown()             {}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }

const gvName = "rr1---sn-test.googlevideo.com"

var bad = netip.MustParseAddr("74.125.110.70")

func newSvc() (*Service, *fakeNet, *fakeRules, *clock) {
	n := &fakeNet{state: map[string]Verdict{"74.125.110.70": Bad, "74.125.110.38": Good}}
	r := &fakeRules{}
	c := &clock{t: time.Date(2026, 11, 9, 20, 0, 0, 0, time.UTC)}
	return &Service{Checker: n, Rules: r, Now: c.now}, n, r, c
}
func wait(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatal("ответ DNS так и не отпущен")
	}
}
