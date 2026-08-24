#!/bin/sh
# /opt/zapret2/z2k-warp.sh — обвязка игрового режима WARP над движком z2k-warpd.
#
# Движок (/opt/sbin/z2k-warpd, наш, Go) владеет туннелем целиком: регистрация,
# транспорты (WireGuard → MASQUE-h2), интерфейс z2ktunN, NAT, liveness,
# реконнект, status.json. Здесь — только то, что честно shell:
#   install   скачать бинарь под арку + зарегистрировать устройство; НИЧЕГО не запускает
#   enable    флаг=1, ipset'ы, S51 start, дождаться ready, маршрут
#   disable   маршрут снять, S51 stop, флаг=0 — RSS ноль
#   remove    disable + бинарь удалён; device.json (1 КБ) остаётся, чтобы
#             повторная установка не заводила новое устройство у Cloudflare
#   ipset     перезагрузить оба ipset'а (z2k_warp из списков, z2k_warp_src из devices.txt)
#   selfheal  раз в 25 с из шедулера: демон жив? ready → маршрут, иначе снять (fail open)
#   status    одна строка key=value для панели/меню
#   migrate   списки (как было) + разовая зачистка usque
#
# Коды возврата enable — контракт с панелью и меню:
#   0 — ready (туннель доказанно несёт трафик)
#   2 — включено, туннель поднимается; флаг остаётся, причина — код из status.json
#   1 — нет бинаря / ipset не создать; флаг откатывается
#
# Маршрутизация: только PREROUTING (LAN-клиенты), никогда OUTPUT — собственный
# пакет роутера в TUN ломает reply-path и глушит доступ роутера к CF/GitHub.
# MARK только формой --set-xmark с маской: --set-mark затирает mark-word Keenetic.
#
# Z2K_STUB_PATH — только для тестов (стабы iptables/ip/ipset перед PATH).
export PATH="${Z2K_STUB_PATH:+$Z2K_STUB_PATH:}/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin"

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"
WARP_BIN="${WARP_BIN:-/opt/sbin/z2k-warpd}"
WARP_INIT="${WARP_INIT:-/opt/etc/init.d/S51z2k-warp}"
WARP_DEVICE="${WARP_DEVICE:-/opt/etc/z2k-warp/device.json}"
WARP_STATUS="${WARP_STATUS:-/tmp/z2k-warp/status.json}"
WARP_LISTS_DIR="${WARP_LISTS_DIR:-$ZAPRET2_DIR/lists/warp}"
WARP_DEVICES_FILE="${WARP_DEVICES_FILE:-$WARP_LISTS_DIR/devices.txt}"
WARP_IPSET="${WARP_IPSET:-z2k_warp}"
WARP_IPSET_SRC="${WARP_IPSET_SRC:-z2k_warp_src}"
WARP_TABLE="${WARP_TABLE:-989}"
WARP_MARK="${WARP_MARK:-0x989}"
WARP_RULE_PREF="${WARP_RULE_PREF:-90}"
WARP_READY_WAIT="${WARP_READY_WAIT:-120}"     # сколько enable ждёт ready, секунд
WARP_LEGACY_LIST="${WARP_LEGACY_LIST:-$ZAPRET2_DIR/lists/game-warp-ips.txt}"
# Остатки usque-эпохи — только для migrate.
WARP_LEGACY_BIN="${WARP_LEGACY_BIN:-/opt/sbin/z2k-usque}"
WARP_LEGACY_INIT="${WARP_LEGACY_INIT:-/opt/etc/init.d/S51usque}"
WARP_LEGACY_DIR="${WARP_LEGACY_DIR:-/opt/etc/z2k-warp}"
# Регистрация через VPS-релей, если API заблокирован напрямую (как было).
[ -f "$CONFIG_FILE" ] && _warp_cfg_proxy=$(grep -m1 '^Z2K_WARP_VPS_PROXY=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
WARP_VPS_PROXY="${WARP_VPS_PROXY:-${_warp_cfg_proxy:-http://z2kwarp:z2kW4rpR3g2026@213.176.74.63:8119}}"

_wlog() { echo "[z2k-warp] $*" >&2; }
warp_flag() { grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '" '; }
warp_set_flag() {
    [ -f "$CONFIG_FILE" ] || return 0
    local tmp="$CONFIG_FILE.warp.$$"
    if grep -q '^GAME_WARP_ENABLED=' "$CONFIG_FILE"; then
        sed "s/^GAME_WARP_ENABLED=.*/GAME_WARP_ENABLED=$1/" "$CONFIG_FILE" > "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
    else
        printf 'GAME_WARP_ENABLED=%s\n' "$1" >> "$CONFIG_FILE"
    fi
    rm -f "$tmp" 2>/dev/null
}
# Поля status.json / device.json — без jq: ключ → значение.
_json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1; }
_json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([a-z0-9.-]*\).*/\1/p" "$1" 2>/dev/null | head -1; }
warp_iface()   { _json_str "$WARP_DEVICE" iface; }

