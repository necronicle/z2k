#!/bin/sh
# /opt/zapret2/z2k-tpws.sh — shared helpers for the tpws transparent-proxy layer.
#
# WHAT THIS IS FOR
#   Some DPI blocks complete the TCP handshake but kill the TLS ClientHello
#   (no ServerHello, no RST visible to nfqws2). On Keenetic the NDM software
#   fastpath (fastvpn) offloads the *forwarded* client flow into the kernel
#   right after the handshake, so nfqws2 only ever sees the first ClientHello
#   and NEVER the retransmits / RST / ServerHello — it therefore cannot detect
#   the block and cannot rotate to a working strategy. www.youtube.com is the
#   canonical case (see reference_whnat_offload_blinds_nfqws).
#
#   bol-van's documented answer for un-removable offload is a TRANSPARENT tpws:
#   we REDIRECT the target traffic to a local tpws instance. Because the
#   connection is intercepted in nat PREROUTING it TERMINATES LOCALLY (it never
#   becomes a forwarded/offloaded flow), so tpws sees the whole stream and
#   re-emits its own outbound ClientHello with the SNI split across TCP
#   segments (--split-pos=1,midsld --disorder), which the DPI cannot reassemble.
#
# SINGLE SOURCE OF TRUTH for: the tpws port, the youtube ipset names + CIDR
# snapshot files, the desync recipe, and the install/remove/conntrack logic.
# Sourced by the init script (S95z2k-tpws), the NDM hook
# (93-z2k-tpws-redirect.sh) and the watchdog (z2k-tpws-watchdog.sh) so all
# three install the EXACT same rule shape and can never disagree.
#
# WHY ipset + -w (same root cause as the Telegram redirect, see
# z2k-tg-redirect.sh): NDM rebuilds the iptables nat table on every netfilter
# event and WIPES non-NDM rules, but it does NOT touch ipsets. So the youtube
# CIDR list (ipset) stays put; only the referencing REDIRECT rules need
# re-adding. iptables -w avoids the silent EBUSY lock-race rule drop.
#
# WHY ipset-targeted (not "redirect all :443"): keeps tpws's blast radius to
# youtube only — if tpws ever dies, the rest of HTTPS is untouched and native
# nfqws2 stays as a youtube fallback. Video is QUIC/UDP and bypasses tpws
# entirely (we only redirect TCP :443).

# ---- constants -------------------------------------------------------------
TPWS_BIN="${TPWS_BIN:-/opt/zapret2/tpws/tpws}"
TPWS_PORT="${TPWS_PORT:-1446}"          # 1443=TG 1444=cdn 1445=rt-proxy 1446=tpws
TPWS_USER="${TPWS_USER:-nobody}"        # priv-drop; mangle OUTPUT mark keys on this uid
TPWS_MARK="${TPWS_MARK:-0x40000000}"    # DESYNC_MARK — _fw_nfqws_post4 already excludes it
TPWS_SET4="${TPWS_SET4:-z2k_tpws}"
TPWS_SET6="${TPWS_SET6:-z2k_tpws6}"
TPWS_HOSTLIST="${TPWS_HOSTLIST:-/opt/zapret2/extra_strats/TCP/YT/List.txt}"
TPWS_HOSTLIST_GV="${TPWS_HOSTLIST_GV:-/opt/zapret2/extra_strats/TCP/YT_GV/List.txt}"
TPWS_CIDR4="${TPWS_CIDR4:-/opt/zapret2/lists/youtube_ips.txt}"
TPWS_CIDR6="${TPWS_CIDR6:-/opt/zapret2/lists/youtube_ips6.txt}"
TPWS_SPLIT="${TPWS_SPLIT:---split-pos=1,midsld --disorder}"
TPWS_PIDFILE="${TPWS_PIDFILE:-/var/run/z2k-tpws.pid}"
TPWS_LOG="${TPWS_LOG:-/tmp/z2k-log/z2k-tpws.log}"
TPWS_CONFIG_FILE="${TPWS_CONFIG_FILE:-/opt/zapret2/config}"

