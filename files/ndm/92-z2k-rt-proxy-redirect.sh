#!/bin/sh
export PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin

# /opt/etc/ndm/netfilter.d/92-z2k-rt-proxy-redirect.sh
#
# Companion to /opt/etc/init.d/S96z2k-rt-proxy. NDM wipes non-NDM iptables rules
# on every netfilter regen (WAN flap, hotplug, reboot); this hook re-inserts the
# sentinel REDIRECT that sends RuTracker traffic into the local rt-proxy.
# Only inserts rules when the rt-proxy daemon is actually running (PID file live)
# — otherwise we'd REDIRECT into a dead port (blackhole). Same shape as
# 91-z2k-http-tunnel-redirect.sh.

[ "$type" = "ip6tables" ] && exit 0

PIDFILE="/var/run/z2k-rt-proxy.pid"
LISTEN_PORT="1445"
SENTINEL="10.171.171.171"

# Only proceed if the supervisor/daemon is alive.
[ -f "$PIDFILE" ] || exit 0
kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || exit 0

iptables -t nat -C PREROUTING -d "$SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port $LISTEN_PORT 2>/dev/null || \
    iptables -t nat -I PREROUTING 1 -d "$SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port $LISTEN_PORT 2>/dev/null
iptables -t nat -C OUTPUT -d "$SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port $LISTEN_PORT 2>/dev/null || \
    iptables -t nat -I OUTPUT 1 -d "$SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port $LISTEN_PORT 2>/dev/null

exit 0
