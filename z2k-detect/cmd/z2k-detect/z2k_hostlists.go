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
	{"/opt/zapret2/lists/extra-domains.txt", "z2k community extras"},
	{"/opt/zapret2/lists/discovered-domains.txt", "z2k-detect auto-discovered"},
	{"/opt/zapret2/lists/whitelist.txt", "operator whitelist (no-bypass)"},
}

// findDomainInZ2kLists scans the well-known z2k hostlists for `domain`.
// Returns the human label of the first file that contains an exact match,
// or empty string if not found. Comment lines and blanks are skipped.
//
// Match is case-insensitive (DNS names are case-insensitive per RFC 1035),
// exact-string against the trimmed line. No glob/wildcard logic; the
// hostlists are flat domain lists.
func findDomainInZ2kLists(domain string) string {
	needle := strings.ToLower(strings.TrimSpace(domain))
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
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.ToLower(line) == needle {
			return true
		}
	}
	return false
}
