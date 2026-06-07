#!/bin/sh
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin
# /opt/zapret2/z2k-tpws-watchdog.sh
#
# Minute-cadence health check for the tpws layer, fired by z2k-scheduler.sh.
# Three jobs:
#   1. Respect a user stop (Z2K_TPWS=0 / TPWS_USER_DISABLED=1) — tear down.
#   2. Respawn tpws if the supervisor/daemon died or stopped listening.
#   3. Belt-and-suspenders re-assert of the REDIRECT/mark rules (the NDM hook
#      already covers wipes; this catches anything the hook missed).
# Deep "is youtube actually pierced" probing isn't done here: the PREROUTING
# redirect only catches forwarded client traffic, not the router's own, so an
# end-to-end probe from the router can't traverse tpws. Liveness + listen-bind
# + the static desync recipe is the meaningful signal.

LIB="/opt/zapret2/z2k-tpws.sh"
[ -r "$LIB" ] || exit 0
. "$LIB"

INIT="/opt/etc/init.d/S95z2k-tpws"
[ -x "$TPWS_BIN" ] || exit 0

# ---- log cap (CWE-59-safe; keep tail when over 2MB) ------------------------
cap_log() {
    f="$1"; max_kb="${2:-2048}"
    [ -L "$f" ] && { rm -f "$f" 2>/dev/null; return 0; }
    [ -f "$f" ] || return 0
    sz_kb=$(du -k "$f" 2>/dev/null | awk '{print $1}')
    [ -n "$sz_kb" ] && [ "$sz_kb" -gt "$max_kb" ] || return 0
    tmp=$(mktemp "/tmp/.tpwswd-cap.XXXXXX" 2>/dev/null) || return 0
    if tail -n 200 "$f" > "$tmp" 2>/dev/null; then cat "$tmp" > "$f" 2>/dev/null; fi
    rm -f "$tmp" 2>/dev/null
}
cap_log "$TPWS_LOG" 2048

# ---- 1. honour a user stop -------------------------------------------------
if z2k_tpws_user_disabled; then
    if z2k_tpws_alive || z2k_tpws_rule_present4; then
        [ -x "$INIT" ] && "$INIT" stop >/dev/null 2>&1
    fi
    exit 0
fi

# ---- 2. listening? respawn if not ------------------------------------------
listening() { netstat -ltn 2>/dev/null | grep -q ":$TPWS_PORT "; }

if ! z2k_tpws_alive || ! listening; then
    logger -t tpws-watchdog "restart: tpws not alive/listening on :$TPWS_PORT" 2>/dev/null
    [ -x "$INIT" ] && "$INIT" restart >/dev/null 2>&1
    exit 0
fi

# ---- 3. rules sane (cheap -C-guarded re-assert) ----------------------------
z2k_tpws_ensure_rules >/dev/null 2>&1
exit 0
