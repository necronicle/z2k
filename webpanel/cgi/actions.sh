#!/bin/sh
# z2k webpanel — action handlers.
# Each function mirrors exactly what the corresponding menu_* function in
# lib/menu.sh does, minus the interactive printf/read/pause layer.
# Sourced from api.sh. All functions return 0 on success, non-zero on error
# and write a single-line error to stderr (captured by the caller into JSON).

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_DIR="${CONFIG_DIR:-/opt/etc/zapret2}"
LISTS_DIR="${LISTS_DIR:-$ZAPRET2_DIR/lists}"
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"
WHITELIST_FILE="${WHITELIST_FILE:-$LISTS_DIR/whitelist.txt}"
EXTRA_DOMAINS_FILE="${EXTRA_DOMAINS_FILE:-$LISTS_DIR/extra-domains.txt}"

# --- read helpers (POSIX sh, no sourcing of lib/utils.sh required) ---

read_flag() {
    # read_flag <key> <file> [default]
    local key="$1" file="$2" def="${3:-0}"
    [ -f "$file" ] || { printf '%s' "$def"; return 0; }
    local raw val
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -1)
    if [ -z "$raw" ]; then
        printf '%s' "$def"
        return 0
    fi
    val=$(printf '%s' "$raw" | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')
    # An empty value (e.g. `DROP_DPI_RST=` with nothing after the equals)
    # must fall back to the default, not propagate as "" — otherwise the
    # caller's printf emits `"key":,` which breaks JSON. Caught in the wild
    # on Владислав's router 2026-04-15 after a reinstall left DROP_DPI_RST
    # with no value.
    [ -z "$val" ] && val="$def"
    printf '%s' "$val"
}

