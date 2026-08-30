//go:build !linux

package sniwl

import (
	"syscall"

	"github.com/necronicle/z2k/z2k-detect/internal/classify"
)

// BypassMark — константа общая, чтобы значение не разъехалось между сборками.
const BypassMark = classify.Z2KBypassMark

// На не-Linux обход не наш и ставить метку некуда. Разработческая сборка на
// маке при этом честно работает — она просто меряет линию как есть.
func markControl(network, address string, c syscall.RawConn) error { return nil }
