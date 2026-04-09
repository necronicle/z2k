package main

import "net"

// dcEntry maps a CIDR to a Telegram DC number.
type dcEntry struct {
	cidr *net.IPNet
	dc   int16
}

var dcTable []dcEntry

func init() {
	// Telegram DC IP ranges -> DC number.
	// Negative DC = media DC (abs value is the DC).
	entries := []struct {
		cidr string
		dc   int16
	}{
		// DC1
		{"149.154.175.0/24", 1},
		// DC2
		{"149.154.167.0/24", 2},
		{"95.161.76.0/24", 2},
		// DC3
		{"149.154.175.100/32", 3},
		// DC4
		{"149.154.167.91/32", 4},
		// DC5
		{"149.154.171.0/24", 5},
		{"91.108.56.0/22", 5},
		// General Telegram ranges (default to DC2)
		{"91.108.4.0/22", 2},
		{"91.108.8.0/22", 2},
		{"91.108.12.0/22", 2},
		{"91.108.16.0/22", 2},
		{"91.108.20.0/22", 2},
		{"149.154.160.0/20", 2},
		{"185.76.151.0/24", 2},
		{"91.105.192.0/23", 2},
		{"95.161.64.0/20", 2},
	}

	for _, e := range entries {
		_, cidr, err := net.ParseCIDR(e.cidr)
		if err != nil {
			continue
		}
		dcTable = append(dcTable, dcEntry{cidr: cidr, dc: e.dc})
	}
}

// LookupDC returns the Telegram DC number for the given IP.
// Returns 2 (default DC) if no match found.
func LookupDC(ip net.IP) int16 {
	// Check most specific first (single IPs for DC3/DC4).
	for _, e := range dcTable {
		ones, _ := e.cidr.Mask.Size()
		if ones == 32 && e.cidr.IP.Equal(ip) {
			return e.dc
		}
	}
	for _, e := range dcTable {
		ones, _ := e.cidr.Mask.Size()
		if ones < 32 && e.cidr.Contains(ip) {
			return e.dc
		}
	}
	return 2
}
