//go:build !linux

package quicprobe

import (
	"context"
	"errors"
	"net"
	"time"
)

// Вне Linux фрагментировать нечем: сырых сокетов с собственным заголовком IP
// там нет. Возвращаем ошибку, а не тишину, — тогда вопрос будет помечен как
// НЕИЗМЕРЕННЫЙ, а не как «приём не помог».
func exchangeFragmented(_ context.Context, _ *net.UDPAddr, _ probeSpec,
	_ time.Duration) exchangeResult {
	return exchangeResult{err: errors.New("quicprobe: фрагментация доступна только на Linux")}
}
