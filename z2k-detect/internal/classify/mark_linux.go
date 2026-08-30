//go:build linux

package classify

import (
	"errors"
	"syscall"

	"golang.org/x/sys/unix"
)

// markControl ставит SO_MARK на обычный сокет до подключения.
//
// Метка — ОПТИМИЗАЦИЯ, а не условие работы: по ней наши же правила пропускают
// зонд мимо очереди, чтобы обход не искажал измерение. Прав на неё требуется
// CAP_NET_ADMIN, и на роутере они есть — там мы root.
//
// А там, где прав нет, setsockopt возвращает EPERM, и раньше эта ошибка
// выносилась наружу, роняя само подключение: тесты классификатора падали на
// раннере GitHub с «dial tcp 127.0.0.1: operation not permitted», хотя
// подключаться к своему же localhost никаких прав не нужно. На маке файл вовсе
// не компилируется, поэтому локальный прогон был зелёным, а CI красным.
//
// Не смогли пометить — идём без метки: измерение остаётся верным везде, где
// наши правила не стоят, а на роутере метка ставится как раньше.
func markControl(network, address string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, Z2KBypassMark)
	})
	if err != nil {
		return err
	}
	if errors.Is(serr, unix.EPERM) || errors.Is(serr, unix.ENOPROTOOPT) {
		return nil
	}
	return serr
}
