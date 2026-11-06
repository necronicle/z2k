#!/bin/sh
# tests/test_uninstall_restores_router.sh
#
# Удаление обязано вернуть роутер в прежнее состояние и не сделать ему хуже.
#
# ЧТО СТОРОЖИМ И ПОЧЕМУ ИМЕННО ЭТО:
#   1. Штатный lighttpd на 80-м порту не возвращается: при следующей загрузке он
#      занял бы 0.0.0.0:80 и уронил nginx прошивки, то есть веб-интерфейс роутера.
#   2. Записи ip host, указывающие на наш узел, снимаются любым путём удаления и
#      при любом имени: они сохранены в конфиге и переживают перезагрузку.
#   3. Сетевые параметры возвращаются, даже если S99 уже нет или он не отработал.
#   4. Сбой одной команды не обрывает удаление на середине: половина служб снята,
#      половина осталась и поднимется при загрузке.
#
# Функции исполняем настоящие, из файлов проекта, в подставном окружении. Сам
# uninstall_zapret2 здесь НЕ запускается: в нём прошиты пути /opt/..., и на машине
# разработчика он тронул бы настоящие файлы. Сквозной прогон всего удаления —
# tests/e2e_uninstall_docker.sh, он живёт в одноразовом контейнере.

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

# Функцию берём по пометкам, чтобы в файлах это был обычный код.
extract() { # <файл> <имя функции>
    awk -v n="$2" '
        index($0, "# z2k:shared:" n ":begin") == 1 { on=1; next }
        index($0, "# z2k:shared:" n ":end") == 1   { on=0 }
        on' "$1"
}

# --- 1. Копии общих функций не разъехались ---------------------------------
# Аварийный скрипт и удаление панели запускаются сами по себе и подключить общий
# файл не могут, поэтому функция лежит в нескольких местах. Расхождение копий —
# ровно тот класс ошибок, из-за которого пути удаления вели себя по-разному.
same_copies() { # <имя функции> <файл...>
    _name="$1"; shift
    _ref=""
    for _f in "$@"; do
        _b=$(extract "$_f" "$_name")
        if [ -z "$_b" ]; then bad "$_name: нет функции в ${_f##*/}"; return; fi
        if [ -z "$_ref" ]; then _ref="$_b"
        elif [ "$_b" != "$_ref" ]; then bad "$_name: копия в ${_f##*/} разъехалась"; return; fi
    done
    ok "$_name: копии совпадают ($# шт.)"
}
same_copies restore_stock_lighttpd "$INSTALL" "$WEBPANEL" "$PANEL_UN" "$CLEANUP"
same_copies remove_our_ip_hosts "$INSTALL" "$CLEANUP"
same_copies restore_kernel_tuning "$INSTALL" "$CLEANUP"
same_copies warp_routing_sweep "$INSTALL" "$CLEANUP"
same_copies own_processes "$INSTALL" "$CLEANUP"
same_copies own_rules "$INSTALL" "$CLEANUP"
same_copies warp_finish "$INSTALL" "$CLEANUP"
same_copies purge_leftovers "$INSTALL" "$CLEANUP"

# Функция, которую никто не вызывает, защищает только тест.
called() { # <файл> <функция>
    if grep -v '^[[:space:]]*#' "$1" | grep -qE "^[[:space:]]*$2([[:space:]]|\$)"; then
        ok "${1##*/} вызывает $2"
    else
        bad "${1##*/} не вызывает $2"
    fi
}
for _f in "$INSTALL" "$WEBPANEL" "$PANEL_UN" "$CLEANUP"; do
    called "$_f" _z2k_restore_stock_lighttpd
done
for _f in "$INSTALL" "$CLEANUP"; do
    called "$_f" _z2k_remove_our_ip_hosts
    called "$_f" _z2k_restore_kernel_tuning
    called "$_f" _z2k_warp_routing_sweep
    called "$_f" _z2k_kill_ours
    called "$_f" _z2k_sweep_our_rules
    called "$_f" _z2k_destroy_our_ipsets
    called "$_f" _z2k_warp_finish
    called "$_f" _z2k_purge_leftovers
    called "$_f" _z2k_remove_our_packages
done

