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
# Flash (persistent) state — daily-cadence keys only (fired ≤1×/day). Persisting
# these across reboot is the point: it stops a same-day re-fire after a restart.
STATE="${ZAPRET2_DIR}/.z2k-scheduler-state"
# RAM state — minute-cadence epoch keys (tg-watchdog-epoch / ppe-deoffload-epoch).
# These are rewritten ~2×/min; keeping them on flash burned ~2880 write+rename
# per day (flash wear). They only gate "did we already fire this minute", which
# is meaningless across a reboot, so /tmp (tmpfs) is the correct home.
TMP_STATE="/tmp/.z2k-scheduler-state"

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

# We were forked by the OOM-protected supervisor (S99z2k-scheduler sets its
# oom_score_adj to -1000) and inherit that immunity. Reset ours to normal so the
# scheduler AND every heavy task it fires (auto-update reinstall, list refresh)
# stay ordinary OOM candidates — only the tiny supervisor stays protected, and it
# respawns us if we are ever killed. Without this, a leaking task would be immune
# and the OOM killer would take an innocent bystander (nfqws2, dropbear) instead.
echo 0 > "/proc/$$/oom_score_adj" 2>/dev/null || true

# Ensure log dir exists.
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf '[%s] %s\n' "$ts" "$1" >> "$LOG"
}

# $1 - log path (defaults to the scheduler's own $LOG)
rotate_log() {
    local f="${1:-$LOG}"
    [ -f "$f" ] || return
    local lines
    lines=$(wc -l < "$f" 2>/dev/null)
    if [ "${lines:-0}" -gt 1000 ]; then
        # TRUNCATE IN PLACE, never mv. `mv` replaces the inode, and a daemon holding the
        # file open with >> keeps writing into the unlinked one — its log then freezes
        # forever while the file on disk looks fine. That is exactly what happened to the
        # usque engine log: field reports were read from a file the engine had stopped
        # writing to days earlier, and every conclusion drawn from them was unsound.
        tail -800 "$f" > "${f}.tmp" 2>/dev/null && cat "${f}.tmp" > "$f" 2>/dev/null
        rm -f "${f}.tmp" 2>/dev/null
    fi
}

