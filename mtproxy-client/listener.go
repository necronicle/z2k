package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"syscall"
	"unsafe"
)

const (
	soOriginalDst  = 80 // SO_ORIGINAL_DST for IPv4 (SOL_IP = IPPROTO_IP)
	soOriginalDst6 = 80 // IP6T_SO_ORIGINAL_DST for IPv6
	solIPv6        = 41 // SOL_IPV6
)

// rawSockaddrIn6 matches the C struct sockaddr_in6 layout:
//
//	struct sockaddr_in6 {
//	    uint16_t sin6_family;   // [0:2]
//	    uint16_t sin6_port;     // [2:4]  big-endian
//	    uint32_t sin6_flowinfo; // [4:8]
//	    uint8_t  sin6_addr[16]; // [8:24]
//	    uint32_t sin6_scope_id; // [24:28]
//	};
type rawSockaddrIn6 struct {
	Family   uint16
	Port     uint16 // big-endian
	Flowinfo uint32
	Addr     [16]byte
	ScopeID  uint32
}

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
		// GetsockoptIPv6Mreq gives us 20 bytes — enough for sockaddr_in (16 bytes)
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

		// Try IPv6: use raw getsockopt to get the full 28-byte sockaddr_in6
		var sa6 rawSockaddrIn6
		sa6Len := uint32(unsafe.Sizeof(sa6))
		_, _, errno := syscall.Syscall6(
			syscall.SYS_GETSOCKOPT,
			fd,
			uintptr(solIPv6),
			uintptr(soOriginalDst6),
			uintptr(unsafe.Pointer(&sa6)),
			uintptr(unsafe.Pointer(&sa6Len)),
			0,
		)
		if errno != 0 {
			if err != nil {
				syscallErr = fmt.Errorf("getsockopt SO_ORIGINAL_DST v4: %w, v6: %v", err, errno)
			} else {
				syscallErr = fmt.Errorf("getsockopt IP6T_SO_ORIGINAL_DST: %v", errno)
			}
			return
		}

		// Parse the full sockaddr_in6.
		// Port is stored in network byte order (big-endian) by the kernel,
		// but Go reads raw struct bytes as host-endian uint16.
		// Convert from network to host byte order:
		portBytes := (*[2]byte)(unsafe.Pointer(&sa6.Port))
		origPort = int(binary.BigEndian.Uint16(portBytes[:]))
		origIP = net.IP(sa6.Addr[:])
	})

	if err != nil {
		return nil, 0, err
	}
	if syscallErr != nil {
		return nil, 0, syscallErr
	}

	return origIP, origPort, nil
}
