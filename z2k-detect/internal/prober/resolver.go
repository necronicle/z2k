package prober

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// resolverFiles are checked in order for nameserver entries. /etc/resolv.conf
// is the standard POSIX location; /opt/etc/resolv.conf is Entware's separate
// override (some Keenetic setups maintain both). We dedup the union — if both
// exist with the same nameservers, only one copy ends up in the pool.
var resolverFiles = []string{
	"/etc/resolv.conf",
	"/opt/etc/resolv.conf",
}

// ndmcLabels caches the IP→label map derived from `ndmc -c "show ip
// name-server"` output. Populated lazily on first probe via initNDMCLabels.
// Empty when ndmc isn't available (non-Keenetic system) or the call
// times out — caller falls back to RFC1918/loopback detection then.
var (
	ndmcLabels    map[string]string
	ndmcLabelOnce sync.Once
)

const dnsTimeout = 800 * time.Millisecond

// resolverAttempt is one resolver's outcome.
type resolverAttempt struct {
	Server string // "1.2.3.4:53"
	IPs    []net.IPAddr
	Err    error
}

func (a resolverAttempt) short() string {
	label := a.Server
	host, _, err := net.SplitHostPort(a.Server)
	if err == nil {
		// Priority: explicit NDM-configured label (Keenetic's own name
		// for the upstream — interface like "PPPoE0" or service like
		// "Dns::Manager") → fall back to RFC1918 heuristic → bare IP.
		if l, ok := ndmcLabels[host]; ok && l != "" {
			label = a.Server + " (" + l + ")"
		} else if isPrivateIP(host) {
			label = a.Server + " (local)"
		}
	}
	if a.Err == nil {
		return fmt.Sprintf("%s: ok (%d IPs)", label, len(a.IPs))
	}
	es := a.Err.Error()
	switch {
	case strings.Contains(es, "no such host"):
		return label + ": NXDOMAIN"
	case strings.Contains(es, "i/o timeout"):
		return label + ": timeout"
	case strings.Contains(es, "connection refused"):
		return label + ": refused"
	default:
		if i := strings.Index(es, ": "); i >= 0 && i+2 < len(es) {
			es = es[i+2:]
		}
		if len(es) > 60 {
			es = es[:60] + "…"
		}
		return label + ": " + es
	}
}

// buildResolverPool returns the list of nameservers actually configured
// on this system, in resolv.conf order, plus NDM-known upstreams
// (Keenetic-specific) the local 127.0.0.1 forwarder relays to. Dedup'd.
// Caller probes them all in parallel.
//
// Why both: on Keenetic /etc/resolv.conf typically only lists 127.0.0.1
// (the local NDM forwarder). Probing only 127.0.0.1 hides the real
// per-upstream behaviour — operator can't see "ISP DNS via PPPoE0 says
// NXDOMAIN, manual Dns::Manager says ok" unless we query each upstream
// directly. NDM exposes the upstream list via `ndmc -c "show ip
// name-server"`.
func buildResolverPool() []string {
	initNDMCLabels()
	seen := map[string]struct{}{}
	var out []string
	for _, f := range resolverFiles {
		for _, ns := range readResolvConf(f) {
			if _, dup := seen[ns]; dup {
				continue
			}
			seen[ns] = struct{}{}
			out = append(out, ns+":53")
		}
	}
	// NDM-discovered upstreams (the IPs the local forwarder relays to).
	// Order: resolv.conf first (operator-canonical), then NDM list.
	for ip := range ndmcLabels {
		if _, dup := seen[ip]; dup {
			continue
		}
		seen[ip] = struct{}{}
		out = append(out, ip+":53")
	}
	return out
}

// initNDMCLabels populates ndmcLabels lazily by invoking `ndmc -c "show
// ip name-server"`. Runs once per process. Silently no-ops on systems
// without ndmc (non-Keenetic) or if the call fails/times out.
func initNDMCLabels() {
	ndmcLabelOnce.Do(func() {
		if _, err := exec.LookPath("ndmc"); err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, "ndmc", "-c", "show ip name-server").Output()
		if err != nil {
			return
		}
		ndmcLabels = parseNDMCResolvers(out)
	})
}

