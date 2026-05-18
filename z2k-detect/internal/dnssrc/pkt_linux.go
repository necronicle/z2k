//go:build linux

package dnssrc

import (
	"context"
	"fmt"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

const ethPIP = 0x0800

func packetCapture(ctx context.Context, out chan<- Event, errs chan<- error) {
	defer close(out)
	defer close(errs)

	fd, err := openPacketSocket()
	if err != nil {
		errs <- fmt.Errorf("af_packet: %w", err)
		return
	}
	defer unix.Close(fd)

	// Closing the fd from a separate goroutine on ctx.Done is the
	// canonical way to unblock a blocking Recvfrom on Linux without
	// SetReadDeadline (which AF_PACKET fds don't support).
	go func() {
		<-ctx.Done()
		_ = unix.Close(fd)
	}()

	buf := make([]byte, 2048)
	for {
		n, _, err := unix.Recvfrom(fd, buf, 0)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if err == unix.EINTR || err == unix.EAGAIN {
				continue
			}
			// fd closed by shutdown goroutine — exit silently.
			if err == unix.EBADF {
				return
			}
			errs <- fmt.Errorf("af_packet recv: %w", err)
			return
		}
		if n < 28 {
			continue
		}
		domain, peer, ok := parseDNSQuery(buf[:n])
		if !ok || domain == "" {
			continue
		}
		select {
		case out <- Event{Domain: domain, Peer: peer}:
		case <-ctx.Done():
			return
		default:
			// Drop if engine isn't draining — flood resistance.
		}
	}
}

// openPacketSocket binds an AF_PACKET socket bound to all interfaces
// (ifindex 0) with a BPF program that only passes UDP-to-port-53
// packets. Kernel-side filtering is strictly more efficient than
// user-space — 99%+ of traffic discarded before any syscall handoff.
//
// SOCK_DGRAM (not SOCK_RAW): kernel strips link-layer headers so the
// buffer we read starts at the IP layer. No Ethernet/VLAN parsing.
func openPacketSocket() (int, error) {
	proto := int(htons(ethPIP))
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_DGRAM, proto)
	if err != nil {
		return -1, fmt.Errorf("socket: %w", err)
	}

	// BPF: accept iff IPv4 + UDP + dst port 53.
	//
	// SOCK_DGRAM AF_PACKET delivers from IP-header start, so offsets:
	//   off 0 byte = version|IHL
	//   off 9 byte = protocol            (want UDP=17)
	//   off 22 word = UDP dst port       (want 53; assumes IHL=5, no IP options)
	//
	// IHL>5 packets slip through the filter and fail later parsing —
	// no correctness issue, just a tiny amount of wasted recv work.
	// >99.9% of real-world DNS queries have IHL=5.
	prog := []bpf.Instruction{
		bpf.LoadAbsolute{Off: 9, Size: 1},
		bpf.JumpIf{Cond: bpf.JumpNotEqual, Val: 17, SkipTrue: 3},
		bpf.LoadAbsolute{Off: 22, Size: 2},
		bpf.JumpIf{Cond: bpf.JumpNotEqual, Val: 53, SkipTrue: 1},
		bpf.RetConstant{Val: 1500},
		bpf.RetConstant{Val: 0},
	}
	raw, err := bpf.Assemble(prog)
	if err != nil {
		unix.Close(fd)
		return -1, fmt.Errorf("bpf assemble: %w", err)
	}
	filters := make([]unix.SockFilter, len(raw))
	for i, ins := range raw {
		filters[i] = unix.SockFilter{
			Code: ins.Op,
			Jt:   ins.Jt,
			Jf:   ins.Jf,
			K:    ins.K,
		}
	}
	fprog := &unix.SockFprog{
		Len:    uint16(len(filters)),
		Filter: &filters[0],
	}
	// SetsockoptSockFprog handles the arch-specific setsockopt(2)
	// dispatch (direct syscall on amd64/arm64, socketcall(2) on 386)
	// without us touching syscall.SYS_SETSOCKOPT — which is missing
	// on 386 where setsockopt goes through socketcall multiplexing.
	if err := unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, fprog); err != nil {
		unix.Close(fd)
		return -1, fmt.Errorf("attach bpf: %w", err)
	}
	return fd, nil
}

func htons(v uint16) uint16 {
	return (v<<8)&0xFF00 | v>>8
}
