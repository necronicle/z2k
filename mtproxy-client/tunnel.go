package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

// ---------- Mux wire protocol ----------

const (
	muxAUTH         = 0x00
	muxCONNECT      = 0x01
	muxDATA         = 0x02
	muxCLOSE        = 0x03
	muxCONNECT_OK   = 0x04
	muxCONNECT_FAIL = 0x05
)

const (
	addrIPv4 = 1
	addrIPv6 = 4
)

type muxFrame struct {
	StreamID uint16
	MsgType  byte
	Payload  []byte
}

func encodeMuxFrame(streamID uint16, msgType byte, payload []byte) []byte {
	buf := make([]byte, 3+len(payload))
	binary.BigEndian.PutUint16(buf[0:2], streamID)
	buf[2] = msgType
	if len(payload) > 0 {
		copy(buf[3:], payload)
	}
	return buf
}

func decodeMuxFrame(data []byte) (muxFrame, error) {
	if len(data) < 3 {
		return muxFrame{}, fmt.Errorf("frame too short: %d", len(data))
	}
	return muxFrame{
		StreamID: binary.BigEndian.Uint16(data[0:2]),
		MsgType:  data[2],
		Payload:  data[3:],
	}, nil
}

func encodeConnectPayload(ip net.IP, port int) []byte {
	if v4 := ip.To4(); v4 != nil {
		buf := make([]byte, 1+4+2)
		buf[0] = addrIPv4
		copy(buf[1:5], v4)
		binary.BigEndian.PutUint16(buf[5:7], uint16(port))
		return buf
	}
	buf := make([]byte, 1+16+2)
	buf[0] = addrIPv6
	copy(buf[1:17], ip.To16())
	binary.BigEndian.PutUint16(buf[17:19], uint16(port))
	return buf
}

func computeAuthHMAC(secret string) []byte {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(secret))
	return mac.Sum(nil)
}

// ---------- Stream ----------

type streamState uint8

const (
	stOpening streamState = iota // CONNECT sent, awaiting CONNECT_OK
	stOpen                       // CONNECT_OK received, tcpReadLoop running
	stClosed                     // fully closed, awaiting purge
)

// cfLimit is Cloudflare's hard per-invocation limit on concurrent outbound
// connections (confirmed in developers.cloudflare.com/workers/platform/limits).
// This is the only concurrency gate for CONNECT → CF Worker.
const cfLimit = 6

// pendingDataCap bounds how much we buffer on a stream before CONNECT_OK arrives.
const pendingDataCap = 8 * 64 * 1024

type stream struct {
	id    uint16
	conn  *net.TCPConn
	state streamState

	localClosed   bool
	remoteClosed  bool
	gateReleased  bool
	closeDeadline time.Time // set when first side closes; purge at +10s grace

	pendingData    [][]byte // DATA buffered while state == stOpening
	pendingBytes   int
}

// ---------- Session ----------

// session holds all state for one WebSocket lifecycle. On WS death the whole
// session is discarded (via kill) and run() builds a new one. No state is
// carried across reconnects — making leaks impossible by construction.
type session struct {
	tc  *tunnelClient
	idx int // which parallel slot this session occupies
	ws  *websocket.Conn

	writeCh chan []byte   // buffered; writePump is the sole writer to ws
	pingReq chan struct{} // writePump also watches this to emit pings
	done    chan struct{} // closed once when the session is killed
	killOnce sync.Once

	mu      sync.Mutex         // guards streams map and stream fields
	streams map[uint16]*stream
	nextID  uint16
	cfGate  chan struct{}      // size cfLimit, acquired per CONNECT
}

func newSession(tc *tunnelClient, idx int, ws *websocket.Conn) *session {
	return &session{
		tc:      tc,
		idx:     idx,
		ws:      ws,
		writeCh: make(chan []byte, 256),
		pingReq: make(chan struct{}, 1),
		done:    make(chan struct{}),
		streams: make(map[uint16]*stream),
		cfGate:  make(chan struct{}, cfLimit),
	}
}

