#!/bin/sh
# tests/test_warp_ndm_hook.sh — 93-z2k-warp.sh возвращает ВСЁ, что NDM сносит
# на регене netfilter: два MARK-правила (mangle PREROUTING, форма --set-xmark
# с маской), MSS-clamp (mangle FORWARD) и MASQUERADE (nat POSTROUTING) для
# z2ktunN из device.json. Только пока режим включён и движок установлен.
# POSIX sh.
TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/files/ndm/93-z2k-warp.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/z2k"

# стабы: iptables пишет argv; -C отвечает «нет правила», чтобы -A дошёл. ipset — сеты есть.
cat > "$SB/bin/iptables" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/ipt.log"
case "\$*" in *" -C "*) exit 1 ;; esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$SB/bin/ipset"
chmod +x "$SB/bin/iptables" "$SB/bin/ipset"

printf 'GAME_WARP_ENABLED=1\n' > "$SB/z2k/config"
printf '{"iface": "z2ktun3", "id": "x"}\n' > "$SB/device.json"

run() { # $1=type $2=table
    rm -f "$SB/ipt.log"
    Z2K_STUB_PATH="$SB/bin" type="$1" table="$2" ZAPRET2_DIR="$SB/z2k" DEVICE_JSON="$SB/device.json" \
        sh "$HOOK" >/dev/null 2>&1
    [ -f "$SB/ipt.log" ] || : > "$SB/ipt.log"
}

run iptables mangle
assert_eq "mangle: MARK for z2k_warp dst, xmark with mask" "1" \
    "$(grep -c -- '-w -t mangle -A PREROUTING -m set --match-set z2k_warp dst -j MARK --set-xmark 0x989/0x989' "$SB/ipt.log")"
assert_eq "mangle: MARK for z2k_warp_src src" "1" \
    "$(grep -c -- '-w -t mangle -A PREROUTING -m set --match-set z2k_warp_src src -j MARK --set-xmark 0x989/0x989' "$SB/ipt.log")"
assert_eq "mangle: MSS clamp on z2ktun3" "1" \
    "$(grep -c -- '-w -t mangle -A FORWARD -o z2ktun3 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' "$SB/ipt.log")"
assert_eq "mangle: no legacy --set-mark form" "0" "$(grep -c -- '--set-mark ' "$SB/ipt.log")"
assert_eq "mangle: nothing in OUTPUT" "0" "$(grep -c -- ' OUTPUT ' "$SB/ipt.log")"

run iptables nat
assert_eq "nat: MASQUERADE on z2ktun3" "1" "$(grep -c -- '-w -t nat -A POSTROUTING -o z2ktun3 -j MASQUERADE' "$SB/ipt.log")"
assert_eq "nat: no mangle rules" "0" "$(grep -c -- '-t mangle' "$SB/ipt.log")"

run iptables filter
assert_eq "filter: nothing" "0" "$(wc -l < "$SB/ipt.log" | tr -d ' ')"

run ip6tables mangle
assert_eq "ip6tables: nothing" "0" "$(wc -l < "$SB/ipt.log" | tr -d ' ')"

printf 'GAME_WARP_ENABLED=0\n' > "$SB/z2k/config"
run iptables mangle
assert_eq "mode off: nothing" "0" "$(wc -l < "$SB/ipt.log" | tr -d ' ')"
printf 'GAME_WARP_ENABLED=1\n' > "$SB/z2k/config"

rm -f "$SB/device.json"
run iptables nat
assert_eq "no device.json: nothing" "0" "$(wc -l < "$SB/ipt.log" | tr -d ' ')"

printf '{"iface": "opkgtun0"}\n' > "$SB/device.json"
run iptables nat
assert_eq "foreign iface name is rejected" "0" "$(wc -l < "$SB/ipt.log" | tr -d ' ')"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
