#!/bin/sh
export PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin

# /opt/etc/ndm/netfilter.d/93-z2k-dns-filter-redirect.sh
#
# Keenetic NDM wipes/regenerates netfilter on reconnects and config changes,
# dropping z2k-dns-filter's :53 -> :15353 REDIRECT. This hook re-inserts it —
# but ONLY if the filter is enabled AND actually listening, mirroring the
# supervisor's FAIL-OPEN rule: a re-added redirect to a dead daemon would
# blackhole all DNS, so we never re-add unless the daemon is up.

[ "$table" != "nat" ] && exit 0

CONFIG="/opt/zapret2/config"
LISTEN_PORT="15353"

[ "$(awk -F= '/^Z2K_DNS_FILTER=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG" 2>/dev/null)" = "1" ] || exit 0

# fail-open gate: daemon must be listening before we (re)point DNS at it.
netstat -ln 2>/dev/null | grep -q ":${LISTEN_PORT}[[:space:]]" || exit 0

for proto in udp tcp; do
    iptables -t nat -C PREROUTING ! -i lo -p "$proto" --dport 53 -j REDIRECT --to-port "$LISTEN_PORT" 2>/dev/null || \
        iptables -t nat -I PREROUTING 1 ! -i lo -p "$proto" --dport 53 -j REDIRECT --to-port "$LISTEN_PORT" 2>/dev/null
done

exit 0
