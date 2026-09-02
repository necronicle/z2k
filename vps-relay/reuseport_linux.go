//go:build linux

package main

import (
	"context"
	"net"
	"syscall"
)

// listenReusePort — SO_REUSEPORT: два экземпляра релея слушают один порт,
// ядро раздаёт новые соединения обоим; так деплой идёт без окна, когда
// порт никто не слушает (спека §3.6).
func listenReusePort(network, addr string) (net.Listener, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var serr error
		err := c.Control(func(fd uintptr) {
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEPORT, 1)
		})
		if err != nil {
			return err
		}
		return serr
	}}
	return lc.Listen(context.Background(), network, addr)
}
