#!/bin/sh
# z2k-tg-watchdog.sh — periodic health check + auto-restart for the
# Telegram tunnel (tg-mtproxy-client). Runs every minute via cron;
# install.sh wires it up and adds the crontab entry.
#
# Two independent failure triggers:
#   1. CONNECT_FAIL storm — legacy passive check. Scans the tunnel log
#      for CONNECT_FAIL markers; restart if ≥10 in the last 40 lines.
#      Catches the case where tg-mtproxy-client is alive but every
#      stream to Telegram DCs is refused.
#
#   2. Active end-to-end HTTPS probe — curl to core.telegram.org which,
#      by virtue of our PREROUTING REDIRECT, transits the full
#      tunnel → VPS-relay → Telegram chain. Three consecutive failures
#      (~3 min) trigger a restart. Catches the "process alive but
#      silently wedged after WS reconnect" mode that the CONNECT_FAIL
#      check misses because no new streams are being attempted.
#
# Restart path:
#   - Prefer /opt/etc/init.d/S98tg-tunnel which handles iptables and
#     pidfile bookkeeping properly.
#   - Fallback: `killall -9` + fresh background spawn. Log truncated to
#     exactly one marker line on restart so the CONNECT_FAIL tail doesn't
#     echo back and retrigger us on the next cron tick (classic flap loop).

LOG=/tmp/tg-tunnel.log
BIN=/opt/sbin/tg-mtproxy-client
INIT=/opt/etc/init.d/S98tg-tunnel
STATE=/tmp/tg-tunnel-watchdog.state
PROBE_URL=https://core.telegram.org/

[ -x "$BIN" ] || exit 0

# Honor explicit user disable from menu / webpanel. The "stop tunnel"
# action there sets TG_PROXY_USER_DISABLED=1 in /opt/zapret2/config so
# the watchdog stops resurrecting the daemon every 3 min.
# `re-enable` from the same UI flips it back to 0.
CONFIG_FILE="/opt/zapret2/config"
if [ -f "$CONFIG_FILE" ]; then
    user_disabled=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG_FILE")
    if [ "$user_disabled" = "1" ]; then
        # If process is somehow still up after the user said stop, kill
        # it once on the way out so the next tick has nothing to find.
        if pidof tg-mtproxy-client >/dev/null 2>&1; then
            killall -9 tg-mtproxy-client 2>/dev/null
        fi
        exit 0
    fi
fi

restart_tunnel() {
    local reason="$1"
    logger -t tg-watchdog "restart: $reason"
    if [ -x "$INIT" ]; then
        "$INIT" stop  >/dev/null 2>&1
        sleep 1
        # belt-and-suspenders kill in case init script left a leftover
        killall -9 tg-mtproxy-client 2>/dev/null
        sleep 1
        # Truncate log to exactly one marker line. Without this, the very
        # CONNECT_FAIL storm that triggered the restart is still sitting in
        # tail -40 when cron runs again in a minute, and the detector fires
        # a second restart before the new session has time to stabilise —
        # classic restart loop.
        echo "$(date) watchdog restart: $reason" > "$LOG"
        "$INIT" start >/dev/null 2>&1
    else
        killall -9 tg-mtproxy-client 2>/dev/null
        sleep 1
        echo "$(date) watchdog restart: $reason" > "$LOG"
        "$BIN" --listen=:1443 -v >> "$LOG" 2>&1 &
    fi
    echo 0 > "$STATE"
}

# 1) CONNECT_FAIL storm (legacy)
if [ -f "$LOG" ] && pidof tg-mtproxy-client >/dev/null 2>&1; then
    FAILS=$(tail -40 "$LOG" 2>/dev/null | grep -c "CONNECT_FAIL")
    if [ "$FAILS" -ge 10 ]; then
        restart_tunnel "CONNECT_FAIL storm ($FAILS in last 40 lines)"
        exit 0
    fi
fi

# If the binary isn't running at all, just start it and reset state.
if ! pidof tg-mtproxy-client >/dev/null 2>&1; then
    restart_tunnel "tunnel process not running"
    exit 0
fi

# 1.5) iptables REDIRECT rules check. nfqws2 restart (S99zapret2) can
#   wipe the NAT PREROUTING/OUTPUT chains without triggering the NDM
#   netfilter hooks that re-insert our REDIRECT rules. When this
#   happens the tunnel process is alive and connected to the VPS, but
#   LAN traffic to Telegram DCs goes straight out the WAN — blocked.
#   Android Telegram is especially sensitive: it caches TCP connections
#   aggressively and won't retry through the tunnel until the app is
#   force-killed. Re-insert rules if even one is missing.
if ! iptables -t nat -C PREROUTING -d 149.154.160.0/20 -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; then
    logger -t tg-watchdog "REDIRECT rules missing — re-inserting + flushing conntrack"
    CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
    for cidr in $CIDRS; do
        iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
            iptables -t nat -I PREROUTING 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
        iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
            iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
    done
    # Flush stale conntrack entries for ALL Telegram DC CIDRs. Without
    # this, Android Telegram holds onto dead direct-to-DC connections
    # (SYN_SENT/ESTABLISHED to ISP blackhole) via the kernel conntrack
    # table, and new packets from the app follow those stale entries
    # BYPASSING the freshly re-inserted REDIRECT rules. The app stays
    # dead for minutes (exponential backoff) until conntrack naturally
    # expires. Flushing forces immediate new connections that hit the
    # REDIRECT → tunnel path. conntrack -D is idempotent — no harm if
    # entries already expired.
    for cidr in $CIDRS; do
        conntrack -D -d "$cidr" 2>/dev/null || true
    done
fi

# 2) Active end-to-end probe through the tunnel.
#    core.telegram.org resolves into 149.154.0.0/16, which our PREROUTING
#    REDIRECT bounces to 127.0.0.1:1443 → tg-mtproxy-client → VPS relay →
#    Telegram. Successful TLS + HTTP response = full path is healthy.
if curl --connect-timeout 8 --max-time 15 -sf -o /dev/null "$PROBE_URL" 2>/dev/null; then
    echo 0 > "$STATE"
    exit 0
fi

# Probe failed — increment consecutive-failure counter.
FAIL_CNT=0
[ -f "$STATE" ] && FAIL_CNT=$(head -1 "$STATE" 2>/dev/null)
case "$FAIL_CNT" in ''|*[!0-9]*) FAIL_CNT=0 ;; esac
FAIL_CNT=$((FAIL_CNT + 1))
echo "$FAIL_CNT" > "$STATE"

# Restart only after 3 consecutive failures (~3 minutes) to avoid
# flapping when Telegram itself or the upstream relay has a brief blip.
if [ "$FAIL_CNT" -ge 3 ]; then
    restart_tunnel "active probe failed ${FAIL_CNT}x in a row"
fi
