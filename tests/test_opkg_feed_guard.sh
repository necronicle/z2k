#!/bin/sh
# tests/test_opkg_feed_guard.sh
#
# THE INVARIANT: the opkg feed must be reachable over PLAIN HTTP with no redirect.
#
# opkg does not download anything itself — it shells out to wget, and on Keenetic that
# is usually BusyBox wget built without SSL. entware.diversion.ch answers 301 http->https
# on every file, so such a wget follows the redirect and dies with
#     wget: not an http or ftp url: https://entware.diversion.ch/...
# surfaced by opkg as "wget returned 1". Verified 2026-07-26:
#     http://entware.diversion.ch/mipselsf-k3.4/Packages.gz  -> 301 https://...
#     http://bin.entware.net/mipselsf-k3.4/Packages.gz       -> 200, no redirect
#     http://bin.entware.net/mipselsf-k3.4/keenetic/Packages.gz -> 200, no redirect
# The owner's own router has such a wget (https probe fails) while sitting on
# bin.entware.net — i.e. it is exactly the box the guard protects.
#
# Two consequences, both covered here:
#   * lib/install.sh must NOT swap a working bin.entware.net for diversion.ch on a router
#     whose wget cannot do https. That swap is the RKN-blocking workaround; it is only
#     valid where wget-ssl exists.
#   * webpanel/install.sh must recover a router already stuck on that mirror: a months-old
#     package list makes opkg build a URL for a version the feed no longer carries (Entware
#     keeps only the current one), which is how "lighttpd_1.4.79-1 ... wget returned 1"
#     appears while the feed actually has 1.4.82-2.
#
# Offline by construction: opkg, wget and the config are all stubs. The network facts above
# were verified by hand, not here — a test that reached out would fail in CI.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
WP=${Z2K_WEBPANEL_INSTALL_UNDER_TEST:-"$HERE/webpanel/install.sh"}
LIB="$HERE/lib/install.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/opkgf.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

for f in "$WP" "$LIB"; do
    [ -f "$f" ] || { printf '[FAIL] missing %s\n' "$f"; exit 1; }
done

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*\\{?[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

# =============================================================================
# 1. webpanel: a router stuck on the https-only mirror is recovered
# =============================================================================
# The stub opkg fails the way BusyBox wget makes it fail, until the feed is switched.
mk_env() {
    BIN="$TMP/bin"; mkdir -p "$BIN"
    printf 'src/gz entware http://entware.diversion.ch/mipselsf-k3.4\n' > "$TMP/opkg.conf"
    cat > "$BIN/opkg" <<EOF
#!/bin/sh
printf 'opkg %s\n' "\$*" >> "$TMP/opkg.calls"
if grep -q 'entware\.diversion\.ch' "$TMP/opkg.conf" 2>/dev/null; then
    echo "Downloading http://entware.diversion.ch/mipselsf-k3.4/Packages.gz"
    echo "wget: not an http or ftp url: https://entware.diversion.ch/mipselsf-k3.4/Packages.gz"
    echo "opkg_download: Failed to download, wget returned 1."
    exit 1
fi
echo "Updated list of available packages in /opt/var/opkg-lists/entware"
exit 0
EOF
    chmod +x "$BIN/opkg"
    # `sed -i EXPR FILE` shim. The production code uses the BusyBox/GNU form, which is
    # correct for the router; BSD sed on a dev Mac wants a SUFFIX after -i and would take
    # EXPR as one, silently leaving the file untouched. That is exactly how this test first
    # "passed" the rewrite assertion against an unmodified config, so the shim is what makes
    # the test faithful to the router rather than to the host.
    # Путь к настоящему sed берём У ХОЗЯИНА, а не пишем /usr/bin/sed: на
    # Keenetic его там НЕТ (sed живёт в /opt/bin), шим падал молча, файл
    # оставался нетронутым — и на роутере краснели три проверки, ни одна из
    # которых не про дефект. Та же ошибка, что жёсткий PATH="/usr/bin:/bin".
    _real_sed=$(command -v sed)
    cat > "$BIN/sed" <<SHIM
#!/bin/sh
if [ "\$1" = "-i" ]; then
    _expr=\$2; _file=\$3
    $_real_sed "\$_expr" "\$_file" > "\$_file.shim" && mv "\$_file.shim" "\$_file"
    exit \$?
fi
exec $_real_sed "\$@"
SHIM
    chmod +x "$BIN/sed"
    : > "$TMP/opkg.calls"
}

run_refresh() {
    mk_env
    cat > "$TMP/r.sh" <<EOF
$(extract_fn refresh_opkg_lists "$WP")
# Point the function at the fixture instead of the live system config.
refresh_opkg_lists
echo "rc=\$?"
refresh_opkg_lists
echo "rc2=\$?"
EOF
    # /opt/etc/opkg.conf is hardcoded in the function; bind the fixture over it via a
    # sed-rewritten copy rather than touching the real file.
    sed "s#/opt/etc/opkg.conf#$TMP/opkg.conf#g" "$TMP/r.sh" > "$TMP/r2.sh"
    PATH="$BIN:$PATH" sh "$TMP/r2.sh" 2>&1
}

out=$(run_refresh)
case "$out" in
    *"switching feed back to http://bin.entware.net"*)
        ok "detects the https-only mirror and says it is switching" ;;
    *)  no "detects the https-only mirror and says it is switching" "a switch message" "$out" ;;
