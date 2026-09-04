package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Стенд ядра: настоящий handleWS, поддельный клиент v1/v2, локальный
// «Telegram DC». Адресат в CONNECT остаётся телеграмовским (allowlist), а
// sessionDialFn ведёт его в локальный сервер: порт 443 — обработчик теста,
// порт 80 — «чёрная дыра» (net.Pipe, другой конец никто не читает), чтобы
// запись в DC гарантированно вставала.
const tgTarget = "149.154.167.50"

func withMemEvents(t *testing.T) *memEvents {
	t.Helper()
	prev := *eventsSink.Load().(*eventSink)
	m := &memEvents{}
	setEvents(m)
	t.Cleanup(func() { setEvents(prev) })
	return m
}

// testSmallSockBufs — сжать буферы сокетов WS до 8 КБ с обеих сторон.
// Тестам давления на память нужен клиент, который «не читает»: на Linux
// автонастройка tcp_rmem/tcp_wmem на loopback молча вбирает несколько МБ, и
// очередь релея не растёт, хотя клиент не читает ничего (GitHub CI, 02.09.2026).
var testSmallSockBufs atomic.Bool

func smallSocketBuffers(t *testing.T) {
	t.Helper()
	testSmallSockBufs.Store(true)
	t.Cleanup(func() { testSmallSockBufs.Store(false) })
}

type smallBufListener struct{ net.Listener }

func (l smallBufListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil {
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetWriteBuffer(8 * 1024)
			_ = tc.SetReadBuffer(8 * 1024)
		}
	}
	return c, err
}

func startRelay(t *testing.T) string {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleWS(ctx, w, r)
	}))
	if testSmallSockBufs.Load() {
		srv.Listener = smallBufListener{srv.Listener}
	}
	srv.Start()
	t.Cleanup(func() {
		cancel()
		srv.Close()
		// Хайджекнутые WS-соединения httptest не ждёт: сессии дописывают
		// закрытие уже после Close. Следующий тест не должен видеть их события.
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			n := 0
			forEachSession(func(*session) { n++ })
			if n == 0 {
				return
			}
			forEachSession(func(s *session) { s.killWith("test_cleanup") })
			time.Sleep(5 * time.Millisecond)
		}
		t.Errorf("сессии релея не завершились за 3 с")
	})
	return "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
}

func startFakeDC(t *testing.T, handler func(net.Conn)) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go handler(c)
		}
	}()
	prev := sessionDialFn
	var mu sync.Mutex
	var holes []net.Conn
	sessionDialFn = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if strings.HasSuffix(addr, ":80") {
			a, b := net.Pipe()
			mu.Lock()
			holes = append(holes, b)
			h := pipeDC
			mu.Unlock()
			if h != nil {
				go h(b)
			}
			return a, nil
		}
		return (&net.Dialer{}).DialContext(ctx, network, ln.Addr().String())
	}
	t.Cleanup(func() {
		sessionDialFn = prev
		pipeDC = nil
		ln.Close()
		mu.Lock()
		for _, h := range holes {
			h.Close()
		}
		mu.Unlock()
	})
}

// pipeDC — обработчик «DC» на синхронном pipe (порт 80). nil = чёрная дыра:
// другой конец никто не читает, запись у релея встаёт.
var pipeDC func(net.Conn)

func testInstall(t *testing.T) (string, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw := make([]byte, 16)
	_, _ = rand.Read(raw)
	id := hex.EncodeToString(raw)
	if reg == nil {
		initRegistry(t.TempDir() + "/registry.json")
	}
	reg.upsert(id, base64.StdEncoding.EncodeToString(pub))
	return id, priv
}

func connectPayload(ip string, port int) []byte {
	v4 := net.ParseIP(ip).To4()
	p := []byte{addrIPv4, v4[0], v4[1], v4[2], v4[3], 0, 0}
	binary.BigEndian.PutUint16(p[5:7], uint16(port))
	return p
}

func readFrame(t *testing.T, ws *websocket.Conn, timeout time.Duration) (uint16, byte, []byte) {
	t.Helper()
	_ = ws.SetReadDeadline(time.Now().Add(timeout))
	_, msg, err := ws.ReadMessage()
	if err != nil {
		t.Fatalf("readFrame: %v", err)
	}
	sid, mt, p, err := decodeFrame(msg)
	if err != nil {
		t.Fatal(err)
	}
	return sid, mt, p
}

// expectFrame читает, пропуская кадры других стримов/типов, до нужного.
func expectFrame(t *testing.T, ws *websocket.Conn, sid uint16, mt byte, timeout time.Duration) []byte {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		gotSID, gotMT, p := readFrame(t, ws, time.Until(deadline))
		if gotSID == sid && gotMT == mt {
			return p
		}
	}
	t.Fatalf("не дождались кадра sid=%d type=0x%02x", sid, mt)
	return nil
}

