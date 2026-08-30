//go:build linux

package sniwl

import (
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/necronicle/z2k/z2k-detect/internal/classify"
)

// BypassMark — та же метка, что у остального дерева. Константа берётся из
// classify, чтобы источник правды был один.
const BypassMark = classify.Z2KBypassMark

// markControl ставит SO_MARK на сокет до подключения.
//
// БЕЗ ЭТОГО ПРОБА БЕССМЫСЛЕННА: она измерила бы наш собственный десинк, а не
// коробку провайдера. Дверь уже стоит в правилах NFQUEUE как
// `-m mark ! --mark 0x40000000`, поэтому в системе трогать нечего.
//
// Путь исключения выбран ОДИН и намеренно: голый SO_MARK против двери NFQUEUE,
// как в classify. Второй путь — connmark-правило из prober/raw_linux.go
// (`-t mangle -I OUTPUT ... CONNMARK --set-mark 0x20000000`) — здесь НЕ
// используется: метка у обоих одна, а смешивать два механизма исключения
// значит получить поведение, которое зависит от того, кто из них успел
// поставить своё правило первым.
//
// ОБЛАСТЬ ДЕЙСТВИЯ. Метка нужна ПРОБЕ — она меряет коробку. Проверять этой же
// пробой, что готовый профиль работает, НЕЛЬЗЯ: там надо мерить ровно то, что
// получит пользователь, то есть идти через nfqws2, без метки.
func markControl(network, address string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, BypassMark)
	})
	if err != nil {
		return err
	}
	return serr
}
