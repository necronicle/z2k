//go:build !linux

package gvsub

import "errors"

// Queue вне Linux не существует: служба работает только на роутере.
type Queue struct{}

// Packet — пакет из очереди.
type Packet struct {
	ID      uint32
	Payload []byte
}

func OpenQueue(num uint16) (*Queue, error) {
	return nil, errors.New("NFQUEUE есть только в Linux")
}
func (q *Queue) Read(buf []byte) ([]Packet, error) { return nil, errors.New("нет очереди") }
func (q *Queue) Accept(id uint32) error            { return nil }
func (q *Queue) Close() error                      { return nil }

// DeleteFlow вне Linux не нужен.
func DeleteFlow(f Flow) error { return errors.New("conntrack есть только в Linux") }
