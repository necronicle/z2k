// vps-relay: TCP-over-WebSocket relay for the z2k tunnel client.
//
// Wire protocol (identical to cf-worker/worker.js):
//   [streamId u16 BE][msgType u8][payload]
//   Types: AUTH=0x00, CONNECT=0x01, DATA=0x02, CLOSE=0x03,
//          CONNECT_OK=0x04, CONNECT_FAIL=0x05
//   Auth:  streamId=0, type=0x00, payload = HMAC-SHA256(secret, secret) (32 bytes)
//   CONNECT payload: [addr_type u8][addr][port u16 BE]
//     addr_type 1 = IPv4 (4 bytes), 4 = IPv6 (16 bytes)
//
// No CF-style constraints: no 6-socket cap, no 10ms CPU limit, sessions
// live as long as the WebSocket stays up.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	muxAUTH         byte = 0x00
	muxCONNECT      byte = 0x01
	muxDATA         byte = 0x02
	muxCLOSE        byte = 0x03
	muxCONNECT_OK   byte = 0x04
	muxCONNECT_FAIL byte = 0x05

	addrIPv4 = 1
	addrIPv6 = 4
)

var (
	listenAddr = flag.String("listen", ":8080", "HTTP listen address (TLS terminated upstream by Caddy)")
	secret     = flag.String("secret", "", "shared HMAC secret (must match tunnel client)")
	verbose    = flag.Bool("v", false, "verbose logging")
)

// Telegram DC allowlist — same ranges the CF worker accepts.
var telegramV4 []netRange
var telegramV6Prefixes = []string{"2001:b28:f23d:", "2001:b28:f23f:", "2001:67c:4e8:"}

type netRange struct {
	net  uint32
	mask uint32
}

func init() {
	cidrs := []string{
		"149.154.160.0/20",
		"91.108.4.0/22",
		"91.108.8.0/22",
		"91.108.12.0/22",
		"91.108.16.0/22",
		"91.108.20.0/22",
		"91.108.56.0/22",
		"91.105.192.0/23",
		"95.161.64.0/20",
		"185.76.151.0/24",
	}
	for _, c := range cidrs {
		_, ipnet, err := net.ParseCIDR(c)
		if err != nil {
			panic(err)
		}
		v4 := ipnet.IP.To4()
		mask := binary.BigEndian.Uint32(ipnet.Mask)
		telegramV4 = append(telegramV4, netRange{
			net:  binary.BigEndian.Uint32(v4),
			mask: mask,
		})
	}
}

func isTelegramAddr(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if v4 := ip.To4(); v4 != nil {
		u := binary.BigEndian.Uint32(v4)
		for _, r := range telegramV4 {
			if u&r.mask == r.net {
				return true
			}
		}
		return false
	}
	// IPv6 prefix match
	s := ip.String()
	for _, p := range telegramV6Prefixes {
		if len(s) >= len(p) && s[:len(p)] == p {
			return true
		}
	}
	return false
}

func computeAuthHMAC(secret string) []byte {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(secret))
	return m.Sum(nil)
}

func encodeFrame(streamID uint16, msgType byte, payload []byte) []byte {
	buf := make([]byte, 3+len(payload))
	binary.BigEndian.PutUint16(buf[0:2], streamID)
	buf[2] = msgType
	if len(payload) > 0 {
		copy(buf[3:], payload)
	}
	return buf
}

func decodeFrame(data []byte) (streamID uint16, msgType byte, payload []byte, err error) {
	if len(data) < 3 {
		err = fmt.Errorf("frame too short: %d", len(data))
		return
	}
	streamID = binary.BigEndian.Uint16(data[0:2])
	msgType = data[2]
	payload = data[3:]
	return
}

