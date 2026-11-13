package gvsub

import (
	"net/netip"
	"os"
	"strings"
	"testing"
)

func TestBadNeutralStateLifecycle(t *testing.T) {
	s, _, _, _ := newSvc()
	s.StatusPath = t.TempDir() + "/status"
	wait(t, s.OnDNS(gvName, []netip.Addr{bad}))
	b, _ := os.ReadFile(s.StatusPath + ".neutral")
	if !strings.Contains(string(b), "bad 4a7d6e46") {
		t.Fatalf("neutral=%q", b)
	}
	s.Shutdown()
	b, _ = os.ReadFile(s.StatusPath + ".neutral")
	if strings.TrimSpace(string(b)) != "" {
		t.Fatal("stale neutral on shutdown")
	}
}
