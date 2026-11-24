package gvsub

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestClassifyNodeAll5ClassesAndSanitize(t *testing.T) {
	googleIP := netip.MustParseAddr("74.125.99.17")
	ispIP4 := netip.MustParseAddr("46.61.136.172")
	ispIP6 := netip.MustParseAddr("2a01:620:1:a053::e")

	cases := []struct {
		name string
		addr netip.Addr
		want NodeKind
		str  string
		cl   bool
	}{
		{"rr1---sn-abcd.googlevideo.com", googleIP, KindGVCacheGoogle, "google", true},
		{"rr1---sn-isp.googlevideo.com", ispIP4, KindGVCacheISP, "isp", true},
		{"RR2.SN-ISP6.GOOGLEVIDEO.COM.", ispIP6, KindGVCacheISP, "isp", true},
		{"rr4---sn-play.gvt1.com", googleIP, KindPlayCache, "play", true},
		{"rr4---sn-play.gvt1.com", ispIP4, KindPlayCache, "play", true},
		{"rr1---sn-yt.c.youtube.com", googleIP, KindYouTubeCache, "yt", false},
		{"redirector.googlevideo.com", googleIP, KindSharedGFE, "gfe", false},
		{"manifest.googlevideo.com", ispIP4, KindSharedGFE, "gfe", false},
		{"www.youtube.com", googleIP, KindUnknown, "unknown", false},
	}
	for _, tc := range cases {
		got := ClassifyNode(tc.name, tc.addr)
		if got != tc.want || got.String() != tc.str || got.IsCluster() != tc.cl {
			t.Errorf("ClassifyNode(%q, %s) = %v (%q, cl=%v), want %v (%q, cl=%v)",
				tc.name, tc.addr, got, got.String(), got.IsCluster(), tc.want, tc.str, tc.cl)
		}
	}

	validHosts := map[string]string{
		"RR1---SN-ABC.GOOGLEVIDEO.COM.": "rr1---sn-abc.googlevideo.com",
		"  rr4---sn-k9.gvt1.com  ":      "rr4---sn-k9.gvt1.com",
		"rr2.sn-x.c.youtube.com":        "rr2.sn-x.c.youtube.com",
		"redirector.googlevideo.com":    "redirector.googlevideo.com",
	}
	for raw, want := range validHosts {
		got, ok := SanitizeHostname(raw)
		if !ok || got != want {
			t.Errorf("SanitizeHostname(%q) = (%q, %v), want (%q, true)", raw, got, ok, want)
		}
	}

	invalidHosts := []string{
		"",
		"example.com",
		"rr1---sn-a.googlevideo.com/evil",
		"rr1---sn-a.googlevideo.com\tbad",
		"-bad.googlevideo.com",
		"rr1..sn-a.googlevideo.com",
		"bad_host.googlevideo.com",
		strings.Repeat("a", 250) + ".googlevideo.com",
	}
	for _, raw := range invalidHosts {
		if got, ok := SanitizeHostname(raw); ok {
			t.Errorf("SanitizeHostname(%q) unexpectedly accepted -> %q", raw, got)
		}
	}
}

func TestCalibrateTimingClamps(t *testing.T) {
	cold := CalibrateTiming(0, 0, 0)
	if cold.TCPProbeTimeoutMs != 1000 || cold.TLSProbeTimeoutMs != 1000 || cold.ResynDelayMs != 120 || cold.PreflightGiveupMs != 1500 || cold.GGCStallGuardMs != 1800 {
		t.Fatalf("unexpected cold-start timings: %+v", cold)
	}

	fast := CalibrateTiming(10, 15, 10)
	if fast.TCPProbeTimeoutMs != 800 || fast.TLSProbeTimeoutMs != 900 || fast.ResynDelayMs != 60 || fast.PreflightGiveupMs != 1100 || fast.GGCStallGuardMs != 1600 {
		t.Fatalf("lower clamp failed: %+v", fast)
	}

	step0 := CalibrateTiming(45, 430, 25)
	if step0.TCPProbeTimeoutMs != 800 || step0.TLSProbeTimeoutMs != 2150 || step0.ResynDelayMs != 320 || step0.PreflightGiveupMs != 2580 || step0.GGCStallGuardMs != 1600 {
		t.Fatalf("step0 calibration mismatch: %+v", step0)
	}

	slow := CalibrateTiming(800, 900, 500)
	if slow.TCPProbeTimeoutMs != 2500 || slow.TLSProbeTimeoutMs != 3000 || slow.ResynDelayMs != 320 || slow.PreflightGiveupMs != 3200 || slow.GGCStallGuardMs != 3500 {
		t.Fatalf("upper clamp failed: %+v", slow)
	}
}

