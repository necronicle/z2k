package h2

import (
	"bytes"
	"io"
	"testing"
)

func TestDatagramCapsuleRoundTrip(t *testing.T) {
	pkt := []byte{0x45, 0, 0, 20, 1, 2, 3}
	enc := EncodeDatagram(pkt)
	// type=0x00 (varint 1 байт), length=len(pkt), дальше сам пакет — без context id
	if enc[0] != 0x00 || int(enc[1]) != len(pkt) || enc[2] != 0x45 {
		t.Fatalf("%x", enc)
	}
	d := NewDecoder(bytes.NewReader(append(append([]byte{}, enc...), enc...)))
	for i := 0; i < 2; i++ {
		got, err := d.Next()
		if err != nil || !bytes.Equal(got, pkt) {
			t.Fatalf("%x %v", got, err)
		}
	}
	if _, err := d.Next(); err != io.EOF {
		t.Fatalf("want EOF, got %v", err)
	}
}

func TestDecoderSkipsUnknownCapsule(t *testing.T) {
	unknown := []byte{0x41, 0x00, 0x02, 0xaa, 0xbb} // type varint 2 байта (0x0100), len 2
	d := NewDecoder(bytes.NewReader(append(unknown, EncodeDatagram([]byte{1})...)))
	got, err := d.Next()
	if err != nil || !bytes.Equal(got, []byte{1}) {
		t.Fatalf("%x %v", got, err)
	}
}

func TestDecoderSkipsEmptyDatagram(t *testing.T) {
	empty := []byte{0x00, 0x00}
	d := NewDecoder(bytes.NewReader(append(empty, EncodeDatagram([]byte{7})...)))
	got, err := d.Next()
	if err != nil || !bytes.Equal(got, []byte{7}) {
		t.Fatalf("%x %v", got, err)
	}
}

func TestDecoderRejectsOversize(t *testing.T) {
	huge := append(putVarint(nil, 0), putVarint(nil, 1<<20)...)
	d := NewDecoder(bytes.NewReader(huge))
	if _, err := d.Next(); err == nil {
		t.Fatal("want error on oversize capsule")
	}
}

func TestVarint(t *testing.T) {
	for _, v := range []uint64{0, 63, 64, 16383, 16384, 1 << 30, 1<<62 - 1} {
		b := putVarint(nil, v)
		got, n := getVarint(b)
		if got != v || n != len(b) {
			t.Fatalf("%d -> %x -> %d (n=%d)", v, b, got, n)
		}
	}
	if _, n := getVarint(nil); n != 0 {
		t.Fatal("empty must return n=0")
	}
	if _, n := getVarint([]byte{0x80}); n != 0 { // 4-байтовый префикс без хвоста
		t.Fatal("truncated must return n=0")
	}
}
