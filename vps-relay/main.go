// vps-relay: TCP-over-WebSocket relay for the z2k tunnel client.
//
// Wire protocol (identical to cf-worker/worker.js):
//
//	[streamId u16 BE][msgType u8][payload]
//	Types: AUTH=0x00, CONNECT=0x01, DATA=0x02, CLOSE=0x03,
//	       CONNECT_OK=0x04, CONNECT_FAIL=0x05
//	Auth:  streamId=0, type=0x00, payload = HMAC-SHA256(secret, secret) (32 bytes)
//	CONNECT payload: [addr_type u8][addr][port u16 BE]
//	  addr_type 1 = IPv4 (4 bytes), 4 = IPv6 (16 bytes)
package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
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

	dialLimitPerTarget  = flag.Int("dial-limit-per-target", 8, "max in-flight dials per Telegram DC IP")
	dialThrottleTimeout = flag.Duration("dial-throttle-timeout", 3*time.Second, "max wait for dial slot before failing CONNECT")
	perStreamQueueBytes = flag.Int("per-stream-queue-bytes", 2*1024*1024, "max bytes queued per stream before stream-abort")
	sessionQueueBytes   = flag.Int("session-queue-bytes", 24*1024*1024, "max bytes queued per session before session-kill")
	sessionQueueDepth   = flag.Int("session-queue-depth", 1024, "session writeCh depth")
	controlQueueDepth   = flag.Int("control-queue-depth", 256, "session controlCh depth")
	dialStatsInterval   = flag.Duration("dial-stats-interval", 30*time.Second, "dial stats aggregation interval (0 = disabled)")
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

// dialLimiter caps concurrent in-flight dials per target IP. Prevents SYN
// bursts to a single Telegram DC from triggering upstream anti-abuse.
var errDialThrottle = errors.New("dial throttle timeout")

type dialLimiter struct {
	mu       sync.Mutex
	buckets  map[string]chan struct{}
	lastUsed map[string]time.Time
	limit    int
	timeout  time.Duration

	stopGC chan struct{}
}

func newDialLimiter(limit int, timeout time.Duration) *dialLimiter {
	l := &dialLimiter{
		buckets:  make(map[string]chan struct{}),
		lastUsed: make(map[string]time.Time),
		limit:    limit,
		timeout:  timeout,
		stopGC:   make(chan struct{}),
	}
	go l.gcLoop()
	return l
}

func (l *dialLimiter) bucketFor(target string) chan struct{} {
	l.mu.Lock()
	defer l.mu.Unlock()
	bucket, ok := l.buckets[target]
	if !ok {
		bucket = make(chan struct{}, l.limit)
		l.buckets[target] = bucket
	}
	l.lastUsed[target] = time.Now()
	return bucket
}

// acquire returns a release closure that frees the slot exactly once.
// The returned function is safe to call multiple times — only the first call
// releases the slot.
func (l *dialLimiter) acquire(ctx context.Context, target string) (release func(), err error) {
	bucket := l.bucketFor(target)
	timer := time.NewTimer(l.timeout)
	defer timer.Stop()

	select {
	case bucket <- struct{}{}:
		var done atomic.Bool
		return func() {
			if done.CompareAndSwap(false, true) {
				<-bucket
			}
		}, nil
	case <-timer.C:
		return nil, errDialThrottle
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (l *dialLimiter) gcOnce(now time.Time, idle time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := now.Add(-idle)
	for target, last := range l.lastUsed {
		if last.Before(cutoff) {
			bucket := l.buckets[target]
			if bucket != nil && len(bucket) == 0 {
				delete(l.buckets, target)
				delete(l.lastUsed, target)
			}
		}
	}
}

func (l *dialLimiter) gcLoop() {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			l.gcOnce(time.Now(), 5*time.Minute)
		case <-l.stopGC:
			return
		}
	}
}

func (l *dialLimiter) close() {
	select {
	case <-l.stopGC:
	default:
		close(l.stopGC)
	}
}

// dialStats aggregates dial outcomes and emits a single summary log line per
// flush interval. Skips empty intervals to avoid quiet-hours noise.
type dialStats struct {
	mu        sync.Mutex
	ok        int
	fail      int
	throttle  int
	latencies []time.Duration
}

func (s *dialStats) record(ok, throttled bool, lat time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if throttled {
		s.throttle++
		return
	}
	if ok {
		s.ok++
		s.latencies = append(s.latencies, lat)
	} else {
		s.fail++
	}
}

