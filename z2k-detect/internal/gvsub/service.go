package gvsub

// DNS/DoH-наблюдение, двухконтурное самокалибруемое зондирование кэш-узлов,
// публикация ipset и атомарной политики /tmp/z2k-gv-policy.dat для Lua/веб-панели.
import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/sockmark"
)

const (
	CacheTTL           = 60 * time.Second
	RecheckEvery       = CacheTTL / 2
	ActiveFor          = 30 * time.Minute
	IdleDrop           = time.Hour
	DefaultNeutralWait = 1050 * time.Millisecond
	DefaultMaxProbes   = 3
	OracleRefreshEvery = 12 * time.Minute
	maxObservedBytes   = 512 * 1024
)

type entry struct {
	verdict       Verdict
	checked, seen time.Time
	name          string
	kind          NodeKind
	quicChecked   bool
	quicOK        bool
	rttMs         int64
}

type prefixState struct {
	prefix      netip.Prefix
	kind        NodeKind
	verdict     Verdict
	c2Verdict   Verdict
	checked     time.Time
	c2Checked   bool
	quicChecked bool
	quicOK      bool
	rttMs       int64
	samples     int
	name        string
}

type observedKey struct {
	addr netip.Addr
	host string
}

type Service struct {
	Checker          Checker
	Prober           Prober
	Rules            Rules
	Now              func() time.Time
	StatusPath       string
	IPFile           string
	Whitelist        string
	PolicyPath       string
	ObservedPath     string
	DetectPolicyMark func() uint32
	NeutralWait      time.Duration // <=0 => DefaultNeutralWait; <0 => без ожидания (для тестов)
	ActiveWindow     time.Duration
	MaxProbes        int

	whitelist         whitelist
	mu                sync.Mutex
	wg                sync.WaitGroup
	published         map[netip.Addr]struct{}
	known             map[netip.Addr]*entry
	prefixes          map[netip.Prefix]*prefixState
	inflight          map[netip.Addr]chan struct{}
	probing           map[netip.Addr]time.Time
	prefixBusy        map[netip.Prefix]chan struct{}
	probeSem          chan struct{}
	probeCtx          context.Context
	cancelProbes      context.CancelFunc
	policyMark        uint32
	baselineRTTMs     int64
	ggcRTTMs          int64
	globalQUICBlocked bool
	preflightSNI      string
	lastOracleAt      time.Time
	obsMtime          time.Time
	obsSize           int64
	obsSeen           map[observedKey]time.Time
	closed            bool
	ipmu              sync.Mutex
	ipLast            string
	neutralMu         sync.Mutex
	statusMu          sync.Mutex
	policyMu          sync.Mutex
}

func (s *Service) init() {
	if s.known == nil {
		s.known = map[netip.Addr]*entry{}
		s.inflight = map[netip.Addr]chan struct{}{}
		s.probing = map[netip.Addr]time.Time{}
		s.prefixBusy = map[netip.Prefix]chan struct{}{}
	}
	if s.prefixes == nil {
		s.prefixes = map[netip.Prefix]*prefixState{}
	}
	if s.published == nil {
		s.published = map[netip.Addr]struct{}{}
	}
	if s.obsSeen == nil {
		s.obsSeen = map[observedKey]time.Time{}
	}
	if s.probeSem == nil {
		maxP := s.MaxProbes
		if maxP <= 0 {
			maxP = DefaultMaxProbes
		}
		s.probeSem = make(chan struct{}, maxP)
	}
	if s.probeCtx == nil {
		s.probeCtx, s.cancelProbes = context.WithCancel(context.Background())
	}
	if s.Now == nil {
		s.Now = time.Now
	}
}

func (s *Service) neutralWaitDuration() time.Duration {
	if s.NeutralWait < 0 {
		return 0
	}
	if s.NeutralWait == 0 {
		return DefaultNeutralWait
	}
	return s.NeutralWait
}

func (s *Service) activeWindow() time.Duration {
	if s.ActiveWindow > 0 {
		return s.ActiveWindow
	}
	return ActiveFor
}

func (s *Service) prober() Prober {
	if s.Prober != nil {
		return s.Prober
	}
	if p, ok := s.Checker.(Prober); ok {
		return p
	}
	return nil
}

func targetRank(kind HostKind) int {
	switch kind {
	case HostCluster:
		return 3
	case HostYouTubeCache:
		return 2
	case HostSharedGFE:
		return 1
	default:
		return 0
	}
}

func ewmaMs(prev, sample int64) int64 {
	if sample <= 0 {
		return prev
	}
	if prev <= 0 {
		return sample
	}
	return (prev*3 + sample + 2) / 4
}

func atomicWriteFile(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	// Явный chmod 0644 нужен на случай процесса с ограничительным umask: nfqws2
	// работает от nobody и должен читать файлы, созданные от root.
	_ = os.Chmod(tmp, 0o644)
	return os.Rename(tmp, path)
}

