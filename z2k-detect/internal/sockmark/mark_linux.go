//go:build linux

package sockmark

import (
	"context"
	"errors"
	"os/exec"
	"syscall"
	"time"

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
	return setMark(c, Bypass)
}

// ControlWithMark возвращает функцию Control, выставляющую заданную метку SO_MARK.
// При mark == 0 возвращает nil (сокет остаётся без метки).
func ControlWithMark(mark uint32) func(network, address string, c syscall.RawConn) error {
	if mark == 0 {
		return nil
	}
	return func(network, address string, c syscall.RawConn) error {
		return setMark(c, mark)
	}
}

func setMark(c syscall.RawConn, mark uint32) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, int(int32(mark)))
	})
	if err != nil {
		return err
	}
	if errors.Is(serr, unix.EPERM) || errors.Is(serr, unix.ENOPROTOOPT) {
		return nil
	}
	return serr
}

// DetectPolicyMark считывает активную метку политики включения (POLICY_EXCLUDE=0)
// из таблицы mangle (Z2K_POL / POSTROUTING) с запасным опросом ip6tables.
// Если политика не активна или используется режим исключения, возвращает 0.
func DetectPolicyMark() uint32 {
	for _, bin := range []string{"iptables", "ip6tables"} {
		post := runIptablesList(bin, "POSTROUTING")
		pol := runIptablesList(bin, "Z2K_POL")
		if m, ok := ParsePolicyMark(post, pol); ok {
			return m
		}
	}
	return 0
}

func runIptablesList(bin, chain string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "-w", "-t", "mangle", "-S", chain).Output()
	if err == nil {
		return string(out)
	}
	out, err = exec.CommandContext(ctx, bin, "-t", "mangle", "-S", chain).Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// Supported — можно ли вообще пометить сокет на этой системе.
func Supported() bool { return true }