func dialWS(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	d := *websocket.DefaultDialer
	if testSmallSockBufs.Load() {
		d.NetDial = func(network, addr string) (net.Conn, error) {
			c, err := net.Dial(network, addr)
			if err == nil {
				if tc, ok := c.(*net.TCPConn); ok {
					_ = tc.SetWriteBuffer(8 * 1024)
					_ = tc.SetReadBuffer(8 * 1024)
				}
			}
			return c, err
		}
	}
	ws, _, err := d.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.Close() })
	return ws
}

// dialV1 — клиент до v2: первый кадр AUTHID из 88 байт.
func dialV1(t *testing.T, url, id string, priv ed25519.PrivateKey) *websocket.Conn {
	t.Helper()
	ws := dialWS(t, url)
	raw, _ := hex.DecodeString(id)
	msg := make([]byte, 24)
	copy(msg, raw)
	binary.BigEndian.PutUint64(msg[16:24], uint64(time.Now().Unix()))
	payload := append(msg, ed25519.Sign(priv, msg)...)
	sendFrame(t, ws, 0, muxAUTHID, payload)
	return ws
}

// dialV2 — полное рукопожатие v2, возвращает соединение после INFO AUTH_OK.
func dialV2(t *testing.T, url, id string, priv ed25519.PrivateKey, build string) (*websocket.Conn, helloAck) {
	t.Helper()
	ws := dialWS(t, url)
	return ws, handshakeV2Over(t, ws, id, priv, build)
}

// handshakeV2Over — рукопожатие v2 на уже открытом WS (TLS-фронт и т.п.).
// tsOverride — подписать метку времени не серверную, а свою (тест битых часов).
func handshakeV2Over(t *testing.T, ws *websocket.Conn, id string, priv ed25519.PrivateKey, build string, tsOverride ...int64) helloAck {
	t.Helper()
	h := append([]byte{protoVersion2, byte(len(build))}, build...)
	h = binary.BigEndian.AppendUint32(h, 0)
	sendFrame(t, ws, 0, muxHELLO, h)
	p := expectFrame(t, ws, 0, muxHELLO_ACK, 2*time.Second)
	ack, err := decodeHelloAck(p)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := hex.DecodeString(id)
	msg := make([]byte, 40)
	copy(msg, raw)
	ts := ack.ServerUnix
	if len(tsOverride) > 0 {
		ts = tsOverride[0]
	}
	binary.BigEndian.PutUint64(msg[16:24], uint64(ts))
	copy(msg[24:40], ack.Nonce[:])
	payload := append(msg, ed25519.Sign(priv, msg)...)
	sendFrame(t, ws, 0, muxAUTHID, payload)
	ip := expectFrame(t, ws, 0, muxINFO, 2*time.Second)
	k, _, _, _ := decodeInfo(ip)
	if k != infoAuthOK {
		t.Fatalf("после AUTHID v2 ожидался INFO AUTH_OK, получен kind=%d", k)
	}
	return ack
}

func mustURL(s string) *url.URL {
	u, err := url.Parse(s)
	if err != nil {
		panic(err)
	}
	return u
}

func sendFrame(t *testing.T, ws *websocket.Conn, sid uint16, mt byte, p []byte) {
	t.Helper()
	if err := ws.WriteMessage(websocket.BinaryMessage, encodeFrame(sid, mt, p)); err != nil {
		t.Fatal(err)
	}
}

// echoDC — «DC», который отдаёт назад всё, что получил, и закрывает по EOF.
func echoDC(c net.Conn) {
	defer c.Close()
	buf := make([]byte, 64*1024)
	for {
		n, err := c.Read(buf)
		if n > 0 {
			if _, werr := c.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// newTestSession — сессия над «сырой» WS-парой без рукопожатия: для тестов
// учёта установок, которым нужен *session с живым done-каналом.
func newTestSession(t *testing.T) (sess *session, client *websocket.Conn, cleanup func()) {
	t.Helper()
	upg := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	var serverWS *websocket.Conn
	ready := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upg.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("server upgrade: %v", err)
			return
		}
		serverWS = ws
		close(ready)
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
	sess = newSession(serverWS, "test", "127.0.0.1", context.Background())
	cleanup = func() {
		sess.kill()
		_ = client.Close()
		srv.Close()
	}
	return sess, client, cleanup
}

// TestMain — глобалы, которые в проде выставляет main().
func TestMain(m *testing.M) {
	dialThrottle = newDialLimiter(32, 3*time.Second)
	os.Exit(m.Run())
}
