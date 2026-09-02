package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func withMemEvents(t *testing.T) *memEvents {
	t.Helper()
	prev := events
	m := &memEvents{}
	events = m
	t.Cleanup(func() { events = prev })
	return m
}

// newHandleWSServer поднимает настоящий handleWS за httptest.
func newHandleWSServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleWS(ctx, w, r)
	}))
	t.Cleanup(cancel)
	return srv, "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
}

func TestSessionClose_ReasonFromKillWith(t *testing.T) {
	sess, client, cleanup := newTestSession(t)
	defer cleanup()
	defer client.Close()
	go sess.writePump()

	sess.killWith("session_queue")
	sess.killWith("ping_failed") // второй вызов не перезаписывает причину
	if got := sess.closeReason(); got != "session_queue" {
		t.Fatalf("причина: %q, ожидалась session_queue", got)
	}
}

func TestHandleWS_EmitsOpenAndCloseWithReason(t *testing.T) {
	m := withMemEvents(t)
	srv, wsURL := newHandleWSServer(t)
	defer srv.Close()

	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !m.wait("session_open", 1, 2*time.Second) {
		t.Fatal("нет session_open")
	}
	// Первый кадр — не auth: релей закрывает с причиной first_not_auth.
	if err := ws.WriteMessage(websocket.BinaryMessage, encodeFrame(1, muxDATA, []byte("x"))); err != nil {
		t.Fatal(err)
	}
	if !m.wait("session_close", 1, 2*time.Second) {
		t.Fatal("нет session_close")
	}
	ev := m.byEv("session_close")[0]
	if ev.Reason != "first_not_auth" {
		t.Fatalf("reason=%q, ожидалось first_not_auth", ev.Reason)
	}
	if ev.SID == "" || ev.IP == "" || ev.Proto != "v1" {
		t.Fatalf("в событии нет sid/ip/proto: %+v", ev)
	}
	open := m.byEv("session_open")[0]
	if open.SID != ev.SID {
		t.Fatalf("sid открытия %q и закрытия %q различаются", open.SID, ev.SID)
	}
	_ = ws.Close()
}

func TestHandleWS_ReadTimeoutReason(t *testing.T) {
	if testing.Short() {
		t.Skip("ждёт настоящий таймаут чтения")
	}
	m := withMemEvents(t)
	prev := *authReadTimeout
	*authReadTimeout = 300 * time.Millisecond
	t.Cleanup(func() { *authReadTimeout = prev })

	srv, wsURL := newHandleWSServer(t)
	defer srv.Close()
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	if !m.wait("session_close", 1, 3*time.Second) {
		t.Fatal("нет session_close после таймаута")
	}
	if r := m.byEv("session_close")[0].Reason; !strings.HasPrefix(r, "auth_read_err") {
		t.Fatalf("reason=%q, ожидался auth_read_err", r)
	}
}

func TestStreamEvents_EOFClose(t *testing.T) {
	m := withMemEvents(t)
	sess, client, cleanup := newTestSession(t)
	defer cleanup()
	go sess.writePump()

	// Настоящий TCP-апстрим: сервер отдаёт байты и закрывает.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		_, _ = c.Write([]byte("hello"))
		_ = c.Close()
	}()
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	st := &stream{id: 7, conn: conn, opened: time.Now(), target: ln.Addr().String()}
	sess.mu.Lock()
	sess.streams[7] = st
	sess.mu.Unlock()
	events.Emit(Event{Ev: "stream_open", SID: sess.id, Detail: st.target})
	go sess.pumpReadFromTCP(st)

	frames := readFrames(t, client, 2*time.Second)
	var sawClose bool
	for _, f := range frames {
		if f.msgType == muxCLOSE && f.streamID == 7 {
			sawClose = true
		}
	}
	if !sawClose {
		t.Fatal("клиент не получил CLOSE после EOF апстрима")
	}
	if !m.wait("stream_close", 1, time.Second) {
		t.Fatal("нет события stream_close")
	}
	ev := m.byEv("stream_close")[0]
	if ev.Reason != "eof" || ev.Detail != st.target || ev.SID != sess.id {
		t.Fatalf("stream_close неверен: %+v", ev)
	}
}

func TestStreamEvents_AbortReason(t *testing.T) {
	m := withMemEvents(t)
	sess, client, cleanup := newTestSession(t)
	defer cleanup()
	defer client.Close()
	go sess.writePump()
	st := &stream{id: 3, conn: nopConn{}, opened: time.Now(), target: "149.154.167.50:443"}
	sess.mu.Lock()
	sess.streams[3] = st
	sess.mu.Unlock()
	sess.sendAbort(st)
	sess.sendAbort(st) // повтор не даёт второго события
	if !m.wait("stream_close", 1, time.Second) {
		t.Fatal("нет stream_close после abort")
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(m.byEv("stream_close")); n != 1 {
		t.Fatalf("stream_close должно быть одно, получено %d", n)
	}
	if r := m.byEv("stream_close")[0].Reason; r != "abort" {
		t.Fatalf("reason=%q, ожидалось abort", r)
	}
}
