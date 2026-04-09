package main

import (
	"flag"
	"log"
	"math/rand"
	"net"
	"time"
)

var (
	listenAddr  = flag.String("listen", ":9443", "Local listen address for redirected Telegram traffic")
	serverAddr  = flag.String("server", "api.mtproto.ru:443", "Remote MTProxy server address")
	secretHex   = flag.String("secret", "", "MTProxy secret (ee-prefixed hex string)")
	dialTimeout = flag.Duration("timeout", 15*time.Second, "Connection timeout to MTProxy server")
	verbose     = flag.Bool("v", false, "Verbose logging")
)

func handleConnection(clientConn *net.TCPConn, secret *ProxySecret) {
	defer clientConn.Close()

	// Get original destination (before iptables REDIRECT)
	origIP, origPort, err := getOriginalDst(clientConn)
	if err != nil {
		log.Printf("[error] getOriginalDst: %v", err)
		return
	}

	// Map destination IP to Telegram DC number
	dc := LookupDC(origIP)

	if *verbose {
		log.Printf("[conn] %s -> %s:%d (DC%d)", clientConn.RemoteAddr(), origIP, origPort, dc)
	}

	// Connect to remote MTProxy server
	serverConn, err := net.DialTimeout("tcp", *serverAddr, *dialTimeout)
	if err != nil {
		log.Printf("[error] dial %s: %v", *serverAddr, err)
		return
	}
	defer serverConn.Close()

	serverConn.(*net.TCPConn).SetKeepAlive(true)
	serverConn.(*net.TCPConn).SetKeepAlivePeriod(30 * time.Second)

	// FakeTLS handshake with the MTProxy server
	_, err = doFakeTLSHandshake(serverConn, secret)
	if err != nil {
		log.Printf("[error] FakeTLS handshake: %v", err)
		return
	}

	// Wrap server connection in TLS record framing
	tlsConn := newTLSRecordConn(serverConn)

	// Send ChangeCipherSpec (required after FakeTLS handshake)
	if err := writeTLSRecord(serverConn, tlsRecordChangeCipherSpec, []byte{0x01}); err != nil {
		log.Printf("[error] send ChangeCipherSpec: %v", err)
		return
	}

	// Obfuscated2 layer on top of TLS records
	obfsConn, err := newObfuscated2Conn(tlsConn, secret.Secret, dc)
	if err != nil {
		log.Printf("[error] obfuscated2 init: %v", err)
		return
	}

	if *verbose {
		log.Printf("[relay] %s <-> %s (DC%d)", clientConn.RemoteAddr(), *serverAddr, dc)
	}

	// Bidirectional relay: client <-> obfuscated2(TLS(MTProxy server))
	relay(clientConn, obfsConn)

	if *verbose {
		log.Printf("[done] %s", clientConn.RemoteAddr())
	}
}

func main() {
	flag.Parse()

	if *secretHex == "" {
		log.Fatal("--secret is required (ee-prefixed hex string)")
	}

	secret, err := ParseSecret(*secretHex)
	if err != nil {
		log.Fatalf("Invalid secret: %v", err)
	}

	rand.Seed(time.Now().UnixNano())

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("Listen %s: %v", *listenAddr, err)
	}

	log.Printf("tg-mtproxy-client listening on %s -> %s (SNI: %s)", *listenAddr, *serverAddr, secret.SNI)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("[error] accept: %v", err)
			continue
		}
		go handleConnection(conn.(*net.TCPConn), secret)
	}
}

func init() {
	// Suppress timestamp prefix for cleaner log output
	log.SetFlags(log.Ldate | log.Ltime)
}
