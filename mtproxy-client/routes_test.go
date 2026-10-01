package main

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// This TLS peer only supplies protocol replies; the production client performs
// real TLS, nonce signature, redirect validation and direct connection handling.
func routePeer(t *testing.T, id *relayIdentity, kind byte, limit uint32, target string) *httptest.Server {
	t.Helper()
	up := websocket.Upgrader{}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		_, b, err := ws.ReadMessage()
		if err != nil {
			return
		}
		f, _ := decodeMuxFrame(b)
		if f.MsgType != muxHELLO {
			t.Error("expected v2 HELLO")
			return
		}
		nonce := []byte("0123456789abcdef")
		ack := append([]byte{2}, binary.BigEndian.AppendUint64(nil, uint64(time.Now().Unix()))...)
		ack = append(ack, nonce...)
		ack = append(ack, 0)
		ack = binary.BigEndian.AppendUint32(ack, 8192)
		ack = binary.BigEndian.AppendUint32(ack, 1)
		ws.WriteMessage(2, encodeMuxFrame(0, muxHELLO_ACK, ack))
		_, b, err = ws.ReadMessage()
		if err != nil {
			return
		}
		f, _ = decodeMuxFrame(b)
		if f.MsgType != muxAUTHID || len(f.Payload) != 104 || !ed25519.Verify(id.priv.Public().(ed25519.PublicKey), f.Payload[:40], f.Payload[40:]) {
			t.Error("invalid identity proof")
			return
		}
		raw, _ := hex.DecodeString(id.InstallID)
		if string(raw) != string(f.Payload[:16]) {
			t.Error("identity changed")
		}
		p := append([]byte{kind}, binary.BigEndian.AppendUint32(nil, limit)...)
		p = append(p, target...)
		ws.WriteMessage(2, encodeMuxFrame(0, muxINFO, p))
		if kind == 0 {
			for {
				if _, _, err = ws.ReadMessage(); err != nil {
					return
				}
			}
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}
func peerURL(srv *httptest.Server) string {
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	return "wss://example.com:" + port + "/ws"
}
func routedTestClient(t *testing.T, authority *httptest.Server, id *relayIdentity, path string) *tunnelClient {
	pool := x509.NewCertPool()
	pool.AddCert(authority.Certificate())
	tc := &tunnelClient{tunnelURL: peerURL(authority), identityPath: path, localMaxConnections: 8192}
	tc.ctx, tc.cancel = context.WithCancel(context.Background())
	t.Cleanup(tc.cancel)
	tc.dialer = &websocket.Dialer{TLSClientConfig: &tls.Config{RootCAs: pool}, HandshakeTimeout: time.Second,
		NetDial: func(network, addr string) (net.Conn, error) {
			_, port, _ := net.SplitHostPort(addr)
			return net.DialTimeout("tcp", "127.0.0.1:"+port, time.Second)
		}}
	tc.identity.Store(id)
	tc.useID.Store(true)
	return tc
}
func TestAssignedRelayDirectAuthAndOfflineRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identity")
	id, err := loadOrMintIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	target := routePeer(t, id, 0, 0, "")
	authority := routePeer(t, id, 5, 4096, peerURL(target))
	tc := routedTestClient(t, authority, id, path)
	ws, err := tc.connectTunnelWS()
	if err != nil {
		t.Fatal(err)
	}
	ws.Close()
	if tc.connectionLimit.Load() != 4096 {
		t.Fatalf("client allowance %d", tc.connectionLimit.Load())
	}
	saved, err := loadOrMintIdentity(path)
	if err != nil || saved.InstallID != id.InstallID || saved.Route == nil {
		t.Fatalf("identity/route persistence: %v", err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("cache mode")
	}
	// Copying the identity is precisely the existing reinstall backup contract.
	restored := filepath.Join(t.TempDir(), "restored")
	b, _ := os.ReadFile(path)
	os.WriteFile(restored, b, 0600)
	saved, err = loadOrMintIdentity(restored)
	if err != nil {
		t.Fatal(err)
	}
	restarted := routedTestClient(t, authority, saved, restored)
	restarted.useID.Store(false)
	restarted.loadCachedRoute(saved)
	authority.Close()
	ws, err = restarted.connectTunnelWS()
	if err != nil {
		t.Fatalf("cached target after authority outage: %v", err)
	}
	ws.Close()
}
func TestAuthorityRefusalDoesNotUseCacheOrDowngrade(t *testing.T) {
	path := filepath.Join(t.TempDir(), "id")
	id, _ := loadOrMintIdentity(path)
	target := routePeer(t, id, 0, 0, "")
	authority := routePeer(t, id, 4, 10, "revoked")
	tc := routedTestClient(t, authority, id, path)
	if err := tc.storeRoute(id, &cachedRoute{Authority: tc.tunnelURL, URL: peerURL(target), MaxConnections: 4096}); err != nil {
		t.Fatal(err)
	}
	ws, err := tc.connectTunnelWS()
	if ws != nil {
		ws.Close()
		t.Fatal("refused authority fell back to target")
	}
	if !errors.Is(err, errAuthRefused) || tc.forceV1.Load() {
		t.Fatalf("refusal was not preserved: %v v1=%v", err, tc.forceV1.Load())
	}
}
func TestAssignedTargetCannotRedirectAgain(t *testing.T) {
	path := filepath.Join(t.TempDir(), "id")
	id, _ := loadOrMintIdentity(path)
	target := routePeer(t, id, 5, 8192, "wss://other.example/ws")
	authority := routePeer(t, id, 5, 4096, peerURL(target))
	tc := routedTestClient(t, authority, id, path)
	ws, err := tc.connectTunnelWS()
	if ws != nil {
		ws.Close()
	}
	if err == nil {
		t.Fatal("target redirect accepted")
	}
	if tc.forceV1.Load() {
		t.Fatal("assignment caused v1 downgrade")
	}
}
func TestRouteValidationAndForeignCache(t *testing.T) {
	for _, u := range []string{"ws://example.com/ws", "wss://x:y@example.com/ws", "wss://127.0.0.1/ws", "wss://[::1]/ws", "wss://10.0.0.1/ws", "wss://example.com/ws?x=y", "wss://example.com/ws#x"} {
		if validAssignedRoute(cachedRoute{Authority: "wss://base.example/ws", URL: u, MaxConnections: 4096}) {
			t.Fatalf("accepted %s", u)
		}
	}
	if validAssignedRoute(cachedRoute{Authority: "wss://base.example/ws", URL: "wss://base.example/ws", MaxConnections: 4096}) {
		t.Fatal("self redirect accepted")
	}
	path := filepath.Join(t.TempDir(), "id")
	id, _ := loadOrMintIdentity(path)
	id.Route = &cachedRoute{Authority: "wss://foreign.example/ws", URL: "wss://target.example/ws", MaxConnections: 4096}
	tc := &tunnelClient{tunnelURL: "wss://base.example/ws", localMaxConnections: 8192}
	tc.loadCachedRoute(id)
	if tc.routeSnapshot() != nil || tc.useID.Load() {
		t.Fatal("foreign authority cache trusted")
	}
}
func TestConnectionAdmissionConcurrentAndLimitReduction(t *testing.T) {
	// Existing tests share this channel until all stream goroutines finish.
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	if len(connSemaphore) != 0 {
		t.Fatal("leaked test connections")
	}
	tc := &tunnelClient{}
	tc.connectionLimit.Store(32)
	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); tc.acquireConnection() }()
	}
	wg.Wait()
	if len(connSemaphore) != 32 {
		t.Fatalf("admitted %d", len(connSemaphore))
	}
	tc.connectionLimit.Store(16)
	if tc.acquireConnection() {
		t.Fatal("lowered limit ignored")
	}
	for len(connSemaphore) > 0 {
		<-connSemaphore
	}
	if !tc.acquireConnection() {
		t.Fatal("released slot unavailable")
	}
	<-connSemaphore
}
func TestRouteRejectsExcessAndBoundsFileDescriptors(t *testing.T) {
	if validAssignedRoute(cachedRoute{Authority: "wss://base.example/ws", URL: "wss://target.example/ws", MaxConnections: 8193}) {
		t.Fatal("excessive limit accepted")
	}
	for _, tc := range []struct {
		requested, ceiling int
		fd                 uint64
		want               int
	}{{4096, 8192, 65536, 4096}, {4096, 100, 65536, 100}, {4096, 8192, 1024, 480}} {
		if got := boundedConnectionLimit(tc.requested, tc.ceiling, tc.fd); got != tc.want {
			t.Fatalf("got %d want %d", got, tc.want)
		}
	}
}

