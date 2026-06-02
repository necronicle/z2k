// z2k-dns-filter — a tiny transparent DNS forwarder that strips AAAA (and
// HTTPS/SVCB) answers for the z2k bypass hostlist, pinning blocked domains to
// IPv4 so the browser's Happy-Eyeballs uses the v4 path where z2k's packet
// desync actually works. Everything else is forwarded verbatim to the user's
// existing upstream resolver(s) — the filter is additive and non-breaking.
//
// Mechanism (RFC-correct, the AdGuard model): for a blocklist QNAME, an AAAA
// (type 28) or HTTPS/SVCB (type 65) query is answered with NODATA (NOERROR,
// empty answer, the question echoed, RA set) — NEVER NXDOMAIN (that would
// poison the A path) and NEVER a synthetic ::. Happy-Eyeballs (RFC 8305) then
// connects over IPv4 with no resolution-delay, because a local resolver
// returns the negative AAAA together with the positive A.
//
// Coverage: only clients that send plain DNS to the router (the iptables
// REDIRECT of :53 -> this filter). Clients with their own DoH/DoT or a
// hardcoded public resolver bypass it — that gap is unfixable at the DNS layer.
//
// Dependency-free (stdlib only). DNS is parsed by hand: the question section is
// never compressed, so reading QNAME+QTYPE is trivial, and a NODATA reply is
// just the query bytes up to end-of-question with the header flags/counts fixed.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const version = "z2k-dns-filter 1.0.0"

const (
	typeAAAA  = 28 // IPv6 address
	typeHTTPS = 65 // HTTPS/SVCB (carries ipv6hint + ECH + ALPN)
)

var (
	listenAddr  = flag.String("listen", ":15353", "internal UDP+TCP listen address (NOT :53)")
	hostlistDir = flag.String("hostlist-dir", "/opt/zapret2/extra_strats", "dir holding TCP/{RKN,YT,YT_GV}/List.txt (the live nfqws2 hostlist dir)")
	upstreamArg = flag.String("upstream", "", "comma-separated upstreams host[:53]; empty = auto-discover from resolv.conf + ndmc")
	stripHTTPS  = flag.Bool("strip-https", true, "also NODATA the HTTPS/SVCB (type 65) query (kills ipv6hint + ECH)")
	reloadSecs  = flag.Int("reload", 30, "blocklist mtime / upstream poll interval, seconds")
	showVersion = flag.Bool("version", false, "print version and exit")
)

// blockset is an immutable snapshot of the blocklist; swapped atomically on
// hot-reload so request handlers never lock.
type blockset struct {
	exact map[string]struct{}
}

var (
	currentBlock atomic.Pointer[blockset]
	upstreams    atomic.Pointer[[]string]
)

func blocklistFiles() []string {
	return []string{
		*hostlistDir + "/TCP/RKN/List.txt",
		*hostlistDir + "/TCP/YT/List.txt",
		*hostlistDir + "/TCP/YT_GV/List.txt",
	}
}

func loadBlocklist() *blockset {
	exact := make(map[string]struct{}, 140000)
	for _, f := range blocklistFiles() {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			d := strings.ToLower(strings.TrimSpace(line))
			if d == "" || d[0] == '#' {
				continue
			}
			d = strings.TrimSuffix(d, ".")
			d = strings.TrimPrefix(d, "*.")
			if d != "" {
				exact[d] = struct{}{}
			}
		}
	}
	return &blockset{exact: exact}
}

// matchBlock returns true if qname or any of its parent domains is in the set.
// So sub.cdn.instagram.com matches when instagram.com is listed.
func matchBlock(qname string, bs *blockset) bool {
	if qname == "" || bs == nil {
		return false
	}
	name := qname
	for {
		if _, ok := bs.exact[name]; ok {
			return true
		}
		i := strings.IndexByte(name, '.')
		if i < 0 {
			return false
		}
		name = name[i+1:]
	}
}

