package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestIsolatedFlowsSurviveNeighborClose(t *testing.T) {
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	var sessions atomic.Int32
	var activeSessions atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
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
			return
		}
		ack := []byte{protoVersion2}
		ack = binary.BigEndian.AppendUint64(ack, uint64(time.Now().Unix()))
		nonce := make([]byte, 16)
		rand.Read(nonce)
		ack = append(ack, nonce...)
		ack = append(ack, 0)
		ack = binary.BigEndian.AppendUint32(ack, 2*1024*1024)
		ack = binary.BigEndian.AppendUint32(ack, 0)
		ws.WriteMessage(2, encodeMuxFrame(0, muxHELLO_ACK, ack))
		_, b, err = ws.ReadMessage()
		if err != nil {
			return
		}
		f, _ = decodeMuxFrame(b)
		if f.MsgType != muxAUTHID || len(f.Payload) != 104 {
			return
		}
		wantID, _ := hex.DecodeString(id.InstallID)
		if !bytes.Equal(f.Payload[:16], wantID) || int64(binary.BigEndian.Uint64(f.Payload[16:24])) < time.Now().Unix()-5 || int64(binary.BigEndian.Uint64(f.Payload[16:24])) > time.Now().Unix()+5 || !bytes.Equal(f.Payload[24:40], nonce) || !ed25519.Verify(id.priv.Public().(ed25519.PublicKey), f.Payload[:40], f.Payload[40:]) {
			t.Error("invalid per-install signature/identity/nonce")
			return
		}
		sessions.Add(1)
		activeSessions.Add(1)
		defer activeSessions.Add(-1)
		ws.WriteMessage(2, encodeMuxFrame(0, muxINFO, []byte{infoAuthOK, 0, 0, 0, 0}))
		for {
			_, b, err = ws.ReadMessage()
			if err != nil {
				return
			}
			f, _ = decodeMuxFrame(b)
			switch f.MsgType {
			case muxCONNECT:
				ws.WriteMessage(2, encodeMuxFrame(f.StreamID, muxCONNECT_OK, binary.BigEndian.AppendUint32(nil, 2*1024*1024)))
			case muxDATA:
				ws.WriteMessage(2, encodeMuxFrame(f.StreamID, muxDATA, f.Payload))
			case muxCLOSE:
				return
			}
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := newTunnelClient("ws"+strings.TrimPrefix(server.URL, "http"), "")
	root.ctx = ctx
	root.identity.Store(id)

	root.useID.Store(true)
	root.v2.Store(true)
	root.writer = &wsWriter{} // readiness only; isolated data must not use this writer
	root.isolation = newIsolationBudget(2)
	discoveryDone := make(chan struct{})
	go func() { defer close(discoveryDone); root.runDiscovery() }()
	defer func() { cancel(); <-discoveryDone }()
	deadline := time.Now().Add(3 * time.Second)
	for !root.discoveryReady() || activeSessions.Load() != 0 {
		if time.Now().After(deadline) {
			t.Fatal("discovery retained its session")
		}
		time.Sleep(time.Millisecond)
	}

	done := make(chan struct{}, 2)
	phones := make([]net.Conn, 2)
	for i := range phones {
		local, phone := phonePair(t)
		phones[i] = phone
		defer phone.Close()
		go func() {
			defer func() { done <- struct{}{} }()
			root.handleIsolated(local, net.IPv4(149, 154, 167, 51), 443)
		}()
		time.Sleep(10 * time.Millisecond) // both flows can be admitted in the same burst
	}
	echo := func(c net.Conn) {
		t.Helper()
		c.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err := c.Write([]byte("hello")); err != nil {
			t.Fatal(err)
		}
		b := make([]byte, 5)
		if _, err := io.ReadFull(c, b); err != nil {
			t.Fatal(err)
		}
		if string(b) != "hello" {
			t.Fatal("wrong echo")
		}
	}
	echo(phones[0])
	echo(phones[1])
	if sessions.Load() != 3 {
		t.Fatalf("sessions=%d", sessions.Load())
	}
	phones[0].Close()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("closed flow leaked session")
	}
	echo(phones[1])
	cancel() // shutdown must close the remaining flow without waiting for peer EOF
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("second flow leaked session")
	}
	root.isolation.mu.Lock()
	active := root.isolation.active
	root.isolation.mu.Unlock()
	if active != 0 {
		t.Fatalf("leaked isolation budget: %d", active)
	}
}