func (s *dialStats) flush() {
	s.mu.Lock()
	ok, fail, throttle := s.ok, s.fail, s.throttle
	lats := s.latencies
	s.ok, s.fail, s.throttle = 0, 0, 0
	s.latencies = nil
	s.mu.Unlock()

	if ok+fail+throttle == 0 {
		return
	}
	var p50, p95 time.Duration
	if len(lats) > 0 {
		sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })
		p50idx := len(lats) * 50 / 100
		p95idx := len(lats) * 95 / 100
		if p50idx >= len(lats) {
			p50idx = len(lats) - 1
		}
		if p95idx >= len(lats) {
			p95idx = len(lats) - 1
		}
		p50 = lats[p50idx]
		p95 = lats[p95idx]
	}
	log.Printf("dial summary: ok=%d fail=%d throttle=%d p50=%s p95=%s", ok, fail, throttle, p50, p95)
}

func (s *dialStats) loop(interval time.Duration, stop <-chan struct{}) {
	if interval <= 0 {
		return
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			s.flush()
		case <-stop:
			return
		}
	}
}

// stream represents one tunneled TCP connection to a Telegram DC.
//
// aborted is set ONLY by sendAbort (per-stream cap exceeded, peer-write
// error, or kill); EOF on upstream conn does NOT set this flag.
type stream struct {
	id          uint16
	conn        net.Conn
	queuedBytes atomic.Int64
	aborted     atomic.Bool
}

// queuedFrame carries a frame plus identity of its stream so writePump can
// decrement the right counter even after stream-ID reuse / wrap-around.
type queuedFrame struct {
	stream  *stream
	frame   []byte
	counted int64 // bytes to decrement from stream.queuedBytes (0 for non-DATA)
}

type session struct {
	id string
	ws *websocket.Conn

	writeCh   chan queuedFrame // DATA + ordered-CLOSE; FIFO
	controlCh chan []byte      // CONNECT_OK/FAIL + abort-CLOSE; priority
	done      chan struct{}
	once      sync.Once

	mu          sync.Mutex
	queueMu     sync.Mutex
	queuedBytes int
	streams     map[uint16]*stream

	dialCtx    context.Context
	dialCancel context.CancelFunc
	dialFn     func(ctx context.Context, network, addr string) (net.Conn, error)
}

func newSession(ws *websocket.Conn, id string, parentCtx context.Context) *session {
	dialCtx, dialCancel := context.WithCancel(parentCtx)
	return &session{
		id:         id,
		ws:         ws,
		writeCh:    make(chan queuedFrame, *sessionQueueDepth),
		controlCh:  make(chan []byte, *controlQueueDepth),
		done:       make(chan struct{}),
		streams:    make(map[uint16]*stream),
		dialCtx:    dialCtx,
		dialCancel: dialCancel,
		dialFn:     (&net.Dialer{}).DialContext,
	}
}

func (s *session) kill() {
	s.once.Do(func() {
		close(s.done)
		s.dialCancel()
		_ = s.ws.Close()
		s.mu.Lock()
		for _, st := range s.streams {
			st.aborted.Store(true)
			if st.conn != nil {
				_ = st.conn.Close()
			}
		}
		s.streams = nil
		s.mu.Unlock()
	})
}

func (s *session) reserveSession(n int) bool {
	s.queueMu.Lock()
	defer s.queueMu.Unlock()
	if s.queuedBytes+n > *sessionQueueBytes {
		return false
	}
	s.queuedBytes += n
	return true
}

func (s *session) releaseSession(n int) {
	s.queueMu.Lock()
	defer s.queueMu.Unlock()
	s.queuedBytes -= n
	if s.queuedBytes < 0 {
		s.queuedBytes = 0
	}
}

// sendData enqueues a DATA frame via writeCh (FIFO).
//
// Skip if stream already aborted or replaced in the map (pointer identity).
// Per-stream cap exceeded → call sendAbort (drops pending DATA).
// Session cap exceeded → kill session (true session-wide abuse).
// writeCh full → call sendAbort.
func (s *session) sendData(st *stream, payload []byte) {
	if st.aborted.Load() {
		return
	}
	s.mu.Lock()
	cur := s.streams[st.id]
	s.mu.Unlock()
	if cur != st {
		return
	}

	frame := encodeFrame(st.id, muxDATA, payload)
	n := int64(len(frame))

	if st.queuedBytes.Add(n) > int64(*perStreamQueueBytes) {
		st.queuedBytes.Add(-n)
		log.Printf("[%s] stream %d per-stream queue exceeded, aborting", s.id, st.id)
		s.sendAbort(st)
		return
	}

	if !s.reserveSession(int(n)) {
		st.queuedBytes.Add(-n)
		log.Printf("[%s] session queue %d bytes exceeded, killing session", s.id, *sessionQueueBytes)
		go s.kill()
		return
	}

	qf := queuedFrame{stream: st, frame: frame, counted: n}
	select {
	case s.writeCh <- qf:
	case <-s.done:
		s.releaseSession(int(n))
		st.queuedBytes.Add(-n)
	default:
		s.releaseSession(int(n))
		st.queuedBytes.Add(-n)
		log.Printf("[%s] stream %d writeCh full, aborting stream", s.id, st.id)
		s.sendAbort(st)
	}
}