// OnDNS обрабатывает DNS-ответ (из NFQUEUE) или SNI+IP из DoH/DoT-наблюдений.
// Все HostCluster адреса (Google, ISP GGC и Play) публикуются в /tmp/z2k-gv-ips.txt
// синхронно до освобождения DNS; исключены только c.youtube.com и SharedGFE.
func (s *Service) OnDNS(name string, addrs []netip.Addr) <-chan struct{} {
	done := make(chan struct{})
	kind := ClassifyTarget(name)
	if kind == HostOther || s.whitelisted(name) {
		close(done)
		return done
	}
	s.mu.Lock()
	s.init()
	if s.closed {
		s.mu.Unlock()
		close(done)
		return done
	}
	now := s.Now()
	var waits []chan struct{}
	for _, a := range addrs {
		a = a.Unmap()
		if !a.IsValid() || !a.IsGlobalUnicast() {
			continue
		}
		if kind == HostCluster {
			s.published[a] = struct{}{}
		}
		e := s.known[a]
		if e == nil {
			e = &entry{}
			s.known[a] = e
		}
		e.seen = now
		// Сохраняем приоритет имён кэша (HostCluster > HostYouTubeCache > HostSharedGFE),
		// чтобы общий фронтенд не перетирал кластерный маркер для ipset и класса узла.
		if e.name == "" || targetRank(kind) >= targetRank(ClassifyTarget(e.name)) {
			e.name = name
		}
		e.kind = ClassifyNode(e.name, a)

		shouldProbe := (s.prober() != nil || s.Checker != nil) &&
			(e.checked.IsZero() || now.Before(e.checked) || now.Sub(e.checked) >= CacheTTL)
		if shouldProbe {
			waits = append(waits, s.startLocked(a))
		}
	}
	s.mu.Unlock()
	s.writeNeutral()
	s.writeIPs()
	s.writePolicy()
	go func() {
		for _, w := range waits {
			<-w
		}
		close(done)
	}()
	return done
}

// OnObserved принимает наблюдение (IP, SNI) из DoH/DoT канала и передаёт его
// в общую обработку OnDNS после санитаризации имени.
func (s *Service) OnObserved(name string, addrs []netip.Addr) <-chan struct{} {
	clean, ok := SanitizeHostname(name)
	if !ok {
		done := make(chan struct{})
		close(done)
		return done
	}
	return s.OnDNS(clean, addrs)
}

func (s *Service) startLocked(a netip.Addr) chan struct{} {
	if ch := s.inflight[a]; ch != nil {
		return ch
	}
	ch := make(chan struct{})
	s.inflight[a] = ch
	pctx := s.probeCtx
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer close(ch)
		s.runProbe(pctx, a)
	}()
	return ch
}

