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
			// YouTube category hostlists — already covered by yt_tcp/gv_tcp/
			// yt_quic profiles; skip re-probing youtube.com / googlevideo.com.
			"/opt/zapret2/extra_strats/TCP/YT/List.txt",
			"/opt/zapret2/extra_strats/TCP/YT_GV/List.txt",
			"/opt/zapret2/extra_strats/UDP/YT/List.txt",
			"/opt/zapret2/lists/extra-domains.txt",
			"/opt/zapret2/lists/whitelist.txt",
			// Autohostlist (Z2K_AUTOHOSTLIST=1). The engine's own detector
			// publishes here; both files are wired into the rkn_tcp profile,
			// so a domain already found by nfqws2 is bypassed and must not be
			// probed and re-published by us into a second list.
			"/opt/zapret2/ipset/zapret-hosts-auto.txt",
			"/opt/zapret2/lists/autohostlist-domains.txt",
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
	//
	// Значение = «строгая запись» (nfqws2-форма `^domain`, покрывает только
	// сама себя). false = обычная запись, покрывает и поддомены.
	skipSet map[string]bool
}

func newState() *state {
	return &state{
		bypassed: make(map[string]struct{}),
		cooldown: make(map[string]time.Time),
		skipSet:  make(map[string]bool),
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

	// Evict expired cooldown entries. Everything older than ProbeCooldown
	// is dead weight by definition — the useful working set is whatever
	// was probed in the last few minutes, i.e. tens of entries. Without
	// this the map only grew: a household resolving 30-100k unique names a
	// month keeps every one of them forever, and a Go map never shrinks
	// even after delete, so the high-water mark is permanent. On a 64 MB
	// router that is not academic.
	go st.cooldownEvictLoop(ctx, cfg.ProbeCooldown)

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
			// Validate BEFORE the cooldown map is touched. In pkt mode we
			// see the DNS traffic of the whole LAN, so a DGA-infected
			// device feeds us unbounded garbage; letting invalid names
			// take cooldown slots means the map grows on input we were
			// never going to probe anyway.
			if err := prober.Validate(ev.Domain); err != nil {
				continue
			}
			if !st.eligible(ev.Domain, cfg.ProbeCooldown) {
				continue
			}
			// Fire-and-forget probe. Semaphore caps concurrency; if
			// saturated we skip rather than queue — flood-resistance
			// over completeness.
			select {
			case sem <- struct{}{}:
				// Commit the cooldown slot only once the probe is
				// actually going to run. Recording it before the
				// semaphore meant a dropped observation still burned
				// the full ProbeCooldown: the comment below promised
				// the domain "will be picked up on the next request",
				// but the next request hit the cooldown and was
				// dropped too. The semaphore saturates on every first
				// load of an unfamiliar site (20-40 names in ~2s
				// against ~1.3-2.7 probes/s), so this was the common
				// path, not the corner case — a blocked site took up
				// to ProbeCooldown to be noticed instead of one reload.
				st.markProbed(ev.Domain)
				go func(d string) {
					defer func() { <-sem }()
					st.probeAndPublish(ctx, d, cfg)
				}(ev.Domain)
			default:
				// Semaphore full — drop this observation without
				// burning the cooldown, so the same domain is retried
				// on the next client request.
			}
		}
	}
}

// eligible reports whether the domain is worth probing: not already
// bypassed, not covered by the skip-list, not in cooldown. It does NOT
// mutate state — the caller commits the slot with markProbed once it has
// a semaphore slot, so an observation we drop does not silence the domain
// for a full ProbeCooldown.
func (s *state) eligible(domain string, cooldown time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.bypassed[domain]; ok {
		return false
	}
	if s.skippedLocked(domain) {
		return false
	}
	if last, ok := s.cooldown[domain]; ok && time.Since(last) < cooldown {
		return false
	}
	return true
}

// markProbed commits the cooldown slot. Separate from eligible so the
// window between "decided to probe" and "actually probing" cannot leave a
// domain marked-but-never-probed.
func (s *state) markProbed(domain string) {
	s.mu.Lock()
	s.cooldown[domain] = time.Now()
	s.mu.Unlock()
}

// skippedLocked reports whether the domain is covered by the skip-list.
// Caller must hold s.mu.
//
// Matching is by SUFFIX, not by exact string. nfqws2 hostlists are suffix
// lists — an entry "googlevideo.com" is understood by the engine to cover
// "rr3---sn-4g5e6nez.googlevideo.com". Exact matching meant every unique
// subdomain of an explicitly-excluded domain was still probed and still
// took a cooldown slot; on a video-heavy household that is the bulk of
// both the probe traffic and the map growth, all of it against names the
// operator had already said to leave alone.
func (s *state) skippedLocked(domain string) bool {
	// Точное совпадение покрывает обе формы записи.
	if _, ok := s.skipSet[domain]; ok {
		return true
	}
	// Walk the parent labels: a.b.example.com -> b.example.com -> example.com
	//
	// Родитель покрывает поддомен ТОЛЬКО если он записан обычной формой.
	// Строгая форма `^domain` для того и существует, чтобы поддомены не
	// покрывались; раньше она вообще не работала — readHostlist клал ключ
	// вместе с '^', и с ним не совпадало ничто.
	for i := 0; i < len(domain); i++ {
		if domain[i] != '.' {
			continue
		}
		if strict, ok := s.skipSet[domain[i+1:]]; ok && !strict {
			return true
		}
	}
	return false
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
	next := make(map[string]bool)
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

// cooldownEvictLoop drops cooldown entries older than the cooldown window.
//
// Sweep cadence is the cooldown itself (floored at a minute so a
// pathological config cannot spin): every entry is then at most one extra
// window old before it goes, which bounds the map at "domains seen in the
// last two windows" instead of "every domain ever seen".
func (s *state) cooldownEvictLoop(ctx context.Context, cooldown time.Duration) {
	every := cooldown
	if every < time.Minute {
		every = time.Minute
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.evictCooldown(cooldown)
		}
	}
}

// evictCooldown removes entries whose cooldown has expired. Split out from
// the loop so it is testable without a clock.
func (s *state) evictCooldown(cooldown time.Duration) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for d, last := range s.cooldown {
		if time.Since(last) >= cooldown {
			delete(s.cooldown, d)
			n++
		}
	}
	return n
}

// readHostlist разбирает один хостлист nfqws2 в набор «домен → строгая ли
// запись».
//
// Форма `^domain` — задокументированный синтаксис nfqws2: «Если в начале идет
// символ ^, автоматический учет поддоменов отменяется для этого домена»
// (мануал bol-van, формат хостлистов). Раньше строка клалась в набор КАК ЕСТЬ,
// поэтому ключом становилось буквально "^domain" — а skippedLocked ищет
// "domain" и его родителей, и с таким ключом не совпадало НИКОГДА. То есть
// строгая запись не просто теряла строгость, она переставала действовать
// вовсе. Направление отказа худшее: whitelist.txt входит в SkipPaths, оператор
// пишет туда домен, чтобы обход НЕ включался, а демон такой домен пробивал и
// при вердикте Hot дописывал в discovered-domains.txt.
func readHostlist(path string, out map[string]bool) {
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
		line = strings.ToLower(line)
		if strings.HasPrefix(line, "^") {
			out[strings.TrimPrefix(line, "^")] = true
			continue
		}
		out[line] = false
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