set_flag() {
    # set_flag <key> <value> <file>
    local key="$1" val="$2" file="$3"
    [ -f "$file" ] || { echo "file not found: $file" >&2; return 1; }
    if grep -q "^${key}=" "$file"; then
        sed -i "s/^${key}=.*/${key}=${val}/" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

is_installed() {
    [ -d "$ZAPRET2_DIR" ] && [ -x "$ZAPRET2_DIR/nfq2/nfqws2" ]
}

is_running() {
    pgrep -f "nfqws2" >/dev/null 2>&1
}

service_status_string() {
    if is_running; then
        echo "active"
    elif is_installed; then
        echo "stopped"
    else
        echo "not_installed"
    fi
}

regenerate_config() {
    # Source BOTH utils.sh (for safe_config_read and helpers) and
    # config_official.sh (for create_official_config). Without utils.sh,
    # safe_config_read is undefined → every saved_* variable becomes "" →
    # the heredoc emits empty-value flags → toggle never sticks. This was
    # the root cause of the game-mode toggle bug (2026-04-16).
    local utils="" lib=""
    for d in "$ZAPRET2_DIR/lib" /tmp/z2k/lib; do
        [ -f "$d/utils.sh" ] && [ -z "$utils" ] && utils="$d/utils.sh"
        [ -f "$d/config_official.sh" ] && [ -z "$lib" ] && lib="$d/config_official.sh"
    done
    [ -z "$lib" ] && { echo "config_official.sh not found" >&2; return 1; }
    # shellcheck disable=SC1090
    [ -n "$utils" ] && . "$utils"
    # shellcheck disable=SC1090
    . "$lib"
    create_official_config "$CONFIG_FILE" >/dev/null 2>&1
    return $?
}

restart_service_if_running() {
    if is_running; then
        # Output goes to caller's stdout/stderr — svc_action_async
        # tees those into the job log so UI shows live progress.
        ensure_init_exec
        "$INIT_SCRIPT" restart 2>&1 || true
    else
        echo "Сервис не запущен — пропускаю restart"
    fi
}

# --- service control ---
# Output не silenced — caller (svc_action_async) подхватывает stdout/stderr
# и пишет в job-log для UI live-polling'а.

# Self-heal the init script's executable bit before invoking it. p-42 shipped
# S99zapret2 via the patch path, which could drop +x on some BusyBox builds
# ("/opt/etc/init.d/S99zapret2: Permission denied", rc 126) — chmod here so a
# webpanel start/stop/restart recovers even on a router not yet reinstalled.
ensure_init_exec() { [ -f "$INIT_SCRIPT" ] && chmod +x "$INIT_SCRIPT" 2>/dev/null; return 0; }
svc_start()   { ensure_init_exec; "$INIT_SCRIPT" start   2>&1; }
svc_stop()    { ensure_init_exec; "$INIT_SCRIPT" stop    2>&1; }
svc_restart() { ensure_init_exec; "$INIT_SCRIPT" restart 2>&1; }

# --- async job launcher ---
#
# Запускает любую shell-команду в фоне с tee всех её stdout/stderr в
# /tmp/z2k-job-<id>.log (тот же путь который job_log endpoint раздаёт).
# Возвращает job_id. Frontend получает id, открывает openJobModal с
# live-polling /job?id=...
#
# Закрытие stdin/stdout/stderr (</dev/null >/dev/null 2>&1 на subshell)
# критично — без этого lighttpd не финализирует HTTP-ответ пока хоть
# один наследник держит fd 1/2. Внутреннее `>> log 2>&1` уже после
# наследования /dev/null заменяет fd на лог.
#
# Использование:
#   job_id=$(svc_action_async "Перезапуск сервиса" "/opt/etc/init.d/S99zapret2 restart")
svc_action_async() {
    local label="$1"; shift
    local cmd="$*"
    local job_id
    job_id=$(date +%s)$$
    local log="/tmp/z2k-job-${job_id}.log"
    (
        printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$label" > "$log"
        printf '─────────────────────────────────────────\n' >> "$log"
        eval "$cmd" >> "$log" 2>&1
        local rc=$?
        printf '─────────────────────────────────────────\n' >> "$log"
        if [ "$rc" = "0" ]; then
            printf '[%s] Готово ✓\n' "$(date '+%H:%M:%S')" >> "$log"
        else
            printf '[%s] Завершено с кодом %s\n' "$(date '+%H:%M:%S')" "$rc" >> "$log"
        fi
        echo "$rc" > "/tmp/z2k-job-${job_id}.exit"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "/tmp/z2k-job-${job_id}.pid"
    printf '%s' "$job_id"
}

# --- toggles ---
#
# Each toggle reads the current flag, sets the new value, optionally regenerates
# NFQWS2_OPT via create_official_config (only for toggles that affect it), and
# restarts the running service. Idempotent — setting the same value twice is a no-op.

toggle_rst_filter() {
    # Переключаем nfqws C-level RST_FILTER (нашa реализация в fork'е,
    # branch feat/rst-filter — 3 эвристики drop'a fake DPI RST'ов:
    # pre-response RST, multi-RST burst, TTL fingerprint mismatch).
    # Раньше тут стоял DROP_DPI_RST (iptables xt_u32) — устаревший, фейлил
    # на Keenetic без kmod-ipt-u32. RST_FILTER не требует kmod, работает на
    # уровне nfqws. config_official.sh подхватит RST_FILTER при regenerate.
    local want="$1"
    set_flag "RST_FILTER" "$want" "$CONFIG_FILE" || return 1
    regenerate_config
    restart_service_if_running
}

toggle_silent_fallback() {
    local want="$1"
    set_flag "RKN_SILENT_FALLBACK" "$want" "$CONFIG_FILE" || return 1
    # Flag file consumed by autocircular machinery, mirrors menu_rkn_silent_fallback.
    local flag_file="$ZAPRET2_DIR/extra_strats/cache/autocircular/rkn_silent_fallback.flag"
    if [ "$want" = "1" ]; then
        mkdir -p "$(dirname "$flag_file")" 2>/dev/null
        touch "$flag_file" 2>/dev/null
    else
        rm -f "$flag_file" 2>/dev/null
    fi
    regenerate_config
    restart_service_if_running
}

toggle_game_mode() {
    local want="$1"
    set_flag "ROBLOX_UDP_BYPASS" "$want" "$CONFIG_FILE" || return 1
    set_flag "GAME_MODE_ENABLED" "$want" "$CONFIG_FILE" || return 1
    regenerate_config
    restart_service_if_running
}

toggle_customd() {
    # Note: 1 = ENABLED, 0 = DISABLED in our API; the config flag is
    # DISABLE_CUSTOM which is the INVERSE. We flip here so the web UI
    # stays consistent with "on = feature active".
    local want="$1"
    if [ "$want" = "0" ]; then
        # DISABLING. The firewall unapply (S99zapret2 stop -> zapret_unapply_firewall
        # -> custom_runner zapret_custom_firewall 0) is what removes the custom.d
        # NFQUEUE rules (qnum 65300/65301). But custom_runner early-returns once
        # DISABLE_CUSTOM=1, so flipping the flag FIRST (then restart) leaves those
        # rules ORPHANED in POSTROUTING — they keep shadowing the main profiles
        # (Discord voice stayed broken even after "disabling"). So: stop while the
        # flag is still 0 (clean teardown of custom daemons + firewall), THEN flip,
        # THEN start.
        ensure_init_exec
        local _running=0
        is_running && _running=1
        [ "$_running" = "1" ] && "$INIT_SCRIPT" stop 2>&1
        set_flag "DISABLE_CUSTOM" "1" "$CONFIG_FILE" || return 1
        [ "$_running" = "1" ] && "$INIT_SCRIPT" start 2>&1
    else
        set_flag "DISABLE_CUSTOM" "0" "$CONFIG_FILE" || return 1
        restart_service_if_running
    fi
}

toggle_dynamic_ttl() {
    # Z2K_DYNAMIC_TTL — feature flag for NDM TTL bypass injection in
    # NFQWS2_OPT. Mobile operators (МТС/Билайн) detect tethering via TTL
    # decrement; we counter-inject a fresh TTL. Some users with explicit
    # NDM TTL-fix turn it off (Z2K_DYNAMIC_TTL=0). Default = 1.
    local want="$1"
    set_flag "Z2K_DYNAMIC_TTL" "$want" "$CONFIG_FILE" || return 1
    regenerate_config
    restart_service_if_running
}

toggle_stats() {
    # Z2K_STATS — anonymized strategy telemetry to the project VPS (default 1).
    # Out-of-band: it does NOT affect NFQWS2_OPT and is read fresh by
    # z2k-stats-upload.sh each daily run, so neither a config regen nor a
    # service restart is needed — just flip the flag.
    local want="$1"
    set_flag "Z2K_STATS" "$want" "$CONFIG_FILE" || return 1
}

# --- policy access (Keenetic NDM ip policy filter) ---

# policy_exists <name>: returns 0 if a Keenetic IP policy с description = <name>
# существует, иначе 1. Reuse тот же awk parser что в S99zapret2.new.
policy_exists() {
    local name="$1"
    [ -z "$name" ] && return 1
    local ndmc_bin="ndmc"
    [ -x /bin/ndmc ] && ndmc_bin="/bin/ndmc"
    "$ndmc_bin" -c "show ip policy" 2>/dev/null | awk -v want="$(printf '%s' "$name" | tr 'A-Z' 'a-z')" '
        function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
        function unquote(s) { s=trim(s); if (s ~ /^".*"$/) { sub(/^"/, "", s); sub(/"$/, "", s) } return s }
        function strip_colon(s) { sub(/:+$/, "", s); return s }
        BEGIN { want = strip_colon(want); found = 0 }
        /description[ \t]*=/ {
            desc = $0
            sub(/.*description[ \t]*=[ \t]*/, "", desc)
            desc = strip_colon(tolower(unquote(desc)))
            if (desc == want) { found = 1; exit }
        }
        END { exit (found ? 0 : 1) }
    '
}

policy_status() {
    # Stdout-эмиссия для api.sh: "name=...|exclude=...|exists=0|1".
    local name exclude exists
    name=$(read_flag "POLICY_NAME" "$CONFIG_FILE" "nfqws")
    exclude=$(read_flag "POLICY_EXCLUDE" "$CONFIG_FILE" "0")
    if policy_exists "$name"; then exists=1; else exists=0; fi
    printf 'name=%s|exclude=%s|exists=%s\n' "$name" "$exclude" "$exists"
}

policy_save() {
    local name="$1" exclude="$2"
    # Имя validation: 1-32 chars, [A-Za-z0-9_-]. Пустое разрешено = выключить
    # фильтр (config_official.sh fallback на nfqws default).
    case "$name" in
        '') name="" ;;
        *[!A-Za-z0-9_-]*) echo "invalid policy name" >&2; return 1 ;;
    esac
    if [ -n "$name" ] && [ ${#name} -gt 32 ]; then
        echo "policy name too long" >&2; return 1
    fi
    case "$exclude" in
        0|1) ;;
        *) echo "invalid exclude value" >&2; return 1 ;;
    esac
    set_flag "POLICY_NAME" "$name" "$CONFIG_FILE" || return 1
    set_flag "POLICY_EXCLUDE" "$exclude" "$CONFIG_FILE" || return 1
    regenerate_config
    restart_service_if_running
}

