#!/bin/sh
# tests/test_uninstall_restores_router.sh
#
# Удаление снимает то, что ставит установка, и не делает роутеру хуже.
# Функции исполняем настоящие, из файлов проекта, в подставном окружении. Сам
# uninstall_zapret2 здесь не запускается: в нём прошиты пути /opt/..., и на машине
# разработчика он тронул бы настоящие файлы. Сквозной прогон — tests/e2e_uninstall_docker.sh.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$DIR/lib/install.sh"
WEBPANEL="$DIR/lib/webpanel.sh"
PANEL_UN="$DIR/webpanel/uninstall.sh"
CLEANUP="$DIR/z2k_cleanup.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

extract() { # <файл> <имя блока>
    awk -v n="$2" '
        index($0, "# z2k:shared:" n ":begin") == 1 { on=1; next }
        index($0, "# z2k:shared:" n ":end") == 1   { on=0 }
        on' "$1"
}

# --- Копии общих функций не разъехались ---------------------------------------
same_copies() { # <имя блока> <файл...>
    _name="$1"; shift
    _ref=""
    for _f in "$@"; do
        _b=$(extract "$_f" "$_name")
        if [ -z "$_b" ]; then bad "$_name: нет в ${_f##*/}"; return; fi
        if [ -z "$_ref" ]; then _ref="$_b"
        elif [ "$_b" != "$_ref" ]; then bad "$_name: копия в ${_f##*/} разъехалась"; return; fi
    done
    ok "$_name: копии совпадают"
}
same_copies restore_stock_lighttpd "$INSTALL" "$WEBPANEL" "$PANEL_UN" "$CLEANUP"
same_copies remove_our_ip_hosts "$INSTALL" "$CLEANUP"
same_copies restore_kernel_tuning "$INSTALL" "$CLEANUP"
same_copies warp_routing_sweep "$INSTALL" "$CLEANUP"
same_copies warp_finish "$INSTALL" "$CLEANUP"
same_copies purge_leftovers "$INSTALL" "$CLEANUP"

called() { # <файл> <функция>
    if grep -v '^[[:space:]]*#' "$1" | grep -qE "^[[:space:]]*$2([[:space:]]|\$)"; then
        ok "${1##*/} вызывает $2"
    else
        bad "${1##*/} не вызывает $2"
    fi
}
for _f in "$INSTALL" "$WEBPANEL" "$PANEL_UN" "$CLEANUP"; do called "$_f" _z2k_restore_stock_lighttpd; done
for _fn in _z2k_remove_our_ip_hosts _z2k_restore_kernel_tuning _z2k_warp_routing_sweep _z2k_warp_finish _z2k_purge_leftovers; do
    called "$INSTALL" "$_fn"; called "$CLEANUP" "$_fn"
done
for _fn in _z2k_kill_ours _z2k_sweep_our_rules _z2k_destroy_our_ipsets; do called "$INSTALL" "$_fn"; done

# --- Штатный lighttpd ---------------------------------------------------------
LFN=$(extract "$INSTALL" restore_stock_lighttpd)
lighttpd_case() { # <имя> <строка конфига> <ожидание: off|on> [занято]
    _s="$tmp/l-$1"; mkdir -p "$_s/init.d" "$_s/conf"
    printf '#!/bin/sh\nENABLED=yes\n' > "$_s/init.d/.S80lighttpd.disabled-by-z2k"
    chmod +x "$_s/init.d/.S80lighttpd.disabled-by-z2k"
    printf '%s\n' "$2" > "$_s/conf/lighttpd.conf"
    [ -n "$4" ] && printf 'theirs\n' > "$_s/init.d/S80lighttpd"
    Z2K_INITD_DIR="$_s/init.d" Z2K_LIGHTTPD_CONF_DIR="$_s/conf" sh -c "set -eu
$LFN
_z2k_restore_stock_lighttpd" >/dev/null 2>&1 || { bad "lighttpd/$1: упало"; return; }
    if [ -e "$_s/init.d/.S80lighttpd.disabled-by-z2k" ]; then bad "lighttpd/$1: остался наш файл"; return; fi
    case "$3" in
        off) grep -q '^ENABLED=no' "$_s/init.d/S80lighttpd" && ok "lighttpd/$1: возвращён выключенным" || bad "lighttpd/$1: занял бы порт 80" ;;
        on)  grep -q '^ENABLED=yes' "$_s/init.d/S80lighttpd" && ok "lighttpd/$1: возвращён как был" || bad "lighttpd/$1: выключен зря" ;;
        keep) [ "$(cat "$_s/init.d/S80lighttpd")" = theirs ] && ok "lighttpd/$1: файл с тем же именем не затёрт" || bad "lighttpd/$1: затёрт" ;;
    esac
}
lighttpd_case stock 'server.document-root = "/x"' off
lighttpd_case port80 'server.port = 80' off
lighttpd_case socket80 '$SERVER["socket"] == "0.0.0.0:80" { }' off
lighttpd_case port8081 'server.port = 8081' on
lighttpd_case busy 'server.port = 8081' keep busy