func TestMalformedRouteCacheDoesNotReplaceIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "id")
	id, err := loadOrMintIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	raw = append(raw[:len(raw)-1], []byte(`,"relay_route":{"max_connections":"broken"}}`)...)
	os.WriteFile(path, raw, 0600)
	again, err := loadOrMintIdentity(path)
	if err != nil || again.InstallID != id.InstallID || again.Priv != id.Priv {
		t.Fatal("bad cache replaced installation key")
	}
	if again.Route != nil {
		t.Fatal("malformed route retained")
	}
}
func TestRefreshUnchangedAndOutageKeepDataConnection(t *testing.T) {
	path := filepath.Join(t.TempDir(), "id")
	id, _ := loadOrMintIdentity(path)
	target := routePeer(t, id, 0, 0, "")
	authority := routePeer(t, id, 5, 4096, peerURL(target))
	tc := routedTestClient(t, authority, id, path)
	ws, err := tc.connectTunnelWS()
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	tc.mu.Lock()
	tc.ws = ws
	tc.mu.Unlock()
	tc.refreshAssignment()
	if err := ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(time.Second)); err != nil {
		t.Fatalf("unchanged route closed live tunnel: %v", err)
	}
	authority.Close()
	tc.refreshAssignment()
	if tc.routeSnapshot() == nil {
		t.Fatal("outage removed cached assignment")
	}
	if err := ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(time.Second)); err != nil {
		t.Fatalf("outage closed live tunnel: %v", err)
	}
}
func TestHTTPAuthRefusalCannotUseCachedAssignment(t *testing.T) {
	path := filepath.Join(t.TempDir(), "id")
	id, _ := loadOrMintIdentity(path)
	target := routePeer(t, id, 0, 0, "")
	authority := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "denied", 403) }))
	defer authority.Close()
	tc := routedTestClient(t, authority, id, path)
	tc.storeRoute(id, &cachedRoute{Authority: tc.tunnelURL, URL: peerURL(target), MaxConnections: 4096})
	ws, err := tc.connectTunnelWS()
	if ws != nil {
		ws.Close()
		t.Fatal("HTTP refusal used cached target")
	}
	if !errors.Is(err, errAuthRefused) {
		t.Fatalf("wrong refusal: %v", err)
	}
	if tc.routeSnapshot() != nil {
		t.Fatal("authoritatively refused assignment retained")
	}
}

