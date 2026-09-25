package edgepick

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"sort"
	"strings"
	"time"
)

const (
	metaHost = "speed.cloudflare.com"
	metaURL  = "https://speed.cloudflare.com/meta"
	dohURL   = "https://cloudflare-dns.com/dns-query?name=speed.cloudflare.com&type=A"
	maxMeta  = 4096
)

var errUnknownCountry = errors.New("Cloudflare edge country unknown")

// Meta is the Cloudflare edge location, not the website-facing exit country.
type Meta struct {
	Colo    string
	Country string
}

func lookupDoHWithClient(ctx context.Context, client *http.Client, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/dns-json")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("DoH HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxMeta+1))
	if err != nil || len(data) > maxMeta {
		return "", errors.New("DoH response invalid or too large")
	}
	var answer struct {
		Status int `json:"Status"`
		Answer []struct {
			Type int    `json:"type"`
			Data string `json:"data"`
		} `json:"Answer"`
	}
	if err := json.Unmarshal(data, &answer); err != nil {
		return "", err
	}
	if answer.Status != 0 {
		return "", fmt.Errorf("DoH DNS status %d", answer.Status)
	}
	for _, a := range answer.Answer {
		ip, err := netip.ParseAddr(a.Data)
		if a.Type == 1 && err == nil && ip.Is4() && ip.IsGlobalUnicast() && !ip.IsPrivate() {
			return net.JoinHostPort(ip.String(), "443"), nil
		}
	}
	return "", errors.New("DoH: no public IPv4 address")
}

func parseMeta(raw []byte) (Meta, error) {
	var doc struct {
		Colo struct {
			IATA string `json:"iata"`
			CCA2 string `json:"cca2"`
		} `json:"colo"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return Meta{}, err
	}
	if len(doc.Colo.IATA) != 3 || len(doc.Colo.CCA2) != 2 {
		return Meta{}, errUnknownCountry
	}
	return Meta{Colo: strings.ToUpper(doc.Colo.IATA), Country: strings.ToUpper(doc.Colo.CCA2)}, nil
}

func probeWithClient(ctx context.Context, client *http.Client, url string) (Meta, time.Duration, int, error) {
	var meta Meta
	var samples []time.Duration
	var lastErr error
	for i := 0; i < 3; i++ {
		if err := ctx.Err(); err != nil {
			return Meta{}, 0, 100, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return Meta{}, 0, 100, err
		}
		req.Header.Set("Referer", "https://"+metaHost)
		start := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxMeta+1))
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("meta HTTP %d", resp.StatusCode)
			continue
		}
		if readErr != nil || len(body) > maxMeta {
			lastErr = errors.New("meta response invalid or too large")
			continue
		}
		m, err := parseMeta(body)
		if err != nil {
			lastErr = err
			continue
		}
		meta = m
		samples = append(samples, time.Since(start))
	}
	if len(samples) == 0 {
		if lastErr == nil {
			lastErr = errors.New("meta did not answer")
		}
		return Meta{}, 0, 100, lastErr
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	return meta, samples[len(samples)/2], (3 - len(samples)) * 100 / 3, nil
}

// Probe resolves and fetches Cloudflare metadata using only the tested TUN.
// Health's independent warp=on proof must pass before this result is accepted.
func Probe(ctx context.Context, iface string) (Meta, time.Duration, int, error) {
	if iface == "" {
		return Meta{}, 0, 100, errors.New("edge probe: no TUN interface")
	}
	dialer := &net.Dialer{Timeout: 3 * time.Second, Control: bindToDevice(iface)}
	resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dialer.DialContext(ctx, "udp", "1.1.1.1:53")
	}}
	lookupCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	addresses, err := resolver.LookupIPAddr(lookupCtx, metaHost)
	var target string
	if err == nil {
		for _, a := range addresses {
			if a.IP.To4() == nil {
				continue
			}
			target = net.JoinHostPort(a.IP.String(), "443")
			break
		}
	}
	if target == "" {
		// Some WARP edges carry HTTPS but drop UDP/53. Resolve with DoH through
		// the same TUN, pinned to Cloudflare's IP, so DNS cannot escape via WAN.
		dohTransport := &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dialer.DialContext(ctx, "tcp", "1.1.1.1:443")
			},
			TLSClientConfig: &tls.Config{ServerName: "cloudflare-dns.com"},
		}
		defer dohTransport.CloseIdleConnections()
		dohClient := &http.Client{Transport: dohTransport, Timeout: 4 * time.Second}
		target, err = lookupDoHWithClient(ctx, dohClient, dohURL)
		if err != nil {
			return Meta{}, 0, 100, fmt.Errorf("edge DNS through TUN: %w", err)
		}
	}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp", target)
		},
		TLSClientConfig:   &tls.Config{ServerName: metaHost},
		DisableKeepAlives: true,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 4 * time.Second}
	return probeWithClient(ctx, client, metaURL)
}
