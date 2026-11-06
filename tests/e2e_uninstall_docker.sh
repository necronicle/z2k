#!/bin/sh
# tests/e2e_uninstall_docker.sh — сквозной прогон настоящего удаления на фальшивом роутере.
#
# В основной набор не входит: нужен Docker. В uninstall_zapret2 и z2k_cleanup.sh прошиты
# пути /opt/..., поэтому гонять их можно только в одноразовом контейнере без сети.
# BusyBox ash в Alpine — та же оболочка, что на роутере; ndmc, iptables, ipset и ip — заглушки.
#
# Запуск: sh tests/e2e_uninstall_docker.sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${Z2K_E2E_IMAGE:-alpine:3.22}"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "Docker недоступен"; exit 2; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
# Копия, а не монтирование каталога: Docker на маке не видит часть путей.
(cd "$DIR" && tar -cf - z2k.sh z2k_cleanup.sh lib files webpanel/uninstall.sh) | tar -xf - -C "$tmp"

cat > "$tmp/inner.sh" <<'EOF'
PATH_KIND="$1"; SCEN="$2"
export PATH=/stub:/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /stub /state /opt/bin /opt/sbin /opt/etc/init.d /opt/etc/ndm/netfilter.d /opt/etc/lighttpd \
    /opt/etc/z2k/webpanel /opt/etc/z2k/.trust /opt/etc/z2k-warp /opt/var/log /opt/z2k-rollback /tmp/z2k-log /var/run
cat > /stub/ndmc <<'N'
#!/bin/sh
cmd="$2"
case "$cmd" in
  "show running-config") [ -f /state/fail-show ] && exit 7; cat /state/running; exit 0 ;;
  "system configuration save") exit 0 ;;
  "no ip host "*)
    line="${cmd#no }"
    [ -f /state/fail-no ] && [ "$line" = "$(cat /state/fail-no)" ] && exit 3
    grep -qxF "$line" /state/running || exit 1
    grep -vxF "$line" /state/running > /state/r.new; mv /state/r.new /state/running; exit 0 ;;
esac
exit 0
N
# iptables с состоянием: иначе циклы снятия правил не исполняются вовсе.
cat > /stub/iptables <<'N'
#!/bin/sh
tbl=filter; a=""
while [ $# -gt 0 ]; do
    case "$1" in
        -w) shift ;;
        -t) tbl="$2"; shift 2 ;;
        *) a="$a $1"; shift ;;
    esac
done
a="${a# }"; op="${a%% *}"; rest="${a#* }"
R=/state/rules
case "$a" in
  *"-L "*)
    ch=$(printf '%s\n' "$a" | sed -n 's/.*-L \([^ ]*\).*/\1/p')
    grep "^$tbl $ch " "$R" | sed 's/-j NFQUEUE --queue-num \([0-9]*\).*/NFQUEUE num \1 bypass/' | awk '{ $1=""; $2=""; print NR, $0 }'
    exit 0 ;;
esac
case "$op" in
  -C) grep -qxF "$tbl $rest" "$R" ;;
  -S) grep "^$tbl $rest " "$R" | sed "s/^$tbl /-A /"; exit 0 ;;
  -D)
    ch="${rest%% *}"; num="${rest#* }"
    case "$num" in
      *[!0-9]*) n=$(grep -nxF "$tbl $rest" "$R" | head -1 | cut -d: -f1) ;;
      *) n=$(grep -n "^$tbl $ch " "$R" | sed -n "${num}p" | cut -d: -f1) ;;
    esac
    [ -n "$n" ] || exit 1
    sed -i "${n}d" "$R" ;;
  *) exit 0 ;;
esac
N
printf '#!/bin/sh\nexit 1\n' > /stub/ip6tables
cat > /state/rules <<'N'
mangle PREROUTING -p tcp -m multiport --dports 80,443,2053,2083,2087,2096,5222,8443 -m connskip --connskip 30 -j PPE
mangle FORWARD -p tcp -m multiport --dports 80,443,2053,2083,2087,2096,5222,8443 -m connskip --connskip 30 -j PPE
mangle PREROUTING -p udp --dport 443 -m connskip --connskip 30 -j PPE
mangle FORWARD -p udp --dport 443 -m connskip --connskip 30 -j PPE
mangle _NDM_POSTROUTING_TTL -m mark --mark 0x40000000/0x40000000 -j RETURN
mangle PREROUTING -m set --match-set z2k_warp dst -j Z2K_WARP
nat PREROUTING -p udp --dport 53 -m set --match-set z2k_lan4 src -m set ! --match-set z2k_lan4 dst -j REDIRECT --to-ports 53
nat PREROUTING -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443
nat PREROUTING -p tcp --dport 8080 -j REDIRECT --to-port 80
mangle POSTROUTING -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
mangle POSTROUTING -p tcp -j NFQUEUE --queue-num 300 --queue-bypass
filter FORWARD -o z2ktun0 -m mark --mark 0x989/0x989 -j ACCEPT
filter FORWARD -i z2ktun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
filter OUTPUT -o ppp0 -p udp --sport 53 -j NFLOG --nflog-group 189
nat POSTROUTING -o z2ktun0 -j MASQUERADE
mangle FORWARD -o z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
mangle PREROUTING -p tcp -m multiport --dports 80,443,2053,2083,2087,2096,8443 -m connskip --connskip 30 -j PPE
mangle FORWARD -p udp -m multiport --dports 1024:2407,2409:65535 -m connskip --connskip 30 -j PPE
filter FORWARD -o eth3 -j ACCEPT
N
cat > /stub/ipset <<'N'
#!/bin/sh
case "$1" in
  list) [ "$2" = "-n" ] && cat /state/ipsets ;;
  destroy) grep -vxF "$2" /state/ipsets > /state/s.new; mv /state/s.new /state/ipsets ;;
