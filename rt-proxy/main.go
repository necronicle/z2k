// z2k-rt-proxy — transparent SNI-routed bridge to an upstream HTTPS CONNECT proxy.
//
// Mirrors the official RuTracker browser extension's mechanism, but at the
// router level: for each incoming (DNAT-redirected) TLS connection it peeks the
// ClientHello SNI, dials a HEALTH-CHECKED upstream HTTPS proxy IP over TLS,
// issues `CONNECT <sni>:443`, replays the buffered ClientHello and splices the
// streams. The upstream proxy (e.g. ps1.blockme.site, run by RuTracker) reaches
// the real site from abroad, so the RU CF-edge transit / SNI block is bypassed.
//
// The upstream is an IP POOL behind one hostname; ~1/3 of the IPs are RU-blocked
// at any time and rotate, so a background health-check keeps a live subset and
// connections only ever use live IPs. No auth (the public proxy needs none).
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	listenAddr  = flag.String("listen", ":1445", "local listen address")
	proxyHost   = flag.String("proxy-host", "ps1.blockme.site", "upstream HTTPS proxy hostname (TLS SNI to the proxy)")
	proxyPort   = flag.String("proxy-port", "443", "upstream proxy port")
	seedIPs     = flag.String("ips", "", "comma-separated upstream proxy IPs (seed pool; re-resolved from proxy-host too)")
	healthEvery = flag.Duration("health-interval", 90*time.Second, "health-check interval for the IP pool")
	healthHost  = flag.String("health-target", "rutracker.org:443", "CONNECT target used to probe a proxy IP")

	// Пин SPKI цели health-проверки. Пусто = проверка выключена.
	//
	// Апстрим-узлы берутся из чужого публичного списка, их сертификат мы не
	// проверяем и проверить не можем. В probeProxy по внутреннему рукопожатию
	// принимается решение «узел живой», и без пина подставной узел завершает
	// TLS своим ключом, отдаёт правдоподобный мусор и остаётся в кольце —
	// health-poisoning. Значение подставляется при первом успешном замере
	// (см. verifyHealthSPKI): держать чужой отпечаток захардкоженным в коде
	// нельзя, его перевыпустят без нас.
	healthSPKIPin = flag.String("health-spki-pin", "", "base64 SHA-256 of the health target's SubjectPublicKeyInfo (empty = no check, fingerprint is logged once)")
	dialTO        = flag.Duration("dial-timeout", 8*time.Second, "dial/handshake timeout for live connections")
	probeTO       = flag.Duration("probe-timeout", 12*time.Second, "total budget for one END-TO-END health probe (dial + CONNECT + inner TLS to the target)")
	recoverEvery  = flag.Duration("recover-interval", 10*time.Second, "faster re-probe interval while the pool has 0 live IPs")
	// Настоящий idle-таймаут: соединение закрывается, когда в ОБЕ стороны не
	// прошло ни байта в течение этого срока. Сторож в handle() смотрит на
	// отметку последней активности, которую обновляет всякое чтение, реально
	// сдвинувшее байты (activityReader).
	//
	// Здесь стояло предупреждение, что это не idle, а абсолютный потолок
	// жизни соединения — «таймер создаётся один раз и не сбрасывается». Оно
	// описывало прежнюю реализацию и с тех пор устарело: сторож с атомарной
	// отметкой как раз и был сделан вместо того таймера (см. комментарий у
	// watchdog в handle). Оставленное предупреждение утверждало обратное
	// тому, что делает код, — а именно в этом файле расхождение опаснее
	// всего: зависание здесь клиенту не видно.
	idleTO         = flag.Duration("timeout", 15*time.Minute, "per-connection IDLE timeout: closed after this long with no bytes moving in either direction")
	pickWaitTO     = flag.Duration("pick-wait", 15*time.Second, "max wait for a live upstream before dropping (cold-start / transient-empty smoothing)")
	maxTries       = flag.Int("max-tries", 4, "max upstream IPs to try per connection before dropping")
	firstByteTO    = flag.Duration("first-byte-timeout", 4*time.Second, "how long an upstream has to deliver the server's first TLS handshake record after the replayed ClientHello before it is demoted and another one is tried")
	resolverAddr   = flag.String("resolver", "1.1.1.1:53", "DNS server queried DIRECTLY for the upstream pool, to bypass the router's ndnproxy whose cache goes stale and strands the pool on dead IPs (system resolver is still used as a fallback/union)")
	probePath      = flag.String("probe-path", "/forum/index.php", "path fetched THROUGH each upstream when probing — must return a sizeable body, not a redirect")
	probeBytes     = flag.Int("probe-bytes", 8192, "body bytes an upstream must actually deliver to count as live")
	maxClients     = flag.Int("max-clients", 128, "ceiling on concurrent client connections; further connections are refused immediately rather than queued")
	directFallback = flag.Bool("direct-fallback", true, "when no upstream can serve the target, resolve it ourselves and connect DIRECTLY instead of dropping the client")
	directHosts    = flag.String("direct-fallback-hosts", "rutracker.org,rutracker.wiki,rutracker.cc,t-ru.org", "comma-separated suffixes eligible for the direct fallback — NOT a general escape hatch, see dialDirect")
	resolveTO      = flag.Duration("resolve-timeout", 5*time.Second, "DNS budget PER RESOLVER (not shared: a blocked direct resolver must not starve the system-resolver fallback)")
	verbose        = flag.Bool("v", false, "verbose logging")
)

func main() {
	flag.Parse()
	p := &pool{}
	if *seedIPs != "" {
		for _, ip := range strings.Split(*seedIPs, ",") {
			if ip = strings.TrimSpace(ip); ip != "" {
				p.seed = append(p.seed, ip)
				p.all = append(p.all, ip)
			}
		}
	}
	go p.healthLoop()

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("[rt-proxy] listen %s: %v", *listenAddr, err)
	}
	log.Printf("[rt-proxy] listening on %s, upstream %s:%s", *listenAddr, *proxyHost, *proxyPort)
	serve(ln, p, *maxClients)
}

