package main

import (
	"bytes"
	"testing"
)

func TestHelloRoundTrip(t *testing.T) {
	p := []byte{2, 5, 'r', '-', '8', '2', 'x', 0, 0, 0, 3}
	h, err := decodeHello(p)
	if err != nil || h.Ver != 2 || h.Build != "r-82x" || h.Caps != 3 {
		t.Fatalf("decodeHello: %+v %v", h, err)
	}
	if _, err := decodeHello([]byte{2, 9, 'a'}); err == nil {
		t.Fatal("build_len больше payload принят")
	}
}

func TestHelloAckRoundTrip(t *testing.T) {
	a := helloAck{Ver: 2, ServerUnix: 1788300000, MinBuild: "r-82", DefaultWindow: 262144, Caps: 1}
	copy(a.Nonce[:], bytes.Repeat([]byte{7}, 16))
	got, err := decodeHelloAck(encodeHelloAck(a))
	if err != nil || got != a {
		t.Fatalf("round-trip: %+v %v", got, err)
	}
}

func TestClosePayload(t *testing.T) {
	r, txt := decodeClose(nil)
	if r != rNormal || txt != "" {
		t.Fatalf("пустой CLOSE = NORMAL, получено %d %q", r, txt)
	}
	r, txt = decodeClose(encodeClose(rQueueLimit, "окно"))
	if r != rQueueLimit || txt != "окно" {
		t.Fatalf("round-trip: %d %q", r, txt)
	}
	if reasonName(rReplaced) != "replaced" || reasonName(99) != "unknown" {
		t.Fatal("reasonName")
	}
}

func TestWindowAndInfo(t *testing.T) {
	c, err := decodeWindow(encodeWindow(65536))
	if err != nil || c != 65536 {
		t.Fatal("window")
	}
	if _, err := decodeWindow([]byte{1, 2}); err == nil {
		t.Fatal("короткий WINDOW принят")
	}
	k, arg, txt, err := decodeInfo(encodeInfo(infoRetryAfter, 37, "деплой"))
	if err != nil || k != infoRetryAfter || arg != 37 || txt != "деплой" {
		t.Fatal("info")
	}
	if decodeConnectOK(nil) != 0 || decodeConnectOK(encodeConnectOK(4096)) != 4096 {
		t.Fatal("connect_ok window")
	}
}

func TestAuthV2Layout(t *testing.T) {
	p := make([]byte, 104)
	for i := range p {
		p[i] = byte(i)
	}
	a, err := decodeAuthV2(p)
	if err != nil {
		t.Fatal(err)
	}
	if a.ID != "000102030405060708090a0b0c0d0e0f" || a.TS != 0x1011121314151617 || a.Nonce[0] != 0x18 || len(a.Sig) != 64 || len(a.Signed) != 40 {
		t.Fatalf("раскладка: %+v", a)
	}
	if _, err := decodeAuthV2(p[:88]); err == nil {
		t.Fatal("88 байт приняты как v2")
	}
}

func TestFrameCodecStillWorks(t *testing.T) {
	f := encodeFrame(513, muxDATA, []byte("x"))
	sid, mt, p, err := decodeFrame(f)
	if err != nil || sid != 513 || mt != muxDATA || string(p) != "x" {
		t.Fatal("кодек кадра сломан переездом")
	}
}