# --- whitelist ---

whitelist_list() {
    [ -f "$WHITELIST_FILE" ] || { echo ""; return 0; }
    grep -vE '^[[:space:]]*(#|$)' "$WHITELIST_FILE"
}

whitelist_add() {
    local domain="$1"
    # Basic sanity: lowercase letters/digits/.-, no spaces, no shell metachars.
    # Reject leading `-` defensively — no legitimate hostname starts with one
    # and any shell-out path would treat it as an option flag.
    case "$domain" in
        ''|*' '*|*$'\t'*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    mkdir -p "$LISTS_DIR" 2>/dev/null
    touch "$WHITELIST_FILE" 2>/dev/null
    if grep -qxF "$domain" "$WHITELIST_FILE"; then
        return 0  # idempotent
    fi
    printf '%s\n' "$domain" >> "$WHITELIST_FILE"
    # nfqws2 runs as nobody (uid 65534) and must be able to read the file.
    chmod 644 "$WHITELIST_FILE" 2>/dev/null || true
    # NB: НЕ рестартим сервис — whitelist подхватывается live, как и extra-domains
    # (feedback_no_service_restart_for_hostlist).
}

whitelist_import() {
    # Bulk merge — читает многострочный список доменов из stdin (TXT файл).
    # Per-line: trim CR/spaces, skip empty/comments (#), lowercase, validate.
    # Dedup vs existing whitelist через sort + comm. Append only new entries.
    # Single service restart в конце (а не на каждый домен).
    # Output: "added=N skipped_dup=N skipped_invalid=N" на stdout.
    local skipped_invalid=0
    mkdir -p "$LISTS_DIR" 2>/dev/null
    touch "$WHITELIST_FILE" 2>/dev/null

    local tmpnew tmpexisting tmpnewuniq tmpadd
    tmpnew=$(mktemp) || { echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }
    tmpexisting=$(mktemp) || { rm -f "$tmpnew"; echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }
    tmpnewuniq=$(mktemp) || { rm -f "$tmpnew" "$tmpexisting"; echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }
    tmpadd=$(mktemp) || { rm -f "$tmpnew" "$tmpexisting" "$tmpnewuniq"; echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }

    local line domain
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"           # strip CRLF
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        domain=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
        case "$domain" in
            -*|*' '*|*$'\t'*) skipped_invalid=$((skipped_invalid + 1)); continue ;;
            *[!a-z0-9.-]*)    skipped_invalid=$((skipped_invalid + 1)); continue ;;
        esac
        printf '%s\n' "$domain" >> "$tmpnew"
    done

    sort -u "$tmpnew" > "$tmpnewuniq"
    grep -vE '^[[:space:]]*(#|$)' "$WHITELIST_FILE" | sort -u > "$tmpexisting"
    # busybox `comm` ненадёжен (Input/output error на Entware) — используем awk:
    # NR==FNR проходит первым существующий список, marks each in `e[]`;
    # затем по новому списку печатает только те которые НЕ в `e[]`.
    awk 'NR==FNR { e[$0]=1; next } !e[$0]' "$tmpexisting" "$tmpnewuniq" > "$tmpadd"
    local added skipped_dup
    added=$(wc -l < "$tmpadd" | tr -d ' ')
    skipped_dup=$(awk 'NR==FNR { e[$0]=1; next } e[$0]' "$tmpexisting" "$tmpnewuniq" | wc -l | tr -d ' ')

    if [ "$added" -gt 0 ]; then
        cat "$tmpadd" >> "$WHITELIST_FILE"
        chmod 644 "$WHITELIST_FILE" 2>/dev/null || true
        # NB: НЕ рестартим — whitelist live.
    fi

    rm -f "$tmpnew" "$tmpexisting" "$tmpnewuniq" "$tmpadd"
    printf 'added=%d skipped_dup=%d skipped_invalid=%d\n' "$added" "$skipped_dup" "$skipped_invalid"
}

