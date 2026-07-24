package main

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"io"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// These tests exist because this file broke RuTracker three times in one week and had ZERO
// tests while doing it. Each case below is a FIELD failure, reproduced in-process:
//
//   * an upstream that completes the handshake and stalls on the certificate flight
//     (users saw: page hangs forever, no log line, "works again if you touch anything");
//   * an upstream that accepts CONNECT and then says nothing;
//   * pick() handing out a node that has already proven itself dead.
//
// The point is not coverage percentage. The point is that if someone weakens one of these
// guards again, a test goes red before a user does.

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// tlsRecord builds a well-formed TLS record of the given type carrying n payload bytes.
func tlsRecord(typ byte, n int) []byte {
	rec := make([]byte, 5+n)
	rec[0] = typ
	rec[1], rec[2] = 0x03, 0x03 // TLS 1.2 record version, as used on the wire
	rec[3] = byte(n >> 8)
	rec[4] = byte(n)
	return rec
}

// fakeUpstream returns the conn verifyFirstByte would be given, plus a bufio.Reader sized
// exactly as openTunnel sizes it. serve receives the replayed ClientHello and writes the
// server's answer.
//
// net.Pipe is SYNCHRONOUS: once verifyFirstByte has its verdict nobody reads any more, so an
// unfinished write in serve blocks forever. Both deadlines are set and teardown closes the
// conn BEFORE waiting on the goroutine — a test harness that can hang is worse than no test,
// it turns CI into a coin flip.
func fakeUpstream(t *testing.T, serve func(peer net.Conn, gotHello []byte)) (net.Conn, *bufio.Reader) {
	t.Helper()
	up, peer := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer peer.Close()
		buf := make([]byte, 4096)
		_ = peer.SetDeadline(time.Now().Add(3 * time.Second))
		n, _ := peer.Read(buf)
		serve(peer, buf[:n])
	}()
	t.Cleanup(func() {
		up.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("fake upstream goroutine did not finish — the harness would hang CI")
		}
	})
	// Same size openTunnel uses; Peek() can never exceed the buffer, so tests must mirror it.
	return up, bufio.NewReaderSize(up, 32*1024)
}

func withFastTimeouts(t *testing.T) {
	t.Helper()
	oldFirst := *firstByteTO
	*firstByteTO = 250 * time.Millisecond
	t.Cleanup(func() { *firstByteTO = oldFirst })
}

// ---------------------------------------------------------------------------
// verifyFirstByte — the gate that decides whether a client ever sees this upstream
// ---------------------------------------------------------------------------

// THE regression. A node that returns a ServerHello and then stalls used to pass the gate,
// so the browser hung on it until it gave up. Requiring a real slice of the flight is what
// closed it; this test fails the moment that requirement is weakened back to one record.
func TestVerifyFirstByte_StallsAfterServerHello_IsRejected(t *testing.T) {
	withFastTimeouts(t)

	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		// A ServerHello-sized handshake record, well-formed, and then silence — exactly what
		// the bad blockme nodes do.
		_, _ = peer.Write(tlsRecord(0x16, 120))
		time.Sleep(1 * time.Second) // outlive firstByteTO without closing
	})

	if verifyFirstByte("203.0.113.1", up, br, []byte("clienthello")) {
		t.Fatal("accepted an upstream that delivered only a ServerHello and then stalled — " +
			"this is the exact failure that hung RuTracker on a fresh browser start")
	}
}

func TestVerifyFirstByte_FullFlight_IsAccepted(t *testing.T) {
	withFastTimeouts(t)

	up, br := fakeUpstream(t, func(peer net.Conn, gotHello []byte) {
		if string(gotHello) != "clienthello" {
			t.Errorf("upstream did not receive the replayed ClientHello, got %q", gotHello)
		}
		// ServerHello followed by a certificate-sized record: a healthy node.
		_, _ = peer.Write(tlsRecord(0x16, 120))
		_, _ = peer.Write(tlsRecord(0x16, 4096))
		time.Sleep(300 * time.Millisecond)
	})

	if !verifyFirstByte("203.0.113.2", up, br, []byte("clienthello")) {
		t.Fatal("rejected a healthy upstream that delivered a full server flight")
	}
}

func TestVerifyFirstByte_SilentUpstream_IsRejected(t *testing.T) {
	withFastTimeouts(t)
	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		time.Sleep(1 * time.Second) // accepted CONNECT, then nothing at all
	})

	if verifyFirstByte("203.0.113.3", up, br, []byte("hello")) {
		t.Fatal("accepted an upstream that never sent a byte")
	}
}

