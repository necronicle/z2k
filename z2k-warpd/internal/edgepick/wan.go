package edgepick

import (
	"fmt"
	"net"
	"sort"
)

func identityForIP(source string, ifaces map[string][]string) string {
	names := make([]string, 0, len(ifaces))
	for name := range ifaces {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		for _, addr := range ifaces[name] {
			if addr == source {
				return name + "|" + source
			}
		}
	}
	return ""
}

// WANFor identifies the source interface chosen by the kernel for a WARP IP.
// UDP Dial does not transmit a packet; the live WG proof remains authoritative.
func WANFor(host string) (string, error) {
	remote := net.ParseIP(host)
	if remote == nil || remote.To4() == nil {
		return "", fmt.Errorf("bad WARP IPv4 host %q", host)
	}
	conn, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: remote, Port: 2408})
	if err != nil {
		return "", err
	}
	source := conn.LocalAddr().(*net.UDPAddr).IP.String()
	_ = conn.Close()
	interfaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	addrs := make(map[string][]string, len(interfaces))
	for _, iface := range interfaces {
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err == nil {
				addrs[iface.Name] = append(addrs[iface.Name], ip.String())
			}
		}
	}
	identity := identityForIP(source, addrs)
	if identity == "" {
		return "", fmt.Errorf("source %s has no WAN interface", source)
	}
	return identity, nil
}
