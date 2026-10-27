//go:build linux

package sockmark

import (
	"errors"
	"syscall"

	"golang.org/x/sys/unix"
)

// Control ставит метку на сокет до подключения (поле Control у net.Dialer и
// net.ListenConfig).
//
// Метка — ОПТИМИЗАЦИЯ, а не условие работы. Прав на неё требуется
// CAP_NET_ADMIN, и на роутере они есть — там мы root. Там, где прав нет (мак,
// раннер CI), setsockopt возвращает EPERM, и раньше эта ошибка выносилась
// наружу, роняя само подключение: тесты падали на раннере GitHub с «dial tcp
// 127.0.0.1: operation not permitted», хотя для localhost никаких прав не
// нужно. Не смогли пометить — идём без метки: измерение остаётся верным
// везде, где наши правила не стоят.
func Control(network, address string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, Bypass)
	})
	if err != nil {
		return err
	}
	if errors.Is(serr, unix.EPERM) || errors.Is(serr, unix.ENOPROTOOPT) {
		return nil
	}
	return serr
}

// Supported — можно ли вообще пометить сокет на этой системе.
func Supported() bool { return true }
