// Package transport — что движку нужно от транспорта, и только это.
//
// Транспорт получает TUN на конструкторе и сам гоняет пакеты в обе стороны;
// движок лишь открывает, спрашивает здоровье и закрывает. Так лестница
// меняет транспорт, не зная ничего о WireGuard или HTTP/2.
package transport

import (
	"context"
	"errors"
	"time"
)

// ErrNoHandshake — сессия не установилась за отведённое время.
var ErrNoHandshake = errors.New("no handshake")

// Health — мгновенный снимок состояния сессии.
type Health struct {
	Connected     bool
	LastHandshake time.Time // zero = не было
	Rx, Tx        uint64
	Err           error
}

// HandshakeAge — возраст последнего handshake в секундах; -1, если не было.
func (h Health) HandshakeAge(now time.Time) int {
	if h.LastHandshake.IsZero() {
		return -1
	}
	return int(now.Sub(h.LastHandshake) / time.Second)
}

// Transport — одна сессия к Cloudflare поверх конкретного протокола.
type Transport interface {
	// Open устанавливает сессию и не возвращается, пока она не доказана
	// (handshake / 200 на CONNECT) или не истёк ctx.
	Open(ctx context.Context) error
	Health() Health
	Close() error
}
