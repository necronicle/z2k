//go:build !linux

package sockmark

import "syscall"

// Вне Linux метки нет и обход не наш — ставить нечего.
func Control(network, address string, c syscall.RawConn) error { return nil }

// Supported — вне Linux false: замер с такой машины пройдёт через наш же
// обход и будет недостоверен; вызывающий обязан сказать об этом, а не молча
// выдать результат.
func Supported() bool { return false }
