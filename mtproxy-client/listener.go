package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"syscall"
)

const (
	soOriginalDst  = 80 // SO_ORIGINAL_DST for IPv4 (SOL_IP = IPPROTO_IP)
	soOriginalDst6 = 80 // IP6T_SO_ORIGINAL_DST for IPv6
	solIPv6        = 41  // SOL_IPV6
)

// getOriginalDst retrieves the original destination address from a redirected connection.
// Works with iptables/ip6tables REDIRECT target. Supports both IPv4 and IPv6.
func getOriginalDst(conn *net.TCPConn) (net.IP, int, error) {
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return nil, 0, fmt.Errorf("SyscallConn: %w", err)
	}

	var origIP net.IP
	var origPort int
	var syscallErr error

	err = rawConn.Control(func(fd uintptr) {
		// Try IPv4 first: getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, &addr, &len)
		addr, err := syscall.GetsockoptIPv6Mreq(int(fd), syscall.IPPROTO_IP, soOriginalDst)
		if err == nil {
			// addr.Multiaddr contains sockaddr_in as raw bytes:
			// [0:2] = family (AF_INET=2)
			// [2:4] = port (big-endian)
			// [4:8] = IPv4 address
			raw := addr.Multiaddr
			family := binary.LittleEndian.Uint16(raw[0:2])
			if family == syscall.AF_INET {
				origPort = int(binary.BigEndian.Uint16(raw[2:4]))
				origIP = net.IPv4(raw[4], raw[5], raw[6], raw[7])
				return
			}
		}

		// Try IPv6: getsockopt(fd, SOL_IPV6, IP6T_SO_ORIGINAL_DST, &addr, &len)
		addr6, err6 := syscall.GetsockoptIPv6Mreq(int(fd), solIPv6, soOriginalDst6)
		if err6 != nil {
			// Both failed — report the IPv6 error (IPv4 either failed or had wrong family)
			if err != nil {
				syscallErr = fmt.Errorf("getsockopt SO_ORIGINAL_DST v4: %w, v6: %w", err, err6)
			} else {
				syscallErr = fmt.Errorf("getsockopt IP6T_SO_ORIGINAL_DST: %w", err6)
			}
			return
		}

		// addr6.Multiaddr contains sockaddr_in6 as raw bytes:
		// [0:2]  = family (AF_INET6=10)
		// [2:4]  = port (big-endian)
		// [4:8]  = flow info
		// [8:24] = 16-byte IPv6 address (but Multiaddr is only 16 bytes,
		//          so we use both Multiaddr and Interface for the full struct)
		// With GetsockoptIPv6Mreq, the sockaddr_in6 is split:
		//   Multiaddr [0:16] = bytes 0-15 of sockaddr_in6
		//   Interface [0:4]  = bytes 16-19 of sockaddr_in6 (last 4 of IPv6 addr)
		// So port is at Multiaddr[2:4], IPv6 address is at Multiaddr[4:16] + Interface bytes
		raw6 := addr6.Multiaddr
		origPort = int(binary.BigEndian.Uint16(raw6[2:4]))

		// Reconstruct the 16-byte IPv6 address: bytes [4:16] from Multiaddr (12 bytes)
		// plus 4 bytes from the Interface field
		var ipv6Addr [16]byte
		copy(ipv6Addr[0:12], raw6[4:16])
		ifBytes := make([]byte, 4)
		binary.BigEndian.PutUint32(ifBytes, addr6.Interface)
		copy(ipv6Addr[12:16], ifBytes)
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
