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

# Telegram IPv6 DC ranges — from Telegram's OWN announced AS prefixes
# (AS62041/62014/44907/59930/211157, via RIPEstat/BGP), collapsed. These are
# the authoritative v6 DC blocks, not a guess from one client's log.
#
# WHY fast-REJECT (root fix for "mobile TG connects 10-60s, PC is instant"):
#   The MTProto tunnel is IPv4-only (redirect below → :1443 → v4 relay → DC).
#   Telegram's IPv6 DCs are RU-blocked, but a mobile client on a cold connect
#   races v4 AND v6 DC endpoints in parallel. The v6 SYN leaves via FORWARD
#   (policy DROP has an ACCEPT path for LAN→WAN) and dies SILENTLY upstream at
#   the ТСПУ → the client waits its full 8s connect timeout, retries v6, and
#   only then falls back to v4 — stacking ~40s of dead-v6 stalls (proven in the
#   client's net.txt: repeated "connecting (2001:067c:04e8:f004::a:443)" →
#   "timeout = 8" → "disconnected reason 2"). PC/warm reuses a known-good v4 DC
#   so it never pays this. We insert an ip6tables REJECT --reject-with
#   tcp-reset so the phone's v6 DC SYN gets an INSTANT RST at the router and
#   immediately uses the working v4 tunnel. (We reject rather than tunnel v6
#   because the relay path is v4 and the v6 DCs are dead anyway.)
Z2K_TG_SET6="z2k_tg_dc6"
Z2K_TG_CIDRS6="2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48 2a0a:f280:203::/48"

# xtables-lock-safe iptables: wait for the lock, fall back to plain on
# ancient iptables without -w (mirrors S99zapret2.new:937).
_z2k_tg_ipt() { iptables -w "$@" 2>/dev/null || iptables "$@" 2>/dev/null; }
_z2k_tg_ipt6() { ip6tables -w "$@" 2>/dev/null || ip6tables "$@" 2>/dev/null; }

# Собственные релеи z2k. Соединения САМОГО роутера с ними (туннель Telegram,
# /resolve) обход не трогает: 10.11.2026 проба движка на SYN рвала новые
# соединения туннеля. Исключаем их меткой движка 0x40000000 в mangle OUTPUT —
# правило очереди в POSTROUTING пакеты с ней пропускает, — а НЕ адресом в
# nozapret, как было с p-87.26 по p-88.2: на этот же адрес роутер уводит домены
# WhatsApp устройств сети (ip host), и исключение по адресу лишило их обхода —
# DPI резал их по имени (15.11.2026: static/mmg.whatsapp.net через VPS висели до
# таймаута, без исключения — ответ за 0,3 с). Пакеты устройств идут через
# FORWARD и метку не получают.
Z2K_OWNED_RELAYS="85.192.60.175 45.146.90.136"
Z2K_OWNED_RELAY_MARK="0x40000000/0x40000000"

z2k_owned_relay_rule_present() {
    _z2k_tg_ipt -t mangle -C OUTPUT -d "$1" -j MARK --set-xmark "$Z2K_OWNED_RELAY_MARK"
}

z2k_owned_relays_ensure() {
    for _r in $Z2K_OWNED_RELAYS; do
        z2k_owned_relay_rule_present "$_r" \
            || _z2k_tg_ipt -t mangle -I OUTPUT 1 -d "$_r" -j MARK --set-xmark "$Z2K_OWNED_RELAY_MARK" \
            || return 1
    done
    return 0
}

z2k_owned_relays_remove() {
    for _r in $Z2K_OWNED_RELAYS; do
        _i=0
        while [ "$_i" -lt 8 ] && z2k_owned_relay_rule_present "$_r"; do
            _z2k_tg_ipt -t mangle -D OUTPUT -d "$_r" -j MARK --set-xmark "$Z2K_OWNED_RELAY_MARK" || break
            _i=$((_i + 1))
        done
    done
    return 0
}

