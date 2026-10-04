#!/bin/sh
# Main-table-only WAN discovery contract. The target BusyBox ip may ignore a
# `default` selector, so lib/wan.sh must still parse the returned routes itself.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wan.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_LOG"
case "$1" in -6) family=6 ;; *) family=4 ;; esac
case "$*" in
    *'route show table main'*) mode=main ;;
    *'route show default'*) mode=fallback ;;
    *) mode=unexpected ;;
esac
eval fail=\${IP_${family}_${mode}_FAIL:-0}
[ "$fail" = 1 ] && exit 1
eval file=\${IP_${family}_${mode}_FILE:-}
[ -n "$file" ] && cat "$file"
exit 0
EOF
chmod +x "$BIN/ip"

IP_LOG="$TMP/ip.log"; export IP_LOG
PATH="$BIN:$PATH"; export PATH
. "$ROOT/lib/wan.sh"

clear_ip() {
    : > "$IP_LOG"
    unset IP_4_main_FILE IP_4_fallback_FILE IP_6_main_FILE IP_6_fallback_FILE
    unset IP_4_main_FAIL IP_4_fallback_FAIL IP_6_main_FAIL IP_6_fallback_FAIL
}
run_capture() {
    family=$1
    set +e
    RESULT=$(z2k_wan_ifaces "$family")
    STATUS=$?
    set -e
}
assert_no_all() {
    if grep -q 'table all' "$IP_LOG"; then
        no "$1" 'no table all query' "$(tr '\n' ';' < "$IP_LOG")"
    else
        ok "$1"
    fi
}

# Two defaults in main are both real WANs. Policy-only routes never participate,
# regardless of whether their device looks like a modem or an arbitrary VPN.
clear_ip
cat > "$TMP/main4" <<'EOF'
default via 10.0.0.1 dev eth3
default via 192.0.2.1 dev ppp0 metric 20
192.168.1.0/24 dev br0 scope link
EOF
cat > "$TMP/fallback4" <<'EOF'
default via 10.0.0.1 dev eth3
default via 192.0.2.1 dev ppp0 metric 20
default via 192.168.8.1 dev usb0 table 16400
default dev mystery-vpn table 16401
EOF
IP_4_main_FILE="$TMP/main4" IP_4_fallback_FILE="$TMP/fallback4"; export IP_4_main_FILE IP_4_fallback_FILE
run_capture -4
[ "$STATUS:$RESULT" = '0:eth3 ppp0' ] && ok 'main table retains both ISP defaults only' || no 'main table defaults' '0:eth3 ppp0' "$STATUS:$RESULT"
[ "$(wc -l < "$IP_LOG" | tr -d ' ')" = 1 ] && ok 'successful main read does not query fallback' || no 'main read count' 1 "$(wc -l < "$IP_LOG" | tr -d ' ')"
assert_no_all 'automatic discovery never queries table all'

# A named VPN is a valid WAN when the operator put its default in main. Device
# names and sysfs link types are not provider classifiers.
clear_ip
mkdir -p "$TMP/net/custom-tap"
: > "$TMP/net/custom-tap/tun_flags"
printf 'default dev nwg0\ndefault dev custom-tap\n' > "$TMP/main4"
Z2K_NET_CLASS="$TMP/net"; export Z2K_NET_CLASS
IP_4_main_FILE="$TMP/main4"; export IP_4_main_FILE
run_capture -4
[ "$STATUS:$RESULT" = '0:nwg0 custom-tap' ] && ok 'named and sysfs-typed VPNs carrying main defaults are accepted' || no 'main VPN' '0:nwg0 custom-tap' "$STATUS:$RESULT"
unset Z2K_NET_CLASS

# The parser accepts only default spellings, rejects annotations for other
# tables, accepts explicit main/254, and excludes loopback while allowing a bridge with a main default.
clear_ip
cat > "$TMP/main4" <<'EOF'
0.0.0.0/0 dev wan0 table main
default dev wan1 table 254
default dev policy0 table 100
default dev lo
default dev br7
10.0.0.0/8 dev lan0
EOF
mkdir -p "$TMP/net/br7/bridge"
Z2K_NET_CLASS="$TMP/net"; export Z2K_NET_CLASS
IP_4_main_FILE="$TMP/main4"; export IP_4_main_FILE
run_capture -4
[ "$STATUS:$RESULT" = '0:wan0 wan1 br7' ] && ok 'default spellings and main annotations are filtered exactly' || no 'main annotations' '0:wan0 wan1 br7' "$STATUS:$RESULT"
unset Z2K_NET_CLASS

