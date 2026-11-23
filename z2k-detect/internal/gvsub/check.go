package gvsub

// Двухконтурное зондирование узлов видеокэша и адаптивная калибровка таймингов:
// Контур 1 (SO_MARK = 0x40000000, SNI=example.com) — обходит nfqws2 и проверяет
// базовую связность TCP/TLS без загрязнения кэшей;
// Контур 2 (activePolicyMark, реальный SNI) — проходит через nfqws2 под
// временным probe-охранником в .neutral, проверяя HTTP/204 и QUIC 2/2.

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/quicprobe"
	"github.com/necronicle/z2k/z2k-detect/internal/sockmark"
)

// Verdict — состояние адреса или префикса.
type Verdict int

const (
	VerdictUnknown Verdict = iota
	VerdictGoodDirect
	VerdictGoodGGC
	VerdictBadBypassable
	VerdictBadUnbypassable
	VerdictDeadL3
	VerdictDeadGGC

	// Совместимость имён PR 1 для существующих модульных тестов.
	Unknown = VerdictUnknown
	Good    = VerdictGoodDirect
	Bad     = VerdictBadUnbypassable
	Dead    = VerdictDeadL3
)

func (v Verdict) String() string {
	switch v {
	case VerdictGoodDirect:
		return "good_direct"
	case VerdictGoodGGC:
		return "good_ggc"
	case VerdictBadBypassable:
		return "bad_bypassable"
	case VerdictBadUnbypassable:
		return "bad_unbypassable"
	case VerdictDeadL3:
		return "dead_l3"
	case VerdictDeadGGC:
		return "dead_ggc"
	default:
		return "unknown"
	}
}

// IsUsable возвращает true, если узел способен отдавать трафик (напрямую или через обход).
func (v Verdict) IsUsable() bool {
	return v == VerdictGoodDirect || v == VerdictGoodGGC || v == VerdictBadBypassable
}

// Значения по умолчанию до первого замера живого RTT.
const (
	TCPTimeout    = 1 * time.Second
	TLSTimeout    = 1 * time.Second
	QUICTimeout   = 1500 * time.Millisecond
	ProbeSNI      = "example.com"
	DefaultPreSNI = "www.google.com"
)

var preflightSNICandidates = []string{
	"www.google.com",
	"example.com",
	"ya.ru",
	"vk.com",
	"gosuslugi.ru",
}

var (
	defaultOraclesV4 = []netip.Addr{
		netip.MustParseAddr("1.1.1.1"),
		netip.MustParseAddr("8.8.8.8"),
	}
	defaultOraclesV6 = []netip.Addr{
		netip.MustParseAddr("2606:4700:4700::1111"),
		netip.MustParseAddr("2001:4860:4860::8888"),
	}
)

// TimingParams — самокалибруемые тайминги в миллисекундах из реального RTT.
type TimingParams struct {
	TCPProbeTimeoutMs int64 `json:"tcp_probe_timeout_ms"`
	TLSProbeTimeoutMs int64 `json:"tls_probe_timeout_ms"`
	ResynDelayMs      int64 `json:"resyn_delay_ms"`
	PreflightGiveupMs int64 `json:"preflight_giveup_ms"`
	GGCStallGuardMs   int64 `json:"ggc_stall_guard_ms"`
}

