#!/bin/sh
# /opt/etc/ndm/netfilter.d/91-z2k-http-tunnel-redirect.sh
#
# Companion to /opt/etc/init.d/S97z2k-http-tunnel. Same shape as the
# Telegram redirect hook (90-z2k-tg-redirect.sh) — NDM wipes non-NDM
# iptables rules whenever it regenerates the ruleset (boot, WAN up/down,
# tunnel up/down, hotplug), so we re-insert ours idempotently here.
#
# Only inserts rules when the http-tunnel daemon is actually running
# (PID file present and live) — otherwise we'd REDIRECT into a dead
# port instead of letting traffic try the direct path.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

[ "$type" = "ip6tables" ] && exit 0
[ "$table" = "nat" ] || exit 0

PIDFILE="/var/run/z2k-http-tunnel.pid"
LISTEN_PORT="1444"

# Daemon must be live; pid file alone isn't enough — could be stale.
if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || exit 0
else
    exit 0
fi

CIDRS="168.119.95.238/32"

# xtables-lock-safe iptables (-w): without it an insert racing NDM's own
# iptables churn returns EBUSY and fails SILENTLY, dropping the redirect
# (mirrors S99zapret2.new; plain-iptables fallback for ancient builds).
ipt() { iptables -w "$@" 2>/dev/null || iptables "$@" 2>/dev/null; }

for cidr in $CIDRS; do
    ipt -t nat -C PREROUTING -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port $LISTEN_PORT || \
        ipt -t nat -I PREROUTING 1 -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port $LISTEN_PORT
    ipt -t nat -C OUTPUT -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port $LISTEN_PORT || \
        ipt -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port $LISTEN_PORT
done

for cidr in $CIDRS; do
    conntrack -D -d "${cidr%/*}" 2>/dev/null || true
done

exit 0
