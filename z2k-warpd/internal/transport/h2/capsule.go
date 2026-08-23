// Package h2 — MASQUE CONNECT-IP поверх HTTP/2: страховочный транспорт на
// случай полного UDP-блока. IP-пакеты ходят как DATAGRAM-капсулы (RFC 9297)
// в теле CONNECT-стрима.
//
// ОТСТУПЛЕНИЕ ОТ RFC, и оно не наше: Cloudflare кладёт в payload капсулы
// голый IP-пакет, без varint context id, который требует RFC 9484 §4.6.
// Кодек здесь повторяет провод Cloudflare, а не стандарт.
package h2

import (
	"bufio"
	"errors"
	"io"
)

const (
	capsuleDatagram = 0x00
	maxCapsule      = 64 * 1024 // IP-пакет больше 64К невозможен; всё крупнее — мусор
)

// QUIC varint (RFC 9000 §16): 2 старших бита — длина.
func putVarint(b []byte, v uint64) []byte {
	switch {
	case v < 1<<6:
		return append(b, byte(v))
	case v < 1<<14:
		return append(b, byte(v>>8)|0x40, byte(v))
	case v < 1<<30:
		return append(b, byte(v>>24)|0x80, byte(v>>16), byte(v>>8), byte(v))
	default:
		return append(b, byte(v>>56)|0xc0, byte(v>>48), byte(v>>40), byte(v>>32),
			byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
	}
}

// getVarint возвращает значение и число съеденных байт; 0 — не хватило данных.
func getVarint(b []byte) (uint64, int) {
	if len(b) == 0 {
		return 0, 0
	}
	n := 1 << (b[0] >> 6)
	if len(b) < n {
		return 0, 0
	}
	v := uint64(b[0] & 0x3f)
	for i := 1; i < n; i++ {
		v = v<<8 | uint64(b[i])
	}
	return v, n
}

// EncodeDatagram — IP-пакет → DATAGRAM-капсула (payload = пакет, см. шапку).
func EncodeDatagram(pkt []byte) []byte {
	out := make([]byte, 0, len(pkt)+10)
	out = putVarint(out, capsuleDatagram)
	out = putVarint(out, uint64(len(pkt)))
	return append(out, pkt...)
}

// Decoder читает капсулы из потока и отдаёт только IP-пакеты.
type Decoder struct {
	r   *bufio.Reader
	buf []byte
}

// NewDecoder оборачивает тело ответа.
func NewDecoder(r io.Reader) *Decoder {
	return &Decoder{r: bufio.NewReaderSize(r, 32*1024)}
}

func (d *Decoder) readVarint() (uint64, error) {
	hdr, err := d.r.Peek(1)
	if err != nil {
		return 0, err
	}
	n := 1 << (hdr[0] >> 6)
	raw, err := d.r.Peek(n)
	if err != nil {
		return 0, err
	}
	v, used := getVarint(raw)
	if used != n {
		return 0, errors.New("varint decode")
	}
	if _, err := d.r.Discard(n); err != nil {
		return 0, err
	}
	return v, nil
}

// Next возвращает следующий IP-пакет; капсулы других типов пропускает.
// Буфер переиспользуется — копировать, если нужно хранить.
func (d *Decoder) Next() ([]byte, error) {
	for {
		typ, err := d.readVarint()
		if err != nil {
			return nil, err
		}
		length, err := d.readVarint()
		if err != nil {
			return nil, err
		}
		if length > maxCapsule {
			return nil, errors.New("capsule too large")
		}
		if cap(d.buf) < int(length) {
			d.buf = make([]byte, length)
		}
		body := d.buf[:length]
		if _, err := io.ReadFull(d.r, body); err != nil {
			return nil, err
		}
		if typ != capsuleDatagram || length == 0 {
			continue
		}
		return body, nil
	}
}
