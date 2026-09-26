// Package wg — WireGuard-транспорт WARP.
//
// Cloudflare маршрутизирует consumer-WARP по трём «reserved»-байтам заголовка
// WireGuard (байты 1..3), в которые клиент кладёт client_id из регистрации.
// Без них handshake проходит, ICMP/UDP ходят, а TCP — нет (измерено на
// роутере 2026-08-23). Стандартный WireGuard эти байты не трогает, поэтому
// патчим их на уровне conn.Bind: на отправке — ставим, на приёме — обнуляем,
// чтобы device не счёл пакет повреждённым.
package wg

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math/big"

	"golang.zx2c4.com/wireguard/conn"
)

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
	out := make([][]byte, 0, len(bufs)+7)
	for _, p := range bufs {
		if len(p) == 148 && p[0] == 1 {
			preamble, err := awgPreamble()
			if err != nil {
				return fmt.Errorf("awg preamble: %w", err)
			}
			out = append(out, preamble...)
		}
		if len(p) >= 4 {
			copy(p[1:4], b.r[:])
		}
		out = append(out, p)
	}
	return b.Bind.Send(out, ep)
}

// AWG-compatible initial disguise: a short DNS-looking first datagram and
// six small random junk datagrams before each ordinary WG initiation. The
// actual handshake and transport packets retain Cloudflare's reserved bytes.
// This matches the default pre-handshake shape used by Warpscout's AWG mode;
// the WARP server ignores these extra datagrams.
func awgPreamble() ([][]byte, error) {
	const dnsHex = "858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737"
	dns, err := hex.DecodeString(dnsHex)
	if err != nil {
		return nil, err
	}
	first := make([]byte, 2+len(dns))
	if _, err := rand.Read(first[:2]); err != nil {
		return nil, err
	}
	copy(first[2:], dns)
	out := [][]byte{first}
	for range 6 {
		n, err := rand.Int(rand.Reader, big.NewInt(41))
		if err != nil {
			return nil, err
		}
		packet := make([]byte, 10+int(n.Int64()))
		if _, err := rand.Read(packet); err != nil {
			return nil, err
		}
		out = append(out, packet)
	}
	return out, nil
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
