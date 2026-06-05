#!/bin/sh
# /opt/zapret2/z2k-tg-redirect.sh — shared Telegram-DC REDIRECT helpers.
#
# SINGLE SOURCE OF TRUTH for the Telegram-DC redirect: the DC CIDR list, the
# ipset name, and the install/remove/conntrack logic. Sourced by all three
# places that touch these rules — the NDM netfilter.d hook
# (90-z2k-tg-redirect.sh), the tg-watchdog, and the S98tg-tunnel init script
# — so they install the EXACT same rule shape and can never disagree.
#
# WHY ipset + -w (root fix for "rule slips, TG drops ~30min"):
#   - NDM rebuilds the iptables nat table on every netfilter event (boot,
#     WAN/link flap, DHCP renew, hotplug, policy reapply) and WIPES non-NDM
#     rules. It does NOT touch ipsets. So the DC list (ipset) stays put; only
#     2 referencing rules need re-adding instead of 20 per-CIDR rules. A
#     lock race now drops 0-or-2 rules ATOMICALLY instead of "9 of 10".
#   - iptables -w (xtables lock wait): without it, an insert racing NDM's own
#     iptables churn returns EBUSY and fails SILENTLY (stderr->/dev/null) —
#     the documented cause of the missing-rule symptom. We wait for the lock.
#     NOTE: Keenetic/Entware iptables supports bare -w but NOT "-w <timeout>",
#     so we use plain -w with a fallback to no-lock (mirrors S99zapret2.new).

Z2K_TG_SET="z2k_tg_dc"
Z2K_TG_PORT=1443
Z2K_TG_CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"

# xtables-lock-safe iptables: wait for the lock, fall back to plain on
# ancient iptables without -w (mirrors S99zapret2.new:937).
_z2k_tg_ipt() { iptables -w "$@" 2>/dev/null || iptables "$@" 2>/dev/null; }

# Ensure the ipset exists and holds the current DC CIDR list (idempotent;
# ipset survives NDM wipes so this is usually a no-op after first run).
z2k_tg_ensure_ipset() {
    ipset create "$Z2K_TG_SET" hash:net -exist 2>/dev/null || return 1
    for _c in $Z2K_TG_CIDRS; do
        ipset add "$Z2K_TG_SET" "$_c" -exist 2>/dev/null
    done
    return 0
}

# Is the REDIRECT rule present in chain $1 (PREROUTING|OUTPUT)?
z2k_tg_rule_present() {
    _z2k_tg_ipt -t nat -C "$1" -p tcp --dport 443 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"
}

# Install both REDIRECT rules with verify-retry. Returns 0 only when both
# rules are confirmed present.
z2k_tg_ensure_rules() {
    z2k_tg_ensure_ipset || return 1
    _retry=0
    while [ "$_retry" -lt 3 ]; do
        z2k_tg_rule_present PREROUTING || _z2k_tg_ipt -t nat -I PREROUTING 1 -p tcp --dport 443 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"
        z2k_tg_rule_present OUTPUT     || _z2k_tg_ipt -t nat -I OUTPUT 1 -p tcp --dport 443 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"
        if z2k_tg_rule_present PREROUTING && z2k_tg_rule_present OUTPUT; then
            return 0
        fi
        _retry=$((_retry + 1))
        [ "$_retry" -lt 3 ] && sleep 1
    done
    return 1
}

# Remove both REDIRECT rules (tunnel stop). Loops in case duplicates exist.
# Leaves the ipset in place (cheap, reused on next start).
z2k_tg_remove_rules() {
    while z2k_tg_rule_present PREROUTING; do
        _z2k_tg_ipt -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"
    done
    while z2k_tg_rule_present OUTPUT; do
        _z2k_tg_ipt -t nat -D OUTPUT -p tcp --dport 443 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"
    done
}

# Remove LEGACY per-CIDR REDIRECT rules from the pre-ipset implementation, so
# an in-place upgrade migrates cleanly instead of leaving 10 stale rules
# alongside the 2 new ipset rules. Cheap after migration (-C fails fast).
z2k_tg_remove_legacy_rules() {
    for _c in $Z2K_TG_CIDRS; do
        while _z2k_tg_ipt -t nat -C PREROUTING -d "$_c" -p tcp --dport 443 -j REDIRECT --to-port "$Z2K_TG_PORT"; do
            _z2k_tg_ipt -t nat -D PREROUTING -d "$_c" -p tcp --dport 443 -j REDIRECT --to-port "$Z2K_TG_PORT"
        done
        while _z2k_tg_ipt -t nat -C OUTPUT -d "$_c" -p tcp --dport 443 -j REDIRECT --to-port "$Z2K_TG_PORT"; do
            _z2k_tg_ipt -t nat -D OUTPUT -d "$_c" -p tcp --dport 443 -j REDIRECT --to-port "$Z2K_TG_PORT"
        done
    done
}

# Flush stale conntrack so clients re-evaluate through the restored REDIRECT
# path immediately instead of riding dead direct-to-DC entries.
z2k_tg_flush_conntrack() {
    for _c in $Z2K_TG_CIDRS; do
        conntrack -D -d "$_c" 2>/dev/null || true
    done
}