# ---- xtables-lock-safe wrappers (wait for lock, fall back on ancient ipt) ---
_z2k_tpws_ipt()  { iptables  -w "$@" 2>/dev/null || iptables  "$@" 2>/dev/null; }
_z2k_tpws_ipt6() { ip6tables -w "$@" 2>/dev/null || ip6tables "$@" 2>/dev/null; }

# Is IPv6 nat REDIRECT usable on this box? Detected once, cached.
z2k_tpws_v6_ok() {
    [ -n "$_Z2K_TPWS_V6" ] && { [ "$_Z2K_TPWS_V6" = 1 ] && return 0 || return 1; }
    if [ "$(awk -F= '/^DISABLE_IPV6=/{gsub(/[" ]/,"",$2);print $2;exit}' "$TPWS_CONFIG_FILE" 2>/dev/null)" = "1" ]; then
        _Z2K_TPWS_V6=0; return 1
    fi
    # -S (not -L): -L without -n does reverse-DNS per rule and can HANG under
    # xtables lock contention in the NDM hook; -S dumps rules with no lookups.
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -t nat -S PREROUTING >/dev/null 2>&1; then
        _Z2K_TPWS_V6=1; return 0
    fi
    _Z2K_TPWS_V6=0; return 1
}

# Is the tpws daemon actually alive? (pidfile holds the supervisor)
z2k_tpws_alive() {
    [ -f "$TPWS_PIDFILE" ] || return 1
    kill -0 "$(cat "$TPWS_PIDFILE" 2>/dev/null)" 2>/dev/null
}

# Has the user explicitly disabled the layer? (survives a stale process)
z2k_tpws_user_disabled() {
    [ -f "$TPWS_CONFIG_FILE" ] || return 1
    [ "$(awk -F= '/^Z2K_TPWS=/{gsub(/[" ]/,"",$2);print $2;exit}' "$TPWS_CONFIG_FILE" 2>/dev/null)" = "0" ] && return 0
    return 1
}

# ---- ipset (youtube CIDR ranges; survives NDM wipes) -----------------------
# Bulk-load a CIDR snapshot file into an ipset via `ipset restore` (one fork
# for ~535 entries instead of 535). Falls back to a per-line add loop.
_z2k_tpws_load_set() {
    _set="$1"; _file="$2"; _fam="$3"   # _fam: inet | inet6
    ipset create "$_set" hash:net family "$_fam" maxelem 65536 -exist 2>/dev/null || return 1
    [ -s "$_file" ] || return 1
    if ! grep -E '^[0-9A-Fa-f:.]+(/[0-9]+)?$' "$_file" \
        | sed "s#^#add $_set #; s#\$# -exist#" \
        | ipset restore -! 2>/dev/null; then
        # restore failed — per-line add fallback (return code is lost in the
        # pipe subshell, so we validate emptiness below instead).
        grep -E '^[0-9A-Fa-f:.]+(/[0-9]+)?$' "$_file" | while read -r _c; do
            ipset add "$_set" "$_c" -exist 2>/dev/null
        done
    fi
    # Success only if the set actually ended up non-empty. Return 1 ONLY when we
    # POSITIVELY see "Number of entries: 0" (don't fail-closed on ipset builds
    # that omit that line — treat unknown as success).
    case "$(ipset list "$_set" 2>/dev/null | awk -F'[: ]+' '/^Number of entries/{print $NF; exit}')" in
        0) return 1 ;;
    esac
    return 0
}

z2k_tpws_ensure_ipset() {
    _z2k_tpws_load_set "$TPWS_SET4" "$TPWS_CIDR4" inet || return 1
    z2k_tpws_v6_ok && _z2k_tpws_load_set "$TPWS_SET6" "$TPWS_CIDR6" inet6
    return 0
}

