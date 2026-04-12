package main

import (
	"flag"
	"log"
	"time"
)

var (
	listenAddr   = flag.String("listen", ":1443", "Local listen address")
	tunnelURL    = flag.String("tunnel-url", "wss://z2k-tunnel.necronicle.workers.dev/ws", "Cloudflare Worker WebSocket URL")
	tunnelSecret = flag.String("tunnel-secret", "d01f72f9543b29da4e3724b1530c0d11cb30a6f8db15bc0adfe8f2d37b5844b2", "Shared secret for tunnel auth")
	verbose      = flag.Bool("v", false, "Verbose logging")
	connTimeout  = flag.Duration("timeout", 5*time.Minute, "Idle connection timeout")
	maxConns     = flag.Int("max-conns", 1024, "Maximum concurrent accept-side connections")
	parallelWS   = flag.Int("parallel", 6, "Number of parallel WebSocket sessions to the relay (each = 6 concurrent TCP slots on CF)")
	sessionTTL   = flag.Duration("session-ttl", 0, "Voluntarily rotate each WS session after this duration (0 = disabled). Workaround for CF CPU limit.")
)

func main() {
	flag.Parse()

	if err := runTunnel(); err != nil {
		log.Fatal(err)
	}
}