func clampInt64(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// CalibrateTiming вычисляет адаптивные тайминги на базе измеренных RTT (мс).
func CalibrateTiming(baselineRTTMs, prefixRTTMs, ggcRTTMs int64) TimingParams {
	var tp TimingParams

	if baselineRTTMs <= 0 {
		tp.TCPProbeTimeoutMs = TCPTimeout.Milliseconds()
	} else {
		tp.TCPProbeTimeoutMs = clampInt64(4*baselineRTTMs, 800, 2500)
	}

	tlsRef := prefixRTTMs
	if tlsRef <= 0 {
		tlsRef = baselineRTTMs
	}
	if tlsRef <= 0 {
		tp.TLSProbeTimeoutMs = TLSTimeout.Milliseconds()
		tp.ResynDelayMs = 120
		tp.PreflightGiveupMs = 1500
	} else {
		tp.TLSProbeTimeoutMs = clampInt64(5*tlsRef, 900, 3000)
		tp.ResynDelayMs = clampInt64(int64(math.Round(1.25*float64(tlsRef))), 60, 320)
		tp.PreflightGiveupMs = clampInt64(6*tlsRef, 1100, 3200)
	}

	ggcRef := ggcRTTMs
	if ggcRef <= 0 {
		ggcRef = baselineRTTMs
	}
	if ggcRef <= 0 {
		tp.GGCStallGuardMs = 1800
	} else {
		tp.GGCStallGuardMs = clampInt64(8*ggcRef+1200, 1600, 3500)
	}

	return tp
}

// PrefixFor возвращает /24 для IPv4 или /48 для IPv6.
func PrefixFor(addr netip.Addr) netip.Prefix {
	a := addr.Unmap()
	if !a.IsValid() {
		return netip.Prefix{}
	}
	if a.Is4() {
		return netip.PrefixFrom(a, 24).Masked()
	}
	return netip.PrefixFrom(a, 48).Masked()
}

// Checker проверяет адрес (интерфейс совместимости PR 1).
type Checker interface {
	Check(ctx context.Context, addr netip.Addr) Verdict
}

// ProbeRequest задаёт параметры двухконтурной проверки узла.
type ProbeRequest struct {
	Addr               netip.Addr
	Host               string
	Kind               NodeKind
	PolicyMark         uint32
	TCPTimeout         time.Duration
	TLSTimeout         time.Duration
	BaselineRTT        time.Duration
	PrefixRTT          time.Duration
	WaitBeforeContour2 func(ctx context.Context) error
	SkipContour2       bool
	CheckQUIC          bool
}

// ProbeResult — результат двухконтурного зонда.
type ProbeResult struct {
	Verdict      Verdict
	RTT          time.Duration
	TLSFast      bool
	QUICChecked  bool
	QUICOK       bool
	UsedContour2 bool
}

// OracleReport — глобальное состояние HTTP/3 и базового канала до публичных узлов.
type OracleReport struct {
	BaselineRTT       time.Duration
	GlobalQUICBlocked bool
	PreflightSNI      string
	ReachableOracles  int
}

// Prober — полный двухконтурный интерфейс проверки кэш-узлов и глобальных оракулов.
type Prober interface {
	Probe(ctx context.Context, req ProbeRequest) ProbeResult
	ProbeOracles(ctx context.Context, policyMark uint32) OracleReport
	VerifyPolicyMark(ctx context.Context, policyMark uint32) uint32
}

// NetChecker — боевая реализация двухконтурных зондов по сети.
type NetChecker struct {
	NoV6      bool
	probePort uint16 // для тестов на петле; 0 => 443

	// Необязательные перехватчики для детерминированных модульных тестов.
	probeTLSFn  func(ctx context.Context, addr netip.Addr, sni string, mark uint32, dialBypass bool, tcpTO, tlsTO time.Duration) (tcpOK, tlsOK bool, rtt time.Duration)
	probeHTTPFn func(ctx context.Context, addr netip.Addr, host string, mark uint32, tcpTO, totalTO time.Duration) (ok, portal bool, dur time.Duration)
	probeQUICFn func(ctx context.Context, addr netip.Addr, sni string, mark uint32, timeout time.Duration) error
	oraclesFn   func() []netip.Addr
}

func (nc NetChecker) Check(ctx context.Context, addr netip.Addr) Verdict {
	tcpOK, tlsOK, _ := nc.dialAndTLS(ctx, addr, ProbeSNI, 0, true, TCPTimeout, TLSTimeout)
	if !tcpOK {
		return VerdictDeadL3
	}
	if tlsOK {
		return VerdictGoodDirect
	}
	return VerdictBadUnbypassable
}

// Probe выполняет полный двухконтурный прогон одного узла.
func (nc NetChecker) Probe(ctx context.Context, req ProbeRequest) ProbeResult {
	tcpTO := req.TCPTimeout
	if tcpTO <= 0 {
		tcpTO = TCPTimeout
	}
	tlsTO := req.TLSTimeout
	if tlsTO <= 0 {
		tlsTO = TLSTimeout
	}

	// Контур 1: SO_MARK = 0x40000000 (мимо nfqws2), нейтральный SNI=example.com.
	tcpOK, c1OK, rtt := nc.dialAndTLS(ctx, req.Addr, ProbeSNI, 0, true, tcpTO, tlsTO)
	if !tcpOK {
		if req.Kind == KindGVCacheISP {
			return ProbeResult{Verdict: VerdictDeadGGC}
		}
		return ProbeResult{Verdict: VerdictDeadL3}
	}

	c2Armed := false
	ensureC2Guard := func() error {
		if c2Armed {
			return nil
		}
		if req.WaitBeforeContour2 != nil {
			if err := req.WaitBeforeContour2(ctx); err != nil {
				return err
			}
		}
		c2Armed = true
		return nil
	}

	c2HTTPTO := tcpTO + tlsTO

	// Особая ветка для кэша провайдера (ISP GGC): нужна реальная проверка скорости HEAD /generate_204.
	if req.Kind == KindGVCacheISP {
		if req.SkipContour2 || req.Host == "" {
			if c1OK {
				return ProbeResult{Verdict: VerdictGoodGGC, RTT: rtt, TLSFast: true}
			}
			return ProbeResult{Verdict: VerdictUnknown, RTT: rtt}
		}
		if err := ensureC2Guard(); err != nil {
			return ProbeResult{Verdict: VerdictUnknown, RTT: rtt, UsedContour2: c2Armed}
		}
		httpOK, portal, httpDur := nc.contour2HTTP(ctx, req.Addr, req.Host, req.PolicyMark, tcpTO, c2HTTPTO)
		fastLimit := max(250*time.Millisecond, 3*rtt)
		var v Verdict
		fast := false
		if httpOK && !portal {
			if httpDur < fastLimit {
				v = VerdictGoodGGC
				fast = true
			} else {
				v = VerdictBadBypassable
			}
		} else {
			v = VerdictDeadGGC
		}
		res := ProbeResult{Verdict: v, RTT: rtt, TLSFast: fast, UsedContour2: c2Armed}
		if v != VerdictDeadGGC && req.CheckQUIC && req.Host != "" {
			res.QUICChecked = true
			res.QUICOK = nc.probeQUIC2of2(ctx, req, tlsTO)
		}
		return res
	}

	// Кэши Google / Play / c.youtube / SharedGFE.
	if c1OK {
		res := ProbeResult{Verdict: VerdictGoodDirect, RTT: rtt, TLSFast: true}
		if req.CheckQUIC && !req.SkipContour2 && req.Host != "" {
			if err := ensureC2Guard(); err == nil {
				res.UsedContour2 = c2Armed
				res.QUICChecked = true
				res.QUICOK = nc.probeQUIC2of2(ctx, req, tlsTO)
			}
		}
		return res
	}

	// C1 TCP прошёл, но C1 TLS(example.com) упал/завис.
	if req.SkipContour2 || req.Host == "" {
		res := ProbeResult{Verdict: VerdictUnknown, RTT: rtt}
		if req.SkipContour2 && req.CheckQUIC && req.Host != "" {
			if err := ensureC2Guard(); err == nil {
				res.UsedContour2 = c2Armed
				res.QUICChecked = true
				res.QUICOK = nc.probeQUIC2of2(ctx, req, tlsTO)
			}
		}
		return res
	}
	if err := ensureC2Guard(); err != nil {
		return ProbeResult{Verdict: VerdictUnknown, RTT: rtt, UsedContour2: c2Armed}
	}

	httpOK, portal, _ := nc.contour2HTTP(ctx, req.Addr, req.Host, req.PolicyMark, tcpTO, c2HTTPTO)
	verdict := VerdictBadUnbypassable
	if httpOK && !portal {
		verdict = VerdictBadBypassable
	}
	res := ProbeResult{Verdict: verdict, RTT: rtt, UsedContour2: c2Armed}
	if verdict == VerdictBadBypassable && req.CheckQUIC && req.Host != "" {
		res.QUICChecked = true
		res.QUICOK = nc.probeQUIC2of2(ctx, req, tlsTO)
	}
	return res
}

func (nc NetChecker) probeQUIC2of2(ctx context.Context, req ProbeRequest, timeout time.Duration) bool {
	qTO := timeout
	if qTO <= 0 || qTO > 2*time.Second {
		qTO = QUICTimeout
	}
	for i := 0; i < 2; i++ {
		if ctx.Err() != nil {
			return false
		}
		if err := nc.probeQUICOnce(ctx, req.Addr, req.Host, req.PolicyMark, qTO); err != nil {
			return false
		}
	}
	return true
}

func (nc NetChecker) oracleList() []netip.Addr {
	if nc.oraclesFn != nil {
		return nc.oraclesFn()
	}
	out := make([]netip.Addr, 0, len(defaultOraclesV4)+len(defaultOraclesV6))
	out = append(out, defaultOraclesV4...)
	if !nc.NoV6 {
		out = append(out, defaultOraclesV6...)
	}
	return out
}

// VerifyPolicyMark проверяет, что автоопределённая метка политики (POLICY_EXCLUDE=0)
// действительно выпускает трафик в рабочий WAN, а не в мёртвый VPN/маршрут.
func (nc NetChecker) VerifyPolicyMark(ctx context.Context, policyMark uint32) uint32 {
	if policyMark == 0 {
		return 0
	}
	oracles := nc.oracleList()
	if len(oracles) == 0 {
		return policyMark
	}

	// Проверяем доступность оракулов по C1 параллельно (макс. 3 слота), сохраняя приоритет порядка.
	c1OK := make([]bool, len(oracles))
	sem := make(chan struct{}, 3)
	var wg sync.WaitGroup
	for i, ora := range oracles {
		wg.Add(1)
		go func(idx int, addr netip.Addr) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				return
			}
			tcpOK, tlsOK, _ := nc.dialAndTLS(ctx, addr, ProbeSNI, 0, true, TCPTimeout, TLSTimeout)
			c1OK[idx] = tcpOK && tlsOK
		}(i, ora)
	}
	wg.Wait()

	var reachable []netip.Addr
	for i, ok := range c1OK {
		if ok {
			reachable = append(reachable, oracles[i])
			if len(reachable) >= 2 {
				break
			}
		}
	}
	if len(reachable) == 0 {
		// Нет уверенности в доступности WAN через C1 — не сбрасываем метку вслепую.
		return policyMark
	}

	// Проверяем выход с меткой политики параллельно по выбранным оракулам.
	c2Ctx, cancelC2 := context.WithCancel(ctx)
	defer cancelC2()
	resCh := make(chan bool, len(reachable))
	for _, ora := range reachable {
		go func(addr netip.Addr) {
			tcpOK, tlsOK, _ := nc.dialAndTLS(c2Ctx, addr, ProbeSNI, policyMark, false, TCPTimeout, TLSTimeout)
			ok := tcpOK && tlsOK
			if ok {
				cancelC2()
			}
			resCh <- ok
		}(ora)
	}
	for range reachable {
		if <-resCh {
			return policyMark
		}
	}
	return 0
}

