package gvsub

import (
	"fmt"
	"net/netip"
	"strings"
	"testing"
)

func TestCYouTubeNamesAndDNS(t *testing.T) {
	for _, q := range []string{"rr1---sn-4g5e6nss.c.youtube.com", "RR17.SN-4G5E6NSS.C.YOUTUBE.COM."} {
		c, n, ok := ParseCluster(q)
		if !ok || c != "sn-4g5e6nss" || n < 1 {
			t.Fatalf("cluster %s: %s/%d/%v", q, c, n, ok)
		}
		gc, _, _ := ParseCluster("rr1---sn-4g5e6nss.googlevideo.com")
		if c != gc {
			t.Fatal("different logical cluster")
		}
		for _, wrap := range []func([]byte) []byte{ipv4udp, ipv6udp} {
			msg := dnsReply(strings.TrimSuffix(q, "."), rr{5, name("rr1.sn-4g5e6nss.c.youtube.com")}, rr{1, []byte{173, 194, 182, 198}}, rr{28, netip.MustParseAddr("2a00:1450:4001:5e::6").AsSlice()})
			a, ok := ParseReply(wrap(msg))
			if !ok || len(a.Addrs) != 2 {
				t.Fatalf("DNS %s: %+v/%v", q, a, ok)
			}
		}
	}
	for _, q := range []string{"youtube.com", "www.youtube.com", "c.youtube.com", "other.c.youtube.com", "rr1---sn-x.c.youtube.com.evil", "rr1---sn-x.evilc.youtube.com", "sub.rr1---sn-x.c.youtube.com"} {
		if IsTarget(q) {
			t.Fatalf("unrelated target: %s", q)
		}
		if _, ok := ParseReply(ipv4udp(dnsReply(q, rr{1, bad.AsSlice()}))); ok {
			t.Fatalf("unrelated DNS: %s", q)
		}
		s, _, _, _ := newSvc()
		select {
		case <-s.OnDNS(q, []netip.Addr{bad}):
		default:
			t.Fatal("unrelated name held")
		}
		if len(s.known) != 0 {
			t.Fatal("unrelated name registered")
		}
	}
}

func TestCYouTubeDNSRules(t *testing.T) {
	var calls []string
	r := IPTables{Run: func(bin string, args ...string) error {
		line := bin + " " + strings.Join(args, " ")
		calls = append(calls, line)
		if strings.Contains(line, " -C ") || strings.Contains(line, " -D ") {
			return fmt.Errorf("missing")
		}
		return nil
	}, Out: func(string, ...string) (string, error) { return "", nil }}
	if _, err := r.Ensure(); err != nil {
		t.Fatal(err)
	}
	r.Teardown()
	all := strings.Join(calls, "\n")
	for _, bin := range []string{"iptables", "ip6tables"} {
		for _, op := range []string{"-I OUTPUT 1", "-D OUTPUT"} {
			for _, match := range []string{"--string googlevideo", "--hex-string " + cacheDNSHex, "--hex-string |046776743103636f6d00|"} {
				want := bin + " -w -t mangle " + op + " ! -o lo -p udp --sport 53 -m string --algo bm --icase " + match + " -j NFQUEUE --queue-num 210 --queue-bypass"
				if !strings.Contains(all, want) {
					t.Fatalf("missing %s", want)
				}
			}
		}
	}
}