// parseQuestion reads the first question. Returns lowercased qname (no trailing
// dot), qtype, the byte offset just past the question, and ok. Question names
// are never compressed, so this is a straight label walk.
func parseQuestion(msg []byte) (qname string, qtype uint16, qend int, ok bool) {
	if len(msg) < 12 {
		return "", 0, 0, false
	}
	qd := int(msg[4])<<8 | int(msg[5])
	if qd < 1 {
		return "", 0, 0, false
	}
	off := 12
	var b strings.Builder
	for {
		if off >= len(msg) {
			return "", 0, 0, false
		}
		l := int(msg[off])
		if l == 0 {
			off++
			break
		}
		if l&0xC0 != 0 { // compression pointer — illegal in a question
			return "", 0, 0, false
		}
		off++
		if off+l > len(msg) {
			return "", 0, 0, false
		}
		if b.Len() > 0 {
			b.WriteByte('.')
		}
		for i := 0; i < l; i++ {
			c := msg[off+i]
			if c >= 'A' && c <= 'Z' {
				c += 32
			}
			b.WriteByte(c)
		}
		off += l
	}
	if off+4 > len(msg) {
		return "", 0, 0, false
	}
	qtype = uint16(msg[off])<<8 | uint16(msg[off+1])
	off += 4 // qtype(2) + qclass(2)
	return b.String(), qtype, off, true
}

// buildNODATA crafts a NOERROR/empty-answer reply from the query, keeping the
// question. qend = end of the question section in the query.
func buildNODATA(query []byte, qend int) []byte {
	resp := make([]byte, qend)
	copy(resp, query[:qend])
	opcode := query[2] & 0x78 // bits 6..3
	rd := query[2] & 0x01     // recursion desired
	resp[2] = 0x80 | opcode | rd // QR=1, AA=0, TC=0
	resp[3] = 0x80               // RA=1, Z=0, RCODE=0 (NOERROR)
	resp[6], resp[7] = 0, 0      // ANCOUNT=0
	resp[8], resp[9] = 0, 0      // NSCOUNT=0
	resp[10], resp[11] = 0, 0    // ARCOUNT=0  (QDCOUNT left as-is = 1)
	return resp
}

// decide returns a NODATA reply (suppress=true) or nil (forward upstream).
func decide(query []byte) (resp []byte, suppress bool) {
	qname, qtype, qend, ok := parseQuestion(query)
	if !ok {
		return nil, false // unparseable -> forward, never break DNS
	}
	if qtype == typeAAAA || (*stripHTTPS && qtype == typeHTTPS) {
		if matchBlock(qname, currentBlock.Load()) {
			return buildNODATA(query, qend), true
		}
	}
	return nil, false
}

// ---- upstream discovery (resolv.conf + Keenetic ndmc) ----------------------

func discoverUpstreams() []string {
	seen := map[string]bool{}
	var out []string
	add := func(ip string) {
		ip = strings.Trim(strings.TrimSpace(ip), ",;")
		if ip == "" || net.ParseIP(ip) == nil {
			return
		}
		hp := net.JoinHostPort(ip, "53")
		if !seen[hp] {
			seen[hp] = true
			out = append(out, hp)
		}
	}
	for _, f := range []string{"/etc/resolv.conf", "/opt/etc/resolv.conf"} {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "nameserver ") {
				add(line[len("nameserver "):])
			}
		}
	}
	if o, err := exec.Command("ndmc", "-c", "show ip name-server").Output(); err == nil {
		for _, tok := range strings.Fields(string(o)) {
			add(tok)
		}
	}
	if len(out) == 0 {
		out = []string{"8.8.8.8:53", "1.1.1.1:53"} // last-resort, never blackhole
	}
	return out
}

func refreshUpstreams() {
	var ups []string
	if s := strings.TrimSpace(*upstreamArg); s != "" {
		for _, u := range strings.Split(s, ",") {
			u = strings.TrimSpace(u)
			if u == "" {
				continue
			}
			if !strings.Contains(u, ":") {
				u += ":53"
			}
			ups = append(ups, u)
		}
	} else {
		ups = discoverUpstreams()
	}
	upstreams.Store(&ups)
}

func getUpstreams() []string {
	if p := upstreams.Load(); p != nil {
		return *p
	}
	return nil
}

func forwardUDP(query []byte) ([]byte, error) {
	for _, u := range getUpstreams() {
		c, err := net.DialTimeout("udp", u, 2*time.Second)
		if err != nil {
			continue
		}
		_ = c.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err := c.Write(query); err != nil {
			c.Close()
			continue
		}
		buf := make([]byte, 4096)
		n, err := c.Read(buf)
		c.Close()
		if err != nil || n == 0 {
			continue
		}
		return buf[:n], nil
	}
	return nil, fmt.Errorf("all upstreams failed")
}