// ProbeOracles выполняет периодическую проверку глобального HTTP/3 и базового RTT
// строго по контуру C1 (мимо nfqws2), не затрагивая autohostlist и circular.
func (nc NetChecker) ProbeOracles(ctx context.Context, _ uint32) OracleReport {
	oracles := nc.oracleList()
	type oracleProbe struct {
		tcpOK  bool
		rtt    time.Duration
		quicOK bool
	}
	results := make([]oracleProbe, len(oracles))
	sem := make(chan struct{}, 3)
	var wg sync.WaitGroup
	for i, ora := range oracles {
		wg.Add(1)
		go func(idx int, addr netip.Addr) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				return
			}
			tcpOK, _, rtt := nc.dialAndTLS(ctx, addr, ProbeSNI, 0, true, 1500*time.Millisecond, 1500*time.Millisecond)
			if !tcpOK {
				return
			}
			qOK := nc.probeQUICOnce(ctx, addr, ProbeSNI, sockmark.Bypass, QUICTimeout) == nil
			results[idx] = oracleProbe{tcpOK: true, rtt: rtt, quicOK: qOK}
		}(i, ora)
	}
	wg.Wait()

	var (
		rep         OracleReport
		rtts        []time.Duration
		quicOKCount int
		firstOracle netip.Addr
	)
	for i, r := range results {
		if !r.tcpOK {
			continue
		}
		rep.ReachableOracles++
		if !firstOracle.IsValid() {
			firstOracle = oracles[i]
		}
		if r.rtt > 0 {
			rtts = append(rtts, r.rtt)
		}
		if r.quicOK {
			quicOKCount++
		}
	}
	if len(rtts) > 0 {
		sort.Slice(rtts, func(i, j int) bool { return rtts[i] < rtts[j] })
		rep.BaselineRTT = rtts[len(rtts)/2]
	}
	if rep.ReachableOracles > 0 && quicOKCount == 0 {
		rep.GlobalQUICBlocked = true
	}
	if firstOracle.IsValid() {
		for _, cand := range preflightSNICandidates {
			if ctx.Err() != nil {
				break
			}
			tOK, tlsOK, _ := nc.dialAndTLS(ctx, firstOracle, cand, 0, true, 1200*time.Millisecond, 1200*time.Millisecond)
			if tOK && tlsOK {
				rep.PreflightSNI = cand
				break
			}
		}
	}
	return rep
}

