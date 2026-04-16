#!/bin/sh
# /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh
#
# Keenetic NDM hook. NDM invokes every script in this directory after
# regenerating netfilter rules (on boot, WAN up/down, tunnel up/down,
# hotplug, etc.) and wipes non-NDM rules in the process. Our REDIRECT
# rules for Telegram DC CIDRs live in PREROUTING/OUTPUT and get wiped
# every time. This hook re-inserts them idempotently.
#
# NDM passes two env vars:
#   type   — iptables | ip6tables
#   table  — filter | nat | mangle | raw
#
# We only care about iptables + nat.

[ "$type" = "ip6tables" ] && exit 0
[ "$table" = "nat" ] || exit 0

# Only insert rules if the tunnel process is actually running. If the user
# stopped the tunnel (menu [T] Disable), leave iptables clean so traffic
# falls back to the direct (blocked-by-TSPU) path instead of being
# REDIRECTed into a dead port.
pidof tg-mtproxy-client >/dev/null 2>&1 || exit 0

CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"

for cidr in $CIDRS; do
    iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
        iptables -t nat -I PREROUTING 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
    iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
        iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
done

exit 0