func (s *Service) runProbe(pctx context.Context, a netip.Addr) {
	// Семафор ограничивает параллелизм максимум 3 активными сокетными проверками.
	select {
	case s.probeSem <- struct{}{}:
	case <-pctx.Done():
		s.finishInflight(a)
		return
	}
	defer func() { <-s.probeSem }()

	pr := s.prober()
	if pr == nil {
		// Совместимость с простыми моками PR 1, реализующими только Checker.
		ctx, cancel := context.WithTimeout(pctx, TCPTimeout+TLSTimeout)
		defer cancel()
		v := Unknown
		if s.Checker != nil {
			v = s.Checker.Check(ctx, a)
		}
		s.mu.Lock()
		if e := s.known[a]; e != nil && !s.closed {
			e.verdict, e.checked = v, s.Now()
		}
		delete(s.inflight, a)
		s.mu.Unlock()
		s.writeNeutral()
		s.writePolicy()
		s.writeStatus()
		return
	}

	s.mu.Lock()
	e := s.known[a]
	if e == nil || s.closed {
		delete(s.inflight, a)
		s.mu.Unlock()
		return
	}
	host := e.name
	kind := e.kind
	if kind == KindUnknown && host != "" {
		kind = ClassifyNode(host, a)
	}
	pfx := PrefixFor(a)
	ps := s.prefixes[pfx]
	now := s.Now()
	baseRTT := s.baselineRTTMs
	ggcRTT := s.ggcRTTMs
	mark := s.policyMark
	var pfxRTT int64
	if ps != nil {
		pfxRTT = ps.rttMs
	}
	if kind == KindGVCacheISP && e.rttMs > 0 {
		pfxRTT = e.rttMs
	}
	s.mu.Unlock()

	var releasePfx func()
	skipC2HTTP := false
	checkQUIC := kind.IsCluster()

	// Для Google / Play сериализуем и дедуплицируем C2-проверки по /24 (IPv4) и /48 (IPv6).
	// ISP GGC (KindGVCacheISP) всегда проверяется индивидуально по каждому IP.
	if kind != KindGVCacheISP && pfx.IsValid() {
		releasePfx, skipC2HTTP, checkQUIC = s.acquirePrefixGuard(pctx, pfx, kind.IsCluster())
		if releasePfx != nil {
			defer releasePfx()
		}
	}

	if s.ProbeClosed() {
		s.finishInflight(a)
		return
	}

	timings := CalibrateTiming(baseRTT, pfxRTT, ggcRTT)
	tcpTO := time.Duration(timings.TCPProbeTimeoutMs) * time.Millisecond
	tlsTO := time.Duration(timings.TLSProbeTimeoutMs) * time.Millisecond
	if tlsTO < time.Duration(timings.PreflightGiveupMs)*time.Millisecond {
		tlsTO = time.Duration(timings.PreflightGiveupMs) * time.Millisecond
	}

	var probeGuardActive bool
	defer func() {
		if probeGuardActive {
			s.clearProbeGuard(a)
		}
	}()

	req := ProbeRequest{
		Addr:         a,
		Host:         host,
		Kind:         kind,
		PolicyMark:   mark,
		TCPTimeout:   tcpTO,
		TLSTimeout:   tlsTO,
		BaselineRTT:  time.Duration(baseRTT) * time.Millisecond,
		PrefixRTT:    time.Duration(pfxRTT) * time.Millisecond,
		SkipContour2: skipC2HTTP,
		CheckQUIC:    checkQUIC,
		WaitBeforeContour2: func(wctx context.Context) error {
			if err := s.armProbeGuard(wctx, a); err != nil {
				return err
			}
			probeGuardActive = true
			return nil
		},
	}

	// Выделяем достаточный бюджет времени на C1 + 1050ms ожидания Lua + C2 HTTP + 2x QUIC.
	c2HTTPTO := tcpTO + tlsTO
	budget := tcpTO + tlsTO + s.neutralWaitDuration() + c2HTTPTO + 2*QUICTimeout + 500*time.Millisecond
	ctx, cancel := context.WithTimeout(pctx, budget)
	defer cancel()

	res := pr.Probe(ctx, req)

	s.mu.Lock()
	if probeGuardActive {
		delete(s.probing, a)
		probeGuardActive = false
	}
	now = s.Now()
	if e := s.known[a]; e != nil && !s.closed {
		rttMs := res.RTT.Milliseconds()
		if res.RTT > 0 && rttMs <= 0 {
			rttMs = 1
		}
		if rttMs > 0 {
			e.rttMs = ewmaMs(e.rttMs, rttMs)
			if kind == KindGVCacheISP {
				s.ggcRTTMs = ewmaMs(s.ggcRTTMs, rttMs)
			} else if s.baselineRTTMs <= 0 && (res.Verdict == VerdictGoodDirect || res.Verdict == VerdictBadBypassable) {
				s.baselineRTTMs = rttMs
			}
		}

		// Если контур C2 был пропущен по дедупликации префикса (/24 или /48),
		// подставляем актуальный C2-вердикт и статус QUIC из префикса.
		ps := s.prefixes[pfx]
		if res.Verdict == VerdictUnknown && skipC2HTTP && ps != nil && ps.c2Checked {
			if ps.c2Verdict != VerdictUnknown {
				res.Verdict = ps.c2Verdict
			} else {
				res.Verdict = ps.verdict
			}
			if ps.quicChecked && !res.QUICChecked {
				res.QUICChecked = true
				res.QUICOK = ps.quicOK
			}
		} else if !checkQUIC && ps != nil && ps.quicChecked && !res.QUICChecked {
			res.QUICChecked = true
			res.QUICOK = ps.quicOK
		}

		e.verdict = res.Verdict
		e.checked = now
		if res.QUICChecked {
			e.quicChecked = true
			e.quicOK = res.QUICOK
		}

		// Обновляем статистику префикса (для DEAD_L3 не перетираем уже рабочий префикс).
		if pfx.IsValid() {
			if ps == nil {
				ps = &prefixState{prefix: pfx, kind: kind, name: host}
				s.prefixes[pfx] = ps
			}
			if e.kind != KindUnknown {
				ps.kind = kind
			}
			if e.name != "" {
				ps.name = host
			}
			if rttMs > 0 {
				ps.rttMs = ewmaMs(ps.rttMs, rttMs)
				ps.samples++
			}
			if kind != KindGVCacheISP {
				if res.UsedContour2 && (res.Verdict == VerdictBadBypassable || res.Verdict == VerdictBadUnbypassable) {
					ps.c2Checked = true
					ps.c2Verdict = res.Verdict
				}
				isDead := res.Verdict == VerdictDeadL3 || res.Verdict == VerdictDeadGGC
				if !isDead || ps.checked.IsZero() || ps.verdict == VerdictUnknown {
					// Не даём GoodDirect затирать уже зафиксированный C2-вердикт префикса.
					if !(res.Verdict == VerdictGoodDirect && ps.c2Verdict != VerdictUnknown) {
						ps.verdict = res.Verdict
					}
					ps.checked = now
				}
				if res.QUICChecked {
					ps.quicChecked = true
					ps.quicOK = res.QUICOK
					if ps.checked.IsZero() {
						ps.checked = now
					}
				}
			} else {
				// Для ISP GGC префикс не участвует в C2/L3 дедупликации; при смешанных
				// вердиктах разных IP внутри одного /24 или /48 возвращаем unknown.
				ps.verdict = s.ispPrefixSummaryLocked(pfx)
				ps.checked = now
				if res.QUICChecked {
					ps.quicChecked = true
					ps.quicOK = res.QUICOK
				}
			}
		}
	}
	delete(s.inflight, a)
	s.mu.Unlock()

	s.writeNeutral()
	s.writePolicy()
	s.writeStatus()
}

