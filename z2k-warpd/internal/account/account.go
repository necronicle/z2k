// Package account — регистрация устройства в Cloudflare WARP и device.json.
//
// Протокол — Cloudflare'а: POST /reg заводит устройство по публичному ключу
// X25519, PATCH включает warp_enabled (без него туннель не несёт TCP), GET
// перечитывает эндпоинт и порты, которые Cloudflare вправе менять. device.json
// живёт в /opt/etc/z2k-warp/ и переживает и реинсталл z2k, и «Удалить»:
// повторная установка не должна сжигать новое устройство.
package account

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/crypto/curve25519"
)

const (
	// DefaultBaseURL — API регистрации. Десинкается nfqws2 как любой трафик роутера.
	DefaultBaseURL = "https://api.cloudflareclient.com"
	apiPath        = "/v0a4471"
	clientVersion  = "a-6.35-4471"
	userAgent      = "WARP for Android"

	// Типы ключа/туннеля в API. У одного устройства активен ровно один ключ:
	// переход на MASQUE — это PATCH того же устройства, не второе устройство.
	KeyTypeWG     = "curve25519"
	TunnelWG      = "wireguard"
	KeyTypeMasque = "secp256r1"
	TunnelMasque  = "masque"

	// DefaultH2Endpoint — MASQUE-over-HTTP/2 эндпоинт; регистрация его не
	// отдаёт, значение снято с официального клиента.
	DefaultH2Endpoint = "162.159.198.2"
)

// ErrRevoked — устройство больше не известно Cloudflare (401/403/404 на GET).
var ErrRevoked = errors.New("device revoked")

// Endpoint — куда подключаться. Ports — запасные UDP-порты WireGuard из регистрации.
type Endpoint struct {
	V4    string `json:"v4"`
	H2    string `json:"h2,omitempty"`
	Ports []int  `json:"ports"`
}

// Step — транспорт и порт; используется лестницей и как last_good.
type Step struct {
	Transport string `json:"transport"`
	Port      int    `json:"port"`
}

// H2Key — ключ EC P-256 для MASQUE-h2 (DER, base64) и публичный ключ
// эндпоинта для пиннинга TLS. Появляется лениво, когда лестница дошла до h2.
type H2Key struct {
	PrivateKey string `json:"private_key"`
	PeerKey    string `json:"peer_key,omitempty"`
}

// Device — содержимое device.json.
type Device struct {
	PrivateKey string   `json:"private_key"`
	ID         string   `json:"id"`
	Token      string   `json:"token"`
	ClientID   string   `json:"client_id"`
	AddrV4     string   `json:"addr_v4"`
	AddrV6     string   `json:"addr_v6,omitempty"`
	PeerKey    string   `json:"peer_key"`
	Endpoint   Endpoint `json:"endpoint"`
	Tunnel     string   `json:"tunnel"` // какой ключ сейчас активен у Cloudflare: wireguard | masque
	Iface      string   `json:"iface,omitempty"`
	LastGood   *Step    `json:"last_good,omitempty"`
	H2         *H2Key   `json:"h2,omitempty"`
}

// Client — HTTP-клиент API регистрации.
type Client struct {
	BaseURL string
	HTTP    *http.Client
}

func (c *Client) do(ctx context.Context, method, path, token string, body any) (*http.Response, error) {
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			return nil, err
		}
	}
	base := c.BaseURL
	if base == "" {
		base = DefaultBaseURL
	}
	req, err := http.NewRequestWithContext(ctx, method, base+apiPath+path, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("CF-Client-Version", clientVersion)
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	h := c.HTTP
	if h == nil {
		h = &http.Client{Timeout: 20 * time.Second}
	}
	return h.Do(req)
}

type regResp struct {
	ID          string `json:"id"`
	Token       string `json:"token"`
	WarpEnabled bool   `json:"warp_enabled"`
	Config      struct {
		ClientID  string `json:"client_id"`
		Interface struct {
			Addresses struct {
				V4 string `json:"v4"`
				V6 string `json:"v6"`
			} `json:"addresses"`
		} `json:"interface"`
		Peers []struct {
			PublicKey string `json:"public_key"`
			Endpoint  struct {
				V4    string `json:"v4"`
				Host  string `json:"host"`
				Ports []int  `json:"ports"`
			} `json:"endpoint"`
		} `json:"peers"`
	} `json:"config"`
}

// apply переносит ответ API в Device. ID/Token берутся только если заполнены
// (GET отдаёт их тоже, но перезаписывать нечем и незачем).
func (r *regResp) apply(d *Device) error {
	if len(r.Config.Peers) == 0 {
		return errors.New("registration has no peers")
	}
	p := r.Config.Peers[0]
	if r.ID != "" && d.ID == "" {
		d.ID, d.Token = r.ID, r.Token
	}
	d.ClientID = r.Config.ClientID
	d.AddrV4 = r.Config.Interface.Addresses.V4
	d.AddrV6 = r.Config.Interface.Addresses.V6
	d.PeerKey = p.PublicKey
	host := p.Endpoint.V4
	if i := strings.LastIndex(host, ":"); i > 0 {
		host = host[:i]
	}
	d.Endpoint.V4 = host
	d.Endpoint.Ports = p.Endpoint.Ports
	return nil
}