// kill is idempotent. It closes done, closes the ws, and tears down all streams.
// After kill returns, run() observes <-s.done and throws the whole session away.
func (s *session) kill(why error) {
	s.killOnce.Do(func() {
		if *verbose {
			log.Printf("[tunnel] session killed: %v", why)
		}
		close(s.done)
		_ = s.ws.Close()

		s.mu.Lock()
		streams := s.streams
		s.streams = nil
		s.mu.Unlock()
		for _, st := range streams {
			if st.conn != nil {
				_ = st.conn.Close()
			}
		}
	})
}

// send enqueues a pre-encoded frame to writePump. Non-blocking-ish: if the
// writer is too far behind we kill the session (backpressure failure).
func (s *session) send(frame []byte) bool {
	select {
	case s.writeCh <- frame:
		return true
	case <-s.done:
		return false
	case <-time.After(10 * time.Second):
		s.kill(errors.New("writeCh full 10s — writer stalled"))
		return false
	}
}

// writePump is the ONLY goroutine that writes to ws. This satisfies gorilla's
// single-writer concurrency contract without mutex dances.
func (s *session) writePump() {
	for {
		select {
		case frame := <-s.writeCh:
			_ = s.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := s.ws.WriteMessage(websocket.BinaryMessage, frame); err != nil {
				s.kill(fmt.Errorf("write: %w", err))
				return
			}
		case <-s.pingReq:
			if err := s.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				s.kill(fmt.Errorf("ping: %w", err))
				return
			}
		case <-s.done:
			return
		}
	}
}

// readPump is the ONLY goroutine that reads from ws.
func (s *session) readPump() {
	defer s.kill(errors.New("readPump exited"))
	for {
		_, msg, err := s.ws.ReadMessage()
		if err != nil {
			if *verbose {
				log.Printf("[tunnel] WS read error: %v", err)
			}
			return
		}
		frame, err := decodeMuxFrame(msg)
		if err != nil {
			if *verbose {
				log.Printf("[tunnel] bad frame: %v", err)
			}
			continue
		}
		s.dispatch(frame)
	}
}

func (s *session) dispatch(frame muxFrame) {
	s.mu.Lock()
	st, ok := s.streams[frame.StreamID]
	s.mu.Unlock()

	switch frame.MsgType {
	case muxCONNECT_OK:
		if !ok {
			return
		}
		s.mu.Lock()
		if st.state != stOpening {
			s.mu.Unlock()
			return
		}
		st.state = stOpen
		pending := st.pendingData
		st.pendingData = nil
		st.pendingBytes = 0
		s.mu.Unlock()
		// Flush any DATA that arrived before CONNECT_OK.
		for _, chunk := range pending {
			if _, err := st.conn.Write(chunk); err != nil {
				s.localClose(st)
				return
			}
		}
		go s.tcpReadLoop(st)

	case muxCONNECT_FAIL:
		if !ok {
			return
		}
		s.remoteClose(st)

	case muxDATA:
		if !ok {
			// Silent drop: stream was closed locally, in-flight DATA is fine.
			return
		}
		s.mu.Lock()
		if st.localClosed {
			s.mu.Unlock()
			return
		}
		if st.state == stOpening {
			// Buffer until CONNECT_OK, bounded.
			if st.pendingBytes+len(frame.Payload) > pendingDataCap {
				s.mu.Unlock()
				s.localClose(st)
				return
			}
			chunk := make([]byte, len(frame.Payload))
			copy(chunk, frame.Payload)
			st.pendingData = append(st.pendingData, chunk)
			st.pendingBytes += len(chunk)
			s.mu.Unlock()
			return
		}
		s.mu.Unlock()
		if _, err := st.conn.Write(frame.Payload); err != nil {
			if *verbose {
				log.Printf("[tunnel] stream %d TCP write err: %v", st.id, err)
			}
			s.localClose(st)
		}

	case muxCLOSE:
		if !ok {
			return
		}
		s.remoteClose(st)

	default:
		if *verbose {
			log.Printf("[tunnel] unknown msg type 0x%02x stream=%d", frame.MsgType, frame.StreamID)
		}
	}
}

func (s *session) pingTicker() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			select {
			case s.pingReq <- struct{}{}:
			default:
			}
		case <-s.done:
			return
		}
	}
}

