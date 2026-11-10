package gvsub

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// --- ответ DNS ---------------------------------------------------------------

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
	msg := dnsReply("rr1---sn-i5heen7z.googlevideo.com",
		rr{5, name("rr1.sn-i5heen7z.googlevideo.com")},
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

// --- conntrack ----------------------------------------------------------------

const ctSample = `ipv4     2 tcp      6 115 TIME_WAIT src=192.168.1.117 dst=74.125.110.70 sport=55387 dport=443 packets=11 bytes=2987 src=74.125.110.70 dst=88.87.93.11 sport=443 dport=55387 packets=1 bytes=60 [ASSURED] mark=0
ipv4     2 tcp      6 110 ESTABLISHED src=192.168.1.117 dst=74.125.110.38 sport=55472 dport=443 packets=22 bytes=4658 src=74.125.110.38 dst=88.87.93.11 sport=443 dport=55472 packets=12 bytes=5542 [ASSURED] mark=0
ipv4     2 tcp      6 20 SYN_SENT src=192.168.1.117 dst=74.125.13.129 sport=55400 dport=443 packets=2 bytes=120 [UNREPLIED] src=74.125.13.129 dst=88.87.93.11 sport=443 dport=55400 packets=0 bytes=0 mark=0
ipv4     2 udp      17 20 src=192.168.1.117 dst=74.125.13.70 sport=5000 dport=443 packets=9 bytes=9000 src=74.125.13.70 dst=88.87.93.11 sport=443 dport=5000 packets=0 bytes=0 mark=0
ipv6     10 tcp      6 100 ESTABLISHED src=2a03::1 dst=2a00:1450:4005:2::7 sport=50000 dport=443 packets=6 bytes=900 src=2a00:1450:4005:2::7 dst=2a03::1 sport=443 dport=50000 packets=1 bytes=80 [ASSURED] mark=0
ipv6     10 tcp      6 119 TIME_WAIT src=2a03::1 dst=2a00:1450:4001:37::7 sport=53644 dport=443 packets=17 bytes=3827 src=2a00:1450:4001:37::7 dst=2a03::1 sport=443 dport=53644 packets=6 bytes=440 [ASSURED] mark=0
ipv6     10 tcp      6 58 TIME_WAIT src=2a03::1 dst=2a00:1450:4001:37::8 sport=56060 dport=443 packets=11 bytes=1147 src=2a00:1450:4001:37::8 dst=2a03::1 sport=443 dport=56060 packets=8 bytes=5572 [ASSURED] mark=0
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.117 dst=1.1.1.1 sport=50001 dport=80 packets=6 bytes=900 src=1.1.1.1 dst=88.87.93.11 sport=80 dport=50001 packets=1 bytes=60 mark=0
`

func TestParseConntrack(t *testing.T) {
	fl := ParseConntrack(strings.NewReader(ctSample))
	var all, stuck []string
	for _, f := range fl {
		all = append(all, f.Dst.String())
		if f.Stuck {
			stuck = append(stuck, f.Dst.String())
		}
	}
	// Подтверждения кусков ClientHello (6 пустых пакетов) — тоже без ответа.
	want := "74.125.110.70 2a00:1450:4005:2::7 2a00:1450:4001:37::7"
	if strings.Join(stuck, " ") != want {
		t.Fatalf("зависшие %v, ждали %s", stuck, want)
	}
	wantAll := "74.125.110.70 74.125.110.38 74.125.13.129 74.125.13.70 2a00:1450:4005:2::7 2a00:1450:4001:37::7 2a00:1450:4001:37::8"
	if strings.Join(all, " ") != wantAll {
		t.Fatalf("в ходу %v, ждали %s", all, wantAll)
	}
}

// --- соседи и правила -----------------------------------------------------------

func TestParseCluster(t *testing.T) {
	for name, want := range map[string]string{
		"rr1---sn-n8v7kn7z.googlevideo.com":   "sn-n8v7kn7z/1",
		"rr17.sn-n8v7kn7z.googlevideo.com.":   "sn-n8v7kn7z/17",
		"RR3---SN-OJ5HN5-5A.googlevideo.com":  "sn-oj5hn5-5a/3",
		"redirector.googlevideo.com":          "",
		"manifest.googlevideo.com":            "",
		"rr1---sn-n8v7kn7z.googlevideo.com.x": "",
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

func TestRulesShape(t *testing.T) {
	var calls []string
	r := IPTables{Run: func(bin string, args ...string) error {
		if args[3] == "-C" {
			return fmt.Errorf("нет такого правила")
		}
		calls = append(calls, bin+" "+strings.Join(args, " "))
		return nil
	}}
	_ = r.Add(netip.MustParseAddr("74.125.110.70"), netip.MustParseAddr("74.125.110.38"))
	all := strings.Join(calls, "\n")
	for _, must := range []string{
		"iptables -w -t nat -A Z2K_GVSUB -d 74.125.110.70 -p tcp --dport 443 -j DNAT --to-destination 74.125.110.38",
		"iptables -w -t nat -A Z2K_GVSUB -d 74.125.110.70 -p udp --dport 443 -j DNAT --to-destination 74.125.110.38",
		// Метка — только новым соединениям, очередь — только помеченным:
		// соединение, открытое до подмены, остаётся у пробы z2k на выходе.
		"-t mangle -A Z2K_GVSUB -d 74.125.110.70 -p tcp --dport 443 -m conntrack --ctstate NEW ! --ctstatus CONFIRMED -j CONNMARK --or-mark 0x20000000",
		"-p tcp --dport 443 -m connmark --mark 0x20000000/0x20000000 -m connbytes --connbytes 0:20 --connbytes-mode packets --connbytes-dir original -j NFQUEUE --queue-num 200 --queue-bypass",
	} {
		if !strings.Contains(all, must) {
			t.Errorf("нет правила: %s\n%s", must, all)
		}
	}
	// Метка исключения обязана стоять до очереди: NFQUEUE завершает цепочку.
	if strings.Index(all, "-p tcp --dport 443 -m conntrack") > strings.Index(all, "-p tcp --dport 443 -m connmark") {
		t.Error("CONNMARK после NFQUEUE — метка не встанет")
	}
	// DNAT — последним: новое соединение между командами не должно получить
	// переадресацию без обработки z2k до неё.
	if strings.LastIndex(all, "-t mangle") > strings.Index(all, "-t nat") {
		t.Error("DNAT ставится раньше строк mangle")
	}
	calls = nil
	_ = r.Add(netip.MustParseAddr("2a00:1450:4005:2::7"), netip.MustParseAddr("2a00:1450:4005:2::6"))
	if !strings.HasPrefix(calls[0], "ip6tables ") {
		t.Errorf("IPv6 не через ip6tables: %s", calls[0])
	}
	// Сбой посреди установки — откат всего, что успели поставить.
	calls = nil
	n := 0
	r.Run = func(bin string, args ...string) error {
		if args[3] == "-C" {
			return fmt.Errorf("нет такого правила")
		}
		calls = append(calls, strings.Join(args, " "))
		n++
		if n == 3 {
			return fmt.Errorf("сбой")
		}
		return nil
	}
	if err := r.Add(netip.MustParseAddr("74.125.110.70"), netip.MustParseAddr("74.125.110.38")); err == nil {
		t.Fatal("сбой не вернулся")
	}
	dels := 0
	for _, c := range calls {
		if strings.Contains(c, " -D ") {
			dels++
		}
	}
	if dels != 6 {
		t.Errorf("откат: %d удалений, ждали 6", dels)
	}
}

// Повторная установка не дублирует строки: стоящее правило пропускается.
func TestRulesAddIdempotent(t *testing.T) {
	present := map[string]bool{}
	adds := 0
	r := IPTables{Run: func(bin string, args ...string) error {
		key := strings.Join(append([]string{args[2]}, args[5:]...), " ")
		switch args[3] {
		case "-C":
			if !present[key] {
				return fmt.Errorf("нет")
			}
		case "-A":
			present[key] = true
			adds++
		}
		return nil
	}}
	b, g := netip.MustParseAddr("74.125.110.70"), netip.MustParseAddr("74.125.110.38")
	_ = r.Add(b, g)
	first := adds
	_ = r.Add(b, g)
	if first != 6 || adds != first {
		t.Fatalf("строк добавлено %d, после повтора %d — ждали 6 и 6", first, adds)
	}
}

// --- служба ------------------------------------------------------------------------

type fakeNet struct {
	mu      sync.Mutex
	state   map[string]Verdict
	calls   int
	checked []netip.Addr
}

func (f *fakeNet) set(a string, v Verdict) { f.mu.Lock(); f.state[a] = v; f.mu.Unlock() }
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

type fakeRules struct {
	mu        sync.Mutex
	set       map[string]string
	rejected  map[netip.Addr]bool
	adds      int
	recreate  bool // следующий Ensure сообщит, что цепочки пересозданы пустыми
	ensures   int
	teardowns int
}

func (r *fakeRules) Ensure() (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ensures++
	if r.recreate {
		r.recreate = false
		r.set = map[string]string{} // цепочки пустые
		r.rejected = map[netip.Addr]bool{}
		return true, nil
	}
	return false, nil
}
func (r *fakeRules) Teardown() { r.mu.Lock(); r.teardowns++; r.mu.Unlock() }

func (r *fakeRules) Add(b, g netip.Addr) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.set[b.String()] = g.String()
	r.adds++
	return nil
}
func (r *fakeRules) Del(b, g netip.Addr) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.set[b.String()] == g.String() {
		delete(r.set, b.String())
	}
	return nil
}

func (r *fakeRules) RejectQUIC(a netip.Addr) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.rejected == nil {
		r.rejected = map[netip.Addr]bool{}
	}
	r.rejected[a] = true
	return nil
}
func (r *fakeRules) AllowQUIC(a netip.Addr) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.rejected, a)
	return nil
}
func (r *fakeRules) rejects(a netip.Addr) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.rejected[a]
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

