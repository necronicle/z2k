package main

import (
	"encoding/hex"
	"fmt"

	"github.com/gotd/td/mtproxy"
)

// ParseSecret decodes an ee-prefixed hex secret string.
// Format (tdesktop-compatible): ee + tag(1) + secret(16) + sni(rest)
// Tag byte may not match standard codec tags — we force PaddedIntermediate.
func ParseSecret(hexStr string) (mtproxy.Secret, error) {
	if len(hexStr) < 4 || hexStr[:2] != "ee" {
		return mtproxy.Secret{}, fmt.Errorf("secret must start with 'ee' (FakeTLS mode)")
	}

	raw, err := hex.DecodeString(hexStr[2:])
	if err != nil {
		return mtproxy.Secret{}, fmt.Errorf("invalid hex: %w", err)
	}

	if len(raw) < 17 {
		return mtproxy.Secret{}, fmt.Errorf("secret too short: need 1+16+sni bytes, got %d", len(raw))
	}

	// mtg format (confirmed working with mtproto.ru servers):
	// raw[0:16] = secret key (includes tag byte as part of key)
	// raw[16:] = SNI domain
	// Force PaddedIntermediate (0xdd) as protocol tag.
	return mtproxy.Secret{
		Secret:    raw[0:16],
		Tag:       0xdd,
		CloakHost: string(raw[16:]),
		Type:      mtproxy.TLS,
	}, nil
}