func TestNetCheckerTwoContourAllBranches(t *testing.T) {
	t.Run("Google DeadL3 never invokes WaitBeforeContour2 or C2", func(t *testing.T) {
		var waited, httpCalled, quicCalled bool
		nc := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return false, false, 0
			},
			probeHTTPFn: func(context.Context, netip.Addr, string, uint32, time.Duration, time.Duration) (bool, bool, time.Duration) {
				httpCalled = true
				return false, false, 0
			},
			probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error { quicCalled = true; return nil },
		}
		res := nc.Probe(context.Background(), ProbeRequest{
			Addr: netip.MustParseAddr("74.125.99.17"), Host: gvName, Kind: KindGVCacheGoogle, CheckQUIC: true,
			WaitBeforeContour2: func(context.Context) error { waited = true; return nil },
		})
		if res.Verdict != VerdictDeadL3 || waited || httpCalled || quicCalled {
			t.Fatalf("unexpected DeadL3 result: %+v waited=%v http=%v quic=%v", res, waited, httpCalled, quicCalled)
		}
	})

	t.Run("Google GoodDirect checks strict 2of2 QUIC under WaitBeforeContour2", func(t *testing.T) {
		var waitCalls, quicCalls int
		nc := NetChecker{
			probeTLSFn: func(_ context.Context, _ netip.Addr, sni string, _ uint32, bypass bool, _, _ time.Duration) (bool, bool, time.Duration) {
				if !bypass || sni != ProbeSNI {
					t.Fatalf("C1 expected bypass + %s, got bypass=%v sni=%s", ProbeSNI, bypass, sni)
				}
				return true, true, 42 * time.Millisecond
			},
			probeQUICFn: func(_ context.Context, _ netip.Addr, sni string, mark uint32, _ time.Duration) error {
				if waitCalls == 0 {
					t.Fatal("QUIC fired before WaitBeforeContour2")
				}
				if sni != gvName || mark != 0x0ffffaab {
					t.Fatalf("C2 QUIC got sni=%q mark=%#x", sni, mark)
				}
				quicCalls++
				return nil
			},
		}
		res := nc.Probe(context.Background(), ProbeRequest{
			Addr: netip.MustParseAddr("74.125.99.18"), Host: gvName, Kind: KindGVCacheGoogle,
			PolicyMark: 0x0ffffaab, CheckQUIC: true,
			WaitBeforeContour2: func(context.Context) error { waitCalls++; return nil },
		})
		if res.Verdict != VerdictGoodDirect || !res.QUICChecked || !res.QUICOK || waitCalls != 1 || quicCalls != 2 {
			t.Fatalf("unexpected GoodDirect result: %+v waitCalls=%d quicCalls=%d", res, waitCalls, quicCalls)
		}
	})

	t.Run("Strict 2of2 QUIC rejects 1of2 flaky", func(t *testing.T) {
		attempt := 0
		nc := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, true, 30 * time.Millisecond
			},
			probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error {
				attempt++
				if attempt == 1 {
					return nil
				}
				return errors.New("timeout on 2nd initial")
			},
		}
		res := nc.Probe(context.Background(), ProbeRequest{
			Addr: netip.MustParseAddr("173.194.164.212"), Host: gvName, Kind: KindGVCacheGoogle, CheckQUIC: true,
		})
		if res.Verdict != VerdictGoodDirect || !res.QUICChecked || res.QUICOK || attempt != 2 {
			t.Fatalf("expected QUICOK=false on 1/2 success, got %+v attempts=%d", res, attempt)
		}
	})

	t.Run("Google C1 blocked -> C2 HTTP 204 => BadBypassable + single WaitBeforeContour2", func(t *testing.T) {
		var waitCalls, httpCalls, quicCalls int
		nc := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 40 * time.Millisecond
			},
			probeHTTPFn: func(_ context.Context, _ netip.Addr, host string, mark uint32, _, _ time.Duration) (bool, bool, time.Duration) {
				if waitCalls != 1 {
					t.Fatalf("C2 HTTP fired before WaitBeforeContour2 (waitCalls=%d)", waitCalls)
				}
				if host != gvName || mark != 0x0ffffaab {
					t.Fatalf("C2 HTTP unexpected host=%q mark=%#x", host, mark)
				}
				httpCalls++
				return true, false, 90 * time.Millisecond
			},
			probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error {
				quicCalls++
				return errors.New("udp blocked")
			},
		}
		res := nc.Probe(context.Background(), ProbeRequest{
			Addr: netip.MustParseAddr("74.125.99.17"), Host: gvName, Kind: KindGVCacheGoogle,
			PolicyMark: 0x0ffffaab, CheckQUIC: true,
			WaitBeforeContour2: func(context.Context) error { waitCalls++; return nil },
		})
		if res.Verdict != VerdictBadBypassable || !res.UsedContour2 || !res.QUICChecked || res.QUICOK || waitCalls != 1 || httpCalls != 1 || quicCalls != 0 {
			t.Fatalf("unexpected BadBypassable result: %+v wait=%d http=%d quic=%d", res, waitCalls, httpCalls, quicCalls)
		}

		// Even when probeQUICFn returns nil (simulated Server Initial), BadBypassable skips QUIC probing and forces QUICOK=false.
		quicCallsNil := 0
		ncNil := NetChecker{
			probeTLSFn: nc.probeTLSFn,
			probeHTTPFn: func(context.Context, netip.Addr, string, uint32, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 90 * time.Millisecond
			},
			probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error {
				quicCallsNil++
				return nil
			},
		}
		resNil := ncNil.Probe(context.Background(), ProbeRequest{
			Addr: netip.MustParseAddr("74.125.99.27"), Host: gvName, Kind: KindGVCacheGoogle,
			PolicyMark: 0x0ffffaab, CheckQUIC: true,
		})
		if resNil.Verdict != VerdictBadBypassable || !resNil.QUICChecked || resNil.QUICOK || quicCallsNil != 0 {
			t.Fatalf("BadBypassable must force QUICOK=false even if probeQUICFn would return nil: %+v quic=%d", resNil, quicCallsNil)
		}
	})

	t.Run("Google C2 block portal => BadUnbypassable", func(t *testing.T) {
		nc := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 30 * time.Millisecond
			},
			probeHTTPFn: func(context.Context, netip.Addr, string, uint32, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return false, true, 50 * time.Millisecond
			},
		}
		res := nc.Probe(context.Background(), ProbeRequest{
			Addr: netip.MustParseAddr("74.125.99.20"), Host: gvName, Kind: KindGVCacheGoogle, CheckQUIC: true,
		})
		if res.Verdict != VerdictBadUnbypassable || res.QUICOK {
			t.Fatalf("expected BadUnbypassable on portal, got %+v", res)
		}
	})

	t.Run("ISP GGC classification: fast=GoodGGC, slow=BadBypassable, dead/fail=DeadGGC", func(t *testing.T) {
		ispAddr := netip.MustParseAddr("46.61.136.172")
		// Fast ISP GGC (< max(250ms, 3*20ms))
		ncFast := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 20 * time.Millisecond
			},
			probeHTTPFn: func(context.Context, netip.Addr, string, uint32, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 60 * time.Millisecond
			},
			probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error { return nil },
		}
		rFast := ncFast.Probe(context.Background(), ProbeRequest{Addr: ispAddr, Host: gvName, Kind: KindGVCacheISP, CheckQUIC: true})
		if rFast.Verdict != VerdictGoodGGC || !rFast.TLSFast || !rFast.QUICOK {
			t.Fatalf("expected fast ISP GoodGGC + QUICOK, got %+v", rFast)
		}

		// High RTT ISP node: rtt=100ms -> fastLimit=300ms -> 260ms is still GoodGGC!
		ncDist := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, true, 100 * time.Millisecond
			},
			probeHTTPFn: func(context.Context, netip.Addr, string, uint32, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 260 * time.Millisecond
			},
		}
		rDist := ncDist.Probe(context.Background(), ProbeRequest{Addr: ispAddr, Host: gvName, Kind: KindGVCacheISP})
		if rDist.Verdict != VerdictGoodGGC || !rDist.TLSFast {
			t.Fatalf("expected 260ms < 3*100ms GoodGGC, got %+v", rDist)
		}

		// Delayed after preflight/bypass: rtt=20ms, http=310ms (>= 250ms) => BadBypassable
		ncSlow := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 20 * time.Millisecond
			},
			probeHTTPFn: func(context.Context, netip.Addr, string, uint32, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, false, 310 * time.Millisecond
			},
		}
		rSlow := ncSlow.Probe(context.Background(), ProbeRequest{Addr: ispAddr, Host: gvName, Kind: KindGVCacheISP})
		if rSlow.Verdict != VerdictBadBypassable || rSlow.TLSFast {
			t.Fatalf("expected slow ISP BadBypassable, got %+v", rSlow)
		}

		// Failed HTTP => DeadGGC; failed TCP => DeadGGC
		ncFail := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return true, true, 20 * time.Millisecond
			},
			probeHTTPFn: func(context.Context, netip.Addr, string, uint32, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return false, false, 500 * time.Millisecond
			},
		}
		if r := ncFail.Probe(context.Background(), ProbeRequest{Addr: ispAddr, Host: gvName, Kind: KindGVCacheISP}); r.Verdict != VerdictDeadGGC {
			t.Fatalf("expected DeadGGC on HTTP failure, got %+v", r)
		}
		ncDead := NetChecker{
			probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
				return false, false, 0
			},
		}
		if r := ncDead.Probe(context.Background(), ProbeRequest{Addr: ispAddr, Host: gvName, Kind: KindGVCacheISP}); r.Verdict != VerdictDeadGGC {
			t.Fatalf("expected DeadGGC on TCP failure, got %+v", r)
		}
	})
}

