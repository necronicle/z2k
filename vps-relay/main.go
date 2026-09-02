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
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
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
	listenAddr      = flag.String("listen", ":8080", "HTTP listen address (TLS terminated upstream by Caddy)")
	secret          = flag.String("secret", "", "shared HMAC secret (must match tunnel client)")
	secretPrev      = flag.String("secret-prev", "", "previous shared HMAC secret, still accepted during rotation (dual-accept; empty=off, NO flip yet)")
	resolveSecret   = flag.String("resolve-secret", "", "dedicated HMAC secret for /resolve (decoupled from the tunnel secret); falls back to --secret when empty")
	verbose         = flag.Bool("v", false, "verbose logging")
	eventsDir       = flag.String("events-dir", "", "каталог структурного журнала событий (пусто = выключено)")
	eventsKeep      = flag.Int("events-keep", 30, "сколько суточных файлов событий хранить")
	authReadTimeout = flag.Duration("auth-read-timeout", 90*time.Second, "таймаут чтения WS до и после авторизации")

	dialLimitPerTarget    = flag.Int("dial-limit-per-target", 8, "max in-flight dials per Telegram DC IP")
	dialThrottleTimeout   = flag.Duration("dial-throttle-timeout", 3*time.Second, "max wait for dial slot before failing CONNECT")
	dialPerAttemptTimeout = flag.Duration("dial-per-attempt-timeout", 10*time.Second, "TCP dial timeout for a single attempt")
	dialRetryCount        = flag.Int("dial-retry-count", 1, "extra dial attempts on i/o timeout (0 disables retry)")
	dialRetryBackoff      = flag.Duration("dial-retry-backoff", 250*time.Millisecond, "delay between dial attempts")
	perStreamQueueBytes   = flag.Int("per-stream-queue-bytes", 2*1024*1024, "max bytes queued per stream before stream-abort")
	sessionQueueBytes     = flag.Int("session-queue-bytes", 24*1024*1024, "max bytes queued per session before session-kill")
	sessionQueueDepth     = flag.Int("session-queue-depth", 1024, "session writeCh depth")
	controlQueueDepth     = flag.Int("control-queue-depth", 256, "session controlCh depth")
	dialStatsInterval     = flag.Duration("dial-stats-interval", 30*time.Second, "dial stats aggregation interval (0 = disabled)")

	// Потолки на неоплаченную работу, которую может заказать один клиент.
	//
	// Их не было вовсе: на каждый входящий кадр CONNECT поднималась горутина
	// без счётчика, а число стримов в сессии ограничивалось только разрядностью
	// uint16. Кадр CONNECT — десять байт, горутина живёт до трёх секунд ожидания
	// слота плюс два диала по десять секунд. То есть один аутентифицированный
	// клиент, льющий CONNECT со скоростью линка, покупает себе десятки тысяч
	// горутин по ≥8 КБ стека, а 65536 стримов с буферами дают гигабайты — при
	// том что вся машина это 2 ГБ.
	//
	// Значения с большим запасом над реальным профилем (замер installstats:
	// в потолок perInstallMaxSessions=64 не упирался никто ни разу), чтобы
	// живой человек их не почувствовал: это защита от флуда, а не квота.
	maxPendingConnects = flag.Int("max-pending-connects", 64, "max in-flight CONNECT handlers per session (0 = unlimited)")
	maxStreamsPerSess  = flag.Int("max-streams-per-session", 512, "max concurrent streams per session (0 = unlimited)")

	// One-off allowlist extension (2026-05-22): permit specific non-Telegram
	// CIDRs through the relay. Used for the cdnbase.com HTTP body-cap bypass
	// (see feedback_no_tunnels.md "One-off exception"). NOT a general
	// tunnel-anything mode — keep this narrow. Format:
	// --extra-cidrs="168.119.95.0/24,1.2.3.4/32"
	extraCIDRs = flag.String("extra-cidrs", "", "comma-separated allowlist of non-Telegram CIDRs (IPv4 only)")
)

// Telegram DC allowlist — same ranges the CF worker accepts.
var telegramV4 []netRange
var telegramV6Prefixes = []string{"2001:b28:f23d:", "2001:b28:f23f:", "2001:67c:4e8:"}

// Optional non-Telegram allowlist, populated from --extra-cidrs at startup.
// See "One-off exception" in feedback_no_tunnels memory.
var extraV4 []netRange

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

