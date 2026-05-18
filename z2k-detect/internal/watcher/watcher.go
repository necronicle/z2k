// Package watcher normalizes DNS query events from upstream parsers.
// State-free since the storage-backed daemon was retired — the engine
// turns events directly into probe candidates without persisting an
// observation history.
package watcher

import (
	"strings"
	"time"
)

// Event is a normalized DNS observation.
type Event struct {
	Domain    string
	Peer      string
	Timestamp time.Time
}

// Normalize trims, lowercases and drops the trailing root-zone dot. Returns
// empty string for events the engine should skip (blank domain after trim).
func Normalize(e Event) string {
	return strings.TrimRight(strings.ToLower(strings.TrimSpace(e.Domain)), ".")
}
