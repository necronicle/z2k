package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
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

var (
	listenAddr  = flag.String("listen", ":1443", "Local listen address")
	secretHex   = flag.String("secret", "", "Proxy secret (dd-prefixed hex, auto-generated if empty)")
	transparent = flag.Bool("transparent", false, "Transparent mode: redirect Telegram DC traffic via iptables (no client config needed)")
	verbose     = flag.Bool("v", false, "Verbose logging")
	connTimeout = flag.Duration("timeout", 5*time.Minute, "Idle connection timeout")
	maxConns    = flag.Int("max-conns", 1024, "Maximum concurrent connections")
)

const handshakeLen = 64

// connSemaphore limits concurrent connections
var connSemaphore chan struct{}

// DC WebSocket domains
func wsDomains(dc int, isMedia bool) []string {
	if dc == 203 {
		dc = 2
	}
	if isMedia {
		return []string{
			fmt.Sprintf("kws%d-1.web.telegram.org", dc),
			fmt.Sprintf("kws%d.web.telegram.org", dc),
		}
	}
	return []string{
		fmt.Sprintf("kws%d.web.telegram.org", dc),
		fmt.Sprintf("kws%d-1.web.telegram.org", dc),
	}
}

// tryHandshake decrypts client's obfuscated2 header using proxy secret.
// Returns DC id, isMedia flag, protocol tag, and AES key material.
func tryHandshake(header []byte, secret []byte) (dc int, isMedia bool, protoTag uint32, decKey, decIV, encKey, encIV []byte, err error) {
	if len(header) != handshakeLen {
		return 0, false, 0, nil, nil, nil, nil, fmt.Errorf("header len %d", len(header))
	}

	// Decrypt direction: client→proxy uses header[8:40] as key, header[40:56] as IV
	rawKey := make([]byte, 32)
	copy(rawKey, header[8:40])
	rawIV := make([]byte, 16)
	copy(rawIV, header[40:56])

	// Mix with secret: key = SHA256(rawKey || secret)
	h := sha256.New()
	h.Write(rawKey)
	h.Write(secret)
	decKey = h.Sum(nil)
	decIV = rawIV

	// Decrypt entire header to read protocol tag and DC
	block, cipherErr := aes.NewCipher(decKey)
	if cipherErr != nil {
		return 0, false, 0, nil, nil, nil, nil, fmt.Errorf("aes.NewCipher(decKey): %w", cipherErr)
	}
	stream := cipher.NewCTR(block, decIV)
	decrypted := make([]byte, handshakeLen)
	stream.XORKeyStream(decrypted, header)

	protoTag = binary.LittleEndian.Uint32(decrypted[56:60])
	// Validate protocol tag
	if protoTag != 0xefefefef && protoTag != 0xeeeeeeee && protoTag != 0xdddddddd {
		return 0, false, 0, nil, nil, nil, nil, fmt.Errorf("bad proto tag 0x%08x", protoTag)
	}

	dcIdx := int16(binary.LittleEndian.Uint16(decrypted[60:62]))
	dc = int(dcIdx)
	if dc < 0 {
		dc = -dc
		isMedia = true
	}
	if dc == 0 {
		dc = 2
	}

	// Encrypt direction (proxy→client): reversed header[8:56]
	reversed := make([]byte, 48)
	copy(reversed, header[8:56])
	for i, j := 0, len(reversed)-1; i < j; i, j = i+1, j-1 {
		reversed[i], reversed[j] = reversed[j], reversed[i]
	}
	h2 := sha256.New()
	h2.Write(reversed[:32])
	h2.Write(secret)
	encKey = h2.Sum(nil)
	encIV = reversed[32:48]

	return dc, isMedia, protoTag, decKey, decIV, encKey, encIV, nil
}

