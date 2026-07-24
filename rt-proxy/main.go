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
	"crypto/tls"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

var (
	listenAddr   = flag.String("listen", ":1445", "local listen address")
	proxyHost    = flag.String("proxy-host", "ps1.blockme.site", "upstream HTTPS proxy hostname (TLS SNI to the proxy)")
	proxyPort    = flag.String("proxy-port", "443", "upstream proxy port")
	seedIPs      = flag.String("ips", "", "comma-separated upstream proxy IPs (seed pool; re-resolved from proxy-host too)")
	healthEvery  = flag.Duration("health-interval", 60*time.Second, "health-check interval for the IP pool")
	healthHost   = flag.String("health-target", "rutracker.org:443", "CONNECT target used to probe a proxy IP")
	dialTO       = flag.Duration("dial-timeout", 8*time.Second, "dial/handshake timeout for live connections")
	probeTO      = flag.Duration("probe-timeout", 10*time.Second, "total budget for one END-TO-END health probe (dial + CONNECT + inner TLS to the target)")
	recoverEvery = flag.Duration("recover-interval", 10*time.Second, "faster re-probe interval while the pool has 0 live IPs")
	idleTO       = flag.Duration("timeout", 15*time.Minute, "per-connection idle timeout")
	pickWaitTO   = flag.Duration("pick-wait", 15*time.Second, "max wait for a live upstream before dropping (cold-start / transient-empty smoothing)")
	maxTries     = flag.Int("max-tries", 3, "max upstream IPs to try per connection before dropping")
	resolverAddr = flag.String("resolver", "1.1.1.1:53", "DNS server queried DIRECTLY for the upstream pool, to bypass the router's ndnproxy whose cache goes stale and strands the pool on dead IPs (system resolver is still used as a fallback/union)")
	verbose      = flag.Bool("v", false, "verbose logging")
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
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("[rt-proxy] accept: %v", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		go handle(c, p)
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

func (p *pool) resolve() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Union of a DIRECT resolver (fresh rotation, bypasses the stale ndnproxy
	// cache) and the system resolver (fallback if the direct one is blocked /
	// hijacked). The end-to-end probe filters whatever these return down to
	// genuinely-live IPs, so a few stale entries in the union are harmless.
	seenR := map[string]bool{}
	var resolved []string
	for _, r := range []*net.Resolver{directResolver(), net.DefaultResolver} {
		hosts, _ := r.LookupHost(ctx, *proxyHost)
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
	var live []string
	for _, ip := range all {
		wg.Add(1)
		go func(ip string) {
			defer wg.Done()
			if probeProxy(ip) {
				lmu.Lock()
				live = append(live, ip)
				lmu.Unlock()
			}
		}(ip)
	}
	wg.Wait()
	p.mu.Lock()
	p.live = live
	p.mu.Unlock()
	if *verbose || len(live) == 0 {
		log.Printf("[rt-proxy] health: %d/%d upstream IPs live", len(live), len(all))
	}
}

// probeProxy returns true only if the IP relays traffic to the health target
// END-TO-END: it must accept the CONNECT *and* carry a real TLS handshake
// through to the target. The old CONNECT-200-only check passed nodes that
// accept the CONNECT but then stall on real data — exactly the ones that
// produced the client-visible 000s (this is what the official RuTracker client
// does: it validates a proxy by fetching THROUGH it, not just connecting).
// Bounded by a single probeTO budget (dial + CONNECT + inner TLS).
func probeProxy(ip string) bool {
	deadline := time.Now().Add(*probeTO)
	up, err := dialProxy(ip, time.Until(deadline))
	if err != nil {
		if *verbose {
			log.Printf("[rt-proxy] probe %s: dial/tls failed: %v", ip, err)
		}
		return false
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
		return false
	}
	for { // drain the rest of the CONNECT response headers
		line, e := br.ReadString('\n')
		if e != nil {
			return false
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
	inner := tls.Client(&bufConn{br: br, Conn: up}, &tls.Config{ServerName: host, InsecureSkipVerify: true})
	if err := inner.Handshake(); err != nil {
		if *verbose {
			log.Printf("[rt-proxy] probe %s: inner TLS to %s failed: %v", ip, host, err)
		}
		return false
	}
	return true
}

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
func dialProxy(ip string, timeout time.Duration) (net.Conn, error) {
	d := net.Dialer{Timeout: timeout}
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
	tc.SetDeadline(time.Now().Add(timeout))
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
func dialUpstream(p *pool, sni string) (net.Conn, *bufio.Reader) {
	target := sni + ":443"
	deadline := time.Now().Add(*pickWaitTO)
	tries := 0
	for {
		ip := p.pick()
		if ip == "" {
			if !time.Now().Before(deadline) {
				return nil, nil // pool stayed empty the whole budget
			}
			time.Sleep(250 * time.Millisecond)
			continue
		}
		up, br, ok := openTunnel(ip, target)
		if ok {
			if *verbose {
				log.Printf("[rt-proxy] tunnel %s via %s", target, ip)
			}
			return up, br
		}
		tries++
		if tries >= *maxTries {
			return nil, nil
		}
		// live IP but this one failed — round-robin to another and retry
	}
}

// openTunnel dials the upstream proxy IP over TLS and issues CONNECT target,
// returning the tunnel and the bufio.Reader that consumed the CONNECT reply
// (its buffered bytes are load-bearing for the up->client splice).
func openTunnel(ip, target string) (net.Conn, *bufio.Reader, bool) {
	up, err := dialProxy(ip, *dialTO)
	if err != nil {
		if *verbose {
			log.Printf("[rt-proxy] dial upstream %s failed: %v", ip, err)
		}
		return nil, nil, false
	}
	up.SetDeadline(time.Now().Add(*dialTO))
	fmt.Fprintf(up, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: Keep-Alive\r\n\r\n", target, target)
	br := bufio.NewReader(up)
	status, err := br.ReadString('\n')
	if err != nil || !strings.Contains(status, " 200") {
		if *verbose {
			log.Printf("[rt-proxy] CONNECT %s via %s rejected: %q", target, ip, strings.TrimSpace(status))
		}
		up.Close()
		return nil, nil, false
	}
	// drain the rest of the CONNECT response headers (up to blank line)
	for {
		line, err := br.ReadString('\n')
		if err != nil || line == "\r\n" || line == "\n" {
			break
		}
	}
	up.SetDeadline(time.Time{})
	return up, br, true
}

func handle(client net.Conn, p *pool) {
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

	up, br := dialUpstream(p, sni)
	if up == nil {
		log.Printf("[rt-proxy] no live upstream proxy IP, dropping %s", sni)
		return
	}
	defer up.Close()
	if *verbose {
		log.Printf("[rt-proxy] %s -> %s:443", client.RemoteAddr(), sni)
	}

	// Replay the peeked ClientHello into the tunnel, then splice. CRITICAL: the
	// up->client direction reads via `br` (the bufio.Reader that consumed the
	// CONNECT response), NOT the raw `up` — otherwise any bytes bufio buffered
	// past the "200" response (the start of the server's reply) are stranded in
	// br and never reach the client, hanging the handshake. client->up writes raw.
	if _, err := up.Write(hello); err != nil {
		return
	}
	// Proper bidirectional splice with HALF-CLOSE: when one direction ends, only
	// the write side of the peer is closed (CloseWrite / close_notify), NOT the
	// whole connection — so the other direction can still finish (e.g. the
	// upstream may close-write after its handshake flight while the client still
	// has bytes to send). Wait for BOTH directions before tearing down.
	type halfCloser interface{ CloseWrite() error }
	done := make(chan struct{}, 2)
	go func() {
		n, e := io.Copy(up, client)
		if hc, ok := up.(halfCloser); ok {
			hc.CloseWrite()
		}
		if *verbose {
			log.Printf("[rt-proxy] c->u copied=%d err=%v", n, e)
		}
		done <- struct{}{}
	}()
	go func() {
		n, e := io.Copy(client, br)
		if hc, ok := client.(halfCloser); ok {
			hc.CloseWrite()
		}
		if *verbose {
			log.Printf("[rt-proxy] u->c copied=%d err=%v", n, e)
		}
		done <- struct{}{}
	}()
	timer := time.NewTimer(*idleTO)
	defer timer.Stop()
	for i := 0; i < 2; i++ {
		select {
		case <-done:
		case <-timer.C:
			return
		}
	}
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