// tryAcquire takes a slot without blocking. Split out so the ceiling decision is
// unit-testable: the only other way to exercise it was to start serve() and hold
// real connections, and those handlers outlive the test by up to --pick-wait while
// still reading flag globals that LATER tests write — a genuine -race failure, and
// a goroutine leak, in a test whose whole point was resource discipline.
func tryAcquire(sem chan struct{}) bool {
	select {
	case sem <- struct{}{}:
		return true
	default:
		return false
	}
}

// serve is the accept loop, split out of main() so the connection ceiling is
// testable. It was inline, which is why "no cap on concurrent clients" sat in the
// open column: nothing could assert the behaviour.
func serve(ln net.Listener, p *pool, maxClients int) {
	// Ceiling on concurrent clients. Each one costs a 33 KiB tunnel reader, two
	// io.Copy buffers, a watchdog and three goroutines, and there was NO limit at
	// all: on a 500 MB router with a documented history of the OOM killer taking
	// daemons out, "unbounded" is a real hazard even if a LAN is unlikely to reach
	// it. Refuse immediately rather than queue — a queued client just hangs, which
	// is the failure mode this whole file exists to avoid.
	sem := make(chan struct{}, maxClients)
	var refused uint64
	for {
		c, err := ln.Accept()
		if err != nil {
			// A permanently closed listener is terminal: the old loop logged and
			// slept 200 ms forever, spinning a dead goroutine and a log line five
			// times a second. Benign in production (the listener never closes) but
			// it also made serve() impossible to stop, which leaked goroutines
			// across tests and produced a real -race failure.
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("[rt-proxy] accept: %v", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		if !tryAcquire(sem) {
			refused++
			c.Close()
			// Log the first refusal and then every 100th, so a flood cannot itself
			// become the resource problem.
			if refused == 1 || refused%100 == 0 {
				log.Printf("[rt-proxy] at the %d-connection ceiling — refused %d so far (--max-clients)",
					maxClients, refused)
			}
			continue
		}
		{
			go func(c net.Conn) {
				defer func() { <-sem }()
				handle(c, p)
			}(c)
		}
	}
}

// ---------------------------------------------------------------------------
// upstream proxy IP pool with background health-checking
// ---------------------------------------------------------------------------
type pool struct {
	mu   sync.RWMutex
	seed []string // immutable seed IPs from --ips; always kept as candidates
	all  []string // current candidate set = seed ∪ latest-resolved ∪ currently-live
	live []string // IPs that passed the latest CONNECT probe
	rr   uint64   // round-robin cursor
}

func (p *pool) pick() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.live) == 0 {
		return ""
	}
	p.rr++
	return p.live[p.rr%uint64(len(p.live))]
}

// demote drops ip from the live set the moment it fails on REAL traffic, without
// waiting for the next health cycle. The health probe is a snapshot up to
// health-interval old, and a node can pass it and stall a minute later — that gap is
// what made RuTracker "work, then not work, then work again": pick() round-robins, so
// whether a page loaded depended purely on which node the cursor handed you. A node
// that just proved itself dead must leave the ring immediately; probeAll will let it
// back in when it genuinely recovers.
func (p *pool) demote(ip string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := p.live[:0]
	for _, x := range p.live {
		if x != ip {
			out = append(out, x)
		}
	}
	p.live = out
}

func (p *pool) liveCount() int {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return len(p.live)
}

func (p *pool) healthLoop() {
	p.resolve()        // populate the pool from DNS BEFORE the first probe
	go p.refreshLoop() // and keep re-resolving in the background
	for {
		p.probeAll()
		// RU blocks a rotating subset of the blockme pool, so there are windows where
		// every currently-known IP is dead at once (health: 0/N live). While the pool
		// is empty, re-resolve + re-probe every recoverEvery (~10s) instead of waiting
		// a full healthEvery — otherwise the proxy starves a whole minute (or longer)
		// after an upstream comes back, and rutracker stays dead the entire time.
		d := *healthEvery
		if p.liveCount() == 0 {
			d = *recoverEvery
			p.resolve()
		}
		time.Sleep(d)
	}
}

// refreshLoop periodically re-resolves the proxy hostname to pick up pool
// rotation. Runs SEPARATELY from probeAll so a slow/poisoned resolve never
// delays the probe → live set.
func (p *pool) refreshLoop() {
	t := time.NewTicker(*healthEvery)
	defer t.Stop()
	for range t.C {
		p.resolve()
	}
}

// resolve fetches the current upstream IP pool the SAME way the browser
// extension does — by resolving the proxy hostname (ps1.blockme.site), NOT from
// any hardcoded address. The operator rotates the pool via DNS; we just follow
// it. Only real IPs are kept (the RU resolver occasionally returns poisoned
// junk hostnames).
//
// The candidate set is REBUILT here, not just appended to: all = seed ∪
// latest-resolved ∪ currently-live. Append-only growth meant every IP the
// hostname ever returned stayed in p.all forever, so over a long uptime
// probeAll fanned out a TLS dial to an ever-growing pile of long-dead IPs every
// health interval. Rebuilding drops IPs that have both fallen out of DNS and
// failed the latest probe, while still retaining a temporarily-unresolved IP
// that is currently live (DNS blip) and the immutable --ips seed.
// directResolver queries *resolverAddr directly (Go's own resolver, no OS /
// ndnproxy cache in the path). The router's ndnproxy caches ps1.blockme.site
// and can serve a stale/poisoned set for a long time, stranding the pool on
// dead IPs — the "hangs for minutes until a DNS nudge" symptom (a browser using
// the official extension re-resolves fresh; we do the same here).
func directResolver() *net.Resolver {
	return &net.Resolver{
		PreferGo: true,
		// Honour the network the resolver asks for. It starts on UDP and RETRIES
		// OVER TCP when the answer comes back truncated (TC=1) — the pool is a
		// dozen-plus A records, so it is one growth spurt away from crossing 512
		// bytes. Hard-coding "udp" would hand the TCP retry a UDP socket, the
		// direct lookup would fail, and we would silently fall back to exactly the
		// stale ndnproxy answer this resolver exists to bypass.
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 4 * time.Second}
			return d.DialContext(ctx, network, *resolverAddr)
		},
	}
}

// hostLookuper is the slice of *net.Resolver that resolve() consults, behind an
// interface so a test can substitute stubs. resolve() used to construct both
// resolvers inline, which made it unreachable from a test - and it is where the
// shared-deadline bug below lived, untested, for its whole life.
type hostLookuper interface {
	LookupHost(ctx context.Context, host string) ([]string, error)
}

