package wg

import (
	"testing"

	"golang.zx2c4.com/wireguard/conn"
)

type fakeBind struct {
	conn.Bind
	sent [][]byte
	recv [][]byte
}

func (f *fakeBind) Send(bufs [][]byte, _ conn.Endpoint) error {
	for _, b := range bufs {
		c := make([]byte, len(b))
		copy(c, b)
		f.sent = append(f.sent, c)
	}
	return nil
}

func (f *fakeBind) Open(uint16) ([]conn.ReceiveFunc, uint16, error) {
	rf := func(packets [][]byte, sizes []int, _ []conn.Endpoint) (int, error) {
		n := 0
		for i := range f.recv {
			if i >= len(packets) {
				break
			}
			sizes[i] = copy(packets[i], f.recv[i])
			n++
		}
		return n, nil
	}
	return []conn.ReceiveFunc{rf}, 0, nil
}

func TestSendPatchesReservedBytes(t *testing.T) {
	fb := &fakeBind{}
	b := NewReservedBind(fb, [3]byte{0x32, 0xfd, 0x2c})
	pkt := []byte{1, 0, 0, 0, 0xaa, 0xbb}
	if err := b.Send([][]byte{pkt}, nil); err != nil {
		t.Fatal(err)
	}
	got := fb.sent[0]
	if got[0] != 1 || got[1] != 0x32 || got[2] != 0xfd || got[3] != 0x2c || got[4] != 0xaa {
		t.Fatalf("bytes not patched: %x", got)
	}
}

func TestSendLeavesShortPacketsAlone(t *testing.T) {
	fb := &fakeBind{}
	b := NewReservedBind(fb, [3]byte{1, 2, 3})
	if err := b.Send([][]byte{{9, 9}}, nil); err != nil {
		t.Fatal(err)
	}
	if string(fb.sent[0]) != string([]byte{9, 9}) {
		t.Fatalf("short packet mutated: %x", fb.sent[0])
	}
}

func TestReceiveZeroesReservedBytes(t *testing.T) {
	fb := &fakeBind{recv: [][]byte{{4, 0x32, 0xfd, 0x2c, 0x55}}}
	b := NewReservedBind(fb, [3]byte{0x32, 0xfd, 0x2c})
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	packets := [][]byte{make([]byte, 64)}
	sizes := make([]int, 1)
	eps := make([]conn.Endpoint, 1)
	n, err := fns[0](packets, sizes, eps)
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	got := packets[0][:sizes[0]]
	if got[1] != 0 || got[2] != 0 || got[3] != 0 || got[4] != 0x55 {
		t.Fatalf("reserved not zeroed: %x", got)
	}
}
