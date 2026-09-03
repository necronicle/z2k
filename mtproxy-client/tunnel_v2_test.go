package main

import (
	"context"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// fakeRelay — поддельный релей на httptest+gorilla. Говорит v2 (или
// отвергает его, если rejectV2), принимает CONNECT, отвечает CONNECT_OK с
// окном и складывает пришедшие DATA в recv. mu защищает ws-запись.
type fakeRelay struct {
	t        *testing.T
	srv      *httptest.Server
	rejectV2 bool
	window   uint32

	client   *tunnelClient // кого ждёт waitReady
	mu       sync.Mutex
	ws       *websocket.Conn
	proto    atomic.Int32 // 1 или 2, версия последней сессии
	sessions atomic.Int32
	recv     chan muxFrame
	ready    chan struct{}
}

func newFakeRelay(t *testing.T) *fakeRelay {
	fr := &fakeRelay{t: t, window: 8192, recv: make(chan muxFrame, 1024), ready: make(chan struct{}, 8)}
	up := websocket.Upgrader{}
	fr.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		fr.serve(ws)
	}))
	t.Cleanup(fr.srv.Close)
	return fr
}

func (fr *fakeRelay) send(f []byte) {
	fr.mu.Lock()
	defer fr.mu.Unlock()
	if fr.ws != nil {
		fr.ws.WriteMessage(websocket.BinaryMessage, f)
	}
}

func (fr *fakeRelay) serve(ws *websocket.Conn) {
	defer ws.Close()
	fr.sessions.Add(1)
	_, msg, err := ws.ReadMessage()
	if err != nil {
		return
	}
	f, _ := decodeMuxFrame(msg)
	switch f.MsgType {
	case muxHELLO:
		if fr.rejectV2 {
			// релей старой сборки: GOODBYE(protocol)
			ws.WriteMessage(websocket.BinaryMessage, encodeMuxFrame(0, muxINFO, append(append([]byte{infoGoodbye}, 0, 0, 0, rProtocol), "v2 off"...)))
			return
		}
		var ack []byte
		ack = append(ack, protoVersion2)
		ack = binary.BigEndian.AppendUint64(ack, uint64(time.Now().Unix()+100)) // часы релея на 100 с вперёд
		nonce := []byte("0123456789abcdef")
		ack = append(ack, nonce...)
		ack = append(ack, 0)
		ack = binary.BigEndian.AppendUint32(ack, fr.window)
		ack = binary.BigEndian.AppendUint32(ack, 0)
		ws.WriteMessage(websocket.BinaryMessage, encodeMuxFrame(0, muxHELLO_ACK, ack))
		_, msg, err = ws.ReadMessage()
		if err != nil {
			return
		}
		f, _ = decodeMuxFrame(msg)
		if f.MsgType != muxAUTHID || len(f.Payload) != 104 {
			fr.t.Errorf("ожидался AUTHID v2 (104 байта), пришло type=0x%02x len=%d", f.MsgType, len(f.Payload))
			return
		}
		ts := int64(binary.BigEndian.Uint64(f.Payload[16:24]))
		if d := ts - (time.Now().Unix() + 100); d < -2 || d > 2 {
			fr.t.Errorf("ts в подписи не учёл поправку часов: разница %d с", d)
		}
		if string(f.Payload[24:40]) != string(nonce) {
			fr.t.Errorf("nonce не вернулся")
		}
		ws.WriteMessage(websocket.BinaryMessage, encodeMuxFrame(0, muxINFO, []byte{infoAuthOK, 0, 0, 0, 0}))
		fr.proto.Store(2)
	case muxAUTHID:
		if len(f.Payload) != 88 {
			fr.t.Errorf("AUTHID v1 должен быть 88 байт, пришло %d", len(f.Payload))
		}
		fr.proto.Store(1)
	default:
		fr.t.Errorf("первый кадр 0x%02x", f.MsgType)
		return
	}
	fr.mu.Lock()
	fr.ws = ws
	fr.mu.Unlock()
	fr.ready <- struct{}{}
	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			fr.mu.Lock()
			fr.ws = nil
			fr.mu.Unlock()
			return
		}
		f, err := decodeMuxFrame(msg)
		if err != nil {
			continue
		}
		if f.MsgType == muxCONNECT {
			var p []byte
			if fr.proto.Load() == 2 {
				p = binary.BigEndian.AppendUint32(nil, fr.window)
			}
			fr.send(encodeMuxFrame(f.StreamID, muxCONNECT_OK, p))
			continue
		}
		fr.recv <- f
	}
}

