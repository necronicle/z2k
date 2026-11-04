package main

import (
	"bufio"
	"io"
	"net"
	"testing"
	"time"
)

func TestRetryBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name   string
		nodes  []string
		cap    int
		budget time.Duration
		want   int
	}{
		{"cap before exhaustion", []string{"a", "b", "c", "d", "e"}, 3, time.Second, 3},
		{"exhaustion before cap", []string{"a", "b"}, 4, time.Second, 2},
		{"zero budget", []string{"a"}, 4, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			oldCap, oldWait := *maxTries, *pickWaitTO
			*maxTries, *pickWaitTO = tc.cap, tc.budget
			defer func() { *maxTries, *pickWaitTO = oldCap, oldWait }()
			seen := map[string]bool{}
			withTunnelStubs(t, func(ip, target string) (net.Conn, *bufio.Reader, bool, bool) {
				if seen[ip] {
					t.Fatalf("repeated %s", ip)
				}
				seen[ip] = true
				return nil, nil, false, true
			}, func(string, net.Conn, *bufio.Reader, []byte) bool { t.Fatal("unexpected flight check"); return false })
			start := time.Now()
			dialUpstream(&pool{live: tc.nodes}, "rutracker.org", nil)
			if len(seen) != tc.want {
				t.Fatalf("attempts=%d, want %d", len(seen), tc.want)
			}
			if time.Since(start) > 300*time.Millisecond {
				t.Fatal("exhausted candidates waited unnecessarily")
			}
		})
	}
}

func TestInitiallyEmptyPoolCanRecover(t *testing.T) {
	old := *pickWaitTO
	*pickWaitTO = time.Second
	defer func() { *pickWaitTO = old }()
	p := &pool{}
	withTunnelStubs(t, func(string, string) (net.Conn, *bufio.Reader, bool, bool) {
		c, br := newStubTunnel()
		return c, br, true, true
	}, func(string, net.Conn, *bufio.Reader, []byte) bool { return true })
	done := make(chan struct{})
	go func() {
		defer close(done)
		time.Sleep(20 * time.Millisecond)
		p.mu.Lock()
		p.live = []string{"new"}
		p.mu.Unlock()
	}()
	up, _ := dialUpstream(p, "rutracker.org", nil)
	<-done
	if up == nil {
		t.Fatal("did not discover newly populated pool")
	}
	up.Close()
}

func TestVerifiedFlightClearsDeadlineAndPreservesBytes(t *testing.T) {
	up, peer := net.Pipe()
	defer up.Close()
	defer peer.Close()
	peer.SetDeadline(time.Now().Add(2 * time.Second))
	flight := []byte{0x16, 3, 3, 0, 1, 1, 0x14, 3, 3, 0, 1, 1}
	done := make(chan struct{})
	go func() {
		defer close(done)
		hello := make([]byte, 5)
		if _, err := io.ReadFull(peer, hello); err != nil {
			return
		}
		peer.Write(flight)
		io.Copy(peer, peer)
	}()
	defer func() { peer.Close(); <-done }()
	br := bufio.NewReaderSize(up, bufSize)
	if !verifyFirstByteUntil("fixture", up, br, []byte("hello"), time.Now().Add(50*time.Millisecond)) {
		t.Fatal("valid flight rejected")
	}
	got := make([]byte, len(flight))
	if _, err := io.ReadFull(br, got); err != nil || string(got) != string(flight) {
		t.Fatalf("flight lost: %x %v", got, err)
	}
	time.Sleep(70 * time.Millisecond)
	// A leaked read or write deadline would reject this exchange immediately.
	if _, err := up.Write([]byte("x")); err != nil {
		t.Fatalf("write deadline leaked: %v", err)
	}
	got = make([]byte, 1)
	if _, err := io.ReadFull(br, got); err != nil || got[0] != 'x' {
		t.Fatalf("read deadline leaked: %v", err)
	}
}