// generateRelayInit creates a new obfuscated2 header for connecting to Telegram DC
// (without proxy secret — direct DC connection).
func generateRelayInit(protoTag uint32, dcIdx int) (header []byte, relayEncKey, relayEncIV, relayDecKey, relayDecIV []byte, err error) {
	header = make([]byte, handshakeLen)
	for {
		if _, err := io.ReadFull(rand.Reader, header); err != nil {
			return nil, nil, nil, nil, nil, err
		}
		if header[0] == 0xef {
			continue
		}
		first4 := binary.LittleEndian.Uint32(header[0:4])
		if first4 == 0x44414548 || first4 == 0x54534f50 || first4 == 0x20544547 ||
			first4 == 0x4954504f || first4 == 0x02010316 ||
			first4 == 0xdddddddd || first4 == 0xeeeeeeee {
			continue
		}
		if header[4]|header[5]|header[6]|header[7] == 0 {
			continue
		}
		break
	}

	// Encryption key for relay→DC (our writes to DC)
	relayEncKey = make([]byte, 32)
	copy(relayEncKey, header[8:40])
	relayEncIV = make([]byte, 16)
	copy(relayEncIV, header[40:56])

	// Decryption key for DC→relay (reads from DC): reversed
	reversed := make([]byte, 48)
	copy(reversed, header[8:56])
	for i, j := 0, len(reversed)-1; i < j; i, j = i+1, j-1 {
		reversed[i], reversed[j] = reversed[j], reversed[i]
	}
	relayDecKey = reversed[:32]
	relayDecIV = reversed[32:48]

	// Write protocol tag and DC, encrypt with AES-CTR
	block, cipherErr := aes.NewCipher(relayEncKey)
	if cipherErr != nil {
		return nil, nil, nil, nil, nil, fmt.Errorf("aes.NewCipher(relayEncKey): %w", cipherErr)
	}
	encStream := cipher.NewCTR(block, relayEncIV)
	encrypted := make([]byte, handshakeLen)
	encStream.XORKeyStream(encrypted, header)

	// Build tail: protocol_tag + dc_bytes + 2 random bytes
	tail := make([]byte, 8)
	binary.LittleEndian.PutUint32(tail[0:4], protoTag)
	binary.LittleEndian.PutUint16(tail[4:6], uint16(int16(dcIdx)))
	if _, err := rand.Read(tail[6:8]); err != nil {
		return nil, nil, nil, nil, nil, fmt.Errorf("rand.Read: %w", err)
	}

	// XOR tail with keystream at position 56
	for i := 0; i < 8; i++ {
		tail[i] ^= encrypted[56+i] ^ header[56+i]
	}
	copy(header[56:64], tail)

	return header, relayEncKey, relayEncIV, relayDecKey, relayDecIV, nil
}

func resolveIPv4(host string) (string, error) {
	ips, err := net.LookupIP(host)
	if err != nil {
		return "", err
	}
	for _, ip := range ips {
		if ip.To4() != nil {
			return ip.String(), nil
		}
	}
	return "", fmt.Errorf("no IPv4 for %s", host)
}

func connectWS(dc int, isMedia bool) (*websocket.Conn, error) {
	domains := wsDomains(dc, isMedia)

	// Try direct WS first, then Cloudflare proxy fallback
	allDomains := make([]string, 0, len(domains)+1)
	allDomains = append(allDomains, domains...)
	allDomains = append(allDomains, fmt.Sprintf("kws%d.pclead.co.uk", dc))

	for _, domain := range allDomains {
		ip, err := resolveIPv4(domain)
		if err != nil {
			if *verbose {
				log.Printf("[debug] resolve %s failed: %v", domain, err)
			}
			continue
		}

		dialer := websocket.Dialer{
			TLSClientConfig: &tls.Config{
				ServerName: domain,
			},
			HandshakeTimeout: 5 * time.Second,
			Subprotocols:     []string{"binary"},
			NetDial: func(network, addr string) (net.Conn, error) {
				return net.DialTimeout("tcp4", ip+":443", 5*time.Second)
			},
		}
		headers := http.Header{}
		headers.Set("Origin", "http://web.telegram.org")
		headers.Set("Host", domain)

		url := fmt.Sprintf("wss://%s/apiws", domain)
		ws, _, err := dialer.Dial(url, headers)
		if err != nil {
			if *verbose {
				log.Printf("[debug] WS dial %s (%s) failed: %v", domain, ip, err)
			}
			continue
		}
		// Set read limit to prevent memory exhaustion
		ws.SetReadLimit(1 * 1024 * 1024) // 1MB max message
		if *verbose {
			log.Printf("[debug] WS connected to %s (%s)", domain, ip)
		}
		return ws, nil
	}
	return nil, fmt.Errorf("all WS domains failed for DC%d", dc)
}

