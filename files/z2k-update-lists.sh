#!/bin/sh
# z2k-update-lists.sh - Автоматическое обновление списков доменов
# Предназначен для вызова из cron: 0 4 * * * sh /opt/zapret2/z2k-update-lists.sh
#
# При обнаружении изменений автоматически перезапускает сервис.

ZAPRET2_DIR="/opt/zapret2"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
LOG_FILE="${ZAPRET2_DIR}/update-lists.log"
MAX_LOG_LINES=200

GITHUB_RAW="https://raw.githubusercontent.com/necronicle/z2k/master"

# ==============================================================================
# z2k_fetch — загрузка файла с GitHub через цепочку зеркал.
# ==============================================================================
# Дублирует логику z2k.sh / lib/utils.sh для standalone cron-запуска (этот
# скрипт не source'ит utils.sh). Слои: raw.github → jsdelivr → gh-proxy →
# Keenetic DNS override через 8.8.8.8 + ndmc.
z2k_fetch() {
    local src="$1"
    local dest="$2"
    local url

    case "$src" in
        http://*|https://*) url="$src" ;;
        /*) url="${GITHUB_RAW}${src}" ;;
        *)  url="${GITHUB_RAW}/${src}" ;;
    esac

    local jsdelivr="" gh_proxy=""
    case "$url" in
        https://raw.githubusercontent.com/*)
            local _rest="${url#https://raw.githubusercontent.com/}"
            local _owner="${_rest%%/*}";  _rest="${_rest#*/}"
            local _repo="${_rest%%/*}";   _rest="${_rest#*/}"
            local _branch="${_rest%%/*}"; _rest="${_rest#*/}"
            jsdelivr="https://cdn.jsdelivr.net/gh/${_owner}/${_repo}@${_branch}/${_rest}"
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
        https://github.com/*/releases/download/*)
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
    esac

    if curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$url" 2>/dev/null; then
        return 0
    fi
    rm -f "$dest"
    if [ -n "$jsdelivr" ] && \
       curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$jsdelivr" 2>/dev/null; then
        return 0
    fi
    rm -f "$dest"
    if [ -n "$gh_proxy" ] && \
       curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$gh_proxy" 2>/dev/null; then
        return 0
    fi
    rm -f "$dest"

    if command -v ndmc >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
        local resolved_any=0 host ip
        for host in raw.githubusercontent.com cdn.jsdelivr.net gh-proxy.com api.github.com \
                    github.com objects.githubusercontent.com release-assets.githubusercontent.com; do
            ip=$(nslookup "$host" 8.8.8.8 2>/dev/null \
                 | awk '/^Name:/ {s=1; next} s && /^Address [0-9]+: [0-9]+\./ {print $3; exit}')
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "8.8.8.8" ]; then
                ndmc -c "ip host $host $ip" >/dev/null 2>&1 && resolved_any=1
            fi
        done
        if [ "$resolved_any" = "1" ]; then
            sleep 1
            if curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$url" 2>/dev/null; then
                return 0
            fi
            rm -f "$dest"
            if [ -n "$jsdelivr" ] && \
               curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$jsdelivr" 2>/dev/null; then
                return 0
            fi
            rm -f "$dest"
            if [ -n "$gh_proxy" ] && \
               curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$gh_proxy" 2>/dev/null; then
                return 0
            fi
            rm -f "$dest"
        fi
    fi

    return 1
}

# ==============================================================================
# ЛОГИРОВАНИЕ
# ==============================================================================

log_msg() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null

    # Ротация лога
    if [ -f "$LOG_FILE" ]; then
        local lines
        lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            local tmp
            tmp=$(mktemp "${LOG_FILE}.XXXXXX") || return
            tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "$tmp" 2>/dev/null
            mv -f "$tmp" "$LOG_FILE" 2>/dev/null || rm -f "$tmp"
        fi
    fi
}

# ==============================================================================
# ОБНОВЛЕНИЕ СПИСКОВ
# ==============================================================================

update_list() {
    local name=$1
    local url=$2
    local dest=$3

    if [ -z "$url" ] || [ -z "$dest" ]; then
        return 1
    fi

    local tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1

    if ! z2k_fetch "$url" "$tmp"; then
        log_msg "FAIL: download $name from $url (all mirrors failed)"
        rm -f "$tmp"
        return 1
    fi

    # Проверить что файл не пустой
    if [ ! -s "$tmp" ]; then
        log_msg "FAIL: $name is empty"
        rm -f "$tmp"
        return 1
    fi

    # Убрать CRLF
    sed -i 's/\r$//' "$tmp" 2>/dev/null

    # Сравнить с текущим
    if [ -f "$dest" ]; then
        local old_hash new_hash
        if command -v md5sum >/dev/null 2>&1; then
            old_hash=$(md5sum "$dest" 2>/dev/null | awk '{print $1}')
            new_hash=$(md5sum "$tmp" 2>/dev/null | awk '{print $1}')
        else
            old_hash=$(wc -c < "$dest" 2>/dev/null)
            new_hash=$(wc -c < "$tmp" 2>/dev/null)
        fi

        if [ "$old_hash" = "$new_hash" ]; then
            rm -f "$tmp"
            return 0  # Без изменений
        fi
    fi

    # Обновить
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    mv -f "$tmp" "$dest"
    log_msg "OK: $name updated ($(wc -l < "$dest") lines)"
    return 2  # Код 2 = есть изменения
}

# ==============================================================================
# ОСНОВНОЙ ПРОЦЕСС
# ==============================================================================

main() {
    # Убедиться что директория для логов существует
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

    log_msg "--- Update lists started ---"

    local changes=0

    # RKN список
    update_list "RKN" \
        "${GITHUB_RAW}/files/lists/extra_strats/TCP/RKN/List.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    # Discord
    update_list "Discord" \
        "${GITHUB_RAW}/files/lists/extra_strats/TCP/RKN/Discord.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/RKN/Discord.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    # YouTube TCP
    update_list "YouTube TCP" \
        "${GITHUB_RAW}/files/lists/extra_strats/TCP/YT/List.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/YT/List.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    # YouTube UDP/QUIC
    update_list "YouTube QUIC" \
        "${GITHUB_RAW}/files/lists/extra_strats/UDP/YT/List.txt" \
        "${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    # Roblox IPs (legacy path — kept for rollback safety, new installs use game_ips.txt)
    update_list "Roblox IPs" \
        "${GITHUB_RAW}/files/lists/roblox_ips.txt" \
        "${ZAPRET2_DIR}/lists/roblox_ips.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    # Game IPs (Roblox AS22697 — used as positive --ipset by the game UDP profile)
    update_list "Game IPs" \
        "${GITHUB_RAW}/files/lists/game_ips.txt" \
        "${ZAPRET2_DIR}/lists/game_ips.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    if [ "$changes" -gt 0 ]; then
        log_msg "Changes detected ($changes lists), restarting service..."
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" restart 2>/dev/null
            if [ $? -eq 0 ]; then
                log_msg "Service restarted successfully"
            else
                log_msg "FAIL: Service restart failed"
            fi
        fi
    else
        log_msg "No changes detected"
    fi

    log_msg "--- Update lists finished ---"
}

main "$@"
