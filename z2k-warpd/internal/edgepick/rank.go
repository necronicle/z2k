package edgepick

import (
	"sort"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
)

// Result describes a candidate that carried traffic through WARP.
type Result struct {
	Step      account.Step  `json:"step"`
	Colo      string        `json:"colo,omitempty"`
	Country   string        `json:"country,omitempty"`
	RTT       time.Duration `json:"rtt"`
	LossPct   int           `json:"loss_pct"`
	CheckedAt time.Time     `json:"checked_at"`
	WAN       string        `json:"wan,omitempty"`
}

func tier(r Result) int {
	if r.Country != "" && r.Country != "RU" {
		return 0
	}
	if r.Country == "RU" {
		return 1
	}
	return 2
}

// Rank prefers confirmed foreign edges, then reliability, then latency.
func Rank(results []Result) []Result {
	out := append([]Result(nil), results...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if tier(a) != tier(b) {
			return tier(a) < tier(b)
		}
		if a.LossPct != b.LossPct {
			return a.LossPct < b.LossPct
		}
		return a.RTT < b.RTT
	})
	return out
}
