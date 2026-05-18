//go:build !linux

package prober

import (
	"context"
	"net"
)

// Non-Linux stub: the iptables/SO_MARK bypass trick is Linux-only.
// macOS dev builds use a plain dialer; production ships only linux/*.
func ensureBypassRule() error { return nil }

func dialContextRaw(ctx context.Context, network, address string) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, network, address)
}

func markedDialer(timeout int) *net.Dialer { return &net.Dialer{} }