# MASQUE-ЭНДПОИНТ ИЗ ОБХОДА НЕ ИСКЛЮЧАЕТСЯ — И ЭТО ИЗМЕРЕНО, А НЕ ЗАБЫТО.
#
# В r-79.4 он добавлялся в nozapret «чтобы наш собственный handshake не ломал
# десинк». Результат на роутере владельца, по три прогона в каждом состоянии:
#   без nozapret (как в r-79.1/79.2): сквозная проба 9 из 9
#   с   nozapret (как в r-79.4):      сквозная проба 0 из 9
# TLS-сессия в обоих случаях УСТАНАВЛИВАЕТСЯ, но без десинка ТСПУ душит её
# сразу после — туннель «поднят» и не несёт ничего. Ровно это и сломало тех,
# у кого WARP работал. Десинк MASQUE-сессии нужен; ничего не исключаем.
warp_ready()   { [ "$(_json_raw "$WARP_STATUS" ready)" = "true" ]; }
warp_daemon_running() { [ -x "$WARP_INIT" ] && sh "$WARP_INIT" status >/dev/null 2>&1; }

# ---- WARP lists --------------------------------------------------------------
# Two kinds of list live here, and the difference matters:
#
#   $WARP_LISTS_DIR/*.txt        — the user's own. Created and edited from the
#                                  panel, preserved across reinstall, ALWAYS
#                                  loaded. Nothing but the user writes here.
#   $WARP_LISTS_DIR/games/*.txt  — upstream per-game lists, refreshed wholesale
#                                  by z2k-update-lists.sh. Read-only in the
#                                  panel, and loaded ONLY when switched on.
#
# Which game lists are on is recorded in $WARP_ENABLED_FILE, one name per line.
# Absent or empty means none — and that is the state of a fresh install. Storing
# it in a file rather than by renaming .txt out of the way is deliberate: the
# upstream refresh recreates those files, and would silently switch back on
# whatever the user had switched off.
WARP_GAMES_DIR="${WARP_GAMES_DIR:-$WARP_LISTS_DIR/games}"
WARP_ENABLED_FILE="${WARP_ENABLED_FILE:-$WARP_LISTS_DIR/.enabled}"

