package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// TestMain initializes the package-global dialThrottle so handleConnect-based
// tests can run without flag.Parse.
func TestMain(m *testing.M) {
	dialThrottle = newDialLimiter(8, 3*time.Second)
	m.Run()
}

type frameRecord struct {
	streamID uint16
	msgType  byte
	payload  string
}

func newTestSession(t *testing.T) (sess *session, client *websocket.Conn, cleanup func()) {
	t.Helper()
	upg := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

	var (
		serverWS *websocket.Conn
		ready    = make(chan struct{})
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upg.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("server upgrade: %v", err)
			return
		}
		serverWS = ws
		close(ready)
		// Hold the goroutine: read until close so we don't tear down underlying conn early.
		for {
			if _, _, err := ws.NextReader(); err != nil {
				return
			}
		}
	}))

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/"
	client, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		srv.Close()
		t.Fatalf("client dial: %v", err)
	}
	<-ready

	sess = newSession(serverWS, "test", context.Background())

	cleanup = func() {
		sess.kill()
		_ = client.Close()
		srv.Close()
	}
	return sess, client, cleanup
}

func readFrames(t *testing.T, ws *websocket.Conn, deadline time.Duration) []frameRecord {
	t.Helper()
	var got []frameRecord
	_ = ws.SetReadDeadline(time.Now().Add(deadline))
	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			// Includes deadline exceeded, EOF — gorilla panics if we read again.
			break
		}
		sid, mt, p, derr := decodeFrame(msg)
		if derr != nil {
			t.Errorf("decode: %v", derr)
			continue
		}
		got = append(got, frameRecord{sid, mt, string(p)})
	}
	return got
}

func TestEOFClose_PreservesTrailingData(t *testing.T) {
	sess, client, cleanup := newTestSession(t)
	defer cleanup()

	go sess.writePump()

	st := &stream{id: 42}
	sess.mu.Lock()
	sess.streams[42] = st
	sess.mu.Unlock()

	sess.sendData(st, []byte("A"))
	sess.sendData(st, []byte("B"))

	// Simulate EOF path from pumpReadFromTCP: detach from map, then ordered CLOSE.
	sess.mu.Lock()
	delete(sess.streams, 42)
	sess.mu.Unlock()
	sess.sendOrderedClose(st)

	got := readFrames(t, client, 500*time.Millisecond)
	want := []frameRecord{
		{42, muxDATA, "A"},
		{42, muxDATA, "B"},
		{42, muxCLOSE, ""},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("frame order broken\n got=%+v\nwant=%+v", got, want)
	}
}

func TestAbortClose_DropsPendingData(t *testing.T) {
	sess, client, cleanup := newTestSession(t)
	defer cleanup()

	st := &stream{id: 42}
	sess.mu.Lock()
	sess.streams[42] = st
	sess.mu.Unlock()

	// Enqueue two DATA frames before writePump starts so they pile up in writeCh.
	sess.sendData(st, []byte("A"))
	sess.sendData(st, []byte("B"))
	sess.sendAbort(st)
	sess.sendData(st, []byte("C")) // must be skipped (st.aborted == true)

	go sess.writePump()

	got := readFrames(t, client, 500*time.Millisecond)

	var dataCount, closeCount int
	for _, f := range got {
		if f.streamID != 42 {
			continue
		}
		switch f.msgType {
		case muxDATA:
			dataCount++
		case muxCLOSE:
			closeCount++
		}
	}
	if dataCount != 0 {
		t.Errorf("got %d DATA frames after abort, want 0; frames=%+v", dataCount, got)
	}
	if closeCount != 1 {
		t.Errorf("got %d CLOSE frames, want exactly 1; frames=%+v", closeCount, got)
	}
}

func TestAbortClose_Idempotent(t *testing.T) {
	sess, client, cleanup := newTestSession(t)
	defer cleanup()

	st := &stream{id: 7}
	sess.mu.Lock()
	sess.streams[7] = st
	sess.mu.Unlock()

	// Concurrent aborts must produce exactly one CLOSE frame.
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); sess.sendAbort(st) }()
	}
	wg.Wait()

	go sess.writePump()
	got := readFrames(t, client, 300*time.Millisecond)

	closeCount := 0
	for _, f := range got {
		if f.streamID == 7 && f.msgType == muxCLOSE {
			closeCount++
		}
	}
	if closeCount != 1 {
		t.Errorf("idempotent abort produced %d CLOSE frames, want 1", closeCount)
	}
}