func (nc NetChecker) dialAndTLS(ctx context.Context, addr netip.Addr, sni string, mark uint32, dialBypass bool, tcpTO, tlsTO time.Duration) (tcpOK, tlsOK bool, rtt time.Duration) {
	if nc.probeTLSFn != nil {
		return nc.probeTLSFn(ctx, addr, sni, mark, dialBypass, tcpTO, tlsTO)
	}
	ctrl := sockmark.ControlWithMark(mark)
	if dialBypass {
		ctrl = sockmark.Control
	}
	port := nc.probePort
	if port == 0 {
		port = 443
	}
	d := net.Dialer{Control: ctrl, Timeout: tcpTO}
	start := time.Now()
	c, err := d.DialContext(ctx, "tcp", netip.AddrPortFrom(addr.Unmap(), port).String())
	if err != nil {
		return false, false, 0
	}
	rtt = time.Since(start)
	if rtt <= 0 {
		rtt = time.Millisecond
	}
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetLinger(0)
	}
	defer c.Close()

	_ = c.SetDeadline(time.Now().Add(tlsTO))
	tc := tls.Client(c, &tls.Config{ServerName: sni, InsecureSkipVerify: true}) // #nosec G402 -- проверяем только факт ответа сервера
	err = tc.HandshakeContext(ctx)
	return true, isTLSServerReply(err), rtt
}