esac
if grep -q 'bin\.entware\.net' "$TMP/opkg.conf" 2>/dev/null &&
   ! grep -q 'diversion\.ch' "$TMP/opkg.conf" 2>/dev/null; then
    ok "the feed in opkg.conf is rewritten to bin.entware.net"
else
    no "the feed in opkg.conf is rewritten to bin.entware.net" "bin.entware.net only" "$(cat "$TMP/opkg.conf")"
fi
[ -f "$TMP/opkg.conf.z2k-bak" ] && ok "the original opkg.conf is backed up before rewriting" \
                                || no "the original opkg.conf is backed up before rewriting" "a .z2k-bak" "absent"
# The scheme must be rewritten too: `s|bin.entware.net|...|` alone would leave
# https://bin.entware.net, which is the same dead end for a wget without SSL.
case "$(cat "$TMP/opkg.conf" 2>/dev/null)" in
    *https://*) no "the rewritten feed is plain http, not https" "http://" "$(cat "$TMP/opkg.conf")" ;;
    *http://*)  ok "the rewritten feed is plain http, not https" ;;
    *)          no "the rewritten feed is plain http, not https" "an http url" "$(cat "$TMP/opkg.conf")" ;;
esac
# Exactly two `opkg update` calls: the failing one, then the one after the switch.
n=$(grep -c '^opkg update$' "$TMP/opkg.calls" 2>/dev/null); n=${n:-0}
[ "$n" = 2 ] && ok "one retry after the switch, not a loop ($n update calls)" \
             || no "one retry after the switch, not a loop" 2 "$n"
# ...and the second call to the function must refuse: run_opkg invokes it for lighttpd
# and again for mod_cgi, and two full `opkg update` runs back to back is a minute wasted.
case "$out" in
    *"rc2=1"*) ok "a second call is refused (once per install, not per package)" ;;
    *)         no "a second call is refused (once per install, not per package)" "rc2=1" "$out" ;;
esac

# =============================================================================
# 2. webpanel: run_opkg retries the ORIGINAL command after refreshing
# =============================================================================
mk_env
cat > "$TMP/ro.sh" <<EOF
$(extract_fn refresh_opkg_lists "$WP")
$(extract_fn run_opkg "$WP")
run_opkg install lighttpd
echo "rc=\$?"
EOF
sed "s#/opt/etc/opkg.conf#$TMP/opkg.conf#g" "$TMP/ro.sh" > "$TMP/ro2.sh"
out=$(PATH="$BIN:$PATH" sh "$TMP/ro2.sh" 2>&1)
case "$out" in
    *"rc=0"*) ok "run_opkg succeeds on the retry after the feed is fixed" ;;
    *)        no "run_opkg succeeds on the retry after the feed is fixed" "rc=0" "$out" ;;
esac
grep -q '^opkg install lighttpd$' "$TMP/opkg.calls" 2>/dev/null \
    && ok "the retry re-runs the SAME command, not something else" \
    || no "the retry re-runs the SAME command, not something else" "opkg install lighttpd" "$(tr '\n' ';' < "$TMP/opkg.calls")"
