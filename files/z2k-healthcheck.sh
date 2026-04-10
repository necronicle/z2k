#!/bin/sh
# z2k-healthcheck.sh
# Проверка доступности сервисов, обходимых через zapret2/nfqws2.
# POSIX sh, совместим с OpenWrt/Keenetic (busybox ash).
#
# Использование:
#   z2k-healthcheck.sh              — интерактивная проверка
#   z2k-healthcheck.sh --cron       — режим для cron (без вывода, только лог/syslog)
#   z2k-healthcheck.sh --status     — показать текущий статус здоровья
#
# Коды возврата: 0=healthy, 1=degraded, 2=down

set -u

# ==============================================================================
# Настраиваемые URL для проверки (по категориям)
# ==============================================================================

# YouTube (TCP, основной сервис)
CHECK_YOUTUBE_URL="${CHECK_YOUTUBE_URL:-https://www.youtube.com}"
CHECK_YOUTUBE_NAME="YouTube"

# Discord (TCP + UDP/QUIC голос)
CHECK_DISCORD_URL="${CHECK_DISCORD_URL:-https://discord.com}"
CHECK_DISCORD_NAME="Discord"

# Telegram (TCP)
CHECK_TELEGRAM_URL="${CHECK_TELEGRAM_URL:-https://web.telegram.org}"
CHECK_TELEGRAM_NAME="Telegram"

# Общие RKN-блокированные ресурсы
CHECK_RKN_URL="${CHECK_RKN_URL:-https://rutracker.org}"
CHECK_RKN_NAME="RKN-blocked"

# ==============================================================================
# Пути и параметры
# ==============================================================================

ZAPRET_BASE="${ZAPRET_BASE:-/opt/zapret2}"
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
STATE_FILE="${ZAPRET_BASE}/extra_strats/cache/autocircular/state.tsv"
LOG_FILE="${ZAPRET_BASE}/healthcheck.log"
LOG_MAX_LINES=100

CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=10

# Имя процесса nfqws2
NFQWS_PROCESS="nfqws2"

# Порог для полного рестарта: сколько сервисов должно упасть
RESTART_THRESHOLD=2

# ==============================================================================
# Вспомогательные функции
# ==============================================================================

_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log() {
    # $1: уровень (INFO/WARN/ERR), $2: сообщение
    local level="$1"
    shift
    local msg="$*"
    local line
    line="$(_ts) [$level] $msg"

    # В файл лога
    if [ -w "$(dirname "$LOG_FILE")" ] || [ -w "$LOG_FILE" ]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null
        _rotate_log
    fi

    # В syslog
    case "$level" in
        ERR)  logger -t z2k-healthcheck -p daemon.err "$msg" 2>/dev/null ;;
        WARN) logger -t z2k-healthcheck -p daemon.warning "$msg" 2>/dev/null ;;
        *)    logger -t z2k-healthcheck -p daemon.info "$msg" 2>/dev/null ;;
    esac
}

_rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    local count
    count=$(wc -l < "$LOG_FILE" 2>/dev/null) || return 0
    if [ "$count" -gt "$LOG_MAX_LINES" ]; then
        local tmp
        tmp=$(mktemp "${LOG_FILE}.XXXXXX") || return 0
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$tmp" 2>/dev/null && \
            mv -f "$tmp" "$LOG_FILE" 2>/dev/null || rm -f "$tmp"
    fi
}

_print() {
    # Вывод только в интерактивном режиме
    [ "$MODE" = "interactive" ] && printf '%s\n' "$*"
}

# ==============================================================================
# Проверки
# ==============================================================================

# Проверить доступность URL через curl
# $1: URL, $2: имя сервиса
# Возвращает 0 при успехе, 1 при неудаче
check_url() {
    local url="$1"
    local name="$2"
    local http_code

    # Пробуем curl с коротким таймаутом
    if command -v curl >/dev/null 2>&1; then
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout "$CURL_CONNECT_TIMEOUT" \
            --max-time "$CURL_MAX_TIME" \
            -L "$url" 2>/dev/null) || http_code="000"
    else
        # Фоллбэк на wget (busybox)
        if wget -q -O /dev/null --timeout="$CURL_MAX_TIME" "$url" 2>/dev/null; then
            http_code="200"
        else
            http_code="000"
        fi
    fi

    case "$http_code" in
        2??|3??) return 0 ;;
        *)       return 1 ;;
    esac
}

# Проверить, запущен ли nfqws2
nfqws_running() {
    # pidof доступен в busybox
    if command -v pidof >/dev/null 2>&1; then
        pidof "$NFQWS_PROCESS" >/dev/null 2>&1 && return 0
    fi
    # Фоллбэк через ps + grep
    ps w 2>/dev/null | grep -q "[n]fqws2" && return 0
    ps 2>/dev/null | grep -q "[n]fqws2" && return 0
    return 1
}

# ==============================================================================
# Сброс autocircular state для категории
# ==============================================================================

# Удалить строки из state.tsv, содержащие ключевое слово категории
# $1: паттерн для grep -v (например "youtube\|yt_" или "discord")
clear_autocircular_state() {
    local pattern="$1"
    local name="$2"

    [ -f "$STATE_FILE" ] || return 0

    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX") || return 1
    grep -iv "$pattern" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    _log INFO "Cleared autocircular state for $name (pattern: $pattern)"
}

# Паттерны для категорий в state.tsv
pattern_for_service() {
    case "$1" in
        YouTube)     echo "youtube\|yt_\|yt " ;;
        Discord)     echo "discord" ;;
        Telegram)    echo "telegram\|tg_\|tg " ;;
        RKN-blocked) echo "rkn\|rutracker" ;;
        *)           echo "" ;;
    esac
}

