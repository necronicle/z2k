#!/bin/sh
# tests/e2e/install_uninstall_rig.sh — исполняется ВНУТРИ одноразового контейнера,
# запускает его tests/e2e_install_uninstall_docker.sh. Настоящая установка и настоящее
# удаление; iptables и ipset настоящие. Заглушки только там, где нет железа Keenetic:
# ndmc, opkg, каталог sysctl ускорителей.
apk add -q --no-cache lighttpd-mod_cgi 2>/dev/null; apk add -q --no-cache curl openssl iptables iptables-legacy ipset iproute2 conntrack-tools lighttpd util-linux-misc coreutils gzip findutils >/dev/null 2>&1 || { echo apk-failed; exit 9; }
for t in iptables iptables-save iptables-restore; do ln -sf /usr/sbin/xtables-legacy-multi /usr/sbin/$t 2>/dev/null; done
for t in ip6tables ip6tables-save ip6tables-restore; do ln -sf /usr/sbin/xtables-legacy-multi /usr/sbin/$t 2>/dev/null; done
mkdir -p /state /stub /opt/bin /opt/sbin /opt/lib /opt/etc/init.d /opt/etc/ndm/netfilter.d /opt/etc/lighttpd/conf.d /opt/var/log /opt/tmp /opt/share/www /opt/usr
export PATH=/stub:/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------- ndmc: настоящий формат running-config, журнал вызовов
cat > /stub/ndmc <<'N'
#!/bin/sh
cmd="$2"; echo "$cmd" >> /state/ndmc.calls
case "$cmd" in
  "show running-config") echo "interface Bridge0"; cat /state/hosts; exit 0 ;;
  "system configuration save") exit 0 ;;
  "no ip host "*) l="${cmd#no }"; grep -qxF "$l" /state/hosts || exit 1; grep -vxF "$l" /state/hosts > /state/h.new; mv /state/h.new /state/hosts; exit 0 ;;
  "ip host "*) grep -qxF "$cmd" /state/hosts || echo "$cmd" >> /state/hosts; exit 0 ;;
  "show version") echo "hw_id: KN-RIG"; exit 0 ;;
esac
exit 0
N
# Запись пользователя на его адрес: обязана пережить всё.
printf 'ip host my.nas.example 192.168.1.50\nip host github.com 140.82.121.3\nip host finland7.discord.media 162.159.1.1\nip host 4pda.to 1.2.3.4\n' > /state/hosts
# ---------- opkg: пакеты считаем уже стоящими, как после команды из README
cat > /opt/bin/opkg <<'N'
#!/bin/sh
echo "opkg $*" >> /state/opkg.calls
case "$1" in
  list-installed) cat /state/pkgs ;;
  --version) echo "opkg rig" ;;
esac
exit 0
N
for p in libmnl libnetfilter-queue libnfnetlink libcap zlib curl flock unzip iptables xtables-addons_legacy kmod_ndms ipset openssl-util lighttpd lighttpd-mod-cgi dropbear; do echo "$p - 1"; done > /state/pkgs
chmod +x /stub/ndmc /opt/bin/opkg
# ---------- то, что стояло до нас
ln -sf /usr/sbin/lighttpd /opt/sbin/lighttpd
mkdir -p /opt/lib/lighttpd; cp -a /usr/lib/lighttpd/. /opt/lib/lighttpd/ 2>/dev/null
printf '#!/bin/sh\nENABLED=yes\nPROCS=lighttpd\n. /opt/etc/init.d/rc.func 2>/dev/null\n' > /opt/etc/init.d/S80lighttpd; chmod +x /opt/etc/init.d/S80lighttpd
printf '#!/bin/sh\n' > /opt/etc/init.d/rc.func; printf '#!/bin/sh\n' > /opt/etc/init.d/S51dropbear; chmod +x /opt/etc/init.d/S51dropbear
printf 'server.document-root = "/opt/share/www"\n' > /opt/etc/lighttpd/lighttpd.conf
printf 'src/gz entware http://bin.entware.net/aarch64-k3.10\n' > /opt/etc/opkg.conf
touch /opt/lib/libmnl.so.0 /opt/lib/libnfnetlink.so.0 /opt/lib/libnetfilter_queue.so.1 /opt/share/www/index.html
printf '#!/bin/sh\necho mine\n' > /opt/etc/ndm/netfilter.d/50-mine.sh; chmod +x /opt/etc/ndm/netfilter.d/50-mine.sh
echo my-backup > /opt/etc/opkg.conf.old
# Правило и набор пользователя: обязаны пережить всё.
iptables -t nat -A PREROUTING -p tcp --dport 8022 -j REDIRECT --to-port 22 2>/dev/null
ipset create my_set hash:ip 2>/dev/null
# ---------- ускорители Keenetic: настоящих файлов в ядре контейнера нет
mkdir -p /fake-nf
for v in fastnat:1 fastnat_xfrm:1 fastroute:1 tcp_be_liberal:0 checksum:1; do echo "${v##*:}" > "/fake-nf/nf_conntrack_${v%%:*}"; done
export Z2K_NF_SYSCTL=/fake-nf Z2K_HWNAT_DIR=/nonexistent-hwnat

