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

func TestDeadNeutralStateLifecycle(t *testing.T) {
	s, _, _, _ := newSvc()
	s.StatusPath = t.TempDir() + "/status"
	dead4 := netip.MustParseAddr("74.125.110.99")
	dead6 := netip.MustParseAddr("2a00:1450:4010:c02::c")
	wait(t, s.OnDNS(gvName, []netip.Addr{dead4, dead6}))
	b, _ := os.ReadFile(s.StatusPath + ".neutral")
	got := string(b)
	if !strings.Contains(got, "dead 4a7d6e63") || !strings.Contains(got, "dead 2a00145040100c02000000000000000c") {
		t.Fatalf("missing dead hex rows in neutral=%q", got)
	}
	s.Shutdown()
	b, _ = os.ReadFile(s.StatusPath + ".neutral")
	if strings.TrimSpace(string(b)) != "" {
		t.Fatal("stale dead neutral on shutdown")
	}
}
