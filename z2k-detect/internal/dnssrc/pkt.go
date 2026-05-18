package dnssrc

import (
	"context"
	"encoding/binary"
	"net"
	"strings"
)

// PacketSource sniffs UDP/53 via AF_PACKET (Linux only — see pkt_linux.go).
// Universal fallback for installs without a parseable resolver log
// (NDM-native Keenetic without AGH or dnsmasq). Captures DNS queries
// from clients on the LAN side of the gateway and emits the QNAME.
//
// Permissions: needs CAP_NET_RAW. init.d runs the daemon as root so this
// works without ambient caps.
type PacketSource struct{}

func NewPacket() *PacketSource { return &PacketSource{} }

func (s *PacketSource) Name() string { return "af_packet:udp/53" }

func (s *PacketSource) Start(ctx context.Context) (<-chan Event, <-chan error) {
	out := make(chan Event, 256)
	errs := make(chan error, 1)
	go packetCapture(ctx, out, errs)
	return out, errs
}

// parseDNSQuery extracts the QNAME from a UDP/53 packet captured at
// AF_PACKET SOCK_DGRAM level (so the buffer starts with the IP header).
// Returns (domain, srcIP, ok). Only A-record queries are returned;
// responses and AAAA/HTTPS queries are skipped to keep the probe
// pipeline from seeing each click N times.
func parseDNSQuery(pkt []byte) (string, string, bool) {
	if len(pkt) < 28 {
		return "", "", false
	}
	// IPv4 sanity: version 4, IHL in [5..15].
	verIHL := pkt[0]
	if verIHL>>4 != 4 {
		return "", "", false
	}
	ihl := int(verIHL&0x0F) * 4
	if ihl < 20 || ihl > 60 || len(pkt) < ihl+8 {
		return "", "", false
	}
	if pkt[9] != 17 { // UDP
		return "", "", false
	}
	srcIP := net.IPv4(pkt[12], pkt[13], pkt[14], pkt[15]).String()
	// UDP header at offset ihl: srcPort(2), dstPort(2), len(2), csum(2).
	dstPort := binary.BigEndian.Uint16(pkt[ihl+2 : ihl+4])
	if dstPort != 53 {
		return "", "", false
	}
	dns := pkt[ihl+8:]
	if len(dns) < 12 {
		return "", "", false
	}
	// DNS header: ID(2), FLAGS(2), QDCOUNT(2), ANCOUNT(2), NSCOUNT(2), ARCOUNT(2).
	// FLAGS bit 15 = QR (0=query, 1=response). We only want queries.
	flags := binary.BigEndian.Uint16(dns[2:4])
	if flags&0x8000 != 0 {
		return "", "", false
	}
	qdcount := binary.BigEndian.Uint16(dns[4:6])
	if qdcount == 0 {
		return "", "", false
	}
	// Skip header, parse first question. QNAME is a length-prefixed
	// label sequence terminated by a zero byte. We don't follow
	// compression pointers in questions (RFC discourages compression
	// in question section; in practice clients never do it).
	pos := 12
	var sb strings.Builder
	for {
		if pos >= len(dns) {
			return "", "", false
		}
		l := int(dns[pos])
		pos++
		if l == 0 {
			break
		}
		if l&0xC0 != 0 {
			// Compression pointer in question section — bail.
			return "", "", false
		}
		if pos+l > len(dns) {
			return "", "", false
		}
		if sb.Len() > 0 {
			sb.WriteByte('.')
		}
		sb.Write(dns[pos : pos+l])
		pos += l
		if sb.Len() > 253 {
			return "", "", false
		}
	}
	// QTYPE(2) follows; only accept A (1). AAAA (28) and HTTPS (65)
	// are duplicates of the same client intent.
	if pos+2 > len(dns) {
		return "", "", false
	}
	qtype := binary.BigEndian.Uint16(dns[pos : pos+2])
	if qtype != 1 {
		return "", "", false
	}
	return strings.ToLower(sb.String()), srcIP, true
}
