package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
	"time"
)

func TestNoisy_FirstThreeThenCount(t *testing.T) {
	sess, client, cleanup := newTestSession(t)
	defer cleanup()
	defer client.Close()

	var printed int
	for i := 0; i < 10; i++ {
		if sess.noisy("rejected_non_tg") {
			printed++
		}
	}
	if printed != 3 {
		t.Fatalf("напечатано %d, ожидалось 3", printed)
	}
	d := sess.noisyDetail()
	if !strings.Contains(d, "rejected_non_tg=10") {
		t.Fatalf("detail=%q, ожидалось rejected_non_tg=10", d)
	}
}

func TestHandleConnect_RejectLinesThrottled(t *testing.T) {
	m := withMemEvents(t)
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })

	sess, client, cleanup := newTestSession(t)
	defer cleanup()
	defer client.Close()
	go sess.writePump()

	payload := []byte{addrIPv4, 37, 193, 146, 91, 0x05, 0xA3} // 37.193.146.91:1443 — самонабор
	for i := 1; i <= 8; i++ {
		sess.handleConnect(uint16(i), payload)
	}
	if n := strings.Count(buf.String(), "rejected non-Telegram"); n != 3 {
		t.Fatalf("строк в логе %d, ожидалось 3", n)
	}
	if !m.wait("dial_fail", 8, time.Second) {
		t.Fatal("dial_fail должно быть 8 — события не троттлятся, только текст")
	}
	sess.killWith("peer_close")
	if d := sess.noisyDetail(); !strings.Contains(d, "rejected_non_tg=8") {
		t.Fatalf("detail=%q", d)
	}
}
