package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
)

const capRelayRoute uint32 = 1
const infoRelayRoute byte = 5

var routesFile = flag.String("routes-file", "", "optional per-install relay assignments (JSON)")
var registrationClosed = flag.Bool("registration-closed", false, "only confirm existing registry identities; never enroll new keys")
var maxStreamsTotal = flag.Int("max-streams-total", 0, "max pending/live streams across all sessions (0 = unlimited)")

type relayRoute struct {
	URL            string `json:"url"`
	MaxConnections int    `json:"max_connections"`
}

var relayRoutes = struct {
	sync.RWMutex
	entries map[string]relayRoute
}{}

func validRoute(r relayRoute) bool {
	if r.MaxConnections < 1 || r.MaxConnections > 8192 || len(r.URL) > 2048 {
		return false
	}
	u, err := url.Parse(r.URL)
	if err != nil || u.Scheme != "wss" || u.Hostname() == "" || u.User != nil || u.Path != "/ws" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.RawFragment != "" {
		return false
	}
	if strings.EqualFold(u.Hostname(), "localhost") {
		return false
	}
	if ip := net.ParseIP(u.Hostname()); ip != nil && (!ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast()) {
		return false
	}
	return true
}

// Parse completely before swapping: a bad operator reload must retain the last
// working assignment rather than silently sending clients back to this node.
func loadRelayRoutes(path string) error {
	entries := map[string]relayRoute{}
	if path != "" {
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		b, err := io.ReadAll(io.LimitReader(f, 1024*1024+1))
		if err != nil {
			return err
		}
		if len(b) > 1024*1024 {
			return fmt.Errorf("route map exceeds 1 MiB")
		}
		if err = json.Unmarshal(b, &entries); err != nil {
			return err
		}
		for id, r := range entries {
			if !validInstallID(id) || !validRoute(r) {
				return fmt.Errorf("invalid route entry for %q", id)
			}
		}
	}
	relayRoutes.Lock()
	relayRoutes.entries = entries
	relayRoutes.Unlock()
	return nil
}

func routeFor(id string) (relayRoute, bool) {
	relayRoutes.RLock()
	defer relayRoutes.RUnlock()
	r, ok := relayRoutes.entries[id]
	return r, ok
}

// Reserve before launching a dial, including concurrent CONNECTs from different
// sessions. emitStreamClose releases this same counter, including failed dials.
func acquireStream() bool {
	for {
		n := liveStreams.Load()
		if *maxStreamsTotal > 0 && n >= int64(*maxStreamsTotal) {
			return false
		}
		if liveStreams.CompareAndSwap(n, n+1) {
			return true
		}
	}
}