func parseConnectPayload(p []byte) (addr string, port int, err error) {
	if len(p) < 1 {
		return "", 0, fmt.Errorf("empty")
	}
	switch p[0] {
	case addrIPv4:
		if len(p) < 7 {
			return "", 0, fmt.Errorf("short v4")
		}
		addr = fmt.Sprintf("%d.%d.%d.%d", p[1], p[2], p[3], p[4])
		port = int(binary.BigEndian.Uint16(p[5:7]))
	case addrIPv6:
		if len(p) < 19 {
			return "", 0, fmt.Errorf("short v6")
		}
		ip := make(net.IP, 16)
		copy(ip, p[1:17])
		addr = ip.String()
		port = int(binary.BigEndian.Uint16(p[17:19]))
	default:
		return "", 0, fmt.Errorf("unknown addr type %d", p[0])
	}
	return
}

// session holds all state for one WS connection.
type session struct {
	id      string
	ws      *websocket.Conn
	writeCh chan []byte
	done    chan struct{}
	once    sync.Once

	mu      sync.Mutex
	streams map[uint16]*stream
}

type stream struct {
	id     uint16
	conn   net.Conn
	closed bool
}

func newSession(ws *websocket.Conn, id string) *session {
	return &session{
		id:      id,
		ws:      ws,
		writeCh: make(chan []byte, 512),
		done:    make(chan struct{}),
		streams: make(map[uint16]*stream),
	}
}

func (s *session) kill() {
	s.once.Do(func() {
		close(s.done)
		_ = s.ws.Close()
		s.mu.Lock()
		for _, st := range s.streams {
			if st.conn != nil {
				_ = st.conn.Close()
			}
			st.closed = true
		}
		s.streams = nil
		s.mu.Unlock()
	})
}

func (s *session) send(frame []byte) {
	select {
	case s.writeCh <- frame:
	case <-s.done:
	default:
		// Writer backpressure: drop the session if we can't keep up.
		log.Printf("[%s] writeCh full, killing session", s.id)
		go s.kill()
	}
}

func (s *session) writePump() {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case frame := <-s.writeCh:
			_ = s.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := s.ws.WriteMessage(websocket.BinaryMessage, frame); err != nil {
				if *verbose {
					log.Printf("[%s] write err: %v", s.id, err)
				}
				s.kill()
				return
			}
		case <-ticker.C:
			_ = s.ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if err := s.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				s.kill()
				return
			}
		case <-s.done:
			return
		}
	}
}

func (s *session) closeStream(id uint16) {
	s.mu.Lock()
	st, ok := s.streams[id]
	if ok {
		delete(s.streams, id)
	}
	s.mu.Unlock()
	if ok && st.conn != nil {
		_ = st.conn.Close()
	}
}

func (s *session) handleConnect(id uint16, payload []byte) {
	addr, port, err := parseConnectPayload(payload)
	if err != nil {
		if *verbose {
			log.Printf("[%s] stream %d bad CONNECT: %v", s.id, id, err)
		}
		s.send(encodeFrame(id, muxCONNECT_FAIL, nil))
		return
	}
	if !isTelegramAddr(addr) {
		log.Printf("[%s] stream %d rejected non-Telegram target %s:%d", s.id, id, addr, port)
		s.send(encodeFrame(id, muxCONNECT_FAIL, nil))
		return
	}

	target := net.JoinHostPort(addr, strconv.Itoa(port))
	t0 := time.Now()
	conn, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		log.Printf("[%s] stream %d dial %s failed: %v", s.id, id, target, err)
		s.send(encodeFrame(id, muxCONNECT_FAIL, nil))
		return
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(60 * time.Second)
	}

	st := &stream{id: id, conn: conn}
	s.mu.Lock()
	if s.streams == nil {
		s.mu.Unlock()
		_ = conn.Close()
		return
	}
	if old, exists := s.streams[id]; exists && old.conn != nil {
		_ = old.conn.Close()
	}
	s.streams[id] = st
	active := len(s.streams)
	s.mu.Unlock()

	if *verbose {
		log.Printf("[%s] stream %d CONNECT %s:%d ok (%s) active=%d", s.id, id, addr, port, time.Since(t0), active)
	}
	s.send(encodeFrame(id, muxCONNECT_OK, nil))

	// Pump TCP → WS
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				// Copy because frame buffer outlives the read buf slice.
				payload := make([]byte, n)
				copy(payload, buf[:n])
				s.send(encodeFrame(id, muxDATA, payload))
			}
			if err != nil {
				break
			}
		}
		// Signal EOF to peer
		s.mu.Lock()
		_, still := s.streams[id]
		if still {
			delete(s.streams, id)
		}
		s.mu.Unlock()
		if still {
			s.send(encodeFrame(id, muxCLOSE, nil))
		}
		_ = conn.Close()
	}()
}

