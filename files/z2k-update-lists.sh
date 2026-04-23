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
    esac

    if curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$url" 2>/dev/null; then
        return 0
    fi
    if [ -n "$jsdelivr" ] && \
       curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$jsdelivr" 2>/dev/null; then
        return 0
    fi
    if [ -n "$gh_proxy" ] && \
       curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$gh_proxy" 2>/dev/null; then
        return 0
    fi

    if command -v ndmc >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
        local resolved_any=0 host ip
        for host in raw.githubusercontent.com cdn.jsdelivr.net api.github.com; do
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
            if [ -n "$jsdelivr" ] && \
               curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$jsdelivr" 2>/dev/null; then
                return 0
            fi
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

    # Phase 12: domain lists (RKN / Discord / YouTube TCP / YouTube QUIC)
    # are now pulled from runetfreedom/russia-blocked-geosite release
    # assets via z2k-geosite.sh. ETag-aware, RAM-adaptive RKN variant,
    # atomic rename, sub-80% size guard. The old GitHub raw fetches
    # from necronicle/z2k shipped snapshots are retired; they remain
    # as first-install fallback via lib/install.sh step_download_domain_lists.
    if [ -x "${ZAPRET2_DIR}/z2k-geosite.sh" ]; then
        log_msg "Running z2k-geosite fetch (runetfreedom)..."
        if sh "${ZAPRET2_DIR}/z2k-geosite.sh" fetch >>"$LOG_FILE" 2>&1; then
            # z2k-geosite handles atomic rename + service-safe writes;
            # count a change whenever at least one asset was applied.
            # ETag cache makes 304-only runs a no-op, so we approximate
            # "something changed" by checking log for "applied" markers.
            if tail -30 "$LOG_FILE" | grep -q ': applied,'; then
                changes=$((changes + 1))
                log_msg "geosite: applied changes detected"
            else
                log_msg "geosite: all assets unchanged (ETag match)"
            fi
        else
            log_msg "WARN: geosite fetch partial/failed"
        fi
    else
        log_msg "z2k-geosite.sh missing, skipping list refresh"
    fi

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