// parseNDMCResolvers extracts IP→label pairs from ndmc's `show ip
// name-server` output. The output is YAML-ish blocks like:
//
//	server:
//	  address: 88.87.64.6
//	  domain:
//	  global: 32767
//	  service: Network::Interface::Ppp-PPPoE0
//	  interface: PPPoE0
//
// We label by `interface` when set (most concrete: "PPPoE0"), falling
// back to the last segment of `service` ("Ppp-PPPoE0" → use "Ppp-PPPoE0"
// raw is unhelpful; prefer the interface or the service-class like
// "Dns::Manager" → "manual"). IPv6 entries are filtered out (z2k probe
// pipeline is v4-only anyway).
func parseNDMCResolvers(out []byte) map[string]string {
	labels := map[string]string{}
	var curAddr, curService, curInterface string
	flush := func() {
		if curAddr == "" {
			return
		}
		ip := net.ParseIP(curAddr)
		if ip == nil || ip.To4() == nil {
			return
		}
		label := curInterface
		if label == "" {
			// Map common service classes to short labels.
			switch curService {
			case "Dns::Manager":
				label = "manual"
			case "":
				label = ""
			default:
				// Fallback: take the last "::"-separated segment.
				if i := strings.LastIndex(curService, "::"); i >= 0 {
					label = curService[i+2:]
				} else {
					label = curService
				}
			}
		}
		labels[curAddr] = label
	}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "server:") {
			flush()
			curAddr, curService, curInterface = "", "", ""
			continue
		}
		if strings.HasPrefix(line, "address:") {
			curAddr = strings.TrimSpace(strings.TrimPrefix(line, "address:"))
			continue
		}
		if strings.HasPrefix(line, "service:") {
			curService = strings.TrimSpace(strings.TrimPrefix(line, "service:"))
			continue
		}
		if strings.HasPrefix(line, "interface:") {
			curInterface = strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
			continue
		}
	}
	flush()
	return labels
}

// readResolvConf extracts nameserver entries from one resolv.conf file.
// Returns empty slice on missing/unreadable file. Only IPv4 supported
// (z2k probe pipeline is v4-only anyway).
func readResolvConf(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var nss []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if !strings.HasPrefix(line, "nameserver") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		ip := net.ParseIP(fields[1])
		if ip == nil || ip.To4() == nil {
			continue
		}
		nss = append(nss, ip.String())
	}
	return nss
}

func isPrivateIP(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return true
	}
	return false
}

// poolDial возвращает Dial-функцию резолвера для одного сервера пула.
//
// network передаётся КАК ЗАПРОШЕНО, а не прибитый "udp". Резолвер Go
// начинает с UDP и при усечённом ответе (TC=1) повторяет по TCP тем же
// Dial'ом; прибитый "udp" подсовывал TCP-повтору UDP-сокет —
// length-prefixed запрос уходил в никуда, повтор таймаутил, и большой
// ответ (>1232 Б, либо EDNS срезан миддлбоксом) превращался в «резолвер
// не ответил» у ВСЕХ резолверов пула разом. Ровно эта ошибка уже была
// найдена и исправлена в rt-proxy (directResolver) — с тем же
// обоснованием в комментарии там. Вынесено в функцию, чтобы тест мог
// доказать соответствие network↔сокет, не поднимая настоящий DNS.
func poolDial(srv string) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{Timeout: dnsTimeout}).DialContext(ctx, network, srv)
	}
}

// resolveDomain asks every nameserver from the system's resolv.conf in
// parallel and returns the IPs of the first successful answer. Full
// per-resolver attempts are returned so the caller can surface
// per-server outcomes on failure.
func resolveDomain(ctx context.Context, domain string) ([]net.IPAddr, []resolverAttempt, error) {
	servers := buildResolverPool()
	if len(servers) == 0 {
		return nil, nil, errors.New("dns: no resolvers configured (empty /etc/resolv.conf)")
	}
	attempts := make([]resolverAttempt, len(servers))
	var wg sync.WaitGroup
	for i, srv := range servers {
		i, srv := i, srv
		attempts[i].Server = srv
		wg.Add(1)
		go func() {
			defer wg.Done()
			resolver := &net.Resolver{
				PreferGo: true,
				Dial:     poolDial(srv),
			}
			subCtx, cancel := context.WithTimeout(ctx, dnsTimeout)
			defer cancel()
			ips, err := resolver.LookupIPAddr(subCtx, domain)
			attempts[i].IPs = ips
			attempts[i].Err = err
		}()
	}
	wg.Wait()

	for _, a := range attempts {
		if a.Err == nil && len(a.IPs) > 0 {
			return a.IPs, attempts, nil
		}
	}
	return nil, attempts, errors.New(formatAttempts(attempts))
}

// formatAttempts renders per-resolver outcomes compactly:
//
//	127.0.0.1:53 (local): timeout; 1.1.1.1:53 (Cloudflare): ok (3 IPs)
func formatAttempts(attempts []resolverAttempt) string {
	parts := make([]string, 0, len(attempts))
	for _, a := range attempts {
		parts = append(parts, a.short())
	}
	return strings.Join(parts, "; ")
}

// firstError returns the first non-nil attempt error in pool order.
// Used by the caller to pick a FailureCode that reflects the canonical
// upstream's response.
func firstError(attempts []resolverAttempt) error {
	for _, a := range attempts {
		if a.Err != nil {
			return a.Err
		}
	}
	return nil
}

// PrimaryResolver returns a comma-joined list of currently-configured
// system resolvers. Reads fresh each call (operator may have changed
// resolv.conf since daemon start).
func PrimaryResolver() string {
	return strings.Join(buildResolverPool(), ", ")
}
