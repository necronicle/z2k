// Package engine wires the daemon pipeline:
//
//	tail dnsmasq log → parse DNS events → skip-if-known → probe → if HOT
//	→ append domain to discovered-domains.txt.
//
// State is intentionally ephemeral: in-memory dedup set + cooldown map.
// The discovered-domains.txt file is the source of truth for "we already
// added this to bypass". On restart the engine reloads the file into its
// dedup set. No state.tsv, no Hot vs Cache, no TTL, no scorer. Daemon is
// proactive: first HOT verdict → bypass active within seconds (nfqws2
// inotify reload on file append).
package engine

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/decision"
	"github.com/necronicle/z2k/z2k-detect/internal/dnssrc"
	"github.com/necronicle/z2k/z2k-detect/internal/prober"
)

// Config tunes daemon behaviour.
type Config struct {
	// DNSSource is the observation backend. nil means auto-detect at
	// startup (AGH log → dnsmasq log → AF_PACKET sniff).
	DNSSource dnssrc.Source

	// PublishPath is the nfqws2 hostlist file the engine appends to on
	// HOT verdicts. nfqws2 picks up additions via inotify; no service
	// restart required.
	PublishPath string

	// SkipPaths are operator-managed hostlists the engine consults to
	// avoid re-probing domains already covered (RKN, extra-domains,
	// whitelist). Loaded at startup + re-read every SkipReloadInterval.
	SkipPaths          []string
	SkipReloadInterval time.Duration

	// ProbeTimeout caps each of the four probe stages.
	ProbeTimeout time.Duration

	// ProbeCooldown is the minimum time between two probes of the same
	// domain. DNS-log floods will hit cooldown after the first probe.
	ProbeCooldown time.Duration

	// ProbeConcurrency caps simultaneous probes.
	ProbeConcurrency int

	// IgnorePeer suppresses observations from this client IP (the gateway
	// itself, since our own daemon HTTP probes would echo through the
	// source).
	IgnorePeer string
}

// Defaults returns the production config for the service-mode invocation.
// DNSSource is left nil so the caller can override; auto-detection runs
// in Run() if still nil at start.
func Defaults() Config {
	return Config{
		PublishPath: "/opt/zapret2/lists/discovered-domains.txt",
		SkipPaths: []string{
			"/opt/zapret2/extra_strats/TCP/RKN/List.txt",
			"/opt/zapret2/extra_strats/TCP_Discord.txt",
			"/opt/zapret2/lists/extra-domains.txt",
			"/opt/zapret2/lists/whitelist.txt",
		},
		SkipReloadInterval: 5 * time.Minute,
		ProbeTimeout:       1500 * time.Millisecond,
		ProbeCooldown:      5 * time.Minute,
		ProbeConcurrency:   8,
		IgnorePeer:         "192.168.1.1",
	}
}

// state is the in-memory bookkeeping the engine owns. Never persisted to
// disk by the daemon — discovered-domains.txt IS the persistence layer.
type state struct {
	mu sync.Mutex
	// bypassed tracks domains we've already appended to PublishPath. Used
	// for the append-with-dedup check; reloaded from disk at start.
	bypassed map[string]struct{}
	// cooldown is the last-probed timestamp per domain. Domains in
	// cooldown window skip re-probe.
	cooldown map[string]time.Time
	// skipSet is the union of SkipPaths content — domains already
	// covered by operator-managed hostlists. Refreshed periodically.
	skipSet map[string]struct{}
}

func newState() *state {
	return &state{
		bypassed: make(map[string]struct{}),
		cooldown: make(map[string]time.Time),
		skipSet:  make(map[string]struct{}),
	}
}

// Run blocks until ctx is cancelled. On clean cancel (SIGTERM) it returns
// context.Canceled — callers should treat that as a graceful stop, not a
// fatal error.
func Run(ctx context.Context, cfg Config) error {
	if cfg.PublishPath == "" {
		return errors.New("engine: PublishPath required")
	}
	if cfg.DNSSource == nil {
		src, err := dnssrc.Detect("")
		if err != nil {
			return fmt.Errorf("engine: detect dns source: %w", err)
		}
		cfg.DNSSource = src
	}

	st := newState()

	// Bootstrap: load whatever the previous daemon (or operator) left in
	// PublishPath so we don't re-probe and re-append the same domains.
	if err := st.loadBypassed(cfg.PublishPath); err != nil {
		log.Printf("engine: load %s: %v", cfg.PublishPath, err)
	}
	st.reloadSkipSet(cfg.SkipPaths)
	log.Printf("engine: bootstrap — source=%s, %d bypassed, %d skip",
		cfg.DNSSource.Name(), len(st.bypassed), len(st.skipSet))

	// Bounded semaphore for parallel probes. Keeps router CPU/network
	// usage predictable even under DNS-floods.
	sem := make(chan struct{}, max(1, cfg.ProbeConcurrency))

	// Periodic refresh of operator-managed skip lists so adding a
	// domain to extra-domains.txt via webpanel takes effect without a
	// daemon restart.
	go st.skipReloadLoop(ctx, cfg)

	events, srcErrs := cfg.DNSSource.Start(ctx)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err, ok := <-srcErrs:
			if !ok {
				srcErrs = nil
				continue
			}
			if err != nil {
				return fmt.Errorf("dnssrc(%s): %w", cfg.DNSSource.Name(), err)
			}
		case ev, ok := <-events:
			if !ok {
				return errors.New("engine: dns source stream closed")
			}
			if cfg.IgnorePeer != "" && ev.Peer == cfg.IgnorePeer {
				continue
			}
			if ev.Domain == "" {
				continue
			}
			if !st.shouldProbe(ev.Domain, cfg.ProbeCooldown) {
				continue
			}
			// Fire-and-forget probe. Semaphore caps concurrency; if
			// saturated we skip rather than queue — flood-resistance
			// over completeness.
			select {
			case sem <- struct{}{}:
				go func(d string) {
					defer func() { <-sem }()
					st.probeAndPublish(ctx, d, cfg)
				}(ev.Domain)
			default:
				// Semaphore full — drop this observation, the same
				// domain will reappear on the next client request and
				// be picked up then.
			}
		}
	}
}

