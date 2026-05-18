package dnssrc

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/necronicle/z2k/z2k-detect/internal/tail"
)

// AGHSource tails AdGuardHome's querylog.json — one JSON object per line.
// We only need a tiny subset of fields so we don't bind to AGH's full
// QueryLogEntry schema; an anonymous struct catches forward-compat
// drift (new fields are ignored, removed fields zero out cleanly).
type AGHSource struct {
	Path string
}

func NewAGH(path string) *AGHSource {
	return &AGHSource{Path: path}
}

func (s *AGHSource) Name() string { return "agh:" + s.Path }

// aghEntry mirrors the relevant subset of AGH's querylog format:
//
//	{"T":"2024-01-15T10:30:00Z","QH":"example.com","QT":"A","QC":"IN",
//	 "CL":"192.168.1.42","Upstream":"...","Answer":"...","Result":{...}}
//
// QH = query host, QT = query type, CL = client IP.
type aghEntry struct {
	QH string `json:"QH"`
	QT string `json:"QT"`
	CL string `json:"CL"`
}

func (s *AGHSource) Start(ctx context.Context) (<-chan Event, <-chan error) {
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
				line = strings.TrimSpace(line)
				if line == "" || line[0] != '{' {
					continue
				}
				var e aghEntry
				if err := json.Unmarshal([]byte(line), &e); err != nil {
					continue
				}
				// AGH logs ALL query types (A/AAAA/HTTPS/...). For
				// probe purposes we only care about A queries —
				// HTTPS/SVCB and AAAA are duplicates that would
				// trigger the same probe path. Filter at source.
				if e.QT != "" && e.QT != "A" {
					continue
				}
				domain := strings.TrimRight(strings.ToLower(strings.TrimSpace(e.QH)), ".")
				if domain == "" {
					continue
				}
				select {
				case out <- Event{Domain: domain, Peer: e.CL}:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out, errs
}