func (fr *fakeRelay) wsURL() string { return "ws" + strings.TrimPrefix(fr.srv.URL, "http") + "/ws" }

// newTestClient — клиент с зарегистрированной личностью, без identityLoop.
func newTestClient(t *testing.T, fr *fakeRelay) *tunnelClient {
	t.Helper()
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096) // общий на все тесты: горутины прошлого теста ещё отпускают слоты
	}
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	tc := &tunnelClient{tunnelURL: fr.wsURL(), tunnelSecret: "x", connectSem: make(chan struct{}, 6)}
	tc.ctx, tc.cancel = context.WithCancel(context.Background())
	t.Cleanup(tc.cancel)
	tc.identity.Store(id)
	tc.useID.Store(true)
	fr.client = tc
	return tc
}

// waitReady — релей завершил рукопожатие И клиент выставил писателя: до
// этого openStream отбрасывает соединения («WS не поднят»). На GitHub (Linux)
// тест обгонял клиента и стрим не открывался.
func waitReady(t *testing.T, fr *fakeRelay) {
	t.Helper()
	select {
	case <-fr.ready:
	case <-time.After(5 * time.Second):
		t.Fatal("релей не дождался сессии")
	}
	tc := fr.client
	for i := 0; i < 500; i++ {
		tc.mu.Lock()
		w := tc.writer
		tc.mu.Unlock()
		if w != nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("клиент не выставил писателя после рукопожатия")
}

// pipePair — «телефон»: слушатель на loopback, клиентская сторона теста.
func phonePair(t *testing.T) (*net.TCPConn, net.Conn) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	done := make(chan *net.TCPConn, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			done <- nil
			return
		}
		done <- c.(*net.TCPConn)
	}()
	phone, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	srv := <-done
	if srv == nil {
		t.Fatal("accept")
	}
	connSemaphore <- struct{}{}
	return srv, phone
}

func open(t *testing.T, tc *tunnelClient, conn *net.TCPConn) *tunnelStream {
	t.Helper()
	tc.openStream(conn, net.IPv4(149, 154, 167, 51), 443)
	var st *tunnelStream
	deadline := time.Now().Add(3 * time.Second)
	for st == nil && time.Now().Before(deadline) {
		tc.streams.Range(func(k, v any) bool {
			s := v.(*tunnelStream)
			if s.conn == conn {
				st = s
			}
			return true
		})
		if st == nil {
			time.Sleep(5 * time.Millisecond)
		}
	}
	if st == nil {
		t.Fatal("стрим не открылся")
	}
	for i := 0; i < 300 && !st.writing.Load(); i++ {
		time.Sleep(10 * time.Millisecond) // дождаться CONNECT_OK
	}
	if !st.writing.Load() {
		t.Fatal("CONNECT_OK не пришёл")
	}
	return st
}

func recvFrame(t *testing.T, fr *fakeRelay, typ byte) muxFrame {
	t.Helper()
	select {
	case f := <-fr.recv:
		if f.MsgType != typ {
			t.Fatalf("ожидался кадр 0x%02x, пришёл 0x%02x", typ, f.MsgType)
		}
		return f
	case <-time.After(3 * time.Second):
		t.Fatalf("кадр 0x%02x не пришёл", typ)
	}
	return muxFrame{}
}

func TestHandshakeV2HappyPath(t *testing.T) {
	fr := newFakeRelay(t)
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	for i := 0; i < 100 && !tc.v2.Load(); i++ {
		time.Sleep(10 * time.Millisecond) // клиент дочитывает INFO AUTH_OK
	}
	if fr.proto.Load() != 2 || !tc.v2.Load() {
		t.Fatal("сессия не v2")
	}
	if off := tc.clockOffset.Load(); off < 98 || off > 102 {
		t.Fatalf("поправка часов %d, ожидалось ~100", off)
	}
	if tc.window.Load() != 8192 {
		t.Fatalf("окно %d", tc.window.Load())
	}
	// данные телефон→релей→телефон
	srv, phone := phonePair(t)
	defer phone.Close()
	st := open(t, tc, srv)
	if _, err := phone.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	f := recvFrame(t, fr, muxDATA)
	if string(f.Payload) != "hello" || f.StreamID != st.id {
		t.Fatalf("DATA %q sid=%d", f.Payload, f.StreamID)
	}
	fr.send(encodeMuxFrame(st.id, muxDATA, []byte("world")))
	buf := make([]byte, 16)
	phone.SetReadDeadline(time.Now().Add(3 * time.Second))
	n, err := phone.Read(buf)
	if err != nil || string(buf[:n]) != "world" {
		t.Fatalf("телефон получил %q %v", buf[:n], err)
	}
	if st.semHeld.Load() {
		t.Fatal("connectSem не отпущен после CONNECT_OK")
	}
}