whitelist_delete() {
    local domain="$1"
    [ -f "$WHITELIST_FILE" ] || return 0
    case "$domain" in
        ''|*' '*|*$'\t'*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    if ! grep -qxF "$domain" "$WHITELIST_FILE"; then
        return 0  # idempotent
    fi
    # In-place rewrite via temp file — preserve original permissions/owner
    # by never replacing the inode with mktemp's default 600-mode file.
    local tmp="$WHITELIST_FILE.z2k-new"
    grep -vxF "$domain" "$WHITELIST_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$WHITELIST_FILE"
    rm -f "$tmp"
    chmod 644 "$WHITELIST_FILE" 2>/dev/null || true
    # NB: НЕ рестартим — whitelist live (см. whitelist_add).
}

# --- extra-domains ---
# Live hostlist для autocircular. Подхватывается сервисом без рестарта
# (memory feedback_no_service_restart_for_hostlist). Если файл редактируют
# вручную или через webpanel — z2k увидит изменения в течение нескольких
# секунд через файловый poll.

extra_domains_list() {
    [ -f "$EXTRA_DOMAINS_FILE" ] || { echo ""; return 0; }
    grep -vE '^[[:space:]]*(#|$)' "$EXTRA_DOMAINS_FILE"
}

extra_domains_add() {
    local domain="$1"
    case "$domain" in
        ''|*' '*|*$'\t'*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    # Lowercase + strip trailing dot (как делает normalize_hostkey_for_state
    # в lua, чтобы UI consistent).
    domain=$(printf '%s' "$domain" | tr 'A-Z' 'a-z')
    domain="${domain%.}"
    [ -z "$domain" ] && { echo "invalid domain" >&2; return 1; }
    mkdir -p "$LISTS_DIR" 2>/dev/null
    touch "$EXTRA_DOMAINS_FILE" 2>/dev/null
    if grep -qxF "$domain" "$EXTRA_DOMAINS_FILE"; then
        return 0  # idempotent
    fi
    printf '%s\n' "$domain" >> "$EXTRA_DOMAINS_FILE"
    chmod 644 "$EXTRA_DOMAINS_FILE" 2>/dev/null || true
    # NB: НЕ рестартим сервис — extra-domains.txt подхватывается live.
}

