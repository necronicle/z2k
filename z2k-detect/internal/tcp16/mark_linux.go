//go:build linux

package tcp16

import (
	"errors"
	"syscall"

	"golang.org/x/sys/unix"
)

// bypassMark совпадает с classify.Z2KBypassMark (0x40000000): пакеты с этой
// меткой пропускаются правилами NFQUEUE, чтобы активная стратегия обхода не
// модифицировала контрольный замер TCP-16 и не скрывала блок ТСПУ на 16 КБ.
const bypassMark = 0x40000000

func markControl(network, address string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, bypassMark)
	})
	if err != nil {
		return err
	}
	if errors.Is(serr, unix.EPERM) || errors.Is(serr, unix.ENOPROTOOPT) {
		return nil
	}
	return serr
}
