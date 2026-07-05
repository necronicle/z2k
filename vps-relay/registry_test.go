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

func TestValidEd25519Pubkey(t *testing.T) {
	// Real generated keys must always pass.
	for i := 0; i < 50; i++ {
		pub, _, _ := ed25519.GenerateKey(rand.Reader)
		if !validEd25519Pubkey(pub) {
			t.Fatalf("genuine generated key rejected: %x", pub)
		}
	}

	// Canonical small-order Ed25519 point encodings — every one is forgeable and
	// must be rejected. Includes the all-zero key `00112233…` we actually saw
	// registered (base64 "AAAA…" decodes to 32 zero bytes).
	smallOrderHex := []string{
		"0000000000000000000000000000000000000000000000000000000000000000", // 0 (order 4)
		"0100000000000000000000000000000000000000000000000000000000000000", // 1 (neutral, order 1)
		"0000000000000000000000000000000000000000000000000000000000000080", // 0 with sign bit
		"0100000000000000000000000000000000000000000000000000000000000080", // 1 with sign bit
		"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05", // order 8
		"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a", // order 8
		"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p-1 (order 2)
		"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p ≡ 0 (order 4)
		"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p+1 ≡ 1 (order 1)
	}
	for _, h := range smallOrderHex {
		pub, err := hex.DecodeString(h)
		if err != nil {
			t.Fatalf("bad test vector %q: %v", h, err)
		}
		if validEd25519Pubkey(pub) {
			t.Fatalf("small-order/forgeable key accepted: %s", h)
		}
	}

	// Wrong length must be rejected.
	if validEd25519Pubkey(make([]byte, 31)) || validEd25519Pubkey(make([]byte, 33)) {
		t.Fatal("wrong-length key accepted")
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