// parseExtraCIDRs parses --extra-cidrs and populates extraV4. Called once at startup.
func parseExtraCIDRs(s string) error {
	if s == "" {
		return nil
	}
	for _, c := range strings.Split(s, ",") {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		_, ipnet, err := net.ParseCIDR(c)
		if err != nil {
			return fmt.Errorf("extra-cidrs: invalid CIDR %q: %w", c, err)
		}
		v4 := ipnet.IP.To4()
		if v4 == nil {
			return fmt.Errorf("extra-cidrs: IPv4 only (got %q)", c)
		}
		mask := binary.BigEndian.Uint32(ipnet.Mask)
		extraV4 = append(extraV4, netRange{
			net:  binary.BigEndian.Uint32(v4),
			mask: mask,
		})
	}
	return nil
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
		// Non-Telegram extras (one-off cdnbase exception, etc.)
		for _, r := range extraV4 {
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

// Пул буферов чтения. Раньше каждый стрим держал собственные 64 КБ всю свою
// жизнь; у Telegram стримы живут часами, поэтому на ~1300 туннелях это и был
// основной вклад в RSS. Пул отдаёт буфер только на время активного чтения.
var readBufPool = sync.Pool{
	New: func() any {
		b := make([]byte, 64*1024)
		return &b
	},
}

// newConnectSlots — буфер под потолок одновременных CONNECT (nil = без лимита).
func newConnectSlots() chan struct{} {
	if *maxPendingConnects <= 0 {
		return nil
	}
	return make(chan struct{}, *maxPendingConnects)
}

// acquireConnectSlot берёт слот НЕ блокируясь: ждать здесь нельзя, читатель
// кадров один на сессию, и заснув в нём мы остановили бы и DATA тоже.
func (s *session) acquireConnectSlot() bool {
	if s.connectSlots == nil {
		return true
	}
	select {
	case s.connectSlots <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *session) releaseConnectSlot() {
	if s.connectSlots == nil {
		return
	}
	select {
	case <-s.connectSlots:
	default:
	}
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

// isTimeoutErr reports whether err represents a timeout — either the dial
// hit the per-attempt deadline (context.DeadlineExceeded) or the OS-level
// "i/o timeout" surfaced via net.Error.Timeout().
func isTimeoutErr(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var ne net.Error
	if errors.As(err, &ne) {
		return ne.Timeout()
	}
	return false
}

type dialAttemptFunc func(ctx context.Context, network, addr string) (net.Conn, error)

// dialWithRetry wraps dialFn with per-attempt timeout and a simple retry
// loop on timeout-class errors. Returns the surviving conn (if any), the
// final error, and the 0-based attempt index that produced the result —
// caller uses this to flag retry-saved successes for stats.
//
// Non-timeout errors (refused/unreachable) bypass the retry loop because
// they're deterministic.
func dialWithRetry(
	ctx context.Context,
	dialFn dialAttemptFunc,
	target string,
	perAttemptTimeout time.Duration,
	maxAttempts int,
	backoff time.Duration,
) (net.Conn, int, error) {
	if maxAttempts < 1 {
		maxAttempts = 1
	}
	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		dCtx, cancel := context.WithTimeout(ctx, perAttemptTimeout)
		conn, err := dialFn(dCtx, "tcp", target)
		cancel()

		if err == nil {
			return conn, attempt, nil
		}
		lastErr = err
		if errors.Is(err, context.Canceled) {
			return nil, attempt, err
		}
		if !isTimeoutErr(err) {
			return nil, attempt, err
		}
		if attempt+1 >= maxAttempts {
			break
		}
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return nil, attempt, ctx.Err()
		}
	}
	return nil, maxAttempts - 1, lastErr
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
	retried   int // dials that succeeded only after a retry — visibility into how often retry saves the call
	latencies []time.Duration
}

func (s *dialStats) record(ok, throttled bool, retried bool, lat time.Duration) {
	switch {
	case throttled:
		metrics.inc("relay_dial_total", `result="throttle"`)
	case ok:
		metrics.inc("relay_dial_total", `result="ok"`)
		metrics.observe("relay_dial_latency_seconds", lat)
	default:
		metrics.inc("relay_dial_total", `result="fail"`)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if throttled {
		s.throttle++
		return
	}
	if ok {
		s.ok++
		if retried {
			s.retried++
		}
		s.latencies = append(s.latencies, lat)
	} else {
		s.fail++
	}
}

func (s *dialStats) flush() {
	s.mu.Lock()
	ok, fail, throttle, retried := s.ok, s.fail, s.throttle, s.retried
	lats := s.latencies
	s.ok, s.fail, s.throttle, s.retried = 0, 0, 0, 0
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
	log.Printf("dial summary: ok=%d fail=%d throttle=%d retried=%d p50=%s p95=%s", ok, fail, throttle, retried, p50, p95)
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
// aborted помечает стрим как отменённый: writePump выбрасывает его кадры, не
// отправляя, а pumpReadFromTCP не шлёт по нему упорядоченный CLOSE.
//
// Выставляется в ЧЕТЫРЁХ местах, и это важно знать, добавляя пятое:
//   - sendAbort — единственный, кто делает это через CAS и потому шлёт ровно
//     один CLOSE (превышен потолок стрима, ошибка записи пиру);
//   - kill — гасит все стримы сессии разом;
//   - closeStream — закрытие по инициативе клиента (CLOSE от него);
//   - handleConnect — вытесняя прежний стрим с тем же идентификатором.
//
// Прежняя редакция утверждала «set ONLY by sendAbort», и это было неверно уже
// на момент написания: три прямых Store существуют рядом. Прочитавший
// поверил бы, что достаточно обойти sendAbort, чтобы флаг не поднялся.
//
// EOF на соединении с Telegram флаг НЕ выставляет — это штатный конец, по
// нему уходит упорядоченный CLOSE.
type stream struct {
	id          uint16
	conn        net.Conn
	queuedBytes atomic.Int64
	aborted     atomic.Bool
	opened      time.Time
	target      string
	closeReason atomic.Value // string; выставляется первым, кто закрывает
}

// queuedFrame carries a frame plus identity of its stream so writePump can
// decrement the right counter even after stream-ID reuse / wrap-around.
type queuedFrame struct {
	stream  *stream
	frame   []byte
	counted int64 // bytes to decrement from stream.queuedBytes (0 for non-DATA)
}

type session struct {
	id      string
	relayID string // per-install identity (Stage B); "" for shared-secret auth
	// Настоящий адрес клиента — известен уже при принятии соединения, а нужен
	// глубже, в аутентификации, где становится известна установка. Связать одно
	// с другим сшивкой строк лога нельзя надёжно, поэтому адрес едет в сессии.
	clientIP string
	ws       *websocket.Conn

	// Кумулятивный объём за сессию. Раньше в релее не было НИ ОДНОГО счётчика
	// трафика: queuedBytes ниже — это датчик подпора очереди, он уменьшается
	// при отправке и накопленного не показывает. Без объёма нельзя отличить
	// домашний роутер от того, кто раздаёт наш туннель дальше.
	rxBytes atomic.Int64 // от Telegram к клиенту
	txBytes atomic.Int64 // от клиента к Telegram

	writeCh   chan queuedFrame // DATA + ordered-CLOSE; FIFO
	controlCh chan []byte      // CONNECT_OK/FAIL + abort-CLOSE; priority
	done      chan struct{}
	once      sync.Once

	// Причина закрытия: выставляется первым вызовом killWith и читается
	// после завершения readPump — kill идёт через once, поэтому чтение
	// после него упорядочено с записью.
	reasonOnce  sync.Once
	reason      string
	peakStreams atomic.Int32
	proto       string
	started     time.Time

	noisyMu sync.Mutex
	noisyN  map[string]int

	// Потолок одновременных обработчиков CONNECT. Буферизованный канал, а не
	// счётчик: слот занимается ДО запуска горутины, поэтому переполнение видно
	// сразу и отвечается отказом, а не копится в памяти.
	connectSlots chan struct{}

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
		id:           id,
		ws:           ws,
		proto:        "v1",
		started:      time.Now(),
		writeCh:      make(chan queuedFrame, *sessionQueueDepth),
		controlCh:    make(chan []byte, *controlQueueDepth),
		connectSlots: newConnectSlots(),
		done:         make(chan struct{}),
		streams:      make(map[uint16]*stream),
		dialCtx:      dialCtx,
		dialCancel:   dialCancel,
		dialFn:       (&net.Dialer{}).DialContext,
	}
}

// killWith фиксирует причину и закрывает сессию. Повторные вызовы причину
// не меняют: первая и есть настоящая.
func (s *session) killWith(reason string) {
	s.reasonOnce.Do(func() { s.reason = reason })
	s.kill()
}

const noisyPrintLimit = 3

// noisy считает повторяющиеся отказы одной сессии и разрешает печать
// только первых трёх: одна установка с самонабором давала 13 тысяч строк
// за два часа и вымывала журнал релея до пяти часов истории (02.09.2026).
func (s *session) noisy(kind string) bool {
	s.noisyMu.Lock()
	defer s.noisyMu.Unlock()
	if s.noisyN == nil {
		s.noisyN = map[string]int{}
	}
	s.noisyN[kind]++
	return s.noisyN[kind] <= noisyPrintLimit
}

func (s *session) noisyDetail() string {
	s.noisyMu.Lock()
	defer s.noisyMu.Unlock()
	if len(s.noisyN) == 0 {
		return ""
	}
	keys := make([]string, 0, len(s.noisyN))
	for k := range s.noisyN {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, s.noisyN[k]))
	}
	return strings.Join(parts, " ")
}

func (s *session) closeReason() string {
	s.reasonOnce.Do(func() { s.reason = "peer_close" })
	return s.reason
}

// classifyReadErr сводит ошибку чтения WS к причине события: таймаут —
// read_timeout, штатное закрытие пиром — peer_close, остальное — prefix.
func authRejectClass(why string) string {
	switch {
	case strings.HasPrefix(why, "часы разошлись"):
		return "clock_skew"
	case strings.HasPrefix(why, "повтор подписи"):
		return "replay"
	default:
		return "other"
	}
}

func classifyReadErr(err error, prefix string) string {
	if isTimeoutErr(err) {
		if prefix == "auth_read_err" {
			return "auth_read_err:timeout"
		}
		return "read_timeout"
	}
	if websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway, websocket.CloseNoStatusReceived) || errors.Is(err, io.EOF) {
		if prefix == "auth_read_err" {
			return "auth_read_err:eof"
		}
		return "peer_close"
	}
	return prefix
}

