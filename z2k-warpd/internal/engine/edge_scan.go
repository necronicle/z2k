package engine

import (
	"context"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/edgepick"
	"github.com/necronicle/z2k/z2k-warpd/internal/ladder"
)

const edgeScanBudget = 60 * time.Second

// scanEdges runs before ready/routing. One WG transport at a time uses the
// existing device key and shared TUN; a second session could steal replies.
func (e *Engine) scanEdges(ctx context.Context) []edgepick.Result {
	if e.cfg.Mode == ladder.ModeH2 || len(e.cfg.EdgeCandidates) == 0 {
		return nil
	}
	scanCtx, cancel := context.WithTimeout(ctx, edgeScanBudget)
	defer cancel()
	wan, err := e.cfg.EdgeWAN(e.cfg.EdgeCandidates[0].Host)
	if err != nil {
		e.cfg.Logf("edge: WAN fingerprint unavailable: %v", err)
	}
	if wan != "" {
		cached := edgepick.Rank(edgepick.LoadCache(e.cfg.EdgeCachePath, wan, e.cfg.Now()))
		for _, hint := range cached {
			if hint.Country == "" || hint.Country == "RU" {
				continue
			}
			result, ok := e.checkEdge(scanCtx, hint.Step)
			if ok && result.Country != "" && result.Country != "RU" {
				e.cfg.Logf("edge: cached foreign %s %s %s proved again", result.Colo, result.Country, result.Step.Host)
				return []edgepick.Result{result}
			}
			break
		}
	}
	var results []edgepick.Result
	for _, step := range e.cfg.EdgeCandidates {
		if scanCtx.Err() != nil {
			break
		}
		result, ok := e.checkEdge(scanCtx, step)
		if ok {
			results = append(results, result)
		}
	}
	if ctx.Err() != nil {
		return nil
	}
	if wan != "" && len(results) > 0 {
		if err := edgepick.SaveCache(ctx, e.cfg.EdgeCachePath, wan, results); err != nil {
			e.cfg.Logf("edge: cache save failed: %v", err)
		}
	}
	e.cfg.Logf("edge: checked up to %d candidates, %d verified with location", len(e.cfg.EdgeCandidates), len(results))
	return results
}

func (e *Engine) checkEdge(ctx context.Context, step account.Step) (edgepick.Result, bool) {
	if step.Transport != "wg" || step.Host == "" || step.Port < 1 || step.Port > 65535 {
		return edgepick.Result{}, false
	}
	tr, err := e.open(ctx, step, e.tunDev.Handle())
	if err != nil {
		e.cfg.Logf("edge: %s handshake failed: %v", ladder.Label(step), err)
		return edgepick.Result{}, false
	}
	defer tr.Close()
	if err := e.cfg.Probe(ctx, e.iface); err != nil {
		e.cfg.Logf("edge: %s no transit: %v", ladder.Label(step), err)
		return edgepick.Result{}, false
	}
	meta, rtt, loss, geoErr := e.cfg.GeoProbe(ctx, e.iface)
	result := edgepick.Result{Step: step, RTT: rtt, LossPct: loss, CheckedAt: e.cfg.Now()}
	if geoErr != nil || meta.Country == "" {
		e.cfg.Logf("edge: %s location unavailable: %v", ladder.Label(step), geoErr)
		return edgepick.Result{}, false
	}
	result.Colo, result.Country = meta.Colo, meta.Country
	if wan, err := e.cfg.EdgeWAN(step.Host); err == nil {
		result.WAN = wan
	}
	return result, true
}
