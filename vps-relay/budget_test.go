package main

import (
	"bytes"
	"net"
	"testing"
	"time"
)

// Бюджет: три стрима копят данные к клиенту, который не читает; при
// превышении high режется самый тяжёлый — сессия жива, событие budget_trim.
func TestBudget_TrimsHeaviestStreamNotSession(t *testing.T) {
	m := withMemEvents(t)
	smallSocketBuffers(t) // иначе ядро на loopback вбирает всё, что клиент «не читает»
	budget.setLimit(256 * 1024) // high = 100 КБ, low = 75 КБ
	t.Cleanup(func() { budget.setLimit(0) })
	stop := make(chan struct{})
	go budget.trimLoop(20*time.Millisecond, stop)
	t.Cleanup(func() { close(stop) })

	big := bytes.Repeat([]byte("B"), 300*1024)
	startFakeDC(t, func(c net.Conn) { c.Write(big); time.Sleep(3 * time.Second); c.Close() })
	url := startRelay(t)
	id, priv := testInstall(t)
	ws, _ := dialV2(t, url, id, priv, "r-82")
	// Клиент даёт большие окна и не читает данные.
	for _, sid := range []uint16{1, 2, 3} {
		sendFrame(t, ws, sid, muxCONNECT, connectPayload(tgTarget, 443))
		sendFrame(t, ws, sid, muxWINDOW, encodeWindow(1<<20))
	}
	if !m.wait("budget_trim", 1, 3*time.Second) {
		t.Fatal("нет budget_trim")
	}
	var trimmed int
	for _, e := range m.byEv("stream_close") {
		if e.Reason == "queue_limit" {
			trimmed++
		}
	}
	if trimmed == 0 {
		t.Fatal("ни один стрим не срезан с причиной queue_limit")
	}
	if n := len(m.byEv("session_close")); n != 0 {
		t.Fatalf("сессия закрыта (%d) — бюджет обязан резать стримы, не сессии", n)
	}
}
