package main

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net"
)

// Кадр: uint16 stream_id (BE) | byte type | payload. Спека v2 §2.1–2.2.
const (
	muxAUTH         byte = 0x00 // общий секрет, v1-легаси
	muxCONNECT      byte = 0x01
	muxDATA         byte = 0x02
	muxCLOSE        byte = 0x03
	muxCONNECT_OK   byte = 0x04
	muxCONNECT_FAIL byte = 0x05
	muxAUTHID       byte = 0x06
	muxHELLO        byte = 0x07
	muxHELLO_ACK    byte = 0x08
	muxWINDOW       byte = 0x09
	muxINFO         byte = 0x0A
)

const (
	addrIPv4 = 1
	addrIPv6 = 4
)

// Коды причин (§2.3). Текст рядом — только для журнала.
const (
	rNormal        byte = 0
	rProtocol      byte = 1
	rTimeout       byte = 2
	rStreamLimit   byte = 3
	rQueueLimit    byte = 4
	rDialFailed    byte = 5
	rDialThrottled byte = 6
	rNotAllowed    byte = 7
	rAuthFailed    byte = 8
	rClockSkew     byte = 9
	rRevoked       byte = 10
	rOverloaded    byte = 11
	rShutdown      byte = 12
	rReplaced      byte = 13
	rPeerReset     byte = 14
)

var reasonNames = [...]string{"normal", "protocol", "timeout", "stream_limit", "queue_limit",
	"dial_failed", "dial_throttled", "not_allowed", "auth_failed", "clock_skew", "revoked",
	"overloaded", "shutdown", "replaced", "peer_reset"}

func reasonName(r byte) string {
	if int(r) < len(reasonNames) {
		return reasonNames[r]
	}
	return "unknown"
}

const (
	infoAuthOK         byte = 0
	infoRetryAfter     byte = 1
	infoUpdateRequired byte = 2
	infoClockSkew      byte = 3
	infoGoodbye        byte = 4
)

const protoVersion2 byte = 2

func encodeFrame(streamID uint16, msgType byte, payload []byte) []byte {
	buf := make([]byte, 3+len(payload))
	binary.BigEndian.PutUint16(buf[0:2], streamID)
	buf[2] = msgType
	copy(buf[3:], payload)
	return buf
}

func decodeFrame(data []byte) (streamID uint16, msgType byte, payload []byte, err error) {
	if len(data) < 3 {
		err = fmt.Errorf("frame too short: %d", len(data))
		return
	}
	return binary.BigEndian.Uint16(data[0:2]), data[2], data[3:], nil
}

func parseConnectPayload(p []byte) (addr string, port int, err error) {
	if len(p) < 1 {
		return "", 0, fmt.Errorf("empty")
	}
	switch p[0] {
	case addrIPv4:
		if len(p) < 7 {
			return "", 0, fmt.Errorf("short v4")
		}
		return fmt.Sprintf("%d.%d.%d.%d", p[1], p[2], p[3], p[4]), int(binary.BigEndian.Uint16(p[5:7])), nil
	case addrIPv6:
		if len(p) < 19 {
			return "", 0, fmt.Errorf("short v6")
		}
		ip := make(net.IP, 16)
		copy(ip, p[1:17])
		return ip.String(), int(binary.BigEndian.Uint16(p[17:19])), nil
	default:
		return "", 0, fmt.Errorf("unknown addr type %d", p[0])
	}
}

// --- v2 payloads ---------------------------------------------------------

type hello struct {
	Ver   byte
	Build string
	Caps  uint32
}

// HELLO: ver(1) build_len(1) build[…] caps(BE32)
func decodeHello(p []byte) (hello, error) {
	if len(p) < 2 {
		return hello{}, fmt.Errorf("HELLO короче 2 байт")
	}
	n := int(p[1])
	if len(p) < 2+n+4 {
		return hello{}, fmt.Errorf("HELLO: build_len=%d не помещается в %d байт", n, len(p))
	}
	return hello{Ver: p[0], Build: string(p[2 : 2+n]), Caps: binary.BigEndian.Uint32(p[2+n : 6+n])}, nil
}