var resolversFor = func() []hostLookuper {
	return []hostLookuper{directResolver(), net.DefaultResolver}
}

func (p *pool) resolve() {
	// Union of a DIRECT resolver (fresh rotation, bypasses the stale ndnproxy
	// cache) and the system resolver (fallback if the direct one is blocked /
	// hijacked). The end-to-end probe filters whatever these return down to
	// genuinely-live IPs, so a few stale entries in the union are harmless.
	seenR := map[string]bool{}
	var resolved []string
	for _, r := range resolversFor() {
		// EACH resolver gets its own budget. A single shared deadline meant a
		// blocked direct resolver consumed all of it and handed the system
		// resolver an already-expired context, so the fallback documented on the
		// --resolver flag could never run in the one situation it exists for:
		// an ISP filtering 1.1.1.1:53. resolved then came back empty, resolve()
		// took the early return below, and the candidate pool was never
		// populated at all - the daemon stayed dead with a healthy-looking log.
		// Covered by TestResolve_BlockedDirectResolverStillLetsTheFallbackAnswer.
		ctx, cancel := context.WithTimeout(context.Background(), *resolveTO)
		hosts, err := r.LookupHost(ctx, *proxyHost)
		cancel()
		if err != nil && *verbose {
			log.Printf("[rt-proxy] resolve %s: %v", *proxyHost, err)
		}
		for _, ip := range hosts {
			if net.ParseIP(ip) != nil && !seenR[ip] {
				seenR[ip] = true
				resolved = append(resolved, ip)
			}
		}
	}
	if len(resolved) == 0 {
		return // keep the existing candidate set on a failed/empty resolve
	}
	p.mu.Lock()
	seen := map[string]bool{}
	next := make([]string, 0, len(p.seed)+len(resolved)+len(p.live))
	add := func(ip string) {
		if ip != "" && net.ParseIP(ip) != nil && !seen[ip] {
			seen[ip] = true
			next = append(next, ip)
		}
	}
	for _, ip := range p.seed {
		add(ip)
	}
	for _, ip := range resolved {
		add(ip)
	}
	for _, ip := range p.live { // retain currently-live IPs through a DNS blip
		add(ip)
	}
	p.all = next
	p.mu.Unlock()
}

// probeAll probes every known IP in PARALLEL and atomically swaps in the live
// set. Parallel keeps this ~= probeTO regardless of how many pool IPs are dead.
func (p *pool) probeAll() {
	p.mu.RLock()
	all := append([]string(nil), p.all...)
	p.mu.RUnlock()
	var wg sync.WaitGroup
	var lmu sync.Mutex
	var live, degraded []string
	for _, ip := range all {
		wg.Add(1)
		go func(ip string) {
			defer wg.Done()
			// Same reasoning as handle(): probeProxy parses bytes from an untrusted
			// upstream, and a panic here would kill the daemon rather than one probe.
			defer func() {
				if r := recover(); r != nil {
					log.Printf("[rt-proxy] panic probing %s: %v — treated as dead", ip, r)
				}
			}()
			full, hs := probeProxy(ip)
			lmu.Lock()
			if full {
				live = append(live, ip)
			}
			if hs {
				degraded = append(degraded, ip)
			}
			lmu.Unlock()
		}(ip)
	}
	wg.Wait()
	// SAFETY VALVE. The strict bar is "delivers real body bytes of probe-path", which is
	// what finally excluded the nodes that relay small answers and stall on a real page.
	// But it now depends on a URL we do not own: if RuTracker renames or redirects that
	// path, EVERY node fails the body stage at once and the pool would go empty — the
	// tool would take itself offline over a cosmetic upstream change. So when nothing
	// clears the strict bar, fall back to the nodes that at least completed the tunnel,
	// and say so loudly.
	if len(live) == 0 && len(degraded) > 0 {
		log.Printf("[rt-proxy] no upstream delivered body bytes of %s — falling back to %d handshake-only node(s); check probe-path",
			*probePath, len(degraded))
		live = degraded
	}
	p.mu.Lock()
	prev := len(p.live)
	p.live = live
	p.mu.Unlock()
	// Log on every CHANGE, not only when the pool empties. Field triage needs to see "3/17
	// live" — a user whose ISP blocks most of the pool looks identical, from the outside, to
	// a user hitting a bug in our code, and without this line the only observable state was
	// silence. Steady state stays quiet: no line while the count is unchanged.
	// len(live) == 0 is included on purpose: a pool that has been empty since start never
	// "changes", so logging only on change silently removed the one case that was previously
	// always reported — the case a user actually needs to see.
	if *verbose || len(live) != prev || len(live) == 0 {
		log.Printf("[rt-proxy] health: %d/%d upstream IPs live", len(live), len(all))
	}
}

// verifyHealthSPKI сверяет открытый ключ листового сертификата с пином.
//
// Пин — SHA-256 от SubjectPublicKeyInfo, а не от сертификата целиком: у цели
// health-проверки сертификат перевыпускается, а ключ при перевыпуске обычно
// сохраняют, поэтому пин листа превращался бы в кирпич при каждом обновлении.
//
// БЕЗ ЗАДАННОГО ПИНА ПРОВЕРКИ НЕТ — поведение ровно такое же, как до появления
// этого кода. Так сделано намеренно, и вот почему отвергнут вариант с TOFU
// (запомнить ключ при первом замере): цель нам не принадлежит. Легальная смена
// ключа на её стороне при TOFU уронила бы проверку у ВСЕХ узлов разом, пул
// опустел бы, и rt-proxy перестал бы работать целиком — авария, устроенная нам
// третьей стороной без нашего участия. Отпечаток печатается в лог один раз,
// чтобы оператор мог закрепить его осознанно:
//
//	--health-spki-pin=<то, что напечатано>
//
// Тогда подставной узел, завершающий внутреннее рукопожатие своим ключом
// (health-poisoning: узел проходит проверку и остаётся в кольце, не отдавая
// реальных данных), отсекается.
var healthSPKILogged sync.Once

func spkiFingerprint(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return base64.StdEncoding.EncodeToString(sum[:])
}