warp_lists_migrate() {
    [ -d "$WARP_LISTS_DIR" ] || mkdir -p "$WARP_LISTS_DIR" || {
        _wlog "cannot create $WARP_LISTS_DIR"; return 1; }
    mkdir -p "$WARP_GAMES_DIR" 2>/dev/null

    # One-shot purge of the legacy aggregate. It was 14297 entries covering 15%
    # of IPv4 — private space and the user's own LAN included — and it is what
    # made "switch WARP on" mean "lose the internet". It is deleted outright
    # rather than left switched off: a list that is visible but does nothing
    # generates more confusion than its absence. Its 3-way-merge companions go
    # with it; nothing merges any more.
    if [ ! -f "$WARP_LISTS_DIR/.legacy-aggregate-purged" ]; then
        rm -f "$WARP_LISTS_DIR/game-warp-ips.txt" \
              "$WARP_LISTS_DIR/.game-warp-ips.base" \
              "$WARP_LISTS_DIR/.game-warp-ips.upstream" \
              "$WARP_LISTS_DIR/.game-warp-ips.removed" \
              "$WARP_LISTS_DIR/.game-warp-ips.san" 2>/dev/null
        rm -f "$WARP_LEGACY_LIST" 2>/dev/null
        touch "$WARP_LISTS_DIR/.legacy-aggregate-purged" 2>/dev/null || true
        _wlog "legacy aggregate list removed — pick per-game lists in the panel"
    fi

    chmod 644 "$WARP_LISTS_DIR"/*.txt 2>/dev/null
    return 0
}

# Echo the files to load: every user list, plus each enabled game list that
# actually exists. A name in .enabled with no file behind it (upstream dropped
# it, or the refresh has not run yet) is simply skipped.
warp_active_lists() {
    local f n
    for f in "$WARP_LISTS_DIR"/*.txt; do
        # devices.txt — список УСТРОЙСТВ (источников), он грузится в z2k_warp_src
        # отдельно; сюда, в адреса назначения, ему нельзя.
        [ "$f" = "$WARP_DEVICES_FILE" ] && continue
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    [ -f "$WARP_ENABLED_FILE" ] || return 0
    while IFS= read -r n; do
        n=$(printf '%s' "$n" | tr -d ' \t\r')
        [ -n "$n" ] || continue
        case "$n" in
            '#'*|.*|-*) continue ;;
            *[!A-Za-z0-9._-]*) continue ;;
        esac
        [ -f "$WARP_GAMES_DIR/$n.txt" ] && printf '%s\n' "$WARP_GAMES_DIR/$n.txt"
    done < "$WARP_ENABLED_FILE"
    return 0
}

warp_ipset_count() {
    ipset list "$WARP_IPSET" 2>/dev/null | awk '/^Members:/{m=1;next} m&&NF{n++} END{print n+0}'
}

warp_ipset_load() {
    warp_lists_migrate
    ipset create "$WARP_IPSET" hash:net family inet 2>/dev/null
    ipset list "$WARP_IPSET" >/dev/null 2>&1 || { _wlog "cannot create ipset $WARP_IPSET"; return 1; }
    # Lists are user-edited now, so validate STRICTLY (mirrors the webpanel
    # save-time filter in actions.sh warp_list_save — keep in sync):
    #   - octets 0-255 with NO leading zeros (ipset parses 010.1.2.3 as OCTAL
    #     8.1.2.3 — silently wrong address; 08.8.8.8 doesn't parse at all),
    #   - first octet >= 1, prefix 1-32 (hash:net rejects cidr 0),
    # because ONE line ipset can't parse aborts the whole restore stream.
    # Defence in depth for that abort: load into a TEMP set and atomically
    # `ipset swap` it in — a failed restore then leaves the LIVE set intact
    # instead of the old flush-first stream that left it empty.
    # An empty/absent set of lists is a VALID state (user deleted everything):
    # the set just becomes empty and the PBR marks match nothing.
    local tmpset="${WARP_IPSET}_new"
    ipset destroy "$tmpset" 2>/dev/null
    ipset create "$tmpset" hash:net family inet 2>/dev/null
    ipset list "$tmpset" >/dev/null 2>&1 || { _wlog "cannot create temp ipset $tmpset"; return 1; }
    if warp_active_lists | while IFS= read -r _wl; do cat "$_wl" 2>/dev/null; done | awk -v set="$tmpset" '
# --- z2k warp address filter (canonical; keep byte-identical in all 3 copies) ---
function z2k_warp_addr_ok(s,   ip, h, o) {
    if (s !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/) return 0
    ip = s
    if (split(s, h, "/") == 2) ip = h[1]
    # No width cap. There was one at /10, on the reasoning that no game lives on
    # a /8 — but the blocks it cut are 3.0.0.0/8 and 15.0.0.0/8, i.e. Amazon,
    # which is exactly what people switch WARP on for. /0 is still impossible:
    # the grammar above only accepts prefixes 1-32.
    split(ip, o, ".")
    if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return 0
    if (o[1] == 10 || o[1] == 127 || o[1] >= 224) return 0
    if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 0
    if (o[1] == 169 && o[2] == 254) return 0
    if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 0
    if (o[1] == 192 && o[2] == 168) return 0
    if (o[1] == 192 && o[2] == 0 && (o[3] == 0 || o[3] == 2)) return 0
    if (o[1] == 198 && (o[2] == 18 || o[2] == 19)) return 0
    if (o[1] == 198 && o[2] == 51 && o[3] == 100) return 0
    if (o[1] == 203 && o[2] == 0 && o[3] == 113) return 0
    return 1
}
# --- end z2k warp address filter ---
        {
            sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
            if (!z2k_warp_addr_ok($0)) next
            print "add " set " " $0 " -exist"
        }' | ipset restore -exist 2>/dev/null; then
        ipset swap "$tmpset" "$WARP_IPSET" 2>/dev/null \
            || { _wlog "ipset swap failed — keeping previous set"; ipset destroy "$tmpset" 2>/dev/null; return 1; }
        ipset destroy "$tmpset" 2>/dev/null
        _wlog "warp ipset loaded: $(warp_ipset_count) entries"
    else
        _wlog "ipset restore failed — keeping previous set ($(warp_ipset_count) entries)"
        ipset destroy "$tmpset" 2>/dev/null
        return 1
    fi
}


# ---- устройства «всё в WARP» (B) ------------------------------------------------
# devices.txt: IPv4 или MAC по строке. MAC → IP через таблицу соседей; офлайн-
# устройство просто пропускается и подхватится следующим selfheal. Hostname —
# нет: это DNS-слой, которого у нас нет по решению владельца.
warp_devices_ips() {
    [ -s "$WARP_DEVICES_FILE" ] || return 0
    # Таблица соседей — переменной, не временным файлом: каталог для файла
    # (/tmp/z2k-warp) появляется только с первым стартом демона, и до него
    # весь список устройств молча терялся (ловилось CI, не глазами).
    # Одной строкой через «;»: многострочное значение в awk -v — ошибка
    # «newline in string» и у BSD awk, и у mawk.
    local neigh
    # Только IPv4: `ip neigh` без -4 отдаёт и fe80::… с тем же MAC, запись
    # перекрывала IPv4, в restore уезжал IPv6 для hash:ip inet — и весь поток
    # отвергался, сет оставался пустым («устройств: 0» при записанном MAC).
    neigh=$(ip -4 neigh show 2>/dev/null | awk '$0 ~ /lladdr/ {for (i=1;i<=NF;i++) if ($i=="lladdr") printf "%s %s;", tolower($(i+1)), $1}')
    awk -v neigh="$neigh" '
    BEGIN { n = split(neigh, lines, ";"); for (i = 1; i <= n; i++) { split(lines[i], f, " "); if (f[1] != "") mac[f[1]] = f[2] } }
    function ip_ok(s,  o) {
        if (s !~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) return 0
        split(s, o, "."); return (o[1] <= 255 && o[2] <= 255 && o[3] <= 255 && o[4] <= 255 && o[1] > 0)
    }
    {
        sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0 == "" || $0 ~ /^#/) next
        s = tolower($0); gsub(/-/, ":", s)
        if (s ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) { if ((s in mac) && ip_ok(mac[s])) print mac[s]; next }
        if (ip_ok($0)) print $0
    }' "$WARP_DEVICES_FILE"
}

warp_ipset_src_load() {
    local tmpset="${WARP_IPSET_SRC}_new"
    ipset create "$WARP_IPSET_SRC" hash:ip family inet 2>/dev/null
    ipset destroy "$tmpset" 2>/dev/null
    ipset create "$tmpset" hash:ip family inet 2>/dev/null
    warp_devices_ips | awk -v set="$tmpset" '{ print "add " set " " $0 " -exist" }' | ipset restore -exist 2>/dev/null
    ipset swap "$tmpset" "$WARP_IPSET_SRC" 2>/dev/null
    ipset destroy "$tmpset" 2>/dev/null
    return 0
}

warp_ipset_all() { warp_ipset_load; warp_ipset_src_load; }

# ---- маршрутизация --------------------------------------------------------------
warp_pbr_up() {
    local iface; iface=$(warp_iface)
    [ -n "$iface" ] || { _wlog "нет имени интерфейса в device.json"; return 1; }
    ip route replace default dev "$iface" table "$WARP_TABLE" 2>/dev/null
    ip rule show 2>/dev/null | grep -q "fwmark $WARP_MARK" \
        || ip rule add pref "$WARP_RULE_PREF" fwmark "$WARP_MARK/$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    local set
    for set in "$WARP_IPSET dst" "$WARP_IPSET_SRC src"; do
        # shellcheck disable=SC2086 # два аргумента, разбиение намеренно
        iptables -w -t mangle -C PREROUTING -m set --match-set $set -j MARK --set-xmark "$WARP_MARK/$WARP_MARK" 2>/dev/null \
            || iptables -w -t mangle -A PREROUTING -m set --match-set $set -j MARK --set-xmark "$WARP_MARK/$WARP_MARK" 2>/dev/null
    done
    return 0
}

warp_pbr_down() {
    # Обе формы и обе цепочки: --set-mark ставили до r-62, OUTPUT — ещё раньше;
    # на роутерах, переживших те версии, такие правила ещё лежат.
    local ch set mk
    for ch in PREROUTING OUTPUT; do
        for set in "$WARP_IPSET dst" "$WARP_IPSET_SRC src"; do
            for mk in "--set-xmark $WARP_MARK/$WARP_MARK" "--set-mark $WARP_MARK"; do
                # shellcheck disable=SC2086
                while iptables -w -t mangle -C "$ch" -m set --match-set $set -j MARK $mk 2>/dev/null; do
                    # shellcheck disable=SC2086
                    iptables -w -t mangle -D "$ch" -m set --match-set $set -j MARK $mk 2>/dev/null || break
                done
            done
        done
    done
    ip rule del fwmark "$WARP_MARK/$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    ip rule del fwmark "$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    ip route flush table "$WARP_TABLE" 2>/dev/null
}

# ---- установка / удаление -------------------------------------------------------
warp_arch() {
    local a
    a=$(grep -hoE 'mipselsf|mipsel|mips64el|mips64|mips|aarch64|armv7|armv5|x86_64|i[36]86' \
            /opt/etc/opkg.conf /opt/etc/opkg/*.conf 2>/dev/null | head -1)
    [ -n "$a" ] || a=$(uname -m)
    case "$a" in
        aarch64|arm64)      printf 'arm64' ;;
        mipselsf|mipsel)    printf 'mipsel' ;;
        mips)               grep -qiE 'system type.*MediaTek' /proc/cpuinfo 2>/dev/null && printf 'mipsel' || printf 'mips' ;;
        armv7*)             printf 'arm' ;;
        x86_64)             printf 'amd64' ;;
        *)                  printf '' ;;
    esac
}

# Ожидаемый sha256 бинаря из UPDATES.json (files_sha256) — тот же гейт, что у
# всех деливераблов; нет записи — качаем без сверки, но проверяем ELF и запуск.
warp_expected_sha() {
    local upd="$ZAPRET2_DIR/UPDATES.json"
    [ -f "$upd" ] || return 0
    sed -n "s/.*\"z2k-warpd\/builds\/z2k-warpd-linux-$1\"[[:space:]]*:[[:space:]]*\"\([0-9a-f]*\)\".*/\1/p" "$upd" | head -1
}