func forwardTCP(query []byte) ([]byte, error) {
	for _, u := range getUpstreams() {
		c, err := net.DialTimeout("tcp", u, 2*time.Second)
		if err != nil {
			continue
		}
		_ = c.SetDeadline(time.Now().Add(5 * time.Second))
		out := make([]byte, 2+len(query))
		out[0] = byte(len(query) >> 8)
		out[1] = byte(len(query))
		copy(out[2:], query)
		if _, err := c.Write(out); err != nil {
			c.Close()
			continue
		}
		var lb [2]byte
		if _, err := io.ReadFull(c, lb[:]); err != nil {
			c.Close()
			continue
		}
		n := int(lb[0])<<8 | int(lb[1])
		resp := make([]byte, n)
		if _, err := io.ReadFull(c, resp); err != nil {
			c.Close()
			continue
		}
		c.Close()
		return resp, nil
	}
	return nil, fmt.Errorf("all upstreams failed (tcp)")
}

// ---- listeners -------------------------------------------------------------

func serveUDP(addr string, wg *sync.WaitGroup) {
	defer wg.Done()
	pc, err := net.ListenPacket("udp", addr)
	if err != nil {
		log.Fatalf("udp listen %s: %v", addr, err)
	}
	log.Printf("udp listening on %s", addr)
	buf := make([]byte, 4096)
	for {
		n, src, err := pc.ReadFrom(buf)
		if err != nil {
			continue
		}
		q := make([]byte, n)
		copy(q, buf[:n])
		go func(query []byte, from net.Addr) {
			if resp, sup := decide(query); sup {
				_, _ = pc.WriteTo(resp, from)
				return
			}
			if r, err := forwardUDP(query); err == nil {
				_, _ = pc.WriteTo(r, from)
			}
		}(q, src)
	}
}

func serveTCP(addr string, wg *sync.WaitGroup) {
	defer wg.Done()
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("tcp listen %s: %v", addr, err)
	}
	log.Printf("tcp listening on %s", addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(conn net.Conn) {
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
			var lb [2]byte
			if _, err := io.ReadFull(conn, lb[:]); err != nil {
				return
			}
			n := int(lb[0])<<8 | int(lb[1])
			if n == 0 || n > 65535 {
				return
			}
			query := make([]byte, n)
			if _, err := io.ReadFull(conn, query); err != nil {
				return
			}
			resp, sup := decide(query)
			if !sup {
				r, err := forwardTCP(query)
				if err != nil {
					return
				}
				resp = r
			}
			out := make([]byte, 2+len(resp))
			out[0] = byte(len(resp) >> 8)
			out[1] = byte(len(resp))
			copy(out[2:], resp)
			_, _ = conn.Write(out)
		}(c)
	}
}

func fileSig() string {
	var b strings.Builder
	for _, f := range blocklistFiles() {
		if fi, err := os.Stat(f); err == nil {
			fmt.Fprintf(&b, "%s:%d:%d;", f, fi.Size(), fi.ModTime().UnixNano())
		}
	}
	return b.String()
}

func reloadLoop() {
	last := fileSig()
	for range time.Tick(time.Duration(*reloadSecs) * time.Second) {
		if sig := fileSig(); sig != last {
			bs := loadBlocklist()
			currentBlock.Store(bs)
			last = sig
			log.Printf("blocklist reloaded: %d domains", len(bs.exact))
		}
		refreshUpstreams() // resolv.conf / ndmc can change at runtime
	}
}

func main() {
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	log.SetFlags(log.LstdFlags)

	bs := loadBlocklist()
	currentBlock.Store(bs)
	refreshUpstreams()
	log.Printf("%s | blocklist %d domains | upstreams %v | strip-https=%v",
		version, len(bs.exact), getUpstreams(), *stripHTTPS)

	go reloadLoop()

	var wg sync.WaitGroup
	wg.Add(2)
	go serveUDP(*listenAddr, &wg)
	go serveTCP(*listenAddr, &wg)
	wg.Wait()
}