func TestVerifyFirstByte_NonHandshakeRecord_IsRejected(t *testing.T) {
	withFastTimeouts(t)
	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		// 0x15 = alert. A proxy answering the tunnel itself, not relaying the site.
		_, _ = peer.Write(tlsRecord(0x15, 2))
		time.Sleep(300 * time.Millisecond)
	})

	if verifyFirstByte("203.0.113.4", up, br, []byte("hello")) {
		t.Fatal("accepted a non-handshake record as a valid server flight")
	}
}

func TestVerifyFirstByte_ImplausibleRecordLength_IsRejected(t *testing.T) {
	withFastTimeouts(t)
	for _, n := range []int{0, 16385} {
		up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
			hdr := []byte{0x16, 0x03, 0x03, byte(n >> 8), byte(n)}
			_, _ = peer.Write(hdr)
			time.Sleep(300 * time.Millisecond)
		})
		if verifyFirstByte("203.0.113.5", up, br, []byte("hello")) {
			t.Fatalf("accepted an implausible record length %d", n)
		}
		up.Close()
		up.Close()
		}
}

func TestVerifyFirstByte_WriteFailure_IsRejected(t *testing.T) {
	withFastTimeouts(t)
	up, peer := net.Pipe()
	peer.Close() // replaying the ClientHello will fail
	br := bufio.NewReaderSize(up, 32*1024)
	if verifyFirstByte("203.0.113.6", up, br, []byte("hello")) {
		t.Fatal("accepted an upstream we could not even write the ClientHello to")
	}
	up.Close()
}

// THE regression the byte-count gate caused, and the reason it was replaced. A RESUMED
// TLS 1.2 handshake is ServerHello + ChangeCipherSpec + Finished — about 137 bytes total.
// A gate that demanded 2 KB called every healthy node dead and emptied the pool; measured
// on-router 28 times before this test existed. Short but COMPLETE must be accepted.
func TestVerifyFirstByte_ResumedHandshake_IsAccepted(t *testing.T) {
	withFastTimeouts(t)

	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		_, _ = peer.Write(tlsRecord(0x16, 91)) // ServerHello of a resumed session
		_, _ = peer.Write(tlsRecord(0x14, 1))  // ChangeCipherSpec
		_, _ = peer.Write(tlsRecord(0x16, 40)) // encrypted Finished
		time.Sleep(300 * time.Millisecond)
	})

	if !verifyFirstByte("203.0.113.8", up, br, []byte("hello")) {
		t.Fatal("rejected a RESUMED handshake (137 bytes, but complete) — this is the bug that " +
			"demoted every healthy node and emptied the pool")
	}
}

// TLS 1.3 shape: ServerHello, ChangeCipherSpec, then encrypted application_data.
func TestVerifyFirstByte_TLS13Shape_IsAccepted(t *testing.T) {
	withFastTimeouts(t)
	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		_, _ = peer.Write(tlsRecord(0x16, 120))
		_, _ = peer.Write(tlsRecord(0x14, 1))
		_, _ = peer.Write(tlsRecord(0x17, 600))
		time.Sleep(300 * time.Millisecond)
	})
	if !verifyFirstByte("203.0.113.9", up, br, []byte("hello")) {
		t.Fatal("rejected a well-formed TLS 1.3 server flight")
	}
}

// An alert after the ServerHello is the proxy talking, not the site relaying.
func TestVerifyFirstByte_AlertAfterServerHello_IsRejected(t *testing.T) {
	withFastTimeouts(t)
	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		_, _ = peer.Write(tlsRecord(0x16, 91))
		_, _ = peer.Write(tlsRecord(0x15, 2)) // alert
		time.Sleep(300 * time.Millisecond)
	})
	if verifyFirstByte("203.0.113.10", up, br, []byte("hello")) {
		t.Fatal("accepted an alert as a continuing server flight")
	}
}

// Mutation-driven: with a zero-length first record followed by a WELL-FORMED continuation,
// every later guard passes — only the length sanity check can reject it. Without this shape
// the check could be deleted with no observable change.
func TestVerifyFirstByte_ZeroLengthRecord_IsRejectedEvenWhenAValidRecordFollows(t *testing.T) {
	withFastTimeouts(t)
	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		_, _ = peer.Write([]byte{0x16, 0x03, 0x03, 0x00, 0x00}) // handshake record, length 0
		_, _ = peer.Write(tlsRecord(0x14, 1))                   // valid ChangeCipherSpec after it
		_, _ = peer.Write(tlsRecord(0x16, 40))
		time.Sleep(300 * time.Millisecond)
	})
	if verifyFirstByte("203.0.113.11", up, br, []byte("hello")) {
		t.Fatal("accepted a zero-length TLS record; the length sanity check is not doing anything")
	}
}

