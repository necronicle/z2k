package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"golang.org/x/crypto/acme/autocert"
)

// tlsFront — TLS-слушатель релея за nginx (спека §5.1). nginx разводит по
// SNI и шлёт PROXY-заголовок; мы терминируем TLS сами, сертификат ведёт
// autocert через TLS-ALPN-01 — вызов приходит тем же SNI-маршрутом, что и
// клиенты. Только TLS 1.2+, http/1.1 (WebSocket) и acme-tls/1.
type tlsFront struct {
	srv *http.Server
	ln  net.Listener
	mgr *autocert.Manager
}

func newTLSFront(handler http.Handler, addr, host, cache, email string) (*tlsFront, error) {
	if host == "" || cache == "" {
		return nil, fmt.Errorf("tls-front: нужны --acme-host и --acme-cache")
	}
	mgr := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		HostPolicy: autocert.HostWhitelist(host),
		Cache:      autocert.DirCache(cache),
		Email:      email,
	}
	cfg := mgr.TLSConfig()
	cfg.MinVersion = tls.VersionTLS12
	cfg.NextProtos = []string{"http/1.1", "acme-tls/1"}
	raw, err := listenReusePort("tcp", addr)
	if err != nil {
		return nil, err
	}
	f := tlsFrontWithConfig(handler, newProxyListener(raw), cfg)
	f.mgr = mgr
	return f, nil
}

// tlsFrontWithConfig — без autocert: тесты подставляют свой сертификат.
func tlsFrontWithConfig(handler http.Handler, ln net.Listener, cfg *tls.Config) *tlsFront {
	srv := &http.Server{
		Handler: handler, ReadHeaderTimeout: 10 * time.Second, TLSConfig: cfg,
		ErrorLog: log.New(&handshakeNoiseFilter{}, "", 0),
	}
	return &tlsFront{srv: srv, ln: tls.NewListener(ln, cfg)}
}

// handshakeNoiseFilter — «http: TLS handshake error … EOF» от сканеров и
// клиентов, закрывших соединение на полпути: 16 строк в минуту сразу после
// переключения (02.09.2026). Считаем в метрику, в журнал не пишем; всё
// остальное от http.Server идёт в обычный лог.
type handshakeNoiseFilter struct{}

func (handshakeNoiseFilter) Write(p []byte) (int, error) {
	if bytes.Contains(p, []byte("TLS handshake error")) {
		metrics.inc("relay_tls_handshake_errors_total", "")
		return len(p), nil
	}
	log.Printf("%s", bytes.TrimRight(p, "\n"))
	return len(p), nil
}

func (f *tlsFront) serve() error { return f.srv.Serve(f.ln) }

func (f *tlsFront) shutdown(ctx context.Context) error { return f.srv.Shutdown(ctx) }
