package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"testing"
	"time"
)

func mkFrame(id [16]byte, ts int64, priv ed25519.PrivateKey) []byte {
	buf := make([]byte, 24, 88)
	copy(buf[0:16], id[:])
	binary.BigEndian.PutUint64(buf[16:24], uint64(ts))
	return append(buf, ed25519.Sign(priv, buf)...)
}

func TestVerifyPerInstallAuth(t *testing.T) {
	skew := int64(120)
	authSkewSeconds = &skew
	reg = &registry{m: map[string]*regEntry{}}

	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	var idb [16]byte
	if _, err := rand.Read(idb[:]); err != nil {
		t.Fatal(err)
	}
	id := hex.EncodeToString(idb[:])
	reg.m[id] = &regEntry{Pubkey: base64.StdEncoding.EncodeToString(pub)}

	now := time.Now().Unix()
	frame := mkFrame(idb, now, priv)

	if gotID, ok := verifyPerInstallAuth(frame); !ok || gotID != id {
		t.Fatalf("valid auth rejected: ok=%v id=%s want=%s", ok, gotID, id)
	}

	// tampered signature
	bad := append([]byte(nil), frame...)
	bad[30] ^= 0xff
	if _, ok := verifyPerInstallAuth(bad); ok {
		t.Fatal("tampered signature accepted")
	}

	// wrong length
	if _, ok := verifyPerInstallAuth(frame[:87]); ok {
		t.Fatal("short frame accepted")
	}

	// stale timestamp (signed correctly but too old)
	if _, ok := verifyPerInstallAuth(mkFrame(idb, now-9999, priv)); ok {
		t.Fatal("stale timestamp accepted")
	}
	// future timestamp beyond skew
	if _, ok := verifyPerInstallAuth(mkFrame(idb, now+9999, priv)); ok {
		t.Fatal("future timestamp accepted")
	}

	// revoked
	reg.m[id].Revoked = true
	if _, ok := verifyPerInstallAuth(frame); ok {
		t.Fatal("revoked identity accepted")
	}
	reg.m[id].Revoked = false

	// unknown id
	reg.m = map[string]*regEntry{}
	if _, ok := verifyPerInstallAuth(frame); ok {
		t.Fatal("unknown identity accepted")
	}

	// signature by a different key (key substitution) must fail
	reg.m[id] = &regEntry{Pubkey: base64.StdEncoding.EncodeToString(pub)}
	_, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
	if _, ok := verifyPerInstallAuth(mkFrame(idb, now, otherPriv)); ok {
		t.Fatal("signature from a non-registered key accepted")
	}
}

func TestRegistryUpsert(t *testing.T) {
	reg = &registry{m: map[string]*regEntry{}, path: ""} // empty path = no persist

	if created, ok := reg.upsert("aa", "pub1"); !created || !ok {
		t.Fatalf("first upsert: created=%v ok=%v, want true/true", created, ok)
	}
	if created, ok := reg.upsert("aa", "pub1"); created || !ok {
		t.Fatalf("idempotent re-register: created=%v ok=%v, want false/true", created, ok)
	}
	if _, ok := reg.upsert("aa", "pub2"); ok {
		t.Fatal("re-binding an install_id to a different pubkey must be rejected")
	}
}

func TestValidInstallID(t *testing.T) {
	if !validInstallID("0123456789abcdef0123456789abcdef") {
		t.Fatal("valid 32-hex rejected")
	}
	for _, bad := range []string{"", "short", "0123456789ABCDEF0123456789abcdef", "0123456789abcdef0123456789abcdeg", "0123456789abcdef0123456789abcde"} {
		if validInstallID(bad) {
			t.Fatalf("invalid id accepted: %q", bad)
		}
	}
}
