package domainroute

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

type Transport uint8

const (
	TransportUDP Transport = iota
	TransportTCP
)

type Answer struct {
	IP  netip.Addr
	TTL time.Duration
}

var excluded = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"), netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"), netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.0.0/24"), netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.168.0.0/16"), netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"), netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"), netip.MustParsePrefix("240.0.0.0/4"),
}

// IPv6: только глобальный юникаст 2000::/3 — то, что вообще уходит в интернет;
// из него — без адресов документации, бенчмарков, Teredo и 6to4 (последние два
// — туннели поверх IPv4 к узлам, а не сами узлы).
var global6 = netip.MustParsePrefix("2000::/3")
var excluded6 = []netip.Prefix{
	netip.MustParsePrefix("2001::/32"), netip.MustParsePrefix("2001:2::/48"),
	netip.MustParsePrefix("2001:db8::/32"), netip.MustParsePrefix("2002::/16"),
	netip.MustParsePrefix("3fff::/20"),
}

func EligibleDestination(ip netip.Addr) bool {
	if ip.Is4In6() || !ip.IsGlobalUnicast() {
		return false
	}
	list := excluded
	if ip.Is6() {
		if !global6.Contains(ip) {
			return false
		}
		list = excluded6
	}
	for _, p := range list {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}

func ParseReply(packet []byte, transport Transport) (string, []Answer, error) {
	if transport == TransportTCP {
		if len(packet) < 2 || int(binary.BigEndian.Uint16(packet[:2])) != len(packet)-2 {
			return "", nil, errors.New("incomplete TCP DNS frame")
		}
		packet = packet[2:]
	}
	if len(packet) < 12 || len(packet) > 4096 {
		return "", nil, errors.New("invalid DNS size")
	}
	var msg dnsmessage.Message
	if err := msg.Unpack(packet); err != nil {
		return "", nil, err
	}
	if !msg.Header.Response || msg.Header.Truncated || msg.Header.RCode != dnsmessage.RCodeSuccess || len(msg.Questions) != 1 {
		return "", nil, errors.New("not a complete DNS answer")
	}
	q := msg.Questions[0]
	if (q.Type != dnsmessage.TypeA && q.Type != dnsmessage.TypeAAAA) || q.Class != dnsmessage.ClassINET {
		return "", nil, errors.New("not an A or AAAA question")
	}
	question := strings.ToLower(strings.TrimSuffix(q.Name.String(), "."))
	type edge struct {
		to  string
		ttl uint32
	}
	cnames := make(map[string][]edge)
	addresses := make(map[string][]dnsmessage.Resource)
	for _, rr := range msg.Answers {
		if rr.Header.Class != dnsmessage.ClassINET {
			continue
		}
		name := strings.ToLower(strings.TrimSuffix(rr.Header.Name.String(), "."))
		switch body := rr.Body.(type) {
		case *dnsmessage.CNAMEResource:
			cnames[name] = append(cnames[name], edge{strings.ToLower(strings.TrimSuffix(body.CNAME.String(), ".")), rr.Header.TTL})
		case *dnsmessage.AResource, *dnsmessage.AAAAResource:
			addresses[name] = append(addresses[name], rr)
		}
	}
	got := make(map[netip.Addr]time.Duration)
	var walk func(string, uint32, int, map[string]bool)
	walk = func(name string, ttl uint32, depth int, seen map[string]bool) {
		if depth > 16 || seen[name] {
			return
		}
		seen[name] = true
		for _, rr := range addresses[name] {
			var ip netip.Addr
			switch body := rr.Body.(type) {
			case *dnsmessage.AResource:
				ip = netip.AddrFrom4(body.A)
			case *dnsmessage.AAAAResource:
				ip = netip.AddrFrom16(body.AAAA)
			}
			seconds := min(ttl, rr.Header.TTL, 3600)
			if seconds == 0 || !EligibleDestination(ip) {
				continue
			}
			d := time.Duration(seconds) * time.Second
			if old, ok := got[ip]; !ok || d < old {
				got[ip] = d
			}
		}
		for _, e := range cnames[name] {
			walk(e.to, min(ttl, e.ttl), depth+1, seen)
		}
		delete(seen, name)
	}
	walk(question, 3600, 0, make(map[string]bool))
	answers := make([]Answer, 0, len(got))
	for ip, ttl := range got {
		answers = append(answers, Answer{ip, ttl})
	}
	return question, answers, nil
}
