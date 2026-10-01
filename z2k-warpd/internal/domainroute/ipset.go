package domainroute

import (
	"errors"
	"fmt"
	"net/netip"
	"os/exec"
	"strings"
	"time"
)

const clientSetPrefix = "z2kd_"

// PairSet uses one supported hash:ip set per LAN client. Keenetic's userspace
// advertises hash:net,net, but its 4.9 kernel lacks that set type.
type PairSet struct{ Binary, IPTablesBinary string }

func (s PairSet) ipset(args ...string) ([]byte, error) {
	bin := s.Binary
	if bin == "" {
		bin = "ipset"
	}
	return exec.Command(bin, args...).CombinedOutput()
}
func (s PairSet) iptables(args ...string) ([]byte, error) {
	bin := s.IPTablesBinary
	if bin == "" {
		bin = "iptables"
	}
	return exec.Command(bin, args...).CombinedOutput()
}
func clientSet(client netip.Addr) (string, error) {
	if !client.Is4() || !(client.IsPrivate() || carrierNAT.Contains(client)) {
		return "", errors.New("not a LAN client")
	}
	return clientSetPrefix + client.String(), nil
}
func setClient(name string) (netip.Addr, bool) {
	if !strings.HasPrefix(name, clientSetPrefix) {
		return netip.Addr{}, false
	}
	ip, err := netip.ParseAddr(strings.TrimPrefix(name, clientSetPrefix))
	canonical, ce := clientSet(ip)
	return ip, err == nil && ce == nil && canonical == name
}
func markArgs(action string, client netip.Addr, name string) []string {
	return []string{"-w", "-t", "mangle", action, "PREROUTING", "-s", client.String() + "/32", "-m", "set", "--match-set", name, "dst", "-j", "Z2K_WARP"}
}
func (s PairSet) ensureMark(client netip.Addr, name string) error {
	if _, err := s.iptables(markArgs("-C", client, name)...); err == nil {
		return nil
	}
	if out, err := s.iptables(markArgs("-A", client, name)...); err != nil {
		return fmt.Errorf("add WARP DNS mark: %w: %s", err, out)
	}
	return nil
}
func (s PairSet) removeMark(client netip.Addr, name string) {
	// Remove both generations before destroying the set. An upgrade can start
	// the observer before shell selfheal has removed the old direct marks.
	for _, target := range [][]string{{"Z2K_WARP"}, {"MARK", "--set-xmark", "0x989/0x989"}} {
		args := markArgs("-D", client, name)
		args = append(args[:len(args)-1], target...)
		_, _ = s.iptables(args...)
		for i := 0; i < 8; i++ {
			args[3] = "-C"
			if _, err := s.iptables(args...); err != nil {
				break
			}
			args[3] = "-D"
			if _, err := s.iptables(args...); err != nil {
				break
			}
		}
	}
}
func (s PairSet) Apply(changes []Change, now time.Time) error {
	for _, ch := range changes {
		name, err := clientSet(ch.Client)
		if err != nil || !EligibleDestination(ch.Dest) {
			return errors.New("invalid WARP DNS pair")
		}
		if ch.Delete {
			_, _ = s.ipset("del", name, ch.Dest.String(), "-exist")
			saved, err := s.ipset("save", name)
			if err == nil && !strings.Contains(string(saved), "\nadd ") {
				s.removeMark(ch.Client, name)
				_, _ = s.ipset("destroy", name)
			}
			continue
		}
		if out, err := s.ipset("create", name, "hash:ip", "family", "inet", "timeout", "3600", "maxelem", "8192", "-exist"); err != nil {
			return fmt.Errorf("create WARP DNS set: %w: %s", err, out)
		}
		seconds := int(ch.Expiry.Sub(now).Seconds())
		if ch.Expiry.After(now.Add(time.Duration(seconds) * time.Second)) {
			seconds++
		}
		if seconds < 1 {
			seconds = 1
		}
		if seconds > 3600 {
			seconds = 3600
		}
		if out, err := s.ipset("add", name, ch.Dest.String(), "timeout", fmt.Sprint(seconds), "-exist"); err != nil {
			return fmt.Errorf("add WARP DNS address: %w: %s", err, out)
		}
		if err := s.ensureMark(ch.Client, name); err != nil {
			return err
		}
	}
	return nil
}
func (s PairSet) ReplaceAll(changes []Change, now time.Time) error {
	output, err := s.ipset("list", "-n")
	if err != nil {
		return fmt.Errorf("list WARP DNS sets: %w: %s", err, output)
	}
	for _, name := range strings.Fields(string(output)) {
		client, ok := setClient(name)
		if !ok {
			continue
		}
		s.removeMark(client, name)
		if out, err := s.ipset("destroy", name); err != nil {
			return fmt.Errorf("destroy stale WARP DNS set: %w: %s", err, out)
		}
	}
	return s.Apply(changes, now)
}
