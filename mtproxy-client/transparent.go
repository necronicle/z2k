package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

// DNS cache to survive temporary resolver failures.
var (
	dnsCache    sync.Map // domain → *dnsCacheEntry
	dnsCacheTTL = 5 * time.Minute
)

type dnsCacheEntry struct {
	ip string
	ts time.Time
}

func resolveIPv4Cached(host string) (string, error) {
	// Check cache
	if val, ok := dnsCache.Load(host); ok {
		entry := val.(*dnsCacheEntry)
		if time.Since(entry.ts) < dnsCacheTTL {
			return entry.ip, nil
		}
	}

	// Try resolving
	newIP, err := resolveIPv4(host)
	if err != nil {
		// DNS failed — use stale cache if available
		if val, ok := dnsCache.Load(host); ok {
			entry := val.(*dnsCacheEntry)
			if *verbose {
				log.Printf("[debug] DNS failed for %s, using cached %s", host, entry.ip)
			}
			return entry.ip, nil
		}
		return "", err
	}

	// Update cache atomically
	dnsCache.Store(host, &dnsCacheEntry{ip: newIP, ts: time.Now()})
	return newIP, nil
}

// handleTransparent redirects intercepted Telegram traffic through
// Cloudflare WebSocket without any encryption/decryption.
func handleTransparent(ctx context.Context, clientConn *net.TCPConn) {
	defer clientConn.Close()
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[panic] %s: %v", clientConn.RemoteAddr(), r)
		}
	}()

	origIP, _, err := getOriginalDst(clientConn)
	if err != nil {
		return
	}

	dc := LookupDC(origIP)
	isMedia := false

	if *verbose {
		log.Printf("[conn] %s -> DC%d (%s)", clientConn.RemoteAddr(), dc, origIP)
	}

	// Set initial deadline
	clientConn.SetDeadline(time.Now().Add(*connTimeout))

	// Connect via WebSocket with retry
	var ws *websocket.Conn
	for attempt := 0; attempt < 3; attempt++ {
		ws, err = connectWSTransparent(int(dc), isMedia)
		if err == nil {
			break
		}
		if attempt < 2 {
			time.Sleep(500 * time.Millisecond)
		}
	}
	if err != nil {
		if *verbose {
			log.Printf("[error] WS DC%d: %v", dc, err)
		}
		return
	}
	defer ws.Close()

	writer := &wsWriter{ws: ws}

	// Create cancellable context for this connection
	connCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Keepalive: CF kills idle WS after 100s. Ping every 60s.
	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				writer.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
			case <-connCtx.Done():
				return
			}
		}
	}()

	if *verbose {
		log.Printf("[relay] %s <-> WS DC%d", clientConn.RemoteAddr(), dc)
	}

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		defer cancel()
		buf := make([]byte, 65536)
		for {
			select {
			case <-connCtx.Done():
				return
			default:
			}
			n, err := clientConn.Read(buf)
			if n > 0 {
				clientConn.SetDeadline(time.Now().Add(*connTimeout))
				if werr := writer.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
	}()

	go func() {
		defer wg.Done()
		defer cancel()
		for {
			select {
			case <-connCtx.Done():
				return
			default:
			}
			_, msg, err := ws.ReadMessage()
			if err != nil {
				break
			}
			if len(msg) > 0 {
				clientConn.SetDeadline(time.Now().Add(*connTimeout))
				if _, werr := clientConn.Write(msg); werr != nil {
					break
				}
			}
		}
	}()

	wg.Wait()

	if *verbose {
		log.Printf("[done] %s DC%d", clientConn.RemoteAddr(), dc)
	}
}

func connectWSTransparent(dc int, isMedia bool) (*websocket.Conn, error) {
	cfDomain := fmt.Sprintf("kws%d.pclead.co.uk", dc)

	ip, err := resolveIPv4Cached(cfDomain)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", cfDomain, err)
	}

	dialer := websocket.Dialer{
		TLSClientConfig: &tls.Config{
			ServerName: cfDomain,
		},
		HandshakeTimeout: 5 * time.Second,
		Subprotocols:     []string{"binary"},
		NetDial: func(network, addr string) (net.Conn, error) {
			return net.DialTimeout("tcp4", ip+":443", 5*time.Second)
		},
	}
	headers := http.Header{}
	headers.Set("Origin", "http://web.telegram.org")
	headers.Set("Host", cfDomain)

	url := fmt.Sprintf("wss://%s/apiws", cfDomain)
	ws, _, err := dialer.Dial(url, headers)
	if err != nil {
		return nil, fmt.Errorf("dial %s (%s): %w", cfDomain, ip, err)
	}

	// Set read limit to prevent memory exhaustion
	ws.SetReadLimit(1 * 1024 * 1024) // 1MB

	if *verbose {
		log.Printf("[debug] WS connected to %s (%s)", cfDomain, ip)
	}
	return ws, nil
}

// transparentListener runs the transparent proxy mode with graceful shutdown.
func transparentListener(listenAddr string) error {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return err
	}

	// Initialize connection limiter
	connSemaphore = make(chan struct{}, *maxConns)

	// Pre-warm DNS cache for all DCs
	for _, dc := range []int{1, 2, 3, 4, 5} {
		domain := fmt.Sprintf("kws%d.pclead.co.uk", dc)
		if ip, err := resolveIPv4(domain); err == nil {
			dnsCache.Store(domain, &dnsCacheEntry{ip: ip, ts: time.Now()})
			log.Printf("DNS cache: %s -> %s", domain, ip)
		}
	}

	log.Printf("tg-transparent-proxy listening on %s", listenAddr)

	// Graceful shutdown
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Periodic DNS cache refresh
	go func() {
		ticker := time.NewTicker(dnsCacheTTL)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				for _, dc := range []int{1, 2, 3, 4, 5} {
					domain := fmt.Sprintf("kws%d.pclead.co.uk", dc)
					if ip, err := resolveIPv4(domain); err == nil {
						dnsCache.Store(domain, &dnsCacheEntry{ip: ip, ts: time.Now()})
					}
				}
			case <-ctx.Done():
				return
			}
		}
	}()

	go func() {
		<-ctx.Done()
		log.Println("[shutdown] Closing listener...")
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				log.Println("[shutdown] Transparent proxy stopped")
				return nil
			default:
				continue
			}
		}
		tcpConn, ok := conn.(*net.TCPConn)
		if !ok {
			conn.Close()
			continue
		}

		// Rate limit connections
		select {
		case connSemaphore <- struct{}{}:
			go func() {
				defer func() { <-connSemaphore }()
				handleTransparent(ctx, tcpConn)
			}()
		default:
			if *verbose {
				log.Printf("[warn] max connections reached, rejecting %s", conn.RemoteAddr())
			}
			conn.Close()
		}
	}
}
