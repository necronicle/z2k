//go:build linux

package prober

import (
	"context"
	"net"
	"os/exec"
	"sync"
	"syscall"
)

// probeMark is stamped onto every outgoing probe socket via SO_MARK. The
// iptables OUTPUT mangle rule below converts it to z2k's connmark-exclude
// bit so nfqws2 leaves probe connections alone. Without this, probing
// rutracker.org from the same router that runs nfqws2 reports "IGNORE"
// because bypass made it work — wrong diagnostic.
const probeMark = 0x40000000

var (
	ruleOnce sync.Once
	ruleErr  error
)

// ensureBypassRule installs (once per process) the OUTPUT mangle rule that
// maps probeMark → z2k's connmark-exclude. Non-fatal: if iptables is absent
// or the mangle table isn't loaded, probes run through nfqws2 (same as before
// the mark was added). Note: -t mangle must precede -C/-I in iptables syntax.
func ensureBypassRule() error {
	ruleOnce.Do(func() {
		ruleSpec := []string{
			"-m", "mark", "--mark", "0x40000000/0x40000000",
			"-j", "CONNMARK", "--set-mark", "0x20000000/0x20000000",
		}
		check := append([]string{"-t", "mangle", "-C", "OUTPUT"}, ruleSpec...)
		if exec.Command("iptables", check...).Run() == nil {
			return // already present
		}
		insert := append([]string{"-t", "mangle", "-I", "OUTPUT", "1"}, ruleSpec...)
		ruleErr = exec.Command("iptables", insert...).Run()
	})
	return ruleErr
}

func markedDialer(_ int) *net.Dialer {
	_ = ensureBypassRule()
	return &net.Dialer{
		Control: func(network, address string, c syscall.RawConn) error {
			var setErr error
			_ = c.Control(func(fd uintptr) {
				setErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_MARK, probeMark)
			})
			return setErr
		},
	}
}

func dialContextRaw(ctx context.Context, network, address string) (net.Conn, error) {
	return markedDialer(0).DialContext(ctx, network, address)
}
