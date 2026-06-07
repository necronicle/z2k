#!/bin/sh
# tests/test_tpws.sh - Unit tests for files/z2k-tpws.sh (tpws youtube layer lib).
# Verifies rule SHAPE (redirect + mark), loop-freedom (NO OUTPUT redirect),
# mark-value parity with the nfqws2 exclusion, port, and the CIDR loader.
# POSIX sh compatible (busybox ash). Run: sh tests/test_tpws.sh

TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] %s\n" "$1"
    else TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] %s\n      want=[%s] got=[%s]\n" "$1" "$2" "$3"; fi
}
assert_has() {   # file CONTAINS regex
    if grep -qE "$3" "$2" 2>/dev/null; then TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] %s\n" "$1"
    else TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] %s (no match: %s)\n" "$1" "$3"; fi
}
assert_hasnt() { # file does NOT contain regex
    if grep -qE "$3" "$2" 2>/dev/null; then TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] %s (unexpected match: %s)\n" "$1" "$3"
    else TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] %s\n" "$1"; fi
}

HERE=$(cd "$(dirname "$0")/.." && pwd)
LIB="$HERE/files/z2k-tpws.sh"
TMP=$(mktemp -d /tmp/tpws_test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls"; : > "$CALLS"
IPSET="$TMP/ipset"; : > "$IPSET"
RESTORE="$TMP/restore"; : > "$RESTORE"
DEL="$TMP/deleted"; mkdir -p "$DEL"

# --- mocks ---
# add-phase: -C always "absent" (return 1) so the -I/-A adds always fire.
# remove-phase (after $REMOVE set): -C is "present" until a -D for the same
# rule has run (tracked in $DEL) — lets the remove while-loops run once.
_ipt() {
    fam="$1"; shift
    printf '%s %s\n' "$fam" "$*" >> "$CALLS"
    # op-agnostic id for a rule (strip -C/-D/-A/-I + position digit, hash safe)
    # canonical id: strip -w and the op token (-C/-D/-A/-I) and any -I position,
    # so "iptables -w ... -C" and the "... -D" / no-w fallback map to one rule.
    kid=$(printf '%s' "$fam $*" | sed 's/ -w / /g; s/ -[CDAI] / /g; s/ PREROUTING [0-9]* / PREROUTING /; s/ OUTPUT [0-9]* / OUTPUT /' | cksum | cut -d' ' -f1)
    case " $* " in
        *" -C "*)
            if [ -n "${REMOVE:-}" ]; then
                [ -f "$DEL/$kid" ] && return 1   # already deleted -> absent
                return 0                          # present
            fi
            return 1 ;;                           # add-phase: always absent
        *" -D "*) : > "$DEL/$kid"; return 0 ;;
    esac
    return 0
}
iptables()  { _ipt v4 "$@"; }
ip6tables() { _ipt v6 "$@"; }
ipset() { printf 'ipset %s\n' "$*" >> "$IPSET"; [ "$1" = restore ] && cat >> "$RESTORE"; return 0; }
sleep() { :; }   # kill the verify-retry backoff delay

# lib config: temp paths, non-empty CIDR snapshots, force v6 path on
TPWS_CONFIG_FILE="$TMP/config"; : > "$TPWS_CONFIG_FILE"
TPWS_CIDR4="$TMP/yt4.txt"; printf '1.2.3.0/24\n' > "$TPWS_CIDR4"
TPWS_CIDR6="$TMP/yt6.txt"; printf '2a00:1450::/32\n' > "$TPWS_CIDR6"
_Z2K_TPWS_V6=1
. "$LIB"

# ---- constants / parity ----
assert_eq "port is 1446"                   "1446"        "$TPWS_PORT"
assert_eq "mark is DESYNC_MARK 0x40000000" "0x40000000"  "$TPWS_MARK"
assert_eq "v4 ipset name"                  "z2k_tpws"    "$TPWS_SET4"
assert_eq "v6 ipset name"                  "z2k_tpws6"   "$TPWS_SET6"

# ---- ensure_rules shape ----
z2k_tpws_ensure_rules >/dev/null 2>&1
assert_has "v4 PREROUTING REDIRECT to 1446 via z2k_tpws" "$CALLS" \
    'v4 .*-t nat -I PREROUTING 1 -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446'
assert_has "v4 mangle OUTPUT MARK 0x40000000 owner nobody" "$CALLS" \
    'v4 .*-t mangle -A OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000'
assert_has "v6 PREROUTING REDIRECT to 1446 via z2k_tpws6" "$CALLS" \
    'v6 .*-t nat -I PREROUTING 1 -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446'
# loop-freedom: REDIRECT is PREROUTING-only (an OUTPUT redirect would loop
# tpws's own outbound to the youtube IPs back into tpws).
assert_hasnt "NO OUTPUT REDIRECT (loop-freedom)"          "$CALLS" '\-I OUTPUT .*-j REDIRECT'
assert_hasnt "NO REDIRECT-to-1446 in OUTPUT (loop-free)"  "$CALLS" 'OUTPUT .*--to-port 1446'
# the ipset must be loaded before the rules reference it
assert_has "v4 ipset created"                             "$IPSET" 'ipset create z2k_tpws hash:net family inet'
assert_has "v6 ipset created"                             "$IPSET" 'ipset create z2k_tpws6 hash:net family inet6'

# ---- remove_rules issues deletes ----
: > "$CALLS"; rm -rf "$DEL"; mkdir -p "$DEL"; REMOVE=1
z2k_tpws_remove_rules >/dev/null 2>&1
assert_has "remove drops v4 PREROUTING redirect" "$CALLS" \
    'v4 .*-t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446'
assert_has "remove drops v4 mangle mark" "$CALLS" \
    'v4 .*-t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK'
assert_has "remove drops v6 PREROUTING redirect" "$CALLS" \
    'v6 .*-t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446'
unset REMOVE

# ---- CIDR loader: filters comments/junk, loads valid CIDRs ----
printf '# comment line with /slash\n173.194.192.0/19\n64.233.160.0/19\nnot-an-ip\n2a00:1450::/40\n' > "$TPWS_CIDR4"
: > "$RESTORE"; : > "$IPSET"
_z2k_tpws_load_set z2k_tpws "$TPWS_CIDR4" inet >/dev/null 2>&1
assert_has   "loader loads a valid v4 CIDR via restore" "$RESTORE" '^add z2k_tpws 173.194.192.0/19 -exist$'
assert_hasnt "loader skips comment lines"               "$RESTORE" 'comment line'
assert_hasnt "loader skips junk lines"                  "$RESTORE" 'not-an-ip'

printf "\n%d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
