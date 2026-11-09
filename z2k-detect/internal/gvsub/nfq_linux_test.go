//go:build linux

package gvsub

import (
	"encoding/binary"
	"testing"
)

// Сообщение о пакете нечётной длины в конце пачки — ровно так ядро присылает
// ответ DNS длиной не кратной 4. syscall.ParseNetlinkMessage на нём падает с
// EINVAL (роутер, 09.11.2026); свой разбор обязан его взять.
func TestSplitPacketsUnpaddedTail(t *testing.T) {
	payload := []byte{1, 2, 3, 4, 5, 6, 7} // 7 байт — не кратно 4
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, 42)
	attrs := append(attr(nfqaPacketHdr, append(hdr, 0, 0x08, 0, 3)), attr(nfqaPayload, payload)...)
	attrs = attrs[:len(attrs)-1] // хвост без дополнения
	msg := make([]byte, 16+4+len(attrs))
	binary.LittleEndian.PutUint32(msg[0:4], uint32(len(msg)))
	binary.LittleEndian.PutUint16(msg[4:6], nfnlSubsysQueue<<8|nfqnlMsgPacket)
	copy(msg[20:], attrs)
	got := splitPackets(msg)
	if len(got) != 1 || got[0].ID != 42 || string(got[0].Payload) != string(payload) {
		t.Fatalf("разобрано %+v", got)
	}
}
