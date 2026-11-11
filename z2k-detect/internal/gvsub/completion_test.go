package gvsub

import (
	"net/netip"
	"os"
	"testing"
	"time"
)

// Tick starts probes independently of OnDNS. Tests must drain them before
// removing files used by their final status write.
func waitForProbes(t *testing.T, s *Service) {
	t.Helper()
	s.mu.Lock()
	var pending []<-chan struct{}
	for _, done := range s.inflight {
		pending = append(pending, done)
	}
	s.mu.Unlock()
	for _, done := range pending {
		wait(t, done)
	}
}

// DNS completion must include the probe's status write, so callers can
// safely release resources once the returned channel closes.
func TestDNSCompletionWaitsForStatus(t *testing.T) {
	s, _, _, _ := newSvc()
	s.Resolver = nil
	s.StatusPath = t.TempDir() + "/status.json"
	s.statusMu.Lock()
	done := s.OnDNS(gvName, []netip.Addr{netip.MustParseAddr("74.125.110.38")})
	select {
	case <-done:
		t.Error("DNS completed while its status write was still blocked")
	case <-time.After(50 * time.Millisecond):
	}
	s.statusMu.Unlock()
	wait(t, done)
	// Also drain the old implementation on failure before TempDir cleanup.
	waitFor(t, func() bool {
		_, err := os.Stat(s.StatusPath)
		return err == nil
	}, "probe status was not written")
}
