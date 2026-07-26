#!/bin/sh
# tests/test_rt_proxy_domains.sh
#
# Two invariants about the RuTracker domain set, which lives in FOUR places and had
# already drifted:
#
#   1. What we PIN must equal what the official RuTracker extension proxies.
#      Source of truth is the shipped artifact, not a description of it:
#      addons.mozilla.org add-on "rutracker-add-on" v0.9.32, publisher RuTracker,
#      file bundle/background.js —
#          proxies        = ['HTTPS ps1.blockme.site:443']   (the same upstream we use)
#          proxiedDomains = [rutracker.org, rutracker.wiki,
#                            api.rutracker.cc, rep.rutracker.cc, static.rutracker.cc]
#      and proxyScript.js selects with proxiedDomains.includes(domain) — EXACT match,
#      so www.* is deliberately not proxied there either.
#
#      We used to pin two extras. Both measured dead through the proxy (000, four
#      upstreams returning EOF in a row): rutracker.cc has no upstream A record at
#      all, and blockme serves the apex but not www. Pinning a host the upstream
#      cannot serve is worse than leaving it alone — the name gets hijacked to a
#      sentinel and the request can then only fail.
#
#   2. Every CLEANUP path must cover the UNION of current and legacy domains.
#      Otherwise the two dropped pins survive forever on every already-installed
#      router: S96 only unpins what it currently knows about, so shrinking the set
#      without a legacy list orphans the difference — rutracker stays hijacked to a
#      sentinel with nothing listening, which is the worst failure this component
#      has.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
S96="$HERE/files/init.d/S96z2k-rt-proxy"
CLEANUP="$HERE/z2k_cleanup.sh"
INSTALL="$HERE/lib/install.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

# The official five, verbatim from the extension bundle.
OFFICIAL="api.rutracker.cc rep.rutracker.cc rutracker.org rutracker.wiki static.rutracker.cc"
# Everything z2k has ever pinned and must therefore still be able to unpin.
LEGACY="rutracker.cc www.rutracker.org"

for f in "$S96" "$CLEANUP" "$INSTALL"; do
    [ -f "$f" ] || { no "$(basename "$f") exists" "a file" "missing"; }
done

# --- 1. what we pin == the official set -------------------------------------
got=$(sed -n 's/^DOMAINS="\([^"]*\)".*/\1/p' "$S96" | head -1 | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
want=$(printf '%s\n' $OFFICIAL | sort | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want" ] && ok "S96 pins exactly the official five" \
                     || no "S96 pins exactly the official five" "$want" "$got"

# The two known-dead extras must NOT be pinned again.
for d in $LEGACY; do
    if sed -n 's/^DOMAINS="\([^"]*\)".*/\1/p' "$S96" | head -1 | tr ' ' '\n' | grep -qx "$d"; then
        no "$d is not pinned (measured dead through the proxy)" "absent" "present"
    else
        ok "$d is not pinned (measured dead through the proxy)"
    fi
done

# --- 2. cleanup covers the union --------------------------------------------
# S96's own clear path.
clr=$(sed -n '/^dns_override_clear()/,/^}/p' "$S96")
case "$clr" in
    *'$DOMAINS'*) ok "S96 clear path iterates the current set" ;;
    *)            no "S96 clear path iterates the current set" '$DOMAINS' "not referenced" ;;
esac
case "$clr" in
    *'$DOMAINS_LEGACY'*) ok "S96 clear path also iterates the legacy set" ;;
    *)                   no "S96 clear path also iterates the legacy set" '$DOMAINS_LEGACY' "not referenced" ;;
esac

# The standalone cleanup script and the uninstaller must both name every domain
# literally — they run when S96 may be gone, so they cannot rely on its variables.
for f in "$CLEANUP" "$INSTALL"; do
    n=$(basename "$f")
    missing=""
    for d in $OFFICIAL $LEGACY; do
        grep -q "$d" "$f" 2>/dev/null || missing="$missing $d"
    done
    [ -z "$missing" ] && ok "$n can unpin every domain we ever pinned" \
                      || no "$n can unpin every domain we ever pinned" "all 7" "missing:$missing"
done

# --- 3. the upstream must stay the one the extension uses -------------------
# If RuTracker moves the proxy, our pool resolves a hostname that no longer fronts
# it and every probe fails — worth pinning so a silent divergence is visible.
if grep -q 'ps1\.blockme\.site' "$HERE/rt-proxy/main.go" 2>/dev/null; then
    ok "rt-proxy still defaults to the extension's upstream (ps1.blockme.site)"
else
    no "rt-proxy still defaults to the extension's upstream" "ps1.blockme.site" "changed"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
