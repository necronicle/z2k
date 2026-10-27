//go:build !linux

package tcp16

import "syscall"

// На не-Linux метки SO_MARK нет — возвращаем nil.
func markControl(network, address string, c syscall.RawConn) error { return nil }
