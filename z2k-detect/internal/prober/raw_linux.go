//go:build linux

package prober

import (
	"context"
	"net"
	"os/exec"
	"sync"
	"syscall"
)

// Probe traffic origin tag. SO_MARK on our outgoing sockets stamps every
// packet with this fwmark. An iptables OUTPUT mangle rule (installed
// lazily on first probe) converts this fwmark into z2k's CONNMARK
// exclude bit (0x20000000), which the NFQUEUE rules already check —
// connections with that connmark skip nfqws2 entirely. Net effect: our
// probe sees the raw, unaltered server response, not whatever
// autocircular/nfqws2 made of the trafic. Without this, probing
// rutracker.org from the same router reports "works fine" because
// bypass made it work — wrong diagnostic.
//
// Mark value chosen at 0x40000000: high bit, distinct from z2k's
// internal marks (0x20000000 CONNMARK_EXCLUDE, lower bits for policy
// routing, DESYNC_MARK in upstream zapret2). Won't collide.
const (
	probeMark     = 0x40000000
	probeMarkMask = 0x40000000
	connmarkXcl   = 0x20000000
	connmarkMask  = 0x20000000
)

var (
	ruleOnce   sync.Once
	ruleErr    error
	ruleArgs   = []string{
		"-t", "mangle",
		"-m", "mark", "--mark",
		"0x40000000/0x40000000",
		"-j", "CONNMARK",
		"--set-mark", "0x20000000/0x20000000",
	}
)

// ensureBypassRule installs (once per process) the iptables OUTPUT rule
// that maps our probe fwmark to z2k's CONNMARK exclude. Failure is
// non-fatal: if iptables is missing, the table can't be loaded, or the
// user's z2k install doesn't use CONNMARK exclusion, probe falls back
// to the current "via-nfqws2" behavior. Caller decides whether to log
// the failure.
func ensureBypassRule() error {
	ruleOnce.Do(func() {
		// Check first; insert only if missing. -C exits non-zero when
		// the rule isn't present.
		check := append([]string{"-C", "OUTPUT"}, ruleArgs[1:]...)
		if err := exec.Command("iptables", check...).Run(); err == nil {
			return // already installed by us or a prior run
		}
		insert := append([]string{"-I", "OUTPUT", "1"}, ruleArgs[1:]...)
		if err := exec.Command("iptables", insert...).Run(); err != nil {
			ruleErr = err
		}
	})
	return ruleErr
}

// markedDialer returns a net.Dialer whose Control hook stamps SO_MARK on
// the outgoing socket BEFORE connect(). Combined with the iptables
// OUTPUT rule, this routes probe packets around nfqws2.
//
// Falls back to a plain dialer when ensureBypassRule failed — the
// fwmark is harmless on its own (no rule to act on it), the probe
// just won't be excluded.
func markedDialer(timeout int) *net.Dialer {
	_ = ensureBypassRule() // best-effort; ignored if it failed
	return &net.Dialer{
		Control: func(network, address string, c syscall.RawConn) error {
			var setErr error
			err := c.Control(func(fd uintptr) {
				setErr = syscall.SetsockoptInt(
					int(fd), syscall.SOL_SOCKET, syscall.SO_MARK, probeMark)
			})
			if err != nil {
				return err
			}
			return setErr
		},
	}
}

// dialContextRaw uses the marked dialer. Used by ProbeIPs / Probe for
// the TCP stage. UDP DNS resolver gets a separate marked dialer in
// resolver.go.
func dialContextRaw(ctx context.Context, network, address string) (net.Conn, error) {
	return markedDialer(0).DialContext(ctx, network, address)
}