// grimReaper purges streams in the grace period or that are fully closed.
// It is the sole place cfGate slots get released (guarded by gateReleased).
func (s *session) grimReaper() {
	t := time.NewTicker(1 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			now := time.Now()
			s.mu.Lock()
			for id, st := range s.streams {
				fullyClosed := st.localClosed && st.remoteClosed
				graceExpired := !st.closeDeadline.IsZero() && now.After(st.closeDeadline)
				if fullyClosed || graceExpired {
					if !st.gateReleased {
						st.gateReleased = true
						select {
						case <-s.cfGate:
						default:
						}
					}
					if st.conn != nil {
						_ = st.conn.Close()
					}
					delete(s.streams, id)
				}
			}
			s.mu.Unlock()
		case <-s.done:
			return
		}
	}
}

// localClose is called when our side (TCP to local app or write failure)
// decides to close the stream. It marks localClosed, sends CLOSE to the relay,
// closes the TCP conn, and starts the grace timer. Idempotent.
func (s *session) localClose(st *stream) {
	s.mu.Lock()
	if st.localClosed {
		s.mu.Unlock()
		return
	}
	st.localClosed = true
	if st.closeDeadline.IsZero() {
		st.closeDeadline = time.Now().Add(10 * time.Second)
	}
	conn := st.conn
	id := st.id
	both := st.localClosed && st.remoteClosed
	if both && !st.gateReleased {
		st.gateReleased = true
		select {
		case <-s.cfGate:
		default:
		}
		delete(s.streams, id)
	}
	s.mu.Unlock()

	if conn != nil {
		_ = conn.Close()
	}
	// Tell relay to close its TCP side.
	s.send(encodeMuxFrame(id, muxCLOSE, nil))
}

// remoteClose is called when the relay signals the stream is done (CLOSE or
// CONNECT_FAIL). We do NOT send CLOSE back. Idempotent.
func (s *session) remoteClose(st *stream) {
	s.mu.Lock()
	if st.remoteClosed {
		s.mu.Unlock()
		return
	}
	st.remoteClosed = true
	if st.closeDeadline.IsZero() {
		st.closeDeadline = time.Now().Add(10 * time.Second)
	}
	conn := st.conn
	id := st.id
	both := st.localClosed && st.remoteClosed
	if both && !st.gateReleased {
		st.gateReleased = true
		select {
		case <-s.cfGate:
		default:
		}
		delete(s.streams, id)
	}
	s.mu.Unlock()

	if conn != nil {
		_ = conn.Close()
	}
}

// tcpReadLoop pumps bytes from the local TCP conn into DATA frames. One
// goroutine per open stream. Exits on read EOF/error, calls localClose.
func (s *session) tcpReadLoop(st *stream) {
	buf := make([]byte, 64*1024)
	for {
		_ = st.conn.SetReadDeadline(time.Now().Add(*connTimeout))
		n, err := st.conn.Read(buf)
		if n > 0 {
			frame := encodeMuxFrame(st.id, muxDATA, buf[:n])
			if !s.send(frame) {
				return
			}
		}
		if err != nil {
			s.localClose(st)
			return
		}
	}
}

// ---------- Accept path ----------