func startSelfSignedTLSHTTPServer(t *testing.T, handler http.HandlerFunc) (netip.Addr, uint16) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "rr1---sn-loop.googlevideo.com"},
		DNSNames:     []string{"rr1---sn-loop.googlevideo.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	srv := &http.Server{
		Handler: handler,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
		},
	}
	go func() {
		_ = srv.ServeTLS(ln, "", "")
	}()
	t.Cleanup(func() { _ = srv.Close() })

	ap := netip.MustParseAddrPort(ln.Addr().String())
	return ap.Addr(), ap.Port()
}

func TestLoopbackContour2HTTPAndBlockPortalDetection(t *testing.T) {
	// Проверяем реальные NetChecker.contour2HTTP (включая DialTLSContext, SetLinger(0) и timeout)
	// и NetChecker.Probe на петлевом TLS+HTTP сервере.
	var mode atomic.Int32 // 0=204, 1=portal 302, 2=451
	addr, port := startSelfSignedTLSHTTPServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch mode.Load() {
		case 1:
			w.Header().Set("Location", "https://warning.rt.ru/block")
			w.WriteHeader(http.StatusFound)
		case 2:
			w.WriteHeader(http.StatusUnavailableForLegalReasons)
		default:
			w.WriteHeader(http.StatusNoContent)
		}
	})

	nc := NetChecker{probePort: port}
	ok, portal, _ := nc.contour2HTTP(context.Background(), addr, "rr1---sn-loop.googlevideo.com", 0, 500*time.Millisecond, time.Second)
	if !ok || portal {
		t.Fatalf("contour2HTTP 204 failed: ok=%v portal=%v", ok, portal)
	}

	mode.Store(1)
	ok, portal, _ = nc.contour2HTTP(context.Background(), addr, "rr1---sn-loop.googlevideo.com", 0, 500*time.Millisecond, time.Second)
	if ok || !portal {
		t.Fatalf("contour2HTTP 302->warning.rt.ru not flagged as portal: ok=%v portal=%v", ok, portal)
	}

	mode.Store(2)
	ok, portal, _ = nc.contour2HTTP(context.Background(), addr, "rr1---sn-loop.googlevideo.com", 0, 500*time.Millisecond, time.Second)
	if ok || !portal {
		t.Fatalf("contour2HTTP 451 not flagged as portal: ok=%v portal=%v", ok, portal)
	}

	// End-to-end NetChecker.Probe для KindGVCacheISP при 204 -> VerdictGoodGGC
	mode.Store(0)
	res := nc.Probe(context.Background(), ProbeRequest{
		Addr: addr, Host: "rr1---sn-loop.googlevideo.com", Kind: KindGVCacheISP,
		TCPTimeout: 500 * time.Millisecond, TLSTimeout: time.Second,
	})
	if res.Verdict != VerdictGoodGGC || !res.TLSFast {
		t.Fatalf("real loopback ISP Probe expected GoodGGC, got %+v", res)
	}
}