# --- 2. Штатный lighttpd ----------------------------------------------------
LFN=$(extract "$INSTALL" restore_stock_lighttpd)
lighttpd_case() { # <имя> <server.port или пусто> <ожидание: back|kept> [занято]
    _s="$tmp/l-$1"
    mkdir -p "$_s/init.d" "$_s/conf"
    printf '#!/bin/sh\n' > "$_s/init.d/.S80lighttpd.disabled-by-z2k"
    if [ -n "$2" ]; then
        printf 'server.port = %s\n' "$2" > "$_s/conf/lighttpd.conf"
    else
        printf 'server.document-root = "/opt/share/www"\n' > "$_s/conf/lighttpd.conf"
    fi
    [ -n "$4" ] && printf 'theirs\n' > "$_s/init.d/S80lighttpd"
    _out=$(Z2K_INITD_DIR="$_s/init.d" Z2K_LIGHTTPD_CONF_DIR="$_s/conf" \
        sh -c "$LFN
_z2k_restore_stock_lighttpd" 2>&1)
    _rc=$?
    if [ "$_rc" != 0 ]; then bad "lighttpd/$1: код $_rc: $_out"; return; fi
    case "$3" in
        back)
            if [ -f "$_s/init.d/S80lighttpd" ] && [ ! -e "$_s/init.d/.S80lighttpd.disabled-by-z2k" ]; then
                ok "lighttpd/$1: возвращён"
            else bad "lighttpd/$1: должен был вернуться: $_out"; fi ;;
        kept)
            if [ ! -e "$_s/init.d/S80lighttpd" ] && [ -e "$_s/init.d/.S80lighttpd.disabled-by-z2k" ]; then
                case "$_out" in
                    *S80lighttpd*80*) ok "lighttpd/$1: не возвращён, и сказано почему" ;;
                    *) bad "lighttpd/$1: молчит, человек не поймёт: [$_out]" ;;
                esac
            else bad "lighttpd/$1: занял бы порт 80 и уронил вебморду"; fi ;;
        theirs)
            if [ "$(cat "$_s/init.d/S80lighttpd")" = theirs ] && [ -e "$_s/init.d/.S80lighttpd.disabled-by-z2k" ]; then
                ok "lighttpd/$1: чужой файл не затёрт"
            else bad "lighttpd/$1: затёр чужой файл"; fi ;;
    esac
}
lighttpd_case stock-no-port "" kept      # стоковый конфиг: нет server.port, значит 80
lighttpd_case port-80 80 kept
lighttpd_case port-8081 8081 back        # свой lighttpd человека возвращаем, как и раньше
lighttpd_case name-busy 8081 theirs busy
# На 80-м это наш пакет: снимаем целиком, не оставляя выключенный файл и конфиг.
_s="$tmp/l-pkg"; mkdir -p "$_s/init.d" "$_s/conf" "$_s/bin"
printf '#!/bin/sh\n' > "$_s/init.d/.S80lighttpd.disabled-by-z2k"
printf 'server.document-root = "/x"\n' > "$_s/conf/lighttpd.conf"
cat > "$_s/bin/opkg" <<EOF
#!/bin/sh
case "\$1" in
  list-installed) [ -f "$_s/removed" ] || { echo 'lighttpd - 1'; echo 'lighttpd-mod-cgi - 1'; }; echo 'dropbear - 1' ;;
  remove) echo "\$*" > "$_s/removed" ;;
esac
EOF
chmod +x "$_s/bin/opkg"
PATH="$_s/bin:$PATH" Z2K_INITD_DIR="$_s/init.d" Z2K_LIGHTTPD_CONF_DIR="$_s/conf" sh -c "$LFN
_z2k_restore_stock_lighttpd" >/dev/null 2>&1
if [ "$(cat "$_s/removed" 2>/dev/null)" = "remove lighttpd-mod-cgi lighttpd" ] \
   && [ ! -e "$_s/init.d/.S80lighttpd.disabled-by-z2k" ] && [ ! -e "$_s/init.d/S80lighttpd" ] && [ ! -d "$_s/conf" ]; then
    ok "lighttpd на 80-м: пакет, выключенный файл и конфиг сняты, чужой пакет цел"
else
    bad "lighttpd на 80-м: остался мусор: [$(cat "$_s/removed" 2>/dev/null)]"