func verifyHealthSPKI(rawCerts [][]byte) error {
	if len(rawCerts) == 0 {
		return errors.New("health target presented no certificate")
	}
	leaf, err := x509.ParseCertificate(rawCerts[0])
	if err != nil {
		return fmt.Errorf("health target certificate unparsable: %w", err)
	}
	got := spkiFingerprint(leaf)

	if *healthSPKIPin == "" {
		healthSPKILogged.Do(func() {
			log.Printf("[rt-proxy] отпечаток ключа цели health-проверки: %s "+
				"(закрепить: --health-spki-pin=%s)", got, got)
		})
		return nil
	}
	if got != *healthSPKIPin {
		return fmt.Errorf("health target SPKI mismatch: got %s, pinned %s", got, *healthSPKIPin)
	}
	return nil
}

// probeProxy returns true only if the IP relays traffic to the health target
// END-TO-END: it must accept the CONNECT *and* carry a real TLS handshake
// through to the target. The old CONNECT-200-only check passed nodes that
// accept the CONNECT but then stall on real data — exactly the ones that
// produced the client-visible 000s (this is what the official RuTracker client
// does: it validates a proxy by fetching THROUGH it, not just connecting).
// Bounded by a single probeTO budget (dial + CONNECT + inner TLS).
func probeProxy(ip string) (full bool, handshake bool) {
	deadline := time.Now().Add(*probeTO)
	up, err := dialProxyDeadline(ip, deadline)
	if err != nil {
		if *verbose {
			log.Printf("[rt-proxy] probe %s: dial/tls failed: %v", ip, err)
		}
		return false, false
	}
	defer up.Close()
	up.SetDeadline(deadline)

	fmt.Fprintf(up, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: Keep-Alive\r\n\r\n", *healthHost, *healthHost)
	br := bufio.NewReader(up)
	status, err := br.ReadString('\n')
	if err != nil || !strings.Contains(status, " 200") {
		if *verbose {
			log.Printf("[rt-proxy] probe %s: CONNECT reply %q err=%v", ip, strings.TrimSpace(status), err)
		}
		return false, false
	}
	for { // drain the rest of the CONNECT response headers
		line, e := br.ReadString('\n')
		if e != nil {
			return false, false
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	// End-to-end proof: a real TLS handshake to the health target THROUGH the
	// tunnel. A node that accepts CONNECT but cannot actually reach rutracker
	// fails here (RST / EOF / timeout) and is correctly marked dead.
	host := *healthHost
	if h, _, e := net.SplitHostPort(host); e == nil {
		host = h
	}
	// InsecureSkipVerify здесь остаётся — на Entware/musl нет системного
	// CA-бандла, и обычная проверка цепочки просто не с чем сверяться. Но в
	// ОТЛИЧИЕ от dialProxyDeadline, где сквозной TLS проверяет настоящий клиент
	// (браузер, curl), здесь клиент — мы сами, и по этому рукопожатию мы
	// принимаем решение «узел живой». Обоснование «MITM невозможен, потому что
	// внутри сквозной TLS» для этой точки ЛОЖНО.
	//
	// Поэтому сверяем отпечаток открытого ключа (SPKI) листового сертификата.
	// Пин именно SPKI, а не сертификата: у rutracker он самоподписанный и
	// перевыпускается, а ключ при перевыпуске обычно сохраняют. Пустой пин =
	// проверка выключена (путь отката, если ключ всё же сменят).
	inner := tls.Client(&bufConn{br: br, Conn: up}, &tls.Config{
		ServerName:         host,
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			return verifyHealthSPKI(rawCerts)
		},
	})
	if err := inner.Handshake(); err != nil {
		if *verbose {
			log.Printf("[rt-proxy] probe %s: inner TLS to %s failed: %v", ip, host, err)
		}
		return false, false
	}
	// A completed handshake is STILL not proof. Measured on-router: two pool nodes passed
	// this exact check every cycle (health said 7/17 live) yet could not deliver a single
	// byte of a real page — curl through them stalled right after the certificate flight,
	// 0 bytes downloaded, 2 out of 2 attempts, reproducibly. They were ~28% of the live
	// ring, which is precisely the share of RuTracker page loads that hung. So finish the
	// job the official client does and FETCH through the tunnel: require a real HTTP
	// response line over the session we just established.
	// ...and a RESPONSE LINE is not proof either. Measured on-router against the two bad
	// nodes: HEAD returned a clean 301 through both, while a GET of a real page returned
	// 0 bytes and hung, reproducibly. They relay small answers and stall on the first real
	// transfer — which is why CONNECT, the TLS handshake and a HEAD probe all waved them
	// through while ~28% of page loads (their share of the ring) hung. So pull actual BODY
	// BYTES, the way the official client validates a proxy by fetching through it.
	fmt.Fprintf(inner, "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n",
		*probePath, host)
	rd := bufio.NewReader(inner)
	line, err := rd.ReadString('\n')
	if err != nil || !strings.Contains(line, " 200") {
		if *verbose {
			log.Printf("[rt-proxy] probe %s: no 200 for %s from %s (%q, %v)", ip, *probePath, host, strings.TrimSpace(line), err)
		}
		return false, true
	}
	for { // drain response headers
		l, e := rd.ReadString('\n')
		if e != nil {
			return false, true
		}
		if l == "\r\n" || l == "\n" {
			break
		}
	}
	if n, err := io.CopyN(io.Discard, rd, int64(*probeBytes)); err != nil || n < int64(*probeBytes) {
		if *verbose {
			log.Printf("[rt-proxy] probe %s: stalled after %d/%d body bytes (%v)", ip, n, *probeBytes, err)
		}
		return false, true
	}
	return true, true
}

// bufSize is the tunnel reader's size. Single source of truth: the test asserts
// against THIS constant, so the buffer and the assertion cannot drift apart.
const bufSize = 33 * 1024

// bufConn lets crypto/tls read through a bufio.Reader that may still hold bytes
// buffered while reading the CONNECT response, then fall through to the raw
// conn. Writes and deadlines go straight to the embedded conn.
type bufConn struct {
	br *bufio.Reader
	net.Conn
}

func (b *bufConn) Read(p []byte) (int, error) { return b.br.Read(p) }

// ---------------------------------------------------------------------------
// per-connection handling
// ---------------------------------------------------------------------------
// Takes an ABSOLUTE deadline, not a duration. With a duration the dial got the
// whole budget and then the TLS handshake got a FRESH one of the same length, so a
// node that completed a slow TCP handshake and then stalled in TLS cost 2x what
// the caller asked for. probeProxy documents "bounded by a single probeTO", and
// with probeTO=12s a blackholed node could burn ~24s; since probeAll waits on all
// probes, that stretched the whole health cycle and, when the pool was empty, made
// the 10s recover cadence effectively ~34s — in exactly the window users are
// waiting. openTunnel had the same doubling at 8s per try.
func dialProxyDeadline(ip string, deadline time.Time) (net.Conn, error) {
	d := net.Dialer{Deadline: deadline}
	raw, err := d.Dial("tcp", net.JoinHostPort(ip, *proxyPort))
	if err != nil {
		return nil, err
	}
	// InsecureSkipVerify: the upstream is a CONNECT transport only — the
	// end-to-end TLS to the real site flows INSIDE the tunnel and is verified by
	// the actual client (browser/curl), so the proxy cannot MITM it. We also
	// can't rely on a system CA bundle being present on Entware/musl.
	tc := tls.Client(raw, &tls.Config{
		ServerName:         *proxyHost,
		InsecureSkipVerify: true,
		NextProtos:         []string{"http/1.1"}, // curl negotiates ALPN to the proxy; some proxies close without it
	})
	tc.SetDeadline(deadline)
	if err := tc.Handshake(); err != nil {
		raw.Close()
		return nil, err
	}
	tc.SetDeadline(time.Time{})
	return tc, nil
}

// dialUpstream returns a live upstream tunnel (CONNECT to sni:443) plus the
// bufio.Reader that consumed the CONNECT response. It WAITS up to pickWaitTO for
// the pool to become non-empty instead of dropping the client instantly — this
// smooths the COLD-START window (right after a restart/reinstall the first
// health probe has not populated p.live yet, ~5-13s) and transient all-dead
// windows where the recover-loop is re-probing. Once a live IP exists it tries
// up to maxTries of them so one flaky upstream does not kill the connection.
// Returns (nil, nil) if nothing works within the budget (genuine all-dead pool).
// Seams: dialUpstream is otherwise untestable because both helpers do real I/O.
// It had no tests at all, which is where both defects below survived.
var openTunnelFn = openTunnel
var verifyFirstByteFn = verifyFirstByte

func dialUpstream(p *pool, sni string, hello []byte) (net.Conn, *bufio.Reader) {
	target := sni + ":443"
	deadline := time.Now().Add(*pickWaitTO)
	tries := 0
	// Blast-radius cap on demotion: AT MOST ONE node may leave the ring per client
	// request. Observed on the owner's router (2026-07-26): a single request for a
	// dead hostname demoted four healthy upstreams in a row -
	//   "accepted CONNECT but sent no server flight (EOF) - demoting" x4
	//   "no usable upstream proxy IP, dropping rutracker.cc"
	// - because neither failure mode can tell "this NODE is broken" from "this
	// TARGET is dead": the EOF arrives from the far end and the middleman is
	// punished for it. Half the pool then disappears until the next 90 s probe and
	// rutracker.org degrades FOR EVERYONE because one client asked for a dead host.
	// Capping at one keeps the original guarantee (a genuinely dead node still
	// leaves the ring on the first request that touches it, and the next request
	// removes the next one) while making a dead target cost one node instead of
	// maxTries.
	demotedHere := false
	demoteOnce := func(ip, why string) {
		if demotedHere {
			log.Printf("[rt-proxy] %s also failed via %s (%s) — NOT demoting further this request; "+
				"looks like the target, not the pool", target, ip, why)
			return
		}
		p.demote(ip)
		demotedHere = true
	}
	for {
		// The budget is checked on EVERY iteration, not only while the pool is
		// empty. It used to gate just the empty-pool branch, so with a live-looking
		// but broken pool the retry loop was bounded by nothing but max-tries x the
		// per-try dial budget - the client could be held far past pick-wait with its
		// read deadline already cleared.
		if !time.Now().Before(deadline) {
			return nil, nil
		}
		ip := p.pick()
		if ip == "" {
			time.Sleep(250 * time.Millisecond)
			continue
		}
		up, br, ok, reachable := openTunnelFn(ip, target)
		if !reachable {
			// Could not reach it at all. Do not leave it in the ring for the rest of
			// the health interval: round-robin would keep handing it out, burning the
			// dial budget every time. probeAll re-admits it when it recovers, exactly
			// as it does for a verifyFirstByte demotion.
			demoteOnce(ip, "unreachable")
		}
		if ok {
			// Do not hand the client a tunnel that has not proven it carries data.
			if verifyFirstByteFn(ip, up, br, hello) {
				if *verbose {
					log.Printf("[rt-proxy] tunnel %s via %s", target, ip)
				}
				return up, br
			}
			up.Close()
			demoteOnce(ip, "no server flight")
		}
		tries++
		if tries >= *maxTries {
			return nil, nil
		}
		// this upstream failed — round-robin to another and retry
	}
}

// verifyFirstByte replays the client's ClientHello into the tunnel and requires the
// upstream to deliver the server's ENTIRE first TLS handshake record within firstByteTO.
//
// One byte is not enough — measured on-router, that was the difference between a fix and
// a placebo. The bad nodes DO emit a byte or two and then stall forever: with a one-byte
// check they sailed through, the splice started, and the browser hung exactly as before
// (verbose log: `tunnel via <ip>` … `c->u copied=437` twenty seconds later, and no `u->c`
// line at all — the upstream never sent the server's flight). Demanding a complete,
// well-formed record proves the node is actually relaying the far end.
//
// THIS IS THE FIX for "RuTracker works, then hangs, then works again if you touch
// anything". A pool node can accept the CONNECT and then never deliver a single byte
// of the real conversation. Nothing here noticed: the ClientHello was written, both
// splice directions were started, and the only bound was the 15-MINUTE idle timeout —
// so the browser sat on a dead tunnel until IT gave up, and not one line was logged
// (the splice logs only under -v). Whether a page loaded was decided by which node
// pick()'s round-robin cursor happened to hand you; retrying — reloading the page,
// or any other new connection — advanced the cursor to a working node, which is
// exactly why "any sneeze" appeared to fix it.
//
// Peek, don't Read: the byte stays in br, and the up->client splice reads from br, so
// nothing is consumed or lost. A failure here is invisible to the client — we have not
// sent it anything yet, so the caller can simply replay the same ClientHello into a
// different upstream.
func verifyFirstByte(ip string, up net.Conn, br *bufio.Reader, hello []byte) bool {
	if _, err := up.Write(hello); err != nil {
		log.Printf("[rt-proxy] %s: ClientHello write failed: %v — trying another", ip, err)
		return false
	}
	up.SetReadDeadline(time.Now().Add(*firstByteTO))
	defer up.SetReadDeadline(time.Time{})
	// TLS record header: type(1) version(2) length(2).
	hdr, err := br.Peek(5)
	if err != nil {
		// Neutral wording on purpose: this function now also guards the DIRECT
		// path, where no CONNECT ever happens. Saying "accepted CONNECT" there
		// sent field triage looking for a tunnel that was never opened.
		log.Printf("[rt-proxy] %s sent no server flight within %s (%v) — demoting, trying another",
			ip, *firstByteTO, err)
		return false
	}
	if hdr[0] != 0x16 { // handshake
		log.Printf("[rt-proxy] %s answered with a non-handshake record (type 0x%02x) — demoting, trying another", ip, hdr[0])
		return false
	}
	n := int(hdr[3])<<8 | int(hdr[4])
	if n <= 0 || n > 16384 { // RFC 8446 max TLSPlaintext fragment
		log.Printf("[rt-proxy] %s answered with an implausible record length %d — demoting, trying another", ip, n)
		return false
	}
	if _, err := br.Peek(5 + n); err != nil {
		log.Printf("[rt-proxy] %s stalled mid-record (%d of %d bytes) within %s (%v) — demoting, trying another",
			ip, br.Buffered(), 5+n, *firstByteTO, err)
		return false
	}
	// ONE record is not enough — the bad nodes deliver a ServerHello happily and stall on what
	// follows. But a BYTE COUNT is the wrong bar, and shipping one broke RuTracker worse than
	// the bug it replaced: a RESUMED TLS 1.2 handshake is ServerHello + ChangeCipherSpec +
	// Finished — 137 bytes in total. Demanding 2 KB demoted every healthy node in turn until
	// the pool was empty. Measured on-router, 28 times: "delivered only 137 of 2048 flight
	// bytes ... demoting" across all six live nodes, then "no usable upstream". curl never
	// showed it because separate curl processes do not share a TLS session cache, so every
	// probe was a full 4.6 KB handshake — a browser resumes, and broke instantly.
	//
	// The right bar is COMPLETENESS, not size: require a well-formed SECOND record. A server
	// flight always spans at least two records (ChangeCipherSpec cannot share a record with
	// handshake data, and TLS 1.3 follows ServerHello with CCS then application_data), while
	// a node that stalls after the ServerHello never produces one. Short-but-complete passes;
	// long-but-truncated does not.
	off := 5 + n
	hdr2, err := br.Peek(off + 5)
	if err != nil {
		log.Printf("[rt-proxy] %s sent only the first record and stalled within %s (%v) — demoting, trying another",
			ip, *firstByteTO, err)
		return false
	}
	switch hdr2[off] {
	case 0x14, 0x16, 0x17: // ChangeCipherSpec, handshake, application_data — a flight continuing
	default:
		log.Printf("[rt-proxy] %s followed the ServerHello with record type 0x%02x — demoting, trying another",
			ip, hdr2[off])
		return false
	}
	n2 := int(hdr2[off+3])<<8 | int(hdr2[off+4])
	if n2 < 0 || n2 > 16384 {
		log.Printf("[rt-proxy] %s second record has an implausible length %d — demoting, trying another", ip, n2)
		return false
	}
	if _, err := br.Peek(off + 5 + n2); err != nil {
		log.Printf("[rt-proxy] %s stalled inside its second record within %s (%v) — demoting, trying another",
			ip, *firstByteTO, err)
		return false
	}
	return true
}

// dialDirect is the last resort: resolve the SNI ourselves and go straight to the
// origin. Two guards make this safe, and neither is optional.
//
// LOOP GUARD. The whole design hijacks these names to a sentinel, so resolving
// through the SYSTEM resolver would hand us our own sentinel address and we would
// connect to ourselves, recursively, until the box runs out of descriptors. Only
// the direct resolver is used, and any answer that is loopback, private,
// link-local, multicast or unspecified is refused — that covers the sentinel
// (10.171.171.171) and every other way this can point back inside.
//
// REACH GUARD. Without an allowlist this would turn a LAN-reachable listener into
// a general-purpose relay: today a client's SNI can only reach hosts the upstream
// proxy agrees to serve, whereas a direct dial reaches anything the ROUTER can,
// including its own services. The fallback is therefore limited to the domains we
// pin in the first place — which is exactly the population that can end up in the
// dead end this function exists to fix.
func dialDirect(sni string, hello []byte) (net.Conn, *bufio.Reader) {
	if !directHostAllowed(sni) {
		log.Printf("[rt-proxy] %s is not in --direct-fallback-hosts — dropping rather than relaying", sni)
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), *resolveTO)
	ips, err := directLookup(ctx, sni)
	cancel()
	if err != nil || len(ips) == 0 {
		if *verbose {
			log.Printf("[rt-proxy] direct fallback: cannot resolve %s: %v", sni, err)
		}
		return nil, nil
	}
	for _, ips := range ips {
		ip := net.ParseIP(ips)
		if ip == nil || !routableUnicast(ip) {
			continue // sentinel / loopback / RFC1918 / link-local — would loop back inside
		}
		d := net.Dialer{Timeout: *dialTO}
		c, err := d.Dial("tcp", net.JoinHostPort(ips, "443"))
		if err != nil {
			continue
		}
		br := bufio.NewReaderSize(c, bufSize)
		if !verifyFirstByte("direct:"+ips, c, br, hello) {
			c.Close()
			continue
		}
		log.Printf("[rt-proxy] %s served DIRECTLY via %s (no upstream could carry it)", sni, ips)
		return c, br
	}
	return nil, nil
}

// Seam so a test can prove the allowlist is consulted BEFORE any lookup happens —
// asserting the pure function alone left the call site unguarded, and a mutation
// that deleted the check went undetected.
var directLookup = func(ctx context.Context, host string) ([]string, error) {
	return directResolver().LookupHost(ctx, host)
}

// directHostAllowed matches the SNI against --direct-fallback-hosts, exactly or as
// a dot-anchored suffix, so "cc.rutracker.org.evil.tld" cannot slip through.
func directHostAllowed(sni string) bool {
	sni = strings.ToLower(strings.TrimSuffix(sni, "."))
	for _, sfx := range strings.Split(*directHosts, ",") {
		sfx = strings.ToLower(strings.TrimSpace(sfx))
		if sfx == "" {
			continue
		}
		if sni == sfx || strings.HasSuffix(sni, "."+sfx) {
			return true
		}
	}
	return false
}

// routableUnicast rejects everything that could point back at this router.
func routableUnicast(ip net.IP) bool {
	return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() ||
		ip.IsInterfaceLocalMulticast())
}

