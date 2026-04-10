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

		// IPv6 Telegram ranges
		{"2001:b28:f23d::/48", 2}, // DC2 main IPv6
		{"2001:b28:f23f::/48", 5}, // DC5 IPv6
		{"2001:67c:4e8::/48", 2},  // General Telegram IPv6
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
// Returns 2 (default DC) if no match found. Supports both IPv4 and IPv6.
func LookupDC(ip net.IP) int16 {
	isV6 := ip.To4() == nil

	if !isV6 {
		// IPv4: check most specific first (single IPs for DC3/DC4).
		for _, e := range dcTable {
			ones, _ := e.cidr.Mask.Size()
			if ones == 32 && e.cidr.IP.Equal(ip) {
				return e.dc
			}
		}
	}

	// Check all CIDR ranges (both v4 and v6).
	// For IPv4, skip /32 (already checked above). For IPv6, check all.
	bestOnes := -1
	bestDC := int16(0)
	for _, e := range dcTable {
		ones, bits := e.cidr.Mask.Size()
		if !isV6 && ones == 32 {
			continue // already handled above for v4
		}
		if e.cidr.Contains(ip) {
			// Pick the most specific (longest prefix) match.
			// Normalize: compare relative specificity (ones out of bits).
			// For same address family, just compare ones directly.
			specificity := ones
			if bits == 128 {
				// IPv6 range
				specificity = ones
			}
			if specificity > bestOnes {
				bestOnes = specificity
				bestDC = e.dc
			}
		}
	}
	if bestOnes >= 0 {
		return bestDC
	}
	return 2
}
