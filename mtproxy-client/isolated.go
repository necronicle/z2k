package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// The primary tunnel retains sole ownership of enrollment and route persistence.
// Every data flow has its own bounded session; no shared data transport fallback.
type isolationBudget struct {
	mu          sync.Mutex
	active      int
	limit       int
	localLimit  int
	deviceLimit int
	next        time.Time
	retryDelay  time.Duration
	byDevice    map[string]int
	waiting     map[string]int
	order       []string
}

// Keep the existing 16-slot source allowance as headroom for other sources.
// A source behind NAT may borrow up to total-16: 32 of the legacy 48 slots,
// 47 of a server quota of 64 minus its existing one-slot headroom, or 1007
// with the local ceiling/server quota of 1024. Small totals retain the old
// allowance; the independent total budget still bounds actual admissions.
const isolationSourceReserve = 16

func newIsolationBudget(limit int) *isolationBudget {
	return &isolationBudget{limit: limit, localLimit: limit, deviceLimit: max(isolationSourceReserve, limit-isolationSourceReserve), byDevice: map[string]int{}, waiting: map[string]int{}}
}
func (b *isolationBudget) setServerLimit(server int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	limit := b.localLimit
	// Old relays do not advertise quotas. Reserve headroom below their normal64.
	remote := 48
	if server > 0 {
		remote = server
		if remote > 1 {
			remote--
		}
	}
	if limit > remote {
		limit = remote
	}
	b.limit = limit
	b.deviceLimit = max(isolationSourceReserve, limit-isolationSourceReserve)
}
func (b *isolationBudget) enqueue(device string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.waiting[device] == 0 {
		b.order = append(b.order, device)
	}
	b.waiting[device]++
}
func (b *isolationBudget) removeWaiterLocked(device string) {
	b.waiting[device]--
	if b.waiting[device] == 0 {
		delete(b.waiting, device)
		for i, d := range b.order {
			if d == device {
				b.order = append(b.order[:i], b.order[i+1:]...)
				break
			}
		}
	}
}
func (b *isolationBudget) removeWaiter(device string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.removeWaiterLocked(device)
}
func (b *isolationBudget) acquire(now time.Time) bool { return b.acquireFor(now, "") }
func (b *isolationBudget) acquireFor(now time.Time, device string) bool {
	if b == nil {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.active >= b.limit || now.Before(b.next) || b.byDevice[device] >= b.deviceLimit {
		return false
	}
	if device != "" {
		chosen := ""
		for _, d := range b.order {
			if b.byDevice[d] < b.deviceLimit {
				chosen = d
				break
			}
		}
		if chosen != device {
			return false
		}
		b.removeWaiterLocked(device)
		// Rotate remaining requests from this device behind other devices.
		for i, d := range b.order {
			if d == device {
				b.order = append(append(b.order[:i], b.order[i+1:]...), device)
				break
			}
		}
	}
	b.active++
	b.byDevice[device]++
	return true
}
func (b *isolationBudget) release(devices ...string) {
	device := ""
	if len(devices) > 0 {
		device = devices[0]
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.active--
	b.byDevice[device]--
	if b.byDevice[device] == 0 {
		delete(b.byDevice, device)
	}
}
func (b *isolationBudget) failed() {
	b.mu.Lock()
	// Reuse the primary tunnel's backoffFor bounds (3s initial, 120s max)
	// and jitter (+/-30%). Double after each failed dial/handshake; cap the
	// actual pause too, so jitter cannot exceed the existing 120s ceiling.
	ceiling := backoffFor(10)
	if b.retryDelay == 0 {
		b.retryDelay = backoffFor(1)
	} else {
		b.retryDelay = min(2*b.retryDelay, ceiling)
	}
	b.next = time.Now().Add(min(jitter(b.retryDelay), ceiling))
	b.mu.Unlock()
}

// reserveIsolated snapshots the authoritative route and identity without making
// an accepted TCP flow wait behind a network handshake under connectMu.
func (tc *tunnelClient) reserveIsolated(device string) (*tunnelClient, *relayIdentity) {
	if tc.isolation == nil {
		return nil, nil
	}
	// Identity replacement and route persistence both own routeMu. Snapshot them
	// together, without the network-probe mutex: a slow authority must not block
	// new flows to the already-authenticated route.
	tc.routeMu.Lock()
	defer tc.routeMu.Unlock()
	id := tc.identity.Load()
	if !tc.discoveryReady() {
		return nil, nil
	}
	if !tc.isolation.acquireFor(time.Now(), device) {
		return nil, nil
	}
	endpoint := tc.tunnelURL
	if tc.route != nil {
		endpoint = tc.route.URL
	}
	child := newTunnelClient(endpoint, "")
	child.forceV1.Store(tc.forceV1.Load())
	child.isolatedDials = tc.isolatedDials
	child.isolation = tc.isolation
	return child, id
}

func (tc *tunnelClient) handleIsolated(conn *net.TCPConn, ip net.IP, port int) {
	device := isolationDevice(conn.RemoteAddr().(*net.TCPAddr))
	admitted := false
	started := time.Now()
	tc.isolation.enqueue(device)
	defer func() {
		if !admitted {
			tc.isolation.removeWaiter(device)
		}
	}()

	// Waiting consumes the existing global connection budget. Never divert an
	// overflow flow into the old shared data WebSocket.
	wait := time.NewTimer(45 * time.Second)
	defer wait.Stop()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		if tc.ctx.Err() != nil {
			break
		}
		child, id := tc.reserveIsolated(device)
		if child != nil {
			admitted = true
			if *verbose {
				log.Printf("[isolated] admitted %s after %s", conn.RemoteAddr(), time.Since(started))
			}
			defer tc.isolation.release(device)
			child.serveIsolated(tc.ctx, conn, id, ip, port, func(err error) {
				select {
				case tc.discoveryWake <- struct{}{}:
				default:
				}
			})
			return
		}
		// Preserve the successful experiment's fail-fast capacity behavior.
		// Accepting a socket and withholding its first bytes for45s makes
		// Telegram wait on a dead connection instead of retrying immediately.
		if capacity := tc.isolation.capacityReason(device); capacity != "" {
			if *verbose {
				log.Printf("[isolated] capacity full; refusing %s after %s source=%s %s", conn.RemoteAddr(), time.Since(started), device, capacity)
			}
			conn.Close()
			<-connSemaphore
			return
		}
		select {
		case <-tc.ctx.Done():
			conn.Close()
			<-connSemaphore
			return
		case <-wait.C:
			tc.dropped.Add(1)
			if *verbose {
				log.Printf("[isolated] admission timeout; closing queued flow")
			}
			conn.Close()
			<-connSemaphore
			return
		case <-tick.C:
		}
	}
	conn.Close()
	<-connSemaphore
}

func (tc *tunnelClient) serveIsolated(parent context.Context, phone *net.TCPConn, id *relayIdentity, ip net.IP, port int, onFailure func(error)) {
	tc.ctx, tc.cancel = context.WithCancel(parent)
	defer tc.cancel()
	tc.isolated = true
	phone.SetNoDelay(true)
	phone.SetDeadline(time.Now().Add(*connTimeout))
	if tc.isolatedDials != nil {
		select {
		case tc.isolatedDials <- struct{}{}:
		case <-tc.ctx.Done():
			phone.Close()
			<-connSemaphore
			return
		case <-time.After(10 * time.Second):
			phone.Close()
			<-connSemaphore
			return
		}
	}
	ws, err := tc.connectEndpoint(tc.tunnelURL, id)
	if tc.isolatedDials != nil {
		<-tc.isolatedDials
	}
	if err != nil && onFailure != nil {
		onFailure(err)
	}
	if err != nil {
		log.Printf("[isolated] handshake failed: %v", err)
		phone.Close()
		<-connSemaphore
		return
	}
	defer ws.Close()
	tc.mu.Lock()
	tc.ws = ws
	tc.writer = &wsWriter{ws: ws}
	tc.mu.Unlock()
	defer tc.closeAllStreams()
	tc.openStream(phone, ip, port)
	readDone := make(chan struct{})
	go func() { defer close(readDone); tc.readLoop(ws) }()
	defer func() { ws.Close(); <-readDone }()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	ping := time.NewTicker(wsPingInterval)
	defer ping.Stop()
	log.Printf("[isolated] flow open %s -> %s:%d", phone.RemoteAddr(), ip, port)
	defer log.Printf("[isolated] flow closed %s -> %s:%d", phone.RemoteAddr(), ip, port)
	for {
		select {
		case <-tc.ctx.Done():
			return
		case <-readDone:
			return
		case <-deadline.C:
			connected := false
			tc.streams.Range(func(_, v any) bool { connected = v.(*tunnelStream).writing.Load(); return false })
			if !connected {
				log.Printf("[isolated] CONNECT acknowledgment timeout")
				return
			}
		case <-ping.C:
			if err := ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
				return
			}
		}
	}
}

