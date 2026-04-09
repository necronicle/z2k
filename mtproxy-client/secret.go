package main

import (
	"encoding/hex"
	"fmt"
)

// ProxySecret holds parsed MTProxy FakeTLS secret (ee-prefixed).
type ProxySecret struct {
	Tag    byte   // protocol tag (0xdd = PaddedIntermediate)
	Secret []byte // 16-byte crypto secret
	SNI    string // disguise domain (e.g. "s3.amazonaws.com")
}

// ParseSecret decodes an ee-prefixed hex secret string.
// Format: "ee" + 1 byte tag + 16 bytes secret + N bytes SNI domain (ASCII).
func ParseSecret(hexStr string) (*ProxySecret, error) {
	if len(hexStr) < 4 || hexStr[:2] != "ee" {
		return nil, fmt.Errorf("secret must start with 'ee' (FakeTLS mode)")
	}

	raw, err := hex.DecodeString(hexStr[2:])
	if err != nil {
		return nil, fmt.Errorf("invalid hex in secret: %w", err)
	}

	if len(raw) < 17 {
		return nil, fmt.Errorf("secret too short: need at least 17 bytes, got %d", len(raw))
	}

	return &ProxySecret{
		Tag:    raw[0],
		Secret: raw[1:17],
		SNI:    string(raw[17:]),
	}, nil
}
