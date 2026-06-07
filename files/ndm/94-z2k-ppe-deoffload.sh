#!/bin/sh
# /opt/etc/ndm/netfilter.d/94-z2k-ppe-deoffload.sh
#
# Keenetic NDM hook. NDM re-runs every script here after regenerating netfilter
# rules (boot, WAN up/down, hotplug, DHCP renew, ...) and wipes non-NDM rules in
# the process. We re-install the per-flow PPE de-offload rules (mangle FORWARD +
# PREROUTING) so blocked-host handshake windows stay on the CPU slow-path and
# nfqws2 keeps its retransmit visibility for rotation.
#
# NDM passes: type (iptables|ip6tables), table (filter|nat|mangle). Our rules
# live in mangle, so we act only on a mangle regen. z2k_ppe_ensure_rules is
# idempotent (-C guarded) and no-ops cleanly where the `-j PPE` target is absent
# (non-Keenetic) or the user disabled the layer.
#
# Rule logic lives in the shared lib (/opt/zapret2/z2k-ppe-deoffload.sh) so the
# hook, the watchdog and the S99 start path can never disagree on rule shape.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

# Only act on a mangle regen (the table our rules live in).
case "$table" in
    mangle) ;;
    *) exit 0 ;;
esac

LIB="/opt/zapret2/z2k-ppe-deoffload.sh"
[ -r "$LIB" ] || exit 0
. "$LIB"

# Respect explicit user disable + no-op on boxes without the firmware PPE target.
z2k_ppe_user_disabled && exit 0
z2k_ppe_available || exit 0

z2k_ppe_ensure_rules

exit 0
