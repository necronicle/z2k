#!/bin/sh
# /opt/etc/ndm/netfilter.d/93-z2k-tpws-redirect.sh
#
# Keenetic NDM hook. NDM invokes every script in this directory after
# regenerating netfilter rules (boot, WAN up/down, hotplug, DHCP renew, etc.)
# and wipes non-NDM rules in the process. We re-install the tpws REDIRECT (and
# the mangle OUTPUT mark that keeps tpws's own traffic out of nfqws2) here.
#
# NDM passes two env vars: type (iptables|ip6tables), table (filter|nat|mangle).
# z2k_tpws_ensure_rules re-asserts ALL rules (v4+v6, nat+mangle) idempotently
# with -C guards, so we can run it on any matching event and self-heal whatever
# table NDM just wiped. We skip only the ip6tables/filter noise.
#
# Rule logic lives in the shared lib (/opt/zapret2/z2k-tpws.sh) so the hook,
# the watchdog and the S95 init script can never disagree on rule shape.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

# Only act on nat/mangle regen (the tables we put rules in).
case "$table" in
    nat|mangle) ;;
    *) exit 0 ;;
esac

LIB="/opt/zapret2/z2k-tpws.sh"
[ -r "$LIB" ] || exit 0   # graceful: watchdog/S95 cover if the lib is missing
. "$LIB"

# Respect explicit user disable.
z2k_tpws_user_disabled && exit 0

# Only insert if tpws is actually running — otherwise leave the tables clean so
# youtube falls back to the direct (native nfqws2) path instead of a dead
# REDIRECT blackhole.
z2k_tpws_alive || exit 0

z2k_tpws_ensure_rules    # ipset + REDIRECT (v4/v6) + mangle mark, -w-locked, verify-retry

exit 0