func (s *Service) ispPrefixSummaryLocked(pfx netip.Prefix) Verdict {
	summary := VerdictUnknown
	for a, e := range s.known {
		if e == nil || e.kind != KindGVCacheISP || e.verdict == VerdictUnknown || PrefixFor(a) != pfx {
			continue
		}
		if summary == VerdictUnknown {
			summary = e.verdict
			continue
		}
		if summary != e.verdict {
			return VerdictUnknown
		}
	}
	return summary
}

func (s *Service) acquirePrefixGuard(pctx context.Context, pfx netip.Prefix, needQUIC bool) (release func(), skipC2HTTP bool, checkQUIC bool) {
	for {
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return nil, false, false
		}
		now := s.Now()
		ps := s.prefixes[pfx]
		c2Fresh := ps != nil && ps.c2Checked && !ps.checked.IsZero() && !now.Before(ps.checked) && now.Sub(ps.checked) < CacheTTL
		quicFresh := ps != nil && ps.quicChecked && !ps.checked.IsZero() && !now.Before(ps.checked) && now.Sub(ps.checked) < CacheTTL
		if ch := s.prefixBusy[pfx]; ch != nil {
			s.mu.Unlock()
			select {
			case <-ch:
				continue
			case <-pctx.Done():
				return nil, false, false
			}
		}
		if c2Fresh && (!needQUIC || quicFresh) {
			s.mu.Unlock()
			return nil, true, false
		}
		ch := make(chan struct{})
		s.prefixBusy[pfx] = ch
		s.mu.Unlock()
		rel := func() {
			s.mu.Lock()
			delete(s.prefixBusy, pfx)
			s.mu.Unlock()
			close(ch)
		}
		return rel, c2Fresh, needQUIC && !quicFresh
	}
}

func (s *Service) ProbeClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

func (s *Service) finishInflight(a netip.Addr) {
	s.mu.Lock()
	delete(s.inflight, a)
	s.mu.Unlock()
}

