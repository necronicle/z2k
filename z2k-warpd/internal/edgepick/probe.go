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
	"sort"
	"strings"
	"time"
)

const (
	metaHost = "speed.cloudflare.com"
	metaURL  = "https://speed.cloudflare.com/meta"
	maxMeta  = 4096
)

var errUnknownCountry = errors.New("Cloudflare edge country unknown")

// Meta is the Cloudflare edge location, not the website-facing exit country.
type Meta struct {
	Colo    string
	Country string
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
	lookupCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	addresses, err := resolver.LookupIPAddr(lookupCtx, metaHost)
	if err != nil {
		return Meta{}, 0, 100, fmt.Errorf("edge DNS through TUN: %w", err)
	}
	var target string
	for _, a := range addresses {
		if a.IP.To4() != nil {
			target = net.JoinHostPort(a.IP.String(), "443")
			break
		}
	}
	if target == "" {
		return Meta{}, 0, 100, errors.New("edge DNS: no IPv4 address")
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
