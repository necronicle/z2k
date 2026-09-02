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

var (
	listenAddr           = flag.String("listen", ":8080", "HTTP listen address (TLS terminated upstream by Caddy)")
	secret               = flag.String("secret", "", "shared HMAC secret (must match tunnel client)")
	secretPrev           = flag.String("secret-prev", "", "previous shared HMAC secret, still accepted during rotation (dual-accept; empty=off, NO flip yet)")
	resolveSecret        = flag.String("resolve-secret", "", "dedicated HMAC secret for /resolve (decoupled from the tunnel secret); falls back to --secret when empty")
	verbose              = flag.Bool("v", false, "verbose logging")
	eventsDir            = flag.String("events-dir", "", "каталог структурного журнала событий (пусто = выключено)")
	eventsKeep           = flag.Int("events-keep", 30, "сколько суточных файлов событий хранить")
	authReadTimeout      = flag.Duration("auth-read-timeout", 90*time.Second, "таймаут чтения WS до и после авторизации")
	defaultWindow        = flag.Int("default-window", 256*1024, "начальный кредит на стрим, байт (v2)")
	upstreamWriteTimeout = flag.Duration("upstream-write-timeout", 15*time.Second, "дедлайн записи в сокет DC")
	wsWriteTimeout       = flag.Duration("ws-write-timeout", 10*time.Second, "дедлайн записи кадра в WS")
	minBuild             = flag.String("min-build", "", "минимальная версия клиента v2 (пусто = не требовать)")
	drainTimeout         = flag.Duration("drain-timeout", 90*time.Second, "сколько ждать сессии при остановке")
	asnTablePath         = flag.String("asn-table", "", "путь к ip2asn-v4.tsv (пусто = ASN в событиях не пишется)")

	dialLimitPerTarget    = flag.Int("dial-limit-per-target", 32, "max in-flight dials per Telegram DC IP (поверх потолка 6 на установку)")
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
		b := make([]byte, readBufSize)
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
	return l.bucketForN(target, l.limit)
}

func (l *dialLimiter) bucketForN(key string, limit int) chan struct{} {
	l.mu.Lock()
	defer l.mu.Unlock()
	bucket, ok := l.buckets[key]
	if !ok {
		bucket = make(chan struct{}, limit)
		l.buckets[key] = bucket
	}
	l.lastUsed[key] = time.Now()
	return bucket
}

// perInstallDialLimit — потолок одновременных дозвонов одной установки к
// одному адресату: столько же, сколько connectSem у клиента.
const perInstallDialLimit = 6

// acquire2 — сначала ведро «установка|адресат», затем общее ведро адресата.
// Так один клиент не съедает чужой доступ к DC (аудит 02.09.2026).
func (l *dialLimiter) acquire2(ctx context.Context, install, target string) (func(), error) {
	rel1, err := l.acquireN(ctx, install+"|"+target, perInstallDialLimit)
	if err != nil {
		return nil, err
	}
	rel2, err := l.acquire(ctx, target)
	if err != nil {
		rel1()
		return nil, err
	}
	return func() { rel2(); rel1() }, nil
}

// acquire returns a release closure that frees the slot exactly once.
// The returned function is safe to call multiple times — only the first call
// releases the slot.
func (l *dialLimiter) acquire(ctx context.Context, target string) (release func(), err error) {
	return l.acquireN(ctx, target, l.limit)
}

func (l *dialLimiter) acquireN(ctx context.Context, key string, limit int) (release func(), err error) {
	bucket := l.bucketForN(key, limit)
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

var upgrader = websocket.Upgrader{
	ReadBufferSize:    8 * 1024, // payload копируется наружу, буфер нужен только под заголовок кадра
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
	s := newSession(ws, sid, ip, parentCtx)
	started := time.Now()
	s.run()

	// Строка закрытия несёт всё, что нужно для разбора, СРАЗУ — установку,
	// адрес, длительность, объём и причину.
	rx, tx := s.bytes()
	who := s.relayID
	if who == "" {
		who = "-"
	}
	log.Printf("[%s] WS closed install=%s ip=%s dur=%s rx=%d tx=%d reason=%s",
		sid, who, ip, time.Since(started).Truncate(time.Second), rx, tx, s.closeReason())
	emitEvent(Event{
		Ev: "session_close", SID: sid, Install: who, IP: ip, ASN: asnLookup(ip), Proto: s.proto().name(),
		DurMS: time.Since(started).Milliseconds(), RX: rx, TX: tx,
		Streams: int(s.peakStreams.Load()), Reason: s.closeReason(), Detail: s.noisyDetail(),
	})
	metrics.inc("relay_session_close_total", fmt.Sprintf("reason=%q", s.closeReason()))
}

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
		setEvents(fe)
		defer fe.Close()
	}
	metrics.gauge("relay_sessions", func() int64 { return liveSessions.Load() })
	metrics.gauge("relay_streams", func() int64 { return liveStreams.Load() })
	metrics.gauge("relay_event_write_errors_total", func() int64 { return eventWriteErrors.Load() })
	metrics.add("relay_build_info", fmt.Sprintf("version=%q", buildVersion), 1)
	budget.setLimit(memLimitBytes())
	metrics.gauge("relay_queue_bytes", func() int64 { return budget.used.Load() })
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
	if *asnTablePath != "" {
		if t, err := loadASNTable(*asnTablePath); err != nil {
			log.Printf("ASN-таблица не загружена: %v (события пойдут без asn)", err)
		} else {
			asnTab.Store(t)
		}
		go watchASNTable(*asnTablePath, time.Hour, ctx.Done())
	}
	defer stop()

	statsStop := make(chan struct{})
	go stats.loop(*dialStatsInterval, statsStop)
	go budget.trimLoop(500*time.Millisecond, statsStop)
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
		drainSessions(*drainTimeout)
		close(statsStop)
		dialThrottle.close()
		if err := <-serveErr; err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
		log.Printf("server stopped")
	}
}