func (s *Service) armProbeGuard(ctx context.Context, a netip.Addr) error {
	s.mu.Lock()
	s.init()
	if s.closed {
		s.mu.Unlock()
		return context.Canceled
	}
	_, already := s.probing[a]
	if !already {
		s.probing[a] = s.Now()
	}
	s.mu.Unlock()

	if already {
		return nil
	}

	// Выписываем probe <hex> синхронно ДО ожидания TTL RAM-кэша Lua.
	if s.StatusPath == "" {
		return nil
	}
	s.writeNeutral()

	wait := s.neutralWaitDuration()
	if wait <= 0 {
		return nil
	}
	t := time.NewTimer(wait)
	defer t.Stop()
	select {
	case <-t.C:
		if s.ProbeClosed() {
			return context.Canceled
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Service) clearProbeGuard(a netip.Addr) {
	s.mu.Lock()
	_, ok := s.probing[a]
	delete(s.probing, a)
	s.mu.Unlock()
	if ok {
		s.writeNeutral()
	}
}

// RefreshOracles обновляет activePolicyMark (с проверкой против мёртвого VPN/маршрута),
// базовый RTT, global_quic_blocked и preflight_sni.
func (s *Service) RefreshOracles(ctx context.Context) {
	pr := s.prober()
	if pr == nil {
		return
	}
	s.mu.Lock()
	s.init()
	closed := s.closed
	detectFn := s.DetectPolicyMark
	curMark := s.policyMark
	s.mu.Unlock()
	if closed {
		return
	}

	candMark := curMark
	if detectFn != nil {
		candMark = detectFn()
	}
	verifiedMark := pr.VerifyPolicyMark(ctx, candMark)
	if candMark != 0 && verifiedMark == 0 {
		log.Printf("gvsub: метка политики %#x ведёт в недоступный маршрут, откат к 0", candMark)
	}
	rep := pr.ProbeOracles(ctx, verifiedMark)

	s.mu.Lock()
	if !s.closed {
		s.policyMark = verifiedMark
		if rep.BaselineRTT > 0 {
			ms := rep.BaselineRTT.Milliseconds()
			if ms <= 0 {
				ms = 1
			}
			s.baselineRTTMs = ewmaMs(s.baselineRTTMs, ms)
		}
		if rep.ReachableOracles > 0 {
			s.globalQUICBlocked = rep.GlobalQUICBlocked
		}
		if rep.PreflightSNI != "" {
			s.preflightSNI = rep.PreflightSNI
		}
		s.lastOracleAt = s.Now()
	}
	s.mu.Unlock()

	s.writePolicy()
	s.writeStatus()
}

// ProcessObservedFile считывает новые пары (ip, sni) из /tmp/z2k-gv-observed.tsv
// (с ограничением объёма чтения до 512 KiB) и передаёт их в обработку OnObserved.
func (s *Service) ProcessObservedFile() int {
	if s.ObservedPath == "" {
		return 0
	}
	st, err := os.Stat(s.ObservedPath)
	if err != nil {
		return 0
	}
	s.mu.Lock()
	s.init()
	if s.closed || (s.obsMtime.Equal(st.ModTime()) && s.obsSize == st.Size()) {
		s.mu.Unlock()
		return 0
	}
	s.mu.Unlock()

	f, err := os.Open(s.ObservedPath)
	if err != nil {
		return 0
	}
	defer f.Close()

	// Если внешний файл вырос больше maxObservedBytes, читаем только хвост.
	if st.Size() > maxObservedBytes {
		_, _ = f.Seek(st.Size()-maxObservedBytes, io.SeekStart)
	}
	data, err := io.ReadAll(io.LimitReader(f, maxObservedBytes))
	if err != nil {
		return 0
	}
	if st.Size() > maxObservedBytes {
		if idx := bytes.IndexByte(data, '\n'); idx >= 0 && idx+1 < len(data) {
			data = data[idx+1:]
		}
	}

	type batchItem struct {
		host string
		addr netip.Addr
	}
	var items []batchItem
	now := s.Now()

	s.mu.Lock()
	s.obsMtime = st.ModTime()
	s.obsSize = st.Size()
	// Периодически чистим старые ключи дедупликации observed.tsv.
	if len(s.obsSeen) > 4096 {
		for k, ts := range s.obsSeen {
			if now.Sub(ts) > ActiveFor {
				delete(s.obsSeen, k)
			}
		}
	}
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var (
			foundAddr netip.Addr
			foundHost string
		)
		for _, tok := range strings.Fields(line) {
			if !foundAddr.IsValid() {
				if a, err := netip.ParseAddr(tok); err == nil {
					a = a.Unmap()
					if a.IsGlobalUnicast() {
						foundAddr = a
						continue
					}
				} else if ap, err := netip.ParseAddrPort(tok); err == nil {
					a := ap.Addr().Unmap()
					if a.IsGlobalUnicast() {
						foundAddr = a
						continue
					}
				}
			}
			if foundHost == "" {
				if h, ok := SanitizeHostname(tok); ok {
					foundHost = h
				}
			}
		}
		if !foundAddr.IsValid() || foundHost == "" {
			continue
		}
		key := observedKey{addr: foundAddr, host: foundHost}
		if prev, ok := s.obsSeen[key]; ok && !now.Before(prev) && now.Sub(prev) < RecheckEvery {
			continue
		}
		s.obsSeen[key] = now
		items = append(items, batchItem{host: foundHost, addr: foundAddr})
	}
	s.mu.Unlock()

	grouped := map[string][]netip.Addr{}
	var order []string
	for _, it := range items {
		if _, ok := grouped[it.host]; !ok {
			order = append(order, it.host)
		}
		grouped[it.host] = append(grouped[it.host], it.addr)
	}
	for _, h := range order {
		s.OnObserved(h, grouped[h])
	}
	return len(items)
}

func (s *Service) Tick() {
	if s.Rules != nil {
		if _, err := s.Rules.Ensure(); err != nil {
			log.Printf("gvsub: DNS rules: %v", err)
		}
	}
	s.ProcessObservedFile()

	needOracleRefresh := false
	s.mu.Lock()
	s.init()
	now := s.Now()
	actWin := s.activeWindow()
	hasActive := false
	if !s.closed {
		for a, e := range s.known {
			if !now.Before(e.seen) && now.Sub(e.seen) > IdleDrop {
				delete(s.known, a)
				continue
			}
			if now.Before(e.seen) || now.Sub(e.seen) < actWin {
				hasActive = true
				if (s.prober() != nil || s.Checker != nil) &&
					(e.checked.IsZero() || now.Before(e.checked) || now.Sub(e.checked) >= RecheckEvery) {
					s.startLocked(a)
				}
			}
		}
		for p, ps := range s.prefixes {
			if !ps.checked.IsZero() && !now.Before(ps.checked) && now.Sub(ps.checked) > IdleDrop {
				delete(s.prefixes, p)
			}
		}
		if hasActive && s.prober() != nil && (s.lastOracleAt.IsZero() || now.Before(s.lastOracleAt) || now.Sub(s.lastOracleAt) >= OracleRefreshEvery) {
			needOracleRefresh = true
		}
	}
	s.mu.Unlock()

	if needOracleRefresh {
		octx, ocancel := context.WithTimeout(s.probeCtx, 12*time.Second)
		s.RefreshOracles(octx)
		ocancel()
	}

	s.writeNeutral()
	s.writeIPs()
	s.writePolicy()
	s.writeStatus()
}

// Bad / Dead / Probe / Provider / Reject записываются в .neutral для Lua-детекторов nfqws2.
func (s *Service) writeNeutral() {
	if s.StatusPath == "" {
		return
	}
	s.neutralMu.Lock()
	defer s.neutralMu.Unlock()
	s.mu.Lock()
	var rows []string
	if !s.closed {
		for a, e := range s.known {
			hx := hex.EncodeToString(a.AsSlice())
			if _, ok := s.probing[a]; ok {
				rows = append(rows, "probe "+hx)
			}
			if providerCache(e.name, a) && e.verdict != VerdictBadBypassable {
				rows = append(rows, "provider "+hx)
			}
			switch e.verdict {
			case VerdictBadUnbypassable:
				rows = append(rows, "bad "+hx)
			case VerdictDeadL3, VerdictDeadGGC:
				rows = append(rows, "dead "+hx)
			case VerdictBadBypassable, VerdictGoodDirect, VerdictGoodGGC:
				if e.quicChecked && !e.quicOK {
					rows = append(rows, "reject "+hx)
				}
			}
		}
	}
	s.mu.Unlock()
	sort.Strings(rows)
	path := s.StatusPath + ".neutral"
	body := ""
	if len(rows) > 0 {
		body = strings.Join(rows, "\n") + "\n"
	} else {
		body = "\n"
	}
	_ = atomicWriteFile(path, []byte(body))
}

func (s *Service) Shutdown() {
	s.mu.Lock()
	s.init()
	s.closed = true
	if s.cancelProbes != nil {
		s.cancelProbes()
	}
	s.mu.Unlock()
	s.wg.Wait()
	s.writeNeutral()
	s.writePolicy()
	s.writeStatus()
}

type statusFile struct {
	Updated           time.Time      `json:"updated"`
	Known             int            `json:"known"`
	Bad               int            `json:"bad_seen"`
	Addrs             []knownAddr    `json:"addrs,omitempty"`
	Version           int            `json:"version,omitempty"`
	UsableV4          int            `json:"usable_v4,omitempty"`
	UsableV6          int            `json:"usable_v6,omitempty"`
	BaselineRTTMs     int64          `json:"baseline_rtt_ms,omitempty"`
	GGCRTTMs          int64          `json:"ggc_rtt_ms,omitempty"`
	GlobalQUICBlocked bool           `json:"global_quic_blocked,omitempty"`
	PreflightSNI      string         `json:"preflight_sni,omitempty"`
	ActivePolicyMark  string         `json:"active_policy_mark,omitempty"`
	Timings           *TimingParams  `json:"timings,omitempty"`
	Verdicts          map[string]int `json:"verdicts,omitempty"`
	Prefixes          []prefixStatus `json:"prefixes,omitempty"`
}

type knownAddr struct {
	Addr    string    `json:"addr"`
	Name    string    `json:"name,omitempty"`
	Seen    time.Time `json:"seen"`
	Kind    string    `json:"kind,omitempty"`
	Verdict string    `json:"verdict,omitempty"`
	QUICOK  bool      `json:"quic_ok,omitempty"`
	RTTMs   int64     `json:"rtt_ms,omitempty"`
	Prefix  string    `json:"prefix,omitempty"`
}

type prefixStatus struct {
	CIDR            string `json:"cidr"`
	Kind            string `json:"kind"`
	Verdict         string `json:"verdict"`
	QUICOK          bool   `json:"quic_ok"`
	RTTMs           int64  `json:"rtt_ms"`
	ResynDelayMs    int64  `json:"resyn_delay_ms"`
	PreflightGiveup int64  `json:"giveup_ms"`
	GGCStallGuard   int64  `json:"stall_ms"`
}

func parseVerdictString(s string) Verdict {
	switch s {
	case "good_direct", "good":
		return VerdictGoodDirect
	case "good_ggc":
		return VerdictGoodGGC
	case "bad_bypassable":
		return VerdictBadBypassable
	case "bad_unbypassable", "bad":
		return VerdictBadUnbypassable
	case "dead_l3", "dead":
		return VerdictDeadL3
	case "dead_ggc":
		return VerdictDeadGGC
	default:
		return VerdictUnknown
	}
}

func (s *Service) Restore() int {
	// Движок может жить дольше службы: не сужаем его набор при рестарте,
	// даже если status отсутствует или повреждён. Заглушки не входят в published.
	s.mu.Lock()
	s.init()
	if f, err := os.Open(s.IPFile); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if a, err := netip.ParseAddr(strings.TrimSpace(sc.Text())); err == nil && !a.IsUnspecified() && a.IsGlobalUnicast() {
				s.published[a] = struct{}{}
			}
		}
		if err := sc.Err(); err != nil {
			log.Printf("gvsub: чтение списка адресов: %v", err)
		}
		f.Close()
	}
	s.mu.Unlock()
	if s.StatusPath == "" {
		return 0
	}
	b, err := os.ReadFile(s.StatusPath)
	if err != nil {
		return 0
	}
	var st statusFile
	if json.Unmarshal(b, &st) != nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.init()
	now := s.Now()
	n := 0
	for _, k := range st.Addrs {
		a, err := netip.ParseAddr(k.Addr)
		if err != nil || now.Sub(k.Seen) > IdleDrop || k.Seen.After(now) {
			continue
		}
		a = a.Unmap()
		if s.known[a] == nil {
			e := &entry{
				seen:    k.Seen,
				name:    k.Name,
				kind:    ClassifyNode(k.Name, a),
				verdict: parseVerdictString(k.Verdict),
				quicOK:  k.QUICOK,
				rttMs:   k.RTTMs,
			}
			if e.quicOK {
				e.quicChecked = true
			}
			s.known[a] = e
			switch ClassifyTarget(k.Name) {
			case HostCluster:
				// Все HostCluster (включая ISP GGC и Play) публикуются в gv-ips.txt.
				s.published[a] = struct{}{}
			case HostYouTubeCache, HostSharedGFE:
				// Очищаем старое загрязнение /tmp/z2k-gv-ips.txt от redirector/manifest/c.youtube
				// после обновления сервиса, если status.json относит IP только к ним.
				delete(s.published, a)
			}
			n++
		}
	}
	return n
}

