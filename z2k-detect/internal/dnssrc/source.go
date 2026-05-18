// Package dnssrc is the DNS-observation layer. Universal-by-detection:
// at startup we try the available sources in order and use the first
// that produces events. z2k targets Keenetic where the resolver varies
// (NDM native, AGH from Entware, occasional dnsmasq) — no single fixed
// log path works across all installs, so the daemon adapts.
//
// Order of detection (most to least specific):
//
//  1. AGH querylog (/opt/var/AdGuardHome/data/querylog.json) — JSON-
//     per-line, contains client peer; preferred when present.
//  2. dnsmasq.log (/var/log/dnsmasq.log) — text log with peer IPs.
//  3. AF_PACKET sniff — raw UDP/53 capture, works regardless of resolver.
//     CPU/syscall cost is higher than tailing a file, so we only fall
//     back to it when no log source exists.
//
// Each source emits Event{Domain, Peer} on its channel. Engine doesn't
// care which source produced an event; everything downstream is uniform.
package dnssrc

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"
)

// Event is one DNS query observation from any source.
type Event struct {
	Domain    string
	Peer      string
	Timestamp time.Time
}

// Source is a DNS-observation backend. Start emits events on a channel
// until ctx is cancelled or the source dies. Name identifies the source
// in logs.
type Source interface {
	Name() string
	Start(ctx context.Context) (<-chan Event, <-chan error)
}

// Detect picks the first available source from the standard order. If
// override is non-empty, forces that source by name ("agh", "dnsmasq",
// "pkt") instead of probing — useful for testing on an install that has
// multiple sources.
func Detect(override string) (Source, error) {
	if override != "" {
		switch strings.ToLower(override) {
		case "agh":
			return NewAGH(defaultAGHPath()), nil
		case "dnsmasq":
			return NewDnsmasq(defaultDnsmasqPath()), nil
		case "pkt", "packet", "af_packet":
			return NewPacket(), nil
		default:
			return nil, fmt.Errorf("unknown dns source %q (want: agh|dnsmasq|pkt)", override)
		}
	}

	// Probe in order, return first one whose source file/socket exists.
	if p := defaultAGHPath(); fileExists(p) {
		log.Printf("dnssrc: using AGH querylog at %s", p)
		return NewAGH(p), nil
	}
	if p := defaultDnsmasqPath(); fileExists(p) {
		log.Printf("dnssrc: using dnsmasq log at %s", p)
		return NewDnsmasq(p), nil
	}
	log.Printf("dnssrc: no resolver log found, falling back to AF_PACKET sniff")
	return NewPacket(), nil
}

func defaultAGHPath() string {
	// Entware-installed AGH stores querylog under /opt/var. Native
	// Debian-installed AGH lands under /opt/AdGuardHome. We check both.
	for _, p := range []string{
		"/opt/var/AdGuardHome/data/querylog.json",
		"/opt/AdGuardHome/data/querylog.json",
	} {
		if fileExists(p) {
			return p
		}
	}
	return "/opt/var/AdGuardHome/data/querylog.json"
}

func defaultDnsmasqPath() string {
	return "/var/log/dnsmasq.log"
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}