func (s *session) kill() {
	s.once.Do(func() {
		close(s.done)
		s.dialCancel()
		_ = s.ws.Close()
		s.mu.Lock()
		for _, st := range s.streams {
			s.emitStreamClose(st, "session_close")
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
	s.sendDataFrame(st, encodeFrame(st.id, muxDATA, payload))
}

// sendDataFrame — то же самое, но кадр уже собран вызывающим.
//
// Разделено, чтобы горячий путь (pumpReadFromTCP) мог собрать кадр прямо из
// буфера чтения: там иначе получалось два выделения и два копирования на
// каждый прочитанный блок, причём первая копия становилась мусором сразу же.
// sendData оставлена для вызовов, у которых на руках именно payload.
func (s *session) sendDataFrame(st *stream, frame []byte) {
	if st.aborted.Load() {
		return
	}
	n := int64(len(frame))
	// Учёт трафика — по полезной нагрузке, без трёх байт заголовка: цифра
	// должна означать то же, что и раньше.
	s.rxBytes.Add(n - 3)
	s.mu.Lock()
	cur := s.streams[st.id]
	s.mu.Unlock()
	if cur != st {
		return
	}

	if st.queuedBytes.Add(n) > int64(*perStreamQueueBytes) {
		st.queuedBytes.Add(-n)
		if s.noisy("queue_abort") {
			log.Printf("[%s] stream %d per-stream queue exceeded, aborting", s.id, st.id)
		}
		s.sendAbort(st)
		return
	}

	if !s.reserveSession(int(n)) {
		st.queuedBytes.Add(-n)
		log.Printf("[%s] session queue %d bytes exceeded, killing session", s.id, *sessionQueueBytes)
		go s.killWith("session_queue")
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
		if s.noisy("queue_abort") {
			log.Printf("[%s] stream %d writeCh full, aborting stream", s.id, st.id)
		}
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
// emitStreamClose пишет ровно одно событие закрытия на стрим: первая
// причина побеждает, повторные вызовы игнорируются.
func (s *session) emitStreamClose(st *stream, reason string) {
	if !st.closeReason.CompareAndSwap(nil, reason) {
		return
	}
	liveStreams.Add(-1)
	metrics.inc("relay_stream_close_total", fmt.Sprintf("reason=%q", reason))
	events.Emit(Event{
		Ev: "stream_close", SID: s.id, Install: s.relayID, Reason: reason,
		DurMS: time.Since(st.opened).Milliseconds(), Detail: st.target,
	})
}

func (s *session) sendAbort(st *stream) {
	if !st.aborted.CompareAndSwap(false, true) {
		return
	}
	s.emitStreamClose(st, "abort")
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
		go s.killWith("control_queue")
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
		go s.killWith("control_queue")
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
	s.emitStreamClose(st, "peer_close")
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
			if isTimeoutErr(err) {
				metrics.inc("relay_ws_write_timeouts_total", "")
			}
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
				s.killWith("write_err")
				return
			}
			continue
		default:
		}

		select {
		case frame := <-s.controlCh:
			if !writeFrame(frame) {
				s.killWith("write_err")
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
				s.killWith("write_err")
				return
			}
		case <-ping.C:
			_ = s.ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if err := s.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				log.Printf("[%s] ping failed: %v", s.id, err)
				s.killWith("ping_failed")
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
		if s.noisy("rejected_non_tg") {
			log.Printf("[%s] stream %d rejected non-Telegram %s:%d", s.id, id, addr, port)
		}
		events.Emit(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "not_allowed", Detail: net.JoinHostPort(addr, strconv.Itoa(port))})
		s.sendConnectResult(id, false)
		return
	}

	target := net.JoinHostPort(addr, strconv.Itoa(port))

	release, terr := dialThrottle.acquire(s.dialCtx, addr)
	if terr != nil {
		if errors.Is(terr, errDialThrottle) {
			stats.record(false, true, false, 0)
			if *verbose {
				log.Printf("[%s] stream %d dial throttle %s", s.id, id, addr)
			}
			events.Emit(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "throttled", Detail: target})
		}
		s.sendConnectResult(id, false)
		return
	}

	t0 := time.Now()
	conn, attempt, err := dialWithRetry(s.dialCtx, s.dialFn, target, *dialPerAttemptTimeout, 1+*dialRetryCount, *dialRetryBackoff)
	release()
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		stats.record(false, false, false, 0)
		if s.noisy("dial_failed") {
			log.Printf("[%s] stream %d dial %s failed (attempts=%d): %v", s.id, id, target, attempt+1, err)
		}
		events.Emit(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "dial_error", Detail: target})
		s.sendConnectResult(id, false)
		return
	}
	lat := time.Since(t0)
	stats.record(true, false, attempt > 0, lat)

	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(60 * time.Second)
	}

	st := &stream{id: id, conn: conn, opened: time.Now(), target: target}

	s.mu.Lock()
	if s.streams == nil {
		s.mu.Unlock()
		_ = conn.Close()
		return
	}
	_, replacing := s.streams[id]
	// Потолок стримов. Переиспользование существующего id пропускаем всегда:
	// это не рост, а замена, и отказ там оборвал бы живой стрим.
	//
	// Без потолка предел задавала только разрядность uint16 — 65536 стримов в
	// одной сессии, каждый со своим соединением и очередью. На машине с 2 ГБ
	// это чужая память, купленная десятибайтовыми кадрами.
	if !replacing && *maxStreamsPerSess > 0 && len(s.streams) >= *maxStreamsPerSess {
		s.mu.Unlock()
		if s.noisy("stream_limit") {
			log.Printf("[%s] stream %d: превышен потолок стримов на сессию (%d) — отказ",
				s.id, id, *maxStreamsPerSess)
		}
		_ = conn.Close()
		events.Emit(Event{Ev: "dial_fail", SID: s.id, Install: s.relayID, Reason: "stream_limit", Detail: target})
		s.sendConnectResult(id, false)
		return
	}
	if replacing {
		old := s.streams[id]
		s.emitStreamClose(old, "replaced")
		old.aborted.Store(true)
		if old.conn != nil {
			_ = old.conn.Close()
		}
	}
	s.streams[id] = st
	liveStreams.Add(1)
	active := len(s.streams)
	for {
		cur := s.peakStreams.Load()
		if int32(active) <= cur || s.peakStreams.CompareAndSwap(cur, int32(active)) {
			break
		}
	}
	s.mu.Unlock()

	if *verbose {
		log.Printf("[%s] stream %d CONNECT %s ok (%s) active=%d", s.id, id, target, lat, active)
	}
	s.sendConnectResult(id, true)
	events.Emit(Event{Ev: "stream_open", SID: s.id, Install: s.relayID, DurMS: lat.Milliseconds(), Detail: target})

	go s.pumpReadFromTCP(st)
}