fi
# Дополнительный сокет занимает 80-й при любом server.port.
_s="$tmp/l-socket"; mkdir -p "$_s/init.d" "$_s/conf"
printf '#!/bin/sh\n' > "$_s/init.d/.S80lighttpd.disabled-by-z2k"
printf 'server.port = 8081\n$SERVER["socket"] == "0.0.0.0:80" { }\n' > "$_s/conf/lighttpd.conf"
Z2K_INITD_DIR="$_s/init.d" Z2K_LIGHTTPD_CONF_DIR="$_s/conf" sh -c "$LFN
_z2k_restore_stock_lighttpd" >/dev/null 2>&1
if [ ! -e "$_s/init.d/S80lighttpd" ]; then
    ok "lighttpd/socket-80: не возвращён"
else
    bad "lighttpd/socket-80: занял бы порт 80 через socket-блок"
fi

# --- 3. Записи ip host ------------------------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ndmc" <<'EOF'
#!/bin/sh
case "$2" in
  "show running-config") cat "$NDMC_RUNNING" ;;
  "system configuration save") ;;
  *) echo "$2" >> "$NDMC_LOG"
     # Сбой на одной записи не должен мешать снять остальные.
     [ "$2" = "no ip host g.whatsapp.net 85.192.60.175" ] && exit 3 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/ndmc"
cat > "$tmp/running" <<'EOF'
interface Bridge0
ip host whatsapp.com 85.192.60.175
ip host g.whatsapp.net 85.192.60.175
ip host mmg.whatsapp.net 85.192.60.175
ip host crashlogs.whatsapp.net 213.176.74.63
ip host static.whatsapp.net 79.137.196.7
ip host some.future.relay.example 85.192.60.175
ip host finland10001.discord.media 162.159.1.1
ip host raw.githubusercontent.com 185.199.108.133
ip host cdn.jsdelivr.net 1.1.1.1
ip host example.com 9.9.9.9
ip host not-finland1.discord.media 9.9.9.9
ip host finland.example.com 9.9.9.9
ip host my.whatsapp.net.example.com 9.9.9.9
EOF
PFN=$(extract "$INSTALL" remove_our_ip_hosts)
: > "$tmp/ndmc.log"
PATH="$tmp/bin:$PATH" NDMC_RUNNING="$tmp/running" NDMC_LOG="$tmp/ndmc.log" \
    sh -c "set -e
$PFN
_z2k_remove_our_ip_hosts
echo reached > '$tmp/pins.reached'" >/dev/null 2>&1
for _want in whatsapp.com g.whatsapp.net mmg.whatsapp.net crashlogs.whatsapp.net \
             static.whatsapp.net some.future.relay.example \
             finland10001.discord.media raw.githubusercontent.com cdn.jsdelivr.net; do
    if grep -q "^no ip host $_want " "$tmp/ndmc.log"; then
        ok "снято: $_want"
    else
        bad "осталось висеть: $_want"
    fi
done
# Записи d2k не наши, даже на нашем адресе.
_dm="$tmp/d2k-pins"; printf 'mmg.whatsapp.net\t85.192.60.175\n' > "$_dm"
_left=$(PATH="$tmp/bin:$PATH" NDMC_RUNNING="$tmp/running" NDMC_LOG="$tmp/ndmc-d2k.log" Z2K_D2K_PINS="$_dm" sh -c "$PFN
_z2k_remove_our_ip_hosts" 2>&1; grep -c '^no ip host mmg.whatsapp.net ' "$tmp/ndmc-d2k.log")
case "$_left" in
    *0) ok "запись d2k не снята" ;;
    *)  bad "снята запись d2k" ;;
esac
if grep -qE 'example\.com|not-finland' "$tmp/ndmc.log"; then
    bad "снята чужая запись: $(grep -E 'example\.com|not-finland' "$tmp/ndmc.log" | head -1)"
else
    ok "чужие записи не тронуты"
fi
if [ -f "$tmp/pins.reached" ]; then
    ok "сбой одной записи не роняет удаление под set -e"
else
    bad "сбой ndmc на одной записи обрывает удаление под set -e"