func isTLSServerReply(err error) bool {
	if err == nil {
		return true
	}
	var ae tls.AlertError
	var re tls.RecordHeaderError
	return errors.As(err, &ae) || errors.As(err, &re)
}

func (nc NetChecker) contour2HTTP(ctx context.Context, addr netip.Addr, host string, mark uint32, tcpTO, totalTO time.Duration) (ok, portal bool, dur time.Duration) {
	if nc.probeHTTPFn != nil {
		return nc.probeHTTPFn(ctx, addr, host, mark, tcpTO, totalTO)
	}
	dialTimeout := tcpTO
	if totalTO > dialTimeout {
		dialTimeout = totalTO
	}
	port := nc.probePort
	if port == 0 {
		port = 443
	}
	target := netip.AddrPortFrom(addr.Unmap(), port).String()
	tr := &http.Transport{
		DisableKeepAlives: true,
		DialTLSContext: func(dctx context.Context, _, _ string) (net.Conn, error) {
			dialer := net.Dialer{
				Control: sockmark.ControlWithMark(mark),
				Timeout: dialTimeout,
			}
			rawConn, err := dialer.DialContext(dctx, "tcp", target)
			if err != nil {
				return nil, err
			}
			if tc, ok := rawConn.(*net.TCPConn); ok {
				_ = tc.SetLinger(0)
			}
			tlsConn := tls.Client(rawConn, &tls.Config{
				ServerName:         host,
				InsecureSkipVerify: true, // #nosec G402 -- проверяем доступность кэша под реальным SNI
			})
			if err := tlsConn.HandshakeContext(dctx); err != nil {
				_ = rawConn.Close()
				return nil, err
			}
			return tlsConn, nil
		},
	}
	defer tr.CloseIdleConnections()

	client := &http.Client{
		Transport: tr,
		Timeout:   totalTO,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	reqCtx, cancel := context.WithTimeout(ctx, totalTO)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodHead, "https://"+host+"/generate_204", nil)
	if err != nil {
		return false, false, 0
	}
	start := time.Now()
	resp, err := client.Do(req)
	dur = time.Since(start)
	if err != nil {
		return false, false, dur
	}
	defer resp.Body.Close()
	bodyBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
	if isBlockPortalResponse(resp, bodyBytes) {
		return false, true, dur
	}
	return resp.StatusCode > 0 && resp.StatusCode < 500, false, dur
}

