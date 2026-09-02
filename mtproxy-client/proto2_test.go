package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"testing"
	"time"
)

func TestHelloEncode(t *testing.T) {
	h := encodeHello("r-82")
	if h[0] != protoVersion2 || h[1] != 4 || string(h[2:6]) != "r-82" || len(h) != 10 {
		t.Fatalf("HELLO: %v", h)
	}
}

func TestHelloAckDecode(t *testing.T) {
	var p []byte
	p = append(p, 2)
	p = binary.BigEndian.AppendUint64(p, 1788300000)
	p = append(p, bytes.Repeat([]byte{9}, 16)...)
	p = append(p, 4)
	p = append(p, "r-82"...)
	p = binary.BigEndian.AppendUint32(p, 262144)
	p = binary.BigEndian.AppendUint32(p, 0)
	a, err := decodeHelloAck(p)
	if err != nil || a.ServerUnix != 1788300000 || a.Nonce[3] != 9 || a.MinBuild != "r-82" || a.DefaultWindow != 262144 {
		t.Fatalf("%+v %v", a, err)
	}
	if _, err := decodeHelloAck(p[:20]); err == nil {
		t.Fatal("короткий HELLO_ACK принят")
	}
}

func TestAuthPayloadV2(t *testing.T) {
	id, err := loadOrMintIdentity(t.TempDir() + "/id")
	if err != nil {
		t.Fatal(err)
	}
	var nonce [16]byte
	copy(nonce[:], bytes.Repeat([]byte{7}, 16))
	ts := time.Now().Unix() + 5
	p := id.authPayloadV2(ts, nonce)
	if len(p) != 104 {
		t.Fatalf("длина %d, ожидалось 104", len(p))
	}
	raw, _ := hex.DecodeString(id.InstallID)
	if !bytes.Equal(p[0:16], raw) || int64(binary.BigEndian.Uint64(p[16:24])) != ts || !bytes.Equal(p[24:40], nonce[:]) {
		t.Fatal("раскладка id|ts|nonce")
	}
	if !verifySig(id, p[0:40], p[40:104]) {
		t.Fatal("подпись не над 40 байтами")
	}
}

func TestWindowInfoClose(t *testing.T) {
	c, err := decodeWindow(encodeWindow(4096))
	if err != nil || c != 4096 {
		t.Fatal("window")
	}
	if r, txt := decodeClose(append([]byte{rProtocol}, "x"...)); r != rProtocol || txt != "x" || reasonName(r) != "protocol" {
		t.Fatal("close")
	}
	if r, _ := decodeClose(nil); r != rNormal {
		t.Fatal("пустой CLOSE = normal")
	}
	p := append([]byte{infoRetryAfter}, 0, 0, 0, 37)
	k, arg, _, err := decodeInfo(p)
	if err != nil || k != infoRetryAfter || arg != 37 {
		t.Fatal("info")
	}
	if decodeConnectOK(nil) != 0 {
		t.Fatal("v1 CONNECT_OK без окна = 0")
	}
}