func TestAssignmentPersistenceRetriesAfterWriteFailure(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "identity")
	id, _ := loadOrMintIdentity(path)
	tc := &tunnelClient{tunnelURL: "wss://base.example/ws", identityPath: filepath.Join(dir, "later", "identity")}
	r := &cachedRoute{Authority: tc.tunnelURL, URL: "wss://target.example/ws", MaxConnections: 4096}
	if tc.storeRoute(id, r) == nil {
		t.Fatal("expected absent identity path")
	}
	os.Mkdir(filepath.Join(dir, "later"), 0700)
	raw, _ := os.ReadFile(path)
	os.WriteFile(tc.identityPath, raw, 0600)
	if err := tc.storeRoute(id, r); err != nil {
		t.Fatal(err)
	}
	restored, err := loadOrMintIdentity(tc.identityPath)
	if err != nil || restored.Route == nil {
		t.Fatal("unchanged route never retried persistence")
	}
}

func TestLegacyRelayClosingHelloFallsBack(t *testing.T) {
	id, _ := loadOrMintIdentity(filepath.Join(t.TempDir(), "identity"))
	up := websocket.Upgrader{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, e := up.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer ws.Close()
		_, b, e := ws.ReadMessage()
		if e != nil {
			return
		}
		f, _ := decodeMuxFrame(b)
		if f.MsgType == muxHELLO {
			return
		}
		if f.MsgType != muxAUTHID || len(f.Payload) != 88 {
			t.Error("expected v1 identity auth")
		}
		for {
			if _, _, e = ws.ReadMessage(); e != nil {
				return
			}
		}
	}))
	defer srv.Close()
	tc := &tunnelClient{tunnelURL: "ws" + srv.URL[4:] + "/ws"}
	tc.identity.Store(id)
	tc.useID.Store(true)
	if ws, err := tc.connectTunnelWS(); err == nil {
		ws.Close()
		t.Fatal("HELLO unexpectedly accepted")
	}
	ws, err := tc.connectTunnelWS()
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	if !tc.forceV1.Load() || tc.v2.Load() {
		t.Fatal("legacy fallback missing")
	}
}

