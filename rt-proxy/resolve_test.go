package main

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

// A resolver that never answers until its context is done — what a filtered
// 1.1.1.1:53 looks like from Go's resolver. This is the ONLY interesting failure
// mode for resolve(): the direct resolver exists precisely to bypass the router's
// sticky ndnproxy, and RU ISPs filtering 1.1.1.1 is routine, so the system
// resolver behind it is not a nicety - it is the path that keeps the pool alive.
type blockedResolver struct{ waited time.Duration }

func (b *blockedResolver) LookupHost(ctx context.Context, _ string) ([]string, error) {
	t0 := time.Now()
	<-ctx.Done()
	b.waited = time.Since(t0)
	return nil, errors.New("i/o timeout")
}

type fixedResolver struct {
	ips    []string
	called bool
	gotCtx error // ctx.Err() as observed on entry
}

func (f *fixedResolver) LookupHost(ctx context.Context, _ string) ([]string, error) {
	f.called = true
	f.gotCtx = ctx.Err()
	if f.gotCtx != nil {
		return nil, f.gotCtx
	}
	return f.ips, nil
}

// withResolvers swaps the resolver set for one test and restores it after.
func withResolvers(t *testing.T, rs ...hostLookuper) {
	t.Helper()
	prev := resolversFor
	resolversFor = func() []hostLookuper { return rs }
	t.Cleanup(func() { resolversFor = prev })
}

// THE regression test. A blocked direct resolver must not consume the system
// resolver's budget: the fallback documented on the --resolver flag has to
// actually run in the one situation it exists for.
func TestResolve_BlockedDirectResolverStillLetsTheFallbackAnswer(t *testing.T) {
	blocked := &blockedResolver{}
	fallback := &fixedResolver{ips: []string{"203.0.113.7"}}
	withResolvers(t, blocked, fallback)

	p := &pool{}
	p.resolve()

	if !fallback.called {
		t.Fatal("system resolver was never consulted at all")
	}
	if fallback.gotCtx != nil {
		t.Fatalf("system resolver received an already-dead context (%v) — the blocked "+
			"direct resolver ate the shared budget, so the fallback cannot work", fallback.gotCtx)
	}
	p.mu.RLock()
	all := append([]string(nil), p.all...)
	p.mu.RUnlock()
	found := false
	for _, ip := range all {
		if ip == "203.0.113.7" {
			found = true
		}
	}
	if !found {
		t.Fatalf("fallback IP never reached the candidate pool: p.all=%v", all)
	}
}

// The happy path must be unchanged: both resolvers answer, the union is kept and
// deduplicated, and junk is dropped.
func TestResolve_UnionsBothResolversAndDropsNonIPs(t *testing.T) {
	a := &fixedResolver{ips: []string{"203.0.113.1", "not-an-ip", "203.0.113.2"}}
	b := &fixedResolver{ips: []string{"203.0.113.2", "203.0.113.3"}}
	withResolvers(t, a, b)

	p := &pool{seed: []string{"203.0.113.9"}, all: []string{"203.0.113.9"}}
	p.resolve()

	p.mu.RLock()
	all := append([]string(nil), p.all...)
	p.mu.RUnlock()

	want := map[string]bool{"203.0.113.9": true, "203.0.113.1": true, "203.0.113.2": true, "203.0.113.3": true}
	if len(all) != len(want) {
		t.Fatalf("expected %d unique candidates, got %d: %v", len(want), len(all), all)
	}
	for _, ip := range all {
		if !want[ip] {
			t.Errorf("unexpected candidate %q (junk should be dropped)", ip)
		}
		if net.ParseIP(ip) == nil {
			t.Errorf("non-IP %q made it into the pool", ip)
		}
	}
}

// A total resolve failure must keep the previous candidate set rather than
// emptying it — otherwise one DNS blip strands the daemon with nothing to probe.
func TestResolve_TotalFailureKeepsTheExistingCandidates(t *testing.T) {
	withResolvers(t, &fixedResolver{ips: nil}, &fixedResolver{ips: nil})
	p := &pool{seed: []string{"203.0.113.9"}, all: []string{"203.0.113.9", "203.0.113.8"}}
	p.resolve()
	p.mu.RLock()
	n := len(p.all)
	p.mu.RUnlock()
	if n != 2 {
		t.Fatalf("candidate set was clobbered by an empty resolve: want 2, got %d", n)
	}
}

// A currently-live IP that has fallen out of DNS must be retained (DNS blip),
// and an IP that is neither seeded, resolved nor live must be dropped so p.all
// cannot grow without bound.
func TestResolve_RetainsLiveButDropsForgottenCandidates(t *testing.T) {
	withResolvers(t, &fixedResolver{ips: []string{"203.0.113.1"}})
	p := &pool{
		seed: []string{"203.0.113.9"},
		all:  []string{"203.0.113.9", "203.0.113.1", "198.51.100.44"}, // .44 is stale
		live: []string{"198.51.100.55"},                               // live but unresolved
	}
	p.resolve()
	p.mu.RLock()
	all := append([]string(nil), p.all...)
	p.mu.RUnlock()

	has := func(x string) bool {
		for _, ip := range all {
			if ip == x {
				return true
			}
		}
		return false
	}
	if !has("203.0.113.9") {
		t.Error("seed IP must always be retained")
	}
	if !has("198.51.100.55") {
		t.Error("a currently-live IP must survive a DNS blip")
	}
	if has("198.51.100.44") {
		t.Error("an IP that is neither seed, resolved nor live must be dropped")
	}
}
