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
	"syscall"
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

func runH2MultiplexProbe(ctx context.Context, r *Result, reachableIPs []string, sni string, timeout time.Duration) {
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

	rawConn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(ip, "443"))
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
	if err := tlsConn.HandshakeContext(ctx); err != nil {
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
			streamCtx, cancel := context.WithTimeout(ctx, timeout)
			defer cancel()
			req, err := http.NewRequestWithContext(streamCtx, "GET", "https://"+sni+"/", nil)
			if err != nil {
				return
			}
			req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; z2k-detect)")
			resp, err := cc.RoundTrip(req)
			if err != nil {
				// A RoundTrip error only counts as a cutoff if it carries a
				// DPI-interference signature (reset / mid-stream sever).
				// Benign H2 conditions — GOAWAY, rate-limit (ENHANCE_YOUR_CALM),
				// REFUSED_STREAM, per-stream timeout, "use HTTP/1.1" — must NOT
				// downgrade a verdict that HTTP/1.1 already passed.
				if h2ErrIsBlockSignal(err) {
					cutoffReason <- fmt.Sprintf("stream %d: %s",
						streamIdx, sanitizeH2Err(err))
				}
				return
			}
			defer resp.Body.Close()
			n, readErr := io.Copy(io.Discard, io.LimitReader(resp.Body, httpReadLimit))
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				// Same discriminator on the body read: only a reset/sever
				// mid-body is a cutoff; a benign GOAWAY or timeout is not.
				if h2ErrIsBlockSignal(readErr) {
					cutoffReason <- fmt.Sprintf("stream %d cut at %d bytes: %s",
						streamIdx, n, sanitizeH2Err(readErr))
				}
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

// h2ErrIsBlockSignal reports whether an H2 RoundTrip / body-read error
// carries a DPI-interference signature worth downgrading a *passing*
// HTTP/1.1 verdict over. It is deliberately conservative: anything that
// could be normal server behavior (GOAWAY, rate-limit, REFUSED_STREAM,
// "use HTTP/1.1", per-stream timeout, h2-not-supported) returns false so
// we leave the HTTP/1.1 verdict intact and never auto-block a working host.
//
// A block signal is a mid-stream sever: a TCP reset, an unexpected EOF, or
// the TLS-garbage record-cut signatures the rest of the prober already
// treats as path-active interference.
func h2ErrIsBlockSignal(err error) bool {
	if err == nil {
		return false
	}
	// Timeouts (per-stream deadline, context cancel) are inconclusive.
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return false
	}
	var nerr net.Error
	if errors.As(err, &nerr) && nerr.Timeout() {
		return false
	}

	// GOAWAY = graceful server shutdown / rate-limit / overload. Benign.
	var goAway http2.GoAwayError
	if errors.As(err, &goAway) {
		return false
	}

	// Per-stream control codes the server legitimately uses. None of these
	// indicate a middlebox cutting the stream.
	var streamErr http2.StreamError
	if errors.As(err, &streamErr) {
		switch streamErr.Code {
		case http2.ErrCodeNo,
			http2.ErrCodeEnhanceYourCalm, // rate limit
			http2.ErrCodeRefusedStream,   // server declined this stream
			http2.ErrCodeCancel,          // graceful cancel
			http2.ErrCodeHTTP11Required:  // server wants HTTP/1.1
			return false
		}
		// Other stream-error codes (PROTOCOL_ERROR, INTERNAL_ERROR,
		// STREAM_CLOSED, etc.) arriving mid-transfer match the cutoff
		// pattern — fall through to treat as a block signal.
		return true
	}

	// A connection reset or an unexpected EOF mid-stream is the canonical
	// DPI sever signature.
	if errors.Is(err, syscall.ECONNRESET) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}

	// Reuse the shared taxonomy: a TLS-garbage / reset categorization on the
	// HTTP stage is a block signal; anything that lands as a generic/timeout
	// bucket is not.
	switch categorize(stageHTTP, err) {
	case CodeHTTPReset, CodeTLSGarbage:
		return true
	}
	return false
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
