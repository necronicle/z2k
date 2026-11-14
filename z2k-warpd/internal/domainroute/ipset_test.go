package domainroute

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func pairSetStubs(t *testing.T, stale string) (PairSet, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "commands")
	ipset := filepath.Join(dir, "ipset")
	iptables := filepath.Join(dir, "iptables")
	ipsetScript := "#!/bin/sh\necho \"ipset $*\" >> \"$Z2K_PAIR_LOG\"\n" +
		"if [ \"$1\" = restore ]; then while IFS= read -r l; do echo \"ipset $l\" >> \"$Z2K_PAIR_LOG\"; done; fi\n" +
		"if [ \"$1 $2\" = 'list -n' ]; then printf '%s\\n' \"$Z2K_STALE_SET\"; fi\n" +
		"if [ \"$1 $2\" = 'save z2kd_192.168.1.10' ]; then :; fi\n"
	iptablesScript := "#!/bin/sh\necho \"iptables $*\" >> \"$Z2K_PAIR_LOG\"\ncase \"$*\" in *' -C '*) exit 1;; esac\n"
	if err := os.WriteFile(ipset, []byte(ipsetScript), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(iptables, []byte(iptablesScript), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("Z2K_PAIR_LOG", log)
	t.Setenv("Z2K_STALE_SET", stale)
	return PairSet{Binary: ipset, IPTablesBinary: iptables}, log
}

func TestPairSetWritesClientScopedDestinationAndTimeout(t *testing.T) {
	s, log := pairSetStubs(t, "")
	now := time.Unix(100, 0)
	client := netip.MustParseAddr("192.168.1.10")
	dest := netip.MustParseAddr("8.8.8.8")
	if err := s.Apply([]Change{{Client: client, Dest: dest, Expiry: now.Add(20 * time.Second)}}, now); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	for _, part := range []string{
		"ipset create z2kd_192.168.1.10 hash:ip family inet timeout 3600 maxelem 8192 -exist",
		"ipset add z2kd_192.168.1.10 8.8.8.8 timeout 20 -exist",
		"iptables -w -t mangle -A PREROUTING -s 192.168.1.10/32 -m set --match-set z2kd_192.168.1.10 dst -j Z2K_WARP",
	} {
		if !strings.Contains(string(b), part) {
			t.Fatalf("missing %q in %s", part, b)
		}
	}
	if err := s.Apply([]Change{{Client: client, Dest: dest, Delete: true}}, now); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(log)
	if !strings.Contains(string(b), "ipset del z2kd_192.168.1.10 8.8.8.8 -exist") {
		t.Fatalf("missing deletion: %s", b)
	}
}

func TestPairSetReplacesStaleClientSets(t *testing.T) {
	s, log := pairSetStubs(t, "z2kd_192.168.1.99")
	if err := s.ReplaceAll(nil, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	got := string(b)
	for _, part := range []string{
		"iptables -w -t mangle -D PREROUTING -s 192.168.1.99/32 -m set --match-set z2kd_192.168.1.99 dst -j Z2K_WARP",
		"iptables -w -t mangle -D PREROUTING -s 192.168.1.99/32 -m set --match-set z2kd_192.168.1.99 dst -j MARK --set-xmark 0x989/0x989",
		"ipset destroy z2kd_192.168.1.99",
	} {
		if !strings.Contains(got, part) {
			t.Fatalf("missing %q in %s", part, got)
		}
	}
}

func TestPairSetDeduplicatesCreateAndMarkPerClientInBatch(t *testing.T) {
	s, log := pairSetStubs(t, "")
	now := time.Unix(100, 0)
	client := netip.MustParseAddr("192.168.1.10")
	d1 := netip.MustParseAddr("8.8.8.8")
	d2 := netip.MustParseAddr("8.8.4.4")
	if err := s.Apply([]Change{
		{Client: client, Dest: d1, Expiry: now.Add(20 * time.Second)},
		{Client: client, Dest: d2, Expiry: now.Add(30 * time.Second)},
	}, now); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(log)
	got := string(b)
	if n := strings.Count(got, "ipset create z2kd_192.168.1.10"); n != 1 {
		t.Fatalf("expected 1 ipset create for batch, got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "iptables -w -t mangle -A PREROUTING -s 192.168.1.10/32"); n != 1 {
		t.Fatalf("expected 1 iptables -A for batch, got %d:\n%s", n, got)
	}
}

// Ответ DNS ждёт записи: адреса пачки — одним запуском ipset, а правило метки
// известного устройства не проверяется на каждом ответе (iptables ~100 мс).
func TestPairSetBatchesAddsAndSkipsKnownMarks(t *testing.T) {
	s, log := pairSetStubs(t, "")
	now := time.Unix(100, 0)
	client := netip.MustParseAddr("192.168.1.10")
	marked := make(marks)
	batch := []Change{
		{Client: client, Dest: netip.MustParseAddr("8.8.8.8"), Expiry: now.Add(20 * time.Second)},
		{Client: client, Dest: netip.MustParseAddr("8.8.4.4"), Expiry: now.Add(20 * time.Second)},
	}
	for i := 0; i < 2; i++ {
		if err := s.apply(batch, now, marked); err != nil {
			t.Fatal(err)
		}
	}
	b, _ := os.ReadFile(log)
	got := string(b)
	if n := strings.Count(got, "ipset restore -exist"); n != 2 {
		t.Fatalf("expected one restore per batch, got %d:\n%s", n, got)
	}
	if n := strings.Count(got, "iptables -w -t mangle -C"); n != 1 {
		t.Fatalf("mark checked %d times for a known device:\n%s", n, got)
	}
	// Apply (проход таймера) проверяет правило всегда.
	if err := s.Apply(batch, now); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(log)
	if n := strings.Count(string(b), "iptables -w -t mangle -C"); n != 2 {
		t.Fatalf("timer pass must re-check the mark: %d", n)
	}
}
