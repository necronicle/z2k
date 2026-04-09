package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
)

// MsgSplitter splits an encrypted MTProto stream into individual packets
// for WebSocket framing. Each WS message must be exactly one MTProto packet.
type MsgSplitter struct {
	dec       cipher.Stream // decrypts relay-encrypted data to read headers
	proto     uint32
	cipherBuf []byte
	plainBuf  []byte
	disabled  bool
}

// NewMsgSplitter creates a splitter from relay init header.
// It needs to decrypt the stream to read packet lengths, but returns
// the original encrypted chunks (not decrypted).
func NewMsgSplitter(relayInit []byte, proto uint32) *MsgSplitter {
	// Create a decrypt stream using relay keys (no secret)
	key := make([]byte, 32)
	copy(key, relayInit[8:40])
	iv := make([]byte, 16)
	copy(iv, relayInit[40:56])

	block, _ := aes.NewCipher(key)
	dec := cipher.NewCTR(block, iv)

	// Advance past the 64-byte header
	skip := make([]byte, 64)
	dec.XORKeyStream(skip, skip)

	return &MsgSplitter{
		dec:   dec,
		proto: proto,
	}
}

// Split takes an encrypted chunk and returns individual encrypted packets.
func (s *MsgSplitter) Split(chunk []byte) [][]byte {
	if len(chunk) == 0 {
		return nil
	}
	if s.disabled {
		return [][]byte{chunk}
	}

	s.cipherBuf = append(s.cipherBuf, chunk...)
	// Decrypt to read headers
	plain := make([]byte, len(chunk))
	s.dec.XORKeyStream(plain, chunk)
	s.plainBuf = append(s.plainBuf, plain...)

	var parts [][]byte
	for len(s.cipherBuf) > 0 {
		pktLen := s.nextPacketLen()
		if pktLen < 0 {
			// Error — send rest as-is
			parts = append(parts, append([]byte(nil), s.cipherBuf...))
			s.cipherBuf = nil
			s.plainBuf = nil
			s.disabled = true
			break
		}
		if pktLen == 0 {
			// Not enough data yet
			break
		}
		parts = append(parts, append([]byte(nil), s.cipherBuf[:pktLen]...))
		s.cipherBuf = s.cipherBuf[pktLen:]
		s.plainBuf = s.plainBuf[pktLen:]
	}
	return parts
}

// Flush returns any remaining buffered data.
func (s *MsgSplitter) Flush() []byte {
	if len(s.cipherBuf) == 0 {
		return nil
	}
	out := append([]byte(nil), s.cipherBuf...)
	s.cipherBuf = nil
	s.plainBuf = nil
	return out
}

func (s *MsgSplitter) nextPacketLen() int {
	switch s.proto {
	case 0xefefefef: // Abridged
		return s.nextAbridgedLen()
	case 0xeeeeeeee, 0xdddddddd: // Intermediate, PaddedIntermediate
		return s.nextIntermediateLen()
	default:
		return -1
	}
}

func (s *MsgSplitter) nextAbridgedLen() int {
	if len(s.plainBuf) < 1 {
		return 0
	}
	first := s.plainBuf[0]
	var headerLen, payloadLen int
	if first == 0x7f || first == 0xff {
		if len(s.plainBuf) < 4 {
			return 0
		}
		payloadLen = int(s.plainBuf[1]) | int(s.plainBuf[2])<<8 | int(s.plainBuf[3])<<16
		payloadLen *= 4
		headerLen = 4
	} else {
		payloadLen = int(first&0x7f) * 4
		headerLen = 1
	}
	if payloadLen <= 0 {
		return -1
	}
	total := headerLen + payloadLen
	if len(s.plainBuf) < total {
		return 0
	}
	return total
}

func (s *MsgSplitter) nextIntermediateLen() int {
	if len(s.plainBuf) < 4 {
		return 0
	}
	payloadLen := int(binary.LittleEndian.Uint32(s.plainBuf[0:4]) & 0x7FFFFFFF)
	if payloadLen <= 0 {
		return -1
	}
	total := 4 + payloadLen
	if len(s.plainBuf) < total {
		return 0
	}
	return total
}
