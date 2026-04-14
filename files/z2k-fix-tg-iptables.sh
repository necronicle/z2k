#!/bin/sh
# z2k-fix-tg-iptables.sh — restore missing Telegram REDIRECT rules.
#
# Use when Telegram works on some devices (e.g. desktop) but not others
# (e.g. Android), and `iptables -t nat -L PREROUTING -n | grep 1443`
# returns nothing. The culprit is usually Keenetic's NDM daemon wiping
# our rules on a network event (WAN up/down, tunnel up/down, hotplug).
#
# Script is idempotent: safe to run multiple times, won't duplicate rules.

set -eu

CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"

echo "=== Before ==="
before=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c '1443' || true)
echo "PREROUTING rules with :1443 → $before"

if ! pgrep -f tg-mtproxy-client >/dev/null 2>&1; then
    echo
    echo "WARNING: tg-mtproxy-client is NOT running — REDIRECT rules will"
    echo "         point traffic at a dead port. Start the tunnel first:"
    echo "           /opt/etc/init.d/S98tg-tunnel start"
    echo
fi

echo
echo "=== Inserting missing rules ==="
added=0
for cidr in $CIDRS; do
    if iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; then
        echo "  PREROUTING $cidr — already present"
    else
        iptables -t nat -I PREROUTING 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 \
            && { echo "  PREROUTING $cidr — ADDED"; added=$((added + 1)); }
    fi

    if iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; then
        echo "  OUTPUT     $cidr — already present"
    else
        iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 \
            && { echo "  OUTPUT     $cidr — ADDED"; added=$((added + 1)); }
    fi
done

echo
echo "=== After ==="
after=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c '1443' || true)
echo "PREROUTING rules with :1443 → $after (was $before, $added new)"

if [ "$after" -ge 10 ]; then
    echo
    echo "OK: all 10 Telegram DC CIDRs are now redirected to :1443"
    echo
    echo "Test: open Telegram on Android. If it still doesn't connect,"
    echo "      send the output of this command:"
    echo "        iptables -t nat -L PREROUTING -n -v | grep 1443"
    echo
    echo "Note: these rules can be wiped again by Keenetic NDM on the next"
    echo "      network event (reboot, WAN reconnect). If that happens,"
    echo "      just run this script again. A permanent fix requires a"
    echo "      cron/hotplug watchdog, which will come in a follow-up."
else
    echo
    echo "ERROR: expected >=10 rules, got $after. Check errors above."
    exit 1
fi
