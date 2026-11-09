//go:build linux

package gvsub

import (
	"encoding/binary"
	"net/netip"
	"testing"
)

// Сообщение удаления: подсистема ctnetlink, семейство и вложенный кортеж
// с адресами и портами в сетевом порядке.
func TestCtDeleteMsg(t *testing.T) {
	f := Flow{Proto: "tcp", Src: netip.MustParseAddr("2a03::1"), Dst: netip.MustParseAddr("2a00:1450:4001:37::7"), Sport: 53644, Dport: 443}
	b, err := ctDeleteMsg(f, 7)
	if err != nil {
		t.Fatal(err)
	}
	if int(binary.LittleEndian.Uint32(b)) != len(b) || binary.LittleEndian.Uint16(b[4:6]) != 1<<8|2 || b[16] != 10 {
		t.Fatalf("заголовок: %x", b[:20])
	}
	// orig(4) ip(4) v6src(4+16) v6dst(4+16) proto(4) num(8) sport(8) dport(8)
	if len(b) != 20+4+4+20+20+4+8+8+8 {
		t.Fatalf("длина %d", len(b))
	}
	// Последний атрибут — порт назначения: 4 байта заголовка, 2 байта порта, 2 выравнивания.
	if got := binary.BigEndian.Uint16(b[len(b)-4:]); got != 443 {
		t.Fatalf("порт назначения %d", got)
	}
	if _, err := ctDeleteMsg(Flow{Src: netip.MustParseAddr("1.2.3.4"), Dst: f.Dst}, 1); err == nil {
		t.Fatal("смешанные семейства приняты")
	}
}