func genKey() (string, error) {
	var priv [32]byte
	if _, err := rand.Read(priv[:]); err != nil {
		return "", err
	}
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64
	return base64.StdEncoding.EncodeToString(priv[:]), nil
}

func pubOf(privB64 string) (string, error) {
	priv, err := base64.StdEncoding.DecodeString(privB64)
	if err != nil || len(priv) != 32 {
		return "", errors.New("bad private key")
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}

func genECKey() (string, error) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", err
	}
	der, err := x509.MarshalECPrivateKey(k)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

// ECPrivateKey разбирает H2-ключ.
func ECPrivateKey(b64 string) (*ecdsa.PrivateKey, error) {
	der, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, err
	}
	return x509.ParseECPrivateKey(der)
}

func ecPubOf(privB64 string) (string, error) {
	k, err := ECPrivateKey(privB64)
	if err != nil {
		return "", err
	}
	der, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

// Register заводит новое устройство (POST /reg) и включает warp (PATCH).
func (c *Client) Register(ctx context.Context) (*Device, error) {
	priv, err := genKey()
	if err != nil {
		return nil, err
	}
	pub, err := pubOf(priv)
	if err != nil {
		return nil, err
	}
	body := map[string]any{
		"key": pub, "install_id": "", "fcm_token": "",
		"tos":   time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		"model": "PC", "serial_number": "", "os_version": "", "locale": "en_US",
		"key_type": KeyTypeWG, "tunnel_type": TunnelWG,
	}
	resp, err := c.do(ctx, "POST", "/reg", "", body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("register: HTTP %d", resp.StatusCode)
	}
	var r regResp
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, err
	}
	d := &Device{PrivateKey: priv, Tunnel: TunnelWG}
	if err := r.apply(d); err != nil {
		return nil, err
	}
	if d.ID == "" || d.Token == "" {
		return nil, errors.New("register: response without id/token")
	}
	if !r.WarpEnabled {
		if err := c.enableWarp(ctx, d); err != nil {
			return nil, err
		}
	}
	return d, nil
}

func (c *Client) enableWarp(ctx context.Context, d *Device) error {
	resp, err := c.do(ctx, "PATCH", "/reg/"+d.ID, d.Token, map[string]any{"warp_enabled": true})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("enable warp: HTTP %d", resp.StatusCode)
	}
	return nil
}

// Refresh перечитывает регистрацию: эндпоинт, порты, адрес могут меняться.
// Ключ и идентичность устройства не трогает.
func (c *Client) Refresh(ctx context.Context, d *Device) error {
	resp, err := c.do(ctx, "GET", "/reg/"+d.ID, d.Token, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case 200:
	case 401, 403, 404:
		return ErrRevoked
	default:
		return fmt.Errorf("refresh: HTTP %d", resp.StatusCode)
	}
	var r regResp
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return err
	}
	return r.apply(d)
}

// SwitchTunnel переключает ключ устройства: masque — на H2-ключ (генерируется,
// если его нет), wireguard — обратно на X25519. Ответ обновляет эндпоинт и
// публичный ключ пира.
func (c *Client) SwitchTunnel(ctx context.Context, d *Device, tunnel string) error {
	var body map[string]any
	switch tunnel {
	case TunnelWG:
		pub, err := pubOf(d.PrivateKey)
		if err != nil {
			return err
		}
		body = map[string]any{"key": pub, "key_type": KeyTypeWG, "tunnel_type": TunnelWG}
	case TunnelMasque:
		if d.H2 == nil || d.H2.PrivateKey == "" {
			priv, err := genECKey()
			if err != nil {
				return err
			}
			d.H2 = &H2Key{PrivateKey: priv}
		}
		pub, err := ecPubOf(d.H2.PrivateKey)
		if err != nil {
			return err
		}
		body = map[string]any{"key": pub, "key_type": KeyTypeMasque, "tunnel_type": TunnelMasque}
	default:
		return fmt.Errorf("unknown tunnel %q", tunnel)
	}
	resp, err := c.do(ctx, "PATCH", "/reg/"+d.ID, d.Token, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case 200:
	case 401, 403, 404:
		return ErrRevoked
	default:
		return fmt.Errorf("switch tunnel: HTTP %d", resp.StatusCode)
	}
	var r regResp
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return err
	}
	if err := r.apply(d); err != nil {
		return err
	}
	d.Tunnel = tunnel
	if tunnel == TunnelMasque {
		d.H2.PeerKey = d.PeerKey
	}
	return nil
}

// Reserved — три байта client_id, которые несёт заголовок каждого WG-пакета.
func (d *Device) Reserved() ([3]byte, error) {
	var r [3]byte
	b, err := base64.StdEncoding.DecodeString(d.ClientID)
	if err != nil || len(b) < 3 {
		return r, errors.New("bad client_id")
	}
	copy(r[:], b[:3])
	return r, nil
}

// Load читает device.json.
func Load(path string) (*Device, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var d Device
	if err := json.Unmarshal(b, &d); err != nil {
		return nil, err
	}
	return &d, nil
}

// Save пишет атомарно (tmp + rename), режим 0600.
func (d *Device) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
