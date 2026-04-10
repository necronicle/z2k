package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// DNS cache to survive temporary resolver failures.
var (
	dnsCache     = make(map[string]string) // domain → IPv4
	dnsCacheMu   sync.RWMutex
	dnsCacheTTL  = 5 * time.Minute
	dnsCacheTime = make(map[string]time.Time)
)


func resolveIPv4Cached(host string) (string, error) {
	dnsCacheMu.RLock()
	ip, ok := dnsCache[host]
	t := dnsCacheTime[host]
	dnsCacheMu.RUnlock()

	// Return cache if fresh
	if ok && time.Since(t) < dnsCacheTTL {
		return ip, nil
	}

	// Try resolving
	newIP, err := resolveIPv4(host)
	if err != nil {
		// DNS failed — use stale cache if available
		if ok {
			if *verbose {
				log.Printf("[debug] DNS failed for %s, using cached %s", host, ip)
			}
			return ip, nil
		}
		return "", err
	}

	// Update cache
	dnsCacheMu.Lock()
	dnsCache[host] = newIP
	dnsCacheTime[host] = time.Now()
	dnsCacheMu.Unlock()

	return newIP, nil
}

// handleTransparent redirects intercepted Telegram traffic through
// Cloudflare WebSocket without any encryption/decryption.
func handleTransparent(clientConn *net.TCPConn) {
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

	// Keepalive: CF kills idle WS after 100s. Ping every 60s via WriteControl (thread-safe).
	// No SetReadDeadline/SetWriteDeadline — those block data transfer.
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
			case <-done:
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
		buf := make([]byte, 65536)
		for {
			n, err := clientConn.Read(buf)
			if n > 0 {
				if werr := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
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
		for {
			_, msg, err := ws.ReadMessage()
			if err != nil {
				break
			}
			if len(msg) > 0 {
				if _, werr := clientConn.Write(msg); werr != nil {
					break
				}
			}
		}
	}()

	wg.Wait()
	close(done)

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

	if *verbose {
		log.Printf("[debug] WS connected to %s (%s)", cfDomain, ip)
	}
	return ws, nil
}

// transparentListener runs the transparent proxy mode.
func transparentListener(listenAddr string) error {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return err
	}

	// Pre-warm DNS cache for all DCs
	for _, dc := range []int{1, 2, 3, 4, 5} {
		domain := fmt.Sprintf("kws%d.pclead.co.uk", dc)
		if ip, err := resolveIPv4(domain); err == nil {
			dnsCacheMu.Lock()
			dnsCache[domain] = ip
			dnsCacheTime[domain] = time.Now()
			dnsCacheMu.Unlock()
			log.Printf("DNS cache: %s -> %s", domain, ip)
		}
	}

	log.Printf("tg-transparent-proxy listening on %s", listenAddr)

	// Periodic DNS cache refresh
	go func() {
		for {
			time.Sleep(dnsCacheTTL)
			for _, dc := range []int{1, 2, 3, 4, 5} {
				domain := fmt.Sprintf("kws%d.pclead.co.uk", dc)
				if ip, err := resolveIPv4(domain); err == nil {
					dnsCacheMu.Lock()
					dnsCache[domain] = ip
					dnsCacheTime[domain] = time.Now()
					dnsCacheMu.Unlock()
				}
			}
		}
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleTransparent(conn.(*net.TCPConn))
	}
	return nil
}
