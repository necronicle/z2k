package engine

import (
	"os"
	"sync"

	"golang.zx2c4.com/wireguard/tun"
)

// nullTun — tun.Device без устройства: Read блокируется до Close, Write
// глотает. Нужен, чтобы проверить WG-handshake, не трогая рабочий TUN,
// на котором в этот момент живёт h2-сессия.
type nullTun struct {
	once   sync.Once
	closed chan struct{}
	events chan tun.Event
	mtu    int
}

func newNullTun(mtu int) *nullTun {
	return &nullTun{closed: make(chan struct{}), events: make(chan tun.Event, 1), mtu: mtu}
}

func (n *nullTun) File() *os.File { return nil }
func (n *nullTun) Read(_ [][]byte, _ []int, _ int) (int, error) {
	<-n.closed
	return 0, os.ErrClosed
}
func (n *nullTun) Write(bufs [][]byte, _ int) (int, error) { return len(bufs), nil }
func (n *nullTun) MTU() (int, error)                       { return n.mtu, nil }
func (n *nullTun) Name() (string, error)                   { return "null", nil }
func (n *nullTun) Events() <-chan tun.Event                { return n.events }
func (n *nullTun) BatchSize() int                          { return 1 }
func (n *nullTun) Close() error {
	n.once.Do(func() { close(n.closed); close(n.events) })
	return nil
}
