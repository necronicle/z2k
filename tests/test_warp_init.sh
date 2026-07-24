#!/bin/sh
# tests/test_warp_init.sh — decision logic of the WARP tunnel init (files/init.d/S51z2k-warp).
#
# The script spawns supervisors and talks to NDM, so what is tested here is what DECIDES:
# which interface we claim and which address we put on it. Both had real bugs — adopting a
# stranger's tunnel, and pinning an address another interface already owns (NDM then refuses
# to raise the interface and the tunnel never comes up, silently).

TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

Z2K_WARP_INIT_SOURCE_ONLY=1
export Z2K_WARP_INIT_SOURCE_ONLY
WARP_DIR="$SB/warp"; mkdir -p "$WARP_DIR"
STATE_IFACE="$WARP_DIR/iface"
STATE_ADDR="$WARP_DIR/addr"
LOG="$SB/log"
# shellcheck disable=SC1090
. "$ROOT/files/init.d/S51z2k-warp"

WARP_DIR="$SB/warp"; STATE_IFACE="$WARP_DIR/iface"; STATE_ADDR="$WARP_DIR/addr"; ADDR_NET="172.16.240"
IFACES=""      # what `ip link show` knows about
ADDRS=""       # "<iface> <addr>" pairs
PKG_CONF="$SB/usque.conf"

ip() {
    # `ip -o link show` with no device: enumerate, so a mutant that adopts "the first live
    # opkgtunN" actually gets one and the hijack guard is really exercised.
    if [ "$1" = "-o" ] && [ "$2" = link ] && [ -z "$4" ]; then
        n=9
        for i in $IFACES; do n=$((n + 1)); printf '%d: %s: <POINTOPOINT,UP> mtu 1280\n' "$n" "$i"; done
        return 0
    fi
    case "$2" in
        show)
            if [ "$1" = link ]; then
                for i in $IFACES; do [ "$i" = "$3" ] && return 0; done
                return 1
            fi ;;
    esac
    if [ "$1" = "-o" ] && [ "$2" = "-4" ]; then
        echo "$ADDRS" | while read -r i a; do
            [ -n "$i" ] && printf '9: %s    inet %s/32 scope global %s\n' "$i" "$a" "$i"
        done
        return 0
    fi
    return 0
}
# the package config we may adopt an interface from
grep() { command grep "$@"; }

printf "\n--- ndm_name: netdev -> NDM object ---\n"
assert_eq "opkgtun0 -> OpkgTun0"   "OpkgTun0" "$(ndm_name opkgtun0)"
assert_eq "opkgtun3 -> OpkgTun3"   "OpkgTun3" "$(ndm_name opkgtun3)"

printf "\n--- pick_iface: first genuinely free slot ---\n"
IFACES="opkgtun0 opkgtun1"
assert_eq "skips the taken ones"   "opkgtun2" "$(pick_iface)"
IFACES=""
assert_eq "nothing taken -> tun0"  "opkgtun0" "$(pick_iface)"

printf "\n--- iface_name: recorded state wins ---\n"
echo "opkgtun4" > "$STATE_IFACE"; IFACES="opkgtun0 opkgtun4"
assert_eq "reuses what we recorded" "opkgtun4" "$(iface_name)"

printf "\n--- iface_name: a STRANGER's tunnel is never adopted ---\n"
# Regression: adopting any live opkgtunN reconfigured somebody else's Entware tunnel
# (sing-box / xray / AmneziaWG), saved it into startup-config and dropped it on our stop().
rm -f "$STATE_IFACE"
IFACES="opkgtun0"                 # exists, but no usque package config claims it
: > "$PKG_CONF"
assert_eq "picks a free slot instead" "opkgtun1" "$(iface_name)"

printf "\n--- addr_taken_by_other: only OTHER interfaces count ---\n"
ADDRS="opkgtun0 172.16.240.1"
addr_taken_by_other "172.16.240.1" "opkgtun1" && r=0 || r=1
assert_eq "held by another -> conflict"  "0" "$r"
addr_taken_by_other "172.16.240.1" "opkgtun0" && r=0 || r=1
assert_eq "held by OURSELVES -> fine"    "1" "$r"
addr_taken_by_other "172.16.240.9" "opkgtun1" && r=0 || r=1
assert_eq "nobody holds it -> fine"      "1" "$r"

printf "\n--- iface_addr: steps over a conflict instead of dying on it ---\n"
# NDM refuses to raise an interface onto an address another one owns; the old code pinned
# .1 unconditionally and the tunnel silently never came up.
rm -f "$STATE_ADDR"; ADDRS="opkgtun0 172.16.240.1"
assert_eq "conflict -> next free"        "172.16.240.2" "$(iface_addr opkgtun1)"
rm -f "$STATE_ADDR"; ADDRS=""
assert_eq "no conflict -> .1"            "172.16.240.1" "$(iface_addr opkgtun1)"
printf '%s\n' "172.16.240.7" > "$STATE_ADDR"; ADDRS=""
assert_eq "recorded address is reused"   "172.16.240.7" "$(iface_addr opkgtun1)"
printf '%s\n' "172.16.240.7" > "$STATE_ADDR"; ADDRS="opkgtun0 172.16.240.7"
assert_eq "recorded but now taken -> moves" "172.16.240.1" "$(iface_addr opkgtun1)"

printf "\n=== warp init tests: %d passed, %d failed ===\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