func (nc NetChecker) probeQUICOnce(ctx context.Context, addr netip.Addr, sni string, mark uint32, timeout time.Duration) error {
	if nc.probeQUICFn != nil {
		return nc.probeQUICFn(ctx, addr, sni, mark, timeout)
	}
	port := nc.probePort
	if port == 0 {
		port = 443
	}
	ctrl := sockmark.ControlWithMark(mark)
	_, _, err := quicprobe.ProbeInitial(ctx, netip.AddrPortFrom(addr.Unmap(), port), sni, ctrl, timeout)
	return err
}

func isAllowedGoogleRedirectHost(rawLoc string) bool {
	u, err := url.Parse(strings.TrimSpace(rawLoc))
	if err != nil {
		return false
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if host == "" || host == "ov.google.com" {
		return false
	}
	for _, dom := range []string{"googlevideo.com", "youtube.com", "gvt1.com", "google.com", "gstatic.com", "ggpht.com"} {
		if host == dom || strings.HasSuffix(host, "."+dom) {
			return true
		}
	}
	return false
}

func isBlockPortalResponse(resp *http.Response, body []byte) bool {
	if resp == nil {
		return false
	}
	if resp.StatusCode == http.StatusUnavailableForLegalReasons {
		return true
	}
	if loc := strings.ToLower(resp.Header.Get("Location")); loc != "" {
		if strings.HasPrefix(loc, "http://") {
			return true
		}
		for _, kw := range []string{"warning.rt.ru", "rkn.gov", "eais", "nap.gov", "fz139", "fz-139", "block", "forbidden", "zapret", "vigruzki", "lawfilter", "ov.google.com"} {
			if strings.Contains(loc, kw) {
				return true
			}
		}
		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			// Перенаправление кэша за пределы доверенных доменов Google/YouTube считается заглушкой ТСПУ.
			if !isAllowedGoogleRedirectHost(loc) {
				return true
			}
		}
	}
	if len(body) > 0 && resp.StatusCode != http.StatusNoContent {
		low := strings.ToLower(string(body))
		for _, kw := range []string{"warning.rt.ru", "rkn.gov", "eais", "nap.gov", "zapret-info", "lawfilter", "ov.google.com", "роскомнадзор", "единый реестр", "доступ ограничен"} {
			if strings.Contains(low, kw) {
				return true
			}
		}
	}
	return false
}