// wsWriter serializes all writes to a WebSocket connection.
// gorilla/websocket supports only one concurrent writer.
type wsWriter struct {
	ws *websocket.Conn
	mu sync.Mutex
}

func (w *wsWriter) WriteMessage(messageType int, data []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return w.ws.WriteMessage(messageType, data)
}

func (w *wsWriter) WriteControl(messageType int, data []byte, deadline time.Time) error {
	// WriteControl is documented as thread-safe in gorilla/websocket,
	// but we serialize anyway for safety
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.ws.WriteControl(messageType, data, deadline)
}

func handleConnection(ctx context.Context, clientConn *net.TCPConn, secret []byte) {
	defer clientConn.Close()
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[panic] %s: %v", clientConn.RemoteAddr(), r)
		}
	}()

	// Set initial deadline for handshake
	clientConn.SetDeadline(time.Now().Add(10 * time.Second))

	// Read client obfuscated2 header
	header := make([]byte, handshakeLen)
	if _, err := io.ReadFull(clientConn, header); err != nil {
		return
	}

	// Decrypt with proxy secret
	dc, isMedia, protoTag, cltDecKey, cltDecIV, cltEncKey, cltEncIV, err := tryHandshake(header, secret)
	if err != nil {
		if *verbose {
			log.Printf("[error] handshake: %v", err)
		}
		return
	}

	mediaTag := ""
	if isMedia {
		mediaTag = "m"
	}
	dcIdx := dc
	if isMedia {
		dcIdx = -dc
	}

	if *verbose {
		log.Printf("[conn] %s DC%d%s proto=0x%08x", clientConn.RemoteAddr(), dc, mediaTag, protoTag)
	}

	// Generate relay header for Telegram DC (no secret)
	relayInit, relayEncKey, relayEncIV, relayDecKey, relayDecIV, err := generateRelayInit(protoTag, dcIdx)
	if err != nil {
		log.Printf("[error] relay init: %v", err)
		return
	}

	// Connect via WebSocket to Telegram DC
	ws, err := connectWS(dc, isMedia)
	if err != nil {
		log.Printf("[error] WS connect DC%d%s: %v", dc, mediaTag, err)
		return
	}
	defer ws.Close()

	writer := &wsWriter{ws: ws}

	// Send relay init header as first WS message
	if err := writer.WriteMessage(websocket.BinaryMessage, relayInit); err != nil {
		log.Printf("[error] WS write init: %v", err)
		return
	}

	// Create AES-CTR streams
	cltDecBlock, err := aes.NewCipher(cltDecKey)
	if err != nil {
		log.Printf("[error] aes.NewCipher(cltDecKey): %v", err)
		return
	}
	cltDecStream := cipher.NewCTR(cltDecBlock, cltDecIV)
	// Advance past the 64-byte header
	skip := make([]byte, handshakeLen)
	cltDecStream.XORKeyStream(skip, skip)

	cltEncBlock, err := aes.NewCipher(cltEncKey)
	if err != nil {
		log.Printf("[error] aes.NewCipher(cltEncKey): %v", err)
		return
	}
	cltEncStream := cipher.NewCTR(cltEncBlock, cltEncIV)

	relayEncBlock, err := aes.NewCipher(relayEncKey)
	if err != nil {
		log.Printf("[error] aes.NewCipher(relayEncKey): %v", err)
		return
	}
	relayEncStream := cipher.NewCTR(relayEncBlock, relayEncIV)
	relayEncStream.XORKeyStream(make([]byte, handshakeLen), make([]byte, handshakeLen))

	relayDecBlock, err := aes.NewCipher(relayDecKey)
	if err != nil {
		log.Printf("[error] aes.NewCipher(relayDecKey): %v", err)
		return
	}
	relayDecStream := cipher.NewCTR(relayDecBlock, relayDecIV)

	if *verbose {
		log.Printf("[relay] %s <-> WS DC%d%s", clientConn.RemoteAddr(), dc, mediaTag)
	}

	// Reset deadline for data transfer
	clientConn.SetDeadline(time.Now().Add(*connTimeout))

	// Create cancellable context for this connection
	connCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup
	wg.Add(2)
	var upBytes, downBytes int64

	// client → WS
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
				// Reset deadline on activity
				clientConn.SetDeadline(time.Now().Add(*connTimeout))
				plain := make([]byte, n)
				cltDecStream.XORKeyStream(plain, buf[:n])
				encrypted := make([]byte, n)
				relayEncStream.XORKeyStream(encrypted, plain)
				if werr := writer.WriteMessage(websocket.BinaryMessage, encrypted); werr != nil {
					break
				}
				upBytes += int64(n)
			}
			if err != nil {
				break
			}
		}
	}()

	// WS → client
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
				// Reset deadline on activity
				clientConn.SetDeadline(time.Now().Add(*connTimeout))
				plain := make([]byte, len(msg))
				relayDecStream.XORKeyStream(plain, msg)
				encrypted := make([]byte, len(msg))
				cltEncStream.XORKeyStream(encrypted, plain)
				if _, werr := clientConn.Write(encrypted); werr != nil {
					break
				}
				downBytes += int64(len(msg))
			}
		}
	}()

	wg.Wait()

	if *verbose {
		log.Printf("[done] %s DC%d%s up=%d down=%d", clientConn.RemoteAddr(), dc, mediaTag, upBytes, downBytes)
	}
}