func TestGlobalHTTP3OracleAndPreflightSNIAndPolicyMarkFallback(t *testing.T) {
	ora1 := netip.MustParseAddr("1.1.1.1")
	ora2 := netip.MustParseAddr("8.8.8.8")

	// 1. Все оракулы отвечают, www.google.com режется ТСПУ -> preflight_sni откатывается на example.com
	ncOK := NetChecker{
		oraclesFn: func() []netip.Addr { return []netip.Addr{ora1, ora2} },
		probeTLSFn: func(_ context.Context, addr netip.Addr, sni string, mark uint32, bypass bool, _, _ time.Duration) (bool, bool, time.Duration) {
			if !bypass && mark == 0x0dead000 {
				return false, false, 0 // политика ведёт в мёртвый VPN
			}
			if sni == "www.google.com" {
				return true, false, 30 * time.Millisecond // заблокированный preflight SNI
			}
			return true, true, 36 * time.Millisecond
		},
		probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error { return nil },
	}
	rep := ncOK.ProbeOracles(context.Background(), 0)
	if rep.GlobalQUICBlocked || rep.ReachableOracles != 2 || rep.BaselineRTT != 36*time.Millisecond || rep.PreflightSNI != "example.com" {
		t.Fatalf("unexpected oracle report: %+v", rep)
	}
	if got := ncOK.VerifyPolicyMark(context.Background(), 0x0dead000); got != 0 {
		t.Fatalf("expected dead policyMark fallback to 0, got %#x", got)
	}
	if got := ncOK.VerifyPolicyMark(context.Background(), 0x0ffffaab); got != 0x0ffffaab {
		t.Fatalf("expected healthy policyMark 0x0ffffaab preserved, got %#x", got)
	}

	// 2. TCP жив, но QUIC режется глобально => GlobalQUICBlocked = true
	ncBlocked := NetChecker{
		oraclesFn: func() []netip.Addr { return []netip.Addr{ora1} },
		probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
			return true, true, 40 * time.Millisecond
		},
		probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error {
			return errors.New("quic timeout")
		},
	}
	repB := ncBlocked.ProbeOracles(context.Background(), 0)
	if !repB.GlobalQUICBlocked || repB.ReachableOracles != 1 {
		t.Fatalf("expected GlobalQUICBlocked=true, got %+v", repB)
	}

	// 3. Оффлайн: 0 доступных оракулов -> GlobalQUICBlocked=false и VerifyPolicyMark не сбрасывает метку вслепую
	ncOffline := NetChecker{
		oraclesFn: func() []netip.Addr { return []netip.Addr{ora1} },
		probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
			return false, false, 0
		},
	}
	repOff := ncOffline.ProbeOracles(context.Background(), 0)
	if repOff.GlobalQUICBlocked || repOff.ReachableOracles != 0 {
		t.Fatalf("offline must not assert global QUIC block: %+v", repOff)
	}
	if got := ncOffline.VerifyPolicyMark(context.Background(), 0x0ffffaab); got != 0x0ffffaab {
		t.Fatalf("offline should preserve policyMark, got %#x", got)
	}
}

type scriptProber struct {
	mu          sync.Mutex
	active      int
	maxActive   int
	probeCalls  map[netip.Addr]int
	c2Calls     map[netip.Prefix]int
	onProbe     func(req ProbeRequest) ProbeResult
	neutralSeen map[netip.Addr]bool
}

func (sp *scriptProber) Probe(ctx context.Context, req ProbeRequest) ProbeResult {
	sp.mu.Lock()
	sp.active++
	if sp.active > sp.maxActive {
		sp.maxActive = sp.active
	}
	if sp.probeCalls == nil {
		sp.probeCalls = map[netip.Addr]int{}
	}
	if sp.c2Calls == nil {
		sp.c2Calls = map[netip.Prefix]int{}
	}
	sp.probeCalls[req.Addr]++
	sp.mu.Unlock()
	defer func() {
		sp.mu.Lock()
		sp.active--
		sp.mu.Unlock()
	}()
	return sp.onProbe(req)
}

func (sp *scriptProber) ProbeOracles(context.Context, uint32) OracleReport {
	return OracleReport{BaselineRTT: 40 * time.Millisecond, PreflightSNI: "www.google.com", ReachableOracles: 2}
}

func (sp *scriptProber) VerifyPolicyMark(_ context.Context, m uint32) uint32 { return m }

func TestProbeGuardLifecycleAndLuaCacheWait(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "gvsub.json")
	target := netip.MustParseAddr("74.125.99.17")

	var waitElapsed time.Duration
	var sawProbeInFile bool
	var sp *scriptProber
	sp = &scriptProber{
		onProbe: func(req ProbeRequest) ProbeResult {
			t0 := time.Now()
			if req.WaitBeforeContour2 != nil {
				if err := req.WaitBeforeContour2(context.Background()); err != nil {
					t.Errorf("WaitBeforeContour2 err: %v", err)
				}
			}
			waitElapsed = time.Since(t0)
			nb, err := os.ReadFile(statusPath + ".neutral")
			if err == nil && strings.Contains(string(nb), "probe 4a7d6311\n") {
				sawProbeInFile = true
			}
			if st, serr := os.Stat(statusPath + ".neutral"); serr != nil || (runtime.GOOS != "windows" && st.Mode().Perm() != 0o644) {
				t.Errorf(".neutral perms=%v err=%v, want 0644", st, serr)
			}
			return ProbeResult{
				Verdict: VerdictBadBypassable, RTT: 400 * time.Millisecond,
				UsedContour2: true, QUICChecked: true, QUICOK: false,
			}
		},
	}

	s := &Service{
		Prober:      sp,
		StatusPath:  statusPath,
		IPFile:      filepath.Join(dir, "ips"),
		PolicyPath:  filepath.Join(dir, "policy.dat"),
		NeutralWait: 35 * time.Millisecond,
	}
	t.Cleanup(s.Shutdown)

	wait(t, s.OnDNS("rr1---sn-test.googlevideo.com", []netip.Addr{target}))

	if !sawProbeInFile {
		t.Fatal("probe <hex> was not written into .neutral before C2")
	}
	if waitElapsed < 30*time.Millisecond {
		t.Fatalf("WaitBeforeContour2 returned too early: %s", waitElapsed)
	}
	nb, err := os.ReadFile(statusPath + ".neutral")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(nb), "probe 4a7d6311") {
		t.Fatalf("stale probe guard lingered after probe finished: %q", string(nb))
	}
	if !strings.Contains(string(nb), "reject 4a7d6311") {
		t.Fatalf("expected UDP reject marker when C2 QUIC failed on BadBypassable: %q", string(nb))
	}
}