esac
exit 0
N
cat > /stub/ip <<'N'
#!/bin/sh
echo "ip $*" >> /state/ip.log
case "$*" in
  "-o link show") [ -f /state/tun ] && echo "9: z2ktun0: <POINTOPOINT,UP> mtu 1280 qdisc" ;;
  "link delete"*|"tuntap del"*) [ -f /state/tun-busy ] && exit 1; rm -f /state/tun ;;
esac
exit 0
N
printf '#!/bin/sh\nexit 0\n' > /stub/conntrack
cp /stub/conntrack /stub/crontab
cat > /opt/bin/opkg <<'N'
#!/bin/sh
case "$1" in
  list-installed) sed 's/$/ - 1/' /state/pkgs ;;
  remove)
    shift
    for p in "$@"; do
        case "$p" in -*) continue ;; esac
        grep -vxF "$p" /state/pkgs > /state/p.new; mv /state/p.new /state/pkgs
    done ;;
esac
exit 0
N
printf 'dropbear\nlighttpd\nlighttpd-mod-cgi\nipset\nflock\ncurl\n' > /state/pkgs
# BusyBox pidof ищет по имени процесса, а наши подставные процессы — скрипты.
cat > /stub/pidof <<'N'
#!/bin/sh
ps w | awk -v n="$1" '$0 ~ "/" n "( |$)" && !/awk/ {print $1}'
N
chmod +x /stub/* /opt/bin/opkg

mkdir -p /opt/zapret2/lists /opt/zapret2/nfq2 /opt/zapret2/webpanel /opt/zapret2/www /opt/zapret2.old.111
cp -R /src/lib /opt/zapret2/lib
cp /src/z2k.sh /opt/zapret2/z2k.sh; chmod +x /opt/zapret2/z2k.sh
cp /src/files/*.sh /opt/zapret2/
cp /src/webpanel/uninstall.sh /opt/zapret2/webpanel/
ln -sf /opt/zapret2/z2k.sh /opt/bin/z2k
printf 'sleep 1000\n' > /opt/zapret2/nfq2/nfqws2
# Чужое: должно пережить удаление.
mkdir -p /opt/zapret /opt/other
echo keep > /opt/zapret/keep
printf 'sleep 1000\n' > /opt/other/nfqws2; cp /opt/other/nfqws2 /opt/other/nfqws; cp /opt/other/nfqws2 /opt/other/tpws
sh /opt/zapret2/nfq2/nfqws2 & sh /opt/other/nfqws2 & sh /opt/other/nfqws & sh /opt/other/tpws &
printf 'ENABLED=1\nINIT_APPLY_FW=1\nZ2K_FASTROUTE_OFF=1\n' > /opt/zapret2/config
cp /src/files/ndm/* /src/files/000-zapret2.sh /opt/etc/ndm/netfilter.d/
for s in S02z2k-tcp-tuning S51z2k-warp S96z2k-rt-proxy S96z2k-webpanel S97z2k-http-tunnel S98tg-tunnel S98z2k-detect S99z2k-scheduler S99zapret2; do
    printf '#!/bin/sh\nexit 0\n' > /opt/etc/init.d/$s; chmod +x /opt/etc/init.d/$s
done
for s in S99zapret S99nfqws S10cron; do printf '#!/bin/sh\n' > /opt/etc/init.d/$s; done
chmod +x /opt/etc/init.d/S99zapret /opt/etc/init.d/S99nfqws; chmod -x /opt/etc/init.d/S10cron
echo foreign > /opt/etc/ndm/netfilter.d/50-zapret.sh
touch /opt/etc/opkg.conf /opt/etc/opkg.conf.backup /opt/etc/opkg.conf.z2k-bak
touch /opt/etc/init.d/S99zapret2.backup.1 /opt/sbin/foreign-tool
touch /opt/sbin/z2k-warpd.rb.7 /opt/sbin/foreign.rb.7 /opt/etc/init.d/S99zapret2.z2k-au.5
mkdir -p /opt/lib; touch /opt/lib/libmnl.so.0 /opt/lib/foreign.so; ln -s libmnl.so.0 /opt/lib/libmnl.so
touch /tmp/z2k-job-1.log /tmp/.z2k-scheduler-state /tmp/z2k-dns-check.json /var/run/z2k-x.pid /tmp/foreign.tmp
printf 'ipset\nflock\ncurl\n' > /opt/etc/z2k/installed-packages
echo extra > /opt/etc/z2k-warp/cache.json
mkdir -p /opt/z2k-work; echo w > /opt/z2k-work/w
printf '#!/bin/sh\n' > /opt/etc/init.d/.S80lighttpd.disabled-by-z2k
chmod +x /opt/etc/init.d/.S80lighttpd.disabled-by-z2k
printf 'server.document-root = "/opt/share/www"\n' > /opt/etc/lighttpd/lighttpd.conf
for b in tg-mtproxy-client z2k-rt-proxy z2k-rt-proxy.z2kbak z2k-detect z2k-warpd z2k-usque z2k-warpd.new.123; do echo x > /opt/sbin/$b; done
echo '{}' > /opt/etc/z2k-warp/device.json; echo 8088 > /opt/etc/z2k/webpanel/port; echo k > /opt/etc/z2k/.trust/pinned
for f in z2k-scheduler.log z2k-auto-update.log z2k-auto-update.log.old z2k-detect-watchdog.log; do echo l > /opt/var/log/$f; done
echo m > /opt/etc/.z2k-rkn-fp.list; echo m > /opt/etc/.z2k-rkn-fp.sha256; echo m > /opt/etc/.z2k-instagram-purge-2026-05-28.done
echo r > /opt/z2k-rollback/snap
mkdir -p /opt/z2k-upgrade-backup /opt/etc/zapret2; echo b > /opt/z2k-upgrade-backup/b; echo c > /opt/etc/zapret2/c
cat > /state/running <<'R'
ip host rutracker.org 10.171.171.171
ip host instagram.com 157.240.9.174
ip host www.whatsapp.com 57.144.1.1
ip host redirector.googlevideo.com 74.125.1.1
ip host raw.githubusercontent.com 185.199.108.133
ip host whatsapp.com 85.192.60.175
ip host whatsapp.net 85.192.60.175
ip host g.whatsapp.net 85.192.60.175
ip host mmg.whatsapp.net 85.192.60.175
ip host mmg.whatsapp.net 79.137.196.7
ip host finland10001.discord.media 162.159.1.1
ip host example.com 9.9.9.9
R
printf 'z2k_tg_dc\nz2k_lan4\nforeign_set\n' > /state/ipsets
[ -d /opt/zapret ] && echo nozapret >> /state/ipsets
case "$SCEN" in
  fail-one-pin) echo "ip host instagram.com 157.240.9.174" > /state/fail-no ;;
  fail-show) touch /state/fail-show ;;
  no-foreign) rm -rf /opt/zapret; echo nozapret >> /state/ipsets ;;
  tun-busy) touch /state/tun /state/tun-busy ;;
esac
[ -f /state/tun ] || touch /state/tun
cd /
if [ "$PATH_KIND" = main ]; then
    env Z2K_UNINSTALL_CONFIRMED=1 sh /opt/zapret2/z2k.sh uninstall > /state/out.log 2>&1; rc=$?
else
    sh /src/z2k_cleanup.sh > /state/out.log 2>&1; rc=$?
fi
clean_out=$(sed 's/\x1b\[[0-9;]*m//g' /state/out.log)
fails=0
want() { if eval "$2"; then :; else echo "  [FAIL] $1"; fails=$((fails+1)); fi; }
want "код возврата 0 (получен $rc)" '[ "$rc" = 0 ]'
want "веб-интерфейс: S80lighttpd не возвращён" '[ ! -e /opt/etc/init.d/S80lighttpd ]'
want "чужая запись цела" 'grep -q "^ip host example.com" /state/running || [ -f /state/fail-show ]'
want "чужой ipset цел" 'grep -qx foreign_set /state/ipsets'
want "наши ipset снесены" '! grep -q z2k /state/ipsets'
if [ "$SCEN" = no-foreign ]; then
    want "без чужого zapret общий nozapret снят" '! grep -qx nozapret /state/ipsets'
else
    want "чужой zapret: общий nozapret и каталог целы" 'grep -qx nozapret /state/ipsets && [ -f /opt/zapret/keep ]'
fi
want "хуки сняты, чужой цел" '[ "$(ls /opt/etc/ndm/netfilter.d)" = "50-zapret.sh" ]'
want "службы сняты, чужие целы" '[ "$(ls -A /opt/etc/init.d | tr "\n" " ")" = "S10cron S99nfqws S99zapret " ]'
want "S10cron не тронут" '[ ! -x /opt/etc/init.d/S10cron ]'
want "свой nfqws2 убит" '! ps w | grep -q "[s]h /opt/zapret2/nfq2/nfqws2"'
want "чужие nfqws, nfqws2 и tpws живы" '[ "$(ps w | grep -c "[s]h /opt/other/")" = 3 ]'
want "ключ WARP сохранён, остальное там снято" '[ -f /opt/etc/z2k-warp/device.json ] && [ "$(ls -A /opt/etc/z2k-warp)" = device.json ]'
want "бэкапы и настройки сняты" '[ ! -e /opt/etc/opkg.conf.backup ] && [ ! -e /opt/etc/opkg.conf.z2k-bak ] && [ -e /opt/etc/opkg.conf ] && [ ! -e /opt/etc/z2k ] && [ ! -d /opt/z2k-work ]'
want "ссылка на библиотеку снята, чужая библиотека цела" '[ ! -L /opt/lib/libmnl.so ] && [ -e /opt/lib/foreign.so ]'
want "пакеты: наши и lighttpd сняты, curl и чужой целы" '[ "$(tr "\n" " " < /state/pkgs)" = "dropbear curl " ]'
want "временные файлы сняты, журнал задачи и чужое целы" '[ ! -e /tmp/.z2k-scheduler-state ] && [ ! -e /tmp/z2k-dns-check.json ] && [ ! -e /var/run/z2k-x.pid ] && [ -e /tmp/z2k-job-1.log ] && [ -e /tmp/foreign.tmp ]'
if [ "$SCEN" != tun-busy ]; then
    want "интерфейс WARP удалён" '[ ! -e /state/tun ]'
fi
want "дерево снято" '[ ! -d /opt/zapret2 ] && [ ! -d /opt/zapret2.old.111 ] && [ ! -d /opt/z2k-rollback ] && [ ! -d /opt/z2k-upgrade-backup ]'
want "WARP: правило маршрутизации снято" 'grep -q "ip rule del fwmark 0x989" /state/ip.log'
want "наши правила iptables сняты, чужие остались" '[ "$(sort /state/rules | tr "\n" ";")" = "filter FORWARD -o eth3 -j ACCEPT;mangle POSTROUTING -p tcp -j NFQUEUE --queue-num 300 --queue-bypass;nat PREROUTING -p tcp --dport 8080 -j REDIRECT --to-port 80;" ]'
want "конфигурация снята" '[ ! -d /opt/etc/zapret2 ]'
want "бинарники сняты, чужие целы" '[ "$(ls /opt/sbin | tr "\n" " ")" = "foreign-tool foreign.rb.7 " ]'
want "журналы сняты" '[ -z "$(ls /opt/var/log)" ]'
if [ "$SCEN" = fail-show ]; then
    want "нет ложного успеха: записи не проверены" 'printf "%s" "$clean_out" | grep -q "записи ip host не проверены"'
    want "нет ложного «полностью удален»" '! printf "%s" "$clean_out" | grep -q "полностью удален"'
fi
if [ "$SCEN" = tun-busy ]; then
    want "сказано про оставшийся интерфейс" 'printf "%s" "$clean_out" | grep -q "Остался интерфейс WARP"'
fi
if [ ! -f /state/fail-show ]; then
    if [ "$SCEN" = fail-one-pin ]; then
        want "снято всё, кроме сбойной записи" '[ "$(grep -vc -e example.com -e "ip host instagram.com" /state/running)" = 0 ]'
    else
        want "записи ip host сняты" '[ "$(grep -vc example.com /state/running)" = 0 ]'
    fi
fi
[ "$fails" = 0 ] && echo "[PASS] $PATH_KIND/$SCEN" || { echo "[FAIL] $PATH_KIND/$SCEN"; grep -v example.com /state/running | sed 's/^/    остался пин: /' | head -5; tail -3 /state/out.log | cut -c1-120 | sed 's/^/    /'; exit 1; }
EOF

fail=0
for c in "main normal" "main no-foreign" "main fail-one-pin" "main fail-show" "main tun-busy" \
         "cleanup no-foreign" \
         "cleanup normal" "cleanup fail-one-pin" "cleanup fail-show" "cleanup tun-busy"; do
    # shellcheck disable=SC2086  # два аргумента — разбиение намеренно
    tar -cf - -C "$tmp" . | docker run --rm -i --network none "$IMAGE" sh -c "mkdir /src && tar -xf - -C /src && sh /src/inner.sh $c" || fail=1
done
[ "$fail" = 0 ]