extra_domains_delete() {
    local domain="$1"
    [ -f "$EXTRA_DOMAINS_FILE" ] || return 0
    case "$domain" in
        ''|*' '*|*$'\t'*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    domain=$(printf '%s' "$domain" | tr 'A-Z' 'a-z')
    domain="${domain%.}"
    [ -z "$domain" ] && { echo "invalid domain" >&2; return 1; }
    if ! grep -qxF "$domain" "$EXTRA_DOMAINS_FILE"; then
        return 0  # idempotent
    fi
    local tmp="$EXTRA_DOMAINS_FILE.z2k-new"
    grep -vxF "$domain" "$EXTRA_DOMAINS_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$EXTRA_DOMAINS_FILE"
    rm -f "$tmp"
    chmod 644 "$EXTRA_DOMAINS_FILE" 2>/dev/null || true
    # NB: НЕ рестартим сервис.
}

# --- tunnel (Telegram) ---

tunnel_pid() {
    # Match by cmdline contains `--listen=:1443` — S97z2k-http-tunnel
    # уs eventually runs the SAME tg-mtproxy-client binary but with
    # `--listen=:1444` (cdnbase tunnel). Без фильтра `pgrep -f tg-mtproxy-client`
    # сматчит S97 sibling и /status report'ит tg-tunnel.running=true даже
    # когда S98 daemon реально остановлен. Field-bug 2026-05-24 (юзер
    # отключал TG-туннель, badge показывал «ВКЛЮЧЁН»).
    pgrep -f "tg-mtproxy-client .*--listen=:1443" 2>/dev/null | head -1
}

tunnel_enable() {
    # Clear user-disabled flag before starting so the watchdog resumes
    # auto-restarting on real crashes.
    local cfg="${ZAPRET2_DIR}/config"
    if [ -f "$cfg" ]; then
        if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg"; then
            echo "Снимаю флаг TG_PROXY_USER_DISABLED → 0 в /opt/zapret2/config"
            sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=0/' "$cfg"
        fi
    fi
    if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
        echo "Запускаю S98tg-tunnel..."
        /opt/etc/init.d/S98tg-tunnel start 2>&1
    else
        echo "tunnel init script missing" >&2
        return 1
    fi
    echo "Туннель запущен."
}

tunnel_disable() {
    # Set user-disabled marker BEFORE stopping so the watchdog (fired
    # by z2k-scheduler every ~minute) sees the flag and respects the
    # user's intent instead of resurrecting the daemon ~3 min later.
    # Output verbose так чтобы svc_action_async log показывал
    # реальный прогресс, не «пустую секцию между разделителями».
    local cfg="${ZAPRET2_DIR}/config"
    if [ -f "$cfg" ]; then
        if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg"; then
            echo "Устанавливаю TG_PROXY_USER_DISABLED=1 в /opt/zapret2/config"
            sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=1/' "$cfg"
        else
            echo "Добавляю TG_PROXY_USER_DISABLED=1 в /opt/zapret2/config"
            echo "TG_PROXY_USER_DISABLED=1" >> "$cfg"
        fi
    else
        echo "Конфиг /opt/zapret2/config не найден — флаг не записан"
    fi
    if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
        echo "Останавливаю S98tg-tunnel..."
        /opt/etc/init.d/S98tg-tunnel stop 2>&1
    else
        echo "Init-скрипт S98tg-tunnel не найден — пропускаю"
    fi
    echo "Туннель остановлен, watchdog респектнёт флаг и не будет его перезапускать."
}

# --- healthcheck / jobs ---

