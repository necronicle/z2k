package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"syscall"
)

const soOriginalDst = 80 // SO_ORIGINAL_DST for IPv4

// getOriginalDst retrieves the original destination address from a redirected connection.
// Works with iptables REDIRECT target.
func getOriginalDst(conn *net.TCPConn) (net.IP, int, error) {
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return nil, 0, fmt.Errorf("SyscallConn: %w", err)
	}

	var origIP net.IP
	var origPort int
	var syscallErr error

	err = rawConn.Control(func(fd uintptr) {
		// IPv4: getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, &addr, &len)
		addr, err := syscall.GetsockoptIPv6Mreq(int(fd), syscall.IPPROTO_IP, soOriginalDst)
		if err != nil {
			syscallErr = fmt.Errorf("getsockopt SO_ORIGINAL_DST: %w", err)
			return
		}

		// addr.Multiaddr contains sockaddr_in as raw bytes:
		// [0:2] = family (AF_INET)
		// [2:4] = port (big-endian)
		// [4:8] = IPv4 address
		raw := addr.Multiaddr
		origPort = int(binary.BigEndian.Uint16(raw[2:4]))
		origIP = net.IPv4(raw[4], raw[5], raw[6], raw[7])
	})

	if err != nil {
		return nil, 0, err
	}
	if syscallErr != nil {
		return nil, 0, syscallErr
	}

	return origIP, origPort, nil
}