# Прежняя форма исключения (p-87.26…p-88.2): адрес в файле исключений и в
# nozapret. Снимаем только свои строки: чужие записи файла не трогаем. Сначала
# файл — иначе перезапуск обхода вернул бы адрес в набор из файла.
z2k_owned_relays_unexclude_legacy() {
    _excl="${TG_EXCLUDE_FILE:-/opt/zapret2/ipset/zapret-hosts-user-exclude.txt}"
    for _r in $Z2K_OWNED_RELAYS; do
        if [ -f "$_excl" ] && grep -qFx "$_r" "$_excl" 2>/dev/null; then
            grep -vFx "$_r" "$_excl" > "$_excl.z2k.$$" 2>/dev/null && cat "$_excl.z2k.$$" > "$_excl"
            rm -f "$_excl.z2k.$$"
        fi
        command -v ipset >/dev/null 2>&1 && ipset del nozapret "$_r" -exist 2>/dev/null
    done
    return 0
}

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

# --- IPv6 fast-reject of Telegram DC ranges (see Z2K_TG_CIDRS6 rationale) ---

# Ensure the v6 ipset exists and holds the current v6 DC CIDR list. Survives
# NDM ip6tables wipes just like the v4 set, so this is a no-op after first run.
z2k_tg_ensure_ipset6() {
    ipset create "$Z2K_TG_SET6" hash:net family inet6 -exist 2>/dev/null || return 1
    for _c in $Z2K_TG_CIDRS6; do
        ipset add "$Z2K_TG_SET6" "$_c" -exist 2>/dev/null
    done
    return 0
}

# Is the v6 REJECT rule present in filter chain $1 (FORWARD|OUTPUT)?
z2k_tg_rule6_present() {
    _z2k_tg_ipt6 -C "$1" -p tcp -m set --match-set "$Z2K_TG_SET6" dst -j REJECT --reject-with tcp-reset
}

# Install both v6 REJECT rules (FORWARD for LAN clients, OUTPUT for the router
# itself). Best-effort: never blocks the v4 redirect contract. Returns 0 only
# when both are confirmed, but callers ignore the return.
z2k_tg_ensure_rules6() {
    z2k_tg_ensure_ipset6 || return 1
    _retry6=0
    while [ "$_retry6" -lt 3 ]; do
        z2k_tg_rule6_present FORWARD || _z2k_tg_ipt6 -I FORWARD 1 -p tcp -m set --match-set "$Z2K_TG_SET6" dst -j REJECT --reject-with tcp-reset
        z2k_tg_rule6_present OUTPUT  || _z2k_tg_ipt6 -I OUTPUT 1 -p tcp -m set --match-set "$Z2K_TG_SET6" dst -j REJECT --reject-with tcp-reset
        if z2k_tg_rule6_present FORWARD && z2k_tg_rule6_present OUTPUT; then
            return 0
        fi
        _retry6=$((_retry6 + 1))
        [ "$_retry6" -lt 3 ] && sleep 1
    done
    return 1
}

# Remove both v6 REJECT rules (tunnel stop). Loops in case of duplicates.
z2k_tg_remove_rules6() {
    while z2k_tg_rule6_present FORWARD; do
        _z2k_tg_ipt6 -D FORWARD -p tcp -m set --match-set "$Z2K_TG_SET6" dst -j REJECT --reject-with tcp-reset
    done
    while z2k_tg_rule6_present OUTPUT; do
        _z2k_tg_ipt6 -D OUTPUT -p tcp -m set --match-set "$Z2K_TG_SET6" dst -j REJECT --reject-with tcp-reset
    done
}

