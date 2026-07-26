#!/bin/sh
export PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin

# /opt/etc/ndm/netfilter.d/93-z2k-warp.sh
#
# Companion to /opt/zapret2/z2k-warp.sh. NDM rebuilds the netfilter tables on every
# regen (WAN flap, hotplug, policy change, reboot) and drops non-NDM rules with them.
# WARP was the ONE z2k layer without a hook: its mangle PREROUTING MARK rule — the
# thing that actually steers the game ipset into the tunnel — was only restored by the
# minute-cadence scheduler selfheal, so every regen left a window of up to a minute in
# which WARP silently did nothing while the panel still showed it enabled.
#
# Routing state (`ip rule` / table 989) survives a netfilter regen untouched, so this
# hook only has to re-assert the MARK rule. Same shape as 92-z2k-rt-proxy-redirect.sh.

[ "$type" = "ip6tables" ] && exit 0
[ "$table" = "mangle" ] || exit 0

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_FILE="$ZAPRET2_DIR/config"
WARP_IPSET="${WARP_IPSET:-z2k_warp}"
WARP_MARK="${WARP_MARK:-0x989}"

# Only while the user actually has the mode on — otherwise a regen would resurrect
# routing for a feature that is switched off.
[ "$(grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d ' ')" = "1" ] || exit 0

# The set is z2k-owned and survives NDM regens (ipsets are not wiped), but a MARK rule
# referencing a missing set is rejected outright — bail rather than log noise.
ipset list "$WARP_IPSET" >/dev/null 2>&1 || exit 0

# xtables-lock-safe (-w): without it an insert racing NDM's own iptables churn returns
# EBUSY and fails SILENTLY, dropping the rule.
ipt() { iptables -w "$@" 2>/dev/null || iptables "$@" 2>/dev/null; }

# PREROUTING only — forwarded LAN-client traffic (console/phone). NOT OUTPUT: routing a
# router-originated packet into the tun breaks its reply path and blackholes the router's
# own Cloudflare/AWS access (github fetches, VPS relay).
ipt -t mangle -C PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" || \
    ipt -t mangle -A PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK"

