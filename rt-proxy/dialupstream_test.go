package main

import (
	"bufio"
	"bytes"
	"io"
	"net"
	"testing"
	"time"
)

// stubConn is a closable no-op net.Conn; dialUpstream only ever Closes it.
type stubConn struct {
	net.Conn
	closed bool
}

func (s *stubConn) Close() error { s.closed = true; return nil }

func newStubTunnel() (*stubConn, *bufio.Reader) {
	c := &stubConn{}
	return c, bufio.NewReader(bytes.NewReader(nil))
}

// withTunnelStubs replaces the two I/O helpers dialUpstream depends on.
func withTunnelStubs(t *testing.T,
	open func(ip, target string) (net.Conn, *bufio.Reader, bool, bool),
	verify func(ip string, up net.Conn, br *bufio.Reader, hello []byte) bool) {
	t.Helper()
	po, pv := openTunnelFn, verifyFirstByteFn
	openTunnelFn, verifyFirstByteFn = open, verify
	t.Cleanup(func() { openTunnelFn, verifyFirstByteFn = po, pv })
}

func liveSet(p *pool) []string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return append([]string(nil), p.live...)
}

// DEFECT 1. A node we cannot reach at all is the RU-block signature. It must
// leave the ring immediately; otherwise round-robin keeps handing it out for the
// rest of the health interval, burning the dial budget on every pick.
func TestDialUpstream_UnreachableNodeIsDemoted(t *testing.T) {
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			return nil, nil, false, false // never reached it
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	p := &pool{live: []string{"203.0.113.1"}}
	old := *maxTries
	*maxTries = 1
	t.Cleanup(func() { *maxTries = old })

	up, _ := dialUpstream(p, "rutracker.org", []byte("hello"))
	if up != nil {
		t.Fatal("dialUpstream returned a tunnel although the upstream was unreachable")
	}
	if got := liveSet(p); len(got) != 0 {
		t.Fatalf("unreachable node was left in the live ring: %v", got)
	}
}

// ...but a node that ANSWERS and refuses the CONNECT (502/503 from a healthy but
// overloaded proxy) must be kept. Evicting on that throws away good nodes under
// load, which is worse than the retry it saves.
func TestDialUpstream_NodeThatAnswersNon200IsNotDemoted(t *testing.T) {
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			return nil, nil, false, true // answered, refused
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	p := &pool{live: []string{"203.0.113.1"}}
	old := *maxTries
	*maxTries = 1
	t.Cleanup(func() { *maxTries = old })

	dialUpstream(p, "rutracker.org", []byte("hello"))
	if got := liveSet(p); len(got) != 1 {
		t.Fatalf("a reachable-but-refusing node must stay in the ring, got %v", got)
	}
}

// The pre-existing contract must survive the change: a node that opens a tunnel
// but never delivers the server flight is still demoted, and its connection closed.
func TestDialUpstream_FirstByteFailureStillDemotesAndCloses(t *testing.T) {
	var conn *stubConn
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			c, br := newStubTunnel()
			conn = c
			return c, br, true, true
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return false })

	p := &pool{live: []string{"203.0.113.1"}}
	old := *maxTries
	*maxTries = 1
	t.Cleanup(func() { *maxTries = old })

	up, _ := dialUpstream(p, "rutracker.org", []byte("hello"))
	if up != nil {
		t.Fatal("a tunnel that never proved itself must not be handed to the client")
	}
	if got := liveSet(p); len(got) != 0 {
		t.Fatalf("node failing verifyFirstByte must be demoted, got %v", got)
	}
	if conn == nil || !conn.closed {
		t.Error("the rejected tunnel was not closed — fd leak")
	}
}