// Кластер sn-test: машины .70 (плохая), .71 (плохая), .69 (не в работе),
// .38/.39/.102 (рабочие). .200 рабочий, но из ЧУЖОГО кластера — брать нельзя.
const gvName = "rr1---sn-test.googlevideo.com"

type fakeResolver struct{ calls int }

func (r *fakeResolver) Siblings(_ context.Context, cluster string, v6 bool) []netip.Addr {
	r.calls++
	if cluster != "sn-test" || v6 {
		return nil
	}
	var out []netip.Addr
	for _, a := range []string{"74.125.110.70", "74.125.110.71", "74.125.110.69", "74.125.110.38", "74.125.110.39", "74.125.110.102"} {
		out = append(out, netip.MustParseAddr(a))
	}
	return out
}

func newSvc() (*Service, *fakeNet, *fakeRules, *clock) {
	n := &fakeNet{state: map[string]Verdict{
		"74.125.110.70": Bad, "74.125.110.71": Bad, "74.125.110.69": Dead,
		"74.125.110.38": Good, "74.125.110.39": Good, "74.125.110.102": Good,
		"74.125.110.200": Good,
	}}
	r := &fakeRules{set: map[string]string{}}
	c := &clock{t: time.Date(2026, 11, 9, 20, 0, 0, 0, time.UTC)}
	return &Service{Checker: n, Rules: r, Resolver: &fakeResolver{}, Now: c.now}, n, r, c
}

