package h2

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
	"golang.zx2c4.com/wireguard/tun"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
)

// Провод Cloudflare (снято с официального клиента, не из RFC):
//   - TLS к эндпоинту с SNI consumer-masque.cloudflareclient.com, ALPN h2,
//     клиентский сертификат — самоподписанный от P-256 ключа регистрации;
//     серверный сертификат не валидируется по цепочке, а пинится по
//     публичному ключу пира из регистрации;
//   - запрос — обычный CONNECT на https://cloudflareaccess.com с заголовками
//     cf-connect-proto: cf-connect-ip и pq-enabled: false;
//   - дальше в обе стороны идут DATAGRAM-капсулы (capsule.go).
const (
	sni         = "consumer-masque.cloudflareclient.com"
	connectURL  = "https://cloudflareaccess.com"
	port        = 443
	dialTimeout = 8 * time.Second
	// tunOffset — запас перед пакетом для заголовка virtio (Linux TUN с
	// offload'ом требует ≥10 байт); 16 — как у wireguard-go.
	tunOffset = 16
	bufSize   = 65536 + tunOffset
	batch     = 8
)

// Transport — одна CONNECT-IP сессия поверх HTTP/2.
type Transport struct {
	tun  tun.Device
	d    *account.Device
	logf func(string, ...any)
	ep   string

	mu        sync.Mutex
	closed    bool
	connected time.Time
	err       error
	cancel    context.CancelFunc
	reqBody   *io.PipeWriter
	respBody  io.ReadCloser
	conn      net.Conn
	rx, tx    atomic.Uint64
}

// New готовит транспорт; нужен H2-ключ в device.json (SwitchTunnel masque).
func New(tunDev tun.Device, d *account.Device, logf func(string, ...any)) (*Transport, error) {
	if d.H2 == nil || d.H2.PrivateKey == "" {
		return nil, errors.New("h2: no masque key in device.json")
	}
	if logf == nil {
		logf = func(string, ...any) {}
	}
	host := d.Endpoint.H2
	if host == "" {
		host = account.DefaultH2Endpoint
	}
	return &Transport{tun: tunDev, d: d, logf: logf, ep: fmt.Sprintf("%s:%d", host, port)}, nil
}

func (t *Transport) tlsConfig() (*tls.Config, error) {
	priv, err := account.ECPrivateKey(t.d.H2.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("h2 key: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(0),
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return nil, fmt.Errorf("h2 cert: %w", err)
	}
	cfg := &tls.Config{
		Certificates:       []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: priv}},
		ServerName:         sni,
		NextProtos:         []string{"h2"},
		InsecureSkipVerify: true, // SNI не совпадает с эндпоинтом; доверие — пиннинг ниже
	}
	if pin := t.pinnedKey(); pin != nil {
		cfg.VerifyPeerCertificate = func(raw [][]byte, _ [][]*x509.Certificate) error {
			if len(raw) == 0 {
				return errors.New("no server certificate")
			}
			cert, err := x509.ParseCertificate(raw[0])
			if err != nil {
				return err
			}
			got, ok := cert.PublicKey.(*ecdsa.PublicKey)
			if !ok || !got.Equal(pin) {
				return errors.New("endpoint key does not match registration")
			}
			return nil
		}
	} else {
		t.logf("h2: no peer key in registration — TLS pinning off")
	}
	return cfg, nil
}

// pinnedKey разбирает публичный ключ эндпоинта. Для MASQUE регистрация
// отдаёт его PEM-блоком; на всякий случай принимаем и голый base64-DER.
func (t *Transport) pinnedKey() *ecdsa.PublicKey {
	raw := t.d.H2.PeerKey
	var der []byte
	if block, _ := pem.Decode([]byte(raw)); block != nil {
		der = block.Bytes
	} else {
		var err error
		if der, err = base64.StdEncoding.DecodeString(raw); err != nil {
			return nil
		}
	}
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil
	}
	k, _ := pub.(*ecdsa.PublicKey)
	return k
}