# Every z2k log lives in tmpfs, i.e. in RAM on a 500 MB box, and NOTHING capped
# any of them except the scheduler's own. Measured on the owner's router before
# adding this: rt-proxy 18 KB / 185 lines, all z2k logs together 592 KB, tmpfs at
# 21% - so this is insurance against a chatty failure mode (a flapping pool logs
# per demotion), not a fix for observed growth. Reuses rotate_log rather than
# introducing a second rotation mechanism.
rotate_all_logs() {
    local d="${Z2K_LOG_DIR:-/tmp/z2k-log}"
    [ -d "$d" ] || return
    for f in "$d"/*.log; do
        [ -f "$f" ] || continue
        rotate_log "$f"
    done
}

# $1 state file, $2 key
last_fired_in() {
    local file="$1" key="$2"
    [ -f "$file" ] || return
    awk -F= -v k="$key" '$1==k {print $2}' "$file" | tail -1
}

# $1 state file, $2 key, $3 value
mark_fired_in() {
    local file="$1" key="$2" val="$3"
    if [ -f "$file" ]; then
        awk -F= -v k="$key" '$1!=k' "$file" > "${file}.tmp"
    else
        : > "${file}.tmp"
    fi
    printf '%s=%s\n' "$key" "$val" >> "${file}.tmp"
    mv "${file}.tmp" "$file"
}

# Daily-cadence keys live on flash ($STATE) so a same-day reboot can't re-fire.
last_fired_for_key() { last_fired_in "$STATE" "$1"; }
mark_fired() { mark_fired_in "$STATE" "$1" "$2"; }

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
        last_wd=$(last_fired_in "$TMP_STATE" tg-watchdog-epoch)
        case "$last_wd" in ''|*[!0-9]*) last_wd=0 ;; esac
        if [ "$((now_epoch - last_wd))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" tg-watchdog-epoch "$now_epoch"
            "${ZAPRET2_DIR}/tg-tunnel-watchdog.sh" >/dev/null 2>&1 &
        fi
    fi

    # Per-flow PPE de-offload re-assert (mangle FORWARD/PREROUTING). The NDM hook
    # (94-z2k-ppe-deoffload.sh) handles event-driven re-apply after netfilter
    # regen; this is the secondary net AND the boot-time apply (the rule is
    # self-contained — no ipset/order dependency — so this lands it as soon as
    # the scheduler ticks). No-ops cleanly where the firmware `-j PPE` target is
    # absent or the user disabled the layer.
    if [ -r "${ZAPRET2_DIR}/z2k-ppe-deoffload.sh" ]; then
        last_ppe=$(last_fired_in "$TMP_STATE" ppe-deoffload-epoch)
        case "$last_ppe" in ''|*[!0-9]*) last_ppe=0 ;; esac
        if [ "$((now_epoch - last_ppe))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" ppe-deoffload-epoch "$now_epoch"
            ( . "${ZAPRET2_DIR}/z2k-ppe-deoffload.sh"
              z2k_ppe_user_disabled || z2k_ppe_ensure_rules ) >/dev/null 2>&1 &
        fi
    fi

    # NFQUEUE self-heal (minute-cadence). Standalone script (mirrors the
    # tg-watchdog / ppe-deoffload pattern) re-applies the firewall when nfqws2 is
    # running and the WAN is up but its NFQUEUE rules are GONE — the boot-race
    # (fw_nfqws_post4/pre4 SKIP rule insertion when the WAN iface isn't detected
    # yet at start_fw and never retry -> NFQUEUE=0 with a live nfqws2, incl.
    # CGNAT/late-WAN topologies) and the secondary net for NDM wiping our rules
    # (the netfilter.d hook is the event-driven primary). Idempotent + coalesced
    # with the hook via the shared restart-fw mutex.
    if [ -x "${ZAPRET2_DIR}/z2k-nfqueue-selfheal.sh" ]; then
        last_sh=$(last_fired_in "$TMP_STATE" nfq-selfheal-epoch)
        case "$last_sh" in ''|*[!0-9]*) last_sh=0 ;; esac
        if [ "$((now_epoch - last_sh))" -ge 55 ]; then
            mark_fired_in "$TMP_STATE" nfq-selfheal-epoch "$now_epoch"
            "${ZAPRET2_DIR}/z2k-nfqueue-selfheal.sh" >/dev/null 2>&1 &
        fi
    fi

    # Game WARP mode self-heal (minute-cadence). z2k-warp.sh selfheal is a no-op
    # unless GAME_WARP_ENABLED=1; when on it re-applies the ipset MARK / route / MSS
    # clamp lost to an NDM firewall reload or WAN flap, and restarts a WEDGED (but
    # already-registered) tunnel. It does NOT do the first install / first bring-up of
    # the tunnel — that is the enable/boot/package's job (doing it here raced the
    # first-enable → opkgtun0 drift). Mirrors the ppe/nfqueue self-heal pattern.
    # CADENCE IS LOAD-BEARING, not a polling preference. Cloudflare drops an IDLE MASQUE
    # session (usque logs H3_NO_ERROR / "Tunnel connection lost"), and usque's author states
    # plainly that keeping light traffic on it prevents the drop entirely — upstream issue
    # Diniboy1123/usque#49, where users otherwise ended up cron-restarting the daemon. The
    # self-heal probe IS that light traffic, so running it every ~25s is the keepalive: it
    # costs one tiny request and removes the failure instead of reacting to it.
    if [ -r "${ZAPRET2_DIR}/z2k-warp.sh" ]; then
        last_warp=$(last_fired_in "$TMP_STATE" warp-selfheal-epoch)
        case "$last_warp" in ''|*[!0-9]*) last_warp=0 ;; esac
        if [ "$((now_epoch - last_warp))" -ge 25 ]; then
            mark_fired_in "$TMP_STATE" warp-selfheal-epoch "$now_epoch"
            sh "${ZAPRET2_DIR}/z2k-warp.sh" selfheal >/dev/null 2>&1 &
        fi
    fi

    # Rotate logs occasionally (cheap, only every minute boundary).
    if [ "$(date +%S)" -lt 30 ]; then
        rotate_log
        rotate_all_logs
    fi

    sleep 30
done