fi
# Итоговая проверка не должна докладывать об успехе при оставшихся записях.
_clean() { PATH="$tmp/bin:$PATH" NDMC_RUNNING="$1" NDMC_LOG="$tmp/ndmc.log" sh -c "$PFN
_z2k_ip_hosts_clean" >/dev/null 2>&1; }
if _clean "$tmp/running"; then bad "итог: остались наши записи, а проверка молчит"; else ok "итог: оставшиеся записи замечены"; fi
printf 'ip host example.com 9.9.9.9\n' > "$tmp/running.clean"
if _clean "$tmp/running.clean"; then ok "итог: чужие записи успеху не мешают"; else bad "итог: чужая запись посчитана нашей"; fi
# ndmc не отвечает вовсе.
cat > "$tmp/bin/ndmc" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$tmp/bin/ndmc"
PATH="$tmp/bin:$PATH" sh -c "set -e
$PFN
_z2k_remove_our_ip_hosts
echo reached > '$tmp/pins2.reached'" >/dev/null 2>&1
if [ -f "$tmp/pins2.reached" ]; then
    ok "неответ ndmc не роняет удаление под set -e"
else
    bad "неответ ndmc обрывает удаление под set -e"
fi
if PATH="$tmp/bin:$PATH" sh -c "$PFN
_z2k_ip_hosts_clean" >/dev/null 2>&1; then
    bad "итог: конфиг не прочитан, а проверка докладывает об успехе"
else
    ok "итог: непрочитанный конфиг не считается успехом"
fi

# --- 4. Сетевые параметры ---------------------------------------------------
KFN=$(extract "$INSTALL" restore_kernel_tuning)
kernel_case() { # <имя> <есть hw_nat: 0|1> <значение тумблера> <ожидаемый fastroute>
    _k="$tmp/k-$1"
    mkdir -p "$_k/nf" "$_k/sys"
    [ "$2" = 1 ] && mkdir -p "$_k/hw_nat"
    echo 0 > "$_k/nf/nf_conntrack_fastnat"
    echo 0 > "$_k/nf/nf_conntrack_fastnat_xfrm"
    echo 0 > "$_k/nf/nf_conntrack_fastroute"
    echo 1 > "$_k/nf/nf_conntrack_tcp_be_liberal"
    echo 0 > "$_k/nf/nf_conntrack_checksum"
    echo 0 > "$_k/sys/mode"
    echo 2 > "$_k/mode.orig"
    Z2K_NF_SYSCTL="$_k/nf" Z2K_HWNAT_DIR="$_k/hw_nat" \
    Z2K_FASTNAT_MODE="$_k/sys/mode" Z2K_FASTNAT_ORIG="$_k/mode.orig" \
        sh -c "$KFN
_z2k_restore_kernel_tuning '$3'" >/dev/null 2>&1
    _got="$(cat "$_k/nf/nf_conntrack_fastnat") $(cat "$_k/nf/nf_conntrack_fastnat_xfrm") $(cat "$_k/nf/nf_conntrack_tcp_be_liberal") $(cat "$_k/nf/nf_conntrack_checksum") $(cat "$_k/nf/nf_conntrack_fastroute")"
    if [ "$_got" = "1 1 0 1 $4" ]; then
        ok "параметры/$1: возвращены"
    else
        bad "параметры/$1: получили [$_got], ждали [1 1 0 1 $4]"
    fi
    if [ "$(cat "$_k/sys/mode")" = 2 ] && [ ! -e "$_k/mode.orig" ]; then
        ok "параметры/$1: режим fastnat возвращён из сохранённого"
    else
        bad "параметры/$1: режим fastnat не возвращён"
    fi
}
kernel_case no-hwnat 0 1 1      # без железа мы гасили fastroute — возвращаем
kernel_case hwnat 1 1 0         # с железом мы его не трогали — не наше дело
kernel_case toggle-off 0 0 0    # тумблер запретил трогать — не трогали и не возвращаем

# Запись не удалась — сохранённое значение бережём для повторной попытки.
_k="$tmp/k-rofail"; mkdir -p "$_k/nf"; echo 2 > "$_k/mode.orig"
Z2K_NF_SYSCTL="$_k/nf" Z2K_HWNAT_DIR="$_k/hw" Z2K_FASTNAT_MODE="$_k/no-such-dir/mode" \
Z2K_FASTNAT_ORIG="$_k/mode.orig" sh -c "$KFN
_z2k_restore_kernel_tuning 1" >/dev/null 2>&1
if [ -e "$_k/mode.orig" ]; then
    ok "при неудачной записи сохранённый режим fastnat не теряется"
else
    bad "сохранённый режим fastnat потерян при неудачной записи"
fi

# Сохранённого значения нет — ничего не выдумываем.
_k="$tmp/k-noorig"; mkdir -p "$_k/nf" "$_k/sys"; echo 0 > "$_k/sys/mode"
Z2K_NF_SYSCTL="$_k/nf" Z2K_HWNAT_DIR="$_k/hw" Z2K_FASTNAT_MODE="$_k/sys/mode" \
Z2K_FASTNAT_ORIG="$_k/none" sh -c "$KFN
_z2k_restore_kernel_tuning 1" >/dev/null 2>&1
if [ "$(cat "$_k/sys/mode")" = 0 ]; then
    ok "без сохранённого значения режим fastnat не выдумывается"
else
    bad "записали режим fastnat, которого никто не сохранял"
fi

# Установщик обязан сохранить значение до того, как его сменит.
_st=$(awk '/^step_disable_hwnat_and_offload\(\)/,/^}/' "$INSTALL")
_save=$(printf '%s\n' "$_st" | grep -n 'fastnat-mode.orig' | head -1 | cut -d: -f1)
_write=$(printf '%s\n' "$_st" | grep -n 'echo 0 > /sys/kernel/fastnat/mode' | head -1 | cut -d: -f1)
if [ -n "$_save" ] && [ -n "$_write" ] && [ "$_save" -lt "$_write" ]; then
    ok "установщик сохраняет режим fastnat до изменения"
else
    bad "установщик меняет режим fastnat, не сохранив прежний"
fi

# --- 4а. Маршрутизация WARP ---------------------------------------------------
WFN=$(extract "$INSTALL" warp_routing_sweep)
mkdir -p "$tmp/w"
cat > "$tmp/w/iptables" <<'EOF'
#!/bin/sh
echo "$*" >> "$W_LOG"
case "$*" in
  *"-S PREROUTING"*)
    echo '-A PREROUTING -m set --match-set z2k_warp dst -j Z2K_WARP'
    echo '-A PREROUTING -p tcp -j NOT_OURS' ;;
  *"-t filter -S FORWARD"*)
    echo '-A FORWARD -o z2ktun0 -m mark --mark 0x989/0x989 -j ACCEPT'
    echo '-A FORWARD -o eth3 -j ACCEPT' ;;
  *"-t filter -S OUTPUT"*)
    echo '-A OUTPUT -o ppp0 -p udp --sport 53 -j NFLOG --nflog-group 189'
    echo '-A OUTPUT -j NFLOG --nflog-group 1890' ;;
  *"-t nat -S POSTROUTING"*)
    echo '-A POSTROUTING -o z2ktun0 -j MASQUERADE' ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "ip $*" >> "$W_LOG"\nexit 0\n' > "$tmp/w/ip"