// DEFECT 2. The pick-wait budget must bound the RETRY loop too, not only the
// empty-pool wait. With a live-looking but broken pool the loop was bounded by
// nothing but max-tries x the per-try dial budget, while the client's read
// deadline had already been cleared.
func TestDialUpstream_RetryLoopRespectsThePickWaitBudget(t *testing.T) {
	attempts := 0
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			attempts++
			time.Sleep(120 * time.Millisecond) // a slow, failing upstream
			return nil, nil, false, true       // answered+refused: no demotion, ring stays full
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	// Many tries allowed, but a tiny budget: the budget must be what stops us.
	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 1000, 300*time.Millisecond
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })

	p := &pool{live: []string{"203.0.113.1", "203.0.113.2"}}
	t0 := time.Now()
	up, _ := dialUpstream(p, "rutracker.org", []byte("hello"))
	el := time.Since(t0)

	if up != nil {
		t.Fatal("expected no tunnel from an always-failing pool")
	}
	if el > 2*time.Second {
		t.Fatalf("retry loop ignored the %s budget: ran %s over %d attempts", *pickWaitTO, el, attempts)
	}
	if attempts >= 1000 {
		t.Fatalf("retry loop ran to max-tries (%d) instead of stopping at the budget", attempts)
	}
}

// max-tries must still cap the attempts when the budget is generous.
func TestDialUpstream_StopsAtMaxTries(t *testing.T) {
	attempts := 0
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			attempts++
			return nil, nil, false, true
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 3, 10*time.Second
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })

	p := &pool{live: []string{"203.0.113.1", "203.0.113.2"}}
	if up, _ := dialUpstream(p, "rutracker.org", []byte("hello")); up != nil {
		t.Fatal("expected no tunnel")
	}
	if attempts != 3 {
		t.Fatalf("want exactly max-tries=3 attempts, got %d", attempts)
	}
}

// The success path: a proven tunnel is returned, with the reader the splice needs.
func TestDialUpstream_ReturnsAProvenTunnel(t *testing.T) {
	withTunnelStubs(t,
		func(ip, target string) (net.Conn, *bufio.Reader, bool, bool) {
			if target != "rutracker.org:443" {
				t.Errorf("CONNECT target should be the SNI plus :443, got %q", target)
			}
			c, br := newStubTunnel()
			return c, br, true, true
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	p := &pool{live: []string{"203.0.113.1"}}
	up, br := dialUpstream(p, "rutracker.org", []byte("hello"))
	if up == nil || br == nil {
		t.Fatal("a proven tunnel and its reader must both be returned")
	}
	if got := liveSet(p); len(got) != 1 {
		t.Errorf("a working node must stay in the ring, got %v", got)
	}
}

// An empty pool must fail closed within the budget rather than hang.
func TestDialUpstream_EmptyPoolFailsClosedWithinBudget(t *testing.T) {
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			t.Error("openTunnel must not be called with an empty pool")
			return nil, nil, false, false
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	oldWait := *pickWaitTO
	*pickWaitTO = 400 * time.Millisecond
	t.Cleanup(func() { *pickWaitTO = oldWait })

	t0 := time.Now()
	up, _ := dialUpstream(&pool{}, "rutracker.org", []byte("hello"))
	el := time.Since(t0)
	if up != nil {
		t.Fatal("empty pool must not yield a tunnel")
	}
	if el > 3*time.Second {
		t.Fatalf("empty-pool wait overran its %s budget: %s", *pickWaitTO, el)
	}
}

// The bufio buffer must hold the LARGEST Peek verifyFirstByte can request: two
// maximum-size TLS records plus their 5-byte headers. It was 10 bytes short, so a
// healthy upstream sending two full records was demoted with ErrBufferFull.
// Asserted behaviourally — feed exactly that shape through verifyFirstByte over a
// reader sized like openTunnel's and require acceptance.
func TestVerifyFirstByte_TwoMaximumSizeRecordsFitTheBuffer(t *testing.T) {
	const maxFrag = 16384
	var flight bytes.Buffer
	// record 1: handshake, full size
	flight.Write([]byte{0x16, 0x03, 0x03, byte(maxFrag >> 8), byte(maxFrag & 0xff)})
	flight.Write(make([]byte, maxFrag))
	// record 2: application_data, full size
	flight.Write([]byte{0x17, 0x03, 0x03, byte(maxFrag >> 8), byte(maxFrag & 0xff)})
	flight.Write(make([]byte, maxFrag))

	need := 5 + maxFrag + 5 + maxFrag
	if flight.Len() != need {
		t.Fatalf("fixture is %d bytes, expected %d", flight.Len(), need)
	}

	up := &recordingConn{r: bytes.NewReader(flight.Bytes())}
	// EXACTLY the size openTunnel uses, read back from the code path under test.
	br := bufio.NewReaderSize(up, bufSizeForTest)
	if bufSizeForTest < need {
		t.Fatalf("openTunnel's reader (%d) is smaller than the maximum Peek (%d) — "+
			"a healthy upstream sending two full records will be demoted", bufSizeForTest, need)
	}
	if !verifyFirstByte("203.0.113.1", up, br, []byte("hello")) {
		t.Fatal("an upstream delivering two maximum-size records was rejected")
	}
}

// recordingConn is a minimal net.Conn over a reader; writes are discarded.
type recordingConn struct {
	net.Conn
	r *bytes.Reader
}

func (c *recordingConn) Read(p []byte) (int, error)      { return c.r.Read(p) }
func (c *recordingConn) Write(p []byte) (int, error)     { return len(p), nil }
func (c *recordingConn) Close() error                    { return nil }
func (c *recordingConn) SetReadDeadline(time.Time) error { return nil }
func (c *recordingConn) SetDeadline(time.Time) error     { return nil }

// Read back from the production constant so this can never drift from the code.
const bufSizeForTest = bufSize

// A DEAD TARGET must not strip the pool. Reproduced on the owner's router: one
// request for a dead hostname demoted four healthy upstreams in a row and then
// dropped the request, degrading rutracker.org for every other client until the
// next 90 s probe. Neither failure mode can tell a broken NODE from a dead
// TARGET, so the blast radius is capped instead: at most one demotion per request.
func TestDialUpstream_DeadTargetDemotesAtMostOneNode(t *testing.T) {
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			c, br := newStubTunnel()
			return c, br, true, true // every node tunnels fine...
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return false }) // ...target is dead

	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 4, 10*time.Second
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })

	p := &pool{live: []string{"203.0.113.1", "203.0.113.2", "203.0.113.3", "203.0.113.4"}}
	if up, _ := dialUpstream(p, "dead.example", []byte("hello")); up != nil {
		t.Fatal("a dead target must not yield a tunnel")
	}
	got := liveSet(p)
	if len(got) != 3 {
		t.Fatalf("a dead target must cost exactly ONE node, not %d: pool went 4 -> %d (%v)",
			4-len(got), len(got), got)
	}
}

