package domainroute

import (
	"encoding/binary"
	"net/netip"
	"time"
)

const maxTCPFlows = 128
const maxDNSFrame = 4096

var carrierNAT = netip.MustParsePrefix("100.64.0.0/10")

type tcpFlow struct {
	src, dst     netip.Addr
	sport, dport uint16
}
type tcpState struct {
	next uint32
	data []byte
	seen time.Time
}
type PacketDecoder struct{ flows map[tcpFlow]tcpState }

func NewPacketDecoder() *PacketDecoder { return &PacketDecoder{flows: make(map[tcpFlow]tcpState)} }

func (d *PacketDecoder) Push(packet []byte, now time.Time) (netip.Addr, []byte, Transport) {
	var src, dst netip.Addr
	var proto byte
	var data []byte
	switch {
	case len(packet) >= 20 && packet[0]>>4 == 4:
		ihl := int(packet[0]&15) * 4
		if ihl < 20 || len(packet) < ihl {
			return netip.Addr{}, nil, TransportUDP
		}
		length := int(binary.BigEndian.Uint16(packet[2:4]))
		if length != len(packet) || packet[6]&0x3f != 0 || packet[7] != 0 {
			return netip.Addr{}, nil, TransportUDP
		}
		src = netip.AddrFrom4([4]byte(packet[12:16]))
		dst = netip.AddrFrom4([4]byte(packet[16:20]))
		if !dst.IsPrivate() && !carrierNAT.Contains(dst) {
			return netip.Addr{}, nil, TransportUDP
		}
		proto, data = packet[9], packet[ihl:]
	case len(packet) >= 40 && packet[0]>>4 == 6:
		// Устройства с IPv6 (macOS, iOS, Android) спрашивают DNS роутера по
		// IPv6 — и A-записи тоже. Ответ DNS заголовков расширения не несёт;
		// со следующим заголовком не UDP/TCP (в том числе фрагмент) пакет
		// не наш.
		if int(binary.BigEndian.Uint16(packet[4:6]))+40 != len(packet) {
			return netip.Addr{}, nil, TransportUDP
		}
		src = netip.AddrFrom16([16]byte(packet[8:24]))
		dst = netip.AddrFrom16([16]byte(packet[24:40]))
		if !lanClient6(dst) {
			return netip.Addr{}, nil, TransportUDP
		}
		proto, data = packet[6], packet[40:]
	default:
		return netip.Addr{}, nil, TransportUDP
	}
	if len(data) < 8 || binary.BigEndian.Uint16(data[:2]) != 53 {
		return netip.Addr{}, nil, TransportUDP
	}
	switch proto {
	case 17:
		ulen := int(binary.BigEndian.Uint16(data[4:6]))
		if ulen < 8 || ulen != len(data) {
			return netip.Addr{}, nil, TransportUDP
		}
		return dst, data[8:], TransportUDP
	case 6:
		if len(data) < 20 {
			return netip.Addr{}, nil, TransportTCP
		}
		hlen := int(data[12]>>4) * 4
		if hlen < 20 || hlen > len(data) {
			return netip.Addr{}, nil, TransportTCP
		}
		payload := data[hlen:]
		if len(payload) == 0 {
			return netip.Addr{}, nil, TransportTCP
		}
		key := tcpFlow{src, dst, 53, binary.BigEndian.Uint16(data[2:4])}
		seq := binary.BigEndian.Uint32(data[4:8])
		for k, state := range d.flows {
			if now.Sub(state.seen) > 5*time.Second {
				delete(d.flows, k)
			}
		}
		state, ok := d.flows[key]
		if ok && seq != state.next {
			delete(d.flows, key)
			return netip.Addr{}, nil, TransportTCP
		}
		if !ok {
			if len(d.flows) >= maxTCPFlows {
				return netip.Addr{}, nil, TransportTCP
			}
			state = tcpState{}
		}
		if len(state.data)+len(payload) > maxDNSFrame+2 {
			delete(d.flows, key)
			return netip.Addr{}, nil, TransportTCP
		}
		state.data = append(state.data, payload...)
		state.next = seq + uint32(len(payload))
		state.seen = now
		if len(state.data) >= 2 {
			frameLen := int(binary.BigEndian.Uint16(state.data[:2]))
			if frameLen < 12 || frameLen > maxDNSFrame {
				delete(d.flows, key)
				return netip.Addr{}, nil, TransportTCP
			}
			if len(state.data) >= frameLen+2 {
				delete(d.flows, key)
				return dst, state.data[:frameLen+2], TransportTCP
			}
		}
		d.flows[key] = state
	}
	return netip.Addr{}, nil, TransportUDP
}
