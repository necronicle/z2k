package wg

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
)

const (
	// handshakeWait — сколько Open ждёт первый handshake.
	handshakeWait = 5 * time.Second
	// staleAfter — handshake старше этого = сессия не живая (WG
	// перехэндшейкается каждые ~2 мин при трафике; 180 с — с запасом).
	staleAfter = 180 * time.Second
	keepalive  = 25
)

// Transport — WireGuard-сессия поверх wireguard-go/device с reserved-Bind.
type Transport struct {
	dev  *device.Device
	logf func(string, ...any)
	ep   string

	mu     sync.Mutex
	closed bool
}

// New собирает транспорт на tunDev к host:port; сессия ещё не открыта.
func New(tunDev tun.Device, d *account.Device, host string, port int, logf func(string, ...any)) (*Transport, error) {
	reserved, err := d.Reserved()
	if err != nil {
		return nil, err
	}
	if host == "" {
		host = d.Endpoint.V4
	}
	cfg, err := ipcConfig(d.PrivateKey, d.PeerKey, host, port)
	if err != nil {
		return nil, err
	}
	if logf == nil {
		logf = func(string, ...any) {}
	}
	bind := NewReservedBind(conn.NewDefaultBind(), reserved)
	dev := device.NewDevice(tunDev, bind, &device.Logger{
		Verbosef: func(string, ...any) {},
		Errorf:   logf,
	})
	if err := dev.IpcSet(cfg); err != nil {
		dev.Close()
		return nil, fmt.Errorf("wg config: %w", err)
	}
	return &Transport{dev: dev, logf: logf, ep: fmt.Sprintf("%s:%d", host, port)}, nil
}

// Open поднимает устройство и ждёт handshake.
func (t *Transport) Open(ctx context.Context) error {
	if err := t.dev.Up(); err != nil {
		return err
	}
	deadline := time.Now().Add(handshakeWait)
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		if h := t.Health(); h.Connected {
			t.logf("wg: handshake ok %s", t.ep)
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
			if time.Now().After(deadline) {
				return transport.ErrNoHandshake
			}
		}
	}
}

// Health читает счётчики из IpcGet.
func (t *Transport) Health() transport.Health {
	t.mu.Lock()
	closed := t.closed
	t.mu.Unlock()
	if closed {
		return transport.Health{Err: errors.New("closed")}
	}
	s, err := t.dev.IpcGet()
	if err != nil {
		return transport.Health{Err: err}
	}
	return parseHealth(s, time.Now())
}

// Close останавливает устройство. TUN закрывает device.Close().
func (t *Transport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	t.mu.Unlock()
	t.dev.Close()
	return nil
}

// Endpoint — "ip:port" для статуса.
func (t *Transport) Endpoint() string { return t.ep }

func parseHealth(ipc string, now time.Time) transport.Health {
	var h transport.Health
	for _, line := range strings.Split(ipc, "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "last_handshake_time_sec":
			if sec, err := strconv.ParseInt(v, 10, 64); err == nil && sec > 0 {
				h.LastHandshake = time.Unix(sec, 0)
			}
		case "rx_bytes":
			h.Rx, _ = strconv.ParseUint(v, 10, 64)
		case "tx_bytes":
			h.Tx, _ = strconv.ParseUint(v, 10, 64)
		}
	}
	h.Connected = !h.LastHandshake.IsZero() && now.Sub(h.LastHandshake) < staleAfter
	return h
}

func ipcConfig(privB64, peerB64, host string, port int) (string, error) {
	priv, err := base64.StdEncoding.DecodeString(privB64)
	if err != nil || len(priv) != 32 {
		return "", errors.New("bad private key")
	}
	peer, err := base64.StdEncoding.DecodeString(peerB64)
	if err != nil || len(peer) != 32 {
		return "", errors.New("bad peer key")
	}
	if host == "" || port <= 0 {
		return "", errors.New("no endpoint")
	}
	return fmt.Sprintf("private_key=%s\nreplace_peers=true\npublic_key=%s\nendpoint=%s:%d\nallowed_ip=0.0.0.0/0\npersistent_keepalive_interval=%d\n",
		hex.EncodeToString(priv), hex.EncodeToString(peer), host, port, keepalive), nil
}
