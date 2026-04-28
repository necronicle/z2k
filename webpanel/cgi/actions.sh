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
AUSTERUSJ_CONF="${AUSTERUSJ_CONF:-$CONFIG_DIR/all_tcp443.conf}"
WHITELIST_FILE="${WHITELIST_FILE:-$LISTS_DIR/whitelist.txt}"

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
    # An empty value (e.g. `ROBLOX_UDP_BYPASS=` with nothing after the
    # equals sign) must fall back to the default, not propagate as ""
    # — otherwise the caller's printf emits `"key":,` which breaks JSON.
    # Caught by Алексей @Guf3477452 2026-04-18 after a reinstall left
    # ROBLOX_UDP_BYPASS with no value.
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
    # Source the generator on the fly. It's a long file that defines
    # create_official_config; sourcing is cheap and keeps us in parity.
    local lib="$ZAPRET2_DIR/lib/config_official.sh"
    if [ ! -f "$lib" ]; then
        # Fallback: try the staging dir used when running from /tmp/z2k
        lib="/tmp/z2k/lib/config_official.sh"
    fi
    if [ -f "$lib" ]; then
        # shellcheck disable=SC1090
        . "$lib"
        create_official_config "$CONFIG_FILE" >/dev/null 2>&1
        return $?
    fi
    echo "config_official.sh not found" >&2
    return 1
}

restart_service_if_running() {
    if is_running; then
        "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    fi
}

# --- service control ---

svc_start()   { "$INIT_SCRIPT" start   >/dev/null 2>&1; }
svc_stop()    { "$INIT_SCRIPT" stop    >/dev/null 2>&1; }
svc_restart() { "$INIT_SCRIPT" restart >/dev/null 2>&1; }

# --- toggles ---
#
# Each toggle reads the current flag, sets the new value, optionally regenerates
# NFQWS2_OPT via create_official_config (only for toggles that affect it), and
# restarts the running service. Idempotent — setting the same value twice is a no-op.

toggle_austerusj() {
    local want="$1"
    [ -f "$AUSTERUSJ_CONF" ] || { echo "$AUSTERUSJ_CONF missing" >&2; return 1; }
    set_flag "ENABLED" "$want" "$AUSTERUSJ_CONF" || return 1
    regenerate_config
    restart_service_if_running
}

toggle_rst_filter() {
    local want="$1"
    set_flag "DROP_DPI_RST" "$want" "$CONFIG_FILE" || return 1
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
    regenerate_config
    restart_service_if_running
}

toggle_customd() {
    # Note: 1 = ENABLED, 0 = DISABLED in our API; the config flag is
    # DISABLE_CUSTOM which is the INVERSE. We flip here so the web UI
    # stays consistent with "on = feature active".
    local want="$1"
    local disable_val="1"
    [ "$want" = "1" ] && disable_val="0"
    set_flag "DISABLE_CUSTOM" "$disable_val" "$CONFIG_FILE" || return 1
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
    restart_service_if_running
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
    restart_service_if_running
}

# --- tunnel (Telegram) ---

tunnel_pid() { pgrep -f "tg-mtproxy-client" 2>/dev/null | head -1; }

tunnel_enable() {
    # Clear user-disabled flag before starting so the watchdog resumes
    # auto-restarting on real crashes.
    local cfg="${ZAPRET2_DIR}/config"
    if [ -f "$cfg" ]; then
        if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg"; then
            sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=0/' "$cfg"
        fi
    fi
    if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
        /opt/etc/init.d/S98tg-tunnel start >/dev/null 2>&1
    else
        echo "tunnel init script missing" >&2
        return 1
    fi
}

tunnel_disable() {
    # Set user-disabled marker BEFORE stopping so the watchdog (cron,
    # every minute) sees the flag and respects the user's intent
    # instead of resurrecting the daemon ~3 min later.
    local cfg="${ZAPRET2_DIR}/config"
    if [ -f "$cfg" ]; then
        if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg"; then
            sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=1/' "$cfg"
        else
            echo "TG_PROXY_USER_DISABLED=1" >> "$cfg"
        fi
    fi
    if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
        /opt/etc/init.d/S98tg-tunnel stop >/dev/null 2>&1
    fi
}

# --- healthcheck / jobs ---

healthcheck_run_async() {
    local hc="$ZAPRET2_DIR/z2k-healthcheck.sh"
    [ -x "$hc" ] || { echo "healthcheck script missing" >&2; return 1; }
    local job_id
    job_id=$(date +%s)$$
    (
        "$hc" > "/tmp/z2k-job-$job_id.log" 2>&1
        echo "$?" > "/tmp/z2k-job-$job_id.exit"
    ) &
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
    for f in /tmp/zapret2.log /var/log/messages /tmp/tg-tunnel.log; do
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