func TestStreamReuse_CounterIsolated(t *testing.T) {
	sess, client, cleanup := newTestSession(t)
	defer cleanup()

	// st1: enqueue several DATA frames, then abort.
	st1 := &stream{id: 1}
	sess.mu.Lock()
	sess.streams[1] = st1
	sess.mu.Unlock()

	const payload1 = "xxxxxxxx" // 8 bytes
	for i := 0; i < 10; i++ {
		sess.sendData(st1, []byte(payload1))
	}
	bytesSt1 := st1.queuedBytes.Load()
	if bytesSt1 == 0 {
		t.Fatal("st1.queuedBytes should be > 0 before abort")
	}

	sess.sendAbort(st1) // st1 removed from map, aborted=true

	// st2: reuse id=1, enqueue more DATA frames.
	st2 := &stream{id: 1}
	sess.mu.Lock()
	sess.streams[1] = st2
	sess.mu.Unlock()

	const payload2 = "yyyy" // 4 bytes
	for i := 0; i < 5; i++ {
		sess.sendData(st2, []byte(payload2))
	}
	bytesSt2Before := st2.queuedBytes.Load()
	if bytesSt2Before == 0 {
		t.Fatal("st2.queuedBytes should be > 0 after reuse-enqueue")
	}

	// Drain: writePump decrements counters even for skipped (aborted) frames.
	go sess.writePump()
	_ = readFrames(t, client, 500*time.Millisecond)

	if got := st1.queuedBytes.Load(); got != 0 {
		t.Errorf("st1.queuedBytes after drain = %d, want 0 (decrement on skip path)", got)
	}
	if got := st2.queuedBytes.Load(); got != 0 {
		t.Errorf("st2.queuedBytes after drain = %d, want 0", got)
	}
}

func TestDialContextCancelOnKill(t *testing.T) {
	sess, _, cleanup := newTestSession(t)
	defer cleanup()

	go sess.writePump()

	started := make(chan struct{})
	returnedAt := make(chan time.Time, 1)
	sess.dialFn = func(ctx context.Context, network, addr string) (net.Conn, error) {
		close(started)
		<-ctx.Done()
		returnedAt <- time.Now()
		return nil, ctx.Err()
	}

	// 149.154.167.50 is in the Telegram allowlist.
	payload := []byte{addrIPv4, 149, 154, 167, 50, 0x01, 0xbb}
	go sess.handleConnect(7, payload)

	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("dialFn never invoked")
	}

	killAt := time.Now()
	sess.kill()

	select {
	case end := <-returnedAt:
		if elapsed := end.Sub(killAt); elapsed > 100*time.Millisecond {
			t.Errorf("dialFn returned %s after kill (want <100ms)", elapsed)
		}
	case <-time.After(time.Second):
		t.Fatal("dialFn did not return after session kill")
	}
}

func TestPeerCloseDropsPendingData(t *testing.T) {
	// closeStream() (peer-initiated muxCLOSE) sets aborted=true so any pending
	// DATA already in writeCh is dropped, and no extra CLOSE goes back.
	sess, client, cleanup := newTestSession(t)
	defer cleanup()

	st := &stream{id: 9, conn: nopConn{}}
	sess.mu.Lock()
	sess.streams[9] = st
	sess.mu.Unlock()

	sess.sendData(st, []byte("A"))
	sess.sendData(st, []byte("B"))
	sess.closeStream(9)

	go sess.writePump()
	got := readFrames(t, client, 300*time.Millisecond)

	for _, f := range got {
		if f.streamID == 9 {
			t.Errorf("peer-close path leaked frame to wire: %+v", f)
		}
	}
}

// nopConn is a minimal net.Conn for tests that need a non-nil conn but don't
// actually exchange bytes; closeStream() calls Close on it.
type nopConn struct{}

func (nopConn) Read(b []byte) (int, error)         { return 0, nil }
func (nopConn) Write(b []byte) (int, error)        { return len(b), nil }
func (nopConn) Close() error                       { return nil }
func (nopConn) LocalAddr() net.Addr                { return nil }
func (nopConn) RemoteAddr() net.Addr               { return nil }
func (nopConn) SetDeadline(t time.Time) error      { return nil }
func (nopConn) SetReadDeadline(t time.Time) error  { return nil }
func (nopConn) SetWriteDeadline(t time.Time) error { return nil }
