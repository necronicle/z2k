package main

import (
	"flag"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// defaultTunnelSecret is injected at BUILD time, NOT committed to source, via:
//
//	go build -ldflags "-X main.defaultTunnelSecret=<hex>"
//
// (see mtproxy-client/Makefile, var Z2K_TUNNEL_SECRET). It is intentionally empty
// in the public repo so the shared tunnel credential is not published. A binary
// built without it requires --tunnel-secret at runtime (the router passes it from
// /opt/zapret2/config Z2K_RELAY_SECRET when set; see files/init.d/S98tg-tunnel).
var defaultTunnelSecret = ""

var (
	listenAddr   = flag.String("listen", ":1443", "Local listen address")
	tunnelURL    = flag.String("tunnel-url", "wss://213.176.74.63.nip.io/ws", "Tunnel relay WebSocket URL")
	tunnelSecret = flag.String("tunnel-secret", defaultTunnelSecret, "Shared secret for tunnel auth (build-injected; override with --tunnel-secret)")
	verbose      = flag.Bool("v", false, "Verbose logging")
	connTimeout  = flag.Duration("timeout", 15*time.Minute, "Idle connection timeout")
	maxConns     = flag.Int("max-conns", 1024, "Maximum concurrent connections")
	relayIDFile  = flag.String("relay-id-file", "/opt/zapret2/.z2k-relay-id", "per-install identity file (Stage B)")
)

// connSemaphore limits concurrent connections
var connSemaphore chan struct{}

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
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.ws.WriteControl(messageType, data, deadline)
}

func main() {
	flag.Parse()

	if err := runTunnel(); err != nil {
		log.Fatal(err)
	}
}
