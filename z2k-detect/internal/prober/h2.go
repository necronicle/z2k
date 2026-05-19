package prober

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/http2"
)

// h2MultiplexProbe opens an ALPN=h2 TLS connection to one of the
// reachable IPs and fires N concurrent GET / streams over the single
// multiplexed connection. The check exists because some TSPU deployments
// gate the cutoff on HTTP/2 multiplexing specifically: a single
// HTTP/1.1 GET (what probeHTTPStaged does) flows through cleanly, but
// concurrent H2 streams get severed past ~16KB. Without this stage we'd
// report "site works" while real browsers (H2 by default with any CDN)
// see the cutoff.
//
// Only runs when the prior staged probe finished with HTTPOK=true — if
// HTTP/1.1 already detected a cutoff, the verdict is settled, no need
// to spend another TLS RTT.
//
// On detection, overrides HTTPOK to false + sets FailureCode to
// CodeHTTPCutoff with a Reason tag identifying H2 multiplex as the
// trigger. Decision.Classify then promotes to Hot.
//
// Tunables intentionally hardcoded: 3 concurrent streams (enough to
// trigger multiplex-gated cutoffs without DoS'ing the target), 32KB
// per-stream cap matching probeHTTPStaged for consistency.
const h2ConcurrentStreams = 3

func runH2MultiplexProbe(r *Result, reachableIPs []string, sni string, timeout time.Duration) {
	if r.HTTPOK == nil || !*r.HTTPOK {
		return // HTTP/1.1 already caught a failure
	}
	if len(reachableIPs) == 0 {
		return
	}
	ip := reachableIPs[0]

	// Dedicated marked dialer so the H2 probe also bypasses our own
	// nfqws2 — same SO_MARK trick as the TCP/TLS stage. Without this
	// the H2 probe could see a "works" result purely because nfqws2 is
	// already running bypass for this destination.
	dialer := markedDialer(0)
	dialer.Timeout = timeout

	rawConn, err := dialer.Dial("tcp", net.JoinHostPort(ip, "443"))
	if err != nil {
		// TCP dial failed on a path that just succeeded — flaky path.
		// Don't pollute the verdict; leave HTTPOK=true as the
		// HTTP/1.1 stage saw it. Operators can rerun.
		return
	}
	tlsConn := tls.Client(rawConn, &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true, // #nosec G402 — reachability probe
		NextProtos:         []string{"h2"},
	})
	tlsConn.SetDeadline(time.Now().Add(timeout))
	if err := tlsConn.HandshakeContext(context.Background()); err != nil {
		tlsConn.Close()
		return
	}
	if tlsConn.ConnectionState().NegotiatedProtocol != "h2" {
		// Server doesn't speak H2 (rare for any modern site / CDN).
		// Nothing to test here.
		tlsConn.Close()
		return
	}

	tr := &http2.Transport{}
	cc, err := tr.NewClientConn(tlsConn)
	if err != nil {
		tlsConn.Close()
		return
	}
	defer cc.Close()

	var wg sync.WaitGroup
	cutoffReason := make(chan string, h2ConcurrentStreams)

	for i := 0; i < h2ConcurrentStreams; i++ {
		wg.Add(1)
		go func(streamIdx int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			req, err := http.NewRequestWithContext(ctx, "GET", "https://"+sni+"/", nil)
			if err != nil {
				return
			}
			req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; z2k-detect)")
			resp, err := cc.RoundTrip(req)
			if err != nil {
				cutoffReason <- fmt.Sprintf("stream %d: %s",
					streamIdx, sanitizeH2Err(err))
				return
			}
			defer resp.Body.Close()
			n, readErr := io.Copy(io.Discard, io.LimitReader(resp.Body, httpReadLimit))
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				cutoffReason <- fmt.Sprintf("stream %d cut at %d bytes: %s",
					streamIdx, n, sanitizeH2Err(readErr))
				return
			}
			// Success: drained ≥some bytes or clean EOF.
		}(i)
	}
	wg.Wait()
	close(cutoffReason)

	var reasons []string
	for r := range cutoffReason {
		reasons = append(reasons, r)
	}
	if len(reasons) == 0 {
		return // all streams clean
	}

	// Flag the cutoff. We keep CodeHTTPCutoff (rather than minting a
	// new code) so decision.Classify and the existing skip-list
	// logic continue to work unchanged; the Reason distinguishes the
	// H2 path for operator triage.
	f := false
	r.HTTPOK = &f
	r.TLSOK = true // TLS itself was fine
	r.FailureCode = CodeHTTPCutoff
	r.FailureReason = "http_cutoff (h2 multiplex): " + strings.Join(reasons, "; ")
}

// sanitizeH2Err trims Go's verbose H2 error prefixes for readable
// Reason output. http2: stream error: stream ID X; sent ENHANCE_YOUR_CALM
// becomes just the salient bit.
func sanitizeH2Err(err error) string {
	s := err.Error()
	for _, prefix := range []string{"http2: ", "tls: "} {
		s = strings.TrimPrefix(s, prefix)
	}
	if i := strings.Index(s, "stream ID "); i >= 0 {
		// Keep up to the next semicolon or end.
		end := strings.IndexAny(s[i:], "; ")
		if end < 0 {
			s = s[:i] + s[i+len("stream ID "):]
		}
	}
	if len(s) > 80 {
		s = s[:80] + "…"
	}
	return s
}