// The same cap must hold when the nodes are unreachable rather than silent —
// a local WAN flap makes every dial fail at once and must not empty the ring.
func TestDialUpstream_WanFlapDemotesAtMostOneNode(t *testing.T) {
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			return nil, nil, false, false // nothing is reachable
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 4, 10*time.Second
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })

	p := &pool{live: []string{"203.0.113.1", "203.0.113.2", "203.0.113.3", "203.0.113.4"}}
	dialUpstream(p, "rutracker.org", []byte("hello"))
	if got := liveSet(p); len(got) != 3 {
		t.Fatalf("a WAN flap must not empty the ring: 4 -> %d (%v)", len(got), got)
	}
}

// ...but a genuinely dead NODE must still leave the ring on the first request
// that touches it — the cap must not turn into "never demote".
func TestDialUpstream_OneBadNodeAmongGoodOnesStillLeavesTheRing(t *testing.T) {
	bad := "203.0.113.1"
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			c, br := newStubTunnel()
			return c, br, true, true
		},
		func(ip string, _ net.Conn, _ *bufio.Reader, _ []byte) bool {
			return ip != bad // only the bad node fails
		})

	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 4, 10*time.Second
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })

	// rr starts at 0 and pick() pre-increments, so index 1 (the bad node) is first.
	p := &pool{live: []string{"203.0.113.0", bad, "203.0.113.2"}}
	up, _ := dialUpstream(p, "rutracker.org", []byte("hello"))
	if up == nil {
		t.Fatal("a healthy node was available; the request should have succeeded")
	}
	for _, ip := range liveSet(p) {
		if ip == bad {
			t.Fatalf("the failing node must still be demoted: %v", liveSet(p))
		}
	}
}