// sendOrderedClose enqueues an EOF CLOSE through writeCh, preserving FIFO
// order with any pending DATA frames for this stream.
//
// Caller MUST have already removed st from s.streams. Caller MUST NOT have
// set st.aborted (that would belong to abort-path, which uses sendAbort).
// counted=0 — CLOSE frame is not charged against per-stream cap.
func (s *session) sendOrderedClose(st *stream) {
	if st.aborted.Load() {
		return
	}
	frame := encodeFrame(st.id, muxCLOSE, nil)
	n := int64(len(frame))

	if !s.reserveSession(int(n)) {
		log.Printf("[%s] stream %d ordered close — session full, dropping", s.id, st.id)
		return
	}

	qf := queuedFrame{stream: st, frame: frame, counted: 0}
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case s.writeCh <- qf:
	case <-s.done:
		s.releaseSession(int(n))
	case <-timer.C:
		s.releaseSession(int(n))
		log.Printf("[%s] stream %d ordered close — writeCh blocked, dropping", s.id, st.id)
	}
}

// sendAbort marks the stream aborted, removes it from the map, closes the
// upstream conn, and enqueues a CLOSE via the priority controlCh. Idempotent
// via CAS — concurrent abort-paths produce exactly one CLOSE frame.
func (s *session) sendAbort(st *stream) {
	if !st.aborted.CompareAndSwap(false, true) {
		return
	}
	s.mu.Lock()
	if cur, ok := s.streams[st.id]; ok && cur == st {
		delete(s.streams, st.id)
	}
	s.mu.Unlock()
	if st.conn != nil {
		_ = st.conn.Close()
	}

	frame := encodeFrame(st.id, muxCLOSE, nil)
	select {
	case s.controlCh <- frame:
	case <-s.done:
	default:
		log.Printf("[%s] controlCh full on abort, killing session", s.id)
		go s.kill()
	}
}

func (s *session) sendConnectResult(streamID uint16, ok bool) {
	mt := muxCONNECT_FAIL
	if ok {
		mt = muxCONNECT_OK
	}
	frame := encodeFrame(streamID, mt, nil)
	select {
	case s.controlCh <- frame:
	case <-s.done:
	default:
		log.Printf("[%s] controlCh full on connect-result, killing session", s.id)
		go s.kill()
	}
}

// closeStream handles peer-initiated close (muxCLOSE from client).
// No CLOSE frame back — peer already knows. Marks aborted so any in-flight
// pumpReadFromTCP and pending writeCh frames are dropped.
func (s *session) closeStream(id uint16) {
	s.mu.Lock()
	st, ok := s.streams[id]
	if ok {
		delete(s.streams, id)
	}
	s.mu.Unlock()
	if !ok {
		return
	}
	st.aborted.Store(true)
	if st.conn != nil {
		_ = st.conn.Close()
	}
}

