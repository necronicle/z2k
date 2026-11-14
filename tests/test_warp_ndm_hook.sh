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
cp "$SCRIPT_DIR/files/z2k-warp.sh" "$SB/z2k/z2k-warp.sh"
printf "v1\nmyip.ru\n" > "$SB/domains.v1"

# стабы: iptables пишет argv; -C отвечает «нет правила», чтобы -A дошёл. ipset — сеты есть.
cat > "$SB/bin/iptables" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/ipt.log"
# Файл noqueue — «ядро без NFQUEUE»: правило очереди не встаёт.
case "\$*" in *NFQUEUE*) [ -f "$SB/noqueue" ] && exit 1 ;; esac
case "\$*" in *" -C "*) exit 1 ;; esac
exit 0
EOF
cat > "$SB/bin/ipset" <<'EOF'
#!/bin/sh
if [ "$1 $2" = 'list -n' ] && [ -z "$3" ]; then echo z2kd_192.168.1.10; fi
exit 0
EOF
cat > "$SB/bin/ip6tables" <<EOF
#!/bin/sh
echo "ip6 \$*" >> "$SB/ipt.log"
case "\$*" in *" -C "*) exit 1 ;; esac
exit 0
EOF
chmod +x "$SB/bin/iptables" "$SB/bin/ip6tables" "$SB/bin/ipset"

printf 'GAME_WARP_ENABLED=1\n' > "$SB/z2k/config"
printf '{"iface": "z2ktun3", "id": "x"}\n' > "$SB/device.json"

run() { # $1=type $2=table
    rm -f "$SB/ipt.log"
    Z2K_STUB_PATH="$SB/bin" type="$1" table="$2" ZAPRET2_DIR="$SB/z2k" DEVICE_JSON="$SB/device.json" WARP_DOMAINS="$SB/domains.v1" SYS_CLASS_NET="$SB/sys/class/net" \
        sh "$HOOK" >/dev/null 2>&1
    [ -f "$SB/ipt.log" ] || : > "$SB/ipt.log"
}

run iptables mangle
assert_eq "mangle: MARK for z2k_warp dst, xmark with mask" "1" \
    "$(grep -c -- '-w -t mangle -A PREROUTING -m set --match-set z2k_warp dst -j Z2K_WARP' "$SB/ipt.log")"
assert_eq "mangle: no whole-device rule" "0" \
    "$(grep -c -- '-w -t mangle -A PREROUTING -m set --match-set z2k_warp_src src -j MARK --set-xmark 0x989/0x989' "$SB/ipt.log")"
assert_eq "mangle: MARK for client-scoped DNS set" "1" \
    "$(grep -c -- '-w -t mangle -A PREROUTING -s 192.168.1.10/32 -m set --match-set z2kd_192.168.1.10 dst -j Z2K_WARP' "$SB/ipt.log")"
# Соединение держит маршрут: реген возвращает и вход для соединений через WARP.
printf '{"iface": "z2ktun3", "id": "x", "addr_v4": "172.16.0.2"}\n' > "$SB/device.json"
run iptables mangle
assert_eq "mangle: WARP flows keep their mark" "1" \
    "$(grep -c -- '-w -t mangle -A Z2K_WARP ! -i z2ktun3 -m conntrack --ctstate RELATED,ESTABLISHED --ctrepldst 172.16.0.2/32 -j MARK --set-xmark 0x989/0x989' "$SB/ipt.log")"
assert_eq "mangle: entry for WARP flows restored" "1" \
    "$(grep -c -- '-w -t mangle -A PREROUTING ! -i z2ktun3 -m conntrack --ctstate RELATED,ESTABLISHED --ctrepldst 172.16.0.2/32 -j Z2K_WARP' "$SB/ipt.log")"
printf '{"iface": "z2ktun3", "id": "x"}\n' > "$SB/device.json"
assert_eq "mangle: MSS clamp on z2ktun3" "1" \
    "$(grep -c -- '-w -t mangle -A FORWARD -o z2ktun3 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' "$SB/ipt.log")"
assert_eq "mangle: no legacy --set-mark form" "0" "$(grep -c -- '-A .*--set-mark ' "$SB/ipt.log")"
assert_eq "mangle: nothing in OUTPUT" "0" "$(grep -c -- '-A OUTPUT ' "$SB/ipt.log")"

# WDTT client traffic is opt-in and identified after decapsulation by its
# ingress interface. It must not alter the router's outer WDTT transport.
assert_eq "mangle: WDTT route is off by default" "0" "$(grep -c -- '-A Z2K_WARP -i wdtt0 -j MARK ' "$SB/ipt.log")"
mkdir -p "$SB/sys/class/net/wdtt0"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=1\n' > "$SB/z2k/config"
run iptables mangle
assert_eq "mangle: WDTT client traffic marked by ingress interface" "1" \
    "$(grep -c -- '-w -t mangle -A Z2K_WARP -i wdtt0 -j MARK --set-xmark 0x989/0x989' "$SB/ipt.log")"

rmdir "$SB/sys/class/net/wdtt0"
run iptables mangle
assert_eq "mangle: WDTT policy survives interface recreation" "1" "$(grep -c -- '-A Z2K_WARP -i wdtt0 -j MARK ' "$SB/ipt.log")"

mkdir -p "$SB/sys/class/net/wdtt0"
printf 'GAME_WARP_ENABLED=0\nZ2K_WARP_WDTT=1\n' > "$SB/z2k/config"
run iptables mangle
assert_eq "mangle: WDTT option is inert while WARP is off" "0" "$(grep -c -- '-A Z2K_WARP -i wdtt0 -j MARK ' "$SB/ipt.log")"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=1\n' > "$SB/z2k/config"

