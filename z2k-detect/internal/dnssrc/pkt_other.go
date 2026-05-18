//go:build !linux

package dnssrc

import (
	"context"
	"errors"
)

// Non-Linux stub: AF_PACKET is Linux-only. macOS dev builds and any
// other GOOS get a compile-clean implementation that fails fast at
// runtime — the daemon only ships to linux/* anyway.
func packetCapture(ctx context.Context, out chan<- Event, errs chan<- error) {
	defer close(out)
	defer close(errs)
	errs <- errors.New("af_packet: not supported on this platform (linux-only)")
}
