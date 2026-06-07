#!/bin/sh
# z2k-scheduler.sh — z2k internal task scheduler.
#
# Replaces Vixie cron for ALL z2k periodic tasks on Keenetic Entware,
# where the cron daemon's crontab reload mechanism is broken: even on a
# fresh `crontab -` + spool-dir mtime update + SIGHUP, the daemon does
# not pick up new entries (see field debug notes around r-26).
#
# Runs as a long-lived process started by S99z2k-scheduler at boot.
# Sleeps ~30s between ticks, fires each registered task once per day at
# the configured HH:MM. Persistent state at $STATE prevents re-firing
# the same minute twice if we wake up multiple times within it.
#
# Tasks (HH:MM <command>):
#   02:00  z2k-auto-update.sh apply       — nightly auto-update check
#   03:00  z2k-stats-upload.sh             — anonymized strategy stats -> VPS
#   04:00  z2k-update-lists.sh             — RKN/YT hostlist refresh
#   06:00  ipset/get_config.sh              — IP-set resolution

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

ZAPRET2_DIR="/opt/zapret2"
PIDFILE="/var/run/z2k-scheduler.pid"
LOG="/opt/var/log/z2k-scheduler.log"
STATE="${ZAPRET2_DIR}/.z2k-scheduler-state"

# Don't double-launch.
if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "z2k-scheduler already running pid $old_pid" >&2
        exit 0
    fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; exit 0' INT TERM HUP

# Ensure log dir exists.
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf '[%s] %s\n' "$ts" "$1" >> "$LOG"
}

rotate_log() {
    [ -f "$LOG" ] || return
    local lines
    lines=$(wc -l < "$LOG" 2>/dev/null)
    if [ "${lines:-0}" -gt 1000 ]; then
        tail -800 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
}

last_fired_for_key() {
    [ -f "$STATE" ] || return
    awk -F= -v k="$1" '$1==k {print $2}' "$STATE" | tail -1
}

mark_fired() {
    local key="$1" today="$2"
    if [ -f "$STATE" ]; then
        awk -F= -v k="$key" '$1!=k' "$STATE" > "${STATE}.tmp"
    else
        : > "${STATE}.tmp"
    fi
    printf '%s=%s\n' "$key" "$today" >> "${STATE}.tmp"
    mv "${STATE}.tmp" "$STATE"
}

# Run one task in background, with output captured into the scheduler log.
run_task() {
    local label="$1"
    shift
    log "fire $label: $*"
    ( "$@" >> "$LOG" 2>&1; log "done $label (exit $?)" ) &
}

log "scheduler started (pid $$, $(uname -srm))"

while true; do
    hhmm=$(date +%H:%M)
    today=$(date +%Y-%m-%d)
    now_epoch=$(date +%s)

    # Daily tasks — gate on date-key so each only fires once per day even
    # if our 30s tick passes through the same minute twice.
    case "$hhmm" in
        02:00)
            if [ "$(last_fired_for_key auto-update)" != "$today" ]; then
                mark_fired auto-update "$today"
                run_task auto-update "${ZAPRET2_DIR}/z2k-auto-update.sh" apply
            fi
            ;;
        03:00)
            # Anonymized strategy-stats upload (gated on Z2K_STATS inside the
            # script; silent no-op on opt-out / network failure).
            if [ "$(last_fired_for_key stats-upload)" != "$today" ]; then
                mark_fired stats-upload "$today"
                run_task stats-upload "${ZAPRET2_DIR}/z2k-stats-upload.sh"
            fi
            ;;
        04:00)
            if [ "$(last_fired_for_key update-lists)" != "$today" ]; then
                mark_fired update-lists "$today"
                run_task update-lists "${ZAPRET2_DIR}/z2k-update-lists.sh"
            fi
            ;;
        06:00)
            if [ "$(last_fired_for_key get-config)" != "$today" ]; then
                mark_fired get-config "$today"
                log "fire get-config: ZAPRET_BASE=${ZAPRET2_DIR} ${ZAPRET2_DIR}/ipset/get_config.sh"
                (
                    ZAPRET_BASE="${ZAPRET2_DIR}" "${ZAPRET2_DIR}/ipset/get_config.sh" >> "$LOG" 2>&1
                    log "done get-config (exit $?)"
                ) &
            fi
            ;;
    esac

    # Minute-cadence task: tg-tunnel-watchdog. Mirrors the old
    # `* * * * *` cron entry. Tracked by unix timestamp so we fire it
    # ~1×/min even though our tick runs ~2×/min.
    if [ -x "${ZAPRET2_DIR}/tg-tunnel-watchdog.sh" ]; then
        last_wd=$(last_fired_for_key tg-watchdog-epoch)
        case "$last_wd" in ''|*[!0-9]*) last_wd=0 ;; esac
        if [ "$((now_epoch - last_wd))" -ge 55 ]; then
            mark_fired tg-watchdog-epoch "$now_epoch"
            "${ZAPRET2_DIR}/tg-tunnel-watchdog.sh" >/dev/null 2>&1 &
        fi
    fi

    # Minute-cadence task: tpws youtube-layer watchdog. The S95 supervisor
    # already respawns a crashed daemon; this is the secondary net (supervisor
    # itself died / rules drifted / user toggled Z2K_TPWS).
    if [ -x "${ZAPRET2_DIR}/z2k-tpws-watchdog.sh" ]; then
        last_tw=$(last_fired_for_key tpws-watchdog-epoch)
        case "$last_tw" in ''|*[!0-9]*) last_tw=0 ;; esac
        if [ "$((now_epoch - last_tw))" -ge 55 ]; then
            mark_fired tpws-watchdog-epoch "$now_epoch"
            "${ZAPRET2_DIR}/z2k-tpws-watchdog.sh" >/dev/null 2>&1 &
        fi
    fi

    # Rotate log occasionally (cheap, only every minute boundary).
    if [ "$(date +%S)" -lt 30 ]; then
        rotate_log
    fi

    sleep 30
done
