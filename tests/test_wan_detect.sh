#!/bin/sh
# tests/test_wan_detect.sh
#
# get_default_ifaces4/6 must return ONLY interfaces carrying a default route.
#
# The bug this guards: BusyBox `ip` IGNORES the `default` selector and prints the
# whole routing table, so the original awk (which took `dev` from every line)
# returned every LAN bridge as a WAN. Measured on a live Keenetic:
#
#     ip route show default
#         default dev ppp0 scope link  metric 1000
#         10.1.30.0/24 dev br1 scope link  src 10.1.30.1
#         192.168.1.0/24 dev br0 scope link  src 192.168.1.1
#     old parse -> "ppp0 ppp0 br1 ppp0 ppp0 br0"      new parse -> "ppp0"
#
# Consequence on that router: 18 v4 NFQUEUE rules instead of 6, and LAN-to-LAN
# traffic queued into nfqws2 for nothing. After the fix: 18 -> 6, bypass verified
# unaffected from a client sitting on br0 (rutracker 301, youtube 200,
# instagram 301, discord 200, nnmclub 200).
#
# iproute2 honours the selector, so the extra filtering is a no-op there - which
# is exactly why this went unnoticed: it only misbehaves on the target platform.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="$HERE/files/S99zapret2.new"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wan.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$INIT" ] || { printf '[FAIL] init script not found: %s\n' "$INIT"; exit 1; }

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

BIN="$TMP/bin"; mkdir -p "$BIN"
# Mock `ip`: replays a fixture verbatim, exactly as BusyBox does - i.e. it
# IGNORES the selector it was given. That is the whole point; a mock that
# honoured `default` would make the old code look correct.
cat > "$BIN/ip" <<EOF
#!/bin/sh
case " \$* " in
    *" -6 "*) cat "$TMP/route6" 2>/dev/null ;;
    *)        cat "$TMP/route4" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$BIN/ip"

{ extract_fn get_default_ifaces4 "$INIT"; echo; extract_fn get_default_ifaces6 "$INIT"; } > "$TMP/fns.sh"
grep -q '^get_default_ifaces4()' "$TMP/fns.sh" || { printf '[FAIL] get_default_ifaces4 not found\n'; exit 1; }

run4() { PATH="$BIN:$PATH" sh -c ". '$TMP/fns.sh'; exists() { command -v \"\$1\" >/dev/null 2>&1; }; get_default_ifaces4"; }
run6() { PATH="$BIN:$PATH" sh -c ". '$TMP/fns.sh'; exists() { command -v \"\$1\" >/dev/null 2>&1; }; get_default_ifaces6"; }

# --- 1. the exact table from the live router --------------------------------
cat > "$TMP/route4" <<'EOF'
default dev ppp0 scope link  metric 1000
5.3.3.3 dev ppp0 scope link  metric 1000
10.1.30.0/24 dev br1 scope link  src 10.1.30.1
88.87.64.6 dev ppp0 scope link  metric 1000
178.78.39.254 dev ppp0 scope link  src 88.87.93.11
192.168.1.0/24 dev br0 scope link  src 192.168.1.1
EOF
got=$(run4)
[ "$got" = "ppp0" ] && ok "live Keenetic table -> only the default-route device" \
                    || no "live Keenetic table -> only the default-route device" "ppp0" "$got"
case "$got" in
    *br0*|*br1*) no "LAN bridges are never reported as WAN" "no br0/br1" "$got" ;;
    *)           ok "LAN bridges are never reported as WAN" ;;
esac

# --- 2. `via` form, and a second default (multi-WAN) -------------------------
cat > "$TMP/route4" <<'EOF'
default via 192.168.100.1 dev eth3
192.168.1.0/24 dev br0 scope link  src 192.168.1.1
default via 10.0.0.1 dev usb0 metric 20
EOF
got=$(run4)
case "$got" in
    "eth3 usb0"|"usb0 eth3") ok "multi-WAN: both default devices, no LAN" ;;
    *) no "multi-WAN: both default devices, no LAN" "eth3 usb0" "$got" ;;
esac

# --- 3. 0.0.0.0/0 spelling (some stacks print it that way) -------------------
printf '0.0.0.0/0 via 10.1.1.1 dev wan0 \n172.16.0.0/24 dev br5 scope link \n' > "$TMP/route4"
got=$(run4)
[ "$got" = "wan0" ] && ok "0.0.0.0/0 spelling is recognised as a default route" \
                    || no "0.0.0.0/0 spelling is recognised as a default route" "wan0" "$got"

# --- 4. no default route at all -> empty, not the whole table ---------------
printf '192.168.1.0/24 dev br0 scope link \n10.1.30.0/24 dev br1 scope link \n' > "$TMP/route4"
got=$(run4)
[ -z "$got" ] && ok "no default route -> empty result (never a LAN device)" \
              || no "no default route -> empty result (never a LAN device)" "" "$got"

# --- 5. v6 ------------------------------------------------------------------
cat > "$TMP/route6" <<'EOF'
fe80::/64 dev br0  metric 256
default via fe80::1 dev ppp0  metric 1024
2a02:100::/64 dev br1  metric 256
EOF
got=$(run6)
[ "$got" = "ppp0" ] && ok "v6: only the default-route device" \
                    || no "v6: only the default-route device" "ppp0" "$got"

printf '::/0 via fe80::1 dev wan6 \nfe80::/64 dev br0 \n' > "$TMP/route6"
got=$(run6)
[ "$got" = "wan6" ] && ok "v6: ::/0 spelling is recognised" \
                    || no "v6: ::/0 spelling is recognised" "wan6" "$got"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