// writePump is the single goroutine that owns the WS write side. It drains
// controlCh with priority over writeCh; on every writeCh dequeue it
// decrements the per-stream and per-session counters, then skips ws.Write
// if the stream was aborted (drops pending DATA after sendAbort).
func (s *session) writePump() {
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()

	writeFrame := func(frame []byte) bool {
		_ = s.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if err := s.ws.WriteMessage(websocket.BinaryMessage, frame); err != nil {
			if *verbose {
				log.Printf("[%s] write err: %v", s.id, err)
			}
			return false
		}
		return true
	}

	for {
		// Priority: drain one control frame if available.
		select {
		case frame := <-s.controlCh:
			if !writeFrame(frame) {
				s.kill()
				return
			}
			continue
		default:
		}

		select {
		case frame := <-s.controlCh:
			if !writeFrame(frame) {
				s.kill()
				return
			}
		case qf := <-s.writeCh:
			if qf.counted > 0 {
				qf.stream.queuedBytes.Add(-qf.counted)
			}
			s.releaseSession(len(qf.frame))
			if qf.stream != nil && qf.stream.aborted.Load() {
				continue
			}
			if !writeFrame(qf.frame) {
				s.kill()
				return
			}
		case <-ping.C:
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

func (s *session) handleConnect(id uint16, payload []byte) {
	addr, port, err := parseConnectPayload(payload)
	if err != nil {
		if *verbose {
			log.Printf("[%s] stream %d bad CONNECT: %v", s.id, id, err)
		}
		s.sendConnectResult(id, false)
		return
	}
	if !isTelegramAddr(addr) {
		log.Printf("[%s] stream %d rejected non-Telegram %s:%d", s.id, id, addr, port)
		s.sendConnectResult(id, false)
		return
	}

	target := net.JoinHostPort(addr, strconv.Itoa(port))

	release, err := dialThrottle.acquire(s.dialCtx, addr)
	if err != nil {
		if errors.Is(err, errDialThrottle) {
			stats.record(false, true, 0)
			if *verbose {
				log.Printf("[%s] stream %d dial throttle %s", s.id, id, addr)
			}
		}
		s.sendConnectResult(id, false)
		return
	}

	t0 := time.Now()
	dCtx, cancel := context.WithTimeout(s.dialCtx, 10*time.Second)
	conn, err := s.dialFn(dCtx, "tcp", target)
	cancel()
	release()
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		stats.record(false, false, 0)
		log.Printf("[%s] stream %d dial %s failed: %v", s.id, id, target, err)
		s.sendConnectResult(id, false)
		return
	}
	lat := time.Since(t0)
	stats.record(true, false, lat)

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
	if old, exists := s.streams[id]; exists {
		old.aborted.Store(true)
		if old.conn != nil {
			_ = old.conn.Close()
		}
	}
	s.streams[id] = st
	active := len(s.streams)
	s.mu.Unlock()

	if *verbose {
		log.Printf("[%s] stream %d CONNECT %s ok (%s) active=%d", s.id, id, target, lat, active)
	}
	s.sendConnectResult(id, true)

	go s.pumpReadFromTCP(st)
}

// pumpReadFromTCP copies upstream TCP bytes into DATA frames. On EOF it
// removes the stream from the map (so further peer-side writes ignore it)
// and emits an ordered CLOSE — but only if the stream wasn't aborted in
// parallel.
func (s *session) pumpReadFromTCP(st *stream) {
	buf := make([]byte, 64*1024)
	for {
		n, err := st.conn.Read(buf)
		if n > 0 {
			payload := make([]byte, n)
			copy(payload, buf[:n])
			s.sendData(st, payload)
		}
		if err != nil {
			break
		}
	}

	s.mu.Lock()
	cur, exists := s.streams[st.id]
	if exists && cur == st {
		delete(s.streams, st.id)
	}
	s.mu.Unlock()
	_ = st.conn.Close()
	if exists && cur == st && !st.aborted.Load() {
		s.sendOrderedClose(st)
	}
}

func (s *session) readPump() {
	defer s.kill()

	s.ws.SetReadLimit(2 * 1024 * 1024)
	_ = s.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
	s.ws.SetPongHandler(func(string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
		return nil
	})
	s.ws.SetPingHandler(func(data string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(90 * time.Second))
		return s.ws.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(5*time.Second))
	})

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
				continue
			}
			if _, err := st.conn.Write(payload); err != nil {
				if *verbose {
					log.Printf("[%s] stream %d tcp write err: %v", s.id, sid, err)
				}
				s.sendAbort(st)
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

var dialThrottle *dialLimiter
var stats = &dialStats{}

var upgrader = websocket.Upgrader{
	ReadBufferSize:    256 * 1024,
	WriteBufferSize:   256 * 1024,
	CheckOrigin:       func(r *http.Request) bool { return true },
	EnableCompression: false,
}

func makeSessionID() string {
	return strconv.FormatInt(time.Now().UnixNano()%100000, 36)
}

func handleWS(parentCtx context.Context, w http.ResponseWriter, r *http.Request) {
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
	s := newSession(ws, sid, parentCtx)
	go s.writePump()
	s.readPump()
	log.Printf("[%s] WS closed", sid)
}

func main() {
	flag.Parse()
	if *secret == "" {
		log.Fatal("--secret is required")
	}

	dialThrottle = newDialLimiter(*dialLimitPerTarget, *dialThrottleTimeout)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	statsStop := make(chan struct{})
	go stats.loop(*dialStatsInterval, statsStop)

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		handleWS(ctx, w, r)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "z2k vps-relay")
	})

	srv := &http.Server{
		Addr:              *listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	serveErr := make(chan error, 1)
	go func() {
		serveErr <- srv.ListenAndServe()
	}()

	log.Printf("z2k vps-relay listening on %s (dial-limit-per-target=%d, dial-throttle-timeout=%s, per-stream-bytes=%d, session-bytes=%d, session-depth=%d, control-depth=%d, stats-interval=%s)",
		*listenAddr, *dialLimitPerTarget, *dialThrottleTimeout, *perStreamQueueBytes, *sessionQueueBytes, *sessionQueueDepth, *controlQueueDepth, *dialStatsInterval)

	select {
	case err := <-serveErr:
		if err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	case <-ctx.Done():
		log.Printf("shutdown requested")
		sdCtx, sdCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer sdCancel()
		if err := srv.Shutdown(sdCtx); err != nil {
			log.Printf("graceful shutdown failed: %v", err)
			_ = srv.Close()
		}
		close(statsStop)
		dialThrottle.close()
		if err := <-serveErr; err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
		log.Printf("server stopped")
	}
}