# Field report: bridged WAN via an upstream router; policy duplicates and
# ordinary LAN bridges must not expand the set of selected interfaces.
clear_ip
cat > "$TMP/main4" <<'EOF'
default via 192.168.11.1 dev br2 table 4096 metric 1000
default via 192.168.11.1 dev br2 table 16394 src 192.168.11.123 metric 1000
default via 192.168.11.1 dev br2 metric 1000
default dev lan-policy table 12000
192.168.1.0/24 dev br0 scope link
EOF
IP_4_main_FILE="$TMP/main4"; export IP_4_main_FILE
run_capture -4
[ "$STATUS:$RESULT" = '0:br2' ] && ok 'bridged WAN main default survives policy duplicates and LAN routes' || no 'bridged WAN' '0:br2' "$STATUS:$RESULT"

# ECMP works in both iproute2 layouts. A dead/linkdown hop is suppressed without
# hiding a healthy sibling, and duplicate devices are emitted once.
clear_ip
cat > "$TMP/main4" <<'EOF'
default metric 10
    nexthop via 10.0.0.1 dev eth3 weight 1
    nexthop via 192.0.2.1 dev usb0 weight 1
default nexthop via 203.0.113.1 dev dead0 weight 1 dead nexthop via 10.0.0.2 dev eth3 weight 1 nexthop via 198.51.100.1 dev bad0 weight 1 linkdown
EOF
IP_4_main_FILE="$TMP/main4"; export IP_4_main_FILE
run_capture -4
[ "$STATUS:$RESULT" = '0:eth3 usb0' ] && ok 'one-line/multiline ECMP retains healthy hops and isolates dead siblings' || no 'ECMP health' '0:eth3 usb0' "$STATUS:$RESULT"

# IPv6 uses the identical main-table contract.
clear_ip
cat > "$TMP/main6" <<'EOF'
::/0 via fe80::1 dev wan6
default via fe80::2 dev wan6b table main
default via fe80::3 dev policy6 table 16400
fe80::/64 dev br0
EOF
IP_6_main_FILE="$TMP/main6"; export IP_6_main_FILE
run_capture -6
[ "$STATUS:$RESULT" = '0:wan6 wan6b' ] && ok 'IPv6 retains only main defaults' || no 'IPv6 main defaults' '0:wan6 wan6b' "$STATUS:$RESULT"

# BusyBox may ignore `show default` and dump connected routes. That fallback is
# used only when the main-table command fails, and parsing still excludes LAN.
clear_ip
IP_4_main_FAIL=1; export IP_4_main_FAIL
cat > "$TMP/fallback4" <<'EOF'
default dev ppp0
192.168.1.0/24 dev br0
10.10.0.0/16 dev lan0
EOF
IP_4_fallback_FILE="$TMP/fallback4"; export IP_4_fallback_FILE
run_capture -4
[ "$STATUS:$RESULT" = '0:ppp0' ] && ok 'failed main read falls back safely despite BusyBox selector bug' || no 'BusyBox fallback' '0:ppp0' "$STATUS:$RESULT"
[ "$(wc -l < "$IP_LOG" | tr -d ' ')" = 2 ] && ok 'fallback is attempted only after main read failure' || no 'fallback count' 2 "$(wc -l < "$IP_LOG" | tr -d ' ')"
assert_no_all 'fallback path never queries table all'

# Empty is known state and succeeds without fallback; two command failures are
# unknown state and must propagate failure to callers such as self-heal.
clear_ip
run_capture -4
[ "$STATUS:$RESULT" = '0:' ] && ok 'successful empty main table remains empty success' || no 'empty main' '0:' "$STATUS:$RESULT"
[ "$(wc -l < "$IP_LOG" | tr -d ' ')" = 1 ] && ok 'empty success does not trigger fallback' || no 'empty fallback count' 1 "$(wc -l < "$IP_LOG" | tr -d ' ')"

clear_ip
IP_4_main_FAIL=1 IP_4_fallback_FAIL=1; export IP_4_main_FAIL IP_4_fallback_FAIL
run_capture -4
[ "$STATUS:$RESULT" = '1:' ] && ok 'both route reads failing returns failure' || no 'route failure status' '1:' "$STATUS:$RESULT"

# Explicit override is authoritative, normalized and deduplicated without any
# route query, including explicit VPN devices.
clear_ip
set +e
RESULT=$(z2k_wan_ifaces -4 ' nwg0,eth3  nwg0,usb0 ')
STATUS=$?
set -e
[ "$STATUS:$RESULT" = '0:nwg0 eth3 usb0' ] && ok 'explicit WAN list wins and is deduplicated' || no 'override' '0:nwg0 eth3 usb0' "$STATUS:$RESULT"
[ ! -s "$IP_LOG" ] && ok 'explicit WAN list performs no ip call' || no 'override ip calls' none "$(cat "$IP_LOG")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
