package h2

import (
	"testing"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

const peerPEM = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIaU7MToJm9NKp8YfGxR6r+/h4mcG\n7SxI8tsW8OR1A5tv/zCzVbCRRh2t87/kxnP6lAy0lkr7qYwu+ox+k3dr6w==\n-----END PUBLIC KEY-----\n"

func TestPinnedKeyParsesPEM(t *testing.T) {
	tr := &Transport{d: &account.Device{H2: &account.H2Key{PeerKey: peerPEM}}}
	if tr.pinnedKey() == nil {
		t.Fatal("PEM peer key not parsed")
	}
}

func TestPinnedKeyParsesBase64DER(t *testing.T) {
	tr := &Transport{d: &account.Device{H2: &account.H2Key{PeerKey: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIaU7MToJm9NKp8YfGxR6r+/h4mcG7SxI8tsW8OR1A5tv/zCzVbCRRh2t87/kxnP6lAy0lkr7qYwu+ox+k3dr6w=="}}}
	if tr.pinnedKey() == nil {
		t.Fatal("DER peer key not parsed")
	}
}

func TestPinnedKeyGarbage(t *testing.T) {
	tr := &Transport{d: &account.Device{H2: &account.H2Key{PeerKey: "nope"}}}
	if tr.pinnedKey() != nil {
		t.Fatal("garbage must not pin")
	}
}
