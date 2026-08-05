package main

// registry.go — Stage B per-install identity gating (Mark 2026-06-21).
//
// Each genuine z2k install mints an Ed25519 keypair on-device (private key never
// leaves the router, never in the repo/binary) and registers its public key here
// via POST /register. On tunnel connect it presents a per-install AUTH frame
// (mux type 0x06) carrying install_id + a fresh timestamp + an Ed25519 signature.
//
// This is DUAL-ACCEPT and NOT a flip: the relay still accepts the shared-secret
// HMAC (muxAUTH 0x00) as long as --require-per-install is false (the default).
// The flip — refusing static auth so only registered installs get through — is a
// separate, deliberate decision flipped via --require-per-install once adoption
// is high. Nothing here blocks any current client.

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"filippo.io/edwards25519"
)

const muxAUTHID byte = 0x06 // per-install AUTH frame: [id:16][ts:8][sig:64]

var (
	registryPath          = flag.String("registry-path", "/var/lib/z2k-relay/registry.json", "per-install identity registry file")
	requirePerInstall     = flag.Bool("require-per-install", false, "FLIP: reject static-secret auth, require a registered per-install signature. DO NOT enable until adoption is high — it black-holes every non-migrated install.")
	perInstallMaxSessions = flag.Int("per-install-max-sessions", 64, "max concurrent tunnel sessions per install_id (0 = unlimited)")
	registerRatePerMin    = flag.Int("register-rate-per-min", 30, "max /register POSTs accepted per source IP per minute (mass-mint speed-bump)")
	authSkewSeconds       = flag.Int64("auth-skew-seconds", 120, "max accepted clock skew (seconds) on the per-install AUTH timestamp")
)

// ----------------------------------------------------------------- registry ---

type regEntry struct {
	Pubkey    string `json:"pubkey"`     // base64(std) Ed25519 public key
	Revoked   bool   `json:"revoked"`    // surgical kill-switch (checked on the auth hot path)
	CreatedAt int64  `json:"created_at"` // unix seconds
}

type registry struct {
	mu   sync.RWMutex
	m    map[string]*regEntry
	path string
}

var reg *registry

func initRegistry(path string) {
	reg = &registry{m: make(map[string]*regEntry), path: path}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("registry: read %s: %v (starting empty)", path, err)
		}
		return
	}
	var m map[string]*regEntry
	if err := json.Unmarshal(data, &m); err != nil {
		log.Printf("registry: parse %s: %v (starting empty)", path, err)
		return
	}
	reg.m = m
	log.Printf("registry: loaded %d install identities from %s", len(m), path)
}

func (rg *registry) get(id string) *regEntry {
	rg.mu.RLock()
	defer rg.mu.RUnlock()
	return rg.m[id]
}

// upsert records a new identity. Mint-once: an existing id with a DIFFERENT
// pubkey is rejected (prevents a thief re-binding someone else's install_id).
// Returns (created bool, ok bool).
func (rg *registry) upsert(id, pubkey string) (bool, bool) {
	rg.mu.Lock()
	defer rg.mu.Unlock()
	if e, exists := rg.m[id]; exists {
		if e.Pubkey != pubkey {
			return false, false // id taken by a different key — reject
		}
		return false, true // idempotent re-register
	}
	rg.m[id] = &regEntry{Pubkey: pubkey, CreatedAt: time.Now().Unix()}
	rg.persistLocked()
	return true, true
}

// setRevoked поднимает или снимает флаг отзыва и сразу сохраняет файл.
//
// До этого способа выставить флаг не существовало вовсе: поле Revoked читалось
// на горячем пути аутентификации, но записать его было нечем. Оставалось
// править registry.json руками — а это не работало дважды: до перезапуска
// правка не читалась, и первая же успешная регистрация переписывала файл из
// памяти и молча её стирала.
func (rg *registry) setRevoked(id string, v bool) bool {
	rg.mu.Lock()
	defer rg.mu.Unlock()
	e := rg.m[id]
	if e == nil {
		return false
	}
	if e.Revoked != v {
		e.Revoked = v
		rg.persistLocked()
	}
	return true
}

// reload перечитывает реестр с диска, не перезапуская релей. Перезапуск рвёт
// все живые туннели разом, поэтому ради правки одной записи он неприемлем.
//
// Записи, добавленные в памяти, но ещё не попавшие в файл, потеряться не могут:
// upsert сохраняет файл сразу же.
func (rg *registry) reload() (int, error) {
	data, err := os.ReadFile(rg.path)
	if err != nil {
		return 0, err
	}
	var m map[string]*regEntry
	if err := json.Unmarshal(data, &m); err != nil {
		return 0, err
	}
	rg.mu.Lock()
	rg.m = m
	n := len(m)
	rg.mu.Unlock()
	return n, nil
}