# ==============================================================================
# Основная логика проверки
# ==============================================================================

run_checks() {
    local fail_count=0
    local fail_services=""
    local total=4
    local ok_count=0

    # Проверка nfqws2
    local nfqws_up=0
    if nfqws_running; then
        nfqws_up=1
        _print "  nfqws2: RUNNING"
    else
        _print "  nfqws2: NOT RUNNING"
        _log WARN "nfqws2 process is not running"
    fi

    # Проверки сервисов
    # Note: Telegram excluded — healthcheck curl would go through tunnel
    # and consume Cloudflare Worker free tier requests unnecessarily.
    for entry in \
        "${CHECK_YOUTUBE_URL}|${CHECK_YOUTUBE_NAME}" \
        "${CHECK_DISCORD_URL}|${CHECK_DISCORD_NAME}" \
        "${CHECK_RKN_URL}|${CHECK_RKN_NAME}" \
    ; do
        local url="${entry%%|*}"
        local name="${entry#*|}"

        if check_url "$url" "$name"; then
            _print "  $name ($url): OK"
            ok_count=$((ok_count + 1))
        else
            _print "  $name ($url): FAIL"
            _log WARN "Connectivity check failed: $name ($url)"
            fail_count=$((fail_count + 1))
            fail_services="${fail_services}${fail_services:+, }${name}"

            # Если nfqws2 запущен — сбросить autocircular state для этой категории
            if [ "$nfqws_up" = "1" ]; then
                local pattern
                pattern=$(pattern_for_service "$name")
                if [ -n "$pattern" ]; then
                    clear_autocircular_state "$pattern" "$name"
                fi
            fi
        fi
    done

    # Итоговый вердикт
    if [ "$fail_count" -eq 0 ] && [ "$nfqws_up" = "1" ]; then
        _log INFO "Health check passed: all $total services OK, nfqws2 running"
        _print ""
        _print "Status: HEALTHY (all $total services reachable)"
        return 0
    fi

    # Полный рестарт при множественных отказах (и если nfqws2 работает)
    if [ "$fail_count" -ge "$RESTART_THRESHOLD" ] && [ "$nfqws_up" = "1" ]; then
        _log ERR "Multiple services failed ($fail_services), restarting zapret2"
        _print ""
        _print "Multiple failures detected ($fail_services), restarting zapret2..."
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" restart >> "$LOG_FILE" 2>&1
            _log INFO "zapret2 restart completed (exit code: $?)"
        else
            _log ERR "Init script not found or not executable: $INIT_SCRIPT"
        fi
    fi

    # nfqws2 не запущен — весь DPI-обход недоступен
    if [ "$nfqws_up" = "0" ]; then
        _log ERR "nfqws2 is not running, DPI bypass is DOWN"
        _print ""
        _print "Status: DOWN (nfqws2 not running, $fail_count/$total services failed)"
        return 2
    fi

    # Частичная деградация
    if [ "$fail_count" -gt 0 ]; then
        _log WARN "Degraded: $fail_count/$total services failed ($fail_services)"
        _print ""
        _print "Status: DEGRADED ($fail_count/$total services failed: $fail_services)"
        return 1
    fi

    # nfqws2 не работает, но сервисы доступны (возможно, не нужен обход)
    _print ""
    _print "Status: DEGRADED (nfqws2 not running, but services reachable)"
    return 1
}

# ==============================================================================
# Режим --status: показать последние результаты из лога
# ==============================================================================

show_status() {
    echo "=== z2k Health Check Status ==="
    echo ""

    # Статус nfqws2
    if nfqws_running; then
        echo "nfqws2: RUNNING ($(pidof "$NFQWS_PROCESS" 2>/dev/null || echo "pid unknown"))"
    else
        echo "nfqws2: NOT RUNNING"
    fi

    # Файл state.tsv
    if [ -f "$STATE_FILE" ]; then
        local lines
        lines=$(wc -l < "$STATE_FILE" 2>/dev/null)
        echo "autocircular state: $STATE_FILE ($lines entries)"
    else
        echo "autocircular state: no state file"
    fi

    echo ""

    # Последние записи из лога
    if [ -f "$LOG_FILE" ]; then
        echo "--- Recent log (last 20 lines) ---"
        tail -n 20 "$LOG_FILE" 2>/dev/null
    else
        echo "No healthcheck log found ($LOG_FILE)"
    fi

    echo ""

    # Быстрая проверка прямо сейчас
    echo "--- Live check ---"
    MODE="interactive"
    run_checks
    return $?
}

# ==============================================================================
# Точка входа
# ==============================================================================

MODE="interactive"

case "${1:-}" in
    --cron)
        MODE="cron"
        run_checks
        exit $?
        ;;
    --status)
        show_status
        exit $?
        ;;
    --help|-h)
        cat <<EOF
Usage: $0 [--cron|--status|--help]

  (no args)   Interactive mode: check and print results
  --cron      Cron mode: no terminal output, log to file and syslog
  --status    Show current health status and recent log
  --help      Show this help

Check URLs (override via environment):
  CHECK_YOUTUBE_URL   (default: $CHECK_YOUTUBE_URL)
  CHECK_DISCORD_URL   (default: $CHECK_DISCORD_URL)
  CHECK_TELEGRAM_URL  (default: $CHECK_TELEGRAM_URL)
  CHECK_RKN_URL       (default: $CHECK_RKN_URL)

Exit codes: 0=healthy, 1=degraded, 2=down
Log: $LOG_FILE (max $LOG_MAX_LINES lines, auto-rotated)
EOF
        exit 0
        ;;
    "")
        echo "=== z2k Health Check ==="
        echo ""
        run_checks
        exit $?
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: $0 [--cron|--status|--help]" >&2
        exit 1
        ;;
esac