// Mutation-driven: the second record's HEADER arrives but its body never does. Only the
// "second record must be complete" peek can reject this.
func TestVerifyFirstByte_SecondRecordTruncated_IsRejected(t *testing.T) {
	withFastTimeouts(t)
	up, br := fakeUpstream(t, func(peer net.Conn, _ []byte) {
		_, _ = peer.Write(tlsRecord(0x16, 91))                  // complete ServerHello
		_, _ = peer.Write([]byte{0x16, 0x03, 0x03, 0x10, 0x00}) // header promising 4096 bytes...
		time.Sleep(1 * time.Second)                             // ...that never arrive
	})
	if verifyFirstByte("203.0.113.12", up, br, []byte("hello")) {
		t.Fatal("accepted an upstream that announced a second record and never delivered it")
	}
}

// ---------------------------------------------------------------------------
// probeProxy — the health gate that decides which nodes exist at all
// ---------------------------------------------------------------------------

// startFakeMasqueProxy speaks outer TLS, accepts CONNECT, then becomes the INNER TLS server
// (as a relaying proxy appears to us) and answers HTTP with bodyBytes of body. bodyBytes=0
// models the nodes that relay small answers and stall on a real page.
func startFakeMasqueProxy(t *testing.T, bodyBytes int) string {
	t.Helper()
	cfg := selfSignedTLSConfig(t)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				for {
					line, err := br.ReadString('\n')
					if err != nil {
						return
					}
					if line == "\r\n" || line == "\n" {
						break
					}
				}
				fmt.Fprint(c, "HTTP/1.1 200 Connection established\r\n\r\n")
				inner := tls.Server(c, cfg)
				if err := inner.Handshake(); err != nil {
					return
				}
				ibr := bufio.NewReader(inner)
				for {
					line, err := ibr.ReadString('\n')
					if err != nil {
						return
					}
					if line == "\r\n" || line == "\n" {
						break
					}
				}
				fmt.Fprint(inner, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n")
				if bodyBytes > 0 {
					_, _ = inner.Write(bytes.Repeat([]byte("x"), bodyBytes))
				}
				time.Sleep(700 * time.Millisecond)
			}(c)
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	return port
}

func withProbeAgainst(t *testing.T, port string) {
	t.Helper()
	oldPort, oldTO, oldHost := *proxyPort, *probeTO, *healthHost
	*proxyPort, *probeTO, *healthHost = port, 6*time.Second, "127.0.0.1:443"
	t.Cleanup(func() { *proxyPort, *probeTO, *healthHost = oldPort, oldTO, oldHost })
}

func TestProbeProxy_NodeThatDeliversABodyIsFullyLive(t *testing.T) {
	withProbeAgainst(t, startFakeMasqueProxy(t, *probeBytes+2048))
	full, handshake := probeProxy("127.0.0.1")
	if !handshake {
		t.Fatal("probe did not register the handshake against a healthy node")
	}
	if !full {
		t.Fatal("probe rejected a node that delivered a full body")
	}
}

// THE field failure at health-gate level: headers arrive, the page never does. Such a node
// must not count as live — that is how stalling nodes got back into the ring.
func TestProbeProxy_NodeThatStallsOnTheBodyIsNotLive(t *testing.T) {
	withProbeAgainst(t, startFakeMasqueProxy(t, 0))
	full, handshake := probeProxy("127.0.0.1")
	if !handshake {
		t.Fatal("expected the handshake stage to succeed for a stalling node (it does in the field)")
	}
	if full {
		t.Fatal("a node that returned headers but no body counted as fully live")
	}
}

func TestProbeProxy_UnreachableNodeIsNeitherLiveNorHandshaked(t *testing.T) {
	oldPort, oldTO := *proxyPort, *probeTO
	*proxyPort, *probeTO = "1", 500*time.Millisecond
	t.Cleanup(func() { *proxyPort, *probeTO = oldPort, oldTO })
	full, handshake := probeProxy("127.0.0.1")
	if full || handshake {
		t.Fatal("probe claimed something about an unreachable node")
	}
}

