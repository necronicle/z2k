package main

import (
	"net"
	"testing"
	"time"
)

// A burst behind one router must not expire locally merely because six
// CONNECTs are waiting for a distant relay. Every phone sends actual data.
func TestConnectBurstSurvivesRelayLatency(t *testing.T) {
	fr := newFakeRelay(t)
	fr.connectDelay = 600 * time.Millisecond
	tc := newTestClient(t, fr)
	runDone := make(chan struct{})
	go func() { defer close(runDone); tc.run() }()
	t.Cleanup(func() {
		tc.cancel()
		tc.mu.Lock()
		ws := tc.ws
		tc.mu.Unlock()
		if ws != nil {
			ws.Close()
		}
		select {
		case <-runDone:
		case <-time.After(5 * time.Second):
			t.Error("tunnel did not stop")
		}
		tc.closeAllStreams()
	})
	waitReady(t, fr)
	const count = 128
	start := time.Now()
	for i := 0; i < count; i++ {
		srv, phone := phonePair(t)
		t.Cleanup(func() { phone.Close() })
		go tc.openStream(srv, net.ParseIP("149.154.175.50"), 443)
		if _, err := phone.Write([]byte("burst")); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.NewTimer(12 * time.Second)
	defer deadline.Stop()
	received := 0
	for received < count {
		select {
		case f := <-fr.recv:
			if f.MsgType == muxDATA && string(f.Payload) == "burst" {
				received++
			}
		case <-deadline.C:
			t.Fatalf("only %d/%d phones delivered data; local CONNECT queue discarded the rest", received, count)
		}
	}
	t.Logf("%d phones delivered data in %s", count, time.Since(start))
}
