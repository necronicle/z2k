//go:build linux

package voiceprobe

import (
	"errors"
	"syscall"

	"golang.org/x/sys/unix"
)

// Z2KBypassMark — метка, по которой наши правила пропускают пакет мимо
// собственного десинка.
//
// ДЛЯ ГОЛОСОВОГО ЗОНДА ОНА КРИТИЧНЕЕ, ЧЕМ ГДЕ-ЛИБО ЕЩЁ. Профиль discord_udp
// ловит ровно те порты, по которым зонд и ходит (3478-3481, 5349, 19294-19344,
// 50000-50100), и ровно тот протокол (--filter-l7=stun). Без метки зонд меряет
// не коробку провайдера, а наш собственный обход поверх неё.
//
// Замер 04.09 на ppp0: запрос STUN на 20 байт уходил в провод датаграммой на
// 1200 — nfqws2 подставлял фальшивку active_discord_udp. Ответа не было, и без
// дампа это выглядело бы как «STUN режут у провайдера».
const Z2KBypassMark = 0x40000000

func markControl(network, address string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, Z2KBypassMark)
	})
	if err != nil {
		return err
	}
	// Прав может не быть (мак, раннер CI) — там и правил наших нет, так что
	// идём без метки. На роутере мы root, и молчаливого отказа не будет.
	if errors.Is(serr, unix.EPERM) || errors.Is(serr, unix.ENOPROTOOPT) {
		return nil
	}
	return serr
}

// markSupported — можно ли пометить сокет на этой системе.
func markSupported() bool { return true }