// ---------------------------------------------------------------------------
// pool — who gets handed to the next client
// ---------------------------------------------------------------------------

func TestPoolPick_EmptyPoolReturnsEmpty(t *testing.T) {
	p := &pool{}
	if got := p.pick(); got != "" {
		t.Fatalf("empty pool handed out %q", got)
	}
}

func TestPoolPick_RoundRobinsOverAllLiveNodes(t *testing.T) {
	p := &pool{live: []string{"a", "b", "c"}}
	seen := map[string]int{}
	for i := 0; i < 30; i++ {
		seen[p.pick()]++
	}
	for _, ip := range []string{"a", "b", "c"} {
		if seen[ip] != 10 {
			t.Fatalf("round-robin is uneven: %v", seen)
		}
	}
}

// demote is what stops a node that just failed on real traffic from being handed to the very
// next client. Before it existed, whether a page loaded depended on the cursor position.
func TestPoolDemote_RemovesOnlyTheFailedNode(t *testing.T) {
	p := &pool{live: []string{"a", "b", "c"}}
	p.demote("b")
	if got := fmt.Sprint(p.live); got != "[a c]" {
		t.Fatalf("demote corrupted the live set: %s", got)
	}
	for i := 0; i < 10; i++ {
		if p.pick() == "b" {
			t.Fatal("a demoted node was handed to a client")
		}
	}
}

func TestPoolDemote_UnknownNodeIsANoop(t *testing.T) {
	p := &pool{live: []string{"a", "b"}}
	p.demote("zzz")
	if got := fmt.Sprint(p.live); got != "[a b]" {
		t.Fatalf("demoting an unknown node changed the set: %s", got)
	}
}

func TestPoolDemote_CanEmptyThePoolSafely(t *testing.T) {
	p := &pool{live: []string{"a"}}
	p.demote("a")
	if p.liveCount() != 0 {
		t.Fatalf("expected an empty pool, got %v", p.live)
	}
	if got := p.pick(); got != "" {
		t.Fatalf("empty pool handed out %q", got)
	}
}

func TestPoolDemote_IsConcurrencySafe(t *testing.T) {
	p := &pool{live: []string{"a", "b", "c", "d", "e"}}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if i%2 == 0 {
				p.demote("c")
			} else {
				p.pick()
			}
		}(i)
	}
	wg.Wait() // -race turns any unsynchronised access here into a failure
	for _, ip := range p.live {
		if ip == "c" {
			t.Fatal("demoted node survived concurrent access")
		}
	}
}

// ---------------------------------------------------------------------------
// SNI parsing — the first thing every connection depends on
// ---------------------------------------------------------------------------

func realClientHello(t *testing.T, serverName string) []byte {
	t.Helper()
	c, s := net.Pipe()
	defer s.Close()
	go func() {
		_ = tls.Client(c, &tls.Config{ServerName: serverName}).Handshake()
		c.Close()
	}()
	buf := make([]byte, 4096)
	_ = s.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := s.Read(buf)
	if err != nil || n == 0 {
		t.Fatalf("could not capture a real ClientHello: %v", err)
	}
	return buf[:n]
}