func main() {
	flag.Parse()

	if *transparent {
		// Transparent mode: iptables REDIRECT, no client config needed
		if err := transparentListener(*listenAddr); err != nil {
			log.Fatal(err)
		}
		return
	}

	// MTProxy mode: requires client configuration
	var secret []byte
	if *secretHex == "" {
		secret = make([]byte, 16)
		if _, err := rand.Read(secret); err != nil {
			log.Fatalf("Failed to generate secret: %v", err)
		}
		*secretHex = fmt.Sprintf("dd%x", secret)
		log.Printf("Generated secret: %s", *secretHex)
	} else {
		parsed, err := parseSecretHex(*secretHex)
		if err != nil {
			log.Fatalf("Invalid secret: %v", err)
		}
		secret = parsed
	}

	// Initialize connection limiter
	connSemaphore = make(chan struct{}, *maxConns)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("Listen %s: %v", *listenAddr, err)
	}

	// Parse host and port safely
	host := "ROUTER_IP"
	_, port, splitErr := net.SplitHostPort(*listenAddr)
	if splitErr != nil {
		port = *listenAddr
	}
	log.Printf("tg-ws-proxy listening on %s", *listenAddr)
	log.Printf("Add proxy in Telegram: tg://proxy?server=%s&port=%s&secret=%s", host, port, *secretHex)

	// Graceful shutdown
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

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
				log.Println("[shutdown] Server stopped")
				return
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
				handleConnection(ctx, tcpConn, secret)
			}()
		default:
			if *verbose {
				log.Printf("[warn] max connections reached, rejecting %s", conn.RemoteAddr())
			}
			conn.Close()
		}
	}
}

func parseSecretHex(s string) ([]byte, error) {
	if len(s) < 34 || (s[:2] != "dd" && s[:2] != "ee") {
		return nil, fmt.Errorf("secret must start with dd or ee and be at least 34 hex chars")
	}
	raw := make([]byte, 16)
	for i := 0; i < 16; i++ {
		_, err := fmt.Sscanf(s[2+i*2:4+i*2], "%02x", &raw[i])
		if err != nil {
			return nil, err
		}
	}
	return raw, nil
}
