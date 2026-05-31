#!/bin/sh
# /opt/etc/ndm/netfilter.d/91-z2k-ttl-bypass.sh
#
# Keenetic's NDM TTL fix (`ip ttl-fix` in CLI) installs
#   _NDM_POSTROUTING_TTL -o <wan> -j TTL --ttl-set 64
# to mask tethering from the carrier. It rewrites every outgoing packet,
# including nfqws2's fake desync packets which intentionally carry low
# TTL (typically 3-20 via ip_autottl/ip_ttl) so they die at the TSPU
# before reaching the real server. With TTL forced to 64 the fakes
# survive, hit the destination, and the desync attack collapses — DPI
# bypass stops working while TTL-fix is on.
#
# We RETURN early from _NDM_POSTROUTING_TTL for any packet carrying the
# z2k DESYNC_MARK (0x40000000). Client traffic still gets TTL=64;
# nfqws2 fakes pass through with their original low TTL.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

[ "$type" = "ip6tables" ] && exit 0
[ "$table" = "mangle" ] || exit 0

# Skip if NDM TTL-fix isn't active (chain absent).
iptables -t mangle -n -L _NDM_POSTROUTING_TTL >/dev/null 2>&1 || exit 0

iptables -t mangle -C _NDM_POSTROUTING_TTL -m mark --mark 0x40000000/0x40000000 -j RETURN 2>/dev/null || \
    iptables -t mangle -I _NDM_POSTROUTING_TTL 1 -m mark --mark 0x40000000/0x40000000 -j RETURN

exit 0