// openTunnel dials the upstream proxy IP over TLS and issues CONNECT target,
// returning the tunnel and the bufio.Reader that consumed the CONNECT reply
// (its buffered bytes are load-bearing for the up->client splice).
// The `reachable` return separates two very different failures. reachable=false
// means we could not reach the proxy at all (TCP refused, SYN dropped, TLS
// failed) - a conclusive death, and the dominant signature of an RU-blocked node,
// so it is worth evicting from the ring immediately. reachable=true with ok=false
// means the node ANSWERED and refused the CONNECT (502/503 from a healthy but
// overloaded proxy); evicting on that would throw away good nodes under load.
func openTunnel(ip, target string) (conn net.Conn, rd *bufio.Reader, ok bool, reachable bool) {
	up, err := dialProxyDeadline(ip, time.Now().Add(*dialTO))
	if err != nil {
		if *verbose {
			log.Printf("[rt-proxy] dial upstream %s failed: %v", ip, err)
		}
		return nil, nil, false, false
	}
	up.SetDeadline(time.Now().Add(*dialTO))
	fmt.Fprintf(up, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: Keep-Alive\r\n\r\n", target, target)
	// Sized for the LARGEST Peek verifyFirstByte can ask for, which is two
	// maximum-size TLS records plus both 5-byte headers:
	//     5 + 16384 + 5 + 16384 = 32778 bytes
	// 32*1024 = 32768 was 10 bytes short, so an upstream that legitimately sent two
	// full-size records was demoted with bufio.ErrBufferFull — punished for being
	// healthy. Peek cannot return more than the buffer holds, so this must stay >=
	// 32778; 33 KiB gives it room without another allocation class.
	br := bufio.NewReaderSize(up, bufSize)
	status, err := br.ReadString('\n')
	if err != nil || !strings.Contains(status, " 200") {
		if *verbose {
			log.Printf("[rt-proxy] CONNECT %s via %s rejected: %q", target, ip, strings.TrimSpace(status))
		}
		up.Close()
		return nil, nil, false, true // it answered; not a reachability failure
	}
	// drain the rest of the CONNECT response headers (up to blank line)
	for {
		line, err := br.ReadString('\n')
		if err != nil || line == "\r\n" || line == "\n" {
			break
		}
	}
	up.SetDeadline(time.Time{})
	return up, br, true, true
}

func handle(client net.Conn, p *pool) {
	// One malformed peer must not take the daemon down. Every connection runs in its
	// own goroutine (`go handle` in main), and an unrecovered panic in ANY goroutine
	// kills the whole process — which here means the supervisor restarts us and every
	// OTHER client's tunnel is cut with it. parseSNI is bounds-checked and no panic
	// path is known today, but this runs unattended on other people's routers and the
	// insurance costs one deferred call per connection.
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[rt-proxy] panic serving %s: %v — connection dropped, daemon continues",
				client.RemoteAddr(), r)
		}
	}()
	defer client.Close()
	client.SetReadDeadline(time.Now().Add(10 * time.Second))
	sni, hello, err := peekSNI(client)
	client.SetReadDeadline(time.Time{})
	if err != nil || sni == "" {
		if *verbose {
			log.Printf("[rt-proxy] SNI peek failed from %s: %v", client.RemoteAddr(), err)
		}
		return
	}

	// dialUpstream replays the ClientHello itself and only returns a tunnel that has
	// already answered with real bytes, retrying other nodes as needed — so by here the
	// upstream is proven, not merely connected.
	up, br := dialUpstream(p, sni, hello)
	if up == nil && *directFallback {
		// FAIL OPEN, the one thing the official RuTracker extension gets better
		// than we did. Its PAC returns DIRECT for anything it cannot proxy; our
		// DNS pin turns the same situation into a dead end, because the name is
		// hijacked to a sentinel and the only route out was the upstream. Measured:
		// rutracker.cc (no upstream A record at all) and www.rutracker.org (blockme
		// serves the apex but not www) were hard 000s purely because they were
		// pinned. main.go used to claim a direct fallback was "not constructible
		// because the destination is a fake sentinel" — untrue: we hold the SNI.
		up, br = dialDirect(sni, hello)
	}
	if up == nil {
		log.Printf("[rt-proxy] no usable upstream proxy IP, dropping %s", sni)
		return
	}
	defer up.Close()
	if *verbose {
		log.Printf("[rt-proxy] %s -> %s:443", client.RemoteAddr(), sni)
	}

	// Splice. CRITICAL: the up->client direction reads via `br` (the bufio.Reader that
	// consumed the CONNECT response and peeked the first response byte), NOT the raw
	// `up` — otherwise any bytes bufio buffered past the "200" response (the start of
	// the server's reply) are stranded in br and never reach the client, hanging the
	// handshake. client->up writes raw.
	// Proper bidirectional splice with HALF-CLOSE: when one direction ends, only
	// the write side of the peer is closed (CloseWrite / close_notify), NOT the
	// whole connection — so the other direction can still finish (e.g. the
	// upstream may close-write after its handshake flight while the client still
	// has bytes to send). Wait for BOTH directions before tearing down.
	type halfCloser interface{ CloseWrite() error }
	// Written by whichever direction moves bytes, read only by the watchdog below.
	var lastActivity atomic.Int64
	lastActivity.Store(time.Now().UnixNano())
	touch := func() { lastActivity.Store(time.Now().UnixNano()) }
	done := make(chan struct{}, 2)
	go func() {
		n, e := io.Copy(up, &activityReader{r: client, touch: touch})
		if hc, ok := up.(halfCloser); ok {
			hc.CloseWrite()
		}
		if *verbose {
			log.Printf("[rt-proxy] c->u copied=%d err=%v", n, e)
		}
		done <- struct{}{}
	}()
	go func() {
		n, e := io.Copy(client, &activityReader{r: br, touch: touch})
		if hc, ok := client.(halfCloser); ok {
			hc.CloseWrite()
		}
		if *verbose {
			log.Printf("[rt-proxy] u->c copied=%d err=%v", n, e)
		}
		done <- struct{}{}
	}()
	// A REAL idle timeout. This used to be a single time.NewTimer that was never
	// Reset, i.e. an absolute cap on the connection's lifetime: an active transfer
	// was cut at 15 minutes, while a genuinely idle tunnel was still held for the
	// full 15 minutes. Both are wrong, in opposite directions.
	//
	// Deliberately NOT done with timer.Reset: resetting a timer from the copy
	// goroutines while this one selects on timer.C is the classic
	// stop/drain/reset race, on the hot path, in the one function whose comments
	// record that a hang here is invisible to the client. An atomic
	// last-activity stamp plus a watchdog has no such race: the stamp is written
	// by whoever reads bytes, and only the watchdog reads it.
	watchdogDone := make(chan struct{})
	defer close(watchdogDone)
	hardStop := make(chan struct{})
	go func() {
		tick := *idleTO / 4
		if tick > 30*time.Second {
			tick = 30 * time.Second
		}
		if tick <= 0 {
			tick = time.Second
		}
		t := time.NewTicker(tick)
		defer t.Stop()
		for {
			select {
			case <-watchdogDone:
				return
			case <-t.C:
				if time.Since(time.Unix(0, lastActivity.Load())) < *idleTO {
					continue
				}
				if *verbose {
					log.Printf("[rt-proxy] idle %s with no bytes either way — closing %s",
						*idleTO, client.RemoteAddr())
				}
				// Closing both ends unblocks the two io.Copy goroutines; the
				// deferred Closes below are then no-ops.
				client.Close()
				up.Close()
				// ...and if a copy goroutine somehow does NOT unblock, release
				// handle() anyway. The old code returned from a select on the
				// timer, so it could never be pinned by a stuck copy; waiting
				// unconditionally on `done` would have quietly traded a 15-minute
				// hang for a permanent one. The grace period is generous because
				// the normal path unblocks in microseconds.
				time.Sleep(2 * time.Second)
				close(hardStop)
				return
			}
		}
	}()
	for i := 0; i < 2; i++ {
		select {
		case <-done:
		case <-hardStop:
			return
		}
	}
}