chmod +x "$tmp/w/iptables" "$tmp/w/ip"
: > "$tmp/w.log"
PATH="$tmp/w:$PATH" W_LOG="$tmp/w.log" sh -c "set -e
$WFN
_z2k_warp_routing_sweep
echo reached > '$tmp/w.reached'" >/dev/null 2>&1
for _want in 'ip rule del fwmark 0x989/0x989 table 989' 'ip route flush table 989' \
             '-t mangle -D PREROUTING -m set --match-set z2k_warp dst -j Z2K_WARP' \
             '-t mangle -X Z2K_WARP' \
             '-t filter -D FORWARD -o z2ktun0 -m mark --mark 0x989/0x989 -j ACCEPT' \
             '-t filter -D OUTPUT -o ppp0 -p udp --sport 53 -j NFLOG --nflog-group 189' \
             '-t nat -D POSTROUTING -o z2ktun0 -j MASQUERADE'; do
    if grep -qF -- "$_want" "$tmp/w.log"; then ok "WARP: $_want"; else bad "WARP: нет [$_want]"; fi
done
if grep -qE -- '-D .*(NOT_OURS|eth3|group 1890)' "$tmp/w.log"; then bad "WARP: снято чужое правило"; else ok "WARP: чужое правило не тронуто"; fi
if [ -f "$tmp/w.reached" ]; then ok "WARP: не роняет удаление под set -e"; else bad "WARP: роняет удаление под set -e"; fi
# Снимать маршрут надо ДО остановки движка, а S51 stop его не снимает.
_wl=$(grep -n 'z2k-warp.sh remove' "$CLEANUP" | head -1 | cut -d: -f1)
_sl=$(grep -n 'Попытка мягкой остановки' "$CLEANUP" | head -1 | cut -d: -f1)
if [ -n "$_wl" ] && [ -n "$_sl" ] && [ "$_wl" -lt "$_sl" ]; then
    ok "зачистка снимает маршрутизацию WARP до остановки движка"