run iptables nat
assert_eq "nat: MASQUERADE on z2ktun3" "1" "$(grep -c -- '-w -t nat -A POSTROUTING -o z2ktun3 -j MASQUERADE' "$SB/ipt.log")"
assert_eq "nat: no mangle rules" "0" "$(grep -c -- '-t mangle' "$SB/ipt.log")"

run iptables filter
assert_eq "filter: marked outbound before Keenetic reject" "1" "$(grep -c -- '-w -t filter -I FORWARD 1 -o z2ktun3 -m mark --mark 0x989/0x989 -j ACCEPT' "$SB/ipt.log")"
assert_eq "filter: established return before Keenetic reject" "1" "$(grep -c -- '-w -t filter -I FORWARD 1 -i z2ktun3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "$SB/ipt.log")"
assert_eq "filter: no broad appended accept" "0" "$(grep -c -- '-w -t filter -A FORWARD -o z2ktun3 -j ACCEPT' "$SB/ipt.log")"
assert_eq "filter: LAN, native VPN and both WDTT modes forwarded DNS queued before ACCEPT" "8" "$(grep -c -- '-I FORWARD .*--sport 53.*--ctstate ESTABLISHED.*-j NFQUEUE --queue-num 189 --queue-bypass' "$SB/ipt.log")"
assert_eq "filter: router DNS to LAN, native VPN and both WDTT modes queued" "8" "$(grep -c -- '-I OUTPUT .*--sport 53.*-j NFQUEUE --queue-num 189 --queue-bypass' "$SB/ipt.log")"
assert_eq "filter: no NFLOG copy next to the queue" "0" "$(grep -c -- '-I .*-j NFLOG' "$SB/ipt.log")"
assert_eq "filter: nothing else" "0" "$(grep -vc -- "-t filter" "$SB/ipt.log")"

assert_eq "filter: iptables rebuild leaves ip6tables alone" "0" "$(grep -c '^ip6 ' "$SB/ipt.log")"
touch "$SB/noqueue"
run iptables filter
assert_eq "filter, no NFQUEUE: forwarded DNS copied" "8" "$(grep -c -- '-I FORWARD .*--sport 53.*--ctstate ESTABLISHED.*-j NFLOG --nflog-group 189' "$SB/ipt.log")"
assert_eq "filter, no NFQUEUE: router DNS copied" "8" "$(grep -c -- '-I OUTPUT .*--sport 53.*-j NFLOG --nflog-group 189' "$SB/ipt.log")"
rm -f "$SB/noqueue"

# Устройства с IPv6 спрашивают DNS роутера по IPv6: реген ip6tables обязан
# вернуть ту же очередь DNS, и только её — туннель, метки и NAT в IPv4.
run ip6tables filter
assert_eq "ip6tables filter: router DNS queue restored" "8" "$(grep -c -- '^ip6 -w -t filter -I OUTPUT .*--sport 53.*-j NFQUEUE --queue-num 189 --queue-bypass' "$SB/ipt.log")"
assert_eq "ip6tables filter: forwarded DNS queue restored" "8" "$(grep -c -- '^ip6 -w -t filter -I FORWARD .*--sport 53.*--ctstate ESTABLISHED.*-j NFQUEUE --queue-num 189 --queue-bypass' "$SB/ipt.log")"
assert_eq "ip6tables filter: no tunnel accept rules without IPv6" "0" "$(grep -c -- 'z2ktun' "$SB/ipt.log")"
assert_eq "ip6tables filter: iptables untouched" "0" "$(grep -vc '^ip6 ' "$SB/ipt.log")"
run ip6tables mangle
assert_eq "ip6tables mangle: nothing" "0" "$(wc -l < "$SB/ipt.log" | tr -d ' ')"
run ip6tables nat
assert_eq "ip6tables nat: nothing" "0" "$(wc -l < "$SB/ipt.log" | tr -d ' ')"

# У аккаунта есть IPv6 — реген ip6tables возвращает то же, что в IPv4: NAT66,
# MSS по MTU туннеля минус 60, узкие ACCEPT и цепочку (policy-sync).
printf '{"iface": "z2ktun3", "id": "x", "addr_v6": "2606:4700:110:8a36::1"}\n' > "$SB/device.json"
run ip6tables nat
assert_eq "ip6tables nat: NAT66 on z2ktun3" "1" "$(grep -c -- '^ip6 -w -t nat -A POSTROUTING -o z2ktun3 -j MASQUERADE' "$SB/ipt.log")"
run ip6tables mangle
assert_eq "ip6tables mangle: MSS both ways" "1 1" "$(grep -c -- '^ip6 -w -t mangle -A FORWARD -o z2ktun3 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' "$SB/ipt.log") $(grep -c -- '^ip6 -w -t mangle -A FORWARD -i z2ktun3 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220' "$SB/ipt.log")"
assert_eq "ip6tables mangle: policy synced" "yes" "$(grep -q -- '^ip6 -w -t mangle -S' "$SB/ipt.log" && echo yes || echo no)"
run ip6tables filter
assert_eq "ip6tables filter: tunnel accepts before NDM rules" "1 1" "$(grep -c -- '^ip6 -w -t filter -I FORWARD 1 -o z2ktun3 -m mark --mark 0x989/0x989 -j ACCEPT' "$SB/ipt.log") $(grep -c -- '^ip6 -w -t filter -I FORWARD 1 -i z2ktun3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "$SB/ipt.log")"
assert_eq "ip6tables filter: DNS queue too" "8" "$(grep -c -- '^ip6 -w -t filter -I OUTPUT .*--sport 53.*-j NFQUEUE' "$SB/ipt.log")"
printf '{"iface": "z2ktun3", "id": "x"}\n' > "$SB/device.json"

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