func TestIsolatedAuthRefusalClosesWithoutRetry(t *testing.T) {
	budget := newIsolationBudget(2)
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		http.Error(w, "denied", http.StatusForbidden)
	}))
	defer server.Close()
	local, phone := phonePair(t)
	defer phone.Close()
	tc := newTunnelClient("ws"+strings.TrimPrefix(server.URL, "http"), "")
	done := make(chan struct{})
	go func() {
		defer close(done)
		tc.serveIsolated(context.Background(), local, id, net.IPv4(149, 154, 167, 51), 443, func(error) { budget.failed() })
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("auth failure leaked worker")
	}
	phone.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, err := phone.Read(b[:]); err == nil {
		t.Fatal("phone kept open")
	}
	if budget.acquire(time.Now()) {
		t.Fatal("failed handshake did not enter cooldown")
	}
	if attempts.Load() != 1 {
		t.Fatalf("auth refusal retried %d times", attempts.Load())
	}
	if tc.forceV1.Load() {
		t.Fatal("auth refusal downgraded protocol")
	}
}

func TestIsolationBudgetBoundAndCooldown(t *testing.T) {
	b := newIsolationBudget(2)
	now := time.Now()
	if !b.acquire(now) || !b.acquire(now) {
		t.Fatal("artificial pacing on available capacity")
	}
	if b.acquire(now.Add(2 * time.Second)) {
		t.Fatal("session limit failed")
	}
	b.release()
	b.failed()
	if b.acquire(time.Now().Add(time.Second)) {
		t.Fatal("failure cooldown bypassed")
	}
	if !b.acquire(time.Now().Add(31 * time.Second)) {
		t.Fatal("cooldown never recovered")
	}
	b.release()
	b.release()
	if newIsolationBudget(0).acquire(now) {
		t.Fatal("disabled mode admitted session")
	}
}

func TestIsolationPreservesPrimaryPolicy(t *testing.T) {
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"unregistered", "offline", "capacity"} {
		t.Run(mode, func(t *testing.T) {
			tc := newTunnelClient("wss://example.test/ws", "")
			tc.isolation = newIsolationBudget(2)
			tc.identity.Store(id)
			tc.authenticatedIdentity.Store(id)
			tc.useID.Store(true)
			tc.v2.Store(true)
			tc.writer = &wsWriter{}
			switch mode {
			case "disabled":
				tc.isolation = nil
			case "unregistered":
				tc.useID.Store(false)
			case "offline":
				tc.authenticatedIdentity.Store(nil)
			case "legacy":
				tc.v2.Store(false)
			case "assigned":
				tc.route = &cachedRoute{URL: "wss://assigned.example/ws"}
			case "reconnecting":
				tc.connectMu.Lock()
				defer tc.connectMu.Unlock()
			case "capacity":
				tc.isolation.active = 2
			}
			if child, _ := tc.reserveIsolated(""); child != nil {
				t.Fatal("must wait without a shared-transport fallback")
			}
		})
	}
}

func TestDedicatedTransportDefault(t *testing.T) {
	if flag.Lookup("relay-sessions").DefValue != "1024" {
		t.Fatal("dedicated session default changed")
	}
}

func TestIsolatedAssignedAndLegacyStayDedicated(t *testing.T) {
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	for _, assigned := range []bool{false, true} {
		tc := newTunnelClient("wss://authority.example/ws", "")
		tc.isolation = newIsolationBudget(16)
		tc.identity.Store(id)
		tc.authenticatedIdentity.Store(id)
		tc.useID.Store(true)
		tc.writer = &wsWriter{}
		expected := tc.tunnelURL
		if assigned {
			expected = "wss://assigned.example/ws"
			tc.route = &cachedRoute{URL: expected}
		} else {
			tc.forceV1.Store(true)
		}
		child, gotID := tc.reserveIsolated("")
		if child == nil || gotID != id || child.tunnelURL != expected {
			t.Fatal("route or identity lost")
		}
		if child.forceV1.Load() == assigned {
			t.Fatal("negotiated protocol lost")
		}
		tc.isolation.release()
	}
}

