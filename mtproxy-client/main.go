package main

import (
	"flag"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var (
	listenAddr   = flag.String("listen", ":1443", "Local listen address")
	tunnelURL    = flag.String("tunnel-url", "wss://213.176.74.63.nip.io/ws", "Tunnel relay WebSocket URL")
	tunnelSecret = flag.String("tunnel-secret", "d01f72f9543b29da4e3724b1530c0d11cb30a6f8db15bc0adfe8f2d37b5844b2", "Shared secret for tunnel auth")
	verbose      = flag.Bool("v", false, "Verbose logging")
	connTimeout  = flag.Duration("timeout", 5*time.Minute, "Idle connection timeout")
	maxConns     = flag.Int("max-conns", 1024, "Maximum concurrent connections")
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
