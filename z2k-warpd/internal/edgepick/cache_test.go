package edgepick

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

func TestCacheIsAtomicAndScopedToCurrentWAN(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "edge-cache.json")
	old := Result{Step: account.Step{Transport: "wg", Host: "188.114.96.17", Port: 2408}, Country: "DE", Colo: "FRA", RTT: 28 * time.Millisecond, CheckedAt: now}
	if err := SaveCache(context.Background(), path, "wan0|192.0.2.2", []Result{old}); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(path); err != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("cache permission: %v %v", st, err)
	}
	got := LoadCache(path, "wan0|192.0.2.2", now.Add(time.Hour))
	if len(got) != 1 || got[0].Step != old.Step || got[0].Country != "DE" {
		t.Fatalf("cache hit: %+v", got)
	}
	if got := LoadCache(path, "wan1|192.0.2.3", now); len(got) != 0 {
		t.Fatalf("cross-WAN cache: %+v", got)
	}
	if got := LoadCache(path, "wan0|192.0.2.2", now.Add(25*time.Hour)); len(got) != 0 {
		t.Fatalf("stale cache: %+v", got)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := SaveCache(cancelled, path, "wan0|192.0.2.2", []Result{{Step: old.Step, Country: "RU", CheckedAt: now}}); err == nil {
		t.Fatal("cancelled save succeeded")
	}
	if got := LoadCache(path, "wan0|192.0.2.2", now); len(got) != 1 || got[0].Country != "DE" {
		t.Fatalf("cancelled save replaced old cache: %+v", got)
	}
}

func TestCacheIgnoresCorruptionAndMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "edge-cache.json")
	if got := LoadCache(path, "wan0|192.0.2.2", time.Now()); len(got) != 0 {
		t.Fatalf("missing cache: %+v", got)
	}
	if err := os.WriteFile(path, []byte("{broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := LoadCache(path, "wan0|192.0.2.2", time.Now()); len(got) != 0 {
		t.Fatalf("corrupt cache: %+v", got)
	}
}

func TestWANIdentityMatchesSelectedSourceInterface(t *testing.T) {
	ifaces := map[string][]string{"usb0": {"192.0.2.2"}, "wifi0": {"198.51.100.5"}}
	if got := identityForIP("192.0.2.2", ifaces); got != "usb0|192.0.2.2" {
		t.Fatalf("WAN identity = %q", got)
	}
	if got := identityForIP("198.51.100.5", ifaces); got != "wifi0|198.51.100.5" {
		t.Fatalf("WAN identity = %q", got)
	}
}
