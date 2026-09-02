//go:build !linux

package main

import (
	"context"
	"net"
	"syscall"
)

// На macOS (машина сборки и тестов) SO_REUSEPORT тоже есть; поведение
// балансировки другое, но для тестов достаточно, что второй Listen не падает.
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
