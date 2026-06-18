#!/bin/sh
# tests/test_webpanel_bind.sh — webpanel LAN-bind detection (detect_lan_ips).
# Extracts the REAL detect_lan_ips() from webpanel/install.sh and drives it
# against canned `ip` output, asserting it binds to every LAN bridge (main +
# guest segments) and NEVER to WAN / non-bridge interfaces. This is the fix
# for the bug where a single guessed IP picked the wrong segment (often a
# guest bridge), leaving the panel unreachable.
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected '%s', got '%s'\n" "$1" "$2" "$3"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- pull the real function out of the installer (no install side effects) ---
eval "$(sed -n '/^detect_lan_ips() {/,/^}/p' "$SCRIPT_DIR/webpanel/install.sh")"

# --- stub `ip`: serves canned addr/route output from globals ---
FAKE_ADDR=""
FAKE_ROUTE=""
ip() {
    case "$*" in
        *"route show default"*) printf '%s\n' "$FAKE_ROUTE" ;;
        *"-4 addr show"*)        printf '%s\n' "$FAKE_ADDR" ;;
        *) : ;;
    esac
}

run() { detect_lan_ips | tr '\n' ',' ; }

# ------------------------------------------------------------------------------
printf "\n--- Mark's router: br0(192.168.1.1 LAN) + br1(10.1.30.1 guest), ppp0 WAN ---\n"
FAKE_ROUTE="default dev ppp0 scope link metric 1000"
FAKE_ADDR="1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue qlen 1
    inet 127.0.0.1/8 scope host lo
9: ezcfg0: <NO-CARRIER,POINTOPOINT,MULTICAST,NOARP,UP> mtu 1500 qdisc fq_codel qlen 500
    inet 78.47.125.180/32 scope global ezcfg0
33: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0
34: br1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue
    inet 10.1.30.1/24 brd 10.1.30.255 scope global br1
37: ppp0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1492 qdisc fq_codel qlen 1000
    inet 88.87.93.11 peer 178.78.39.254/32 scope global ppp0"
assert_eq "both bridges bound; lo/ezcfg/ppp0 excluded" "192.168.1.1,10.1.30.1," "$(run)"

# ------------------------------------------------------------------------------
printf "\n--- The user: br0(10.149.1.2 LAN in 10.x) + br1(192.168.2.1 guest), eth3 WAN ---\n"
# Old single-IP detect preferred 192.168 over 10.x → picked the GUEST and
# left the panel unreachable. New logic binds BOTH, so the 10.x LAN is kept.
FAKE_ROUTE="default via 100.64.0.1 dev eth3"
FAKE_ADDR="1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
    inet 127.0.0.1/8 scope host lo
3: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 10.149.1.2/24 brd 10.149.1.255 scope global br0
4: br1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 192.168.2.1/24 brd 192.168.2.255 scope global br1
6: eth3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 100.64.5.6/22 scope global eth3"
assert_eq "user's 10.x LAN NOT dropped despite 192.168 guest" "10.149.1.2,192.168.2.1," "$(run)"

# ------------------------------------------------------------------------------
printf "\n--- Paranoia: WAN is itself a bridge (br9 on default route) ---\n"
FAKE_ROUTE="default dev br9 scope link"
FAKE_ADDR="3: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0
9: br9: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 10.4.5.6/24 brd 10.4.5.255 scope global br9"
assert_eq "WAN bridge excluded by default-route name" "192.168.1.1," "$(run)"

# ------------------------------------------------------------------------------
printf "\n--- No bridges at all → empty (caller falls back) ---\n"
FAKE_ROUTE="default dev ppp0"
FAKE_ADDR="1: lo: <LOOPBACK> mtu 65536
    inet 127.0.0.1/8 scope host lo
2: ppp0: <POINTOPOINT,UP> mtu 1492
    inet 88.87.93.11 peer 178.78.39.254/32 scope global ppp0"
assert_eq "no bridges → empty list" "" "$(run)"

# ------------------------------------------------------------------------------
printf "\n--- Dedup: same IP listed twice on one bridge → once ---\n"
FAKE_ROUTE="default dev ppp0"
FAKE_ADDR="3: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0
    inet 192.168.1.1/24 brd 192.168.1.255 scope global secondary br0"
assert_eq "duplicate IP deduped" "192.168.1.1," "$(run)"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