type helloAck struct {
	Ver           byte
	ServerUnix    int64
	Nonce         [16]byte
	MinBuild      string
	DefaultWindow uint32
	Caps          uint32
}

// HELLO_ACK: ver(1) server_unix(BE64) nonce(16) min_build_len(1) min_build[…] default_window(BE32) caps(BE32)
func encodeHelloAck(a helloAck) []byte {
	b := make([]byte, 0, 1+8+16+1+len(a.MinBuild)+8)
	b = append(b, a.Ver)
	b = binary.BigEndian.AppendUint64(b, uint64(a.ServerUnix))
	b = append(b, a.Nonce[:]...)
	b = append(b, byte(len(a.MinBuild)))
	b = append(b, a.MinBuild...)
	b = binary.BigEndian.AppendUint32(b, a.DefaultWindow)
	b = binary.BigEndian.AppendUint32(b, a.Caps)
	return b
}

func decodeHelloAck(p []byte) (helloAck, error) {
	if len(p) < 26 {
		return helloAck{}, fmt.Errorf("HELLO_ACK короче 26 байт")
	}
	n := int(p[25])
	if len(p) < 26+n+8 {
		return helloAck{}, fmt.Errorf("HELLO_ACK: min_build_len=%d не помещается", n)
	}
	var a helloAck
	a.Ver = p[0]
	a.ServerUnix = int64(binary.BigEndian.Uint64(p[1:9]))
	copy(a.Nonce[:], p[9:25])
	a.MinBuild = string(p[26 : 26+n])
	a.DefaultWindow = binary.BigEndian.Uint32(p[26+n : 30+n])
	a.Caps = binary.BigEndian.Uint32(p[30+n : 34+n])
	return a, nil
}

func encodeClose(reason byte, text string) []byte {
	return append([]byte{reason}, text...)
}

func decodeClose(p []byte) (byte, string) {
	if len(p) == 0 {
		return rNormal, ""
	}
	return p[0], string(p[1:])
}

func encodeConnectOK(window uint32) []byte { return binary.BigEndian.AppendUint32(nil, window) }

func decodeConnectOK(p []byte) uint32 {
	if len(p) < 4 {
		return 0
	}
	return binary.BigEndian.Uint32(p[:4])
}

func encodeWindow(credit uint32) []byte { return binary.BigEndian.AppendUint32(nil, credit) }

func decodeWindow(p []byte) (uint32, error) {
	if len(p) != 4 {
		return 0, fmt.Errorf("WINDOW: %d байт вместо 4", len(p))
	}
	return binary.BigEndian.Uint32(p), nil
}

func encodeInfo(kind byte, arg uint32, text string) []byte {
	b := make([]byte, 0, 5+len(text))
	b = append(b, kind)
	b = binary.BigEndian.AppendUint32(b, arg)
	return append(b, text...)
}

func decodeInfo(p []byte) (kind byte, arg uint32, text string, err error) {
	if len(p) < 5 {
		return 0, 0, "", fmt.Errorf("INFO короче 5 байт")
	}
	return p[0], binary.BigEndian.Uint32(p[1:5]), string(p[5:]), nil
}

type authV2 struct {
	ID     string
	TS     int64
	Nonce  [16]byte
	Sig    []byte
	Signed []byte // id||ts||nonce — то, что подписано
}

// AUTHID v2: id(16) ts(BE64) nonce(16) sig(64) = 104 байта.
func decodeAuthV2(p []byte) (authV2, error) {
	if len(p) != 104 {
		return authV2{}, fmt.Errorf("AUTHID v2: %d байт вместо 104", len(p))
	}
	var a authV2
	a.ID = hex.EncodeToString(p[0:16])
	a.TS = int64(binary.BigEndian.Uint64(p[16:24]))
	copy(a.Nonce[:], p[24:40])
	a.Sig = p[40:104]
	a.Signed = p[0:40]
	return a, nil
}
