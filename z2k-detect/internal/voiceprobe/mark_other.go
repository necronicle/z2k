//go:build !linux

package voiceprobe

import "syscall"

const Z2KBypassMark = 0x40000000

func markControl(network, address string, c syscall.RawConn) error { return nil }

// Вне Linux метки нет. Для голосового зонда это значит, что замер с такой
// машины пройдёт через наш же обход и будет недостоверен — вызывающий обязан
// сказать об этом, а не молча выдать результат.
func markSupported() bool { return false }