warp_fetch_engine() {
    local arch; arch=$(warp_arch)
    [ -n "$arch" ] || { _wlog "unsupported architecture"; return 1; }
    # WARP_FETCH_STUB — тесты: вместо скачивания копируется готовый файл.
    local tmp="$WARP_BIN.new.$$" want have
    rm -f "$tmp"
    if [ -n "$WARP_FETCH_STUB" ]; then
        cp "$WARP_FETCH_STUB" "$tmp"
    else
        want=$(warp_expected_sha "$arch")
        if [ -x "$WARP_BIN" ] && [ -n "$want" ] && command -v z2k_sha256_file >/dev/null 2>&1; then
            have=$(z2k_sha256_file "$WARP_BIN" 2>/dev/null)
            [ "$have" = "$want" ] && { _wlog "движок уже актуален ($arch)"; return 0; }
        fi
        local url="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}/z2k-warpd/builds/z2k-warpd-linux-$arch"
        # Прогресс — в stderr: это лог job'а в панели. Скачивание ~7 МБ на плохой
        # связи идёт минуты, и молчание выглядело как зависшая установка.
        _wlog "скачиваю движок ($arch, ~7 МБ) — на медленной связи до 3 минут..."
        if command -v z2k_fetch >/dev/null 2>&1; then
            z2k_fetch "$url" "$tmp" 2>/dev/null || curl -sSL --max-time 180 "$url" -o "$tmp"
        else
            curl -sSL --max-time 180 "$url" -o "$tmp"
        fi
        rm -f "$tmp.etag" 2>/dev/null
        [ -s "$tmp" ] && _wlog "скачано: $(wc -c < "$tmp" | tr -d ' ') байт, проверяю..."
        if [ -n "$want" ] && command -v z2k_sha256_file >/dev/null 2>&1; then
            have=$(z2k_sha256_file "$tmp" 2>/dev/null)
            [ "$have" = "$want" ] || { _wlog "sha256 mismatch for engine ($arch)"; rm -f "$tmp"; return 1; }
        fi
    fi
    [ -s "$tmp" ] || { _wlog "engine download failed"; rm -f "$tmp"; return 1; }
    if [ -z "$WARP_FETCH_STUB" ]; then
        head -c 4 "$tmp" 2>/dev/null | grep -q ELF || { _wlog "engine is not an ELF"; rm -f "$tmp"; return 1; }
    fi
    chmod 755 "$tmp"
    "$tmp" version >/dev/null 2>&1 || { _wlog "engine does not run on this architecture"; rm -f "$tmp"; return 1; }
    mkdir -p "$(dirname "$WARP_BIN")" 2>/dev/null
    mv -f "$tmp" "$WARP_BIN" || { rm -f "$tmp"; return 1; }
    _wlog "движок установлен: $WARP_BIN"
    return 0
}

