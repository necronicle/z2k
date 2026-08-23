package tunshare

import (
	"os"
	"sync"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/tun"
)

// fakeTun — устройство, в которое тест кладёт пакеты.
type fakeTun struct {
	in     chan []byte
	mu     sync.Mutex
	wrote  [][]byte
	closed bool
	events chan tun.Event
}

func newFake() *fakeTun { return &fakeTun{in: make(chan []byte, 16), events: make(chan tun.Event)} }

func (f *fakeTun) File() *os.File { return nil }
func (f *fakeTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	p, ok := <-f.in
	if !ok {
		return 0, os.ErrClosed
	}
	sizes[0] = copy(bufs[0][offset:], p)
	return 1, nil
}
func (f *fakeTun) Write(bufs [][]byte, offset int) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, b := range bufs {
		c := make([]byte, len(b)-offset)
		copy(c, b[offset:])
		f.wrote = append(f.wrote, c)
	}
	return len(bufs), nil
}
func (f *fakeTun) MTU() (int, error)        { return 1280, nil }
func (f *fakeTun) Name() (string, error)    { return "z2ktun0", nil }
func (f *fakeTun) Events() <-chan tun.Event { return f.events }
func (f *fakeTun) BatchSize() int           { return 1 }
func (f *fakeTun) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.closed {
		f.closed = true
		close(f.in)
	}
	return nil
}

func TestPacketsGoToCurrentHandleOnly(t *testing.T) {
	ft := newFake()
	s := New(ft, 1280, 16)
	defer s.Close()
	h1 := s.Handle()
	ft.in <- []byte{1, 1, 1}
	bufs := [][]byte{make([]byte, 2000)}
	sizes := []int{0}
	n, err := h1.Read(bufs, sizes, 16)
	if err != nil || n != 1 || sizes[0] != 3 || bufs[0][16] != 1 {
		t.Fatalf("n=%d err=%v sizes=%v", n, err, sizes)
	}
	h2 := s.Handle() // h1 отвязан
	if _, err := h1.Read(bufs, sizes, 16); err != os.ErrClosed {
		t.Fatalf("old handle must be closed, got %v", err)
	}
	ft.in <- []byte{2, 2}
	n, err = h2.Read(bufs, sizes, 16)
	if err != nil || n != 1 || bufs[0][16] != 2 {
		t.Fatalf("new handle: n=%d err=%v", n, err)
	}
}

func TestWriteGoesToDevice(t *testing.T) {
	ft := newFake()
	s := New(ft, 1280, 16)
	defer s.Close()
	h := s.Handle()
	buf := make([]byte, 16+3)
	copy(buf[16:], []byte{9, 9, 9})
	if _, err := h.Write([][]byte{buf}, 16); err != nil {
		t.Fatal(err)
	}
	ft.mu.Lock()
	defer ft.mu.Unlock()
	if len(ft.wrote) != 1 || string(ft.wrote[0]) != string([]byte{9, 9, 9}) {
		t.Fatalf("%v", ft.wrote)
	}
}

func TestHandleCloseDoesNotCloseDevice(t *testing.T) {
	ft := newFake()
	s := New(ft, 1280, 16)
	h := s.Handle()
	h.Close()
	ft.mu.Lock()
	closed := ft.closed
	ft.mu.Unlock()
	if closed {
		t.Fatal("device closed by handle")
	}
	s.Close()
	ft.mu.Lock()
	closed = ft.closed
	ft.mu.Unlock()
	if !closed {
		t.Fatal("device not closed by Shared.Close")
	}
}

func TestReadUnblocksOnClose(t *testing.T) {
	ft := newFake()
	s := New(ft, 1280, 16)
	defer s.Close()
	h := s.Handle()
	done := make(chan error, 1)
	go func() {
		_, err := h.Read([][]byte{make([]byte, 2000)}, []int{0}, 16)
		done <- err
	}()
	time.Sleep(20 * time.Millisecond)
	h.Close()
	select {
	case err := <-done:
		if err != os.ErrClosed {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Read did not unblock")
	}
}

func TestBatchRead(t *testing.T) {
	ft := newFake()
	s := New(ft, 1280, 16)
	defer s.Close()
	h := s.Handle()
	ft.in <- []byte{1}
	ft.in <- []byte{2}
	ft.in <- []byte{3}
	time.Sleep(20 * time.Millisecond)
	bufs := [][]byte{make([]byte, 100), make([]byte, 100)}
	sizes := []int{0, 0}
	n, err := h.Read(bufs, sizes, 16)
	if err != nil || n != 2 || bufs[0][16] != 1 || bufs[1][16] != 2 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	n, _ = h.Read(bufs, sizes, 16)
	if n != 1 || bufs[0][16] != 3 {
		t.Fatalf("rest: n=%d", n)
	}
}
