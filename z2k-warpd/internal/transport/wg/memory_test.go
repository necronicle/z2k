package wg

import (
	"testing"

	"golang.zx2c4.com/wireguard/device"
)

// Буфер под пакет обязан быть маленьким: 64 КБ на пакет при MTU 1280 давали
// 70–90 МБ RSS после одного скачанного файла и OOM-kill на роутере с 512 МБ.
// Константа живёт в копии third_party/wireguard; уйдёт replace из go.mod —
// упадёт этот тест, а не роутер.
func TestSegmentBufferIsSmall(t *testing.T) {
	if device.MaxSegmentSize > 2048 {
		t.Fatalf("device.MaxSegmentSize = %d: буфер на пакет снова 64 КБ, см. third_party/wireguard/Z2K-PATCHES.md", device.MaxSegmentSize)
	}
}
