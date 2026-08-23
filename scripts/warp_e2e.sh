#!/bin/sh
# scripts/warp_e2e.sh — сквозная проверка WARP на роутере владельца.
#
# Полный жизненный цикл по спеку (§10.3): установить → включить → трафик
# через туннель с самого роутера И с LAN-клиента (PREROUTING-путь) →
# выключить (RSS ноль, интерфейса нет, NAT снят) → удалить (бинаря нет, ключ
# есть) → установить снова (устройство то же). Любой провал — exit 1 с шагом.
#
# Запуск с мака:  ROUTER_PASS=... sh scripts/warp_e2e.sh
# Переменные: ROUTER (192.168.1.1), ROUTER_PORT (222), ROUTER_PASS.
# Бинарь движка под арку роутера должен лежать в z2k-warpd/builds/ — скрипт
# копирует его на роутер сам, чтобы не зависеть от раздачи с GitHub.
set -u
R="${ROUTER:-192.168.1.1}"; P="${ROUTER_PORT:-222}"
[ -n "${ROUTER_PASS:-}" ] || { echo "ROUTER_PASS не задан" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
ssh_r() { sshpass -p "$ROUTER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$P" "root@$R" "$@"; }
scp_r() { sshpass -p "$ROUTER_PASS" scp -O -o StrictHostKeyChecking=no -P "$P" "$@"; }
step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

step "подготовка: файлы обвязки и бинарь на роутер"
ARCH=$(ssh_r 'uname -m')
case "$ARCH" in aarch64) BA=arm64 ;; mips) BA=mips ;; mipsel|mipsle) BA=mipsel ;; armv7*) BA=arm ;; x86_64) BA=amd64 ;; *) fail "арка $ARCH" ;; esac
BIN="$HERE/z2k-warpd/builds/z2k-warpd-linux-$BA"
[ -s "$BIN" ] || fail "нет $BIN — cd z2k-warpd && make $BA"
scp_r "$HERE/files/z2k-warp.sh" "root@$R:/opt/zapret2/z2k-warp.sh" || fail scp
scp_r "$HERE/files/init.d/S51z2k-warp" "root@$R:/opt/etc/init.d/S51z2k-warp" || fail scp
scp_r "$HERE/files/ndm/93-z2k-warp.sh" "root@$R:/opt/etc/ndm/netfilter.d/93-z2k-warp.sh" || fail scp
scp_r "$BIN" "root@$R:/tmp/z2k-warpd.e2e" || fail scp
ssh_r 'chmod 755 /opt/zapret2/z2k-warp.sh /opt/etc/init.d/S51z2k-warp /opt/etc/ndm/netfilter.d/93-z2k-warp.sh /tmp/z2k-warpd.e2e'
# Установщик качает бинарь с GitHub; для E2E подсовываем локальный через WARP_FETCH_STUB.
W='WARP_FETCH_STUB=/tmp/z2k-warpd.e2e sh /opt/zapret2/z2k-warp.sh'

step "install"
ssh_r "$W install" || fail install
ssh_r 'test -x /opt/sbin/z2k-warpd && test -s /opt/etc/z2k-warp/device.json' || fail "после install нет бинаря или ключа"
ID1=$(ssh_r 'sed -n "s/.*\"id\": *\"\([^\"]*\)\".*/\1/p" /opt/etc/z2k-warp/device.json')
[ -n "$ID1" ] || fail "device id пуст"
ssh_r 'pgrep -f "z2k-warpd run" >/dev/null' && fail "демон запущен после install (не должен)"

step "enable"
ssh_r "$W enable"; rc=$?
[ "$rc" = 0 ] || fail "enable rc=$rc"
ssh_r 'sh /opt/zapret2/z2k-warp.sh status' | grep -q 'ready=1' || fail "не ready"
IF=$(ssh_r 'sed -n "s/.*\"iface\": *\"\(z2ktun[0-9]*\)\".*/\1/p" /opt/etc/z2k-warp/device.json')
[ -n "$IF" ] || fail "нет iface"
ssh_r "curl -s -m 10 --interface $IF https://1.1.1.1/cdn-cgi/trace" | grep -q '^warp=on' || fail "warp=on через $IF"

step "путь LAN-клиента (PREROUTING → mark → table 989 → $IF)"
ssh_r 'ipset add z2k_warp 1.1.1.1/32 -exist'
curl -s -m 10 https://1.1.1.1/cdn-cgi/trace | grep -q '^warp=on' || { ssh_r 'ipset del z2k_warp 1.1.1.1/32'; fail "трафик LAN-клиента не ушёл в WARP"; }
ssh_r 'ipset del z2k_warp 1.1.1.1/32'
PID=$(ssh_r 'sed -n "s/.*\"pid\":\([0-9]*\).*/\1/p" /tmp/z2k-warp/status.json')
echo "RSS: $(ssh_r "grep VmRSS /proc/$PID/status")"

step "NDM-хук переасcертит правила после регена"
ssh_r 'iptables -w -t nat -D POSTROUTING -o '"$IF"' -j MASQUERADE; type=iptables table=nat sh /opt/etc/ndm/netfilter.d/93-z2k-warp.sh'
ssh_r "iptables -w -t nat -C POSTROUTING -o $IF -j MASQUERADE" || fail "хук не вернул MASQUERADE"

step "disable"
ssh_r "$W disable" || fail disable
ssh_r 'pgrep -f "z2k-warpd run" >/dev/null' && fail "демон жив после disable"
ssh_r "ip link show $IF >/dev/null 2>&1" && fail "интерфейс жив после disable"
ssh_r 'iptables -w -t nat -S POSTROUTING | grep -q z2ktun' && fail "NAT-правило осталось"
ssh_r 'iptables -w -t mangle -S PREROUTING | grep -q z2k_warp' && fail "MARK-правило осталось"

step "remove"
ssh_r "$W remove" || fail remove
ssh_r 'test ! -e /opt/sbin/z2k-warpd && test -s /opt/etc/z2k-warp/device.json' || fail "remove оставил бинарь или потерял ключ"

step "повторная установка — устройство то же"
ssh_r "$W install" || fail reinstall
ID2=$(ssh_r 'sed -n "s/.*\"id\": *\"\([^\"]*\)\".*/\1/p" /opt/etc/z2k-warp/device.json')
[ "$ID1" = "$ID2" ] || fail "перерегистрация ($ID1 → $ID2)"
ssh_r "$W remove" >/dev/null
ssh_r 'rm -f /tmp/z2k-warpd.e2e'
echo; echo "E2E OK ($ARCH, $IF, device $ID1)"