// handleAccept takes a freshly REDIRECT'd TCP conn and turns it into a stream.
func (tc *tunnelClient) handleAccept(conn *net.TCPConn) {
	defer func() { <-tc.acceptGate }()

	_ = conn.SetNoDelay(true)

	origIP, origPort, err := getOriginalDst(conn)
	if err != nil {
		if *verbose {
			log.Printf("[tunnel] getOriginalDst: %v", err)
		}
		_ = conn.Close()
		return
	}

	s := tc.pickSession()
	if s == nil {
		if *verbose {
			log.Printf("[tunnel] no session ready, dropping %s -> %s:%d", conn.RemoteAddr(), origIP, origPort)
		}
		_ = conn.Close()
		return
	}

	// Acquire the CF gate — the ONE concurrency cap against CF's 6-per-invocation limit.
	select {
	case s.cfGate <- struct{}{}:
	case <-s.done:
		_ = conn.Close()
		return
	case <-time.After(10 * time.Second):
		log.Printf("[tunnel] CONNECT throttled (gate full 10s) from %s", conn.RemoteAddr())
		_ = conn.Close()
		return
	}

	// Allocate stream ID and register.
	s.mu.Lock()
	if s.streams == nil {
		s.mu.Unlock()
		<-s.cfGate
		_ = conn.Close()
		return
	}
	var id uint16
	found := false
	for i := 0; i < 100; i++ {
		s.nextID++
		if s.nextID == 0 {
			s.nextID = 1
		}
		if _, exists := s.streams[s.nextID]; !exists {
			id = s.nextID
			found = true
			break
		}
	}
	if !found {
		s.mu.Unlock()
		<-s.cfGate
		log.Printf("[tunnel] stream ID exhaustion")
		_ = conn.Close()
		return
	}
	st := &stream{
		id:    id,
		conn:  conn,
		state: stOpening,
	}
	s.streams[id] = st
	s.mu.Unlock()

	if *verbose {
		log.Printf("[tunnel-%d] stream %d: %s -> %s:%d", s.idx, id, conn.RemoteAddr(), origIP, origPort)
	}

	// Send CONNECT frame. tcpReadLoop is started later by dispatch() on CONNECT_OK.
	frame := encodeMuxFrame(id, muxCONNECT, encodeConnectPayload(origIP, origPort))
	if !s.send(frame) {
		s.localClose(st)
	}
}

// ---------- Supervisor ----------

type tunnelClient struct {
	url, secret string

	// Multiple parallel WS sessions. Each session is an independent CF Worker
	// invocation with its own 6-slot CF gate, so total capacity = cfLimit * N.
	// Load is distributed by round-robin on accept.
	sessions  []atomic.Pointer[session]
	rrCounter atomic.Uint64

	acceptGate chan struct{} // router-side admission limiter, unrelated to CF limit

	ctx    context.Context
	cancel context.CancelFunc
}

// pickSession returns the next ready session via round-robin. If none is
// ready after scanning all slots, returns nil.
func (tc *tunnelClient) pickSession() *session {
	n := len(tc.sessions)
	if n == 0 {
		return nil
	}
	start := int(tc.rrCounter.Add(1) % uint64(n))
	for i := 0; i < n; i++ {
		idx := (start + i) % n
		if s := tc.sessions[idx].Load(); s != nil {
			return s
		}
	}
	return nil
}

// anySessionReady returns true if at least one session is currently connected.
func (tc *tunnelClient) anySessionReady() bool {
	for i := range tc.sessions {
		if tc.sessions[i].Load() != nil {
			return true
		}
	}
	return false
}

