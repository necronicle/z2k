package main

// identity.go — Stage B per-install identity (Mark 2026-06-21).
//
// Each install mints an Ed25519 keypair + random install_id ONCE, persisted to
// /opt/zapret2/.z2k-relay-id (private key never leaves the device, never in the
// repo/binary). It registers its public key with the relay (/register) and then
// authenticates the tunnel with a per-install signature instead of the shared
// secret. Клиент переходит на персональную аутентификацию ТОЛЬКО после удачной
// регистрации; пока она не прошла, он пользуется общим секретом — поэтому
// порядок раскатки не ломает телеграм (релей без /register => регистрация не
// удаётся => клиент остаётся на общем секрете).
//
// ОБРАТНОГО ХОДА НЕТ. Здесь говорилось «falls back to shared-secret auth on
// repeated failure», и это перестало быть правдой: откат убран (tunnel.go,
// ветка про --require-per-install). useID выставляется в true один раз и
// никогда не сбрасывается. Причина в самом релее: с включённым требованием
// персональной аутентификации он общий секрет отвергает молча, и откат
// превращал поправимую заминку в гарантированно мёртвый туннель. Вместо
// отката при череде быстрых обрывов идёт повторная регистрация.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

type relayIdentity struct {
	InstallID string `json:"install_id"` // 16 bytes hex (32 chars)
	Priv      string `json:"priv"`       // base64(std) Ed25519 private key
	Pub       string `json:"pub"`        // base64(std) Ed25519 public key
	priv      ed25519.PrivateKey
}

// loadOrMintIdentity loads the identity file, minting it exactly ONCE if absent
// or corrupt. Mint-once matters on flash-constrained routers (write-wear) and for
// identity stability — never rewrite a valid file.
func loadOrMintIdentity(path string) (*relayIdentity, error) {
	if data, err := os.ReadFile(path); err == nil {
		var id relayIdentity
		if json.Unmarshal(data, &id) == nil && validInstallIDClient(id.InstallID) {
			if pk, e := base64.StdEncoding.DecodeString(id.Priv); e == nil && len(pk) == ed25519.PrivateKeySize {
				id.priv = ed25519.PrivateKey(pk)
				return &id, nil
			}
		}
		log.Printf("[tunnel] identity file %s invalid — re-minting", path)
	}

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	var idb [16]byte
	if _, err := rand.Read(idb[:]); err != nil {
		return nil, err
	}
	id := &relayIdentity{
		InstallID: hex.EncodeToString(idb[:]),
		Priv:      base64.StdEncoding.EncodeToString(priv),
		Pub:       base64.StdEncoding.EncodeToString(pub),
		priv:      priv,
	}
	out, _ := json.Marshal(id)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, out, 0o600); err != nil {
		return nil, err
	}
	if err := os.Rename(tmp, path); err != nil {
		return nil, err
	}
	log.Printf("[tunnel] minted per-install identity %s", id.InstallID)
	return id, nil
}

// authPayload builds the muxAUTHID (0x06) frame payload:
//
//	[install_id:16][timestamp:8 BE unix][ed25519 sig:64]   (88 bytes)
//
// signed message = install_id(16) || timestamp(8).
func (id *relayIdentity) authPayload() []byte {
	idb, _ := hex.DecodeString(id.InstallID)
	buf := make([]byte, 24, 88)
	copy(buf[0:16], idb)
	binary.BigEndian.PutUint64(buf[16:24], uint64(time.Now().Unix()))
	sig := ed25519.Sign(id.priv, buf)
	return append(buf, sig...)
}

// register POSTs {install_id, pubkey} to the relay's /register, authenticated
// with the shared secret (the relay also dual-accepts the previous secret).
// Idempotent and best-effort.
func (id *relayIdentity) register(registerURL, secret string) error {
	body, _ := json.Marshal(map[string]string{"install_id": id.InstallID, "pubkey": id.Pub})
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	req, err := http.NewRequest(http.MethodPost, registerURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Z2K-Auth", hex.EncodeToString(mac.Sum(nil)))
	cl := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			// Force IPv4 — IPv6 to Cloudflare is unstable on some ISPs (mirrors
			// the WS dialer).
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp4", addr)
			},
		},
	}
	resp, err := cl.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// 409 — релей уже знает этот install_id, но под ДРУГИМ ключом (mint-once,
	// vps-relay/registry.go). Такое бывает, когда файл личности пересоздали, а
	// идентификатор остался прежним. Повторять бесполезно: ответ не изменится
	// никогда, и установка запирается навсегда — туннель не поднимется, потому
	// что релей требует персональную аутентификацию. Отдаём отдельную ошибку,
	// чтобы вызывающий перевыпустил личность целиком.
	if resp.StatusCode == http.StatusConflict {
		return errIdentityTaken
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("register status %d", resp.StatusCode)
	}
	return nil
}

// errIdentityTaken — идентификатор занят другим ключом; лечится только
// перевыпуском личности, повторные попытки с тем же ключом бессмысленны.
var errIdentityTaken = errors.New("install_id taken by another key")

// errNotRegistered — личность ещё не зарегистрирована на релее. Не ошибка
// сети и не повод для паники: identityLoop крутится параллельно и повторяет
// регистрацию. Подключаться до неё нечем — общий секрет релей отвергает.
var errNotRegistered = errors.New("identity not registered yet")

// reMintIdentity удаляет файл личности и создаёт новую пару.
//
// Нужно ровно для одного случая: релей ответил 409. loadOrMintIdentity сам
// перевыпускает личность, только если файл ИСПОРЧЕН, а исправный файл с
// занятым идентификатором для него выглядит нормальным — и клиент застревает.
func reMintIdentity(path string) (*relayIdentity, error) {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	return loadOrMintIdentity(path)
}

// deriveRegisterURL maps the tunnel WS URL to the register HTTPS URL:
//
//	wss://host/ws  ->  https://host/register
func deriveRegisterURL(tunnelURL string) string {
	u := tunnelURL
	u = strings.Replace(u, "wss://", "https://", 1)
	u = strings.Replace(u, "ws://", "http://", 1)
	if strings.HasSuffix(u, "/ws") {
		return strings.TrimSuffix(u, "/ws") + "/register"
	}
	return strings.TrimRight(u, "/") + "/register"
}

func validInstallIDClient(s string) bool {
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
