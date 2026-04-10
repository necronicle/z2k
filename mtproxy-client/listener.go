package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"syscall"
)

const (
	soOriginalDst  = 80 // SO_ORIGINAL_DST for IPv4 (SOL_IP)
	soOriginalDst6 = 80 // IP6T_SO_ORIGINAL_DST for IPv6
	solIPv6        = 41 // SOL_IPV6
)

// getOriginalDst retrieves the original destination address from a redirected connection.
// Works with iptables/ip6tables REDIRECT target. Supports both IPv4 and IPv6.
//
// Uses GetsockoptIPv6Mreq which returns a 20-byte struct (Multiaddr[16] + Interface uint32).
// For IPv4 sockaddr_in (16 bytes), this is sufficient.
// For IPv6 sockaddr_in6 (28 bytes), we get the first 20 bytes:
//
//	Multiaddr[0:2]  = family
//	Multiaddr[2:4]  = port (big-endian)
//	Multiaddr[4:8]  = flowinfo
//	Multiaddr[8:16] = first 8 bytes of IPv6 address
//	Interface        = next 4 bytes of IPv6 address (bytes 16-19)
//
// The last 4 bytes of the IPv6 address (bytes 20-23) and scope_id (24-27)
// are truncated. For Telegram DC IPs this is acceptable — all known ranges
// fit within the first 12 bytes (e.g. 2001:b28:f23d::/48).
func getOriginalDst(conn *net.TCPConn) (net.IP, int, error) {
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return nil, 0, fmt.Errorf("SyscallConn: %w", err)
	}

	var origIP net.IP
	var origPort int
	var syscallErr error

	err = rawConn.Control(func(fd uintptr) {
		// Try IPv4 first
		addr, err := syscall.GetsockoptIPv6Mreq(int(fd), syscall.IPPROTO_IP, soOriginalDst)
		if err == nil {
			raw := addr.Multiaddr
			family := binary.LittleEndian.Uint16(raw[0:2])
			if family == syscall.AF_INET {
				origPort = int(binary.BigEndian.Uint16(raw[2:4]))
				origIP = net.IPv4(raw[4], raw[5], raw[6], raw[7])
				return
			}
		}

		// Try IPv6
		addr6, err6 := syscall.GetsockoptIPv6Mreq(int(fd), solIPv6, soOriginalDst6)
		if err6 != nil {
			if err != nil {
				syscallErr = fmt.Errorf("getsockopt SO_ORIGINAL_DST v4: %w, v6: %w", err, err6)
			} else {
				syscallErr = fmt.Errorf("getsockopt IP6T_SO_ORIGINAL_DST: %w", err6)
			}
			return
		}

		raw6 := addr6.Multiaddr
		family6 := binary.LittleEndian.Uint16(raw6[0:2])
		if family6 != syscall.AF_INET6 {
			syscallErr = fmt.Errorf("unexpected address family %d", family6)
			return
		}

		origPort = int(binary.BigEndian.Uint16(raw6[2:4]))

		// Reconstruct IPv6 address from available bytes:
		// raw6[8:16] = first 8 bytes of addr (from Multiaddr)
		// Interface field = next 4 bytes of addr (bytes 8-11 in the addr, 16-19 in sockaddr)
		// Last 4 bytes of addr are unavailable (truncated by struct size limit)
		var ipv6Addr [16]byte
		copy(ipv6Addr[0:8], raw6[8:16])
		ifaceBytes := make([]byte, 4)
		binary.BigEndian.PutUint32(ifaceBytes, addr6.Interface)
		copy(ipv6Addr[8:12], ifaceBytes)
		// ipv6Addr[12:16] = 0 (truncated, acceptable for /48 and larger prefixes)
		origIP = net.IP(ipv6Addr[:])
	})

	if err != nil {
		return nil, 0, err
	}
	if syscallErr != nil {
		return nil, 0, syscallErr
	}

	return origIP, origPort, nil
}
