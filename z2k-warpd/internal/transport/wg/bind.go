// Package wg — WireGuard-транспорт WARP.
//
// Cloudflare маршрутизирует consumer-WARP по трём «reserved»-байтам заголовка
// WireGuard (байты 1..3), в которые клиент кладёт client_id из регистрации.
// Без них handshake проходит, ICMP/UDP ходят, а TCP — нет (измерено на
// роутере 2026-08-23). Стандартный WireGuard эти байты не трогает, поэтому
// патчим их на уровне conn.Bind: на отправке — ставим, на приёме — обнуляем,
// чтобы device не счёл пакет повреждённым.
package wg

import "golang.zx2c4.com/wireguard/conn"

type reservedBind struct {
	conn.Bind
	r [3]byte
}

// NewReservedBind оборачивает inner так, что каждый исходящий WG-пакет несёт
// reserved, а у каждого входящего reserved-байты обнуляются.
func NewReservedBind(inner conn.Bind, reserved [3]byte) conn.Bind {
	return &reservedBind{Bind: inner, r: reserved}
}

func (b *reservedBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	for _, p := range bufs {
		if len(p) >= 4 {
			copy(p[1:4], b.r[:])
		}
	}
	return b.Bind.Send(bufs, ep)
}

func (b *reservedBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	fns, actual, err := b.Bind.Open(port)
	if err != nil {
		return nil, 0, err
	}
	out := make([]conn.ReceiveFunc, len(fns))
	for i, f := range fns {
		f := f
		out[i] = func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
			n, err := f(packets, sizes, eps)
			for j := 0; j < n; j++ {
				if sizes[j] >= 4 {
					packets[j][1], packets[j][2], packets[j][3] = 0, 0, 0
				}
			}
			return n, err
		}
	}
	return out, actual, nil
}
