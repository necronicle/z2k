package main

import (
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"testing"
	"time"
)

func TestSessionBudgetCapability(t *testing.T) {
	if got := sessionBudgetText(1, 64); got != "" {
		t.Fatal("legacy auth response changed")
	}
	if got := sessionBudgetText(3, 64); got != `{"session_limit":64}` {
		t.Fatal(got)
	}
	if got := sessionBudgetText(3, 1); got != `{"session_limit":1}` {
		t.Fatal(got)
	}
}

func TestSessionBudgetWireCompatibility(t *testing.T) {
	url := startRelay(t)
	id, key := testInstall(t)
	for _, caps := range []uint32{1, 3} {
		ws := dialWS(t, url)
		sendFrame(t, ws, 0, muxHELLO, binary.BigEndian.AppendUint32([]byte{2, 0}, caps))
		ack, err := decodeHelloAck(expectFrame(t, ws, 0, muxHELLO_ACK, time.Second))
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := hex.DecodeString(id)
		msg := append(raw, binary.BigEndian.AppendUint64(nil, uint64(ack.ServerUnix))...)
		msg = append(msg, ack.Nonce[:]...)
		sendFrame(t, ws, 0, muxAUTHID, append(msg, ed25519.Sign(key, msg)...))
		kind, arg, text, err := decodeInfo(expectFrame(t, ws, 0, muxINFO, time.Second))
		if err != nil || kind != infoAuthOK || arg != uint32(*maxStreamsPerSess) {
			t.Fatal("AUTH_OK argument contract changed")
		}
		want := ""
		if caps&2 != 0 {
			want = fmt.Sprintf(`{"session_limit":%d}`, *perInstallMaxSessions)
		}
		if text != want {
			t.Fatalf("caps%d: %q != %q", caps, text, want)
		}
		ws.Close()
	}
}