snap() { # <имя>
    d=/state/snap-$1; mkdir -p "$d"
    find /opt /etc/init.d /var/run /tmp -xdev \( -path /tmp/rig -o -path '/tmp/z2k-job-*' \) -prune -o -print 2>/dev/null \
        | grep -vE '^/opt/etc/lighttpd/mime' | sort > "$d/files"
    find /opt -xdev -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null > "$d/sums"
    iptables-save 2>/dev/null | grep -E '^(-A |:[^ ]+ - )' | sed -E 's/\[[0-9]+:[0-9]+\]//' | sort > "$d/ip4"
    ip6tables-save 2>/dev/null | grep -E '^(-A |:[^ ]+ - )' | sed -E 's/\[[0-9]+:[0-9]+\]//' | sort > "$d/ip6"
    ipset list -n 2>/dev/null | sort > "$d/ipsets"
    ip rule 2>/dev/null > "$d/rules"; ip -o link show 2>/dev/null | awk '{print $2}' > "$d/links"
    sort /state/hosts > "$d/hosts"
    for f in /fake-nf/*; do echo "${f##*/}=$(cat "$f")"; done > "$d/accel"
    ps w 2>/dev/null | grep -E 'nfqws|z2k|zapret|tg-mtproxy|lighttpd' | grep -v -E 'grep|rig.sh' | awk '{$1="";$2="";$3="";print}' | cut -c1-60 | sort > "$d/procs"
    crontab -l 2>/dev/null > "$d/cron"
    sort /state/pkgs > "$d/pkgs"
}
snap before

