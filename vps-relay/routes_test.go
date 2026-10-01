package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"
)

func routeFixture(t *testing.T, id string) string {
	t.Helper()
	path := t.TempDir() + "/routes.json"
	os.WriteFile(path, []byte(`{"`+id+`":{"url":"wss://relay.example/ws","max_connections":4096}}`), 0600)
	if err := loadRelayRoutes(path); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { loadRelayRoutes("") })
	return path
}

// A configured ID must not disclose/receive an assignment without proof of its key.
func TestRouteRequiresProofAndCapability(t *testing.T) {
	for _, tc := range []struct {
		name              string
		caps              uint32
		forge, wrongNonce bool
		want              byte
	}{
		{"signed", 1, false, false, 5}, {"legacy", 0, false, false, 4},
		{"forged", 1, true, false, 4}, {"wrong nonce", 1, false, true, 4},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id, key := testInstall(t)
			reg.setRevoked(id, true)
			routeFixture(t, id)
			ws := dialWS(t, startRelay(t))
			hello := binary.BigEndian.AppendUint32([]byte{2, 1, 'x'}, tc.caps)
			sendFrame(t, ws, 0, muxHELLO, hello)
			ack, err := decodeHelloAck(expectFrame(t, ws, 0, muxHELLO_ACK, time.Second))
			if err != nil {
				t.Fatal(err)
			}
			raw, _ := hex.DecodeString(id)
			msg := append(raw, binary.BigEndian.AppendUint64(nil, uint64(ack.ServerUnix))...)
			if tc.wrongNonce {
				ack.Nonce[0] ^= 1
			}
			msg = append(msg, ack.Nonce[:]...)
			sig := ed25519.Sign(key, msg)
			if tc.forge {
				sig[0] ^= 1
			}
			sendFrame(t, ws, 0, muxAUTHID, append(msg, sig...))
			p := expectFrame(t, ws, 0, muxINFO, time.Second)
			kind, arg, text, err := decodeInfo(p)
			if err != nil || kind != tc.want {
				t.Fatalf("kind=%d arg=%d text=%s err=%v", kind, arg, text, err)
			}
			if kind == 5 && (arg != 4096 || text != "wss://relay.example/ws") {
				t.Fatalf("bad assignment: %d %q", arg, text)
			}
			if !reg.get(id).Revoked {
				t.Fatal("routing cleared data revocation")
			}
		})
	}
}

func TestRouteReloadRejectsInvalidAndRetainsLastGood(t *testing.T) {
	id, _ := testInstall(t)
	path := routeFixture(t, id)
	for _, url := range []string{"ws://relay.example/ws", "wss://u:p@relay.example/ws", "wss://127.0.0.1/ws", "wss://10.1.2.3/ws", "wss://relay.example/ws?secret=x", "wss://relay.example/ws#x", "wss://relay.example/"} {
		b, _ := json.Marshal(map[string]relayRoute{id: {URL: url, MaxConnections: 4096}})
		os.WriteFile(path, b, 0600)
		if loadRelayRoutes(path) == nil {
			t.Fatalf("accepted %q", url)
		}
		r, ok := routeFor(id)
		if !ok || r.URL != "wss://relay.example/ws" {
			t.Fatal("bad reload erased good policy")
		}
	}
	os.WriteFile(path, []byte(`{"`+id+`":{"url":"wss://relay.example/ws","max_connections":8193}}`), 0600)
	if loadRelayRoutes(path) == nil {
		t.Fatal("accepted excessive limit")
	}
}

func TestClosedRegistrationCannotMint(t *testing.T) {
	old := *registrationClosed
	*registrationClosed = true
	t.Cleanup(func() { *registrationClosed = old })
	id, key := testInstall(t)
	for _, known := range []bool{true, false} {
		useID := id
		if !known {
			useID = "ffffffffffffffffffffffffffffffff"
		}
		body, _ := json.Marshal(registerReq{InstallID: useID, Pubkey: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))})
		mac := hmac.New(sha256.New, []byte(*secret))
		mac.Write(body)
		req := httptest.NewRequest(http.MethodPost, "/register", bytes.NewReader(body))
		req.Header.Set("X-Z2K-Auth", hex.EncodeToString(mac.Sum(nil)))
		out := httptest.NewRecorder()
		handleRegister(out, req)
		want := 200
		if !known {
			want = 403
		}
		if out.Code != want {
			t.Fatalf("known=%v status=%d", known, out.Code)
		}
		if !known && reg.get(useID) != nil {
			t.Fatal("unknown installation minted")
		}
	}
}

func TestTotalStreamCapConcurrentAndRelease(t *testing.T) {
	withInts(t, maxStreamsTotal, 32)
	before := liveStreams.Load()
	if before != 0 {
		t.Fatalf("baseline streams %d", before)
	}
	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); acquireStream() }()
	}
	wg.Wait()
	if liveStreams.Load() != 32 {
		t.Fatalf("reserved %d", liveStreams.Load())
	}
	liveStreams.Add(-1)
	if !acquireStream() || acquireStream() {
		t.Fatal("release/admission mismatch")
	}
	liveStreams.Store(0)
}
