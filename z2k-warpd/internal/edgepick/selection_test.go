package edgepick

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

func TestRankPrefersReliableForeignEdgeOverFasterDomestic(t *testing.T) {
	got := Rank([]Result{
		{Step: account.Step{Host: "1.1.1.1"}, Country: "RU", RTT: 5 * time.Millisecond},
		{Step: account.Step{Host: "2.2.2.2"}, Country: "FI", RTT: 40 * time.Millisecond},
		{Step: account.Step{Host: "3.3.3.3"}, Country: "DE", RTT: 25 * time.Millisecond},
		{Step: account.Step{Host: "4.4.4.4"}, Country: "SE", RTT: 12 * time.Millisecond, LossPct: 20},
		{Step: account.Step{Host: "5.5.5.5"}, RTT: 3 * time.Millisecond},
	})
	want := []string{"3.3.3.3", "2.2.2.2", "4.4.4.4", "1.1.1.1", "5.5.5.5"}
	for i, host := range want {
		if got[i].Step.Host != host {
			t.Fatalf("rank[%d]=%s, want %s", i, got[i].Step.Host, host)
		}
	}
}

func TestCandidatesAreBoundedDiverseAndDeduplicated(t *testing.T) {
	ep := account.Endpoint{V4: "8.6.112.1", Ports: []int{2408, 4500}}
	pools := []netip.Prefix{netip.MustParsePrefix("8.6.112.0/24"), netip.MustParsePrefix("188.114.96.0/24")}
	got := Candidates(ep, []string{"8.6.112.1", "8.47.69.1"}, pools, 6, 42)
	if len(got) != 6 || got[0].Host != "8.6.112.1" || got[1].Host != "8.47.69.1" {
		t.Fatalf("candidate priority: %+v", got)
	}
	seen := map[string]bool{}
	diverse := false
	for _, step := range got {
		if seen[step.Host] || step.Port != 2408 || step.Transport != "wg" {
			t.Fatalf("duplicate or bad step: %+v", step)
		}
		seen[step.Host] = true
		if netip.MustParsePrefix("188.114.96.0/24").Contains(netip.MustParseAddr(step.Host)) {
			diverse = true
		}
	}
	if !diverse {
		t.Fatalf("no second network in %+v", got)
	}
	again := Candidates(ep, []string{"8.6.112.1", "8.47.69.1"}, pools, 6, 42)
	for i := range got {
		if got[i] != again[i] {
			t.Fatalf("sampling changed for same seed: %+v != %+v", got, again)
		}
	}
}

func TestReadPoolsSkipsUnapprovedAndBadLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pools.txt")
	data := "# WARP\n8.6.112.0/24\n188.114.96.0/24\n8.6.112.0/24\n192.0.2.0/24\n10.0.0.0/24\n8.6.112.0/16\ninvalid\n"
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	got := ReadPools(path)
	if len(got) != 2 || got[0].String() != "8.6.112.0/24" || got[1].String() != "188.114.96.0/24" {
		t.Fatalf("pools: %+v", got)
	}
}