func TestConcurrencyCapMax3AndPrefixDedupVsISPPerIP(t *testing.T) {
	dir := t.TempDir()
	var sp *scriptProber
	sp = &scriptProber{
		onProbe: func(req ProbeRequest) ProbeResult {
			time.Sleep(15 * time.Millisecond)
			if req.Kind == KindGVCacheISP {
				if req.SkipContour2 {
					t.Errorf("ISP IP %s must NEVER skip Contour 2 via prefix dedup", req.Addr)
				}
				switch req.Addr.String() {
				case "2a01:620:1:a053::c":
					return ProbeResult{Verdict: VerdictDeadGGC}
				case "2a01:620:1:a053::d":
					return ProbeResult{Verdict: VerdictBadBypassable, RTT: 25 * time.Millisecond, UsedContour2: true}
				default:
					return ProbeResult{Verdict: VerdictGoodGGC, RTT: 18 * time.Millisecond, UsedContour2: true, TLSFast: true}
				}
			}
			// Google /24 & /48
			if !req.SkipContour2 && req.WaitBeforeContour2 != nil {
				_ = req.WaitBeforeContour2(context.Background())
				sp.mu.Lock()
				sp.c2Calls[PrefixFor(req.Addr)]++
				sp.mu.Unlock()
				return ProbeResult{
					Verdict: VerdictBadBypassable, RTT: 420 * time.Millisecond,
					UsedContour2: true, QUICChecked: true, QUICOK: false,
				}
			}
			return ProbeResult{Verdict: VerdictUnknown, RTT: 410 * time.Millisecond}
		},
	}

	s := &Service{
		Prober:      sp,
		StatusPath:  filepath.Join(dir, "gvsub.json"),
		IPFile:      filepath.Join(dir, "ips"),
		PolicyPath:  filepath.Join(dir, "policy.dat"),
		NeutralWait: -1,
	}
	t.Cleanup(s.Shutdown)

	// Запускаем пачкой 3 адреса в одном /24, 2 в одном /48 и 3 ISP-адреса в одном /48 (= 8 адресов).
	gAddrs := []netip.Addr{
		netip.MustParseAddr("74.125.99.17"),
		netip.MustParseAddr("74.125.99.18"),
		netip.MustParseAddr("74.125.99.19"),
		netip.MustParseAddr("2a00:1450:400f::1"),
		netip.MustParseAddr("2a00:1450:400f::2"),
	}
	ispAddrs := []netip.Addr{
		netip.MustParseAddr("2a01:620:1:a053::c"),
		netip.MustParseAddr("2a01:620:1:a053::d"),
		netip.MustParseAddr("2a01:620:1:a053::e"),
	}
	ch1 := s.OnDNS("rr1---sn-google.googlevideo.com", gAddrs)
	ch2 := s.OnDNS("rr1---sn-isp.googlevideo.com", ispAddrs)
	wait(t, ch1)
	wait(t, ch2)

	sp.mu.Lock()
	maxAct := sp.maxActive
	c2v4 := sp.c2Calls[netip.MustParsePrefix("74.125.99.0/24")]
	c2v6 := sp.c2Calls[netip.MustParsePrefix("2a00:1450:400f::/48")]
	ispC := sp.probeCalls[netip.MustParseAddr("2a01:620:1:a053::c")]
	ispD := sp.probeCalls[netip.MustParseAddr("2a01:620:1:a053::d")]
	ispE := sp.probeCalls[netip.MustParseAddr("2a01:620:1:a053::e")]
	sp.mu.Unlock()

	if maxAct > 3 || maxAct == 0 {
		t.Fatalf("semaphore cap violated: maxActive=%d (want 1..3)", maxAct)
	}
	if c2v4 != 1 || c2v6 != 1 {
		t.Fatalf("expected 1 C2 per /24 and /48, got v4=%d v6=%d", c2v4, c2v6)
	}
	if ispC != 1 || ispD != 1 || ispE != 1 {
		t.Fatalf("ISP GGC IPs must each be probed individually: c=%d d=%d e=%d", ispC, ispD, ispE)
	}

	s.mu.Lock()
	if s.known[netip.MustParseAddr("74.125.99.18")].verdict != VerdictBadBypassable {
		t.Errorf("deduped .18 did not inherit BadBypassable: %+v", s.known[netip.MustParseAddr("74.125.99.18")])
	}
	if s.known[netip.MustParseAddr("2a01:620:1:a053::c")].verdict != VerdictDeadGGC ||
		s.known[netip.MustParseAddr("2a01:620:1:a053::d")].verdict != VerdictBadBypassable ||
		s.known[netip.MustParseAddr("2a01:620:1:a053::e")].verdict != VerdictGoodGGC {
		t.Errorf("ISP per-IP verdicts mismatch")
	}
	s.mu.Unlock()
}