# ---- REDIRECT rules (client → tpws) ----------------------------------------
# Only PREROUTING (forwarded client traffic). NOT OUTPUT: the router itself
# doesn't browse youtube, and an OUTPUT redirect would loop tpws's own
# outbound (which connects to the very youtube IPs in the set) back into tpws.
z2k_tpws_rule_present4() {
    _z2k_tpws_ipt -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set "$TPWS_SET4" dst -j REDIRECT --to-port "$TPWS_PORT"
}
z2k_tpws_rule_present6() {
    _z2k_tpws_ipt6 -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set "$TPWS_SET6" dst -j REDIRECT --to-port "$TPWS_PORT"
}
# mangle OUTPUT mark on tpws's own outbound so nfqws2 POSTROUTING excludes it
# (it already skips -m mark $DESYNC_MARK) — prevents double-desync.
z2k_tpws_mark_present4() {
    _z2k_tpws_ipt -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner "$TPWS_USER" -j MARK --set-xmark "$TPWS_MARK/$TPWS_MARK"
}
z2k_tpws_mark_present6() {
    _z2k_tpws_ipt6 -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner "$TPWS_USER" -j MARK --set-xmark "$TPWS_MARK/$TPWS_MARK"
}

# Install every rule (v4 always, v6 best-effort), idempotent, verify-retry.
z2k_tpws_ensure_rules() {
    z2k_tpws_ensure_ipset || return 1
    _retry=0
    while [ "$_retry" -lt 3 ]; do
        z2k_tpws_rule_present4 || _z2k_tpws_ipt -t nat -I PREROUTING 1 -p tcp --dport 443 -m set --match-set "$TPWS_SET4" dst -j REDIRECT --to-port "$TPWS_PORT"
        z2k_tpws_mark_present4 || _z2k_tpws_ipt -t mangle -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$TPWS_USER" -j MARK --set-xmark "$TPWS_MARK/$TPWS_MARK"
        if z2k_tpws_v6_ok; then
            z2k_tpws_rule_present6 || _z2k_tpws_ipt6 -t nat -I PREROUTING 1 -p tcp --dport 443 -m set --match-set "$TPWS_SET6" dst -j REDIRECT --to-port "$TPWS_PORT"
            z2k_tpws_mark_present6 || _z2k_tpws_ipt6 -t mangle -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$TPWS_USER" -j MARK --set-xmark "$TPWS_MARK/$TPWS_MARK"
        fi
        if z2k_tpws_rule_present4 && z2k_tpws_mark_present4; then
            return 0
        fi
        _retry=$((_retry + 1))
        [ "$_retry" -lt 3 ] && sleep 1
    done
    return 1
}

# Remove every rule (loops in case duplicates exist). Leaves the ipset.
z2k_tpws_remove_rules() {
    while z2k_tpws_rule_present4; do
        _z2k_tpws_ipt -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set "$TPWS_SET4" dst -j REDIRECT --to-port "$TPWS_PORT"
    done
    while z2k_tpws_mark_present4; do
        _z2k_tpws_ipt -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner "$TPWS_USER" -j MARK --set-xmark "$TPWS_MARK/$TPWS_MARK"
    done
    if command -v ip6tables >/dev/null 2>&1; then
        while z2k_tpws_rule_present6; do
            _z2k_tpws_ipt6 -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set "$TPWS_SET6" dst -j REDIRECT --to-port "$TPWS_PORT"
        done
        while z2k_tpws_mark_present6; do
            _z2k_tpws_ipt6 -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner "$TPWS_USER" -j MARK --set-xmark "$TPWS_MARK/$TPWS_MARK"
        done
    fi
}

# Destroy the ipsets too (uninstall only).
z2k_tpws_destroy_ipset() {
    ipset destroy "$TPWS_SET4" 2>/dev/null || true
    ipset destroy "$TPWS_SET6" 2>/dev/null || true
}