healthcheck_run_async() {
    local hc="$ZAPRET2_DIR/z2k-healthcheck.sh"
    [ -x "$hc" ] || { echo "healthcheck script missing" >&2; return 1; }
    local job_id
    job_id=$(date +%s)$$
    # See update_apply_async for why we close inherited CGI fds.
    (
        "$hc" > "/tmp/z2k-job-$job_id.log" 2>&1
        echo "$?" > "/tmp/z2k-job-$job_id.exit"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "/tmp/z2k-job-$job_id.pid"
    printf '%s' "$job_id"
}

job_status() {
    local id="$1"
    local pid_file="/tmp/z2k-job-$id.pid"
    local exit_file="/tmp/z2k-job-$id.exit"
    local log_file="/tmp/z2k-job-$id.log"
    [ -f "$pid_file" ] || { echo "unknown"; return 1; }
    if [ -f "$exit_file" ]; then
        echo "done"
    else
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "running"
        else
            echo "done"
        fi
    fi
}

job_log() {
    local id="$1"
    local log_file="/tmp/z2k-job-$id.log"
    [ -f "$log_file" ] && tail -c 16384 "$log_file" || true
}

job_exit_code() {
    local id="$1"
    cat "/tmp/z2k-job-$id.exit" 2>/dev/null || echo ""
}

# --- log tails (read-only) ---

tail_service_log() {
    local n="${1:-200}"
    # Prefer the journal-less log that S99zapret2 writes; fallback to dmesg.
    for f in /tmp/zapret2.log /var/log/messages /tmp/z2k-log/tg-tunnel.log; do
        if [ -f "$f" ]; then
            tail -n "$n" "$f"
            return 0
        fi
    done
    echo "(no service log found)"
}

tail_healthcheck_log() {
    local n="${1:-200}"
    local f="$ZAPRET2_DIR/healthcheck.log"
    if [ -f "$f" ]; then
        tail -n "$n" "$f"
    else
        echo "(no healthcheck log)"
    fi
}

# --- diag (Phase 3) ---
#
# Runs z2k-diag.sh in full mode. The raw output is a plain-text multi-section
# report designed for copy-paste. API caller embeds it as a JSON string and
# the UI renders it inside a <pre> block.

diag_run() {
    local diag="$ZAPRET2_DIR/z2k-diag.sh"
    if [ ! -x "$diag" ]; then
        echo "(z2k-diag.sh not installed — reinstall z2k to get it)"
        return 0
    fi
    sh "$diag" 2>&1
}

# --- rotator state (Phase 3) ---
#
# /opt/zapret2/extra_strats/cache/autocircular/state.tsv is a tab-separated
# file maintained by z2k-autocircular.lua. Format:
#   key\thost\tstrategy\tts
# Lines starting with # are comments (header). Empty lines are skipped.

STATE_FILE="${STATE_FILE:-$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv}"
# Fallback snapshot the lua also writes (RAM-disk; survives a RO/full /opt).
# It must be cleaned in lockstep with the primary — load_state() merges both on
# the next restart with newer-ts winning, so a stale fallback row would
# otherwise resurrect a host the operator just deleted.
STATE_FILE_FALLBACK="${STATE_FILE_FALLBACK:-/tmp/z2k-autocircular-state.tsv}"

state_read() {
    # Display-truth: read the SAME merged view the persist bridge actually writes
    # to — primary (/opt) AND the /tmp fallback, newer-ts wins per (key,host). On
    # a read-only /opt the bridge writes ONLY the fallback, so reading just the
    # primary would show stale/empty data while the live truth is in /tmp.
    local pf='' ff=''
    [ -f "$STATE_FILE" ] && pf="$STATE_FILE"
    [ -f "$STATE_FILE_FALLBACK" ] && ff="$STATE_FILE_FALLBACK"
    [ -z "$pf" ] && [ -z "$ff" ] && return 0
    awk -F'\t' '!/^#/ && NF>=3 {
        k=$1 FS $2; t=($4=="")?0:$4+0
        if (!(k in seen) || t>=ts[k]) { ts[k]=t; seen[k]=1; row[k]=$0 }
    } END { for (k in row) print row[k] }' $pf $ff 2>/dev/null
}

# Remove one row by host+key from a single state file, preserving inode.
# Caller has already validated key/host. No-op if the file is absent.
_state_delete_one_file() {
    local file="$1" key="$2" host="$3"
    [ -f "$file" ] || return 0
    # Use awk field-equality, NOT a regex grep -v — host literals contain "."
    # which is the ERE wildcard, so a regex match for foo.example.com would
    # also drop foo-example-com and friends from a neighbouring rotator key.
    # Even though the caller's sanitiser rejects non-DNS chars, the wildcard
    # semantics inside the regex itself still over-match legitimately-named
    # hosts that differ only by punctuation.
    local tmp="$file.z2k-new"
    awk -F'\t' -v key="$key" -v host="$host" '
        ($1 == key && $2 == host) { next }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$file"
    rm -f "$tmp"
    chmod 644 "$file" 2>/dev/null || true
}

