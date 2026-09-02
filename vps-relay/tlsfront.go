package main

import (
	"context"
	"crypto/tls"
	"fmt"
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
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second, TLSConfig: cfg}
	return &tlsFront{srv: srv, ln: tls.NewListener(ln, cfg)}
}

func (f *tlsFront) serve() error { return f.srv.Serve(f.ln) }

func (f *tlsFront) shutdown(ctx context.Context) error { return f.srv.Shutdown(ctx) }