func wait(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatal("ответ DNS так и не отпущен")
	}
}

var bad = netip.MustParseAddr("74.125.110.70")

var goodSet = map[string]bool{"74.125.110.38": true, "74.125.110.39": true, "74.125.110.102": true}

// slowNet: неработающие кандидаты держат проверку до таймаута, как в сети.
type slowNet struct{ fakeNet }

func (f *slowNet) Check(ctx context.Context, a netip.Addr) Verdict {
	v := f.fakeNet.Check(ctx, a)
	if v != Good && a != bad {
		select {
		case <-time.After(500 * time.Millisecond):
		case <-ctx.Done():
		}
	}
	return v
}

// Ответ DNS не ждёт медленных кандидатов: подмена ставится по первому
// ответившему соседу (стенд 09.11: ожидание всего окна держало DNS 2–3 с).
func TestDNSNotHeldBySlowCandidates(t *testing.T) {
	s, n, r, _ := newSvc()
	s.Checker = &slowNet{fakeNet{state: n.state}}
	t0 := time.Now()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	if d := time.Since(t0); d > 300*time.Millisecond {
		t.Fatalf("ответ DNS держался %v — ждали всё окно кандидатов", d)
	}
	if !goodSet[r.set["74.125.110.70"]] {
		t.Fatalf("подмена %v", r.set)
	}
}

func TestFirstConnectionGoesToNeighbor(t *testing.T) {
	s, _, r, _ := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	// Ответ DNS отпущен только после подмены — первое соединение уже на соседа.
	if !goodSet[r.set["74.125.110.70"]] {
		t.Fatalf("подмена %v, ждали одного из рабочих соседей", r.set)
	}
}

func TestFreshVerdictDoesNotHold(t *testing.T) {
	s, n, _, c := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{netip.MustParseAddr("74.125.110.38")}))
	before := n.calls
	c.add(CacheTTL / 2)
	select {
	case <-s.OnDNS(gvName, []netip.Addr{netip.MustParseAddr("74.125.110.38")}):
	case <-time.After(100 * time.Millisecond):
		t.Fatal("свежий вердикт придержал ответ")
	}
	if n.calls != before {
		t.Fatal("свежий адрес проверен повторно")
	}
	c.add(CacheTTL)
	wait(t, s.OnDNS(gvName, []netip.Addr{netip.MustParseAddr("74.125.110.38")}))
	if n.calls == before {
		t.Fatal("после истечения вердикта проверки не было")
	}
}

func TestBadBecomesGoodUnmaps(t *testing.T) {
	s, n, r, _ := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	n.set("74.125.110.70", Good)
	s.Tick()
	waitFor(t, func() bool { _, ok := r.get("74.125.110.70"); return !ok }, "ожившего адреса подмена не снята")
}

func TestNeighborDiesRemaps(t *testing.T) {
	s, n, r, _ := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	first, _ := r.get("74.125.110.70")
	time.Sleep(50 * time.Millisecond) // запасные досчитываются в фоне
	n.set(first, Bad)
	s.Tick()
	waitFor(t, func() bool { g, _ := r.get("74.125.110.70"); return goodSet[g] && g != first }, "умерший сосед не заменён рабочим")
}

func TestNoNeighborNoRule(t *testing.T) {
	s, n, r, _ := newSvc()
	n.mu.Lock()
	n.state = map[string]Verdict{"74.125.110.70": Bad}
	n.mu.Unlock()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	if len(r.set) != 0 {
		t.Fatalf("без рабочего соседа поставлено правило: %v", r.set)
	}
}

