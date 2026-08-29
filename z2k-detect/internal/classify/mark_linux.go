//go:build linux

package classify

import (
	"syscall"

	"golang.org/x/sys/unix"
)

// markControl ставит SO_MARK на обычный сокет до подключения.
func markControl(network, address string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, Z2KBypassMark)
	})
	if err != nil {
		return err
	}
	return serr
}
