package main

import (
	"context"
	"net"
	"testing"
	"time"
)

// The reach guard. Without it a LAN-reachable listener becomes a general relay:
// an arbitrary SNI would reach anything the ROUTER can, including its own
// services, whereas today it can only reach what the upstream agrees to serve.
func TestDirectHostAllowed_OnlyPinnedFamilies(t *testing.T) {
	old := *directHosts
	*directHosts = "rutracker.org,rutracker.wiki,rutracker.cc,t-ru.org"
	t.Cleanup(func() { *directHosts = old })

	allowed := []string{
		"rutracker.org", "www.rutracker.org", "static.rutracker.cc",
		"api.rutracker.cc", "rutracker.wiki", "bt2.t-ru.org",
		"RuTracker.ORG", "rutracker.org.", // case and trailing dot
	}
	for _, h := range allowed {
		if !directHostAllowed(h) {
			t.Errorf("%q should be eligible for the direct fallback", h)
		}
	}

	denied := []string{
		"", "example.com", "127.0.0.1", "localhost",
		"192.168.1.1", "router.lan",
		// suffix matching must be DOT-ANCHORED, or an attacker registers these:
		"rutracker.org.evil.tld", "evilrutracker.org", "notrutracker.cc",
		"xrutracker.wiki",
	}
	for _, h := range denied {
		if directHostAllowed(h) {
			t.Errorf("%q must NOT be eligible — this is the SSRF widening the guard exists for", h)
		}
	}
}

// The loop guard. Every one of these names is pinned to a sentinel by this very
// daemon, so an answer pointing back inside must be refused: connecting to it
// would make the proxy talk to itself, recursively, until the router runs out of
// descriptors.
func TestRoutableUnicast_RefusesAnythingPointingBackInside(t *testing.T) {
	mustRefuse := []string{
		"10.171.171.171", // THE sentinel
		"127.0.0.1", "::1",
		"192.168.1.1", "10.0.0.1", "172.16.0.1",
		"169.254.1.1", "fe80::1",
		"224.0.0.1", "ff02::1",
		"0.0.0.0", "::",
	}
	for _, s := range mustRefuse {
		if ip := parseIPForTest(s); ip == nil {
			t.Fatalf("bad fixture %q", s)
		} else if routableUnicast(ip) {
			t.Errorf("%s must be refused — it can point back at this router", s)
		}
	}
	mustAccept := []string{"188.186.154.79", "104.21.32.39", "1.1.1.1", "2606:4700::1111"}
	for _, s := range mustAccept {
		if ip := parseIPForTest(s); ip == nil {
			t.Fatalf("bad fixture %q", s)
		} else if !routableUnicast(ip) {
			t.Errorf("%s is a normal public address and must be accepted", s)
		}
	}
}

func parseIPForTest(s string) net.IP { return net.ParseIP(s) }

// The allowlist must be consulted BEFORE anything is resolved or dialled. Testing
// directHostAllowed on its own is not enough: a mutation that deleted the call
// from dialDirect left every such test green.
func TestDialDirect_RefusesBeforeResolving(t *testing.T) {
	oldHosts, oldOn := *directHosts, *directFallback
	*directHosts, *directFallback = "rutracker.org", true
	t.Cleanup(func() { *directHosts, *directFallback = oldHosts, oldOn })

	looked := 0
	prev := directLookup
	directLookup = func(_ context.Context, host string) ([]string, error) {
		looked++
		return []string{"188.186.154.79"}, nil
	}
	t.Cleanup(func() { directLookup = prev })

	up, br := dialDirect("evil.example.com", []byte("hello"))
	if up != nil || br != nil {
		t.Fatal("a non-allowlisted SNI must never be dialled directly")
	}
	if looked != 0 {
		t.Fatalf("the allowlist must be checked BEFORE resolving; resolver was called %d time(s)", looked)
	}
}