warp_install() {
    warp_lists_migrate
    warp_fetch_engine || return 1
    # Регистрация: есть device.json — проверка, нет — новое устройство.
    # Напрямую (десинк nfqws2), затем через VPS-релей. Ничего не запускается.
    local out
    if [ -s "$WARP_DEVICE" ]; then
        _wlog "ключ устройства уже есть — проверяю у Cloudflare (новое устройство не создаётся)..."
    else
        _wlog "регистрирую устройство у Cloudflare (до минуты)..."
    fi
    if out=$("$WARP_BIN" register --device "$WARP_DEVICE" 2>&1); then
        _wlog "$out"; return 0
    fi
    _wlog "напрямую не вышло ($out) — пробую через релей..."
    if [ -n "$WARP_VPS_PROXY" ] && out=$("$WARP_BIN" register --device "$WARP_DEVICE" --proxy "$WARP_VPS_PROXY" 2>&1); then
        _wlog "через релей: $out"; return 0
    fi
    _wlog "${out:-register_blocked}"
    return 1
}

warp_enable() {
    warp_set_flag 1
    [ -x "$WARP_BIN" ] || { _wlog "движок не установлен — нажмите «Установить»"; warp_set_flag 0; return 1; }
    warp_ipset_all
    ipset list -n "$WARP_IPSET" >/dev/null 2>&1 || { _wlog "cannot create ipset $WARP_IPSET"; warp_set_flag 0; return 1; }
    warp_daemon_running || sh "$WARP_INIT" start >/dev/null 2>&1
    local waited=0
    while [ "$waited" -lt "$WARP_READY_WAIT" ]; do
        warp_ready && break
        sleep 2; waited=$((waited + 2))
    done
    if warp_ready; then
        warp_pbr_up
        _wlog "WARP ready: $(_json_str "$WARP_STATUS" transport) $(_json_str "$WARP_STATUS" endpoint)"
        return 0
    fi
    # Не ready — маршрут НЕ ставим (игровой ipset в мёртвый туннель = чёрная
    # дыра), флаг оставляем: движок продолжает лестницу, selfheal поставит маршрут.
    _wlog "причина: $(_json_str "$WARP_STATUS" last_error)"
    return 2
}