// activityReader stamps the connection as alive on every read that actually moved
// bytes. A read returning (0, err) is not activity - counting it would keep a dead
// tunnel alive forever, which is the exact hang this whole file exists to prevent.
type activityReader struct {
	r     io.Reader
	touch func()
}

func (a *activityReader) Read(p []byte) (int, error) {
	n, err := a.r.Read(p)
	if n > 0 {
		a.touch()
	}
	return n, err
}

// ---------------------------------------------------------------------------
// minimal TLS ClientHello SNI extractor (no handshake / no decryption)
// ---------------------------------------------------------------------------
var errNotClientHello = errors.New("not a TLS ClientHello")

// peekSNI reads the first TLS record (the ClientHello), returns the SNI host
// and ALL bytes consumed (so they can be replayed to the upstream verbatim).
func peekSNI(c net.Conn) (string, []byte, error) {
	var buf bytes.Buffer
	hdr := make([]byte, 5)
	if _, err := io.ReadFull(c, hdr); err != nil {
		return "", nil, err
	}
	buf.Write(hdr)
	if hdr[0] != 0x16 { // not handshake
		return "", buf.Bytes(), errNotClientHello
	}
	recLen := int(binary.BigEndian.Uint16(hdr[3:5]))
	if recLen <= 0 || recLen > 16384 {
		return "", buf.Bytes(), errNotClientHello
	}
	body := make([]byte, recLen)
	if _, err := io.ReadFull(c, body); err != nil {
		return "", nil, err
	}
	buf.Write(body)
	sni := parseSNI(body)
	return sni, buf.Bytes(), nil
}

