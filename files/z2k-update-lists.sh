#!/bin/sh
# z2k-update-lists.sh - Автоматическое обновление списков доменов
# Предназначен для вызова из cron: 0 4 * * * sh /opt/zapret2/z2k-update-lists.sh
#
# При обнаружении изменений автоматически перезапускает сервис.

ZAPRET2_DIR="/opt/zapret2"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
LOG_FILE="${ZAPRET2_DIR}/update-lists.log"
MAX_LOG_LINES=200

# GITHUB_RAW is resolved in this order:
#   1. Explicit env var (useful for manual overrides and testing)
#   2. Z2K_GITHUB_RAW from /opt/zapret2/config (persisted at install time)
#   3. master branch default
# This means clean installs from a non-master branch (e.g. z2k-enhanced
# during feature testing) continue pulling domain lists from the SAME
# branch via cron, instead of silently drifting back to master.
if [ -z "${GITHUB_RAW:-}" ] && [ -r "${ZAPRET2_DIR}/config" ]; then
    _persisted_raw=$(grep '^Z2K_GITHUB_RAW=' "${ZAPRET2_DIR}/config" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//')
    [ -n "$_persisted_raw" ] && GITHUB_RAW="$_persisted_raw"
fi
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}"

# Настройки
CURL_OPTS="--connect-timeout 10 --max-time 60 -fsSL"

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

    if ! curl $CURL_OPTS "$url" -o "$tmp" 2>/dev/null; then
        log_msg "FAIL: download $name from $url"
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

    # Geosite — opt-in via GEOSITE_ENABLED=1 in /opt/zapret2/config. When
    # enabled, refresh v2fly/domain-list-community staging files under
    # ${ZAPRET2_DIR}/files/lists/extra_strats/GEO/. This does NOT replace
    # any existing production lists in Phase 2 — it only writes staging
    # data that Phase 3 (webpanel) will expose for opt-in consumption.
    local geosite_enabled
    geosite_enabled=$(grep -E '^GEOSITE_ENABLED=' "${ZAPRET2_DIR}/config" 2>/dev/null \
        | tail -1 | sed 's/^GEOSITE_ENABLED=//' | tr -d '"' 2>/dev/null)
    if [ "$geosite_enabled" = "1" ] && [ -x "${ZAPRET2_DIR}/z2k-geosite.sh" ]; then
        log_msg "Geosite enabled — refreshing staging lists..."
        if sh "${ZAPRET2_DIR}/z2k-geosite.sh" fetch >>"$LOG_FILE" 2>&1; then
            log_msg "Geosite refresh OK"
        else
            log_msg "WARN: geosite refresh failed (see log)"
        fi
    fi

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