# --- Записи DNS --------------------------------------------------------------
PFN=$(extract "$INSTALL" remove_our_ip_hosts)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ndmc" <<'EOF'
#!/bin/sh
case "$2" in
  "show running-config") cat "$NDMC_RUNNING" ;;
  "system configuration save") ;;
  *) echo "$2" >> "$NDMC_LOG"; [ "$2" = "no ip host g.whatsapp.net 85.192.60.175" ] && exit 3 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/ndmc"
cat > "$tmp/running" <<'EOF'
interface Bridge0
ip host g.whatsapp.net 85.192.60.175
ip host mmg.whatsapp.net 85.192.60.175
ip host old.example 213.176.74.63
ip host raw.githubusercontent.com 185.199.108.133
ip host raw.githubusercontent.com 1.2.3.4
ip host github.com 140.82.121.3
ip host finland1.discord.media 162.159.1.1
ip host example.com 9.9.9.9
EOF
: > "$tmp/ndmc.log"
PATH="$tmp/bin:$PATH" NDMC_RUNNING="$tmp/running" NDMC_LOG="$tmp/ndmc.log" sh -c "set -e
$PFN
_z2k_remove_our_ip_hosts
echo reached > '$tmp/pins.reached'" >/dev/null 2>&1
for _h in 'g.whatsapp.net 85' 'mmg.whatsapp.net 85' 'old.example 213' 'raw.githubusercontent.com 185'; do
    grep -q "^no ip host $_h" "$tmp/ndmc.log" && ok "снято: $_h" || bad "осталось: $_h"
done
if grep -qE 'example\.com|github\.com|finland|raw\.githubusercontent\.com 1\.2' "$tmp/ndmc.log"; then
    bad "снята чужая запись"
else
    ok "чужие записи не тронуты"
fi
[ -f "$tmp/pins.reached" ] && ok "сбой одной записи не обрывает удаление" || bad "сбой одной записи обрывает удаление"
# Записи d2k не наши.
printf 'mmg.whatsapp.net\t85.192.60.175\n' > "$tmp/d2k"
: > "$tmp/ndmc2.log"
PATH="$tmp/bin:$PATH" NDMC_RUNNING="$tmp/running" NDMC_LOG="$tmp/ndmc2.log" Z2K_D2K_PINS="$tmp/d2k" sh -c "$PFN
_z2k_remove_our_ip_hosts" >/dev/null 2>&1
grep -q 'mmg.whatsapp.net' "$tmp/ndmc2.log" && bad "снята запись d2k" || ok "запись d2k не снята"
# Итог не докладывает об успехе при оставшихся записях и непрочитанном конфиге.
if PATH="$tmp/bin:$PATH" NDMC_RUNNING="$tmp/running" NDMC_LOG=/dev/null sh -c "$PFN
_z2k_ip_hosts_clean" >/dev/null 2>&1; then bad "итог молчит об оставшихся записях"; else ok "итог видит оставшиеся записи"; fi
printf '#!/bin/sh\nexit 7\n' > "$tmp/bin/ndmc"
if PATH="$tmp/bin:$PATH" sh -c "$PFN
_z2k_ip_hosts_clean" >/dev/null 2>&1; then bad "непрочитанный конфиг посчитан успехом"; else ok "непрочитанный конфиг не успех"; fi

# --- Ускорители --------------------------------------------------------------
KFN=$(extract "$INSTALL" restore_kernel_tuning)
kernel_case() { # <имя> <есть hw_nat: 0|1> <ожидаемый fastroute>
    _k="$tmp/k-$1"; mkdir -p "$_k/nf" "$_k/bin"
    [ "$2" = 1 ] && mkdir -p "$_k/hw_nat"
    for _v in fastnat fastnat_xfrm fastroute checksum; do echo 0 > "$_k/nf/nf_conntrack_$_v"; done
    echo 1 > "$_k/nf/nf_conntrack_tcp_be_liberal"; echo 0 > "$_k/mode"
    printf '#!/bin/sh\nexit 1\n' > "$_k/bin/pidof"; chmod +x "$_k/bin/pidof"
    PATH="$_k/bin:$PATH" Z2K_NF_SYSCTL="$_k/nf" Z2K_HWNAT_DIR="$_k/hw_nat" Z2K_FASTNAT_MODE="$_k/mode" sh -c "$KFN
_z2k_restore_kernel_tuning" >/dev/null 2>&1
    _got="$(cat "$_k/nf/nf_conntrack_fastnat") $(cat "$_k/nf/nf_conntrack_fastnat_xfrm") $(cat "$_k/mode") $(cat "$_k/nf/nf_conntrack_tcp_be_liberal") $(cat "$_k/nf/nf_conntrack_checksum") $(cat "$_k/nf/nf_conntrack_fastroute")"
    [ "$_got" = "1 1 1 0 1 $3" ] && ok "ускорители/$1: включены" || bad "ускорители/$1: [$_got]"
}
# fastroute=0 оставили версии до p-87.21 на платах без драйвера аппаратного NAT.
kernel_case no-hwnat 0 1
kernel_case hwnat 1 0

