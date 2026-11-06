#!/bin/sh
# z2k_cleanup.sh — полная зачистка z2k
# Для экстренных случаев: зависшие процессы, остатки после удаления и т.д.
#
# Удаляет ВСЁ наше и не трогает чужое: чужой zapret в /opt/zapret, его службы, nfqws и
# очереди NFQUEUE остаются на месте. После зачистки остаётся только ключ WARP
# /opt/etc/z2k-warp/device.json, чтобы не регистрировать устройство заново.
#
# Использование:
#   sh -c 'tmp=/tmp/z2k_cleanup.sh; rm -f "$tmp"; for url in "https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh" "https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/z2k_cleanup.sh" "https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh"; do echo "[i] Пробую: $url" >&2; if curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$tmp"; then exec sh "$tmp"; fi; done; echo "[FAIL] Не удалось скачать z2k_cleanup.sh ни с одного зеркала" >&2; exit 1'
#   или
#   sh z2k_cleanup.sh

# БЕЗ set -e, ОСОЗНАННО. Скрипт запускают, когда уже что-то сломано, и именно тогда
# команды отказывают: ndmc не отвечает, интерфейс занят. Под set -e первый такой
# отказ обрывал зачистку на середине, и она оставляла больше, чем было до неё.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { printf "${GREEN}[+]${NC} %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[X]${NC} %s\n" "$1"; }
log_skip()  { printf "    %s\n" "$1"; }