// dial establishes a WS, performs auth, configures keepalive, and returns it ready.
func (tc *tunnelClient) dial() (*websocket.Conn, error) {
	dialer := websocket.Dialer{
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: false},
		HandshakeTimeout:  10 * time.Second,
		ReadBufferSize:    128 * 1024,
		WriteBufferSize:   128 * 1024,
		EnableCompression: false,
		NetDial: func(network, addr string) (net.Conn, error) {
			conn, err := net.DialTimeout("tcp4", addr, 10*time.Second)
			if err != nil {
				return nil, err
			}
			if tc, ok := conn.(*net.TCPConn); ok {
				_ = tc.SetNoDelay(true)
			}
			return conn, nil
		},
	}
	ws, _, err := dialer.Dial(tc.url, http.Header{})
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", tc.url, err)
	}

	ws.SetReadLimit(2 * 1024 * 1024)
	_ = ws.SetReadDeadline(time.Now().Add(60 * time.Second))
	ws.SetPongHandler(func(string) error {
		_ = ws.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	// Send auth frame synchronously.
	authFrame := encodeMuxFrame(0, muxAUTH, computeAuthHMAC(tc.secret))
	_ = ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := ws.WriteMessage(websocket.BinaryMessage, authFrame); err != nil {
		_ = ws.Close()
		return nil, fmt.Errorf("auth write: %w", err)
	}
	log.Printf("[tunnel] connected to %s", tc.url)
	return ws, nil
}

// runSession is the supervisor for ONE parallel session slot. It keeps a live
// WS in tc.sessions[idx], reconnecting with backoff on failure.
func (tc *tunnelClient) runSession(idx int) {
	consecutiveFails := 0
	for {
		select {
		case <-tc.ctx.Done():
			return
		default:
		}

		ws, err := tc.dial()
		if err != nil {
			consecutiveFails++
			backoff := pickBackoff(consecutiveFails)
			log.Printf("[tunnel-%d] dial failed (%d in a row, backoff %s): %v", idx, consecutiveFails, backoff, err)
			select {
			case <-time.After(backoff):
				continue
			case <-tc.ctx.Done():
				return
			}
		}

		s := newSession(tc, idx, ws)
		tc.sessions[idx].Store(s)
		log.Printf("[tunnel-%d] session up", idx)

		connectedAt := time.Now()
		go s.writePump()
		go s.pingTicker()
		go s.grimReaper()

		// Voluntary TTL rotation: kill the session slightly before CF would.
		// On free plan the invocation burns its 10ms CPU quickly; we pre-empt
		// so the rotation is graceful and other parallel sessions absorb traffic.
		if *sessionTTL > 0 {
			go func(s *session) {
				select {
				case <-time.After(*sessionTTL):
					s.kill(errors.New("voluntary TTL rotation"))
				case <-s.done:
				}
			}(s)
		}

		s.readPump() // blocks until session dies

		tc.sessions[idx].Store(nil)
		log.Printf("[tunnel-%d] session ended", idx)

		lifetime := time.Since(connectedAt)
		if lifetime < 5*time.Second {
			consecutiveFails++
			backoff := pickBackoff(consecutiveFails)
			log.Printf("[tunnel-%d] session died fast (%d in a row), backing off %s", idx, consecutiveFails, backoff)
			select {
			case <-time.After(backoff):
			case <-tc.ctx.Done():
				return
			}
		} else {
			consecutiveFails = 0
			select {
			case <-time.After(1 * time.Second):
			case <-tc.ctx.Done():
				return
			}
			log.Printf("[tunnel-%d] reconnecting...", idx)
		}
	}
}

func pickBackoff(n int) time.Duration {
	switch {
	case n >= 10:
		return 120 * time.Second
	case n >= 5:
		return 30 * time.Second
	case n >= 3:
		return 10 * time.Second
	default:
		return 3 * time.Second
	}
}

// ---------- Entry point ----------

func runTunnel() error {
	if *tunnelURL == "" {
		return fmt.Errorf("--tunnel-url is required")
	}
	if *tunnelSecret == "" {
		return fmt.Errorf("--tunnel-secret is required")
	}

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", *listenAddr, err)
	}
	log.Printf("[tunnel] listening on %s, relay=%s", *listenAddr, *tunnelURL)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	n := *parallelWS
	if n < 1 {
		n = 1
	}
	tc := &tunnelClient{
		url:        *tunnelURL,
		secret:     *tunnelSecret,
		acceptGate: make(chan struct{}, *maxConns),
		sessions:   make([]atomic.Pointer[session], n),
	}
	tc.ctx, tc.cancel = context.WithCancel(ctx)
	log.Printf("[tunnel] starting %d parallel WS sessions (total CF slots=%d)", n, n*cfLimit)

	for i := 0; i < n; i++ {
		go tc.runSession(i)
	}

	// Wait briefly for at least one session to be ready.
	for i := 0; i < 50; i++ {
		if tc.anySessionReady() {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	go func() {
		<-ctx.Done()
		log.Println("[tunnel] shutting down...")
		tc.cancel()
		_ = ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				log.Println("[tunnel] stopped")
				return nil
			default:
				continue
			}
		}
		tcpConn, ok := conn.(*net.TCPConn)
		if !ok {
			_ = conn.Close()
			continue
		}
		select {
		case tc.acceptGate <- struct{}{}:
			go tc.handleAccept(tcpConn)
		default:
			if *verbose {
				log.Printf("[tunnel] acceptGate full, rejecting %s", conn.RemoteAddr())
			}
			_ = conn.Close()
		}
	}
}