func (s *Service) snapshotMetricsLocked() (usableV4, usableV6 int, baseRTT, ggcRTT, globalPfxRTT int64, globalQUICBlocked bool, preSNI string, timings TimingParams) {
	var pfxRTTs, ispRTTs []int64
	for a, e := range s.known {
		if e.kind.IsCluster() && e.verdict.IsUsable() {
			if a.Is4() {
				usableV4++
			} else if a.Is6() {
				usableV6++
			}
		}
		if e.kind == KindGVCacheISP {
			if e.rttMs > 0 {
				ispRTTs = append(ispRTTs, e.rttMs)
			}
		} else if e.rttMs > 0 {
			pfxRTTs = append(pfxRTTs, e.rttMs)
		}
	}
	baseRTT = s.baselineRTTMs
	if baseRTT <= 0 && len(pfxRTTs) > 0 {
		sort.Slice(pfxRTTs, func(i, j int) bool { return pfxRTTs[i] < pfxRTTs[j] })
		baseRTT = pfxRTTs[len(pfxRTTs)/2]
	}
	ggcRTT = s.ggcRTTMs
	if ggcRTT <= 0 && len(ispRTTs) > 0 {
		sort.Slice(ispRTTs, func(i, j int) bool { return ispRTTs[i] < ispRTTs[j] })
		ggcRTT = ispRTTs[len(ispRTTs)/2]
	}
	if len(pfxRTTs) > 0 {
		sort.Slice(pfxRTTs, func(i, j int) bool { return pfxRTTs[i] < pfxRTTs[j] })
		globalPfxRTT = pfxRTTs[len(pfxRTTs)/2]
	} else {
		globalPfxRTT = baseRTT
	}
	timings = CalibrateTiming(baseRTT, globalPfxRTT, ggcRTT)
	globalQUICBlocked = s.globalQUICBlocked
	preSNI = s.preflightSNI
	if preSNI == "" {
		preSNI = DefaultPreSNI
	}
	return
}