warp_disable() {
    warp_pbr_down
    [ -x "$WARP_INIT" ] && sh "$WARP_INIT" stop >/dev/null 2>&1
    warp_set_flag 0
    return 0
}

warp_remove() {
    warp_disable
    rm -f "$WARP_BIN" "$WARP_BIN".new.* 2>/dev/null
    ipset destroy "$WARP_IPSET" 2>/dev/null
    ipset destroy "$WARP_IPSET_SRC" 2>/dev/null
    _wlog "движок удалён; ключ устройства сохранён в $WARP_DEVICE"
    return 0
}

# ---- самолечение: маршрут по факту, а не по надежде -----------------------------
warp_selfheal() {
    [ "$(warp_flag)" = "1" ] || return 0
    [ -x "$WARP_BIN" ] || return 0
    warp_daemon_running || { sh "$WARP_INIT" start >/dev/null 2>&1; return 0; }
    if warp_ready; then
        ipset list -n "$WARP_IPSET" >/dev/null 2>&1 || warp_ipset_all
        warp_ipset_src_load      # MAC устройств могли появиться в neigh
        warp_pbr_up
    else
        warp_pbr_down            # fail open: напрямую лучше, чем в чёрную дыру
    fi
    return 0
}

warp_status() {
    local installed=0 ready=0
    [ -x "$WARP_BIN" ] && installed=1
    warp_ready && ready=1
    local entries devices
    entries=$(warp_ipset_count)
    devices=$(ipset list "$WARP_IPSET_SRC" 2>/dev/null | awk '/^Members:/{m=1;next} m&&NF{n++} END{print n+0}')
    printf 'installed=%s enabled=%s ready=%s transport=%s endpoint=%s iface=%s addr=%s entries=%s devices=%s error=%s\n' \
        "$installed" "${GAME_WARP_ENABLED_OVERRIDE:-$(warp_flag)}" "$ready" \
        "$(_json_str "$WARP_STATUS" transport)" "$(_json_str "$WARP_STATUS" endpoint)" \
        "$(_json_str "$WARP_STATUS" iface)" "$(_json_str "$WARP_STATUS" addr)" \
        "${entries:-0}" "${devices:-0}" "$(_json_str "$WARP_STATUS" last_error)"
}

