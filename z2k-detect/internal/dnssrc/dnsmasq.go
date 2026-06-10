package dnssrc

import (
	"context"
	"strings"

	"github.com/necronicle/z2k/z2k-detect/internal/dnsmasq"
	"github.com/necronicle/z2k/z2k-detect/internal/tail"
)

// DnsmasqSource tails /var/log/dnsmasq.log and parses query lines.
// Source format matches the standard `log-queries=extra` dnsmasq output;
// kept for the subset of Keenetic users who run dnsmasq from Entware.
type DnsmasqSource struct {
	Path string
}

func NewDnsmasq(path string) *DnsmasqSource {
	return &DnsmasqSource{Path: path}
}

func (s *DnsmasqSource) Name() string { return "dnsmasq:" + s.Path }

func (s *DnsmasqSource) Start(ctx context.Context) (<-chan Event, <-chan error) {
	out := make(chan Event, 128)
	errs := make(chan error, 1)

	go func() {
		defer close(out)
		defer close(errs)
		lines, lineErrs := tail.Follow(ctx, s.Path, tail.Options{StartAtEnd: true})
		for {
			select {
			case <-ctx.Done():
				return
			case err, ok := <-lineErrs:
				if ok && err != nil {
					errs <- err
					return
				}
			case line, ok := <-lines:
				if !ok {
					return
				}
				ev, parsed := dnsmasq.Parse(line)
				if !parsed || ev.Action != dnsmasq.Query {
					continue
				}
				// dnsmasq logs query[A]/query[AAAA]/query[HTTPS] — for probe
				// purposes only A matters; AAAA/HTTPS/SVCB are duplicates of
				// the same client intent that would trigger the identical
				// probe path. Filter at source, matching agh.go and pkt.go.
				// Empty RecordType is tolerated (older dnsmasq formats).
				if ev.RecordType != "" && ev.RecordType != "A" {
					continue
				}
				domain := strings.TrimRight(strings.ToLower(strings.TrimSpace(ev.Domain)), ".")
				if domain == "" {
					continue
				}
				select {
				case out <- Event{Domain: domain, Peer: ev.Peer}:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out, errs
}