// parseSNI walks a ClientHello handshake body and returns the server_name.
func parseSNI(b []byte) string {
	// handshake: type(1) len(3) version(2) random(32) ...
	if len(b) < 38 || b[0] != 0x01 {
		return ""
	}
	p := 38
	// session_id
	if p >= len(b) {
		return ""
	}
	p += 1 + int(b[p])
	// cipher_suites
	if p+2 > len(b) {
		return ""
	}
	p += 2 + int(binary.BigEndian.Uint16(b[p:p+2]))
	// compression_methods
	if p+1 > len(b) {
		return ""
	}
	p += 1 + int(b[p])
	// extensions
	if p+2 > len(b) {
		return ""
	}
	extEnd := p + 2 + int(binary.BigEndian.Uint16(b[p:p+2]))
	p += 2
	for p+4 <= len(b) && p+4 <= extEnd {
		etype := binary.BigEndian.Uint16(b[p : p+2])
		elen := int(binary.BigEndian.Uint16(b[p+2 : p+4]))
		p += 4
		if p+elen > len(b) {
			return ""
		}
		if etype == 0x0000 { // server_name
			d := b[p : p+elen]
			// server_name_list len(2), then entries: type(1) len(2) name
			if len(d) >= 5 && d[2] == 0x00 {
				n := int(binary.BigEndian.Uint16(d[3:5]))
				if 5+n <= len(d) {
					return string(d[5 : 5+n])
				}
			}
			return ""
		}
		p += elen
	}
	return ""
}