# --- WARP: сметание правил ----------------------------------------------------
WFN=$(extract "$INSTALL" warp_routing_sweep)
mkdir -p "$tmp/w"
cat > "$tmp/w/iptables" <<'EOF'
#!/bin/sh
echo "$*" >> "$W_LOG"
case "$*" in
  *"-S PREROUTING"*) echo '-A PREROUTING -m set --match-set z2k_warp dst -j Z2K_WARP'; echo '-A PREROUTING -p tcp -j NOT_OURS' ;;
  *"-t filter -S FORWARD"*) echo '-A FORWARD -o z2ktun0 -j ACCEPT'; echo '-A FORWARD -o eth3 -j ACCEPT' ;;
  *"-t filter -S OUTPUT"*) echo '-A OUTPUT -j NFLOG --nflog-group 189'; echo '-A OUTPUT -j NFLOG --nflog-group 1890' ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "ip $*" >> "$W_LOG"\nexit 0\n' > "$tmp/w/ip"; chmod +x "$tmp/w/iptables" "$tmp/w/ip"
: > "$tmp/w.log"
PATH="$tmp/w:$PATH" W_LOG="$tmp/w.log" sh -c "$WFN
_z2k_warp_routing_sweep" >/dev/null 2>&1
for _w in 'ip rule del fwmark 0x989/0x989 table 989' 'ip route flush table 989' '-D PREROUTING -m set --match-set z2k_warp dst -j Z2K_WARP' \
          '-D FORWARD -o z2ktun0 -j ACCEPT' '-D OUTPUT -j NFLOG --nflog-group 189' '-t mangle -X Z2K_WARP'; do
    grep -qF -- "$_w" "$tmp/w.log" && ok "WARP: $_w" || bad "WARP: нет [$_w]"
done
grep -qE -- '-D .*(NOT_OURS|eth3|group 1890)' "$tmp/w.log" && bad "WARP: снято чужое" || ok "WARP: чужое не тронуто"
# Снимать маршрут надо до остановки движка: S51 stop его не снимает.
_wl=$(grep -n 'z2k-warp.sh remove' "$CLEANUP" | head -1 | cut -d: -f1)
_sl=$(grep -n 'Попытка мягкой остановки' "$CLEANUP" | head -1 | cut -d: -f1)
[ -n "$_wl" ] && [ -n "$_sl" ] && [ "$_wl" -lt "$_sl" ] && ok "зачистка снимает WARP до остановки движка" || bad "зачистка снимает WARP не вовремя"

# --- Правила: чужой движок ----------------------------------------------------
RFN=$(extract "$INSTALL" own_rules)
mkdir -p "$tmp/r"
cat > "$tmp/r/iptables" <<'EOF'
#!/bin/sh
case "$*" in
  *"-t mangle -S POSTROUTING"*) echo '-A POSTROUTING -p tcp -j NFQUEUE --queue-num 200 --queue-bypass'; echo '-A POSTROUTING -p tcp -j NFQUEUE --queue-num 300 --queue-bypass'; echo '-A POSTROUTING -m set --match-set z2k_x dst -j ACCEPT' ;;
  *-D*) echo "$*" >> "$R_LOG" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 1\n' > "$tmp/r/ip6tables"
printf '#!/bin/sh\n[ "$1" = nfqws ] && echo 42\nexit 0\n' > "$tmp/r/pidof"
chmod +x "$tmp/r/iptables" "$tmp/r/ip6tables" "$tmp/r/pidof"
: > "$tmp/r.log"
PATH="$tmp/r:$PATH" R_LOG="$tmp/r.log" ZAPRET2_DIR="$tmp/none" sh -c "$RFN
_z2k_sweep_our_rules" >/dev/null 2>&1
grep -q 'queue-num 200' "$tmp/r.log" && bad "при живом чужом движке снята очередь 200" || ok "при живом чужом движке очередь 200 цела"
grep -q z2k_x "$tmp/r.log" && ok "своё снято при живом чужом движке" || bad "своё не снято"
printf '#!/bin/sh\nexit 1\n' > "$tmp/r/pidof"
: > "$tmp/r.log"
PATH="$tmp/r:$PATH" R_LOG="$tmp/r.log" ZAPRET2_DIR="$tmp/none" sh -c "$RFN
_z2k_sweep_our_rules" >/dev/null 2>&1
grep -q 'queue-num 200' "$tmp/r.log" && ok "наша очередь 200 снята" || bad "наша очередь 200 осталась"
grep -q 'queue-num 300' "$tmp/r.log" && bad "снята чужая очередь 300" || ok "чужая очередь 300 цела"