n=$(grep -c '^opkg install lighttpd$' "$TMP/opkg.calls" 2>/dev/null); n=${n:-0}
[ "$n" = 2 ] && ok "the command is attempted exactly twice ($n)" \
             || no "the command is attempted exactly twice" 2 "$n"

# =============================================================================
# 3. lib/install.sh: never swap a working feed onto the https-only mirror
# =============================================================================
# Structural, and deliberately labelled as such: step_update_packages is a large
# install-time function with side effects that cannot be driven offline. What matters is
# the ORDER — the wget probe has to gate the swap, not follow it.
probe_line=$(grep -n 'wget -q -O /dev/null https://entware.diversion.ch/' "$LIB" | head -1 | cut -d: -f1)
swap_line=$(grep -n "sed -i 's|bin.entware.net|entware.diversion.ch|g'" "$LIB" | head -1 | cut -d: -f1)
if [ -n "$probe_line" ] && [ -n "$swap_line" ] && [ "$probe_line" -lt "$swap_line" ]; then
    ok "the https probe gates the mirror swap (probe at $probe_line, swap at $swap_line)"
else
    no "the https probe gates the mirror swap" "probe before swap" "probe=$probe_line swap=$swap_line"
fi
# The probe must disable the swap, not merely warn about it.
if sed -n "${probe_line},$((probe_line + 8))p" "$LIB" | grep -q 'current_mirror=""'; then
    ok "a failing probe clears current_mirror, so the swap cannot run"
else
    no "a failing probe clears current_mirror, so the swap cannot run" 'current_mirror=""' "absent"
fi

# =============================================================================
# 4. a rewrite that did not take effect must be reported, not assumed
# =============================================================================
# `sed -i` can no-op silently (read-only /opt, an unexpected mirror spelling, a sed
# wanting a suffix). Without a check the function ran a second pointless `opkg update`
# against the same dead mirror and said nothing actionable.
mk_env
# A sed whose in-place edit silently does NOTHING. The first version of this case
# achieved that by deleting the shim and relying on BSD sed rejecting
# `-i EXPR FILE` — which is true on a dev Mac and FALSE on the Linux CI runner,
# where GNU sed happily performs the edit, the rewrite succeeds, and the case
# tested nothing (it failed there while passing locally). Simulate the no-op
# explicitly instead, so the branch under test is reached on every host.
_real_sed=$(command -v sed)   # у хозяина, а не /usr/bin: на Keenetic его там нет
cat > "$BIN/sed" <<NOOP
#!/bin/sh
[ "\$1" = "-i" ] && exit 0     # pretend the in-place edit happened; change nothing
exec $_real_sed "\$@"
NOOP
chmod +x "$BIN/sed"
# ...and prove the stub really is a no-op, or this case would be green for the
# wrong reason on a host where $BIN is not first in PATH.
printf 'src/gz entware http://entware.diversion.ch/x\n' > "$TMP/noop.probe"
PATH="$BIN:$PATH" sed -i 's|diversion\.ch|bin.entware.net|' "$TMP/noop.probe"
if grep -q 'diversion\.ch' "$TMP/noop.probe"; then
    ok "harness: the no-op sed stub is in effect"
else
    no "harness: the no-op sed stub is in effect" "file unchanged" "$(cat "$TMP/noop.probe")"
fi
cat > "$TMP/nf.sh" <<EOF
$(extract_fn refresh_opkg_lists "$WP")
refresh_opkg_lists
EOF
sed "s#/opt/etc/opkg.conf#$TMP/opkg.conf#g" "$TMP/nf.sh" > "$TMP/nf2.sh"
out=$(PATH="$BIN:$PATH" sh "$TMP/nf2.sh" 2>&1)
case "$out" in
    *"could not rewrite"*) ok "a failed rewrite is reported with a manual fix" ;;
    *)                     no "a failed rewrite is reported with a manual fix" "a hint" "$out" ;;
esac
n=$(grep -c '^opkg update$' "$TMP/opkg.calls" 2>/dev/null); n=${n:-0}
[ "$n" = 1 ] && ok "no second pointless update against the same dead mirror ($n)" \
             || no "no second pointless update against the same dead mirror" 1 "$n"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