// writePolicy атомарно записывает /tmp/z2k-gv-policy.dat с правами 0644 для
// быстрого O(1)-разбора в Lua (PR 3) и панели (PR 4).
func (s *Service) writePolicy() {
	if s.PolicyPath == "" {
		return
	}
	s.policyMu.Lock()
	defer s.policyMu.Unlock()

	s.mu.Lock()
	s.init()
	now := s.Now()
	usableV4, usableV6, baseRTT, ggcRTT, _, globalQUICBlocked, preSNI, timings := s.snapshotMetricsLocked()
	qBlocked := 0
	if globalQUICBlocked {
		qBlocked = 1
	}

	type pfxRow struct {
		cidr string
		ps   prefixState
	}
	var pfxRows []pfxRow
	for p, ps := range s.prefixes {
		if ps != nil {
			pfxRows = append(pfxRows, pfxRow{cidr: p.String(), ps: *ps})
		}
	}
	sort.Slice(pfxRows, func(i, j int) bool { return pfxRows[i].cidr < pfxRows[j].cidr })

	type ipRow struct {
		addr netip.Addr
		e    entry
		pt   TimingParams
	}
	var ipRows []ipRow
	for a, e := range s.known {
		if e == nil {
			continue
		}
		ipRTT := e.rttMs
		if ipRTT <= 0 {
			if ps := s.prefixes[PrefixFor(a)]; ps != nil && ps.rttMs > 0 {
				ipRTT = ps.rttMs
			}
		}
		ggcForRow := ggcRTT
		if e.kind == KindGVCacheISP && ipRTT > 0 {
			ggcForRow = ipRTT
		}
		ipRows = append(ipRows, ipRow{
			addr: a,
			e:    *e,
			pt:   CalibrateTiming(baseRTT, ipRTT, ggcForRow),
		})
	}
	sort.Slice(ipRows, func(i, j int) bool { return ipRows[i].addr.String() < ipRows[j].addr.String() })
	s.mu.Unlock()

	var sb strings.Builder
	fmt.Fprintf(&sb, "type=header\tversion=1\tupdated=%d\tusable_v4=%d\tusable_v6=%d\tbaseline_rtt_ms=%d\tggc_rtt_ms=%d\tglobal_quic_blocked=%d\tpreflight_sni=%s\tresyn_delay_ms=%d\tpreflight_giveup_ms=%d\tggc_stall_guard_ms=%d\n",
		now.Unix(), usableV4, usableV6, baseRTT, ggcRTT, qBlocked, preSNI,
		timings.ResynDelayMs, timings.PreflightGiveupMs, timings.GGCStallGuardMs)

	for _, r := range pfxRows {
		ggcForRow := ggcRTT
		if r.ps.kind == KindGVCacheISP && r.ps.rttMs > 0 {
			ggcForRow = r.ps.rttMs
		}
		pt := CalibrateTiming(baseRTT, r.ps.rttMs, ggcForRow)
		qok := 0
		if r.ps.quicOK {
			qok = 1
		}
		fmt.Fprintf(&sb, "type=prefix\taddr=%s\tkind=%s\tverdict=%s\tquic_ok=%d\trtt_ms=%d\tresyn_delay_ms=%d\tgiveup_ms=%d\tstall_ms=%d\n",
			r.cidr, r.ps.kind.String(), r.ps.verdict.String(), qok, r.ps.rttMs,
			pt.ResynDelayMs, pt.PreflightGiveupMs, pt.GGCStallGuardMs)
	}

	for _, r := range ipRows {
		qok := 0
		if r.e.quicOK {
			qok = 1
		}
		fmt.Fprintf(&sb, "type=ip\taddr=%s\tkind=%s\tverdict=%s\tquic_ok=%d\trtt_ms=%d\tresyn_delay_ms=%d\tgiveup_ms=%d\tstall_ms=%d\n",
			r.addr.String(), r.e.kind.String(), r.e.verdict.String(), qok, r.e.rttMs,
			r.pt.ResynDelayMs, r.pt.PreflightGiveupMs, r.pt.GGCStallGuardMs)
	}

	if err := atomicWriteFile(s.PolicyPath, []byte(sb.String())); err != nil {
		log.Printf("gvsub: запись policy.dat: %v", err)
	}
}