// ...and a name that IS allowlisted but resolves back inside must still be refused,
// so the two guards cannot be satisfied by one another.
func TestDialDirect_RefusesAnAllowlistedNameResolvingToTheSentinel(t *testing.T) {
	oldHosts, oldOn := *directHosts, *directFallback
	*directHosts, *directFallback = "rutracker.org", true
	t.Cleanup(func() { *directHosts, *directFallback = oldHosts, oldOn })

	prev := directLookup
	directLookup = func(_ context.Context, _ string) ([]string, error) {
		return []string{"10.171.171.171", "127.0.0.1", "192.168.1.1"}, nil
	}
	t.Cleanup(func() { directLookup = prev })

	if up, _ := dialDirect("rutracker.org", []byte("hello")); up != nil {
		up.Close()
		t.Fatal("resolving to the sentinel must not produce a connection — that is the self-dial loop")
	}
}

// LIMIT OF THIS TEST, stated up front: it verifies the TOTAL budget is respected,
// but it canNOT distinguish "one shared budget" from "one each" — on a loopback
// listener the dial completes in ~1 ms, so a restarted handshake budget still
// lands inside the ceiling. Reproducing a slow dial (SYN blackhole) reliably in a
// unit test is not something I could do without depending on the environment, and
// a mutation to the old doubling behaviour DOES pass this test. The fix itself is
// correct by construction rather than by measurement: dialProxyDeadline takes an
// ABSOLUTE deadline and hands the same value to both net.Dialer.Deadline and
// tls.Conn.SetDeadline, so there is no duration left to restart. Verified by
// reading, and by the type signature no longer being able to express the bug.
//
// One budget for dial+handshake, not one each. A blackholed node that completes a
// slow TCP handshake and then stalls in TLS used to cost 2x what the caller asked
// for, because dialProxy took a DURATION and restarted it for the handshake.
// probeAll waits on every probe, so that doubling stretched the whole health cycle
// and made the empty-pool recover cadence ~3x slower than intended.
func TestDialProxyDeadline_TotalBudgetIsRespected(t *testing.T) {
	// A listener that accepts TCP and then never speaks TLS: the dial succeeds
	// quickly, the handshake blocks — exactly the shape that used to double.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_ = c // hold it open, say nothing
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())

	oldPort := *proxyPort
	*proxyPort = port
	t.Cleanup(func() { *proxyPort = oldPort })

	const budget = 700 * time.Millisecond
	t0 := time.Now()
	c, err := dialProxyDeadline("127.0.0.1", time.Now().Add(budget))
	el := time.Since(t0)
	if c != nil {
		c.Close()
	}
	if err == nil {
		t.Fatal("a silent TLS peer must not produce a successful handshake")
	}
	// The old code would take ~2x budget here. Allow generous slack for CI while
	// still failing on a doubling.
	if el > time.Duration(1.6*float64(budget)) {
		t.Fatalf("dial+handshake took %s against a %s absolute deadline — the deadline is not being honoured", el, budget)
	}
}

// The connection ceiling, tested where the decision actually lives. Each client
// costs a 33 KiB reader, two io.Copy buffers, a watchdog and three goroutines, and
// there was no limit at all — on a 500 MB router with a documented OOM-kill history
// that is a real hazard.
//
// Deliberately NOT an end-to-end serve() test. That version held real connections,
// and its handlers outlived the test by up to --pick-wait while still reading flag
// globals that later tests write: -race reported it, correctly, as a data race, and
// it leaked goroutines out of the one test whose subject is resource discipline.
// The gate is unit-tested here; its single call site in serve() is three lines and
// verified by reading.
func TestTryAcquire_RefusesOnceTheCeilingIsReached(t *testing.T) {
	const ceiling = 3
	sem := make(chan struct{}, ceiling)

	for i := 1; i <= ceiling; i++ {
		if !tryAcquire(sem) {
			t.Fatalf("slot %d of %d was refused while still under the ceiling", i, ceiling)
		}
	}
	// Past the ceiling it must refuse IMMEDIATELY rather than block: a queued
	// client just hangs, which is the failure mode this guards against.
	done := make(chan bool, 1)
	go func() { done <- tryAcquire(sem) }()
	select {
	case got := <-done:
		if got {
			t.Fatal("a slot past the ceiling was granted")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("tryAcquire BLOCKED past the ceiling — connections would queue, not be refused")
	}

	// Releasing one slot must let exactly one more in.
	<-sem
	if !tryAcquire(sem) {
		t.Fatal("a freed slot was not reusable")
	}
	if tryAcquire(sem) {
		t.Fatal("two slots were granted after releasing only one")
	}
}
