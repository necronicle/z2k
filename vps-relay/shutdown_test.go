package main

import (
	"testing"
	"time"
)

func TestDrain_SendsRetryAfterThenShutdown(t *testing.T) {
	m := withMemEvents(t)
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, _ := dialV2(t, url, id, priv, "r-82")
	id1, priv1 := testInstall(t)
	ws1 := dialV1(t, url, id1, priv1)
	done := make(chan struct{})
	go func() { drainSessions(300 * time.Millisecond); close(done) }()
	p := expectFrame(t, ws, 0, muxINFO, 2*time.Second)
	k, arg, _, _ := decodeInfo(p)
	if k != infoRetryAfter || arg > 60 {
		t.Fatalf("ожидался RETRY_AFTER ≤60, получено kind=%d arg=%d", k, arg)
	}
	p = expectFrame(t, ws, 0, muxINFO, 2*time.Second)
	k, arg, _, _ = decodeInfo(p)
	if k != infoGoodbye || byte(arg) != rShutdown {
		t.Fatalf("ожидался GOODBYE(SHUTDOWN), получено kind=%d arg=%d", k, arg)
	}
	<-done
	_ = ws1.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := ws1.ReadMessage(); err == nil {
		t.Fatal("v1-сессия не закрыта при остановке")
	}
	if !m.wait("session_close", 2, 2*time.Second) {
		t.Fatal("нет двух session_close")
	}
	for _, e := range m.byEv("session_close") {
		if e.Reason != "shutdown" {
			t.Fatalf("reason=%q", e.Reason)
		}
	}
}