func TestDetectorNeedsTwoPollsAndKnownAddr(t *testing.T) {
	s, n, r, c := newSvc()
	n.set("74.125.110.70", Good)
	wait(t, s.OnDNS(gvName, []netip.Addr{bad})) // адрес из ответа DNS, сейчас хороший
	n.set("74.125.110.70", Bad)                 // испортился
	stranger := Flow{Key: "x", Dst: netip.MustParseAddr("8.8.8.8")}
	flow := Flow{Key: "a:1>74.125.110.70:443", Dst: bad, Stuck: true}
	c.add(DetectorPause)
	s.OnConntrack([]Flow{flow, stranger})
	time.Sleep(50 * time.Millisecond)
	if len(r.set) != 0 {
		t.Fatal("сработал с одного опроса")
	}
	c.add(PollEvery)
	s.OnConntrack([]Flow{flow, stranger})
	waitFor(t, func() bool { g, _ := r.get("74.125.110.70"); return goodSet[g] }, "детектор не поставил подмену")
	if _, ok := r.get("8.8.8.8"); ok {
		t.Fatal("детектор тронул адрес, которого не было в ответах DNS")
	}
}

func TestIdleMappingDropped(t *testing.T) {
	s, _, r, c := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	c.add(IdleDrop + time.Minute)
	s.Tick()
	if len(r.set) != 0 {
		t.Fatalf("давно не встречавшаяся подмена осталась: %v", r.set)
	}
}

// Устройство ходит на адрес из своего кэша DNS, роутер его ответов больше не
// видит. Пока соединения к адресу идут, подмена стоит (10.11.2026: снятая
// через час подмена — видео на Mac встало).
func TestMappingKeptWhileInUse(t *testing.T) {
	s, _, r, c := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	inUse := Flow{Key: "dev", Src: netip.MustParseAddr("192.168.1.117"), Dst: bad}
	for i := 0; i < 3; i++ {
		c.add(IdleDrop / 2)
		s.OnConntrack([]Flow{inUse})
		s.Tick()
	}
	if _, ok := r.get("74.125.110.70"); !ok {
		t.Fatal("подмена адреса в ходу снята")
	}
	c.add(IdleDrop + time.Minute)
	s.Tick()
	time.Sleep(50 * time.Millisecond) // запоздавшие перепроверки
	if _, ok := r.get("74.125.110.70"); ok {
		t.Fatal("подмена брошенного адреса осталась")
	}
}

// Перезапуск службы: адрес, который устройство держит в своём кэше DNS,
// поднимается из файла состояния и проверяется заново.
func TestRestoreAfterRestart(t *testing.T) {
	dir := t.TempDir()
	// Правило появляется раньше завершения resolve и записи status.
	// Ждём именно новый снимок, чтобы фон не писал после удаления TempDir.
	waitStatus := func(s *Service) {
		t.Helper()
		waitFor(t, func() bool {
			b, err := os.ReadFile(s.StatusPath)
			var st statusFile
			return err == nil && json.Unmarshal(b, &st) == nil &&
				st.Updated.Equal(s.Now()) && len(st.Mappings) == 1
		}, "снимок состояния после проверки не записан")
	}
	tick := func(s *Service) {
		// Сначала завершаем синхронную запись Tick; затем resolve запишет
		// снимок с подменой. Два писателя одного status.tmp не пересекаются.
		gate := make(chan struct{})
		s.Checker = gatedNet{inner: s.Checker, gate: gate}
		s.Tick()
		close(gate)
	}
	s, _, _, _ := newSvc()
	s.StatusPath = dir + "/st.json"
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	waitStatus(s)
	// Свой снимок для s4: s2 переписывает файл состояния в фоне.
	snap, err := os.ReadFile(s.StatusPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/st4.json", snap, 0o644); err != nil {
		t.Fatal(err)
	}

	s2, _, r2, c2 := newSvc()
	s2.StatusPath = s.StatusPath
	c2.add(time.Minute)
	if n := s2.Restore(); n != 1 {
		t.Fatalf("поднято %d адресов, ждали 1", n)
	}
	tick(s2)
	waitFor(t, func() bool { g, _ := r2.get("74.125.110.70"); return goodSet[g] }, "после перезапуска подмена не встала")
	waitStatus(s2)

	// Адрес видели 45 мин назад: подмена у него ещё жила бы (IdleDrop),
	// значит и после перезапуска должна встать.
	s4, _, r4, c4 := newSvc()
	s4.StatusPath = dir + "/st4.json"
	c4.add(ActiveFor + 15*time.Minute)
	if n := s4.Restore(); n != 1 {
		t.Fatalf("поднято %d адресов, ждали 1", n)
	}
	tick(s4)
	waitFor(t, func() bool { g, _ := r4.get("74.125.110.70"); return goodSet[g] }, "адрес старше ActiveFor после перезапуска остался без подмены")
	waitStatus(s4)

	s3, _, _, c3 := newSvc()
	s3.StatusPath = s.StatusPath
	c3.add(IdleDrop + time.Minute)
	if n := s3.Restore(); n != 0 {
		t.Fatalf("поднят брошенный адрес (%d)", n)
	}
}