// Discovery authenticates and resolves an assigned route, then closes its socket.
// It never permanently consumes a session slot or carries application payload.
func (tc *tunnelClient) discoveryReady() bool {
	id := tc.identity.Load()
	return id != nil && tc.useID.Load() && tc.authenticatedIdentity.Load() == id
}

func (tc *tunnelClient) runDiscovery() {
	failures := 0
	for tc.ctx.Err() == nil {
		if !tc.isolation.reserveProbe() {
			select {
			case <-tc.ctx.Done():
				return
			case <-time.After(time.Second):
				continue
			}
		}
		tc.connectMu.Lock()
		ws, err := tc.connectTunnelWSLocked()
		id := tc.identity.Load()
		if err == nil {
			ws.Close()
			tc.authenticatedIdentity.Store(id)
			tc.isolation.setServerLimit(int(tc.serverSessions.Load()))
			tc.isolation.authenticated()
		} else {
			tc.isolation.failed()
			if errors.Is(err, errAuthRefused) {
				tc.authenticatedIdentity.Store(nil)
			}
		}
		tc.connectMu.Unlock()
		tc.isolation.releaseProbe()
		delay := routeRefreshInterval
		if err != nil {
			failures++
			delay = jitter(backoffFor(failures))
			if errors.Is(err, errNotRegistered) {
				delay = time.Second
			}
			if errors.Is(err, errAuthRefused) {
				tc.triggerReRegister()
			}
			log.Printf("[isolated] discovery failed: %v; retry in %v", err, delay)
		} else {
			failures = 0
		}
		timer := time.NewTimer(delay)
		tick := time.NewTicker(time.Second)
	wait:
		for {
			select {
			case <-tc.ctx.Done():
				timer.Stop()
				tick.Stop()
				return
			case <-timer.C:
				break wait
			case <-tc.discoveryWake:
				break wait
			case <-tick.C:
				// Enrollment may replace a key; never keep readiness for the old identity.
				if tc.identity.Load() != id {
					break wait
				}
			}
		}
		timer.Stop()
		tick.Stop()
	}
}

