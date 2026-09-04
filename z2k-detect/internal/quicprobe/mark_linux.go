//go:build linux

package quicprobe

import (
	"errors"
	"syscall"

	"golang.org/x/sys/unix"
)

// Z2KBypassMark — метка, по которой наши правила NFQUEUE пропускают пакет мимо
// собственного десинка. Зонд обязан ходить помеченным: иначе он меряет не
// коробку провайдера, а наш обход поверх неё.
//
// Для UDP у этой метки есть ВТОРАЯ роль, которой нет у TCP: правило
// z2k_udp_masquerade_fix в таблице nat заворачивает помеченные UDP-пакеты в
// MASQUERADE (S99zapret2.new:2194). Это не мешает замеру — исходный порт
// сохраняется, — но означает, что помеченная датаграмма проходит другой путь,
// чем непомеченная, и сравнивать их между собой нельзя.
const Z2KBypassMark = 0x40000000

// markControl ставит SO_MARK на сокет до привязки.
//
// Права на неё требуют CAP_NET_ADMIN; на роутере мы root, а на маке и на
// раннере CI прав нет. Отсутствие прав — не повод ронять замер: без наших
// правил метка всё равно ни на что не влияет, поэтому EPERM глотаем.
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
