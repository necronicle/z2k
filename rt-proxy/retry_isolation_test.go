package main

import (
	"bufio"
	"net"
	"testing"
	"time"
)

func TestReproConcurrentTrafficRepeatsFailedNode(t *testing.T) {
	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 4, time.Second
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })
	p := &pool{live: []string{"healthy-A", "failing-B", "healthy-C"}}
	var attempted []string
	withTunnelStubs(t, func(ip, target string) (net.Conn, *bufio.Reader, bool, bool) {
		attempted = append(attempted, ip)
		if ip == "failing-B" {
			// Valid interleaving: two other connections choose nodes between retries.
			p.pick()
			p.pick()
			return nil, nil, false, true
		}
		c, br := newStubTunnel()
		return c, br, true, true
	}, func(string, net.Conn, *bufio.Reader, []byte) bool { return true })
	up, _ := dialUpstream(p, "rutracker.org", []byte("hello"))
	if up == nil {
		t.Fatalf("request failed despite healthy nodes; attempted=%v remaining=%v", attempted, liveSet(p))
	}
}
func TestReproRepeatedHiddenHostDrainsHealthyPool(t *testing.T) {
	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 4, 20*time.Millisecond
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })
	p := &pool{live: []string{"healthy-A", "healthy-B", "healthy-C"}}
	var lastTarget string
	withTunnelStubs(t, func(ip, target string) (net.Conn, *bufio.Reader, bool, bool) {
		lastTarget = target
		c, br := newStubTunnel()
		return c, br, true, true
	}, func(string, net.Conn, *bufio.Reader, []byte) bool { return lastTarget == "rutracker.org:443" })
	for i := 0; i < 3; i++ {
		up, _ := dialUpstream(p, "rutracker.org", []byte("hello"))
		if up == nil {
			t.Fatal("baseline request failed")
		}
		up.Close()
	}
	for i := 0; i < 3; i++ {
		dialUpstream(p, "cloudflare-ech.com", []byte("hello"))
	}
	if p.liveCount() == 0 {
		t.Fatal("3 failed hidden-host requests removed all 3 healthy proxy nodes")
	}
}

func TestRetryPoolReorderDoesNotRepeatAttempt(t *testing.T) {
	oldTries, oldWait := *maxTries, *pickWaitTO
	*maxTries, *pickWaitTO = 4, time.Second
	t.Cleanup(func() { *maxTries, *pickWaitTO = oldTries, oldWait })
	p := &pool{live: []string{"good", "bad"}}
	calls := []string{}
	withTunnelStubs(t, func(ip, target string) (net.Conn, *bufio.Reader, bool, bool) {
		calls = append(calls, ip)
		if ip == "bad" {
			p.mu.Lock()
			p.live = []string{"bad", "good"}
			p.mu.Unlock()
			return nil, nil, false, true
		}
		c, br := newStubTunnel()
		return c, br, true, true
	}, func(string, net.Conn, *bufio.Reader, []byte) bool { return true })
	if up, _ := dialUpstream(p, "rutracker.org", nil); up == nil {
		t.Fatalf("reorder lost good node: %v", calls)
	} else {
		up.Close()
	}
	if len(calls) != 2 || calls[0] == calls[1] {
		t.Fatalf("repeated candidate: %v", calls)
	}
}