// Discovery shares the quota, so even a one-session custom relay can carry data.
func (b *isolationBudget) reserveProbe() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.active >= b.limit || time.Now().Before(b.next) {
		return false
	}
	b.active++
	return true
}
func (b *isolationBudget) releaseProbe() { b.mu.Lock(); b.active--; b.mu.Unlock() }

// isolationDevice identifies a visible source IP, not necessarily a physical
// device. REDIRECT changes the destination only. Neither SO_ORIGINAL_DST nor
// ARP can recover individual devices hidden behind an upstream NAT/proxy.
// IP.String canonicalizes IPv4 and IPv4-mapped addresses; ports never enter the key.
func isolationDevice(addr *net.TCPAddr) string { return addr.IP.String() }

func (b *isolationBudget) capacityReason(device string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	reason := ""
	if b.active >= b.limit {
		reason = "total"
	} else if b.byDevice[device] >= b.deviceLimit {
		reason = "source"
	} else {
		return ""
	}
	return fmt.Sprintf("reason=%s source_active=%d source_limit=%d active=%d limit=%d", reason, b.byDevice[device], b.deviceLimit, b.active, b.limit)
}

func (b *isolationBudget) authenticated() {
	b.mu.Lock()
	b.next = time.Time{}
	b.retryDelay = 0
	b.mu.Unlock()
}

func (b *isolationBudget) coolingDown() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return time.Now().Before(b.next)
}
