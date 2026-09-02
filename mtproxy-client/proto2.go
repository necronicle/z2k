package main

import (
	"encoding/binary"
	"fmt"
)

// Протокол v2 (спека §2.2): зеркало vps-relay/wire.go. Кадр тот же —
// uint16 stream_id | byte type | payload; новые типы и payload'ы ниже.
const (
	muxAUTHID    = 0x06
	muxHELLO     = 0x07
	muxHELLO_ACK = 0x08
	muxWINDOW    = 0x09
	muxINFO      = 0x0A
)

const protoVersion2 = 2

const (
	infoAuthOK         byte = 0
	infoRetryAfter     byte = 1
	infoUpdateRequired byte = 2
	infoClockSkew      byte = 3
	infoGoodbye        byte = 4
)

const (
	rNormal   byte = 0
	rProtocol byte = 1
	rShutdown byte = 12
)

var reasonNames = [...]string{"normal", "protocol", "timeout", "stream_limit", "queue_limit",
	"dial_failed", "dial_throttled", "not_allowed", "auth_failed", "clock_skew", "revoked",
	"overloaded", "shutdown", "replaced", "peer_reset"}

func reasonName(r byte) string {
	if int(r) < len(reasonNames) {
		return reasonNames[r]
	}
	return fmt.Sprintf("unknown(%d)", r)
}

// HELLO: ver(1) build_len(1) build[…] caps(BE32)
func encodeHello(build string) []byte {
	if len(build) > 255 {
		build = build[:255]
	}
	b := append([]byte{protoVersion2, byte(len(build))}, build...)
	return binary.BigEndian.AppendUint32(b, 0)
}

type helloAck struct {
	Ver           byte
	ServerUnix    int64
	Nonce         [16]byte
	MinBuild      string
	DefaultWindow uint32
}

// HELLO_ACK: ver(1) server_unix(BE64) nonce(16) min_build_len(1) min_build[…] default_window(BE32) caps(BE32)
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
	return a, nil
}

func decodeClose(p []byte) (byte, string) {
	if len(p) == 0 {
		return rNormal, ""
	}
	return p[0], string(p[1:])
}

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

func decodeInfo(p []byte) (kind byte, arg uint32, text string, err error) {
	if len(p) < 5 {
		return 0, 0, "", fmt.Errorf("INFO короче 5 байт")
	}
	return p[0], binary.BigEndian.Uint32(p[1:5]), string(p[5:]), nil
}