else
    bad "зачистка не зовёт z2k-warp.sh remove до остановки служб"
fi

# --- 5. Удаление не обрывается на середине ----------------------------------
_un=$(awk '/^uninstall_zapret2\(\)/,/^}/' "$INSTALL")
case "$_un" in
    *'set +e'*'[ "$_z2k_errexit" = 1 ] && set -e'*) ok "основное удаление снимает set -e и возвращает режим вызывающего" ;;
    *) bad "основное удаление идёт под set -e: первый сбой оставит его на середине" ;;
esac
if grep -qE '^set -e' "$CLEANUP"; then
    bad "аварийная зачистка идёт под set -e: обрывается ровно там, где нужна"
else
    ok "аварийная зачистка не обрывается на первом сбое"
fi
# Подметание правил должно идти раньше удаления ipset: занятый набор не удалить.
_sweep=$(printf '%s\n' "$_un" | grep -n '^ *_z2k_sweep_our_rules' | cut -d: -f1)
_destroy=$(printf '%s\n' "$_un" | grep -n '^ *_z2k_destroy_our_ipsets' | cut -d: -f1)
if [ -n "$_sweep" ] && [ -n "$_destroy" ] && [ "$_sweep" -lt "$_destroy" ]; then
    ok "правила снимаются раньше ipset"
else
    bad "ipset удаляется раньше правил, которые на него ссылаются"
fi

# --- 6. Остатки -------------------------------------------------------------
_purge=$(extract "$INSTALL" purge_leftovers)
for _p in /opt/sbin/z2k-usque '/opt/sbin/*.z2kbak' '/opt/var/log/z2k-*' '/opt/etc/.z2k-*' \
          '/opt/zapret2.old.*' /opt/z2k-upgrade-backup /opt/z2k-rollback /opt/z2k-work \
          /opt/etc/z2k /opt/etc/opkg.conf.backup /opt/etc/opkg.conf.z2k-bak; do
    case "$_purge" in
        *"$_p"*) ok "уборка убирает $_p" ;;
        *) bad "уборка оставляет $_p" ;;
    esac
done

# Снятие PPE не должно виснуть, если правило видно, а снять его нельзя.
_ppe="$tmp/ppe"; mkdir -p "$_ppe"
printf '#!/bin/sh\ncase "$*" in *-D*) exit 1 ;; esac\nexit 0\n' > "$_ppe/iptables"; cp "$_ppe/iptables" "$_ppe/ip6tables"; chmod +x "$_ppe/iptables" "$_ppe/ip6tables"
PATH="$_ppe:$PATH" PPE_CONFIG_FILE=/nonexistent sh -c ". '$DIR/files/z2k-ppe-deoffload.sh'; z2k_ppe_remove_rules; echo done > '$tmp/ppe.done'" >/dev/null 2>&1 &
_pid=$!
_i=0; while [ "$_i" -lt 10 ] && kill -0 "$_pid" 2>/dev/null; do sleep 1; _i=$((_i + 1)); done
if kill -0 "$_pid" 2>/dev/null; then kill -9 "$_pid" 2>/dev/null; fi
if [ -f "$tmp/ppe.done" ]; then ok "снятие PPE не виснет при неудачном -D"; else bad "снятие PPE зависло при неудачном -D"; fi
# Удаление панели не должно обрываться, если процесс ушёл между pgrep и kill.
_km=$(awk '/^_kill_matching\(\)/,/^}/' "$PANEL_UN")
case "$_km" in
    *'|| true'*'return 0'*) ok "удаление панели переживает ушедший процесс" ;;
    *) bad "удаление панели обрывается на kill под set -e" ;;
esac
# Обычный файл /opt/bin/z2k чужой: снимаем только ссылку.
case "$(extract "$INSTALL" purge_leftovers)" in
    *'[ -L /opt/bin/z2k ] && rm -f /opt/bin/z2k'*) ok "обычный файл /opt/bin/z2k не трогаем" ;;
    *) bad "обычный файл /opt/bin/z2k удаляется" ;;
esac

