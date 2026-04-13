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
#   curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/master/files/z2k-fix-tg-watchdog.sh | sh

set -e

say() { printf '%s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

say "[1/4] Writing /opt/zapret2/tg-tunnel-watchdog.sh"
mkdir -p /opt/zapret2
cat > /opt/zapret2/tg-tunnel-watchdog.sh << 'WDSCRIPT'
#!/bin/sh
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

[ -x "$BIN" ] || exit 0

restart_tunnel() {
    reason="$1"
    logger -t tg-watchdog "restart: $reason"
    echo "$(date) watchdog restart: $reason" >> "$LOG"
    if [ -x "$INIT" ]; then
        "$INIT" stop  >/dev/null 2>&1
        sleep 1
        killall -9 tg-mtproxy-client 2>/dev/null
        sleep 1
        "$INIT" start >/dev/null 2>&1
    else
        killall -9 tg-mtproxy-client 2>/dev/null
        sleep 1
        "$BIN" --listen=:1443 >> "$LOG" 2>&1 &
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

# Restart only after 3 consecutive failures (~3 minutes) to avoid flapping.
if [ "$FAIL_CNT" -ge 3 ]; then
    restart_tunnel "active probe failed ${FAIL_CNT}x in a row"
fi
WDSCRIPT
chmod +x /opt/zapret2/tg-tunnel-watchdog.sh

say "[2/4] Adding OUTPUT REDIRECT rules for Telegram CIDRs"
CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
for cidr in $CIDRS; do
    iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
        iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443
done

say "[3/4] Ensuring watchdog cron entry exists"
if ! crontab -l 2>/dev/null | grep -q "tg-tunnel-watchdog"; then
    ( crontab -l 2>/dev/null; echo '* * * * * /opt/zapret2/tg-tunnel-watchdog.sh' ) | crontab -
    say "    cron entry added"
else
    say "    cron entry already present"
fi

say "[4/4] Running probe once to verify"
rm -f /tmp/tg-tunnel-watchdog.state
if /opt/zapret2/tg-tunnel-watchdog.sh; then
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