// shouldProbe returns false when the domain is already bypassed, covered
// by a skip-list, or in cooldown. Mutates cooldown[domain] on return-true
// to commit the slot before we release the lock.
func (s *state) shouldProbe(domain string, cooldown time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.bypassed[domain]; ok {
		return false
	}
	if _, ok := s.skipSet[domain]; ok {
		return false
	}
	if last, ok := s.cooldown[domain]; ok && time.Since(last) < cooldown {
		return false
	}
	s.cooldown[domain] = time.Now()
	return true
}

// probeAndPublish runs one probe and appends to PublishPath iff the
// verdict is Hot AND the domain isn't already bypassed.
func (s *state) probeAndPublish(ctx context.Context, domain string, cfg Config) {
	if err := prober.Validate(domain); err != nil {
		return
	}
	res := prober.Probe(ctx, domain, cfg.ProbeTimeout)
	v := decision.Classify(res)
	switch v {
	case decision.Hot:
		s.mu.Lock()
		if _, ok := s.bypassed[domain]; ok {
			s.mu.Unlock()
			return
		}
		s.bypassed[domain] = struct{}{}
		s.mu.Unlock()
		if err := appendDomain(cfg.PublishPath, domain, res.FailureCode, res.FailureReason); err != nil {
			log.Printf("publish %s: %v", domain, err)
			// Roll back the in-memory mark so a retry on the next
			// observation can succeed.
			s.mu.Lock()
			delete(s.bypassed, domain)
			s.mu.Unlock()
			return
		}
		log.Printf("HOT %s → %s (%dms, %s)", domain, cfg.PublishPath, res.LatencyMS, res.FailureCode)
	case decision.Ignore:
		// Silent — too chatty otherwise. Operators wanting visibility
		// run `z2k-detect probe <domain>` manually.
	case decision.Watch:
		// Unused at present; placeholder for future verdicts.
	}
}

// appendDomain writes one line to PublishPath. The file may not exist on
// fresh install — install.sh touches it, but if missing we create. Lines
// are bare hostnames (nfqws2 hostlist format) with a "# z2k-detect: code"
// comment for operator triage.
func appendDomain(path, domain string, code prober.FailureCode, reason string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	// Provenance marker above the entry so an operator opening the file
	// in webpanel can grep which entries came from the daemon and why.
	ts := time.Now().UTC().Format(time.RFC3339)
	comment := fmt.Sprintf("# z2k-detect:%s:%s:%s\n", code, ts, sanitiseReason(reason))
	if _, err := f.WriteString(comment + domain + "\n"); err != nil {
		return err
	}
	return nil
}

func sanitiseReason(r string) string {
	// One-line, no tabs (provenance is parsed by webpanel via awk on
	// field-equality).
	r = strings.ReplaceAll(r, "\n", " ")
	r = strings.ReplaceAll(r, "\t", " ")
	if len(r) > 120 {
		r = r[:120]
	}
	return r
}

// loadBypassed reads PublishPath at startup, populating the dedup set.
// Comments and blanks are skipped; only well-formed hostnames are kept.
func (s *state) loadBypassed(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	s.mu.Lock()
	defer s.mu.Unlock()
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if err := prober.Validate(line); err != nil {
			continue
		}
		s.bypassed[line] = struct{}{}
	}
	return sc.Err()
}

func (s *state) reloadSkipSet(paths []string) {
	next := make(map[string]struct{})
	for _, p := range paths {
		readHostlist(p, next)
	}
	s.mu.Lock()
	s.skipSet = next
	s.mu.Unlock()
}

func (s *state) skipReloadLoop(ctx context.Context, cfg Config) {
	if cfg.SkipReloadInterval <= 0 {
		return
	}
	ticker := time.NewTicker(cfg.SkipReloadInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.reloadSkipSet(cfg.SkipPaths)
		}
	}
}

func readHostlist(path string, out map[string]struct{}) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out[strings.ToLower(line)] = struct{}{}
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