# Delete one row by host+key. Host and key together uniquely identify a row.
#
# No service restart: z2k-state-persist.lua reconciles external edits to
# state.tsv against the live rotator within ~2s (reconcile_external_edits) — a
# deleted host has its in-RAM rotation reset to strategy 1 on its next packet,
# so the "× resets to the first strategy" semantics apply live, without bouncing
# nfqws. We clean BOTH the primary and the /tmp fallback so a later restart's
# merge can't revive the row.
state_delete() {
    local key="$1" host="$2"
    [ -z "$key" ] && { echo "key required" >&2; return 1; }
    [ -z "$host" ] && { echo "host required" >&2; return 1; }
    # Sanitize: key is [a-z0-9_], host is letters/digits/dots/dashes plus "|"
    # for the per-address-family rotation suffix (host|4 / host|6, fork r5+).
    case "$key"  in *[!a-zA-Z0-9_]*) echo "bad key" >&2; return 1 ;; esac
    case "$host" in *[!a-zA-Z0-9.|-]*) echo "bad host" >&2; return 1 ;; esac
    _state_delete_one_file "$STATE_FILE" "$key" "$host" || return 1
    _state_delete_one_file "$STATE_FILE_FALLBACK" "$key" "$host" || return 1
}

# --- geosite (Phase 3) ---

geosite_run_async() {
    local gs="$ZAPRET2_DIR/z2k-geosite.sh"
    [ -x "$gs" ] || { echo "z2k-geosite.sh missing" >&2; return 1; }
    local job_id
    job_id=$(date +%s)$$
    # See update_apply_async for why we close inherited CGI fds.
    (
        sh "$gs" fetch > "/tmp/z2k-job-$job_id.log" 2>&1
        echo "$?" > "/tmp/z2k-job-$job_id.exit"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "/tmp/z2k-job-$job_id.pid"
    printf '%s' "$job_id"
}

# probe_run_async removed in r-15 (Phase 1 cleanup
# detection stack). The active-probe path was never wired into the live
# circular and produced non-actionable verdicts. webpanel /probe/run
# endpoint now returns 410 Gone; Phase 3 will replace it with reactive
# discovery via the z2k-detect daemon.
probe_run_async() {
    echo "active probe removed in r-15" >&2
    return 1
}

# --- debug flag (Phase 3) ---
#
# Touch/rm /opt/zapret2/extra_strats/cache/autocircular/debug.flag. When
# present, z2k-autocircular.lua writes per-packet decisions to
# /opt/zapret2/extra_strats/cache/autocircular/debug.log. Useful for
# debugging silent-stuck rotator behavior.

debug_flag_path() {
    printf '%s' "$ZAPRET2_DIR/extra_strats/cache/autocircular/debug.flag"
}

debug_flag_state() {
    if [ -f "$(debug_flag_path)" ]; then
        printf '1'
    else
        printf '0'
    fi
}

debug_flag_set() {
    local want="$1"
    local p
    p=$(debug_flag_path)
    mkdir -p "$(dirname "$p")" 2>/dev/null
    if [ "$want" = "1" ]; then
        touch "$p" 2>/dev/null && return 0
        return 1
    else
        rm -f "$p" 2>/dev/null
        return 0
    fi
}

# --- auto-update status / apply ---
#
# UI surfaces the same auto-update mechanism that z2k-scheduler runs at
# 02:00 — the user sees "available: <tag>" and can trigger apply manually
# instead of waiting for the nightly window. The check path is cached on
# disk (5 min) so dashboard refreshes don't hammer raw.githubusercontent.

AU_TAG_FILE="${AU_TAG_FILE:-$ZAPRET2_DIR/.z2k-installed-tag}"
AU_MANIFEST_CACHE="${AU_MANIFEST_CACHE:-/tmp/z2k-au-manifest.json}"
AU_MANIFEST_CACHE_TTL="${AU_MANIFEST_CACHE_TTL:-300}"
AU_SCRIPT="${AU_SCRIPT:-$ZAPRET2_DIR/z2k-auto-update.sh}"
AU_LOG_FILE="${AU_LOG_FILE:-/opt/var/log/z2k-auto-update.log}"

update_installed_tag() {
    if [ -f "$AU_TAG_FILE" ]; then
        head -1 "$AU_TAG_FILE" 2>/dev/null | tr -d ' \r\n'
    else
        printf 'unknown'
    fi
}

# Get mtime of a file as a Unix timestamp. BusyBox `stat -c` doesn't exist
# on Entware (even /opt/bin/stat is BusyBox), but `date -r FILE +%s` does.
file_mtime() {
    [ -f "$1" ] || { echo 0; return; }
    date -r "$1" +%s 2>/dev/null || echo 0
}

# Refresh /tmp manifest cache when older than TTL (or force=1).
update_refresh_manifest() {
    local force="${1:-0}"
    if [ "$force" != "1" ] && [ -s "$AU_MANIFEST_CACHE" ]; then
        local age now mtime
        now=$(date +%s 2>/dev/null || echo 0)
        mtime=$(file_mtime "$AU_MANIFEST_CACHE")
        age=$((now - mtime))
        [ "$age" -lt "$AU_MANIFEST_CACHE_TTL" ] && return 0
    fi
    local url="https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/UPDATES.json"
    local tmp="${AU_MANIFEST_CACHE}.new"
    if curl -fsSL --max-time 15 "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$AU_MANIFEST_CACHE"
        return 0
    fi
    rm -f "$tmp"
    # Cache fallback — keep stale file if curl failed.
    [ -s "$AU_MANIFEST_CACHE" ] && return 0
    return 1
}

update_manifest_current() {
    [ -s "$AU_MANIFEST_CACHE" ] || { printf ''; return; }
    sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AU_MANIFEST_CACHE" | head -1
}

# Count how many history entries appear AFTER installed_tag.
# Matches au_history_entries_after semantics in lib/auto_update.sh —
# history-order, not numeric.
update_behind_count() {
    local installed="$1"
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '0'; return; }
    [ -z "$installed" ] || [ "$installed" = "unknown" ] && { printf '0'; return; }
    awk -v inst="$installed" '
        /"v"[[:space:]]*:[[:space:]]*"/ {
            line = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            v = line
            if (found) { count++; next }
            if (v == inst) { found = 1 }
        }
        END {
            print (found ? count : 0)
        }
    ' "$AU_MANIFEST_CACHE"
}

