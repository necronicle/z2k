package main

import (
	"encoding/binary"
	"net"
	"syscall"
	"testing"
)

// sockaddrIn builds a sockaddr_in exactly as a kernel of the given endianness
// hands it back from SO_ORIGINAL_DST: sa_family in HOST order, sin_port in
// network order.
func sockaddrIn(order binary.ByteOrder, ip net.IP, port int) []byte {
	raw := make([]byte, 16)
	order.PutUint16(raw[0:2], syscall.AF_INET)
	binary.BigEndian.PutUint16(raw[2:4], uint16(port))
	copy(raw[4:8], ip.To4())
	return raw
}

// The shipped bug: sa_family_t was read as little-endian regardless of build
// target, so on big-endian MIPS AF_INET (2) arrived as 512, the IPv4 answer was
// thrown away and the caller fell through to the IPv6 path. Both orders must
// decode under their own kernel, and the mismatched pairing must be rejected —
// that rejection is the exact failure that reached users on mips-3.4_kn.
func TestDecodeIPv4DstHonoursHostByteOrder(t *testing.T) {
	want := net.IPv4(149, 154, 167, 50)
	for _, tc := range []struct {
		name  string
		order binary.ByteOrder
	}{
		{"big-endian host (mips)", binary.BigEndian},
		{"little-endian host (mipsel, aarch64, amd64)", binary.LittleEndian},
	} {
		raw := sockaddrIn(tc.order, want, 443)

		ip, port, ok := decodeIPv4Dst(tc.order, raw)
		if !ok {
			t.Fatalf("%s: AF_INET not recognised under its own kernel byte order", tc.name)
		}
		if !ip.Equal(want) || port != 443 {
			t.Fatalf("%s: got %s:%d, want %s:443", tc.name, ip, port, want)
		}

		other := binary.ByteOrder(binary.LittleEndian)
		if tc.order == binary.ByteOrder(binary.LittleEndian) {
			other = binary.BigEndian
		}
		if _, _, ok := decodeIPv4Dst(other, raw); ok {
			t.Fatalf("%s: decoded under the wrong byte order — the family check is not doing its job", tc.name)
		}
	}
}

// Guards the fix itself: production must read sa_family_t in the byte order of
// the machine the binary runs on, never a hardcoded one.
func TestSockaddrOrderIsNative(t *testing.T) {
	if sockaddrOrder != binary.ByteOrder(binary.NativeEndian) {
		t.Fatalf("sockaddrOrder = %T, want binary.NativeEndian — hardcoding an order breaks the other endianness silently", sockaddrOrder)
	}
}

func TestDecodeIPv4DstRejectsShortAndForeignBuffers(t *testing.T) {
	if _, _, ok := decodeIPv4Dst(binary.NativeEndian, []byte{0, 2}); ok {
		t.Fatal("short buffer accepted")
	}
	raw := make([]byte, 16)
	binary.NativeEndian.PutUint16(raw[0:2], syscall.AF_INET6)
	if _, _, ok := decodeIPv4Dst(binary.NativeEndian, raw); ok {
		t.Fatal("AF_INET6 accepted as AF_INET")
	}
}