// CONTRACT: parseSNI takes the HANDSHAKE MESSAGE, not the raw record — peekSNI strips the
// 5-byte TLS record header before calling it. Documented here because the first version of
// this test fed it wire bytes and got "" back, which looks exactly like a parser bug.
func TestParseSNI_ExtractsHostFromARealClientHello(t *testing.T) {
	wire := realClientHello(t, "rutracker.org")
	if len(wire) < 6 || wire[0] != 0x16 {
		t.Fatalf("captured bytes are not a TLS record: % x", wire[:min(6, len(wire))])
	}
	if got := parseSNI(wire[5:]); got != "rutracker.org" {
		t.Fatalf("parseSNI returned %q, want rutracker.org", got)
	}
	// And it must NOT accept the record header — that would mean it is guessing.
	if got := parseSNI(wire); got != "" {
		t.Fatalf("parseSNI accepted a raw record and returned %q", got)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func TestParseSNI_RejectsGarbageWithoutPanicking(t *testing.T) {
	cases := [][]byte{
		nil,
		{},
		{0x16},
		{0x16, 0x03, 0x01, 0x00, 0x05, 1, 2, 3},
		bytes.Repeat([]byte{0xff}, 300),
	}
	for i, c := range cases {
		if got := parseSNI(c); got != "" {
			t.Fatalf("case %d: parseSNI invented %q out of garbage", i, got)
		}
	}
}

func TestPeekSNI_ReturnsTheHelloItPeeked(t *testing.T) {
	hello := realClientHello(t, "example.org")
	client, peer := net.Pipe()
	go func() { _, _ = peer.Write(hello); time.Sleep(200 * time.Millisecond); peer.Close() }()
	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	sni, replay, err := peekSNI(client)
	client.Close()
	if err != nil {
		t.Fatalf("peekSNI failed on a real ClientHello: %v", err)
	}
	if sni != "example.org" {
		t.Fatalf("peekSNI returned sni=%q", sni)
	}
	// The replay is load-bearing: it is what gets written into the tunnel. Losing bytes here
	// silently breaks every connection.
	if !bytes.Equal(replay, hello) {
		t.Fatalf("peekSNI replay differs from what the client sent (%d vs %d bytes)", len(replay), len(hello))
	}
}

// ---------------------------------------------------------------------------
// openTunnel — CONNECT handling against a real TLS proxy
// ---------------------------------------------------------------------------

func selfSignedTLSConfig(t *testing.T) *tls.Config {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test-proxy"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{"test-proxy"},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
}

// startFakeProxy speaks TLS, reads a CONNECT request and answers with the given status line,
// then echoes body bytes. Returns the port it listens on.
func startFakeProxy(t *testing.T, status string, extraHeaders string) string {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", selfSignedTLSConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				for { // read the CONNECT request headers
					line, err := br.ReadString('\n')
					if err != nil {
						return
					}
					if line == "\r\n" || line == "\n" {
						break
					}
				}
				fmt.Fprintf(c, "HTTP/1.1 %s\r\n%s\r\n", status, extraHeaders)
				_, _ = io.Copy(io.Discard, c)
			}(c)
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	return port
}

func TestOpenTunnel_Accepts200AndDrainsHeaders(t *testing.T) {
	port := startFakeProxy(t, "200 Connection established", "X-Proxy: test\r\n")
	oldPort, oldTO := *proxyPort, *dialTO
	*proxyPort, *dialTO = port, 3*time.Second
	t.Cleanup(func() { *proxyPort, *dialTO = oldPort, oldTO })

	up, br, ok := openTunnel("127.0.0.1", "rutracker.org:443")
	if !ok {
		t.Fatal("openTunnel rejected a proxy that answered 200")
	}
	t.Cleanup(func() { up.Close() })
	if br == nil {
		t.Fatal("openTunnel returned a nil reader; the splice depends on its buffered bytes")
	}
}

func TestOpenTunnel_RejectsNon200(t *testing.T) {
	port := startFakeProxy(t, "403 Forbidden", "")
	oldPort, oldTO := *proxyPort, *dialTO
	*proxyPort, *dialTO = port, 3*time.Second
	t.Cleanup(func() { *proxyPort, *dialTO = oldPort, oldTO })

	up, _, ok := openTunnel("127.0.0.1", "rutracker.org:443")
	if ok {
		up.Close()
		t.Fatal("openTunnel accepted a proxy that refused the CONNECT")
	}
	if up != nil {
		t.Fatal("openTunnel leaked a connection on the failure path")
	}
}

func TestOpenTunnel_UnreachableUpstreamFailsCleanly(t *testing.T) {
	oldPort, oldTO := *proxyPort, *dialTO
	*proxyPort, *dialTO = "1", 300*time.Millisecond // port 1: nothing listens
	t.Cleanup(func() { *proxyPort, *dialTO = oldPort, oldTO })

	up, br, ok := openTunnel("127.0.0.1", "rutracker.org:443")
	if ok || up != nil || br != nil {
		t.Fatal("openTunnel claimed success against an unreachable upstream")
	}
}

// ---------------------------------------------------------------------------
// arch/URL assumptions the installer depends on
// ---------------------------------------------------------------------------

func TestProbePathIsNotARedirect(t *testing.T) {
	// The health probe demands real body bytes. Pointing it at "/" would fetch a 301 with an
	// empty body — which is precisely what the broken nodes serve happily, so the probe would
	// stop discriminating and the pool would fill with stalling nodes again.
	if *probePath == "/" || !strings.HasPrefix(*probePath, "/") {
		t.Fatalf("probe-path %q must be a real page path, not the site root", *probePath)
	}
	if *probeBytes < 1024 {
		t.Fatalf("probe-bytes (%d) is too small to distinguish a redirect from a page", *probeBytes)
	}
}
