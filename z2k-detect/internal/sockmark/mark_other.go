//go:build !linux

package sockmark

import "syscall"

// Вне Linux метки нет и обход не наш — ставить нечего.
func Control(network, address string, c syscall.RawConn) error { return nil }

// ControlWithMark вне Linux возвращает nil.
func ControlWithMark(mark uint32) func(network, address string, c syscall.RawConn) error {
	return nil
}

// DetectPolicyMark вне Linux возвращает 0.
func DetectPolicyMark() uint32 { return 0 }

// Supported — вне Linux false: замер с такой машины пройдёт через наш же
// обход и будет недостоверен; вызывающий обязан сказать об этом, а не молча
// выдать результат.
func Supported() bool { return false }
