//go:build !linux

package health

import "syscall"

// bindToDevice вне Linux — заглушка: движок работает только на роутере,
// здесь это нужно лишь для сборки тестов на маке.
func bindToDevice(string) func(network, address string, c syscall.RawConn) error {
	return nil
}