// A panic in one connection must not take the daemon down. Every client runs in
// its own `go handle`, and an unrecovered panic in ANY goroutine kills the whole
// process — the supervisor then restarts us and cuts every OTHER client's tunnel
// too. Forced here through the openTunnel seam; a real trigger would be a parsing
// bug on a malformed peer.
func TestHandle_PanicInOneConnectionDoesNotKillTheDaemon(t *testing.T) {
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			panic("simulated bug on the upstream path")
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	hello := realClientHello(t, "rutracker.org")
	client, peer := net.Pipe()
	go func() { _, _ = peer.Write(hello) }()
	t.Cleanup(func() { client.Close(); peer.Close() })

	done := make(chan struct{})
	go func() {
		// If handle() did not recover, this goroutine's panic would abort the whole
		// test binary — which is exactly what it does to the daemon in production.
		handle(client, &pool{live: []string{"203.0.113.1"}})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("handle() never returned after the panic")
	}
}

// An IDLE connection must be closed after the timeout...
func TestHandle_IdleConnectionIsClosed(t *testing.T) {
	oldTO := *idleTO
	*idleTO = 600 * time.Millisecond
	t.Cleanup(func() { *idleTO = oldTO })

	upPeerDone := make(chan struct{})
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			// A tunnel that accepts the hello and then says nothing at all.
			// A real pipe whose peer never writes: silent, but CLOSABLE — which is
			// what production looks like, and what lets the watchdog unblock it.
			c, peer := net.Pipe()
			go func() { io.Copy(io.Discard, peer); close(upPeerDone) }()
			return c, bufio.NewReader(c), true, true
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	client, peer := net.Pipe()
	go func() { _, _ = peer.Write(realClientHello(t, "rutracker.org")) }()
	t.Cleanup(func() { client.Close(); peer.Close() })

	done := make(chan struct{})
	t0 := time.Now()
	go func() { handle(client, &pool{live: []string{"203.0.113.1"}}); close(done) }()

	select {
	case <-done:
		if el := time.Since(t0); el < 400*time.Millisecond {
			t.Fatalf("returned after %s — too early to be the idle timeout", el)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("an idle connection was never closed — the idle timeout does not fire")
	}
}

// ...but a connection that keeps moving bytes must NOT be cut at the timeout.
// The old code created the timer once and never reset it, so this is exactly the
// case it got wrong: a long transfer died at the deadline regardless of activity.
func TestHandle_ActiveConnectionSurvivesPastTheIdleTimeout(t *testing.T) {
	oldTO := *idleTO
	*idleTO = 400 * time.Millisecond
	t.Cleanup(func() { *idleTO = oldTO })

	stop := make(chan struct{})
	withTunnelStubs(t,
		func(ip, _ string) (net.Conn, *bufio.Reader, bool, bool) {
			c, peer := net.Pipe()
			go func() { io.Copy(io.Discard, peer) }()
			// Upstream trickles a byte every 100ms — well inside the 400ms idle bar.
			return c, bufio.NewReader(&trickleReader{every: 100 * time.Millisecond, stop: stop}), true, true
		},
		func(string, net.Conn, *bufio.Reader, []byte) bool { return true })

	client, peer := net.Pipe()
	go func() {
		_, _ = peer.Write(realClientHello(t, "rutracker.org"))
		io.Copy(io.Discard, peer) // drain what the proxy relays back
	}()
	t.Cleanup(func() { client.Close(); peer.Close() })

	done := make(chan struct{})
	go func() { handle(client, &pool{live: []string{"203.0.113.1"}}); close(done) }()

	// Survive well past the old absolute cap...
	select {
	case <-done:
		t.Fatal("an ACTIVE connection was cut at the idle timeout — the timeout is still absolute")
	case <-time.After(1200 * time.Millisecond):
	}
	// ...and then close once the trickle stops.
	close(stop)
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("connection was not closed after activity ceased")
	}
}

type silentReader struct{}

func (silentReader) Read([]byte) (int, error) { select {} } // blocks forever

type trickleReader struct {
	every time.Duration
	stop  chan struct{}
}

func (t *trickleReader) Read(p []byte) (int, error) {
	select {
	case <-t.stop:
		return 0, io.EOF
	case <-time.After(t.every):
		p[0] = 0x17
		return 1, nil
	}
}
