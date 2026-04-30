#!/bin/sh
# z2k-fix-tg-watchdog.sh
#
# Standalone one-shot patch that upgrades an existing z2k installation to
# the new Telegram-tunnel watchdog (active end-to-end HTTPS probe) and
# adds OUTPUT-chain REDIRECT rules so the probe from the router itself
# transits the tunnel. Idempotent — safe to run multiple times.
#
# Intended for users who already have z2k installed and don't want to
# reinstall just to pick up the watchdog fix. Runs in a few seconds.
#
# Usage:
#   ssh root@<router>
#   curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/files/z2k-fix-tg-watchdog.sh | sh

set -e
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

say() { printf '%s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }
tg_user_disabled() {
    [ -f /opt/zapret2/config ] || return 1
    [ "$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' /opt/zapret2/config)" = "1" ]
}

say "[1/4] Writing /opt/zapret2/tg-tunnel-watchdog.sh"
mkdir -p /opt/zapret2
cat > /opt/zapret2/tg-tunnel-watchdog.sh << 'WDSCRIPT'
#!/bin/sh
# Cron на Entware: PATH без /opt/bin → утилиты не находятся, flag-check тихо
# падает, daemon воскресает каждую минуту даже на TG_PROXY_USER_DISABLED=1.
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

# tg-tunnel watchdog
#  1. Restart on CONNECT_FAIL storm (legacy passive check)
#  2. Restart when an end-to-end HTTPS probe through the tunnel fails 3x
#     in a row. The probe targets a Telegram-owned IP that is REDIRECTed
#     to local :1443, so the request transits the tunnel. Catches the
#     "tunnel process alive but silently dead after WS reconnect" mode
#     that the CONNECT_FAIL detector misses entirely.

LOG=/tmp/tg-tunnel.log
BIN=/opt/sbin/tg-mtproxy-client
INIT=/opt/etc/init.d/S98tg-tunnel
STATE=/tmp/tg-tunnel-watchdog.state
PROBE_URL=https://core.telegram.org/
# IP-пин в TG CIDR (149.154.160.0/20) — без него curl каждую минуту дёргает
# DNS-резолв через https-dns-proxy, и если у юзера DoH с anti-bot rate-limit
# (geohide и т.п.) — лог сыпет 403. REDIRECT отправит трафик в туннель
# независимо от конкретного IP в --resolve.
PROBE_RESOLVE_IP=149.154.167.99

[ -x "$BIN" ] || exit 0

# Honor explicit user disable from menu / webpanel. The "stop tunnel"
# action there sets TG_PROXY_USER_DISABLED=1 in /opt/zapret2/config so
# the watchdog stops resurrecting the daemon every 3 min.
# `re-enable` from the same UI flips it back to 0.
CONFIG_FILE="/opt/zapret2/config"
if [ -f "$CONFIG_FILE" ]; then
    user_disabled=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG_FILE")
    if [ "$user_disabled" = "1" ]; then
        if [ -x "$INIT" ]; then
            "$INIT" stop >/dev/null 2>&1
        elif pidof tg-mtproxy-client >/dev/null 2>&1; then
            killall -9 tg-mtproxy-client 2>/dev/null
        fi
        exit 0
    fi
fi

restart_tunnel() {
    reason="$1"
    logger -t tg-watchdog "restart: $reason"
    if [ -x "$INIT" ]; then
        "$INIT" stop  >/dev/null 2>&1
        sleep 1
        killall -9 tg-mtproxy-client 2>/dev/null
        sleep 1
        # Truncate the log to a single marker line so the CONNECT_FAIL
        # storm that triggered this restart does not cause a second
        # restart on the next cron tick.
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
if [ -f "$LOG" ] && pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
    FAILS=$(tail -40 "$LOG" 2>/dev/null | grep -c "CONNECT_FAIL")
    if [ "$FAILS" -ge 10 ]; then
        restart_tunnel "CONNECT_FAIL storm ($FAILS in last 40 lines)"
        exit 0
    fi
fi

# If the binary isn't running at all, just start it and reset state.
if ! pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
    restart_tunnel "tunnel process not running"
    exit 0
fi

# 2) Active end-to-end probe through the tunnel.
if curl --connect-timeout 8 --max-time 15 -sf -o /dev/null \
        --resolve "core.telegram.org:443:$PROBE_RESOLVE_IP" \
        "$PROBE_URL" 2>/dev/null; then
    echo 0 > "$STATE"
    exit 0
fi

# Probe failed — increment consecutive-failure counter.
FAIL_CNT=0
[ -f "$STATE" ] && FAIL_CNT=$(head -1 "$STATE" 2>/dev/null)
case "$FAIL_CNT" in ''|*[!0-9]*) FAIL_CNT=0 ;; esac
FAIL_CNT=$((FAIL_CNT + 1))
echo "$FAIL_CNT" > "$STATE"

# Restart only after 3 consecutive failures (~3 minutes) to avoid flapping.
if [ "$FAIL_CNT" -ge 3 ]; then
    restart_tunnel "active probe failed ${FAIL_CNT}x in a row"
fi
WDSCRIPT
chmod +x /opt/zapret2/tg-tunnel-watchdog.sh

say "[2a/4] Rewriting /opt/etc/init.d/S98tg-tunnel to honor TG_PROXY_USER_DISABLED"
# Older S98tg-tunnel start() ignores the user-disable flag and resurrects
# the tunnel on every reboot. Rewrite the init script idempotently so it
# checks the flag before starting (matches what files/init.d/S98tg-tunnel
# now ships from the repo).
if [ -f /opt/etc/init.d/S98tg-tunnel ]; then
    cat > /opt/etc/init.d/S98tg-tunnel << 'INITEOF'
#!/bin/sh
# Entware init.d минимальный PATH без /opt/bin — flag-check на awk молча
# падает и daemon стартует даже на TG_PROXY_USER_DISABLED=1.
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

BIN="/opt/sbin/tg-mtproxy-client"
LOG="/tmp/tg-tunnel.log"
PIDFILE="/var/run/tg-tunnel.pid"

CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"

start() {
    [ -x "$BIN" ] || exit 0
    if [ -f "/opt/zapret2/config" ]; then
        user_disabled=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' /opt/zapret2/config)
        if [ "$user_disabled" = "1" ]; then
            echo "tg-tunnel disabled by user — skipping autostart"
            return 0
        fi
    fi
    if pidof tg-mtproxy-client >/dev/null 2>&1; then
        echo "tg-tunnel already running"
        return 0
    fi
    echo "Starting tg-tunnel..."
    $BIN --listen=:1443 --timeout=15m -v >> "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    for cidr in $CIDRS; do
        iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
            iptables -t nat -I PREROUTING 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
        iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
            iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
    done
    for cidr in $CIDRS; do
        conntrack -D -d "$cidr" 2>/dev/null || true
    done
}

stop() {
    echo "Stopping tg-tunnel..."
    killall tg-mtproxy-client 2>/dev/null
    rm -f "$PIDFILE"
    for cidr in $CIDRS; do
        while iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -t nat -D PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
        done
        while iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -t nat -D OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
        done
    done
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac
INITEOF
    chmod +x /opt/etc/init.d/S98tg-tunnel
    say "    S98tg-tunnel updated"
else
    say "    S98tg-tunnel not installed — skipping"
fi

if tg_user_disabled; then
    say "[2/4] Telegram tunnel disabled by user — skipping OUTPUT REDIRECT rules"
else
    say "[2/4] Adding OUTPUT REDIRECT rules for Telegram CIDRs"
    CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
    for cidr in $CIDRS; do
        iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
            iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443
    done
fi

say "[3/4] Ensuring watchdog cron entry exists"
if [ -x /opt/etc/init.d/S97tg-mtproxy ]; then
    /opt/etc/init.d/S97tg-mtproxy stop >/dev/null 2>&1 || true
fi
rm -f /opt/etc/init.d/S97tg-mtproxy 2>/dev/null
crontab -l 2>/dev/null | grep -v "S97tg-mtproxy" | crontab - 2>/dev/null || true
if ! crontab -l 2>/dev/null | grep -q "tg-tunnel-watchdog"; then
    { crontab -l 2>/dev/null || true; echo '* * * * * /opt/zapret2/tg-tunnel-watchdog.sh'; } | crontab -
    say "    cron entry added"
else
    say "    cron entry already present"
fi

say "[4/4] Running probe once to verify"
rm -f /tmp/tg-tunnel-watchdog.state
if /opt/zapret2/tg-tunnel-watchdog.sh; then
    if tg_user_disabled; then
        say ""
        say "[OK] Watchdog and S98tg-tunnel installed."
        say "     Telegram tunnel is disabled by user and will stay stopped after reboot."
        exit 0
    fi
    state="$(cat /tmp/tg-tunnel-watchdog.state 2>/dev/null || echo ?)"
    if [ "$state" = "0" ]; then
        say ""
        say "[OK] Watchdog installed and probe successful."
        say "     It will run every minute via cron and auto-restart the"
        say "     Telegram tunnel if the end-to-end probe fails 3x in a row."
    else
        say ""
        say "[!] Watchdog installed but probe failed (state=$state)."
        say "    It will retry automatically; if the probe fails 3x in a row"
        say "    the tunnel will be restarted."
    fi
else
    die "watchdog script returned non-zero"
fi