func TestFallbackToV1OnProtocolGoodbye(t *testing.T) {
	fr := newFakeRelay(t)
	fr.rejectV2 = true
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	if fr.proto.Load() != 1 || tc.v2.Load() || !tc.forceV1.Load() {
		t.Fatalf("после GOODBYE(protocol) ожидался v1: proto=%d v2=%v forceV1=%v", fr.proto.Load(), tc.v2.Load(), tc.forceV1.Load())
	}
	if fr.sessions.Load() != 2 {
		t.Fatalf("сессий %d, ожидалось 2 (v2 отвергнута, v1 принята)", fr.sessions.Load())
	}
	// v1: CONNECT_OK без окна, данные ходят без кредита
	srv, phone := phonePair(t)
	defer phone.Close()
	st := open(t, tc, srv)
	phone.Write([]byte("v1"))
	f := recvFrame(t, fr, muxDATA)
	if string(f.Payload) != "v2"[:0]+"v1" || f.StreamID != st.id {
		t.Fatal("DATA по v1")
	}
}

func TestCreditBlocksSendUntilWindow(t *testing.T) {
	fr := newFakeRelay(t)
	fr.window = 1000
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	srv, phone := phonePair(t)
	defer phone.Close()
	st := open(t, tc, srv)
	big := make([]byte, 2500)
	go phone.Write(big)
	var got int
	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case f := <-fr.recv:
			got += len(f.Payload)
		case <-time.After(100 * time.Millisecond):
		}
	}
	if got != 1000 {
		t.Fatalf("без кредита ушло %d байт, ожидалось ровно окно 1000", got)
	}
	fr.send(encodeMuxFrame(st.id, muxWINDOW, encodeWindow(1500)))
	deadline = time.Now().Add(2 * time.Second)
	for got < 2500 && time.Now().Before(deadline) {
		select {
		case f := <-fr.recv:
			got += len(f.Payload)
		case <-time.After(100 * time.Millisecond):
		}
	}
	if got != 2500 {
		t.Fatalf("после WINDOW ушло %d, ожидалось 2500", got)
	}
}

func TestWindowGrantedAfterHalfConsumed(t *testing.T) {
	fr := newFakeRelay(t)
	fr.window = 1000
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	srv, phone := phonePair(t)
	defer phone.Close()
	st := open(t, tc, srv)
	fr.send(encodeMuxFrame(st.id, muxDATA, make([]byte, 400)))
	select {
	case f := <-fr.recv:
		t.Fatalf("WINDOW раньше половины окна: 0x%02x", f.MsgType)
	case <-time.After(200 * time.Millisecond):
	}
	buf := make([]byte, 4096)
	phone.SetReadDeadline(time.Now().Add(2 * time.Second))
	phone.Read(buf)
	fr.send(encodeMuxFrame(st.id, muxDATA, make([]byte, 200)))
	phone.Read(buf)
	f := recvFrame(t, fr, muxWINDOW)
	c, _ := decodeWindow(f.Payload)
	if c != 600 {
		t.Fatalf("WINDOW на %d, ожидалось 600", c)
	}
}