# z2k:shared:restore_stock_lighttpd:begin
# Вернуть штатный lighttpd, если его выключала установка панели.
#
# НА 80-Й ПОРТ НЕ ВОЗВРАЩАЕМ. Панель ставит пакет lighttpd, а он приносит свой
# автозапуск со стоковым конфигом: server.port там нет, значит 0.0.0.0:80. Этот
# порт принадлежит nginx прошивки. Возврат такого файла при следующей загрузке
# роняет веб-интерфейс роутера (журнал с поля 01.09.2026: «bind() to
# 192.168.1.1:80 failed», «Service: "Nginx": unexpectedly stopped»). Правило то же,
# что в _stock_init_verdict при установке. Такой lighttpd поставили мы ради панели,
# поэтому он уходит вместе с пакетом. Если opkg не справился, файл остаётся выключенным
# и напечатана команда для возврата.
#
# Этот блок одинаков во всех путях удаления, сверяет tests/test_uninstall_restores_router.sh.
_z2k_restore_stock_lighttpd() {
    local _idir _cdir _dis _base _f _p _sport _pkgs
    _idir="${Z2K_INITD_DIR:-/opt/etc/init.d}"
    _cdir="${Z2K_LIGHTTPD_CONF_DIR:-/opt/etc/lighttpd}"
    for _dis in "$_idir"/.S*lighttpd.disabled-by-z2k; do
        [ -e "$_dis" ] || continue
        _base="${_dis##*/}"; _base="${_base#.}"; _base="${_base%.disabled-by-z2k}"
        _sport=""
        for _f in "$_cdir/lighttpd.conf" "$_cdir"/conf.d/*.conf; do
            [ -f "$_f" ] || continue
            # Дополнительный сокет на 80-м занимает порт при любом server.port.
            if grep -Eq '^[[:space:]]*\$SERVER\["socket"\][^#]*:80"' "$_f"; then _sport=80; break; fi
            _p=$(sed -n 's/^[[:space:]]*server\.port[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_f" | head -1)
            if [ -n "$_p" ] && [ -z "$_sport" ]; then _sport="$_p"; fi
        done
        [ -n "$_sport" ] || _sport=80
        if [ "$_sport" = "80" ]; then
            # Такой lighttpd работать не мог, его принёс пакет ради панели. Снимаем
            # пакет целиком, иначе выключенный файл и пакет остаются мусором.
            _pkgs=""
            if command -v opkg >/dev/null 2>&1; then
                _pkgs=$(opkg list-installed 2>/dev/null | awk '$1 ~ /^lighttpd(-mod-.*)?$/ {print $1}' | sort -r)
                # shellcheck disable=SC2086  # список пакетов: разбиение намеренно
                [ -z "$_pkgs" ] || opkg remove $_pkgs </dev/null >/dev/null 2>&1
                _pkgs=$(opkg list-installed 2>/dev/null | awk '$1 == "lighttpd" {print $1}')
            fi
            if [ -z "$_pkgs" ] && command -v opkg >/dev/null 2>&1; then
                rm -f "$_dis"
                rm -rf "$_cdir" /opt/var/log/lighttpd 2>/dev/null
                echo "[i] Удалён пакет lighttpd, поставленный для панели"
            else
                echo "[!] Штатный $_base не возвращён: порт 80 занят веб-интерфейсом роутера."
                echo "    Если он нужен, смените server.port и выполните: mv '$_dis' '$_idir/$_base'"
            fi
        elif [ -e "$_idir/$_base" ]; then
            echo "[!] Не возвращаю $_base: файл с таким именем уже есть"
        elif mv "$_dis" "$_idir/$_base" 2>/dev/null; then
            echo "[i] Возвращён штатный init: $_base"
        else
            echo "[!] Не удалось вернуть $_dis: перенесите вручную"
        fi
    done
    return 0
}
# z2k:shared:restore_stock_lighttpd:end

# z2k:shared:remove_our_ip_hosts:begin
# Снять записи ip host, которые писали мы. Они в конфиге роутера и переживают
# перезагрузку: снёс z2k, а WhatsApp продолжает ходить через наш узел.
#
# Узел снимаем ПО АДРЕСУ, а не по списку имён: всё, что указывает на него, поставили
# мы, а список имён отстаёт от жизни. Discord и GitHub по адресу не определить, их
# снимаем по закрытому списку имён: Discord-пины сняты с поставки, а записи на GitHub
# писал снятый слой скачивания. Чужих записей тут быть не должно.
# Записи, которые ведёт d2k, не наши: он хранит их точным списком.
_z2k_not_d2k_pins() {
    local _m="${Z2K_D2K_PINS:-/opt/d2k/state/instagram-ip-hosts.tsv}"
    if [ -s "$_m" ]; then
        awk 'NR == FNR { d[$1 " " $2] = 1; next } !(($3 " " $4) in d)' "$_m" -
    else
        cat
    fi
}

_z2k_our_ip_hosts() {
    printf '%s\n' "$1" | awk '
        $1 == "ip" && $2 == "host" {
            n = tolower($3); a = $4
            if (a == "85.192.60.175" || a == "213.176.74.63" || a == "79.137.196.7") print
            else if (a == "2.58.104.1" && n !~ /cloudflare/) print
            else if (n ~ /^finland[0-9]+\.discord\.media$/) print
            else if (n == "github.com" || n == "api.github.com" || n == "codeload.github.com" ||
                     n == "raw.githubusercontent.com" || n == "objects.githubusercontent.com" ||
                     n == "release-assets.githubusercontent.com" || n == "gist.githubusercontent.com" ||
                     n == "cdn.jsdelivr.net" || n == "gh-proxy.com") print
        }' | _z2k_not_d2k_pins
}

# Каждую снятую запись называем: удаление по адресу задело бы и запись, которую
# человек сам направил на наш узел, и он должен это увидеть.
_z2k_remove_our_ip_hosts() {
    command -v ndmc >/dev/null 2>&1 || return 0
    local _cfg _line
    _cfg=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null) || return 0
    _z2k_our_ip_hosts "$_cfg" | while IFS= read -r _line; do
        if LD_LIBRARY_PATH= ndmc -c "no $_line" >/dev/null 2>&1; then
            echo "[i] Снята запись: $_line"
        fi
    done
    LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
    return 0
}

# Итоговая проверка: 0 — наших записей нет. Иначе печатает, что осталось.
_z2k_ip_hosts_clean() {
    command -v ndmc >/dev/null 2>&1 || return 0
    local _cfg _left
    if ! _cfg=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null); then
        echo "[!] Не удалось прочитать конфиг роутера: записи ip host не проверены."
        echo "    Посмотрите: ndmc -c 'show running-config' | grep 'ip host'"
        return 1
    fi
    _left=$(_z2k_our_ip_hosts "$_cfg")
    [ -z "$_left" ] && return 0
    echo "[!] В конфиге роутера остались наши записи ip host:"
    printf '%s\n' "$_left" | sed 's/^/    /'
    return 1
}
# z2k:shared:remove_our_ip_hosts:end

# z2k:shared:restore_kernel_tuning:begin
# Вернуть то, что служба меняла в ядре. Обычно это уже сделал S99 stop, но его могло
# не быть, он мог упасть, а работавшие сторожа могли успеть применить настройки
# обратно, пока удаление шло. Поэтому вызываем ПОСЛЕ снятия планировщика и хуков.
#
# fastroute возвращаем там же, где его гасит S99: нет драйвера аппаратного NAT и
# тумблер Z2K_FASTROUTE_OFF не запрещает. $1 — значение этого тумблера.
#
# Режим /sys/kernel/fastnat/mode меняет установщик. Прежнее значение возвращаем,
# только если оно сохранено: выдумывать чужую настройку нельзя.
_z2k_restore_kernel_tuning() {
    local _d _v
    _d="${Z2K_NF_SYSCTL:-/proc/sys/net/netfilter}"
    [ -w "$_d/nf_conntrack_tcp_be_liberal" ] && echo 0 > "$_d/nf_conntrack_tcp_be_liberal" 2>/dev/null
    [ -w "$_d/nf_conntrack_checksum" ] && echo 1 > "$_d/nf_conntrack_checksum" 2>/dev/null
    [ -w "$_d/nf_conntrack_fastnat" ] && echo 1 > "$_d/nf_conntrack_fastnat" 2>/dev/null
    [ -w "$_d/nf_conntrack_fastnat_xfrm" ] && echo 1 > "$_d/nf_conntrack_fastnat_xfrm" 2>/dev/null
    if [ -w "$_d/nf_conntrack_fastroute" ] && [ "${1:-1}" != "0" ] \
       && [ ! -d "${Z2K_HWNAT_DIR:-/proc/driver/hw_nat}" ]; then
        echo 1 > "$_d/nf_conntrack_fastroute" 2>/dev/null
    fi
    if [ -r "${Z2K_FASTNAT_ORIG:-/opt/etc/z2k/fastnat-mode.orig}" ]; then
        _v=$(cat "${Z2K_FASTNAT_ORIG:-/opt/etc/z2k/fastnat-mode.orig}" 2>/dev/null)
        case "$_v" in
            ''|*[!0-9]*) rm -f "${Z2K_FASTNAT_ORIG:-/opt/etc/z2k/fastnat-mode.orig}" 2>/dev/null ;;
            *) if [ -w "${Z2K_FASTNAT_MODE:-/sys/kernel/fastnat/mode}" ] \
                  && echo "$_v" > "${Z2K_FASTNAT_MODE:-/sys/kernel/fastnat/mode}" 2>/dev/null; then
                   rm -f "${Z2K_FASTNAT_ORIG:-/opt/etc/z2k/fastnat-mode.orig}" 2>/dev/null
               fi ;;
        esac
    fi
    return 0
}
# z2k:shared:restore_kernel_tuning:end

# z2k:shared:own_processes:begin
# Гасим только свои процессы: то же имя может быть у чужой установки. Свой — тот,
# чей бинарник или командная строка указывают на /opt/zapret2.
_z2k_our_pids() { # <имя>
    local _p _e _c _all
    _all=$(pidof "$1" 2>/dev/null)
    [ -n "$_all" ] || _all=$(ps w 2>/dev/null | awk -v n="$1" '$0 ~ "/" n "( |$)" {print $1}')
    for _p in $_all; do
        _e=$(readlink "/proc/$_p/exe" 2>/dev/null)
        _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
        case "$_e $_c" in
            */opt/zapret2/*) echo "$_p" ;;
        esac
    done
    return 0
}

_z2k_kill_ours() { # <имя>
    local _p
    for _p in $(_z2k_our_pids "$1"); do
        kill -9 "$_p" 2>/dev/null
    done
    return 0
}
# z2k:shared:own_processes:end

# z2k:shared:own_rules:begin
# Подметание оставшихся правил: только наша очередь NFQUEUE и то, где в правиле есть
# z2k. Чужая очередь не наша, даже если правило выглядит похоже. Вызывать, пока
# конфиг на месте: в нём номер очереди.
_z2k_sweep_our_rules() {
    local _q _tool _t _ch _r
    _q=$(sed -n 's/^QNUM=//p' "${ZAPRET2_DIR:-/opt/zapret2}/config" 2>/dev/null | tail -n 1 | tr -d "\"'")
    case "$_q" in ''|*[!0-9]*) _q=200 ;; esac
    for _tool in iptables ip6tables; do
        command -v "$_tool" >/dev/null 2>&1 || continue
        for _t in mangle nat raw filter; do
            for _ch in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
                "$_tool" -w -t "$_t" -S "$_ch" 2>/dev/null \
                    | grep -E -- "--queue-num $_q( |\$)|z2k" | sed 's/^-A /-D /' \
                    | while IFS= read -r _r; do
                        # shellcheck disable=SC2086  # строка правила: разбиение намеренно
                        "$_tool" -w -t "$_t" $_r 2>/dev/null
                    done
            done
        done
    done
    return 0
}

# После снятия правил: набор, на который ссылается правило, не удалить. Имена
# nozapret, zapret и ipban общие с исходным проектом: при чужой установке в
# /opt/zapret они её, такие не трогаем.
_z2k_destroy_our_ipsets() {
    local _s
    for _s in $(ipset list -n 2>/dev/null); do
        case "$_s" in
            z2k*|Z2K*) ipset destroy "$_s" 2>/dev/null ;;
            nozapret|nozapret6|zapret|zapret6|ipban|ipban6)
                [ -d /opt/zapret ] || ipset destroy "$_s" 2>/dev/null ;;
        esac
    done
    return 0
}
# z2k:shared:own_rules:end

# z2k:shared:warp_finish:begin
# Интерфейс WARP удаляем за собой: движок мог упасть и оставить его. Ключ устройства
# единственное, что переживает удаление: повторная установка не должна заново
# регистрировать устройство у Cloudflare.
_z2k_warp_finish() {
    local _i _t _tuns _d _f
    killall -9 z2k-warpd 2>/dev/null
    _i=0
    while [ "$_i" -lt 3 ]; do
        _tuns=$(ip -o link show 2>/dev/null | sed -n 's/^[0-9]*: \(z2ktun[0-9]*\)[:@].*/\1/p')
        [ -n "$_tuns" ] || break
        for _t in $_tuns; do
            ip link set "$_t" down 2>/dev/null
            ip link delete "$_t" 2>/dev/null || ip tuntap del dev "$_t" mode tun 2>/dev/null
        done
        _i=$((_i + 1))
        sleep 1
    done
    _d=/opt/etc/z2k-warp
    if [ -d "$_d" ]; then
        for _f in "$_d"/* "$_d"/.[!.]*; do
            [ -e "$_f" ] || continue
            [ "${_f##*/}" = "device.json" ] || rm -rf "$_f"
        done
        rmdir "$_d" 2>/dev/null
    fi
    return 0
}
# z2k:shared:warp_finish:end