# Снятие PPE не виснет, если правило видно, а снять его нельзя.
mkdir -p "$tmp/p"
printf '#!/bin/sh\ncase "$*" in *-D*) exit 1 ;; esac\nexit 0\n' > "$tmp/p/iptables"; cp "$tmp/p/iptables" "$tmp/p/ip6tables"; chmod +x "$tmp/p/iptables" "$tmp/p/ip6tables"
PATH="$tmp/p:$PATH" PPE_CONFIG_FILE=/nonexistent sh -c ". '$DIR/files/z2k-ppe-deoffload.sh'; z2k_ppe_remove_rules; echo done > '$tmp/ppe.done'" >/dev/null 2>&1 &
_pid=$!
_i=0; while [ "$_i" -lt 10 ] && kill -0 "$_pid" 2>/dev/null; do sleep 1; _i=$((_i + 1)); done
kill -0 "$_pid" 2>/dev/null && kill -9 "$_pid" 2>/dev/null
[ -f "$tmp/ppe.done" ] && ok "снятие PPE не виснет" || bad "снятие PPE зависло"

# Разовые миграции снимают записи DNS по имени: на чистом роутере их нельзя запускать.
_mig=$(awk '/^install_all|^z2k_full_install|step_update_packages \|\| return 1/{exit} {print}' "$INSTALL" | tail -40)
case "$_mig" in
    *'[ "$Z2K_WAS_INSTALLED" = 1 ] && cleanup_legacy_ip_hosts'*) ok "миграция записей только при обновлении" ;;
    *) bad "миграция записей снимает чужое на чистом роутере" ;;
esac
grep -q 'finland' "$DIR/files/z2k-update-lists.sh" && bad "ночное обновление снимает записи Discord" || ok "ночное обновление не снимает записи"

# --- Два пути: удаление своё, зачистка полная ---------------------------------
_un=$(awk '/^uninstall_zapret2\(\)/,/^}/' "$INSTALL" | sed -e 's/^[[:space:]]*#.*//')
_cl=$(sed -e 's/^[[:space:]]*#.*//' "$CLEANUP")
case "$_un" in *'set +e'*) ok "сбой команды не обрывает удаление" ;; *) bad "удаление идёт под set -e" ;; esac
grep -qE '^set -e' "$CLEANUP" && bad "зачистка идёт под set -e" || ok "сбой команды не обрывает зачистку"
for _bad in '/opt/zapret ' S99nfqws 'S99zapret ' fuser S10cron 'killall -9 tpws' 'netfilter.d/\*zapret' cleanup_legacy_ip_hosts; do
    printf '%s\n' "$_un" | grep -q -- "$_bad" && bad "удаление трогает чужое: $_bad" || ok "удаление не трогает: $_bad"
done
for _must in '/opt/zapret2 /opt/zapret ' S99nfqws 'S99zapret ' 'killall -9 tpws' 'for proc_name in nfqws2 nfqws ' 'chmod +x /opt/etc/init.d/S10cron' '  /opt/etc/z2k-warp '; do
    printf '%s\n' "$_cl" | grep -qF -- "$_must" && ok "зачистка полная: $_must" || bad "зачистка урезана: $_must"
done
for _f in "$INSTALL" "$CLEANUP"; do
    grep -v '^[[:space:]]*#' "$_f" | grep -q 'opkg remove' && bad "${_f##*/} снимает пакеты" || ok "${_f##*/} не снимает пакеты"
done
for _p in '/tmp/nfqws2\*' '/tmp/zapret2\*' '/var/run/nfqws2' '[^2]/ipset/get_config'; do
    printf '%s\n' "$_un" "$_cl" "$(extract "$INSTALL" purge_leftovers)" | grep -v '^[[:space:]]*#' | grep -qE -- "$_p" && bad "широкий шаблон $_p" || ok "нет широкого шаблона $_p"
done
for _s in "$_un" "$_cl"; do
    printf '%s\n' "$_s" | grep -qE 'crontab -l[^|]*\|[^|]*grep -v' && bad "cron пишется конвейером" || ok "cron читается отдельно от записи"
done

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ]