func TestObservedTSVFeedAndAtomicPolicyDatAndStatusJSON(t *testing.T) {
	dir := t.TempDir()
	obsPath := filepath.Join(dir, "observed.tsv")
	polPath := filepath.Join(dir, "policy.dat")
	ipPath := filepath.Join(dir, "ips")
	statusPath := filepath.Join(dir, "gvsub.json")

	// Записываем observed.tsv с разными форматами, комментариями и мусором + превышением 512 KiB в старой шапке
	var bigPad strings.Builder
	for i := 0; i < 6000; i++ {
		bigPad.WriteString("# old ignored comment line filling more than 512 KiB of padding bytes aaaaaaaaaaaaaaaa\n")
	}
	bigPad.WriteString("1795462600\t173.194.164.212\trr3---sn-doh.googlevideo.com.\n")
	bigPad.WriteString("rr4---sn-play.gvt1.com\t74.125.99.50\n")
	bigPad.WriteString("46.61.136.174 rr5---sn-isp.googlevideo.com\n")
	bigPad.WriteString("127.0.0.1\trr1---sn-bad.googlevideo.com\n")    // loopback отвергается
	bigPad.WriteString("173.194.164.212\tevil.example.com\n")          // чужой домен отвергается
	bigPad.WriteString("173.194.164.212\tbad/slash.googlevideo.com\n") // инъекция отвергается

	if err := os.WriteFile(obsPath, []byte(bigPad.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	var calls atomic.Int32
	var sp *scriptProber
	sp = &scriptProber{
		onProbe: func(req ProbeRequest) ProbeResult {
			calls.Add(1)
			switch req.Kind {
			case KindGVCacheISP:
				return ProbeResult{Verdict: VerdictGoodGGC, RTT: 22 * time.Millisecond, TLSFast: true}
			case KindPlayCache:
				return ProbeResult{Verdict: VerdictGoodDirect, RTT: 55 * time.Millisecond, QUICChecked: true, QUICOK: true}
			default:
				return ProbeResult{Verdict: VerdictBadBypassable, RTT: 430 * time.Millisecond, UsedContour2: true, QUICChecked: true, QUICOK: true}
			}
		},
	}

	now := time.Unix(1795462629, 0).UTC()
	s := &Service{
		Prober:           sp,
		StatusPath:       statusPath,
		IPFile:           ipPath,
		PolicyPath:       polPath,
		ObservedPath:     obsPath,
		DetectPolicyMark: func() uint32 { return 0x0ffffaab },
		NeutralWait:      -1,
		Now:              func() time.Time { return now },
	}
	t.Cleanup(s.Shutdown)

	s.RefreshOracles(context.Background())
	s.Tick()
	// Ждём завершения фоновых проверок для всех 3 валидных хостов из observed.tsv.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		n := 0
		for _, e := range s.known {
			if !e.checked.IsZero() {
				n++
			}
		}
		inf := len(s.inflight)
		s.mu.Unlock()
		if n == 3 && inf == 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	s.writePolicy()
	s.writeStatus()

	if calls.Load() != 3 {
		t.Fatalf("expected 3 sanitized observed probes, got %d", calls.Load())
	}
	// Повторное чтение без изменений файла не должно заново ставить в очередь.
	if n := s.ProcessObservedFile(); n != 0 {
		t.Fatalf("expected 0 new items on unchanged observed.tsv, got %d", n)
	}

	ipBytes, err := os.ReadFile(ipPath)
	if err != nil {
		t.Fatal(err)
	}
	ipStr := string(ipBytes)
	for _, wantIP := range []string{"173.194.164.212", "74.125.99.50", "46.61.136.174"} {
		if !strings.Contains(ipStr, wantIP+"\n") {
			t.Fatalf("missing observed HostCluster IP %s in ipfile %q", wantIP, ipStr)
		}
	}

	// Проверяем права 0644 и схему /tmp/z2k-gv-policy.dat.
	stPol, err := os.Stat(polPath)
	if err != nil || (runtime.GOOS != "windows" && stPol.Mode().Perm() != 0o644) {
		t.Fatalf("policy.dat perms=%v err=%v, want 0644", stPol, err)
	}
	polBytes, err := os.ReadFile(polPath)
	if err != nil {
		t.Fatal(err)
	}
	polStr := string(polBytes)
	for _, want := range []string{
		"type=header\tversion=1\tupdated=1795462629\tusable_v4=3\tusable_v6=0\tbaseline_rtt_ms=40\tggc_rtt_ms=22\tglobal_quic_blocked=0\tpreflight_sni=www.google.com",
		"resyn_delay_ms=", "preflight_giveup_ms=", "ggc_stall_guard_ms=",
		"type=prefix\taddr=173.194.164.0/24\tkind=google\tverdict=bad_bypassable\tquic_ok=0\trtt_ms=430",
		"type=prefix\taddr=74.125.99.0/24\tkind=play\tverdict=good_direct\tquic_ok=1\trtt_ms=55",
		"type=ip\taddr=46.61.136.174\tkind=isp\tverdict=good_ggc\tquic_ok=0\trtt_ms=22",
	} {
		if !strings.Contains(polStr, want) {
			t.Fatalf("policy.dat missing %q\n---\n%s", want, polStr)
		}
	}

	// Проверяем обратную совместимость и расширенные поля /tmp/z2k-gvsub.json.
	stBytes, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatal(err)
	}
	var sf statusFile
	if err := json.Unmarshal(stBytes, &sf); err != nil {
		t.Fatal(err)
	}
	if sf.Known != 3 || sf.Bad != 1 || sf.UsableV4 != 3 || sf.ActivePolicyMark != "0xffffaab" || sf.Timings == nil {
		t.Fatalf("unexpected statusFile telemetry: %+v", sf)
	}
}

func TestBlockPortalStrictHostMatchingAndBudgetAndMixedPrefixSafety(t *testing.T) {
	// 1. Query-string / ov.google.com redirect tricks must be flagged as block portals.
	portalCases := []struct {
		name   string
		status int
		loc    string
		body   string
		want   bool
	}{
		{"ok 204", 204, "", "", false},
		{"google video redirect", 302, "https://rr2---sn-x.googlevideo.com/generate_204", "", false},
		{"evil redirect embedding googlevideo in query", 302, "https://isp-stub.example/page?u=rr1.googlevideo.com", "", true},
		{"ov.google.com TSPU stub", 302, "https://ov.google.com/", "", true},
		{"body eais marker", 200, "", "<html>blocked by eais.rkn.gov.ru</html>", true},
	}
	for _, tc := range portalCases {
		resp := &http.Response{
			StatusCode: tc.status,
			Header:     http.Header{},
		}
		if tc.loc != "" {
			resp.Header.Set("Location", tc.loc)
		}
		if got := isBlockPortalResponse(resp, []byte(tc.body)); got != tc.want {
			t.Errorf("%s: isBlockPortalResponse=%v, want %v", tc.name, got, tc.want)
		}
	}

	// 2. SkipContour2=true + CheckQUIC=true (e.g. SharedGFE probed prefix first, then GVCacheGoogle)
	// must still run 2/2 QUIC probe when !c1OK.
	var quicRuns int
	ncSkip := NetChecker{
		probeTLSFn: func(context.Context, netip.Addr, string, uint32, bool, time.Duration, time.Duration) (bool, bool, time.Duration) {
			return true, false, 35 * time.Millisecond
		},
		probeQUICFn: func(context.Context, netip.Addr, string, uint32, time.Duration) error {
			quicRuns++
			return nil
		},
	}
	rSkip := ncSkip.Probe(context.Background(), ProbeRequest{
		Addr:         netip.MustParseAddr("74.125.99.21"),
		Host:         gvName,
		Kind:         KindGVCacheGoogle,
		SkipContour2: true,
		CheckQUIC:    true,
	})
	if rSkip.Verdict != VerdictUnknown || !rSkip.QUICChecked || !rSkip.QUICOK || quicRuns != 2 {
		t.Fatalf("SkipContour2+CheckQUIC failed to probe QUIC 2/2: %+v runs=%d", rSkip, quicRuns)
	}

	// 3. Mixed /24 prefix: BadBypassable (.17) -> GoodDirect (.18) -> !c1OK (.19)
	// must inherit BadBypassable (c2Verdict), NEVER GoodDirect!
	dir := t.TempDir()
	ip17 := netip.MustParseAddr("74.125.100.17")
	ip18 := netip.MustParseAddr("74.125.100.18")
	ip19 := netip.MustParseAddr("74.125.100.19")
	ip44 := netip.MustParseAddr("74.125.100.44") // SharedGFE in same /24
	var sp *scriptProber
	sp = &scriptProber{
		onProbe: func(req ProbeRequest) ProbeResult {
			switch req.Addr {
			case ip44:
				return ProbeResult{Verdict: VerdictBadBypassable, RTT: 40 * time.Millisecond, UsedContour2: true}
			case ip17:
				if req.SkipContour2 {
					return ProbeResult{Verdict: VerdictUnknown, RTT: 40 * time.Millisecond, QUICChecked: req.CheckQUIC, QUICOK: true}
				}
				return ProbeResult{Verdict: VerdictBadBypassable, RTT: 40 * time.Millisecond, UsedContour2: true, QUICChecked: req.CheckQUIC, QUICOK: true}
			case ip18:
				return ProbeResult{Verdict: VerdictGoodDirect, RTT: 35 * time.Millisecond, TLSFast: true}
			case ip19:
				if !req.SkipContour2 {
					t.Errorf("expected SkipContour2=true on .19")
				}
				return ProbeResult{Verdict: VerdictUnknown, RTT: 45 * time.Millisecond}
			}
			return ProbeResult{Verdict: VerdictUnknown}
		},
	}
	s := &Service{
		Prober:      sp,
		StatusPath:  filepath.Join(dir, "gvsub.json"),
		IPFile:      filepath.Join(dir, "ips"),
		PolicyPath:  filepath.Join(dir, "policy.dat"),
		NeutralWait: -1,
	}
	t.Cleanup(s.Shutdown)

	wait(t, s.OnDNS("redirector.googlevideo.com", []netip.Addr{ip44}))
	wait(t, s.OnDNS(gvName, []netip.Addr{ip17}))
	wait(t, s.OnDNS(gvName, []netip.Addr{ip18}))
	wait(t, s.OnDNS(gvName, []netip.Addr{ip19}))

	s.mu.Lock()
	v17 := s.known[ip17].verdict
	q17 := s.known[ip17].quicChecked && s.known[ip17].quicOK
	v18 := s.known[ip18].verdict
	v19 := s.known[ip19].verdict
	pfx := s.prefixes[PrefixFor(ip17)]
	s.mu.Unlock()

	if v17 != VerdictBadBypassable || !q17 || v18 != VerdictGoodDirect || v19 != VerdictBadBypassable {
		t.Fatalf("mixed /24 inheritance bug: v17=%v(q=%v) v18=%v v19=%v pfx=%+v", v17, q17, v18, v19, pfx)
	}

	// Effective policy.dat promotion under hasGoogleBlock: ip18 (false good_direct) -> bad_bypassable, quic_ok=0.
	polMixed, err := os.ReadFile(s.PolicyPath)
	if err != nil {
		t.Fatal(err)
	}
	polMixedStr := string(polMixed)
	if !strings.Contains(polMixedStr, "type=ip\taddr=74.125.100.18\tkind=google\tverdict=bad_bypassable\tquic_ok=0") {
		t.Fatalf("policy.dat did not promote ip18 under hasGoogleBlock:\n%s", polMixedStr)
	}

	// Clean line (!hasGVCensorship): single KindGVCacheGoogle with GoodDirect + QUICOK keeps good_direct and quic_ok=1.
	cleanDir := t.TempDir()
	ipClean := netip.MustParseAddr("74.125.101.18")
	sClean := &Service{
		Prober: &scriptProber{
			onProbe: func(ProbeRequest) ProbeResult {
				return ProbeResult{Verdict: VerdictGoodDirect, RTT: 30 * time.Millisecond, TLSFast: true, QUICChecked: true, QUICOK: true}
			},
		},
		StatusPath:  filepath.Join(cleanDir, "gvsub.json"),
		IPFile:      filepath.Join(cleanDir, "ips"),
		PolicyPath:  filepath.Join(cleanDir, "policy.dat"),
		NeutralWait: -1,
	}
	t.Cleanup(sClean.Shutdown)
	wait(t, sClean.OnDNS(gvName, []netip.Addr{ipClean}))
	polClean, err := os.ReadFile(sClean.PolicyPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(polClean), "type=ip\taddr=74.125.101.18\tkind=google\tverdict=good_direct\tquic_ok=1") {
		t.Fatalf("clean line policy.dat lost good_direct/quic_ok=1:\n%s", string(polClean))
	}

	// 4. VerifyPolicyMark and ProbeOracles finish within parallel budget when QUIC/routes stall.
	ncParallel := NetChecker{
		oraclesFn: func() []netip.Addr {
			return []netip.Addr{
				netip.MustParseAddr("1.1.1.1"),
				netip.MustParseAddr("8.8.8.8"),
				netip.MustParseAddr("2606:4700:4700::1111"),
				netip.MustParseAddr("2001:4860:4860::8888"),
			}
		},
		probeTLSFn: func(ctx context.Context, _ netip.Addr, _ string, mark uint32, bypass bool, _, _ time.Duration) (bool, bool, time.Duration) {
			if !bypass && mark == 0x0badc0de {
				select {
				case <-time.After(80 * time.Millisecond):
					return false, false, 0
				case <-ctx.Done():
					return false, false, 0
				}
			}
			return true, true, 20 * time.Millisecond
		},
		probeQUICFn: func(ctx context.Context, _ netip.Addr, _ string, _ uint32, _ time.Duration) error {
			select {
			case <-time.After(120 * time.Millisecond):
				return errors.New("quic blocked")
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	}
	t0 := time.Now()
	if got := ncParallel.VerifyPolicyMark(context.Background(), 0x0badc0de); got != 0 {
		t.Fatalf("expected 0 on dead mark, got %#x", got)
	}
	rep := ncParallel.ProbeOracles(context.Background(), 0)
	elapsed := time.Since(t0)
	if !rep.GlobalQUICBlocked || rep.ReachableOracles != 4 || rep.PreflightSNI != "www.google.com" {
		t.Fatalf("unexpected parallel oracle report: %+v", rep)
	}
	if elapsed > 400*time.Millisecond {
		t.Fatalf("oracle probes appear sequential (%s > 400ms)", elapsed)
	}

	// 5. runProbe budget must cover C1 TLS timeout + NeutralWait + C2 HTTP timeout + 2x QUIC without context cancel.
	var ctxCancelled bool
	spBudget := &scriptProber{
		onProbe: func(req ProbeRequest) ProbeResult {
			// Simulate C1 (20ms) + WaitBeforeContour2 + C2 HTTP (25ms) + 2x QUIC (20ms)
			// while verifying req.TLSTimeout >= PreflightGiveupMs and ctx stays alive.
			if req.WaitBeforeContour2 != nil {
				if err := req.WaitBeforeContour2(context.Background()); err != nil {
					ctxCancelled = true
				}
			}
			return ProbeResult{Verdict: VerdictBadUnbypassable, RTT: 20 * time.Millisecond, UsedContour2: true}
		},
	}
	// Ensure budget exceeds tcpTO + C1 tlsTO + neutralWait + C2 HTTP (tcpTO+tlsTO) + 2*QUICTimeout (~7.0s).
	sB := &Service{
		Prober: &budgetCheckProber{inner: spBudget, onCtxCheck: func(ctx context.Context) {
			dl, ok := ctx.Deadline()
			if !ok || time.Until(dl) < 6500*time.Millisecond {
				ctxCancelled = true
			}
		}},
		StatusPath:  filepath.Join(dir, "budget.json"),
		NeutralWait: 10 * time.Millisecond,
	}
	t.Cleanup(sB.Shutdown)
	wait(t, sB.OnDNS(gvName, []netip.Addr{netip.MustParseAddr("74.125.101.17")}))
	if ctxCancelled {
		t.Fatal("runProbe budget did not include sequential C1 + C2 HTTP + 2x QUIC headroom")
	}

	// 6. Mixed ISP /48 prefix produces deterministic VerdictUnknown on prefix row (never masks DeadGGC with GoodGGC).
	sISP := &Service{
		Prober: &scriptProber{
			onProbe: func(req ProbeRequest) ProbeResult {
				if req.Addr.String() == "2a01:620:1:a053::c" {
					return ProbeResult{Verdict: VerdictDeadGGC}
				}
				return ProbeResult{Verdict: VerdictGoodGGC, RTT: 10 * time.Millisecond, TLSFast: true}
			},
		},
		StatusPath:  filepath.Join(dir, "isp.json"),
		PolicyPath:  filepath.Join(dir, "isp_policy.dat"),
		NeutralWait: -1,
	}
	t.Cleanup(sISP.Shutdown)
	wait(t, sISP.OnDNS("rr1---sn-isp.googlevideo.com", []netip.Addr{
		netip.MustParseAddr("2a01:620:1:a053::c"),
		netip.MustParseAddr("2a01:620:1:a053::e"),
	}))
	polISP, err := os.ReadFile(sISP.PolicyPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(polISP), "type=prefix\taddr=2a01:620:1::/48\tkind=isp\tverdict=unknown") {
		t.Fatalf("expected deterministic unknown verdict on mixed ISP /48 prefix, got:\n%s", string(polISP))
	}
	if !strings.Contains(string(polISP), "type=ip\taddr=2a01:620:1:a053::c\tkind=isp\tverdict=dead_ggc") ||
		!strings.Contains(string(polISP), "type=ip\taddr=2a01:620:1:a053::e\tkind=isp\tverdict=good_ggc") {
		t.Fatalf("expected per-IP ISP verdicts in policy.dat, got:\n%s", string(polISP))
	}
}

type budgetCheckProber struct {
	inner      Prober
	onCtxCheck func(ctx context.Context)
}

func (b *budgetCheckProber) Probe(ctx context.Context, req ProbeRequest) ProbeResult {
	if b.onCtxCheck != nil {
		b.onCtxCheck(ctx)
	}
	return b.inner.Probe(ctx, req)
}
func (b *budgetCheckProber) ProbeOracles(ctx context.Context, m uint32) OracleReport {
	return b.inner.ProbeOracles(ctx, m)
}
func (b *budgetCheckProber) VerifyPolicyMark(ctx context.Context, m uint32) uint32 {
	return b.inner.VerifyPolicyMark(ctx, m)
}