echo "=== установка"
curl -fsS "$GITHUB_RAW/z2k.sh" -o /tmp/z2k.sh || { echo fetch-failed; exit 8; }
cd /tmp || exit 8
sh /tmp/z2k.sh install > /state/install.log 2>&1 </dev/null; echo "install rc=$?"
grep -nE 'z2k script|сохранить z2k.sh' /state/install.log | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-110
ls -la /opt/zapret2/z2k.sh /opt/bin/z2k 2>&1 | cut -c1-100
LC_ALL=C tail -6 /state/install.log | sed 's/\x1b\[[0-9;]*m//g' | LC_ALL=C cut -c1-120
# Панель: настоящий установщик, она ставится отдельно.
sh /src/webpanel/install.sh > /state/panel.log 2>&1 </dev/null; echo "panel install rc=$?"; tail -2 /state/panel.log | cut -c1-100
wget -q -O /dev/null -T 3 http://127.0.0.1:8088/ 2>/dev/null; ss -ltn 2>/dev/null | grep -c ':8088 ' | sed 's/^/панель слушает 8088: /'
# WARP: настоящие интерфейс, маршрут, правило, наборы и правила iptables, как их ставят
# z2k-warp.sh и движок. Регистрацию у Cloudflare не запускаем.
ip tuntap add dev z2ktun0 mode tun 2>&1 | head -1; ip link set z2ktun0 up 2>/dev/null
ip route replace default dev z2ktun0 table 989 2>/dev/null
ip rule add pref 90 fwmark 0x989/0x989 table 989 2>/dev/null
ipset create z2k_warp hash:net 2>/dev/null; ipset create z2k_warp_src hash:ip 2>/dev/null
iptables -w -t mangle -N Z2K_WARP 2>/dev/null
iptables -w -t mangle -A Z2K_WARP -j MARK --set-xmark 0x989/0x989 2>/dev/null
iptables -w -t mangle -A PREROUTING -m set --match-set z2k_warp dst -j Z2K_WARP 2>/dev/null
iptables -w -t filter -A FORWARD -o z2ktun0 -m mark --mark 0x989/0x989 -j ACCEPT 2>/dev/null
iptables -w -t filter -A FORWARD -i z2ktun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
iptables -w -t nat -A POSTROUTING -o z2ktun0 -j MASQUERADE 2>/dev/null
iptables -w -t mangle -A FORWARD -o z2ktun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
iptables -w -t filter -A OUTPUT -o lo -p udp --sport 53 -j NFLOG --nflog-group 189 2>/dev/null
mkdir -p /opt/etc/z2k-warp /tmp/z2k-warp; echo '{}' > /opt/etc/z2k-warp/device.json; echo key > /opt/etc/z2k-warp/license
echo a > /opt/etc/z2k-warp/account.json; echo c > /opt/etc/z2k-warp/edge-cache.json; echo s > /tmp/z2k-warp/status.json
# Накопленное: копии и бэкапы от обновлений, журналы, подмены бинарников.
mkdir -p /opt/zapret2.old.555 /opt/z2k-upgrade-backup; echo o > /opt/zapret2.old.555/x; echo b > /opt/z2k-upgrade-backup/config
echo n > /opt/sbin/z2k-warpd.new.77; echo r > /opt/sbin/z2k-detect.rb.8; echo a > /opt/sbin/z2k-rt-proxy.z2kbak
# Роботы успевают обжиться, как на настоящем роутере.
sleep 25
snap installed
echo "--- поставлено: файлов +$(($(wc -l < /state/snap-installed/files)-$(wc -l < /state/snap-before/files))), записей DNS +$(($(wc -l < /state/snap-installed/hosts)-$(wc -l < /state/snap-before/hosts))), правил ip4 +$(($(wc -l < /state/snap-installed/ip4)-$(wc -l < /state/snap-before/ip4))), наборов +$(($(wc -l < /state/snap-installed/ipsets)-$(wc -l < /state/snap-before/ipsets)))"
echo "--- процессы:"; sed 's/^/    /' /state/snap-installed/procs | head -12
echo "--- ускорители:"; tr '\n' ' ' < /state/snap-installed/accel; echo
# Накопленное при работе
echo 'log' >> /opt/var/log/z2k-scheduler.log; echo x > /tmp/.z2k-rig-accrued

echo "=== удаление: $UNINSTALL_PATH"
case "$UNINSTALL_PATH" in
  main) env Z2K_UNINSTALL_CONFIRMED=1 sh /opt/zapret2/z2k.sh uninstall > /state/uninstall.log 2>&1 </dev/null; echo "uninstall rc=$?" ;;
  cleanup) sh /src/z2k_cleanup.sh > /state/uninstall.log 2>&1 </dev/null; echo "cleanup rc=$?" ;;
esac
LC_ALL=C tail -5 /state/uninstall.log | sed 's/\x1b\[[0-9;]*m//g' | LC_ALL=C cut -c1-120
sleep 8
snap after

# Ожидаемая разница одна: S80lighttpd выключен, а обычное удаление бережёт ключ WARP.
EXPECTED='/opt/etc/init.d/S80lighttpd$'
[ "$UNINSTALL_PATH" = main ] && EXPECTED="$EXPECTED|/opt/etc/z2k-warp(/device.json|/license)?$"
echo "=== РАЗНИЦА до установки / после удаления"
rc=0
for k in files sums ip4 ip6 ipsets rules links hosts accel procs cron pkgs; do
    diff /state/snap-before/$k /state/snap-after/$k > /state/d.$k 2>&1
    grep -E '^[-+][^-+]' /state/d.$k | grep -vE "$EXPECTED" > /state/u.$k
    if [ -s /state/u.$k ]; then
        echo "--- $k:"; cut -c1-150 /state/u.$k | head -45; rc=1
    else
        echo "ok $k"
    fi
done
grep -q '^ENABLED=no' /opt/etc/init.d/S80lighttpd || { echo "S80lighttpd не выключен"; rc=1; }
[ "$(cat /fake-nf/nf_conntrack_fastnat)" = 1 ] || rc=1
echo "=== записи DNS после удаления:"; sed 's/^/    /' /state/hosts
exit "$rc"