# --- 6а. Чужое не трогаем ---------------------------------------------------
# Проверка «есть ли чужой /opt/zapret» не трогает его, а как раз бережёт.
_cl=$(sed -e 's/^[[:space:]]*#.*//' -e '/\[ -d \/opt\/zapret \]/d' "$CLEANUP")
_ui=$(printf '%s\n' "$_un" | sed -e 's/^[[:space:]]*#.*//')
for _bad in '/opt/zapret ' '/opt/zapret$' S99nfqws 'S99zapret ' 'fuser' '/tmp/blockcheck' 'S10cron' \
            'killall -9 tpws' 'netfilter.d/\*zapret' 'chmod +x'; do
    if printf '%s\n' "$_ui" | grep -q -- "$_bad"; then bad "основное удаление трогает чужое: $_bad"; else ok "основное удаление не трогает: $_bad"; fi
    if printf '%s\n' "$_cl" | grep -q -- "$_bad"; then bad "зачистка трогает чужое: $_bad"; else ok "зачистка не трогает: $_bad"; fi
done
# Запись поставленных пакетов не должна мешать установке и задваивать строки.
_pk="$tmp/pk/installed"
Z2K_INSTALLED_PKGS="$_pk" sh -c "$(awk '/^z2k_pkg_record\(\)/,/^}/' "$DIR/lib/utils.sh")
set -e
z2k_pkg_record ipset iptables
z2k_pkg_record ipset"
if [ "$(tr '\n' ' ' < "$_pk" 2>/dev/null)" = "ipset iptables " ]; then
    ok "поставленные пакеты записываются без повторов"
else
    bad "список поставленных пакетов неверный: [$(cat "$_pk" 2>/dev/null)]"
fi
_rm=$(extract "$INSTALL" purge_leftovers)
mkdir -p "$tmp/opk"; printf '#!/bin/sh\necho "$*" >> "%s"\n[ "$3" = busy ] && exit 1\nexit 0\n' "$tmp/opk.log" > "$tmp/opk/opkg"; chmod +x "$tmp/opk/opkg"
printf 'iptables\ncurl\nbusy\n../evil\nipset\n' > "$tmp/pkgs"
PATH="$tmp/opk:$PATH" Z2K_INSTALLED_PKGS="$tmp/pkgs" sh -c "set -e
$_rm
_z2k_remove_our_packages
echo reached > '$tmp/pk.reached'" >/dev/null 2>&1
if [ "$(tr '\n' ';' < "$tmp/opk.log" 2>/dev/null)" = "remove --autoremove ipset;remove --autoremove busy;remove --autoremove iptables;" ] && [ -f "$tmp/pk.reached" ]; then
    ok "снимаются только записанные пакеты, в обратном порядке, кроме curl и мусора"
else
    bad "снятие пакетов: [$(tr '\n' ';' < "$tmp/opk.log" 2>/dev/null)]"
fi
for _p in /opt/z2k-rollback /opt/z2k-upgrade-backup /opt/etc/zapret2 '/opt/zapret2.old.'; do
    if grep -qF "$_p" "$CLEANUP"; then
        ok "зачистка убирает $_p"
    else
        bad "зачистка оставляет $_p"
    fi
done
# Правило PPE, которое сейчас ставит установщик, зачистка обязана узнавать.
_ports=$(sed -n 's/^PPE_PORTS="\${PPE_PORTS:-\([^}]*\)}"$/\1/p' "$DIR/files/z2k-ppe-deoffload.sh")
if [ -n "$_ports" ] && grep -qF -- "--dports $_ports " "$CLEANUP"; then
    ok "зачистка снимает текущее правило PPE"
else
    bad "зачистка не узнаёт текущее правило PPE (порты $_ports): оно останется висеть"
fi
if grep -qF -- '-p udp --dport 443 -m connskip --connskip 30 -j PPE' "$CLEANUP"; then
    ok "зачистка снимает и правило PPE для QUIC"
else
    bad "зачистка не снимает правило PPE для QUIC"
fi
if grep -qF 'z2k-scheduler' "$CLEANUP" && grep -qE "kill -9.*_spids|z2k-scheduler\\\\.sh" "$CLEANUP"; then
    ok "зачистка гасит оставшийся планировщик по процессу"
else
    bad "зачистка оставляет планировщик: он вернёт настройки обратно"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ]