// revokedIDs перечисляет отозванные установки — чтобы после перечитывания файла
// оборвать их живые туннели.
func (rg *registry) revokedIDs() []string {
	rg.mu.RLock()
	defer rg.mu.RUnlock()
	out := make([]string, 0, 8)
	for id, e := range rg.m {
		if e.Revoked {
			out = append(out, id)
		}
	}
	return out
}

// persistLocked writes the registry atomically (temp + rename). Caller holds mu.
func (rg *registry) persistLocked() {
	if rg.path == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(rg.path), 0o700)
	tmp := rg.path + ".tmp"
	data, err := json.Marshal(rg.m)
	if err != nil {
		log.Printf("registry: marshal: %v", err)
		return
	}
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		log.Printf("registry: write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, rg.path); err != nil {
		log.Printf("registry: rename %s: %v", rg.path, err)
	}
}

// ------------------------------------------------------- /register rate-limit ---

type ipBucket struct {
	count       int
	windowStart time.Time
}

var (
	regRateMu sync.Mutex
	regRate   = map[string]*ipBucket{}
)

func registerRateOK(ip string) bool {
	if *registerRatePerMin <= 0 {
		return true
	}
	regRateMu.Lock()
	defer regRateMu.Unlock()
	now := time.Now()
	b := regRate[ip]
	if b == nil || now.Sub(b.windowStart) >= time.Minute {
		regRate[ip] = &ipBucket{count: 1, windowStart: now}
		// opportunistic GC of stale buckets
		if len(regRate) > 4096 {
			for k, v := range regRate {
				if now.Sub(v.windowStart) >= 2*time.Minute {
					delete(regRate, k)
				}
			}
		}
		return true
	}
	if b.count >= *registerRatePerMin {
		return false
	}
	b.count++
	return true
}

// -------------------------------------------------------- /register handler ---

type registerReq struct {
	InstallID string `json:"install_id"`
	Pubkey    string `json:"pubkey"` // base64(std) Ed25519 public key
}

// resolveRemoteIP извлекает адрес клиента из X-Forwarded-For.
//
// Берётся ПОСЛЕДНИЙ элемент, а не первый. Разница принципиальная: заголовок
// дописывает наш собственный прокси, добавляя то, что видит сам, в конец. Всё,
// что левее, прислал клиент — и подделать это может кто угодно одной строкой
// запроса.
//
// До 2026-08-05 брался первый элемент, то есть значение, выбранное клиентом.
// Последствия были не косметические: этим адресом ключуется ограничитель
// частоты регистраций (registerRateOK ниже), и обойти его можно было,
// подставляя случайный X-Forwarded-For на каждый запрос. Плюс в лог
// «register: new install ... from ...» писался выдуманный адрес.
//
// Последний элемент подделать нельзя: его ставит прокси поверх того, что
// пришло, уже после клиента.
func resolveRemoteIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := lastIndexByte(xff, ','); i >= 0 {
			return trimSpace(xff[i+1:])
		}
		return trimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func lastIndexByte(s string, b byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == b {
			return i
		}
	}
	return -1
}

func handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	ip := resolveRemoteIP(r)
	if !registerRateOK(ip) {
		http.Error(w, "rate limited", http.StatusTooManyRequests)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	// Auth: X-Z2K-Auth = hex(HMAC-SHA256(tunnelSecret, body)). Gated by the same
	// shared secret as the tunnel (dual-accept with --secret-prev). This is a
	// speed-bump, not the real gate — the rate-limit above bounds mass-minting.
	hsig := func(key string) string {
		m := hmac.New(sha256.New, []byte(key))
		m.Write(body)
		return hex.EncodeToString(m.Sum(nil))
	}
	got := r.Header.Get("X-Z2K-Auth")
	okAuth := subtle.ConstantTimeCompare([]byte(hsig(*secret)), []byte(got)) == 1
	if !okAuth && *secretPrev != "" {
		okAuth = subtle.ConstantTimeCompare([]byte(hsig(*secretPrev)), []byte(got)) == 1
	}
	if !okAuth {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req registerReq
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if !validInstallID(req.InstallID) {
		http.Error(w, "bad install_id", http.StatusBadRequest)
		return
	}
	pub, err := base64.StdEncoding.DecodeString(req.Pubkey)
	if err != nil || !validEd25519Pubkey(pub) {
		http.Error(w, "bad pubkey", http.StatusBadRequest)
		return
	}
	created, ok := reg.upsert(req.InstallID, req.Pubkey)
	if !ok {
		http.Error(w, "install_id taken", http.StatusConflict)
		return
	}
	if created {
		log.Printf("register: new install %s from %s", req.InstallID, ip)
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

// validEd25519Pubkey reports whether pub is a safe Ed25519 public key: a
// canonical encoding of a point of full prime order. It rejects
//   - the wrong length,
//   - non-canonical encodings (SetBytes fails), and
//   - small-order points ([8]P == identity): all-zero, the neutral element,
//     order-2/4/8 points. A low-order key lets an attacker forge AUTH frames
//     without a private key (cofactor forgery) — the reason a zero-pubkey
//     `00112233…` must never have been accepted into the registry.
func validEd25519Pubkey(pub []byte) bool {
	if len(pub) != ed25519.PublicKeySize {
		return false
	}
	p, err := new(edwards25519.Point).SetBytes(pub)
	if err != nil {
		return false // non-canonical / not on curve
	}
	// Point has small order iff cofactor multiplication lands on the identity.
	if new(edwards25519.Point).MultByCofactor(p).Equal(edwards25519.NewIdentityPoint()) == 1 {
		return false
	}
	return true
}

// validInstallID: 16 bytes hex (32 chars), lowercase hex only.
func validInstallID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// ------------------------------------------------ per-install AUTH verify ---

// Anti-replay: the signed AUTH message is only install_id||timestamp, so a
// captured 88-byte frame is replayable for the whole ±authSkewSeconds window.
// We cache the signature of every ACCEPTED frame and reject a second sighting.
// A legitimate client re-signs with a fresh timestamp on each reconnect (backoff
// ≥3s), producing a new signature, so this never rejects a real reconnect. The
// TTL only needs to span the accept window (2*authSkewSeconds) — anything older
// is already rejected by the skew gate. Mirrors the regRate map+mutex+inline-GC.
var (
	authNonceMu   sync.Mutex
	authNonceSeen = map[string]time.Time{} // key: the 64-byte signature
)

// authReplaySeen records sig and reports whether it was already accepted within
// the replay window. Call ONLY for cryptographically-valid frames.
func authReplaySeen(sig []byte) bool {
	ttl := time.Duration(2**authSkewSeconds) * time.Second
	authNonceMu.Lock()
	defer authNonceMu.Unlock()
	now := time.Now()
	key := string(sig)
	if t, ok := authNonceSeen[key]; ok && now.Sub(t) < ttl {
		return true // replay within window
	}
	authNonceSeen[key] = now
	// opportunistic GC of expired entries (bounded memory, no goroutine)
	if len(authNonceSeen) > 8192 {
		for k, t := range authNonceSeen {
			if now.Sub(t) >= ttl {
				delete(authNonceSeen, k)
			}
		}
	}
	return false
}

// verifyPerInstallAuth parses+verifies a muxAUTHID payload:
//
//	[install_id:16][timestamp:8 BE unix][ed25519 sig:64]   (88 bytes)
//
// signed message = install_id(16) || timestamp(8). Returns the install_id (for
// logging/quota) and whether auth succeeded.
func verifyPerInstallAuth(payload []byte) (string, bool) {
	if len(payload) != 88 {
		return "", false
	}
	id := hex.EncodeToString(payload[0:16])
	ts := int64(binary.BigEndian.Uint64(payload[16:24]))
	sig := payload[24:88]
	now := time.Now().Unix()
	if ts < now-*authSkewSeconds || ts > now+*authSkewSeconds {
		return id, false
	}
	e := reg.get(id)
	if e == nil || e.Revoked {
		return id, false
	}
	pub, err := base64.StdEncoding.DecodeString(e.Pubkey)
	if err != nil || !validEd25519Pubkey(pub) {
		// Defense in depth: a low-order key must never authenticate even if it
		// slipped into the registry before validEd25519Pubkey gated /register.
		return id, false
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), payload[0:24], sig) {
		return id, false
	}
	if authReplaySeen(sig) {
		log.Printf("auth rejected (replay) id=%s", id)
		return id, false
	}
	return id, true
}

// ------------------------------------------------ per-install session quota ---

// Квота живёт в общем учёте по установкам (installstats.go). Раньше здесь была
// отдельная sync.Map со счётчиком: она ничего не знала ни об адресах, ни о
// трафике, ни о самих соединениях (то есть отозвать по ней было нечего) и
// НИКОГДА не вычищалась — запись оставалась навсегда после первой же сессии.

func acquireInstallSession(id, ip string, s *session) (bool, string) {
	return installs.begin(id, ip, s)
}

func releaseInstallSession(id string, s *session, rx, tx int64) {
	installs.end(id, s, rx, tx)
}

// tiny helpers (avoid importing strings just for these)
func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}
