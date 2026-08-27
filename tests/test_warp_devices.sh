#!/bin/sh
# tests/test_warp_devices.sh — список устройств «всё в WARP» (lists/warp/devices.txt
# → ipset z2k_warp_src). Строка — IPv4 или MAC; MAC резолвится через `ip neigh`,
# офлайн-устройство пропускается молча (не ошибка), мусор отбрасывается.
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
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/z2k/lists/warp/games" "$SB/etc"
cp "$SCRIPT_DIR/files/z2k-warp.sh" "$SB/z2k/z2k-warp.sh"

cat > "$SB/bin/ip" <<EOF
#!/bin/sh
case "\$*" in
    "-4 neigh show"*) printf '192.168.1.77 dev br0 lladdr aa:bb:cc:dd:ee:ff REACHABLE\\n192.168.1.78 dev br0 lladdr 11:22:33:44:55:66 STALE\\n192.168.1.79 dev br0  FAILED\\n' ;;
    "neigh show"*) printf 'fe80::1 dev br0 lladdr aa:bb:cc:dd:ee:ff REACHABLE\\n192.168.1.77 dev br0 lladdr aa:bb:cc:dd:ee:ff REACHABLE\\n' ;;
esac
exit 0
EOF
cat > "$SB/bin/ipset" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/ipset.log"
case "\$1" in restore) cat >> "$SB/ipset.log" ;; list) echo "Members:" ;; esac
exit 0
EOF
chmod +x "$SB"/bin/*
printf '{"iface":"z2ktun0"}\n' > "$SB/etc/device.json"

cat > "$SB/z2k/lists/warp/devices.txt" <<'EOF'
# PS5
192.168.1.50
AA:BB:CC:DD:EE:FF
11-22-33-44-55-66
de:ad:be:ef:00:01
bad
999.1.1.1
10.0.0.7
100.64.5.5
127.0.0.1
8.8.8.8
213.176.74.63
EOF

Z2K_STUB_PATH="$SB/bin" ZAPRET2_DIR="$SB/z2k" WARP_LISTS_DIR="$SB/z2k/lists/warp" WARP_DEVICE="$SB/etc/device.json" \
    sh "$SB/z2k/z2k-warp.sh" ipset >/dev/null 2>&1

assert_eq "plain IPv4 loaded" "1" "$(grep -c '^add z2k_warp_src_new 192.168.1.50 ' "$SB/ipset.log")"
assert_eq "MAC resolved via ip neigh (upper-case)" "1" "$(grep -c '^add z2k_warp_src_new 192.168.1.77 ' "$SB/ipset.log")"
assert_eq "MAC with dashes resolved" "1" "$(grep -c '^add z2k_warp_src_new 192.168.1.78 ' "$SB/ipset.log")"
assert_eq "offline MAC skipped silently" "0" "$(grep -c 'de:ad:be:ef' "$SB/ipset.log")"
assert_eq "no IPv6 leaks into the inet set" "0" "$(grep -c 'fe80' "$SB/ipset.log")"
assert_eq "garbage dropped" "0" "$(grep -c 'bad' "$SB/ipset.log")"
assert_eq "bad octet dropped" "0" "$(grep -c '999' "$SB/ipset.log")"
assert_eq "private-range device IP allowed (it is a LAN client)" "1" "$(grep -c '^add z2k_warp_src_new 10.0.0.7 ' "$SB/ipset.log")"
# ПОЛЕ ОЗНАЧАЕТ УСТРОЙСТВО В ЛОКАЛЬНОЙ СЕТИ, и фильтр обязан это отражать.
# Раньше принималось всё с первым октетом 1-255. Правило для источников стоит
# в PREROUTING БЕЗ `-i`, поэтому публичный адрес здесь метит ВХОДЯЩИЙ трафик от
# того хоста и уводит ответы ему в туннель — так можно отрезать роутеру его же
# апстрим. Loopback по той же причине: правило матчится и на lo.
assert_eq "CGNAT-адрес устройства принимается" "1" "$(grep -c '^add z2k_warp_src_new 100.64.5.5 ' "$SB/ipset.log")"
assert_eq "loopback в источники не попадает" "0" "$(grep -c '127.0.0.1' "$SB/ipset.log")"
assert_eq "публичный адрес в источники не попадает" "0" "$(grep -c '8.8.8.8' "$SB/ipset.log")"
assert_eq "адрес релея в источники не попадает" "0" "$(grep -c '213.176.74.63' "$SB/ipset.log")"
assert_eq "src set swapped in" "1" "$(grep -c '^swap z2k_warp_src_new z2k_warp_src' "$SB/ipset.log")"
assert_eq "dst set also (re)built" "1" "$(grep -c '^swap z2k_warp_new z2k_warp' "$SB/ipset.log")"
assert_eq "devices never leak into the DESTINATION set" "0" "$(grep -c '^add z2k_warp_new ' "$SB/ipset.log")"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