# Зачистка usque-эпохи — по уликам, а не по имени, и пакет — один раз.
#
# Три класса следов:
#   1. Наши по имени: /opt/sbin/z2k-usque, session.conf/iface/addr в НАШЕМ
#      каталоге, стампы /opt/zapret2/.z2k-warp-*. Их не создаёт никто, кроме
#      старого z2k → сносим всегда, это идемпотентно.
#   2. Пакет usque-keenetic (S51usque, /opt/etc/usque). Его мог поставить и
#      старый z2k, и сам юзер — для своих целей. Сносим ТОЛЬКО при уликах,
#      что его принёс z2k: старый init снимал с S51usque бит исполнения
#      («z2k owns the tunnel now»), либо рядом лежат следы класса 1 (эпоха
#      r-61.x, когда пакет был движком напрямую). Чужой живой пакет — S51usque
#      с +x и без наших следов — не трогаем.
# Маркера нет намеренно: улики исчезают вместе с зачисткой (снятый бит — с
# S51usque, наши файлы — с собой), так что повторные прогоны чужой пакет не
# тронут по построению, а не по памяти.
warp_migrate_usque() {
    local ours=0
    [ -e "$WARP_LEGACY_BIN" ] && ours=1
    [ -e "$WARP_LEGACY_DIR/session.conf" ] || [ -e "$WARP_LEGACY_DIR/iface" ] && ours=1
    ls "$ZAPRET2_DIR"/.z2k-warp-* >/dev/null 2>&1 && ours=1
    [ -d "$ZAPRET2_DIR/warp" ] && ours=1
    # NDM-интерфейс старого туннеля (OpkgTunN с 172.16.x.x, `ip global`) живёт
    # в конфигурации Keenetic и переживает любую зачистку файлов. Имя наш
    # старый init записывал в iface — по нему и снимаем, чужие OpkgTunN не
    # трогаем. Сначала NDM, потом файл: иначе улика уйдёт раньше интерфейса.
    local legacy_if
    legacy_if=$(tr -d ' \n' < "$WARP_LEGACY_DIR/iface" 2>/dev/null)
    case "$legacy_if" in
        opkgtun[0-9]*)
            if command -v ndmc >/dev/null 2>&1; then
                LD_LIBRARY_PATH= ndmc -c "no interface $(echo "$legacy_if" | sed 's/^opkg/Opkg/; s/tun/Tun/')" >/dev/null 2>&1
                LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
                _wlog "NDM-интерфейс прежнего туннеля снят: $legacy_if"
            fi
            ;;
    esac
    # Класс 1 — всегда.
    [ -e "$WARP_LEGACY_BIN" ] && killall z2k-usque 2>/dev/null
    rm -f "$WARP_LEGACY_BIN" 2>/dev/null
    rm -f "$WARP_LEGACY_DIR/session.conf" "$WARP_LEGACY_DIR/session.conf.prev" "$WARP_LEGACY_DIR/session.alt.conf" \
          "$WARP_LEGACY_DIR/iface" "$WARP_LEGACY_DIR/addr" 2>/dev/null
    rm -f "$ZAPRET2_DIR"/.z2k-warp-* 2>/dev/null
    rm -rf "$ZAPRET2_DIR/warp" 2>/dev/null
    # Класс 2 — только по уликам.
    if [ -e "$WARP_LEGACY_INIT" ] && [ ! -x "$WARP_LEGACY_INIT" ]; then
        ours=1    # бит снимал наш старый init
    fi
    [ "$ours" = "1" ] || return 0
    rm -f "$WARP_LEGACY_INIT" 2>/dev/null
    if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -q '^usque'; then
        opkg remove usque-keenetic >/dev/null 2>&1 || opkg remove usque >/dev/null 2>&1
    fi
    _wlog "остатки прежнего WARP (usque) убраны"
    return 0
}

# Sourced by tests to exercise the functions with stubs — skip the dispatch.
[ -n "$Z2K_WARP_SOURCE_ONLY" ] && return 0

case "$1" in
    install)  warp_install ;;
    enable)   warp_enable ;;
    disable)  warp_disable ;;
    remove)   warp_remove ;;
    ipset)    warp_ipset_all ;;
    selfheal) warp_selfheal ;;
    status)   warp_status ;;
    migrate)  warp_lists_migrate; warp_migrate_usque ;;
    *) echo "usage: $0 {install|enable|disable|remove|ipset|selfheal|status|migrate}" >&2; exit 1 ;;
esac
