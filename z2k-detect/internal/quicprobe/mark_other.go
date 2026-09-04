//go:build !linux

package quicprobe

import "syscall"

// Z2KBypassMark объявлен и здесь, чтобы код замера собирался на маке: сама
// метка вне Linux смысла не имеет.
const Z2KBypassMark = 0x40000000

func markControl(network, address string, c syscall.RawConn) error { return nil }