// Соединение к плохому адресу, открытое до подмены, сбрасывается один раз;
// переадресованное (ответ от соседа) и рабочее не трогаются.
func TestStuckFlowBeforeMappingKilled(t *testing.T) {
	s, _, r, c := newSvc()
	var mu sync.Mutex
	var killed []string
	s.Kill = func(f Flow) error { mu.Lock(); killed = append(killed, f.Key); mu.Unlock(); return nil }
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	g, _ := r.get("74.125.110.70")
	dev := netip.MustParseAddr("192.168.1.117")
	old := Flow{Key: "old", Proto: "tcp", Src: dev, Dst: bad, ReplySrc: bad, Stuck: true}
	natted := Flow{Key: "nat", Proto: "tcp", Src: dev, Dst: bad, ReplySrc: netip.MustParseAddr(g), Stuck: true}
	working := Flow{Key: "ok", Proto: "tcp", Src: dev, Dst: bad, ReplySrc: bad}
	// Проба z2k: «зависшая» по размеру пакетов, но счётчики растут.
	probe := Flow{Key: "probe", Proto: "tcp", Src: dev, Dst: bad, ReplySrc: bad, Stuck: true, OrigBytes: 600}
	for i := 0; i < 4; i++ {
		c.add(PollEvery)
		probe.ReplyPkts++
		s.OnConntrack([]Flow{old, natted, working, probe})
		if i == 1 {
			// Сброшенное соединение пропадает из conntrack и возвращается
			// повтором клиента — второй раз его не трогаем.
			probe.ReplyPkts++
			s.OnConntrack([]Flow{natted, working, probe})
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(killed, " ") != "old" {
		t.Fatalf("сброшены %v, ждали только old и один раз", killed)
	}
}

func TestShutdownRemovesAll(t *testing.T) {
	s, _, r, _ := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	s.Shutdown()
	if len(r.set) != 0 {
		t.Fatalf("после остановки остались правила: %v", r.set)
	}
}

func (r *fakeRules) get(b string) (string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	g, ok := r.set[b]
	return g, ok
}

func waitFor(t *testing.T, cond func() bool, msg string) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal(msg)
}

// --- ночь на 10.11.2026 --------------------------------------------------------

// Проверки самой службы оставляют в conntrack соединения роутера без ответа
// сервера. Детектор их видеть не должен: иначе каждая проверка запускает
// следующую (цикл каждые 12 с).
func TestDetectorIgnoresRouterOwnFlows(t *testing.T) {
	s, n, _, c := newSvc()
	n.set("74.125.110.70", Good)
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	router := netip.MustParseAddr("88.87.93.11")
	s.Local = func(a netip.Addr) bool { return a == router }
	before := n.calls
	own := Flow{Key: "own", Src: router, Dst: bad, Stuck: true}
	for i := 0; i < 3; i++ {
		c.add(DetectorPause + PollEvery)
		s.OnConntrack([]Flow{own})
	}
	time.Sleep(50 * time.Millisecond)
	n.mu.Lock()
	calls := n.calls
	n.mu.Unlock()
	if calls != before {
		t.Fatalf("соединения самого роутера запустили проверку (%d)", calls-before)
	}
}

// Плохой адрес без соседа не проверяется заново на каждом опросе.
func TestDetectorBacksOffOnBadWithoutNeighbor(t *testing.T) {
	s, n, r, c := newSvc()
	n.mu.Lock()
	n.state = map[string]Verdict{"74.125.110.70": Bad}
	n.mu.Unlock()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	n.mu.Lock()
	before := n.calls
	n.mu.Unlock()
	fl := Flow{Key: "dev", Src: netip.MustParseAddr("192.168.1.117"), Dst: bad, Stuck: true}
	for i := 0; i < 5; i++ {
		c.add(PollEvery + time.Second)
		s.OnConntrack([]Flow{fl})
	}
	time.Sleep(50 * time.Millisecond)
	n.mu.Lock()
	calls := n.calls
	n.mu.Unlock()
	if calls != before {
		t.Fatalf("за срок вердикта плохой адрес проверялся ещё %d раз", calls-before)
	}
	if len(r.set) != 0 {
		t.Fatal("подмена без соседа")
	}
}

// Цепочки пропали (Keenetic перестроил nat) — служба сама их чинит и ставит
// подмены заново.
func TestTickRestoresMappingsAfterChainLoss(t *testing.T) {
	s, _, r, _ := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	r.mu.Lock()
	r.recreate = true
	r.mu.Unlock()
	s.Tick()
	waitFor(t, func() bool { g, _ := r.get("74.125.110.70"); return goodSet[g] }, "после потери цепочек подмена не вернулась")
}

func TestIPTablesEnsure(t *testing.T) {
	type state struct {
		chainExists bool
		first       string
		dns         bool
	}
	run := func(st state) (bool, []string) {
		var calls []string
		r := IPTables{NoV6: true,
			Run: func(bin string, args ...string) error {
				a := strings.Join(args, " ")
				calls = append(calls, a)
				switch {
				case strings.Contains(a, " -N "):
					if st.chainExists {
						return fmt.Errorf("exists")
					}
				case strings.Contains(a, " -C OUTPUT"):
					if !st.dns {
						return fmt.Errorf("нет")
					}
				case strings.Contains(a, " -D PREROUTING"):
					return fmt.Errorf("нет")
				}
				return nil
			},
			Out: func(bin string, args ...string) (string, error) {
				if args[len(args)-1] == "FORWARD" {
					first := strings.ReplaceAll(st.first, "PREROUTING", "FORWARD")
					first = strings.ReplaceAll(first, "Z2K_GVSUB", "Z2K_GVSUB_Q")
					return "-P FORWARD ACCEPT\n" + first + "\n", nil
				}
				return "-P PREROUTING ACCEPT\n" + st.first + "\n", nil
			}}
		rec, _ := r.Ensure()
		return rec, calls
	}
	ours := "-A PREROUTING -j Z2K_GVSUB"
	rec, calls := run(state{chainExists: true, first: ours, dns: true})
	if rec || strings.Contains(strings.Join(calls, "|"), "-I ") {
		t.Fatalf("всё на месте, а Ensure что-то вставил: %v", calls)
	}
	rec, calls = run(state{chainExists: true, first: "-A PREROUTING -j PPE", dns: true})
	if rec || !strings.Contains(strings.Join(calls, "|"), "-t nat -I PREROUTING 1 -j Z2K_GVSUB") {
		t.Fatalf("крючок не первым — не переставлен: %v", calls)
	}
	rec, calls = run(state{chainExists: false, first: "", dns: false})
	all := strings.Join(calls, "|")
	if !rec || !strings.Contains(all, "-t mangle -I OUTPUT 1 ! -o lo -p udp --sport 53") {
		t.Fatalf("пропавший каркас: recreated=%v, %v", rec, calls)
	}
}

func TestWanted(t *testing.T) {
	dir := t.TempDir()
	owner, conf := dir+"/S99", dir+"/config"
	write := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(owner, "start() {\n z2k_gvsub_start\n}\n")
	write(conf, "ENABLED=1\n")
	cfg := Config{Owner: owner, ConfigPath: conf}
	if !wanted(cfg) {
		t.Fatal("init со службой и без ключа — служба должна работать")
	}
	write(conf, "ENABLED=1\nZ2K_GV_SUBST=0\n")
	if wanted(cfg) {
		t.Fatal("Z2K_GV_SUBST=0, а служба продолжает")
	}
	write(conf, "ENABLED=1\n")
	write(owner, "start() { start_daemons; }\n") // init без службы (откат обновлением)
	if wanted(cfg) {
		t.Fatal("init о службе не знает, а она продолжает держать DNS")
	}
}

// Адрес в ходу перепроверяется в фоне, и ответ DNS по нему не ждёт проверки,
// даже когда прошло больше срока вердикта (Марк: «по-хорошему всегда
// проверять», и при этом DNS не должен тормозить).
func TestActiveAddressRefreshedInBackground(t *testing.T) {
	s, n, _, c := newSvc()
	good := netip.MustParseAddr("74.125.110.38")
	wait(t, s.OnDNS(gvName, []netip.Addr{good}))
	for i := 0; i < 4; i++ {
		c.add(RecheckEvery)
		s.Tick()
		time.Sleep(20 * time.Millisecond)
	}
	n.mu.Lock()
	before := n.calls
	n.mu.Unlock()
	if before < 3 {
		t.Fatalf("фоновых перепроверок %d, ждали каждую половину срока", before-1)
	}
	select {
	case <-s.OnDNS(gvName, []netip.Addr{good}):
	case <-time.After(100 * time.Millisecond):
		t.Fatal("адрес в ходу, а ответ DNS ждёт проверки")
	}
	// Перестал приходить в DNS — фоновая проверка прекращается.
	c.add(ActiveFor + time.Minute)
	s.Tick()
	time.Sleep(20 * time.Millisecond)
	n.mu.Lock()
	mid := n.calls
	n.mu.Unlock()
	c.add(RecheckEvery)
	s.Tick()
	time.Sleep(20 * time.Millisecond)
	n.mu.Lock()
	after := n.calls
	n.mu.Unlock()
	if after != mid {
		t.Fatal("адрес давно не в ходу, а фоновая проверка продолжается")
	}
}

// Сосед — только машина того же кластера (10.11.2026: сосед из /24 вслепую
// оказался чужим кластером, и телевизор буферизовал видео).
func TestNeighborOnlyFromSameCluster(t *testing.T) {
	s, _, r, _ := newSvc()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	if g := r.set["74.125.110.70"]; g == "74.125.110.200" || !goodSet[g] {
		t.Fatalf("подмена %q — не машина кластера sn-test", g)
	}
}

func TestNoClusterNameNoSubstitution(t *testing.T) {
	s, _, r, _ := newSvc()
	wait(t, s.OnDNS("redirector.googlevideo.com", []netip.Addr{bad}))
	if len(r.set) != 0 {
		t.Fatalf("без имени кластера поставлена подмена: %v", r.set)
	}
}

// Плохой без рабочих машин: поиск не чаще SearchPause, проверки — только по
// машинам кластера, никакого перебора /24.
func TestSearchPauseAndBoundedProbes(t *testing.T) {
	s, n, r, c := newSvc()
	n.mu.Lock()
	n.state = map[string]Verdict{"74.125.110.70": Bad}
	n.mu.Unlock()
	res := s.Resolver.(*fakeResolver)
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	n.mu.Lock()
	first := n.calls
	n.mu.Unlock()
	if first > 6 {
		t.Fatalf("на поиск ушло %d проверок, а машин в кластере 6", first)
	}
	for i := 0; i < 5; i++ {
		c.add(CacheTTL)
		wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	}
	if res.calls != 1 {
		t.Fatalf("поиск повторялся %d раз за 5 минут, ждали один", res.calls)
	}
	c.add(SearchPause)
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	if res.calls != 2 {
		t.Fatalf("после паузы поиск не повторился (%d)", res.calls)
	}
	if len(r.set) != 0 {
		t.Fatal("подмена без рабочей машины")
	}
}

// Второй плохой адрес кластера без рабочих машин не запускает поиск заново.
func TestDeadClusterNotSearchedAgain(t *testing.T) {
	s, n, _, _ := newSvc()
	n.mu.Lock()
	n.state = map[string]Verdict{"74.125.110.70": Bad, "74.125.110.71": Bad}
	n.mu.Unlock()
	res := s.Resolver.(*fakeResolver)
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	wait(t, s.OnDNS("rr2---sn-test.googlevideo.com", []netip.Addr{netip.MustParseAddr("74.125.110.71")}))
	if res.calls != 1 {
		t.Fatalf("кластер без рабочих машин искали %d раз", res.calls)
	}
}

// Плохой без рабочих машин, пока поиск на паузе, не перепроверяется ни по
// DNS, ни по таймеру: результат проверки всё равно ничего не изменит, а ответ
// DNS ждал бы её (сбор 10.11.2026: ~17 проверок в минуту).
func TestPausedBadNotRechecked(t *testing.T) {
	s, n, _, c := newSvc()
	n.mu.Lock()
	n.state = map[string]Verdict{"74.125.110.70": Bad}
	n.mu.Unlock()
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	n.mu.Lock()
	first := n.calls
	n.mu.Unlock()
	for i := 0; i < 8; i++ {
		c.add(RecheckEvery)
		s.Tick()
		select {
		case <-s.OnDNS(gvName, []netip.Addr{bad}):
		case <-time.After(100 * time.Millisecond):
			t.Fatal("ответ DNS ждёт проверки адреса, поиск по которому на паузе")
		}
		s.OnConntrack([]Flow{{Key: "k", Src: netip.MustParseAddr("192.168.1.117"), Dst: bad, Stuck: true}})
		s.OnConntrack([]Flow{{Key: "k", Src: netip.MustParseAddr("192.168.1.117"), Dst: bad, Stuck: true}})
	}
	time.Sleep(20 * time.Millisecond)
	n.mu.Lock()
	got := n.calls
	n.mu.Unlock()
	if got != first {
		t.Fatalf("за паузу %d лишних проверок", got-first)
	}
	c.add(SearchPause)
	s.Tick()
	waitFor(t, func() bool { n.mu.Lock(); defer n.mu.Unlock(); return n.calls > got }, "после паузы адрес не перепроверен")
}

// Кластер с машинами в обоих семействах: на IPv4 рабочих нет, на IPv6 есть.
type dualResolver struct{}

func (dualResolver) Siblings(_ context.Context, cluster string, v6 bool) []netip.Addr {
	if v6 {
		return []netip.Addr{netip.MustParseAddr("2a00:1450:400f:4::3"), netip.MustParseAddr("2a00:1450:400f:4::4"), netip.MustParseAddr("2a00:1450:400f:4::5")}
	}
	return []netip.Addr{netip.MustParseAddr("173.194.151.68"), netip.MustParseAddr("173.194.151.69")}
}

// 10.11.2026: на IPv4 у кластера рабочих машин нет, и эта пауза не дала искать
// замену на IPv6 — подмена снялась и не встала, ролик у Марка встал с ошибкой.
func TestDeadClusterPerFamily(t *testing.T) {
	s, n, r, _ := newSvc()
	s.Resolver = dualResolver{}
	n.mu.Lock()
	n.state = map[string]Verdict{"173.194.151.68": Bad, "173.194.151.69": Bad,
		"2a00:1450:400f:4::4": Bad, "2a00:1450:400f:4::3": Good}
	n.mu.Unlock()
	const name = "rr4---sn-aj5go5-53.googlevideo.com"
	wait(t, s.OnDNS(name, []netip.Addr{netip.MustParseAddr("173.194.151.68")}))
	wait(t, s.OnDNS(name, []netip.Addr{netip.MustParseAddr("2a00:1450:400f:4::4")}))
	if g, _ := r.get("2a00:1450:400f:4::4"); g != "2a00:1450:400f:4::3" {
		t.Fatalf("IPv6 без подмены (%q): пауза кластера с IPv4 перекрыла IPv6", g)
	}
}

// Одиночный отказ проверки соседа подмену не снимает.
func TestNeighborSingleFailureKeepsMapping(t *testing.T) {
	s, _, r, _ := newSvc()
	fl := &flakyNet{inner: s.Checker}
	s.Checker = fl
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	first, _ := r.get("74.125.110.70")
	time.Sleep(50 * time.Millisecond)
	fl.mu.Lock()
	fl.addr, fl.fails = first, 1
	fl.mu.Unlock()
	s.Tick()
	time.Sleep(100 * time.Millisecond)
	if g, _ := r.get("74.125.110.70"); g != first {
		t.Fatalf("сосед отказал один раз, а подмена сменилась: %q → %q", first, g)
	}
}

type flakyNet struct {
	mu    sync.Mutex
	inner Checker
	addr  string
	fails int
}

func (f *flakyNet) Check(ctx context.Context, a netip.Addr) Verdict {
	f.mu.Lock()
	if a.String() == f.addr && f.fails > 0 {
		f.fails--
		f.mu.Unlock()
		return Dead
	}
	f.mu.Unlock()
	return f.inner.Check(ctx, a)
}

// Shutdown посреди установки подмены: правило не остаётся бесхозным.
func TestNoMappingAfterShutdown(t *testing.T) {
	s, n, r, _ := newSvc()
	gate := make(chan struct{})
	s.Checker = gatedNet{inner: n, gate: gate}
	done := s.OnDNS(gvName, []netip.Addr{bad})
	s.Shutdown()
	close(gate)
	wait(t, done)
	time.Sleep(20 * time.Millisecond)
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.set) != 0 {
		t.Fatalf("после Shutdown поставлена подмена: %v", r.set)
	}
}