func (s *Service) writeStatus() {
	if s.StatusPath == "" {
		return
	}
	s.statusMu.Lock()
	defer s.statusMu.Unlock()
	s.mu.Lock()
	s.init()
	usableV4, usableV6, baseRTT, ggcRTT, _, globalQUICBlocked, preSNI, timings := s.snapshotMetricsLocked()
	verdicts := map[string]int{}
	st := statusFile{
		Updated:           s.Now(),
		Known:             len(s.known),
		Version:           1,
		UsableV4:          usableV4,
		UsableV6:          usableV6,
		BaselineRTTMs:     baseRTT,
		GGCRTTMs:          ggcRTT,
		GlobalQUICBlocked: globalQUICBlocked,
		PreflightSNI:      preSNI,
		Timings:           &timings,
		Verdicts:          verdicts,
	}
	if s.policyMark != 0 {
		st.ActivePolicyMark = fmt.Sprintf("0x%x", s.policyMark)
	}
	for a, e := range s.known {
		if e.verdict == VerdictBadUnbypassable || e.verdict == VerdictBadBypassable {
			st.Bad++
		}
		verdicts[e.verdict.String()]++
		var pfxStr string
		if p := PrefixFor(a); p.IsValid() {
			pfxStr = p.String()
		}
		st.Addrs = append(st.Addrs, knownAddr{
			Addr:    a.String(),
			Name:    e.name,
			Seen:    e.seen,
			Kind:    e.kind.String(),
			Verdict: e.verdict.String(),
			QUICOK:  e.quicOK,
			RTTMs:   e.rttMs,
			Prefix:  pfxStr,
		})
	}
	for p, ps := range s.prefixes {
		if ps == nil {
			continue
		}
		ggcForRow := ggcRTT
		if ps.kind == KindGVCacheISP && ps.rttMs > 0 {
			ggcForRow = ps.rttMs
		}
		pt := CalibrateTiming(baseRTT, ps.rttMs, ggcForRow)
		st.Prefixes = append(st.Prefixes, prefixStatus{
			CIDR:            p.String(),
			Kind:            ps.kind.String(),
			Verdict:         ps.verdict.String(),
			QUICOK:          ps.quicOK,
			RTTMs:           ps.rttMs,
			ResynDelayMs:    pt.ResynDelayMs,
			PreflightGiveup: pt.PreflightGiveupMs,
			GGCStallGuard:   pt.GGCStallGuardMs,
		})
	}
	s.mu.Unlock()
	sort.Slice(st.Addrs, func(i, j int) bool { return st.Addrs[i].Addr < st.Addrs[j].Addr })
	sort.Slice(st.Prefixes, func(i, j int) bool { return st.Prefixes[i].CIDR < st.Prefixes[j].CIDR })
	b, _ := json.MarshalIndent(st, "", "  ")
	_ = atomicWriteFile(s.StatusPath, b)
}

const ipFileSentinels = "0.0.0.0/32\n::/128\n"

// writeIPs публикует накопительный набор, независимо от known.
// Удаление IP до ServerHello может увести поток из A и оборвать пробу.
// Поэтому не удаляем даже после IdleDrop или добавления имени в whitelist.
// Предела нет: ожидаются сотни адресов за аптайм; /tmp сбрасывает перезагрузка.
func (s *Service) writeIPs() {
	if s.IPFile == "" {
		return
	}
	s.ipmu.Lock()
	defer s.ipmu.Unlock()
	s.mu.Lock()
	list := make([]string, 0, len(s.published))
	for a := range s.published {
		list = append(list, a.String())
	}
	s.mu.Unlock()
	sort.Strings(list)
	body := ipFileSentinels
	if len(list) > 0 {
		body += strings.Join(list, "\n") + "\n"
	}
	if body == s.ipLast {
		// Файл могли удалить или обрезать снаружи: восстанавливаем снимок.
		if b, err := os.ReadFile(s.IPFile); err == nil && string(b) == body {
			return
		}
	}
	if err := atomicWriteFile(s.IPFile, []byte(body)); err != nil {
		log.Printf("gvsub: список адресов: %v", err)
		return
	}
	s.ipLast = body
}

// Keep unused reference check to guarantee sockmark package alignment.
var _ = sockmark.Bypass
