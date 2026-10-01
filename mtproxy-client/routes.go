package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

const capRelayRoute uint32 = 1
const infoRelayRoute byte = 5
const maxAssignedConnections = 8192
const routeRefreshInterval = 10 * time.Minute

type cachedRoute struct {
	Authority      string `json:"authority"`
	URL            string `json:"url"`
	MaxConnections int    `json:"max_connections"`
}
type relayRouteError struct {
	URL            string
	MaxConnections int
}

func (e *relayRouteError) Error() string { return "relay assigned another endpoint" }

func validAssignedRoute(r cachedRoute) bool {
	authority, err := url.Parse(r.Authority)
	if err != nil || authority.Scheme != "wss" || authority.Hostname() == "" || authority.User != nil {
		return false
	}
	if r.Authority == r.URL || r.MaxConnections < 1 || r.MaxConnections > maxAssignedConnections || len(r.URL) > 2048 {
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
func (tc *tunnelClient) routeSnapshot() *cachedRoute {
	tc.routeMu.Lock()
	defer tc.routeMu.Unlock()
	if tc.route == nil {
		return nil
	}
	r := *tc.route
	return &r
}
func (tc *tunnelClient) loadCachedRoute(id *relayIdentity) {
	if id.Route == nil || id.Route.Authority != tc.tunnelURL || !validAssignedRoute(*id.Route) {
		return
	}
	r := *id.Route
	tc.routeMu.Lock()
	tc.route = &r
	tc.routeDirty = false
	tc.forceV1.Store(false)
	tc.routeMu.Unlock()
	tc.setConnectionLimit(r.MaxConnections)
	// The cached assignment came from the authority after signed authentication;
	// the target already has this public key. No enrollment secret is needed there.
	tc.useID.Store(true)
}
func (tc *tunnelClient) storeRoute(id *relayIdentity, r *cachedRoute) error {
	if r != nil && (r.Authority != tc.tunnelURL || !validAssignedRoute(*r)) {
		return fmt.Errorf("invalid relay assignment")
	}
	tc.routeMu.Lock()
	defer tc.routeMu.Unlock()
	if current := tc.identity.Load(); current != nil && (current.InstallID != id.InstallID || current.Priv != id.Priv) {
		return fmt.Errorf("obsolete relay identity")
	}
	if !tc.routeDirty && ((r == nil && tc.route == nil) || (r != nil && tc.route != nil && *r == *tc.route)) {
		if r != nil {
			tc.setConnectionLimit(r.MaxConnections)
		}
		return nil
	}
	tc.routeDirty = true
	if r == nil {
		tc.route = nil
		tc.setConnectionLimit(*maxConns)
	} else {
		tc.forceV1.Store(false)
		copy := *r
		tc.route = &copy
		tc.setConnectionLimit(r.MaxConnections)
	}
	path := tc.identityPath
	if path == "" {
		path = *relayIDFile
	}
	// Do not overwrite a concurrently replaced identity with the old key.
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var disk relayIdentity
	if json.Unmarshal(raw, &disk) != nil || disk.InstallID != id.InstallID || disk.Priv != id.Priv {
		return fmt.Errorf("identity changed while saving assignment")
	}
	disk.Route = r
	out, err := json.Marshal(disk)
	if err != nil {
		return err
	}
	if err = os.WriteFile(path+".route.tmp", out, 0600); err != nil {
		return err
	}
	if err = os.Rename(path+".route.tmp", path); err != nil {
		os.Remove(path + ".route.tmp")
		return err
	}
	tc.routeDirty = false
	return nil
}
func boundedConnectionLimit(requested, ceiling int, fd uint64) int {
	if ceiling <= 0 || ceiling > maxAssignedConnections {
		ceiling = maxAssignedConnections
	}
	if requested > ceiling {
		requested = ceiling
	}
	if fd > 0 {
		slots := uint64(1)
		if fd > 64 {
			slots = (fd - 64) / 2
		}
		if uint64(requested) > slots {
			requested = int(slots)
		}
	}
	if requested < 1 {
		return 1
	}
	return requested
}
func (tc *tunnelClient) setConnectionLimit(n int) {
	tc.connectionLimit.Store(int64(boundedConnectionLimit(n, tc.localMaxConnections, tc.fdLimit)))
}
func connectionFDLimit() uint64 {
	var lim syscall.Rlimit
	if syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim) != nil {
		return 0
	}
	wanted := uint64(maxAssignedConnections*2 + 64)
	if lim.Cur < wanted {
		if wanted > lim.Max {
			wanted = lim.Max
		}
		raised := lim
		raised.Cur = wanted
		if syscall.Setrlimit(syscall.RLIMIT_NOFILE, &raised) == nil {
			lim = raised
		}
	}
	return lim.Cur
}
func (tc *tunnelClient) acquireConnection() bool {
	tc.connectionMu.Lock()
	defer tc.connectionMu.Unlock()
	limit := tc.connectionLimit.Load()
	if limit <= 0 {
		limit = int64(*maxConns)
	}
	if int64(len(connSemaphore)) >= limit {
		return false
	}
	select {
	case connSemaphore <- struct{}{}:
		return true
	default:
		return false
	}
}

func (tc *tunnelClient) connectTunnelWS() (*websocket.Conn, error) {
	tc.connectMu.Lock()
	defer tc.connectMu.Unlock()
	id := tc.identity.Load()
	if id == nil || !tc.useID.Load() {
		return nil, errNotRegistered
	}
	ws, err := tc.connectEndpoint(tc.tunnelURL, id)
	var assigned *relayRouteError
	if errors.As(err, &assigned) {
		r := &cachedRoute{Authority: tc.tunnelURL, URL: assigned.URL, MaxConnections: assigned.MaxConnections}
		if !validAssignedRoute(*r) {
			return nil, fmt.Errorf("invalid relay assignment")
		}
		if saveErr := tc.storeRoute(id, r); saveErr != nil {
			log.Printf("[tunnel] cannot persist relay assignment: %v", saveErr)
		}
		return tc.connectAssigned(r, id)
	}
	if err == nil {
		if saveErr := tc.storeRoute(id, nil); saveErr != nil {
			log.Printf("[tunnel] cannot clear relay assignment: %v", saveErr)
		}
		tc.setConnectionLimit(*maxConns)
		return ws, nil
	}
	// An explicit refusal is authoritative. Do not bypass it with a cached route.
	if errors.Is(err, errAuthRefused) {
		if saveErr := tc.storeRoute(id, nil); saveErr != nil {
			log.Printf("[tunnel] cannot clear refused assignment: %v", saveErr)
		}
		return nil, err
	}
	if r := tc.routeSnapshot(); r != nil {
		log.Printf("[tunnel] authority unavailable; using saved relay assignment")
		return tc.connectAssigned(r, id)
	}
	return nil, err
}
func (tc *tunnelClient) connectAssigned(r *cachedRoute, id *relayIdentity) (*websocket.Conn, error) {
	ws, err := tc.connectEndpoint(r.URL, id)
	var further *relayRouteError
	if errors.As(err, &further) {
		return nil, fmt.Errorf("assigned relay cannot redirect again")
	}
	if err == nil {
		tc.setConnectionLimit(r.MaxConnections)
		log.Printf("[tunnel] assigned relay ready; connection limit %d", tc.connectionLimit.Load())
	}
	return ws, err
}

// Refresh only routed clients. Probe uses separate handshake state so discovery
// cannot change the active tunnel's window/clock or downgrade its protocol.
func (tc *tunnelClient) refreshAssignment() {
	tc.connectMu.Lock()
	defer tc.connectMu.Unlock()
	old := tc.routeSnapshot()
	id := tc.identity.Load()
	if old == nil || id == nil {
		return
	}
	probe := &tunnelClient{tunnelURL: tc.tunnelURL, dialer: tc.dialer}
	ws, err := probe.connectEndpoint(tc.tunnelURL, id)
	if ws != nil {
		ws.Close()
	}
	var assigned *relayRouteError
	var next *cachedRoute
	switch {
	case errors.As(err, &assigned):
		next = &cachedRoute{Authority: tc.tunnelURL, URL: assigned.URL, MaxConnections: assigned.MaxConnections}
		if !validAssignedRoute(*next) {
			return
		}
		if *next == *old {
			if saveErr := tc.storeRoute(id, next); saveErr != nil {
				log.Printf("[tunnel] cannot persist refreshed assignment: %v", saveErr)
			}
			return
		}
	case err == nil, errors.Is(err, errAuthRefused):
		// Withdrawal or explicit denial: clear cached authority and reconnect.
	default:
		return // transport outage preserves healthy data path
	}
	if saveErr := tc.storeRoute(id, next); saveErr != nil {
		log.Printf("[tunnel] cannot persist refreshed assignment: %v", saveErr)
	}
	tc.mu.Lock()
	active := tc.ws
	tc.mu.Unlock()
	if active != nil {
		active.Close()
	}
}
func (tc *tunnelClient) routeRefreshLoop() {
	timer := time.NewTicker(routeRefreshInterval)
	defer timer.Stop()
	for {
		select {
		case <-tc.ctx.Done():
			return
		case <-timer.C:
			tc.refreshAssignment()
		}
	}
}
