package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"log"
	"math/big"
	"net"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func selfSigned(t *testing.T, host string) tls.Certificate {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: host}, DNSNames: []string{host},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// TLS-фронт за PROXY-заголовком: адрес клиента в событиях — из заголовка,
// рукопожатие v2 работает поверх TLS как поверх plain.
func TestTLSFront_ProxyHeaderGivesClientIP(t *testing.T) {
	m := withMemEvents(t)
	startFakeDC(t, echoDC)
	const host = "213.176.74.63.nip.io"
	cert := selfSigned(t, host)
	cfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1", "acme-tls/1"}}
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) { handleWS(ctx, w, r) })
	front := tlsFrontWithConfig(mux, newProxyListener(raw), cfg)
	go front.serve()
	t.Cleanup(func() {
		cancel()
		front.shutdown(context.Background())
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			n := 0
			forEachSession(func(s *session) { n++; s.killWith("test_cleanup") })
			if n == 0 {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
	})

	tcp, err := net.Dial("tcp", raw.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tcp.Write([]byte("PROXY TCP4 46.146.27.195 127.0.0.1 40000 8445\r\n")); err != nil {
		t.Fatal(err)
	}
	tlsConn := tls.Client(tcp, &tls.Config{ServerName: host, InsecureSkipVerify: true, NextProtos: []string{"http/1.1"}})
	if err := tlsConn.Handshake(); err != nil {
		t.Fatal(err)
	}
	if got := tlsConn.ConnectionState().NegotiatedProtocol; got != "http/1.1" {
		t.Fatalf("ALPN %q", got)
	}
	ws, _, err := websocket.NewClient(tlsConn, mustURL("ws://"+host+"/ws"), nil, 4096, 4096)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.Close() })
	id, priv := testInstall(t)
	handshakeV2Over(t, ws, id, priv, "r-82")
	sendFrame(t, ws, 1, muxCONNECT, connectPayload(tgTarget, 443))
	expectFrame(t, ws, 1, muxCONNECT_OK, 2*time.Second)
	if !m.wait("session_open", 1, 2*time.Second) {
		t.Fatal("нет session_open")
	}
	if ip := m.byEv("session_open")[0].IP; ip != "46.146.27.195" {
		t.Fatalf("ip в событии %q, ожидался адрес из PROXY-заголовка", ip)
	}
}

// Обрыв на середине TLS-рукопожатия не пишется в журнал, а считается.
func TestTLSFront_HandshakeNoiseCounted(t *testing.T) {
	cert := selfSigned(t, "x.nip.io")
	cfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	front := tlsFrontWithConfig(http.NewServeMux(), newProxyListener(raw), cfg)
	go front.serve()
	t.Cleanup(func() { front.shutdown(context.Background()) })
	buf := &syncBuffer{}
	prev := log.Writer()
	log.SetOutput(buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	before := metricValue("relay_tls_handshake_errors_total")
	c, err := net.Dial("tcp", raw.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c.Write([]byte("PROXY TCP4 1.2.3.4 127.0.0.1 1 2\r\n\x16\x03\x01\x00\x05\x01\x00\x00\x01\x00"))
	c.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && metricValue("relay_tls_handshake_errors_total") == before {
		time.Sleep(10 * time.Millisecond)
	}
	if metricValue("relay_tls_handshake_errors_total") == before {
		t.Fatal("ошибка рукопожатия не посчитана")
	}
	if strings.Contains(buf.String(), "TLS handshake error") {
		t.Fatal("шум рукопожатия попал в журнал")
	}
}

func metricValue(name string) int64 {
	var b bytes.Buffer
	metrics.write(&b)
	for _, ln := range strings.Split(b.String(), "\n") {
		if strings.HasPrefix(ln, name+" ") {
			v, _ := strconv.ParseInt(strings.TrimPrefix(ln, name+" "), 10, 64)
			return v
		}
	}
	return 0
}
