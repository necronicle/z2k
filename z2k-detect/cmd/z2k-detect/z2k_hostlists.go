package main

import (
	"bufio"
	"os"
	"strings"
)

// z2kHostlists lists the nfqws2 hostlist files the daemon consults to
// answer "is this domain already covered?". Order matters for the
// pretty-printed "found in: <file>" message — the first match wins.
//
// Paths are absolute to /opt/zapret2/lists/ — z2k's canonical install
// prefix. If the file is missing it's silently skipped (fresh install
// might lack discovered-domains.txt; that's normal).
var z2kHostlists = []struct {
	Path  string
	Label string
}{
	// Paths must match lib/config_official.sh's `extra_strats_dir`
	// (= ${ZAPRET2_DIR}/extra_strats — not under /lists/). Previously
	// pointed inside /lists/extra_strats/ which never existed at
	// runtime, so the "уже в списке" check silently said "not found"
	// even for domains that nfqws2 already covered via RKN List.txt.
	{"/opt/zapret2/extra_strats/TCP/RKN/List.txt", "RKN list (shipped)"},
	{"/opt/zapret2/extra_strats/TCP_Discord.txt", "RKN Discord list (shipped)"},
	// YouTube category hostlists — these are dedicated nfqws2 profiles
	// (yt_tcp / gv_tcp / yt_quic), so youtube.com & googlevideo.com are
	// covered here, NOT in the RKN list. Without them the [Y] probe wrongly
	// reported youtube.com as "not in lists".
	{"/opt/zapret2/extra_strats/TCP/YT/List.txt", "YouTube TCP list (shipped)"},
	{"/opt/zapret2/extra_strats/TCP/YT_GV/List.txt", "YouTube googlevideo list (shipped)"},
	{"/opt/zapret2/extra_strats/UDP/YT/List.txt", "YouTube QUIC list (shipped)"},
	{"/opt/zapret2/lists/extra-domains.txt", "z2k community extras"},
	{"/opt/zapret2/lists/discovered-domains.txt", "z2k-detect auto-discovered"},
	{"/opt/zapret2/lists/whitelist.txt", "operator whitelist (no-bypass)"},
}

// findDomainInZ2kLists scans the well-known z2k hostlists for `domain`.
// Returns the human label of the first file that covers it, or empty
// string if not found. Comment lines and blanks are skipped.
//
// Match is case-insensitive (DNS names are case-insensitive per RFC 1035)
// and BY SUFFIX, mirroring nfqws2 semantics: в хостлистах поддомены
// учитываются автоматически (manual, «формат хостлистов»), и движковый
// skip-список (engine.skippedLocked) ходит по родительским меткам ровно
// так же. Точное сравнение здесь противоречило обоим: [Y] на
// rr3---sn-xyz.googlevideo.com отвечал «домен НЕ в списках — добавьте в
// extra-domains», хотя googlevideo.com лежит в списке и уже покрывает
// его. Человек следовал совету и засорял extra-domains записями,
// которые ничего не меняли.
func findDomainInZ2kLists(domain string) string {
	needle := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(domain), "."))
	if needle == "" {
		return ""
	}
	for _, h := range z2kHostlists {
		f, err := os.Open(h.Path)
		if err != nil {
			continue
		}
		match := scanForDomain(f, needle)
		f.Close()
		if match {
			return h.Label
		}
	}
	return ""
}

func scanForDomain(f *os.File, needle string) bool {
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.ToLower(strings.TrimSpace(sc.Text()))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if coversDomain(line, needle) {
			return true
		}
	}
	return false
}

// coversDomain reports whether hostlist entry covers needle: exact match
// or needle is a subdomain of entry (dot-anchored, so "evilgooglevideo.com"
// is NOT covered by "googlevideo.com"). Entries starting with '^' are
// nfqws2's «без поддоменов» form — exact match only.
func coversDomain(entry, needle string) bool {
	if exact := strings.TrimPrefix(entry, "^"); exact != entry {
		return needle == exact
	}
	if needle == entry {
		return true
	}
	return strings.HasSuffix(needle, "."+entry)
}