// Open устанавливает TLS+HTTP/2 и CONNECT; возвращается после 2xx.
func (t *Transport) Open(ctx context.Context) error {
	cfg, err := t.tlsConfig()
	if err != nil {
		return err
	}
	dctx, cancelDial := context.WithTimeout(ctx, dialTimeout)
	defer cancelDial()
	raw, err := (&net.Dialer{}).DialContext(dctx, "tcp", t.ep)
	if err != nil {
		return fmt.Errorf("h2 dial: %w", err)
	}
	tconn := tls.Client(raw, cfg)
	if err := tconn.HandshakeContext(dctx); err != nil {
		raw.Close()
		return fmt.Errorf("h2 tls: %w", err)
	}
	cc, err := (&http2.Transport{}).NewClientConn(tconn)
	if err != nil {
		tconn.Close()
		return err
	}
	pr, pw := io.Pipe()
	rctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(rctx, http.MethodConnect, connectURL, pr)
	req.ContentLength = -1
	req.Header = http.Header{
		"Cf-Connect-Proto": {"cf-connect-ip"},
		"Pq-Enabled":       {"false"},
		"User-Agent":       {""},
	}
	resp, err := cc.RoundTrip(req)
	if err != nil {
		cancel()
		pw.Close()
		tconn.Close()
		return fmt.Errorf("h2 connect: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		cancel()
		pw.Close()
		resp.Body.Close()
		tconn.Close()
		return fmt.Errorf("h2 connect: HTTP %d", resp.StatusCode)
	}
	t.mu.Lock()
	t.cancel, t.reqBody, t.respBody, t.conn = cancel, pw, resp.Body, tconn
	t.connected = time.Now()
	t.err = nil
	t.mu.Unlock()
	t.logf("h2: connected %s", t.ep)
	go t.pumpOut(pw)
	go t.pumpIn(resp.Body)
	return nil
}

// pumpOut: TUN → капсулы → тело запроса.
func (t *Transport) pumpOut(w io.Writer) {
	bufs := make([][]byte, batch)
	for i := range bufs {
		bufs[i] = make([]byte, bufSize)
	}
	sizes := make([]int, batch)
	for {
		n, err := t.tun.Read(bufs, sizes, tunOffset)
		if err != nil {
			t.fail(fmt.Errorf("tun read: %w", err))
			return
		}
		for i := 0; i < n; i++ {
			if sizes[i] == 0 {
				continue
			}
			if _, err := w.Write(EncodeDatagram(bufs[i][tunOffset : tunOffset+sizes[i]])); err != nil {
				t.fail(fmt.Errorf("h2 send: %w", err))
				return
			}
			t.tx.Add(uint64(sizes[i]))
		}
	}
}

// pumpIn: тело ответа → капсулы → TUN.
func (t *Transport) pumpIn(r io.Reader) {
	dec := NewDecoder(r)
	out := make([]byte, bufSize)
	for {
		pkt, err := dec.Next()
		if err != nil {
			t.fail(fmt.Errorf("h2 recv: %w", err))
			return
		}
		n := copy(out[tunOffset:], pkt)
		if _, err := t.tun.Write([][]byte{out[:tunOffset+n]}, tunOffset); err != nil {
			t.fail(fmt.Errorf("tun write: %w", err))
			return
		}
		t.rx.Add(uint64(n))
	}
}

func (t *Transport) fail(err error) {
	t.mu.Lock()
	if t.err == nil && !t.closed {
		t.err = err
		t.logf("h2: %v", err)
	}
	t.mu.Unlock()
}

// Health — сессия жива, пока ни один насос не упал.
func (t *Transport) Health() transport.Health {
	t.mu.Lock()
	defer t.mu.Unlock()
	h := transport.Health{Rx: t.rx.Load(), Tx: t.tx.Load(), Err: t.err, LastHandshake: t.connected}
	h.Connected = !t.closed && t.err == nil && !t.connected.IsZero()
	return h
}

// Close рвёт стрим и соединение. TUN не закрывает — им владеет движок.
func (t *Transport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	cancel, pw, rb, conn := t.cancel, t.reqBody, t.respBody, t.conn
	t.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if pw != nil {
		pw.Close()
	}
	if rb != nil {
		rb.Close()
	}
	if conn != nil {
		conn.Close()
	}
	return nil
}

// Endpoint — "ip:port" для статуса.
func (t *Transport) Endpoint() string { return t.ep }