func TestIdentityReplacementClearsAssignment(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identity")
	id, _ := loadOrMintIdentity(path)
	tc := &tunnelClient{identityPath: path, tunnelURL: "wss://authority.example/ws"}
	tc.identity.Store(id)
	tc.useID.Store(true)
	route := &cachedRoute{Authority: tc.tunnelURL, URL: "wss://relay.example/ws", MaxConnections: 4096}
	if err := tc.storeRoute(id, route); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ID string `json:"install_id"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		if body.ID == id.InstallID {
			w.WriteHeader(409)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()
	tc.registerURL = srv.URL
	if !tc.registerOnce() {
		t.Fatal("replacement registration failed")
	}
	fresh := tc.identity.Load()
	if fresh.InstallID == id.InstallID || tc.routeSnapshot() != nil {
		t.Fatal("identity or route not replaced")
	}
	// A late response for the old identity must not restore either key or route.
	if err := tc.storeRoute(id, route); err == nil {
		t.Fatal("accepted obsolete identity assignment")
	}
	disk, _ := loadOrMintIdentity(path)
	if disk.InstallID != fresh.InstallID || disk.Route != nil || tc.routeSnapshot() != nil {
		t.Fatal("obsolete identity resurrected")
	}
}

func TestAssignedAuthorityTransientHelloCloseKeepsV2(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identity")
	id, _ := loadOrMintIdentity(path)
	target := routePeer(t, id, infoAuthOK, 0, "")
	original := routePeer(t, id, infoRelayRoute, 4096, peerURL(target))
	var unavailable atomic.Bool
	up := websocket.Upgrader{}
	authority := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if unavailable.Load() {
			ws, e := up.Upgrade(w, r, nil)
			if e == nil {
				ws.ReadMessage()
				ws.Close()
			}
			return
		}
		original.Config.Handler.ServeHTTP(w, r)
	}))
	defer authority.Close()
	tc := routedTestClient(t, authority, id, path)
	ws, e := tc.connectTunnelWS()
	if e != nil {
		t.Fatal(e)
	}
	ws.Close()
	unavailable.Store(true)
	ws, e = tc.connectTunnelWS()
	if e != nil {
		t.Fatal(e)
	}
	ws.Close()
	if tc.forceV1.Load() {
		t.Fatal("transient authority failure downgraded assigned client")
	}
	unavailable.Store(false)
	ws, e = tc.connectTunnelWS()
	if e != nil {
		t.Fatal(e)
	}
	ws.Close()
	if tc.routeSnapshot() == nil {
		t.Fatal("authority recovery erased assignment")
	}
}
