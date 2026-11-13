package gvsub

import (
	"net/netip"
	"os"
	"strings"
	"testing"
)

func TestBadRemainsNeutralWithoutReject(t *testing.T) {
	s, _, r, _ := newSvc()
	s.StatusPath = t.TempDir() + "/status"
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	b, _ := os.ReadFile(s.StatusPath + ".neutral")
	if !strings.Contains(string(b), "bad 4a7d6e46") || r.rejects(bad) {
		t.Fatalf("neutral=%q rejected=%t", b, r.rejects(bad))
	}
	s.Shutdown()
	b, _ = os.ReadFile(s.StatusPath + ".neutral")
	if strings.TrimSpace(string(b)) != "" {
		t.Fatal("stale neutral on shutdown")
	}
}