# z2k:shared:purge_leftovers:begin
# Всё наше, что лежит вне дерева: копии, бэкапы, журналы, настройки, пометки. Звать
# последним. Журнал идущей задачи панели и сам скрипт зачистки в /tmp не трогаем:
# это оперативка, а журнал единственный след того, как прошло удаление.
_z2k_purge_leftovers() {
    local _f
    rm -rf /opt/z2k-rollback /opt/z2k-upgrade-backup /opt/z2k-work /opt/zapret2.old.* \
           /opt/etc/z2k /opt/etc/zapret2 2>/dev/null
    rm -f /opt/etc/opkg.conf.backup /opt/etc/opkg.conf.z2k-bak \
          /opt/etc/.z2k-* /opt/var/log/z2k-* \
          /opt/etc/init.d/S99zapret2.* /opt/etc/init.d/S*z2k* /opt/etc/ndm/netfilter.d/*z2k* \
          /opt/sbin/*.z2kbak /opt/sbin/z2k-usque \
          /opt/etc/init.d/S97tg-mtproxy \
          /opt/etc/init.d/*.z2k-au.* /opt/etc/ndm/netfilter.d/*.z2k-au.* /opt/sbin/*.z2k-au.* 2>/dev/null
    # Незавершённые подмены бинарников от оборванных обновлений и откатов.
    for _f in tg-mtproxy-client z2k-detect z2k-warpd z2k-rt-proxy; do
        rm -f "/opt/sbin/$_f.new."* "/opt/sbin/$_f.rb."* 2>/dev/null
    done
    # Обычный файл с таким именем чужой: установщик его и сам не перезаписывает.
    [ -L /opt/bin/z2k ] && rm -f /opt/bin/z2k
    # Ссылки на библиотеки, которые создаёт установка. Только если это именно они.
    for _f in libmnl.so:libmnl.so.0 libnetfilter_queue.so:libnetfilter_queue.so.1 libnfnetlink.so:libnfnetlink.so.0; do
        if [ -L "/opt/lib/${_f%%:*}" ] && [ "$(readlink "/opt/lib/${_f%%:*}")" = "${_f##*:}" ]; then
            rm -f "/opt/lib/${_f%%:*}"
        fi
    done
    for _f in /tmp/z2k* /tmp/.z2k* /tmp/zapret2* /tmp/nfqws2* /tmp/tg-crash.log /tmp/tg-tunnel-watchdog.* \
              /var/run/z2k* /var/run/tg-tunnel.pid /var/run/nfqws2*; do
        [ -e "$_f" ] || continue
        case "$_f" in
            /tmp/z2k-job-*|/tmp/z2k_cleanup*) ;;
            *) rm -rf "$_f" ;;
        esac
    done
    return 0
}

# Пакеты, которые поставила именно наша установка: она записала их при установке.
# Пакет, нужный другим, opkg снять откажется, и это правильно. curl не трогаем:
# без него не выполнить однострочник повторной установки. Звать, пока жив /opt/etc/z2k.
_z2k_remove_our_packages() {
    local _list="${Z2K_INSTALLED_PKGS:-/opt/etc/z2k/installed-packages}" _p
    [ -r "$_list" ] || return 0
    command -v opkg >/dev/null 2>&1 || return 0
    for _p in $(awk '{a[NR]=$1} END {for (i = NR; i > 0; i--) print a[i]}' "$_list"); do
        case "$_p" in ''|curl|*[!A-Za-z0-9._+-]*) continue ;; esac
        if opkg remove --autoremove "$_p" </dev/null >/dev/null 2>&1; then
            echo "[i] Удалён пакет: $_p"
        else
            echo "[!] Пакет $_p оставлен: он нужен другим программам"
        fi
    done
    return 0
}
# z2k:shared:purge_leftovers:end

# z2k:shared:warp_routing_sweep:begin
# Маршрутизация WARP, если z2k-warp.sh уже не отработал: без неё метка, правило и
# цепочка висят до перезагрузки, а ipset нельзя удалить, потому что он занят.
# Трафик при этом не теряется: таблица пустеет вместе с интерфейсом и пакет идёт
# дальше по обычным правилам.
_z2k_warp_routing_sweep() {
    local _spec _t _ch _r
    ip rule del fwmark 0x989/0x989 table 989 2>/dev/null
    ip rule del fwmark 0x989 table 989 2>/dev/null
    ip route flush table 989 2>/dev/null
    # Смотрим через -S: обычный вывод iptables -L -n не показывает интерфейсы, и правила
    # z2ktunN в нём не найти. Метка 0x989, захват DNS (группа 189) и интерфейс — наши.
    for _spec in mangle:PREROUTING mangle:FORWARD mangle:OUTPUT \
                 filter:FORWARD filter:OUTPUT filter:INPUT nat:POSTROUTING; do
        _t="${_spec%%:*}"; _ch="${_spec##*:}"
        iptables -w -t "$_t" -S "$_ch" 2>/dev/null \
            | grep -E -- '-j Z2K_WARP|z2ktun[0-9]|--nflog-group 189( |$)|--mark 0x989(/|$| )' | sed 's/^-A /-D /' \
            | while IFS= read -r _r; do
                # shellcheck disable=SC2086  # строка правила: разбиение намеренно
                iptables -w -t "$_t" $_r 2>/dev/null
            done
    done
    iptables -w -t mangle -F Z2K_WARP 2>/dev/null
    iptables -w -t mangle -X Z2K_WARP 2>/dev/null
    return 0
}
# z2k:shared:warp_routing_sweep:end

echo ""
echo "============================================"
echo "  z2k_cleanup — полная зачистка z2k"
echo "============================================"
echo ""
log_warn "ВНИМАНИЕ: будут удалены все файлы z2k, включая бэкапы и настройки."
log_warn "Останется только ключ WARP. Чужие программы не затрагиваются."
echo ""

# ==========================================
# 1. Остановка init-скриптов (мягкая попытка)
# ==========================================

# WARP снимаем ДО остановки его движка, как в основном удалении: правило и метка
# ведут в интерфейс, который исчезнет вместе с процессом. S51 stop гасит только
# движок, маршрутизацию он не трогает. Ключ устройства ниже удаляется отдельно.
if [ -r /opt/zapret2/z2k-warp.sh ]; then
    log_info "Снятие маршрутизации WARP..."
    # stdin закрыт: скрипт запускают через `curl | sh`, и остаток скрипта читается оттуда же.
    sh /opt/zapret2/z2k-warp.sh remove </dev/null >/dev/null 2>&1
fi

log_info "Попытка мягкой остановки через init-скрипты..."

for init in /opt/etc/init.d/S99zapret2 \
            /opt/etc/init.d/S97z2k-http-tunnel \
            /opt/etc/init.d/S96z2k-rt-proxy \
            /opt/etc/init.d/S96z2k-webpanel \
            /opt/etc/init.d/S98z2k-detect \
            /opt/etc/init.d/S51z2k-warp \
            /opt/etc/init.d/S95z2k-tpws \
            /opt/etc/init.d/S98tg-tunnel \
            /opt/etc/init.d/S99z2k-scheduler; do
    if [ -x "$init" ]; then
        log_info "Останавливаю: $init stop"
        "$init" stop 2>/dev/null || log_warn "  $init stop вернул ошибку (не критично)"
    fi
done

# ==========================================
# 2. Удаление init-скриптов
# ==========================================

log_info "Удаление init-скриптов..."

# Шаблон S*z2k* в конце списка — намеренно. Перечисление руками уже трижды
# отставало от жизни: после полной очистки на роутере оставались S96z2k-webpanel,
# S98z2k-detect и S02z2k-tcp-tuning (поле, 16.09.2026). Имена наших служб все
# начинаются с z2k, поэтому шаблон закрывает и те, что появятся позже.
for init in /opt/etc/init.d/S99zapret2 \
            /opt/etc/init.d/S97z2k-http-tunnel \
            /opt/etc/init.d/S96z2k-rt-proxy \
            /opt/etc/init.d/S96z2k-webpanel \
            /opt/etc/init.d/S98z2k-detect \
            /opt/etc/init.d/S02z2k-tcp-tuning \
            /opt/etc/init.d/S51z2k-warp \
            /opt/etc/init.d/S95z2k-tpws \
            /opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97tg-mtproxy \
            /opt/etc/init.d/S99z2k-scheduler \
            /opt/etc/init.d/S*z2k*; do
    if [ -f "$init" ]; then
        rm -f "$init"
        log_info "  Удалён: $init"
    fi
done

# ==========================================
# 3. Удаление netfilter хуков
# ==========================================

log_info "Удаление netfilter хуков..."

for hook in /opt/etc/ndm/netfilter.d/000-zapret2.sh \
            /opt/etc/ndm/netfilter.d/89-z2k-dns-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-dns* \
            /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-tg* \
            /opt/etc/ndm/netfilter.d/91-z2k-http-tunnel-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-http* \
            /opt/etc/ndm/netfilter.d/92-z2k-rt-proxy-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-rt* \
            /opt/etc/ndm/netfilter.d/93-z2k-tpws-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-tpws* \
            /opt/etc/ndm/netfilter.d/94-z2k-ppe-deoffload.sh \
            /opt/etc/ndm/netfilter.d/*z2k-ppe* \
            /opt/etc/ndm/netfilter.d/*z2k*; do
    if [ -f "$hook" ]; then
        rm -f "$hook"
        log_info "  Удалён: $hook"
    fi
done

# ==========================================
# 4. Убийство всех процессов nfqws / nfqws2
# ==========================================

log_info "Завершение своих процессов..."

killed=0
# Планировщик и фоновые писатели: init-скрипта могло не быть, а живой планировщик
# вернул бы обратно и правила, и настройки ядра.
# Идущее автообновление гасим тоже: иначе оно вернёт удалённое из снимка отката.
for _pat in 'S99z2k-scheduler' 'z2k-scheduler\.sh' 'z2k-auto-update' 'z2k-detect' 'lighttpd.*zapret2'; do
    _spids=$(ps w 2>/dev/null | grep -E "$_pat" | grep -v grep | awk '{print $1}')
    # shellcheck disable=SC2086  # список pid'ов — разбиение намеренно
    [ -n "$_spids" ] && kill -9 $_spids 2>/dev/null
done
# nfqws2 и tpws могут принадлежать чужой установке, остальные имена только наши.
_z2k_kill_ours nfqws2
_z2k_kill_ours nfqws
_z2k_kill_ours tpws
for proc_name in tg-mtproxy-client z2k-rt-proxy z2k-warpd; do
    if pidof "$proc_name" >/dev/null 2>&1; then
        killall -9 "$proc_name" 2>/dev/null
        killed=$((killed + 1))
    fi
done

_z2k_warp_routing_sweep

_z2k_warp_finish

if [ "$killed" -eq 0 ]; then
    log_skip "Запущенных процессов nfqws/nfqws2/tg-mtproxy-client не найдено"
else
    log_info "Завершено процессов: $killed"
fi

# ==========================================
# 5. Очистка iptables правил и цепочек
# ==========================================

log_info "Очистка своих правил iptables..."

# Наши цепочки
chains_mangle="ZAPRET2 z2k_connmark"
chains_nat="z2k_masq_fix zapret2_nat"
chains_raw="z2k_dpi_rst"

# Удаление из mangle
for chain in $chains_mangle; do
    # Удалить ссылки из стандартных цепочек
    for parent in POSTROUTING PREROUTING FORWARD; do
        while iptables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
            iptables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            log_info "  Удалена ссылка mangle/$parent -> $chain"
        done
        while ip6tables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
            ip6tables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            log_info "  Удалена ссылка mangle/$parent -> $chain (IPv6)"
        done
    done
    # Flush и удаление самой цепочки
    iptables -t mangle -F "$chain" 2>/dev/null && log_info "  Очищена mangle/$chain"
    iptables -t mangle -X "$chain" 2>/dev/null && log_info "  Удалена mangle/$chain"
    ip6tables -t mangle -F "$chain" 2>/dev/null && log_info "  Очищена mangle/$chain (IPv6)"
    ip6tables -t mangle -X "$chain" 2>/dev/null && log_info "  Удалена mangle/$chain (IPv6)"
done

# Удаление из nat
for chain in $chains_nat; do
    while iptables -t nat -C POSTROUTING -j "$chain" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$chain" 2>/dev/null || break
    done
    iptables -t nat -F "$chain" 2>/dev/null && log_info "  Очищена nat/$chain"
    iptables -t nat -X "$chain" 2>/dev/null && log_info "  Удалена nat/$chain"
done

# Удаление из raw
for chain in $chains_raw; do
    while iptables -t raw -C PREROUTING -j "$chain" 2>/dev/null; do
        iptables -t raw -D PREROUTING -j "$chain" 2>/dev/null || break
    done
    iptables -t raw -F "$chain" 2>/dev/null && log_info "  Очищена raw/$chain"
    iptables -t raw -X "$chain" 2>/dev/null && log_info "  Удалена raw/$chain"
done

_z2k_sweep_our_rules

# ==========================================
# 5a. Telegram-туннель: NAT REDIRECT правила
# ==========================================
#
# Меню [T] / install вставляет REDIRECT на :1443 для 10 Telegram DC CIDRs
# в PREROUTING и OUTPUT (nat). NDM hook может продублировать их, поэтому
# удаляем в цикле пока -C находит совпадение.

log_info "Удаление iptables NAT REDIRECT правил Telegram-туннеля (:1443)..."

TG_CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
tg_rules_removed=0
# Current ipset-based rules (z2k_tg_dc match-set → :1443) — 2 rules.
for chain in PREROUTING OUTPUT; do
    while iptables -w -t nat -C "$chain" -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443 2>/dev/null; do
        iptables -w -t nat -D "$chain" -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443 2>/dev/null || break
        tg_rules_removed=$((tg_rules_removed + 1))
    done
done
# Legacy per-CIDR rules (pre-ipset builds) — keep removing for back-compat.
for cidr in $TG_CIDRS; do
    for chain in PREROUTING OUTPUT; do
        while iptables -w -t nat -C "$chain" -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -w -t nat -D "$chain" -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
            tg_rules_removed=$((tg_rules_removed + 1))
        done
    done
done
# Destroy the ipset itself — NDM doesn't touch ipsets, so it would linger.
# Защита DNS: два правила REDIRECT :53 (udp/tcp) по ipset LAN-подсетей.
for _p in udp tcp; do
    while iptables -w -t nat -C PREROUTING -p "$_p" --dport 53 -m set --match-set z2k_lan4 src -m set ! --match-set z2k_lan4 dst -j REDIRECT --to-ports 53 2>/dev/null; do
        iptables -w -t nat -D PREROUTING -p "$_p" --dport 53 -m set --match-set z2k_lan4 src -m set ! --match-set z2k_lan4 dst -j REDIRECT --to-ports 53 2>/dev/null || break
    done
done
ipset destroy z2k_lan4 2>/dev/null && log_info "  Удалён ipset z2k_lan4"
if ipset destroy z2k_tg_dc 2>/dev/null; then
    log_info "  Удалён ipset z2k_tg_dc"
fi
if [ "$tg_rules_removed" -gt 0 ]; then
    log_info "  Снято NAT правил Telegram: $tg_rules_removed"
else
    log_skip "Правил REDIRECT :1443 не найдено"
fi

# ==========================================
# 5a-tpws. tpws youtube-слой: NAT REDIRECT (:1446) + mangle mark + ipset
# ==========================================

log_info "Удаление iptables правил tpws-слоя (:1446)..."
tpws_rules_removed=0
while iptables -w -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446 2>/dev/null; do
    iptables -w -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446 2>/dev/null || break
    tpws_rules_removed=$((tpws_rules_removed + 1))
done
while iptables -w -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null; do
    iptables -w -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null || break
    tpws_rules_removed=$((tpws_rules_removed + 1))
done
if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -w -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446 2>/dev/null; do
        ip6tables -w -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446 2>/dev/null || break
        tpws_rules_removed=$((tpws_rules_removed + 1))
    done
    while ip6tables -w -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null; do
        ip6tables -w -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null || break
        tpws_rules_removed=$((tpws_rules_removed + 1))
    done
fi
# Destroy ipsets (NDM doesn't touch them; rules dropped above so not "in use").
ipset destroy z2k_tpws 2>/dev/null && log_info "  Удалён ipset z2k_tpws"
ipset destroy z2k_tpws6 2>/dev/null && log_info "  Удалён ipset z2k_tpws6"
rm -rf /opt/zapret2/tpws /opt/zapret2/z2k-tpws.sh /opt/zapret2/z2k-tpws-watchdog.sh \
       /opt/zapret2/lists/youtube_ips.txt /opt/zapret2/lists/youtube_ips6.txt \
       /var/run/z2k-tpws.pid 2>/dev/null
_z2k_kill_ours tpws
if [ "$tpws_rules_removed" -gt 0 ]; then
    log_info "  Снято правил tpws: $tpws_rules_removed"
else
    log_skip "Правил tpws :1446 не найдено"
fi

# ==========================================
# 5b-ppe. Per-flow PPE de-offload: mangle FORWARD/PREROUTING -j PPE (connskip)
# ==========================================

log_info "Удаление iptables правил per-flow PPE de-offload..."
ppe_rules_removed=0
# Текущее правило, прежнее (без порта 5222) и правило QUIC. Пока тут стоял только
# прежний вариант, текущее не снималось и поток оставался мимо ускорителя.
for ppe_args in "-p tcp -m multiport --dports 80,443,2053,2083,2087,2096,5222,8443 -m connskip --connskip 30 -j PPE" \
                "-p tcp -m multiport --dports 80,443,2053,2083,2087,2096,8443 -m connskip --connskip 30 -j PPE" \
                "-p udp --dport 443 -m connskip --connskip 30 -j PPE" \
                "-p udp -m multiport --dports 1024:2407,2409:65535 -m connskip --connskip 30 -j PPE"; do
    for ppe_c in FORWARD PREROUTING; do
        while iptables -w -t mangle -C "$ppe_c" $ppe_args 2>/dev/null; do
            iptables -w -t mangle -D "$ppe_c" $ppe_args 2>/dev/null || break
            ppe_rules_removed=$((ppe_rules_removed + 1))
        done
        if command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -w -t mangle -C "$ppe_c" $ppe_args 2>/dev/null; do
                ip6tables -w -t mangle -D "$ppe_c" $ppe_args 2>/dev/null || break
                ppe_rules_removed=$((ppe_rules_removed + 1))
            done
        fi
    done
done
rm -f /opt/zapret2/z2k-ppe-deoffload.sh 2>/dev/null
if [ "$ppe_rules_removed" -gt 0 ]; then
    log_info "  Снято правил PPE de-offload: $ppe_rules_removed"
else
    log_skip "Правил PPE de-offload не найдено"
fi

# ==========================================
# 5a-bis. Вспомогательный HTTP-туннель: NAT REDIRECT правила (:1444)
# ==========================================

log_info "Удаление iptables NAT REDIRECT правил вспомогательного туннеля (:1444)..."

HTTP_CIDRS="168.119.95.238/32"
http_rules_removed=0
for cidr in $HTTP_CIDRS; do
    for chain in PREROUTING OUTPUT; do
        while iptables -t nat -C "$chain" -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null; do
            iptables -t nat -D "$chain" -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null || break
            http_rules_removed=$((http_rules_removed + 1))
        done
    done
    conntrack -D -d "${cidr%/*}" 2>/dev/null || true
done
if [ "$http_rules_removed" -gt 0 ]; then
    log_info "  Снято NAT правил :1444: $http_rules_removed"
else
    log_skip "Правил REDIRECT :1444 не найдено"
fi

# ==========================================
# 5a-rt. RuTracker-прокси (:1445) — правила, DNS-пины, бинарь
# ==========================================
# Этой секции не было вовсе, хотя соседние (:1443, :1444, :1446) есть. Последствие
# хуже, чем просто мусор: DOMAINS рутрекера прибиты в конфиге роутера к sentinel
# 10.171.171.171, а слушателя на :1445 после зачистки нет — рутрекер остаётся
# мёртвым НАВСЕГДА, и по коробке не видно почему. Скрипт запускают именно тогда,
# когда что-то сломалось, так что он обязан не добавлять поломку.

log_info "Удаление правил и DNS-пинов RuTracker-прокси (:1445)..."

RTP_SENTINEL="10.171.171.171"
rtp_rules_removed=0
for chain in PREROUTING OUTPUT; do
    while iptables -w -t nat -C "$chain" -d "$RTP_SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null; do
        iptables -w -t nat -D "$chain" -d "$RTP_SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null || break
        rtp_rules_removed=$((rtp_rules_removed + 1))
    done
done
# PPE de-offload на sentinel ставится отдельно от REDIRECT — снимаем и его.
while iptables -w -t mangle -C PREROUTING -d "$RTP_SENTINEL" -p tcp --dport 443 -j PPE 2>/dev/null; do
    iptables -w -t mangle -D PREROUTING -d "$RTP_SENTINEL" -p tcp --dport 443 -j PPE 2>/dev/null || break
    rtp_rules_removed=$((rtp_rules_removed + 1))
done
conntrack -D -d "$RTP_SENTINEL" 2>/dev/null || true
if [ "$rtp_rules_removed" -gt 0 ]; then
    log_info "  Снято правил :1445/sentinel: $rtp_rules_removed"
else
    log_skip "Правил RuTracker-прокси не найдено"
fi

# DNS-пины. LD_LIBRARY_PATH= обязателен: с Entware-путями ndmc грузит несовместимый
# OpenSSL и падает `Cli::Main: failed to initialize` — проверено на KeenOS 5.01.C.1.0-0,
# и именно так этот класс отказа однажды уже оставил пины висеть.
if command -v ndmc >/dev/null 2>&1; then
    rtp_pins_removed=0
    for _d in rutracker.org www.rutracker.org rutracker.cc static.rutracker.cc \
              api.rutracker.cc rep.rutracker.cc rutracker.wiki; do
        if LD_LIBRARY_PATH= ndmc -c "no ip host $_d $RTP_SENTINEL" >/dev/null 2>&1; then
            rtp_pins_removed=$((rtp_pins_removed + 1))
        fi
    done
    LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
    if [ "$rtp_pins_removed" -gt 0 ]; then
        log_info "  Снято DNS-пинов rutracker: $rtp_pins_removed"
    else
        log_skip "DNS-пинов rutracker не найдено"
    fi
fi

# ------------------------------------------------------------------
# DNS-пины остальных доменов: Instagram, WhatsApp, 4pda.
#
# ЗАЧЕМ. Выше снимаются только rutracker-пины, перечисленные руками. Всё
# остальное оставалось висеть НАВСЕГДА: человек снёс z2k, а роутер продолжает
# резолвить instagram.com и 4pda.to в адреса, которые мы туда прошили. Через
# недели-месяцы адреса протухают, и у него ломается то, что без z2k работало бы
# нормально — причём причину найти неоткуда. Плюс у Keenetic потолок 256
# статических записей, и его уже однажды съели пинами Discord.
#
# СПИСОК ДОМЕНОВ НЕ ДУБЛИРУЕМ. Он берётся из HOSTS в самом
# z2k-insta-ip-refresh.sh — то есть оттуда же, откуда берётся при установке.
# Иначе каждый новый домен надо не забыть внести во ВТОРОЕ место, а этот класс
# ошибок у нас уже случался: 4pda добавили 19.08 и в удаление он не попал бы.
# Скрипт на этот момент ещё на диске — /opt/zapret2 сносится ниже.
#
# Строку из running-config подставляем в `no <строка>` целиком: у ndmc удаление
# принимает те же аргументы, что и добавление, а IP в записи может быть любым
# (их переписывает ежедневное обновление).
if command -v ndmc >/dev/null 2>&1; then
    _refresh_sh="${ZAPRET2_DIR:-/opt/zapret2}/z2k-insta-ip-refresh.sh"
    _pin_hosts=""
    if [ -r "$_refresh_sh" ]; then
        _pin_hosts=$(sed -n 's/^HOSTS="\(.*\)"$/\1/p' "$_refresh_sh" | head -1)
    fi
    # Запасной список — на случай, когда скрипта уже нет (частичная установка,
    # ручное удаление файлов). Лучше снять по памяти, чем не снять вовсе.
    [ -n "$_pin_hosts" ] || _pin_hosts="instagram.com www.instagram.com graph.instagram.com api.instagram.com instagram.c10r.instagram.com static.cdninstagram.com scontent.cdninstagram.com web.whatsapp.com www.whatsapp.com scontent.whatsapp.net graph.whatsapp.com v.whatsapp.com 4pda.to www.4pda.to s.4pda.to"

    _pin_removed=0
    _running=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null)
    for _h in $_pin_hosts redirector.googlevideo.com; do
        # Точное совпадение по имени: подстрока зацепила бы чужие домены.
        _lines=$(printf '%s\n' "$_running" | awk -v h="$_h" '$1=="ip" && $2=="host" && $3==h {print}' | _z2k_not_d2k_pins)
        [ -n "$_lines" ] || continue
        _IFS_save="$IFS"
        IFS='
'
        for _line in $_lines; do
            IFS="$_IFS_save"
            if LD_LIBRARY_PATH= ndmc -c "no $_line" >/dev/null 2>&1; then
                _pin_removed=$((_pin_removed + 1))
            fi
            IFS='
'
        done
        IFS="$_IFS_save"
    done
    if [ "$_pin_removed" -gt 0 ]; then
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
        log_info "  Снято DNS-пинов Instagram/WhatsApp/4pda: $_pin_removed"
    else
        log_skip "DNS-пинов Instagram/WhatsApp/4pda не найдено"
    fi
fi

# Записи релея (→ наш узел), голоса Discord и GitHub. Этого блока здесь не было:
# после «полной» зачистки WhatsApp оставался прибит к нашему узлу навсегда.
_z2k_remove_our_ip_hosts

# Бинарь и его init-скрипт (директории /opt/zapret2 сносятся ниже, но /opt/sbin — нет).
# z2k-detect и z2k-warpd лежат там же и так же не уходят с деревом: их забыли
# внести, и после деинсталляции на флешке оставалось 12 МБ мёртвых бинарников.
for _f in /opt/sbin/z2k-rt-proxy /opt/sbin/z2k-rt-proxy.z2kbak \
          /opt/sbin/z2k-detect /opt/sbin/z2k-warpd \
          /opt/sbin/z2k-detect.new.* /opt/sbin/z2k-warpd.new.* \
          /opt/sbin/z2k-rt-proxy.new.*; do
    [ -f "$_f" ] && rm -f "$_f" && log_info "  Удалён $_f"
done

# ==========================================
# 5b. Cron-записи z2k и восстановление cron-демона
# ==========================================

# Strip every cron entry z2k ever installed (current + legacy paths).
if command -v crontab >/dev/null 2>&1; then
    for pat in "tg-tunnel-watchdog" "S97tg-mtproxy" \
               "z2k-auto-update" "z2k-update-lists" "z2k-classify-drift" \
               "z2k-nightly-probe" "ipset/get_config" "z2k-scheduler"; do
        if crontab -l 2>/dev/null | grep -q "$pat"; then
            crontab -l 2>/dev/null | grep -v "$pat" | crontab - 2>/dev/null \
                && log_info "  Удалена cron-запись: $pat"
        fi
    done
fi

# Strip our entries from /opt/etc/crontab too (legacy install method).
if [ -f /opt/etc/crontab ]; then
    if grep -qE "get_config\.sh|z2k-update-lists\.sh|z2k-auto-update\.sh|z2k-classify-drift\.sh|z2k-nightly-probe\.sh|tg-tunnel-watchdog|z2k-scheduler" /opt/etc/crontab 2>/dev/null; then
        grep -vE "get_config\.sh|z2k-update-lists\.sh|z2k-auto-update\.sh|z2k-classify-drift\.sh|z2k-nightly-probe\.sh|tg-tunnel-watchdog|z2k-scheduler" \
            /opt/etc/crontab > /opt/etc/crontab.tmp 2>/dev/null \
            && mv /opt/etc/crontab.tmp /opt/etc/crontab \
            && log_info "  Очищены z2k записи из /opt/etc/crontab"
    fi
fi

# ==========================================
# 6. Удаление директорий
# ==========================================

# Сетевые параметры: S99 мог не отработать. Планировщик и хуки уже сняты, вернуть их
# обратно некому. Конфиг читаем сейчас, ниже он удаляется.
while iptables -w -t mangle -C _NDM_POSTROUTING_TTL -m mark --mark 0x40000000/0x40000000 -j RETURN 2>/dev/null; do
    iptables -w -t mangle -D _NDM_POSTROUTING_TTL -m mark --mark 0x40000000/0x40000000 -j RETURN 2>/dev/null || break
done
_z2k_restore_kernel_tuning "$(sed -n 's/^Z2K_FASTROUTE_OFF=//p' /opt/zapret2/config 2>/dev/null | tail -n 1 | tr -d "\"'")"

_z2k_destroy_our_ipsets

log_info "Удаление своих каталогов..."

for dir in /opt/zapret2 /opt/z2k-rollback /opt/z2k-upgrade-backup /opt/etc/zapret2 /opt/zapret2.old.*; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        log_info "  Удалена: $dir"
    else
        log_skip "$dir не найдена (уже удалена)"
    fi
done

# Бинарник Telegram-туннеля живёт вне /opt/zapret2 — убираем отдельно.
if [ -f /opt/sbin/tg-mtproxy-client ]; then
    rm -f /opt/sbin/tg-mtproxy-client
    log_info "  Удалён бинарник: /opt/sbin/tg-mtproxy-client"
fi

# ==========================================
# 7. Очистка временных файлов
# ==========================================

log_info "Очистка временных файлов..."

# ЧТО УХОДИТ ВМЕСТЕ С ДЕРЕВОМ, А ЧТО ЛЕЖИТ ОТДЕЛЬНО. Настройки панели и журналы живут
# вне /opt/zapret2 и уходят здесь. Ключ WARP остаётся, см. _z2k_warp_finish.
_z2k_remove_our_packages
for tmpdir in /tmp/z2k /tmp/zapret2 \
              /tmp/z2k-log/tg-tunnel.log /tmp/tg-tunnel-watchdog.state \
              /var/run/tg-tunnel.pid \
              /tmp/z2k-log/z2k-http-tunnel.log /var/run/z2k-http-tunnel.pid \
              /tmp/z2k-log/z2k-rt-proxy.log /var/run/z2k-rt-proxy.pid \
              /var/run/z2k-warpd.pid \
              /tmp/z2k-log/z2k-insta-refresh.log /tmp/z2k-log/z2k-insta-refresh.log.old \
              /var/run/z2k-scheduler.pid /opt/var/log/z2k-scheduler.log \
              /opt/var/log/z2k-classify.log \
              /opt/var/log/z2k-classify-drift.log \
              /opt/var/log/z2k-classify-history.tsv \
              /opt/var/log/z2k-auto-update.log \
              /opt/var/log/z2k-auto-update.log.old \
              /opt/var/log/z2k-detect-watchdog.log \
              /tmp/z2k-tcp16-probe.log \
              /opt/bin/z2k \
              /opt/etc/z2k \
              /opt/etc/.z2k-rkn-fp.list /opt/etc/.z2k-rkn-fp.sha256 \
              /opt/etc/.z2k-instagram-purge-2026-05-28.done; do
    if [ -e "$tmpdir" ]; then
        rm -rf "$tmpdir"
        log_info "  Удалён: $tmpdir"
    fi
done

# ==========================================
# 8. Очистка ipset (если остались)
# ==========================================

log_info "Очистка оставшегося..."
_z2k_purge_leftovers

# ==========================================
# 9. Финальная проверка
# ==========================================

echo ""
log_info "=== Финальная проверка ==="

# Проверка процессов
if [ -n "$(_z2k_our_pids nfqws2)" ]; then
    log_error "Остался запущенный nfqws2! Проверьте: ps | grep nfqws2"
else
    log_info "Свой процесс nfqws2: не найден"
fi

if pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
    log_error "Остался запущенный tg-mtproxy-client! Проверьте: ps | grep tg-mtproxy"
else
    log_info "Процесс tg-mtproxy-client: не найден"
fi

# Проверка директорий
if [ -d /opt/zapret2 ]; then
    log_error "Директория всё ещё существует: /opt/zapret2"
else
    log_info "Директория удалена: /opt/zapret2"
fi

# Проверка init-скриптов
for init in /opt/etc/init.d/S99zapret2 \
            /opt/etc/init.d/S97z2k-http-tunnel \
            /opt/etc/init.d/S96z2k-rt-proxy \
            /opt/etc/init.d/S51z2k-warp \
            /opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97tg-mtproxy \
            /opt/etc/init.d/S99z2k-scheduler; do
    if [ -f "$init" ]; then
        log_error "Init-скрипт всё ещё существует: $init"
    fi
done

# Проверка Telegram-бинарника
if [ -f /opt/sbin/tg-mtproxy-client ]; then
    log_error "Бинарник всё ещё существует: /opt/sbin/tg-mtproxy-client"
fi

# ==========================================
# 10. Вернуть штатный lighttpd, если мы его выключали
# ==========================================
#
# Установка панели переименовывает конфликтующий S*lighttpd в
# .<имя>.disabled-by-z2k, чтобы он не держал порт 8088. Основное удаление
# (lib/install.sh) его возвращает, а эта зачистка — нет: человек, дошедший до
# аварийного скрипта, оставался с выключенным навсегда штатным lighttpd и без
# единого следа почему. Ровно эта жалоба пришла с поля 30.08.2026.
#
# Чужой файл не затираем, а на порт 80 не возвращаем (см. саму функцию).
_z2k_restore_stock_lighttpd

_cleanup_incomplete=0
_z2k_ip_hosts_clean || _cleanup_incomplete=1
if ip -o link show 2>/dev/null | grep -q 'z2ktun[0-9]'; then
    log_error "Остался интерфейс WARP z2ktun: исчезнет после перезагрузки роутера."
    _cleanup_incomplete=1
fi

echo ""
echo "============================================"
if [ "$_cleanup_incomplete" = 1 ]; then
    log_warn "Зачистка завершена не полностью: см. сообщения выше."
fi
log_info "Зачистка завершена."
if [ -f /opt/etc/z2k-warp/device.json ]; then
    log_info "Оставлен только ключ WARP: /opt/etc/z2k-warp/device.json"
fi
log_info "Параметры TCP (буферы, BBR) вернутся к заводским после перезагрузки роутера."
log_info "Для переустановки z2k:"
echo "  sh -c 'tmp=/tmp/z2k.sh; rm -f \"\$tmp\"; for url in \"https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh\" \"https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/z2k.sh\" \"https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh\"; do echo \"[i] Пробую: \$url\" >&2; if curl -fsSL --connect-timeout 10 --max-time 180 \"\$url\" -o \"\$tmp\"; then exec sh \"\$tmp\"; fi; done; echo \"[FAIL] Не удалось скачать z2k.sh ни с одного зеркала\" >&2; exit 1'"
echo "============================================"
echo ""

# Сам скрипт, если его скачали во временный файл: оболочка уже держит его открытым.
case "$0" in
    /tmp/z2k_cleanup*) rm -f "$0" ;;
esac
