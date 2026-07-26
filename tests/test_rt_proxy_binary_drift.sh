#!/bin/sh
# tests/test_rt_proxy_binary_drift.sh
#
# The rt-proxy binary exists in TWO places and only one of them ships:
#
#   rt-proxy/z2k-rt-proxy-linux-*                 <- what the Makefile builds
#   mtproxy-client/builds/z2k-rt-proxy-linux-*    <- what lib/install.sh FETCHES
#
# install.sh builds its URL as "${GITHUB_RAW}/mtproxy-client/builds/${rtp_bin}", so
# a rebuild that only lands in rt-proxy/ reaches nobody. That already nearly
# happened: a fully rebuilt, deployed and router-validated binary sat in rt-proxy/
# while mtproxy-client/builds/ still held the previous one, and the release would
# have been a silent no-op — every test green, nothing shipped.
#
# This asserts the two trees agree, per architecture, for exactly the arch names
# install.sh can ask for. It is a drift guard, not a build step: if it fails, copy
# rt-proxy/z2k-rt-proxy-linux-* over mtproxy-client/builds/.
#
# The duplication itself is the real defect (one artifact, two homes, and the
# authoritative one is not the one the build writes). Collapsing it means changing
# the fetch path in install.sh, which is install-time behaviour and needs the
# binaries to exist at the new path first — deliberately left for its own change
# rather than smuggled into this one.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILT="$HERE/rt-proxy"
SHIPPED="$HERE/mtproxy-client/builds"
INSTALL="$HERE/lib/install.sh"

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

# Only the SHIPPED copies are committed; rt-proxy/z2k-rt-proxy-linux-* are build
# output and are not in git. So a fresh CI checkout legitimately has nothing to
# compare against, and the drift comparison is SKIPPED there rather than failed —
# it is a dev-machine guard by nature, since drift can only be introduced by a
# local rebuild. What CI can still check, it does: the shipped binaries must be
# present, be ELF, and pass the installer's size gate.
BUILT_PRESENT=0
ls "$BUILT"/z2k-rt-proxy-linux-* >/dev/null 2>&1 && BUILT_PRESENT=1

md5of() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
    elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
    else echo "NO-MD5-TOOL"; fi
}

# --- the fetch path is still the one this test guards ------------------------
# If someone moves the URL, this guard must be updated with it rather than
# silently protecting a directory nobody reads any more.
if grep -q 'mtproxy-client/builds/\${rtp_bin}' "$INSTALL" 2>/dev/null; then
    ok "install.sh still fetches rt-proxy from mtproxy-client/builds/"
else
    no "install.sh still fetches rt-proxy from mtproxy-client/builds/" \
       "that path" "changed — update this test with it"
fi

# --- the arch list install.sh can ask for -----------------------------------
# Read from install.sh so a new architecture cannot be added there and silently
# escape this check.
ARCHES=$(sed -n 's/.*rtp_arch="\([a-z0-9_]*\)".*/\1/p' "$INSTALL" | sort -u | tr '\n' ' ')
n=$(printf '%s\n' $ARCHES | grep -c .)
if [ "${n:-0}" -ge 5 ]; then
    ok "found the arch list install.sh maps ($ARCHES)"
else
    no "found the arch list install.sh maps" ">=5 arches" "$ARCHES"
fi

# --- every shipped arch must exist and match the built one -------------------
for a in $ARCHES; do
    b="$BUILT/z2k-rt-proxy-linux-$a"
    s="$SHIPPED/z2k-rt-proxy-linux-$a"
    if [ ! -f "$s" ]; then
        no "$a: SHIPPED binary present" "a file" "missing $s — install.sh would 404"
        continue
    fi
    if [ ! -f "$b" ]; then
        if [ "$BUILT_PRESENT" = 0 ]; then
            skip "$a: shipped binary matches the built one" "no build output in this checkout"
        else
            # Some arches built, this one not: that IS drift, not a clean checkout.
            no "$a: built binary present" "a file" "missing $b while other arches built"
        fi
        continue
    fi
    mb=$(md5of "$b"); ms=$(md5of "$s")
    if [ "$mb" = "$ms" ]; then
        ok "$a: shipped binary matches the built one"
    else
        no "$a: shipped binary matches the built one" "$mb" "$ms (rebuild not copied to $SHIPPED)"
    fi
done

# --- and they must be ELF, not a stray text file / LFS pointer --------------
for a in $ARCHES; do
    s="$SHIPPED/z2k-rt-proxy-linux-$a"
    [ -f "$s" ] || continue
    # ELF magic: 0x7f 'E' 'L' 'F'
    if [ "$(dd if="$s" bs=4 count=1 2>/dev/null | od -An -c | tr -d ' \n')" = '177ELF' ]; then
        ok "$a: shipped file is an ELF binary"
    else
        no "$a: shipped file is an ELF binary" "ELF magic" "something else"
    fi
    # install.sh rejects anything under 500000 bytes; catch a truncated commit here.
    sz=$(wc -c < "$s" | tr -d ' ')
    [ "${sz:-0}" -gt 500000 ] && ok "$a: shipped binary passes install.sh's size gate ($sz)" \
                              || no "$a: shipped binary passes install.sh's size gate" ">500000" "$sz"
done

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