func TestIsolatedQueueCancellationDoesNotUseSharedWriter(t *testing.T) {
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	tc := newTunnelClient("wss://authority.example/ws", "")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tc.ctx = ctx
	tc.isolation = newIsolationBudget(1)
	tc.isolation.active = 1
	tc.writer = &wsWriter{} // touching the old writer would panic
	local, phone := phonePair(t)
	defer phone.Close()
	done := make(chan struct{})
	go func() { defer close(done); tc.handleIsolated(local, net.IPv4(149, 154, 167, 51), 443) }()
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("queue failed to cancel")
	}
	phone.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, err := phone.Read(b[:]); err == nil {
		t.Fatal("queued phone remained open")
	}
}

func TestDeviceFairnessAndServerBudget(t *testing.T) {
	b := newIsolationBudget(64)
	b.setServerLimit(64)
	if b.limit != 63 {
		t.Fatal("server headroom missing")
	}
	now := time.Now()
	for i := 0; i < 48; i++ {
		b.enqueue("phone")
	}
	b.enqueue("pc")
	b.enqueue("phone2")
	if !b.acquireFor(now, "phone") {
		t.Fatal("first phone blocked")
	}
	if b.acquireFor(now.Add(time.Second), "phone") {
		t.Fatal("phone jumped ahead of another device")
	}
	if !b.acquireFor(now.Add(time.Second), "pc") || !b.acquireFor(now.Add(2*time.Second), "phone2") {
		t.Fatal("devices starved")
	}
	for i := 1; i < 47; i++ {
		if !b.acquireFor(now.Add(time.Duration(i+2)*time.Second), "phone") {
			t.Fatal("device admitted too few")
		}
	}
	if b.acquireFor(now.Add(time.Minute), "phone") {
		t.Fatal("one device consumed reserved headroom")
	}
	b.enqueue("pc2")
	if !b.acquireFor(now.Add(time.Minute), "pc2") {
		t.Fatal("busy phone blocked another device")
	}
	b.setServerLimit(1)
	if b.limit != 1 || b.acquireFor(now.Add(2*time.Minute), "phone") {
		t.Fatal("small server budget bypassed")
	}
	if b.active != 50 {
		t.Fatal("changing quota must not evict existing flows")
	}
}
func TestSessionBudgetDecode(t *testing.T) {
	for _, tt := range []struct {
		text  string
		limit int
		fail  bool
	}{
		{"", 0, false}, {`{"session_limit":64}`, 64, false}, {`{"session_limit":1}`, 1, false},
		{`{"session_limit":-1}`, 0, true}, {`{"session_limit":999999}`, 0, true},
	} {
		got, err := decodeSessionBudget(tt.text)
		if (err != nil) != tt.fail || got != tt.limit {
			t.Fatalf("%s: %d %v", tt.text, got, err)
		}
	}
}

func TestDiscoveryCannotStealLastDataSlot(t *testing.T) {
	b := newIsolationBudget(64)
	b.setServerLimit(1)
	if !b.reserveProbe() {
		t.Fatal("initial discovery blocked")
	}
	if b.acquire(time.Now()) {
		t.Fatal("data bypassed probe reservation")
	}
	b.releaseProbe()
	if !b.acquire(time.Now()) {
		t.Fatal("single-session server cannot serve data")
	}
	if b.reserveProbe() {
		t.Fatal("discovery stole occupied data slot")
	}
	b.release()
	if !b.reserveProbe() {
		t.Fatal("discovery cannot resume after close")
	}
	b.releaseProbe()
}

func TestDiscoveryNetworkLockDoesNotBlockDataAdmission(t *testing.T) {
	tc := newTunnelClient("wss://authority.example/ws", "")
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	tc.identity.Store(id)
	tc.authenticatedIdentity.Store(id)
	tc.useID.Store(true)
	tc.isolation = newIsolationBudget(64)
	tc.route = &cachedRoute{URL: "wss://assigned.example/ws"}
	tc.connectMu.Lock() // a background probe is stalled on network I/O
	defer tc.connectMu.Unlock()
	done := make(chan *tunnelClient, 1)
	go func() { child, _ := tc.reserveIsolated(""); done <- child }()
	select {
	case child := <-done:
		if child == nil || child.tunnelURL != "wss://assigned.example/ws" {
			t.Fatal("healthy assigned route blocked")
		}
		tc.isolation.release()
	case <-time.After(time.Second):
		t.Fatal("data admission blocked behind discovery")
	}
}

func TestBusyIsNotIdentityRefusal(t *testing.T) {
	path := t.TempDir() + "/id"
	id, err := loadOrMintIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	server := routePeer(t, id, infoGoodbye, 11, "session quota")
	tc := routedTestClient(t, server, id, path)
	_, err = tc.connectEndpoint(tc.tunnelURL, id)
	if !errors.Is(err, errRelayBusy) || errors.Is(err, errAuthRefused) || tc.forceV1.Load() {
		t.Fatalf("capacity misclassified: %v", err)
	}
}

