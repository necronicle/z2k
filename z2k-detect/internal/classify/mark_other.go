//go:build !linux

package classify

import "syscall"

// На не-Linux метки нет и обход не наш — ставить нечего.
func markControl(network, address string, c syscall.RawConn) error { return nil }
