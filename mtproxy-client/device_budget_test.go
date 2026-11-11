package main

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// The same key function feeds handleIsolated and the actual admission budget.
// A /24 key or a shared gateway key would merge independent source accounting.
func TestIsolationVisibleSourcesEachGetSixteen(t *testing.T) {
	b := newIsolationBudget(1024)
	b.setServerLimit(64)
	var wg sync.WaitGroup
	for _, source := range []string{"192.168.1.2", "192.168.1.3", "172.16.6.2"} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 16; i++ {
				device := isolationDevice(&net.TCPAddr{IP: net.ParseIP(source), Port: 11000 + i})
				b.enqueue(device)
				// Other sources can be ahead in the fair queue.
				deadline := time.Now().Add(3 * time.Second)
				for !b.acquireFor(time.Now(), device) {
					if time.Now().After(deadline) {
						t.Errorf("%s blocked at flow %d", source, i+1)
						b.removeWaiter(device)
						return
					}
					time.Sleep(time.Millisecond)
				}
			}
		}()
	}
	wg.Wait()
	if b.active != 48 {
		t.Fatalf("admitted %d flows, want 48", b.active)
	}
	for _, source := range []string{"192.168.1.2", "192.168.1.3", "172.16.6.2"} {
		for i := 0; i < 16; i++ {
			b.release(source)
		}
	}
	if b.active != 0 || len(b.byDevice) != 0 || len(b.waiting) != 0 {
		t.Fatal("source accounting leaked after release")
	}
}

// Exercise the real budget with visible-IP keys, including quota negotiation.
func TestIsolationSoftSourceLimit(t *testing.T) {
	for _, tt := range []struct {
		name                              string
		local, server, total, sourceLimit int
	}{
		{"local", 48, -1, 48, 32},
		{"legacy", 1024, 0, 48, 32},
		{"community", 1024, 64, 63, 47},
		{"dedicated", 1024, 1024, 1023, 1007},
		{"sixteen", 16, 0, 16, 16},
		{"small", 8, 0, 8, 16},
		{"minimum_allowance", 24, 0, 24, 16},
	} {
		t.Run(tt.name, func(t *testing.T) {
			b := newIsolationBudget(tt.local)
			if tt.server >= 0 {
				b.setServerLimit(tt.server)
			}
			first := isolationDevice(&net.TCPAddr{IP: net.ParseIP("172.16.6.2"), Port: 10000})
			second := isolationDevice(&net.TCPAddr{IP: net.ParseIP("192.168.1.2"), Port: 10000})
			admit := func(source string) {
				t.Helper()
				b.enqueue(source)
				if !b.acquireFor(time.Now(), source) {
					t.Fatalf("%s refused at active=%d source=%d", source, b.active, b.byDevice[source])
				}
			}
			firstFlows := min(tt.total, tt.sourceLimit)
			for i := 0; i < firstFlows; i++ {
				admit(first)
			}
			for _, ip := range []string{"172.16.6.2", "::ffff:172.16.6.2"} {
				key := isolationDevice(&net.TCPAddr{IP: net.ParseIP(ip), Port: 65530})
				b.enqueue(key)
				if b.acquireFor(time.Now(), key) {
					t.Fatal("port/mapped IP bypassed source or total cap")
				}
				b.removeWaiter(key)
			}
			wantReason := "source"
			if firstFlows == tt.total {
				wantReason = "total"
			}
			want := fmt.Sprintf("reason=%s source_active=%d source_limit=%d active=%d limit=%d", wantReason, firstFlows, tt.sourceLimit, firstFlows, tt.total)
			if got := b.capacityReason(first); got != want {
				t.Fatalf("capacity: %s, want %s", got, want)
			}
			// The second source can use all reserved slots without evicting the first.
			for i := firstFlows; i < tt.total; i++ {
				admit(second)
			}
			b.enqueue(second)
			if b.acquireFor(time.Now(), second) {
				t.Fatal("full total budget admitted a flow")
			}
			b.removeWaiter(second)
			if got := b.capacityReason(second); !strings.HasPrefix(got, "reason=total ") {
				t.Fatalf("full budget: %s", got)
			}
			if b.byDevice[first] != firstFlows {
				t.Fatal("existing flows evicted")
			}
			// A release makes exactly that capacity available again.
			b.release(first)
			admit(first)
			for b.byDevice[first] > 0 {
				b.release(first)
			}
			for b.byDevice[second] > 0 {
				b.release(second)
			}
			if b.active != 0 || len(b.byDevice) != 0 || len(b.waiting) != 0 || len(b.order) != 0 {
				t.Fatal("budget accounting leaked")
			}
		})
	}
}

func TestIsolationCapacityDistinguishesTotalFromSource(t *testing.T) {
	b := newIsolationBudget(2)
	for i := 0; i < 2; i++ {
		b.enqueue("172.16.6.2")
		if !b.acquireFor(time.Now(), "172.16.6.2") {
			t.Fatal("available capacity refused")
		}
	}
	if got := b.capacityReason("192.168.1.2"); got != "reason=total source_active=0 source_limit=16 active=2 limit=2" {
		t.Fatalf("total cap mistaken for source cap: %s", got)
	}
	b.release("172.16.6.2")
	if got := b.capacityReason("192.168.1.2"); got != "" {
		t.Fatalf("available capacity marked full: %s", got)
	}
}

// Exercise handleIsolated's real refusal path, including socket/semaphore cleanup.
func TestIsolatedRefusalIdentifiesExhaustedBudget(t *testing.T) {
	if connSemaphore == nil {
		connSemaphore = make(chan struct{}, 4096)
	}
	for _, tt := range []struct {
		name, source, want string
		limit, flows       int
	}{
		{"source", "127.0.0.1", "reason=source source_active=47 source_limit=47 active=47 limit=63", 64, 47},
		{"total", "192.168.1.2", "reason=total source_active=0 source_limit=16 active=2 limit=2", 2, 2},
	} {
		t.Run(tt.name, func(t *testing.T) {
			tc := newTunnelClient("wss://unused.invalid/ws", "")
			tc.ctx = context.Background()
			tc.isolation = newIsolationBudget(tt.limit)
			tc.isolation.setServerLimit(64)
			for i := 0; i < tt.flows; i++ {
				tc.isolation.enqueue(tt.source)
				if !tc.isolation.acquireFor(time.Now(), tt.source) {
					t.Fatal("could not fill budget")
				}
			}
			var output bytes.Buffer
			oldWriter, oldVerbose := log.Writer(), *verbose
			log.SetOutput(&output)
			*verbose = true
			defer func() { log.SetOutput(oldWriter); *verbose = oldVerbose }()
			before := len(connSemaphore)
			local, phone := phonePair(t)
			defer phone.Close()
			tc.handleIsolated(local, net.IPv4(149, 154, 167, 51), 443)
			if !strings.Contains(output.String(), "source=127.0.0.1 "+tt.want) {
				t.Fatalf("refusal lacks source/budget evidence: %s", output.String())
			}
			if len(connSemaphore) != before || len(tc.isolation.waiting) != 0 {
				t.Fatal("refused flow leaked admission resources")
			}
			phone.SetReadDeadline(time.Now().Add(time.Second))
			if _, err := phone.Read(make([]byte, 1)); err == nil {
				t.Fatal("refused socket remained open")
			}
		})
	}
}