type gatedNet struct {
	inner Checker
	gate  chan struct{}
}

func (g gatedNet) Check(ctx context.Context, a netip.Addr) Verdict {
	<-g.gate
	return g.inner.Check(ctx, a)
}

func TestResetRule(t *testing.T) {
	var calls []string
	r := IPTables{Run: func(bin string, args ...string) error {
		calls = append(calls, bin+" "+strings.Join(args, " "))
		return nil
	}}
	f := Flow{Proto: "tcp", Src: netip.MustParseAddr("2a03::1"), Dst: netip.MustParseAddr("2a00:1450::7"), Sport: 57419, Dport: 443}
	if err := r.Reset(f); err != nil {
		t.Fatal(err)
	}
	want := "ip6tables -w -I FORWARD 1 -s 2a03::1 -d 2a00:1450::7 -p tcp --sport 57419 --dport 443 -j REJECT --reject-with tcp-reset"
	if len(calls) != 1 || calls[0] != want {
		t.Fatalf("правило сброса %v, ждали %s", calls, want)
	}
	_ = r.Reset(Flow{Proto: "udp", Src: f.Src, Dst: f.Dst})
	if len(calls) != 1 {
		t.Fatal("сброс для UDP — у QUIC его нет")
	}
}

// Адрес из ответа DNS попадает в список для движка ДО возврата из OnDNS (до
// того, как ответ отпущен устройству): иначе первое соединение к нему идёт
// мимо профиля googlevideo, без пробы (10.11.2026).
func TestIPFileWrittenBeforeRelease(t *testing.T) {
	s, _, _, c := newSvc()
	s.IPFile = t.TempDir() + "/gv-ips.txt"
	other := netip.MustParseAddr("2a00:1450:4001::9")
	done := s.OnDNS(gvName, []netip.Addr{bad, other})
	b, err := os.ReadFile(s.IPFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(b); got != ipFileSentinels+"2a00:1450:4001::9\n74.125.110.70\n" {
		t.Fatalf("список %q", got)
	}
	wait(t, done)
	// Брошенный адрес уходит из known, но остаётся в опубликованном наборе.
	c.add(IdleDrop + time.Minute)
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	s.Tick()
	s.mu.Lock()
	_, retained := s.known[other]
	s.mu.Unlock()
	if retained {
		t.Fatal("IdleDrop не удалил адрес из known")
	}
	b, _ = os.ReadFile(s.IPFile)
	if got := string(b); got != ipFileSentinels+"2a00:1450:4001::9\n74.125.110.70\n" {
		t.Fatalf("после уборки список %q", got)
	}
}