// Медленный телефон не должен останавливать соседа: раньше readLoop писал в
// сокет телефона синхронно, и уснувший приёмник стопорил всю сессию.
func TestSlowPhoneDoesNotBlockNeighbour(t *testing.T) {
	fr := newFakeRelay(t)
	fr.window = 1 << 20
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	slowSrv, slowPhone := phonePair(t)
	defer slowPhone.Close()
	fastSrv, fastPhone := phonePair(t)
	defer fastPhone.Close()
	slow := open(t, tc, slowSrv)
	fast := open(t, tc, fastSrv)
	// забить медленного: он не читает, буферы сокета кончаются
	chunk := make([]byte, 64*1024)
	for i := 0; i < 16; i++ {
		fr.send(encodeMuxFrame(slow.id, muxDATA, chunk))
	}
	fr.send(encodeMuxFrame(fast.id, muxDATA, []byte("ping")))
	buf := make([]byte, 16)
	fastPhone.SetReadDeadline(time.Now().Add(3 * time.Second))
	n, err := fastPhone.Read(buf)
	if err != nil || string(buf[:n]) != "ping" {
		t.Fatalf("сосед медленного телефона не получил данные: %q %v", buf[:n], err)
	}
}

func TestRetryAfterOverridesBackoff(t *testing.T) {
	fr := newFakeRelay(t)
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	fr.send(encodeMuxFrame(0, muxINFO, append([]byte{infoRetryAfter}, 0, 0, 0, 60)))
	time.Sleep(100 * time.Millisecond)
	if tc.retryAfter.Load() != maxRetryAfterSec {
		t.Fatalf("RETRY_AFTER 60 должен резаться до %d, получено %d", maxRetryAfterSec, tc.retryAfter.Load())
	}
	fr.send(encodeMuxFrame(0, muxINFO, append([]byte{infoRetryAfter}, 0, 0, 0, 2)))
	time.Sleep(100 * time.Millisecond)
	if tc.retryAfter.Load() != 2 {
		t.Fatalf("retryAfter=%d", tc.retryAfter.Load())
	}
	fr.mu.Lock()
	ws := fr.ws
	fr.mu.Unlock()
	t0 := time.Now()
	ws.Close()
	waitReady(t, fr)
	if d := time.Since(t0); d < 1400*time.Millisecond || d > 2700*time.Millisecond {
		t.Fatalf("переподключение через %s, ожидалось 2 с ±30 %%", d)
	}
}

func TestJitterRange(t *testing.T) {
	for i := 0; i < 1000; i++ {
		d := jitter(10 * time.Second)
		if d < 7*time.Second || d > 13*time.Second {
			t.Fatalf("jitter %s вне [7;13] с", d)
		}
	}
	if backoffFor(1) != 3*time.Second || backoffFor(3) != 10*time.Second || backoffFor(5) != 30*time.Second || backoffFor(10) != 120*time.Second {
		t.Fatal("ступени backoff")
	}
}

func TestConnectSemReleasedOnLocalClose(t *testing.T) {
	fr := newFakeRelay(t)
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	for i := 0; i < 8; i++ {
		srv, phone := phonePair(t)
		st := open(t, tc, srv)
		phone.Close()
		deadline := time.Now().Add(2 * time.Second)
		for st.semHeld.Load() && time.Now().Before(deadline) {
			time.Sleep(5 * time.Millisecond)
		}
		if st.semHeld.Load() {
			t.Fatalf("слот connectSem утёк на стриме %d", st.id)
		}
	}
	if len(tc.connectSem) != 0 {
		t.Fatalf("в connectSem осталось %d слотов", len(tc.connectSem))
	}
}

// DATA и сразу CLOSE от релея — типичный короткий HTTP-ответ: сервер ответил
// и закрыл. Данные обязаны дойти до телефона раньше, чем закроется сокет.
func TestDataBeforeCloseIsDelivered(t *testing.T) {
	fr := newFakeRelay(t)
	tc := newTestClient(t, fr)
	go tc.run()
	waitReady(t, fr)
	for i := 0; i < 20; i++ {
		srv, phone := phonePair(t)
		st := open(t, tc, srv)
		body := make([]byte, 3000)
		fr.send(encodeMuxFrame(st.id, muxDATA, body))
		fr.send(encodeMuxFrame(st.id, muxCLOSE, nil))
		phone.SetReadDeadline(time.Now().Add(3 * time.Second))
		var got int
		buf := make([]byte, 4096)
		for {
			n, err := phone.Read(buf)
			got += n
			if err != nil {
				break
			}
		}
		phone.Close()
		if got != 3000 {
			t.Fatalf("попытка %d: телефон получил %d байт из 3000 перед закрытием", i, got)
		}
	}
}