# Install both REDIRECT rules with verify-retry. Returns 0 only when both
# rules are confirmed present.
z2k_tg_ensure_rules() {
    z2k_tg_udp_down
    z2k_tg_ensure_ipset || return 1
    z2k_tg_ensure_rules6   # best-effort v6 fast-reject; does not gate v4 success
    _retry=0
    while [ "$_retry" -lt 3 ]; do
        z2k_tg_rule_present PREROUTING || _z2k_tg_ipt -t nat -I PREROUTING 1 -p tcp --dport 443 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"
        z2k_tg_rule_present OUTPUT     || _z2k_tg_ipt -t nat -I OUTPUT 1 -p tcp --dport 443 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"
        if z2k_tg_rule_present PREROUTING && z2k_tg_rule_present OUTPUT; then
            z2k_tg_remove_retired_tcp_rules
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
    z2k_tg_remove_retired_tcp_rules
    z2k_tg_udp_down
    z2k_tg_remove_rules6
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

# One-way migration from the retired 85.6-85.8 UDP experiment. These helpers
# only REMOVE its resources. TCP redirect remains exactly the 85.5 path.
Z2K_TG_UDP_IF=z2ktg0
Z2K_TG_UDP_MARK=0x8000000
Z2K_TG_UDP_TABLE=988
Z2K_TG_UDP_PREF=89
Z2K_TG_UDP_READY=/tmp/z2k-log/tg-udp.ready

_z2k_tg_udp_remove_legacy_policy() {
    while ip "$1" rule del pref "$Z2K_TG_UDP_PREF" fwmark "$Z2K_TG_UDP_MARK/$Z2K_TG_UDP_MARK" table "$Z2K_TG_UDP_TABLE" 2>/dev/null; do :; done
}

_z2k_tg_udp_family_down() {
    local fam="$1" set="$2" cmd="$3"
    while "$cmd" -t mangle -C PREROUTING -i br+ -p udp -m set --match-set "$set" dst -j Z2K_TG_UDP; do
        "$cmd" -t mangle -D PREROUTING -i br+ -p udp -m set --match-set "$set" dst -j Z2K_TG_UDP || break
    done
    while "$cmd" -t mangle -C PREROUTING -i "$Z2K_TG_UDP_IF" -j ACCEPT; do
        "$cmd" -t mangle -D PREROUTING -i "$Z2K_TG_UDP_IF" -j ACCEPT || break
    done
    while "$cmd" -C FORWARD -o "$Z2K_TG_UDP_IF" -p udp -m set --match-set "$set" dst -j ACCEPT; do
        "$cmd" -D FORWARD -o "$Z2K_TG_UDP_IF" -p udp -m set --match-set "$set" dst -j ACCEPT || break
    done
    while "$cmd" -C FORWARD -i "$Z2K_TG_UDP_IF" -p udp -m set --match-set "$set" src -m conntrack --ctstate ESTABLISHED -j ACCEPT; do
        "$cmd" -D FORWARD -i "$Z2K_TG_UDP_IF" -p udp -m set --match-set "$set" src -m conntrack --ctstate ESTABLISHED -j ACCEPT || break
    done
    while "$cmd" -t nat -C POSTROUTING -o "$Z2K_TG_UDP_IF" -j ACCEPT; do
        "$cmd" -t nat -D POSTROUTING -o "$Z2K_TG_UDP_IF" -j ACCEPT || break
    done
    "$cmd" -t mangle -F Z2K_TG_UDP || true
    "$cmd" -t mangle -X Z2K_TG_UDP || true
    while ip "$fam" rule del pref "$Z2K_TG_UDP_PREF" fwmark "$Z2K_TG_UDP_MARK/0xffffffff" table "$Z2K_TG_UDP_TABLE" 2>/dev/null; do :; done
    _z2k_tg_udp_remove_legacy_policy "$fam"
    ip "$fam" route flush table "$Z2K_TG_UDP_TABLE" 2>/dev/null || true
}

_z2k_tg_udp_down_unlocked() {
    _z2k_tg_udp_family_down -4 "$Z2K_TG_SET" _z2k_tg_ipt
    _z2k_tg_udp_family_down -6 "$Z2K_TG_SET6" _z2k_tg_ipt6
    rm -f "$Z2K_TG_UDP_READY"
}

z2k_tg_udp_down() { _z2k_tg_udp_down_unlocked; }
# Compatibility with a hook/supervisor already running during file replacement.
z2k_tg_udp_ensure() { z2k_tg_udp_down; }
z2k_tg_udp_enabled() { return 1; }

# File convergence may replace the old helper before stop runs. Remove the
# expanded TCP selector explicitly, while retaining the restored 443 rule.
z2k_tg_remove_retired_tcp_rules() {
    local chain
    for chain in PREROUTING OUTPUT; do
        while _z2k_tg_ipt -t nat -C "$chain" -p tcp -m multiport --dports 80,443,5222 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT"; do
            _z2k_tg_ipt -t nat -D "$chain" -p tcp -m multiport --dports 80,443,5222 -m set --match-set "$Z2K_TG_SET" dst -j REDIRECT --to-port "$Z2K_TG_PORT" || break
        done
    done
}