update_last_check_ts() {
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '0'; return; }
    file_mtime "$AU_MANIFEST_CACHE"
}

# Extract history entries strictly newer than installed_tag, in
# history-file order. Output is a JSON array — entries are emitted
# verbatim (each one is a single-line JSON object in UPDATES.json), no
# field re-serialization. Returns "[]" when installed is unknown or
# nothing is pending.
update_pending_entries() {
    local installed="$1"
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '[]'; return; }
    if [ -z "$installed" ] || [ "$installed" = "unknown" ]; then
        printf '[]'
        return
    fi
    awk -v inst="$installed" '
        /"v"[[:space:]]*:[[:space:]]*"/ {
            v = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", v)
            sub(/".*/, "", v)
            if (found) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                sub(/,$/, "", line)
                entries[++n] = line
                next
            }
            if (v == inst) { found = 1 }
        }
        END {
            printf "["
            for (i=1; i<=n; i++)
                printf "%s%s", (i>1?",":""), entries[i]
            printf "]"
        }
    ' "$AU_MANIFEST_CACHE"
}

# Launch auto-update apply asynchronously, return job_id for /job?id=...
# polling. Output streams to /tmp/z2k-job-<id>.log so the UI can tail it via
# the existing job_log path. The real auto-update log at /opt/var/log/...
# is appended by au_log; we duplicate to the per-job temp log for the UI.
update_apply_async() {
    [ -x "$AU_SCRIPT" ] || { echo "auto-update script missing: $AU_SCRIPT" >&2; return 1; }
    local job_id
    job_id=$(date +%s)$$
    # Daemonize: close stdin and detach stdout/stderr from the CGI pipes.
    # Without `</dev/null >/dev/null 2>&1` on the subshell, the background
    # apply (and every grandchild like `curl`, `sh install`, `lighttpd`
    # restart) inherits fd 1/2 pointing at lighttpd's CGI response pipe.
    # lighttpd won't finalize the HTTP response until EVERY fd 1 holder
    # closes — which means apiPost hangs for the entire 1-2 min install,
    # the browser's confirm closes, and the modal never opens because
    # the response that carries job_id is still in flight. Innermost
    # `> log 2>&1` then overrides /dev/null with the actual job log
    # for the apply itself.
    (
        sh "$AU_SCRIPT" apply > "/tmp/z2k-job-$job_id.log" 2>&1
        echo "$?" > "/tmp/z2k-job-$job_id.exit"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "/tmp/z2k-job-$job_id.pid"
    printf '%s' "$job_id"
}