func TestFullCapacityRejectsPromptly(t *testing.T) {
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	tc := newTunnelClient("wss://authority.example/ws", "")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tc.ctx = ctx
	tc.isolation = newIsolationBudget(1)
	tc.isolation.active = 1
	local, phone := phonePair(t)
	defer phone.Close()
	done := make(chan struct{})
	go func() { defer close(done); tc.handleIsolated(local, net.IPv4(149, 154, 167, 51), 443) }()
	select {
	case <-done:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("full capacity left Telegram waiting on an accepted socket")
	}
	if tc.isolation.active != 1 {
		t.Fatal("rejection modified an existing session")
	}
}

func TestHandshakeGateAllowsBurstAndBoundsConcurrency(t *testing.T) {
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	entered := make(chan struct{}, 8)
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		<-release
		http.Error(w, "denied", http.StatusForbidden)
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := newTunnelClient("ws"+strings.TrimPrefix(server.URL, "http"), "")
	root.ctx = ctx
	root.identity.Store(id)
	root.authenticatedIdentity.Store(id)
	root.useID.Store(true)
	root.isolation = newIsolationBudget(64)
	done := make(chan struct{}, 5)
	for i := 0; i < 5; i++ {
		local, phone := phonePair(t)
		defer phone.Close()
		go func() {
			defer func() { done <- struct{}{} }()
			root.handleIsolated(local, net.IPv4(149, 154, 167, 51), 443)
		}()
	}
	deadline := time.NewTimer(500 * time.Millisecond)
	defer deadline.Stop()
	for i := 0; i < 4; i++ {
		select {
		case <-entered:
		case <-deadline.C:
			once.Do(func() { close(release) })
			t.Fatal("four ready flows were artificially paced")
		}
	}
	select {
	case <-entered:
		once.Do(func() { close(release) })
		t.Fatal("more than four concurrent handshakes")
	case <-time.After(30 * time.Millisecond):
	}
	once.Do(func() { close(release) })
	for i := 0; i < 5; i++ {
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("handshake slot leaked")
		}
	}
	if root.isolation.active != 0 {
		t.Fatal("session budget leaked")
	}
}

func TestTransientHandshakeFailureKeepsOtherAdmissionsReady(t *testing.T) {
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "temporary", http.StatusBadGateway) }))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tc := newTunnelClient("ws"+strings.TrimPrefix(server.URL, "http"), "")
	tc.ctx = ctx
	tc.identity.Store(id)
	tc.authenticatedIdentity.Store(id)
	tc.useID.Store(true)
	tc.isolation = newIsolationBudget(64)
	local, phone := phonePair(t)
	defer phone.Close()
	done := make(chan struct{})
	go func() { defer close(done); tc.handleIsolated(local, net.IPv4(149, 154, 167, 51), 443) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("failed flow did not close")
	}
	child, _ := tc.reserveIsolated("")
	if child == nil {
		t.Fatal("one transport failure paused unrelated new flows")
	}
	tc.isolation.release()
}

func TestDedicatedQuotaDoesNotTreatAggregatedGatewayAsOnePhone(t *testing.T) {
	b := newIsolationBudget(1024)
	b.setServerLimit(1024)
	now := time.Now()
	for i := 0; i < 604; i++ {
		if !b.acquireFor(now, "") {
			t.Fatalf("dedicated gateway stopped at %d flows", i)
		}
	}
	if b.limit != 1023 {
		t.Fatalf("quota headroom: %d", b.limit)
	}
}

func TestCommunityQuotaKeepsSourceReserveWithLargerLocalCeiling(t *testing.T) {
	b := newIsolationBudget(1024)
	b.setServerLimit(64)
	if b.limit != 63 {
		t.Fatalf("community quota: %d", b.limit)
	}
	for i := 0; i < 47; i++ {
		if !b.acquireFor(time.Now(), "") {
			t.Fatal(i)
		}
	}
	if b.acquireFor(time.Now(), "") {
		t.Fatal("community source consumed reserved headroom")
	}
	b.setServerLimit(0)
	if b.limit != 48 || b.deviceLimit != 32 {
		t.Fatal("legacy fallback increased")
	}
}