func (s *session) readPump() {
	defer s.kill()

	s.ws.SetReadLimit(4 * 1024 * 1024)
	_ = s.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
	s.ws.SetPongHandler(func(string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
		return nil
	})
	s.ws.SetPingHandler(func(data string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
		return s.ws.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(5*time.Second))
	})

	// Require auth frame first.
	_, msg, err := s.ws.ReadMessage()
	if err != nil {
		if *verbose {
			log.Printf("[%s] auth read err: %v", s.id, err)
		}
		return
	}
	sid, mt, p, err := decodeFrame(msg)
	if err != nil || sid != 0 || mt != muxAUTH {
		log.Printf("[%s] first message not auth (sid=%d type=0x%02x)", s.id, sid, mt)
		return
	}
	expected := computeAuthHMAC(*secret)
	if subtle.ConstantTimeCompare(p, expected) != 1 {
		log.Printf("[%s] auth HMAC mismatch", s.id)
		return
	}
	log.Printf("[%s] authenticated", s.id)

	for {
		_, msg, err := s.ws.ReadMessage()
		if err != nil {
			if *verbose {
				log.Printf("[%s] read err: %v", s.id, err)
			}
			return
		}
		sid, mt, payload, err := decodeFrame(msg)
		if err != nil {
			if *verbose {
				log.Printf("[%s] bad frame: %v", s.id, err)
			}
			continue
		}

		switch mt {
		case muxCONNECT:
			go s.handleConnect(sid, payload)
		case muxDATA:
			s.mu.Lock()
			st, ok := s.streams[sid]
			s.mu.Unlock()
			if !ok || st.conn == nil {
				// Silent drop — classic mux race, client closed locally.
				continue
			}
			if _, err := st.conn.Write(payload); err != nil {
				if *verbose {
					log.Printf("[%s] stream %d tcp write err: %v", s.id, sid, err)
				}
				s.closeStream(sid)
				s.send(encodeFrame(sid, muxCLOSE, nil))
			}
		case muxCLOSE:
			s.closeStream(sid)
		default:
			if *verbose {
				log.Printf("[%s] unknown msg type 0x%02x stream=%d", s.id, mt, sid)
			}
		}
	}
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:    128 * 1024,
	WriteBufferSize:   128 * 1024,
	CheckOrigin:       func(r *http.Request) bool { return true },
	EnableCompression: false,
}

func makeSessionID() string {
	return strconv.FormatInt(time.Now().UnixNano()%100000, 36)
}

func handleWS(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/ws" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if r.Header.Get("Upgrade") != "websocket" {
		http.Error(w, "Expected WebSocket", http.StatusUpgradeRequired)
		return
	}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade err: %v", err)
		return
	}
	sid := makeSessionID()
	ip := r.Header.Get("X-Forwarded-For")
	if ip == "" {
		ip = r.RemoteAddr
	}
	log.Printf("[%s] WS accepted from %s", sid, ip)
	s := newSession(ws, sid)
	go s.writePump()
	s.readPump()
	log.Printf("[%s] WS closed", sid)
}

func main() {
	flag.Parse()
	if *secret == "" {
		log.Fatal("--secret is required")
	}

	http.HandleFunc("/ws", handleWS)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "z2k vps-relay")
	})

	srv := &http.Server{
		Addr:              *listenAddr,
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		<-ctx.Done()
		sdCtx, sdCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer sdCancel()
		_ = srv.Shutdown(sdCtx)
	}()

	log.Printf("z2k vps-relay listening on %s", *listenAddr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