// pumpReadFromTCP copies upstream TCP bytes into DATA frames. On EOF it
// removes the stream from the map (so further peer-side writes ignore it)
// and emits an ordered CLOSE — but only if the stream wasn't aborted in
// parallel.
func (s *session) pumpReadFromTCP(st *stream) {
	// Буфер чтения — из пула, а не свой на каждый стрим.
	//
	// Раньше здесь стоял make([]byte, 64*1024) на КАЖДЫЙ стрим, и он жил всю
	// жизнь стрима, а стримы у Telegram живут часами. При наблюдаемых ~1300
	// туннелях это доминирующий член в RSS релея: около 400 КБ на туннель, из
	// которых основная часть — вот эти буферы. Потолок здесь не OOM: GOMEMLIMIT
	// мягкий, поэтому раньше него придёт непрерывный GC на двух ядрах, то есть
	// вязкий Telegram у всех и ни строчки в логах.
	bufp := readBufPool.Get().(*[]byte)
	buf := *bufp
	defer readBufPool.Put(bufp)
	for {
		n, err := st.conn.Read(buf)
		if n > 0 {
			// Кадр собираем СРАЗУ из буфера чтения: одно выделение и одно
			// копирование вместо двух. Раньше был payload := make(); copy(),
			// а потом encodeFrame выделял ещё раз и копировал повторно —
			// первая копия становилась мусором немедленно, то есть мы кормили
			// сборщик ровно объёмом трафика.
			s.sendDataFrame(st, encodeFrame(st.id, muxDATA, buf[:n]))
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
		s.emitStreamClose(st, "eof")
		s.sendOrderedClose(st)
	}
}

func (s *session) readPump() {
	defer s.kill()

	s.ws.SetReadLimit(2 * 1024 * 1024)
	_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
	s.ws.SetPongHandler(func(string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
		return nil
	})
	s.ws.SetPingHandler(func(data string) error {
		_ = s.ws.SetReadDeadline(time.Now().Add(*authReadTimeout))
		return s.ws.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(5*time.Second))
	})

	_, msg, err := s.ws.ReadMessage()
	if err != nil {
		if *verbose {
			log.Printf("[%s] auth read err: %v", s.id, err)
		}
		s.killWith(classifyReadErr(err, "auth_read_err"))
		return
	}
	sid, mt, p, err := decodeFrame(msg)
	if err != nil || sid != 0 || (mt != muxAUTH && mt != muxAUTHID) {
		log.Printf("[%s] first message not auth (sid=%d type=0x%02x)", s.id, sid, mt)
		s.killWith("first_not_auth")
		return
	}
	// Dual-accept (NO flip): a registered per-install Ed25519 signature (Stage B,
	// muxAUTHID) is always honored; the shared-secret HMAC (Stage A, muxAUTH) is
	// honored too — with the current AND previous secret — UNLESS the flip
	// (--require-per-install) is enabled. Nothing here blocks a current client.
	var relayID, scheme, why string
	authedOK := false
	if mt == muxAUTHID {
		relayID, authedOK, why = verifyPerInstallAuth(p)
		scheme = "per-install"
	} else if !*requirePerInstall {
		authedOK = subtle.ConstantTimeCompare(p, computeAuthHMAC(*secret)) == 1
		if !authedOK && *secretPrev != "" {
			authedOK = subtle.ConstantTimeCompare(p, computeAuthHMAC(*secretPrev)) == 1
		}
		scheme = "shared-secret"
		if !authedOK {
			// Флаг --require-per-install выключен, а общий секрет не сошёлся.
			why = "общий секрет не совпал"
		}
	}
	legacyScheme := false
	if mt != muxAUTHID && mt != muxAUTH {
		why = "неизвестный тип кадра"
	} else if why == "" && !authedOK {
		// Сюда попадает кадр 0x00 при включённом флаге: ветку общего секрета
		// пропустили целиком, поэтому причина не выставлена ни одной проверкой.
		why = "старая схема (общий секрет) при включённом требовании персональной"
		legacyScheme = true
	}
	if !authedOK {
		// Кадр 0x00 — это клиент до r-76.2, который ещё стучится общим
		// секретом. Общий секрет отменён, такие подключения отвергаются
		// всегда, и писать про каждое незачем: 18.08.2026 их было 28 329 за
		// сутки, треть всего журнала релея. Настоящие инциденты в этом шуме
		// не видно. Флот доедет до r-76.2+ сам, а строка на каждую попытку
		// не приближает этот момент ни на секунду.
		//
		// Всё остальное (неизвестный тип кадра, несовпавшая персональная
		// подпись, испорченный id) логируется как раньше — это уже не
		// «старый клиент», а либо ошибка, либо чужой стук.
		if !legacyScheme {
			log.Printf("[%s] auth rejected (type=0x%02x scheme=%s id=%s): %s", s.id, mt, scheme, relayID, why)
			events.Emit(Event{Ev: "auth_reject", SID: s.id, IP: s.clientIP, Install: relayID, Reason: why})
			metrics.inc("relay_auth_reject_total", fmt.Sprintf("reason=%q", authRejectClass(why)))
		}
		s.killWith("auth_rejected")
		return
	}
	if relayID != "" {
		if ok, why := acquireInstallSession(relayID, s.clientIP, s); !ok {
			log.Printf("[%s] отказ установке %s: %s", s.id, relayID, why)
			s.killWith("install_refused")
			return
		}
		s.relayID = relayID
		defer func() {
			rx, tx := s.bytes()
			releaseInstallSession(relayID, s, rx, tx)
		}()
	}
	log.Printf("[%s] authenticated (scheme=%s id=%s)", s.id, scheme, relayID)

	for {
		_, msg, err := s.ws.ReadMessage()
		if err != nil {
			if *verbose {
				log.Printf("[%s] read err: %v", s.id, err)
			}
			s.killWith(classifyReadErr(err, "read_err"))
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
			// Слот берём ЗДЕСЬ, до запуска горутины. Без слота — честный
			// CONNECT_FAIL: клиент попробует ещё раз, а мы не копим работу,
			// за которую никто не платил.
			if !s.acquireConnectSlot() {
				if s.noisy("connect_limit") {
					log.Printf("[%s] stream %d: превышен потолок одновременных CONNECT (%d) — отказ",
						s.id, sid, *maxPendingConnects)
				}
				s.sendConnectResult(sid, false)
				continue
			}
			go func(id uint16, pl []byte) {
				defer s.releaseConnectSlot()
				s.handleConnect(id, pl)
			}(sid, payload)
		case muxDATA:
			s.mu.Lock()
			st, ok := s.streams[sid]
			s.mu.Unlock()
			if !ok || st.conn == nil {
				continue
			}
			s.txBytes.Add(int64(len(payload)))
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

// buildVersion подставляется сборкой (-X main.buildVersion=...).
var buildVersion = "dev"

// liveStreams — стримы с открытым сокетом к DC; инкремент при вставке в
// карту сессии, декремент ровно один раз в emitStreamClose.
var liveStreams atomic.Int64

// WS buffers are per-connection and held for the connection's lifetime. With
// ~1600 concurrent tunnels the old 256KB read + 256KB write (512KB/conn, no
// pool) was ~840MB — ~85% of relay RSS, not workload. Read is small (upstream is
// read in 64KB chunks at pumpReadFromTCP and copied out, so the WS read buffer
// only needs to hold framing); write buffers are shared via a sync.Pool
// (gorilla's documented fix for "many conns, intermittent writes" — exactly us).
var wsWriteBufPool = &sync.Pool{}

var upgrader = websocket.Upgrader{
	ReadBufferSize:    32 * 1024,
	WriteBufferSize:   16 * 1024,
	WriteBufferPool:   wsWriteBufPool,
	CheckOrigin:       func(r *http.Request) bool { return true },
	EnableCompression: false,
}

// makeSessionID — случайный идентификатор сессии для сшивки строк лога.
//
// Раньше это было UnixNano()%100000 в base36: пять символов, полностью
// определяемые временем. Две сессии, начавшиеся в одну и ту же стотысячную
// долю секунды, получали ОДИН идентификатор, а при полутора тысячах туннелей и
// переподключении всего парка после рестарта это не редкость. Строки «адрес» и
// «установка» пишутся раздельно и сшиваются по нему — на коллизии сшивка
// приписывает чужой адрес чужой установке, то есть врёт ровно там, где мы
// собираемся искать злоупотребление.
// bytes возвращает накопленный объём за сессию (принято, отправлено).
func (s *session) bytes() (int64, int64) {
	return s.rxBytes.Load(), s.txBytes.Load()
}

func makeSessionID() string {
	var b [5]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Источник случайности недоступен — не выдумываем, а честно падаем на
		// прежнюю схему: плохой идентификатор лучше пустого.
		return strconv.FormatInt(time.Now().UnixNano()%100000, 36)
	}
	const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
	out := make([]byte, len(b))
	for i, v := range b {
		out[i] = alphabet[int(v)%len(alphabet)]
	}
	return string(out)
}

// /resolve endpoint: returns fresh DNS A records for a whitelisted set of
// Instagram hostnames. Used by routers to refresh their `ndmc ip host`
// entries (which would otherwise rot — Meta rotates edge IPs faster than
// our shipped defaults can keep up).
//
// Auth: X-Z2K-Auth header = hex(HMAC-SHA256(secret, body)). Body is JSON
// {"hosts":["instagram.com",...]}; response is {"results":{"host":["1.2.3.4",...]}}.
//
// Defense in depth: hosts must match insta-allowlist (apex + suffixes).
// Anything else is silently dropped from the response. Per-host LookupHost
// timeout is short; failures are also silently dropped.

// Аллоулист /resolve. Имя isInstaHost историческое: сюда добавился WhatsApp.
//
// WhatsApp попал по той же причине, что и Instagram, — блокировка идёт по
// диапазону адресов, а не по имени. Замер 2026-08-05: всё, что резолвится в
// 157.240.x, из РФ глухо, а 57.144/57.145/3.33/15.197 отвечают. Мета отдаёт то
// один диапазон, то другой, поэтому роутеру нужен зарубежный резолв, чтобы
// вообще увидеть живые варианты.
//
// wa.me и остальные витринные домены (whatsapp.cc/.info/.org/.tv,
// whatsappbrand.com из списка v2fly) сюда НЕ входят: они не участвуют в работе
// клиента, а каждый лишний домен — это лишняя статическая запись DNS на
// роутере, где потолок 256 и его уже однажды съели пинами Discord.
//
// 4pda.to здесь БЫЛ 19.08.2026 и снят в тот же день: блокировка по адресу
// продержалась несколько часов. Замер до неё — tls_handshake_timeout на
// 8.6.112.0 и 8.47.69.0; замер после снятия — те же адреса отвечают за 100 мс.
// Держать домен в аллоулисте ради временного блока смысла нет: пины пришлось
// бы обновлять ежедневно, а без них сайт открывается сам.
var instaApex = map[string]bool{
	"instagram.com":    true,
	"cdninstagram.com": true,
	"whatsapp.com":     true,
	"whatsapp.net":     true,
}
var instaSuffixes = []string{".instagram.com", ".cdninstagram.com", ".whatsapp.com", ".whatsapp.net"}

func isInstaHost(h string) bool {
	h = strings.ToLower(strings.TrimSuffix(h, "."))
	if instaApex[h] {
		return true
	}
	for _, suf := range instaSuffixes {
		if strings.HasSuffix(h, suf) {
			return true
		}
	}
	return false
}

// publicResolvers — у кого спрашиваем адреса в дополнение к системному.
//
// Ответ зависит от резолвера, и это не мелочь: замер 2026-08-05 по
// web.whatsapp.com с этой машины — 8.8.8.8 отдаёт 57.144.245.32 (из РФ
// работает), а 1.1.1.1 и 9.9.9.9 отдают 157.240.x (из РФ глухо). Спросив
// одного, можно не увидеть ни одного живого варианта вовсе.
var publicResolvers = []string{"8.8.8.8:53", "1.1.1.1:53", "9.9.9.9:53"}

// resolveV4Union собирает IPv4-адреса хоста у системного резолвера и у
// нескольких публичных, объединяя ответы.
//
// Объединение, а не «первый непустой», намеренно: роутер потом сам проверяет
// каждый адрес живым запросом и берёт тот, что ответил. Наша задача — дать ему
// выбор, а не выбрать за него: отсюда, из Европы, «живой» и «живой из РФ» это
// разные вещи, и решить это здесь нельзя в принципе.
func resolveV4Union(parent context.Context, host string) []string {
	ctx, cancel := context.WithTimeout(parent, 6*time.Second)
	defer cancel()

	seen := map[string]bool{}
	out := make([]string, 0, 8)
	add := func(ips []string) {
		for _, ip := range ips {
			if strings.Contains(ip, ":") || seen[ip] {
				continue
			}
			seen[ip] = true
			out = append(out, ip)
		}
	}

	if ips, err := net.DefaultResolver.LookupHost(ctx, host); err == nil {
		add(ips)
	}
	for _, rs := range publicResolvers {
		addr := rs
		res := &net.Resolver{
			PreferGo: true,
			Dial: func(c context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(c, network, addr)
			},
		}
		if ips, err := res.LookupHost(ctx, host); err == nil {
			add(ips)
		}
		if len(out) >= 8 {
			break
		}
	}
	if len(out) > 8 {
		out = out[:8]
	}
	return out
}

type resolveReq struct {
	Hosts []string `json:"hosts"`
}
type resolveResp struct {
	Results map[string][]string `json:"results"`
}

func handleResolve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	// /resolve has its OWN secret, decoupled from the tunnel secret: rotating the
	// tunnel credential must not break Instagram IP refresh, and the low-value
	// resolve secret (which lives in the shell client, i.e. public) must NOT grant
	// tunnel access. Falls back to --secret when --resolve-secret is unset.
	resolveHMAC := func(key string) string {
		m := hmac.New(sha256.New, []byte(key))
		m.Write(body)
		return hex.EncodeToString(m.Sum(nil))
	}
	rk := *resolveSecret
	if rk == "" {
		rk = *secret
	}
	got := r.Header.Get("X-Z2K-Auth")
	okResolve := subtle.ConstantTimeCompare([]byte(resolveHMAC(rk)), []byte(got)) == 1
	// Migration window: a not-yet-updated insta-refresh still signs with the old
	// shared secret (now passed as --secret-prev), so accept it too.
	if !okResolve && *secretPrev != "" {
		okResolve = subtle.ConstantTimeCompare([]byte(resolveHMAC(*secretPrev)), []byte(got)) == 1
	}
	if !okResolve {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req resolveReq
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if len(req.Hosts) == 0 || len(req.Hosts) > 32 {
		http.Error(w, "host count out of range", http.StatusBadRequest)
		return
	}
	results := make(map[string][]string)
	for _, h := range req.Hosts {
		if !isInstaHost(h) {
			if *verbose {
				log.Printf("resolve: reject %q (not insta-allowlisted)", h)
			}
			continue
		}
		v4 := resolveV4Union(r.Context(), h)
		if len(v4) == 0 {
			if *verbose {
				log.Printf("resolve %q: пусто", h)
			}
			continue
		}
		if len(v4) > 0 {
			results[h] = v4
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resolveResp{Results: results})
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
	// Потолок проверяется ДО апгрейда: после него соединение уже не HTTP, и
	// сказать клиенту «приходи через минуту» нечем — остаётся молча закрыть,
	// что для него неотличимо от обрыва.
	if ok, retry := acquireSession(); !ok {
		w.Header().Set("Retry-After", retryAfterHeader(retry))
		http.Error(w, "узел перегружен, попробуйте позже", http.StatusServiceUnavailable)
		return
	}
	defer releaseSession()

	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade err: %v", err)
		return
	}
	sid := makeSessionID()
	// Тот же разбор, что и у /register: последний элемент цепочки — тот, что
	// проставил наш прокси. Всё левее прислал клиент и подделать может любой.
	ip := resolveRemoteIP(r)
	log.Printf("[%s] WS accepted from %s", sid, ip)
	events.Emit(Event{Ev: "session_open", SID: sid, IP: ip, ASN: asnLookup(ip), Proto: "v1"})
	s := newSession(ws, sid, parentCtx)
	s.clientIP = ip
	started := time.Now()
	go s.writePump()
	s.readPump()

	// Строка закрытия несёт всё, что нужно для разбора, СРАЗУ — установку,
	// адрес, длительность и объём. Раньше здесь было только «WS closed», и
	// чтобы понять, кто это был, приходилось сшивать три разные строки по
	// идентификатору сессии. Для поиска того, кто раздаёт наш туннель дальше,
	// нужен ровно этот набор в одном месте: одна установка, много адресов.
	rx, tx := s.bytes()
	who := s.relayID
	if who == "" {
		who = "-"
	}
	log.Printf("[%s] WS closed install=%s ip=%s dur=%s rx=%d tx=%d reason=%s",
		sid, who, ip, time.Since(started).Truncate(time.Second), rx, tx, s.closeReason())
	events.Emit(Event{
		Ev: "session_close", SID: sid, Install: who, IP: ip, ASN: asnLookup(ip), Proto: s.proto,
		DurMS: time.Since(started).Milliseconds(), RX: rx, TX: tx,
		Streams: int(s.peakStreams.Load()), Reason: s.closeReason(), Detail: s.noisyDetail(),
	})
	metrics.inc("relay_session_close_total", fmt.Sprintf("reason=%q", s.closeReason()))
}

// asnLookup — заглушка до задачи 6 плана (таблица ASN).
func asnLookup(ip string) uint32 { return 0 }

func main() {
	flag.Parse()

	// Секреты могут приходить как env:ИМЯ или @/путь — тогда в командной строке
	// остаётся только ссылка. Разбор идёт сразу после разбора флагов, чтобы
	// дальше по коду секрет был обычной строкой (см. secretsrc.go).
	if err := resolveAllSecrets(); err != nil {
		log.Fatalf("секреты: %v", err)
	}
	if *eventsDir != "" {
		fe, err := newFileEvents(*eventsDir, *eventsKeep)
		if err != nil {
			log.Fatalf("события: %v", err)
		}
		events = fe
		defer fe.Close()
	}
	metrics.gauge("relay_sessions", func() int64 { return liveSessions.Load() })
	metrics.gauge("relay_streams", func() int64 { return liveStreams.Load() })
	metrics.gauge("relay_event_write_errors_total", func() int64 { return eventWriteErrors.Load() })
	metrics.add("relay_build_info", fmt.Sprintf("version=%q", buildVersion), 1)
	if *secret == "" {
		log.Fatal("--secret is required")
	}

	if err := parseExtraCIDRs(*extraCIDRs); err != nil {
		log.Fatal(err)
	}

	initRegistry(*registryPath)
	if *requirePerInstall {
		log.Printf("FLIP ACTIVE: --require-per-install — only registered per-install signatures accepted")
	}
	if len(extraV4) > 0 {
		log.Printf("non-Telegram allowlist extras loaded: %d CIDR(s)", len(extraV4))
	}

	dialThrottle = newDialLimiter(*dialLimitPerTarget, *dialThrottleTimeout)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	statsStop := make(chan struct{})
	go stats.loop(*dialStatsInterval, statsStop)
	go installs.snapshotLoop(*installSnapshotInterval, statsStop)

	stopAdmin := startAdmin(*adminAddr)
	defer stopAdmin()

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		handleWS(ctx, w, r)
	})
	mux.HandleFunc("/resolve", handleResolve)
	mux.HandleFunc("/register", handleRegister)
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

	log.Printf("z2k vps-relay listening on %s (dial-limit-per-target=%d, dial-throttle-timeout=%s, dial-per-attempt-timeout=%s, dial-retry-count=%d, dial-retry-backoff=%s, per-stream-bytes=%d, session-bytes=%d, session-depth=%d, control-depth=%d, stats-interval=%s)",
		*listenAddr, *dialLimitPerTarget, *dialThrottleTimeout, *dialPerAttemptTimeout, *dialRetryCount, *dialRetryBackoff, *perStreamQueueBytes, *sessionQueueBytes, *sessionQueueDepth, *controlQueueDepth, *dialStatsInterval)

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
