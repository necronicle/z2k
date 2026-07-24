#!/bin/sh
# /opt/zapret2/z2k-ppe-deoffload.sh — per-flow hardware-offload exclusion (Keenetic MediaTek PPE).
#
# WHAT THIS IS FOR
#   On Keenetic (MediaTek MT7622/PPE) the firmware hardware-offloads forwarded
#   flows into the packet engine after the first data packet. The result:
#   nfqws2 sees only the first ClientHello and NEVER the CH retransmits / RST /
#   ServerHello, so for a silent-drop block it gets no failure signal and the
#   `circular` rotator stays stuck on a non-working strategy forever (mailsuite,
#   flibusta, etc.). See reference_whnat_offload_blinds_nfqws +
#   reference_keenetic_ppe_perflow_skip.
#
#   The firmware exposes its OWN per-flow offload-skip hook: the builtin iptables
#   target `-j PPE` (xt target ppe_tg). Matching the bypass-port flows and
#   sending them to `-j PPE` keeps THOSE flows off the hardware FoE binder (and
#   strips the [FASTNAT] software fastpath tag) so nfqws2 sees the retransmits
#   and rotates — while net.hwnat.ppe_enabled stays 1 and every OTHER flow keeps
#   hardware acceleration. Proven on KN-1811: mailsuite 1→2→302, foe/binds still
#   holds unrelated flows.
#
#   We gate it with `-m connskip --connskip N` (the firmware's own idiom, cf.
#   NDM's `dport 443 ... connskip --connskip 2 -j RETURN`): only the first N
#   packets of each connection — the handshake + CH-retransmit window — ride the
#   CPU; the bulk transfer re-accelerates in hardware after packet N. So the
#   throughput cost is bounded to the handshake, not the whole stream.
#
#   IMPORTANT companion: this only RESTORES VISIBILITY. The silent-drop CH
#   retransmit pattern caps nfqws2's retransmission counter at "1/2" (it dedups
#   identical-seq retransmits), so the rkn/yt/gv circulars must run `retrans=1`
#   (set by ensure_circular_retrans in config_official.sh) for the now-visible
#   fail to actually count. retrans=1 + this de-offload = native rotation works.
#
#   QUIC (UDP/443) gets the SAME treatment (Z2K_PPE_DEOFFLOAD_QUIC, default ON):
#   YouTube / Apple-TV login rides HTTP/3, and the yt_quic `circular` can only
#   rotate to a provider-working fake-blob if nfqws2 sees the QUIC response,
#   which the offload engine otherwise hides (the outgoing QUIC Initial is always
#   seen pre-bind, but the incoming verdict is not). Same connskip window bounds
#   it to the handshake; the bulk video stream re-accelerates in hardware.
#
# SINGLE SOURCE OF TRUTH for the selector, connskip window, the PPE target and
# the install/remove logic. Applied/sourced by: lib/install.sh (install +
# uninstall), the NDM netfilter.d hook (94-z2k-ppe-deoffload.sh, re-apply on
# table=mangle regen) and z2k-scheduler.sh (~55s re-assert, which also serves as
# the boot-time apply since the rule is self-contained — no ipset/order
# dependency). S99zapret2 is stock zapret (not z2k-managed) so it is NOT hooked.
#
# WHY it survives NDM wipes: like every z2k fw rule, NDM rebuilds the tables and
# drops non-NDM rules; the NDM hook re-asserts. The selector ipset (zport_tcp /
# nozapret) is z2k/NDM-owned and survives (ipsets are not wiped).

# ---- constants -------------------------------------------------------------
# Self-contained port match (NOT an ipset dependency): the rule can be (re)applied
# at any time — boot, NDM regen, watchdog — without waiting for zapret's
# zport_tcp/nozapret sets to exist, and S99zapret2 is stock (not z2k-managed) so
# we cannot hook its firewall apply. Ports mirror the bypass dst-port set. Only
# forwarded flows are touched (mangle FORWARD/PREROUTING), connskip-bounded to the
# handshake window, so de-offloading without the nozapret exclusion is harmless.
PPE_PORTS="${PPE_PORTS:-80,443,2053,2083,2087,2096,8443}"
PPE_QUIC_PORT="${PPE_QUIC_PORT:-443}"       # QUIC UDP port — de-offload its handshake window too
PPE_CONNSKIP="${PPE_CONNSKIP:-30}"          # first-N packets kept on CPU (handshake window)
PPE_TARGET="${PPE_TARGET:-PPE}"             # firmware per-flow offload-skip target (ppe_tg)
PPE_CONFIG_FILE="${PPE_CONFIG_FILE:-/opt/zapret2/config}"

# ---- xtables-lock-safe wrappers --------------------------------------------
_z2k_ppe_ipt()  { iptables  -w "$@" 2>/dev/null || iptables  "$@" 2>/dev/null; }
_z2k_ppe_ipt6() { ip6tables -w "$@" 2>/dev/null || ip6tables "$@" 2>/dev/null; }

# r-62 migration, ONE-SHOT: the legacy game-mode UDP de-offload was removed. Strip any
# orphaned game-port -j PPE rule left in mangle on a router that had game mode ON, so it
# doesn't linger forever. Nothing recreates that rule, so once drained the work is done —
# hence the marker. Without it this ran on EVERY assert, i.e. four iptables/ip6tables
# round-trips every ~55s from the scheduler plus one per NDM regen, forever, on every
# router in the fleet, for a rule that has not been created since r-62.
PPE_LEGACY_MARK="${PPE_LEGACY_MARK:-/opt/zapret2/.z2k-ppe-legacy-purged}"
_z2k_ppe_purge_legacy_game() {
    [ -f "$PPE_LEGACY_MARK" ] && return 0
    local a="-p udp -m multiport --dports 1024:2407,2409:65535 -m connskip --connskip $PPE_CONNSKIP -j $PPE_TARGET"
    local ch
    for ch in PREROUTING FORWARD; do
        while _z2k_ppe_ipt  -t mangle -C "$ch" $a; do _z2k_ppe_ipt  -t mangle -D "$ch" $a || break; done
        while _z2k_ppe_ipt6 -t mangle -C "$ch" $a; do _z2k_ppe_ipt6 -t mangle -D "$ch" $a || break; done
    done
    # `touch`, NOT `: > file`: `:` is a POSIX SPECIAL built-in, and a redirection error on a
    # special built-in makes the shell EXIT outright — dash and busybox ash both do it, so a
    # marker path that is not writable (read-only /opt after an unclean shutdown is a real
    # failure mode here) would kill the whole script mid-run, and neither `2>/dev/null` nor
    # `|| true` can catch it because the shell is already gone. touch is an ordinary command.
    touch "$PPE_LEGACY_MARK" 2>/dev/null || true
    return 0
}

# Has the user explicitly disabled the layer? (default ON)
z2k_ppe_user_disabled() {
    [ -f "$PPE_CONFIG_FILE" ] || return 1
    [ "$(awk -F= '/^Z2K_PPE_DEOFFLOAD=/{gsub(/[" ]/,"",$2);print $2;exit}' "$PPE_CONFIG_FILE" 2>/dev/null)" = "0" ] && return 0
    return 1
}

# Also de-offload the QUIC (UDP/443) handshake? (default ON; off only if =0).
# This restores the QUIC response so the yt_quic `circular` can rotate like the
# TCP pools — needed for YouTube/Apple-TV login over HTTP/3 on offload routers.
z2k_ppe_quic_enabled() {
    [ -f "$PPE_CONFIG_FILE" ] || return 0
    [ "$(awk -F= '/^Z2K_PPE_DEOFFLOAD_QUIC=/{gsub(/[" ]/,"",$2);print $2;exit}' "$PPE_CONFIG_FILE" 2>/dev/null)" = "0" ] && return 1
    return 0
}

# Is the firmware `-j PPE` target actually present? (no-op cleanly on
# non-Keenetic / kernels without ppe_tg). Cached in _Z2K_PPE_OK.
z2k_ppe_available() {
    [ -n "$_Z2K_PPE_OK" ] && { [ "$_Z2K_PPE_OK" = 1 ] && return 0 || return 1; }
    if grep -qx "$PPE_TARGET" /proc/net/ip_tables_targets 2>/dev/null; then
        _Z2K_PPE_OK=1; return 0
    fi
    _Z2K_PPE_OK=0; return 1
}

# Is the v6 path usable? (ip6tables present AND the v6 PPE target available)
z2k_ppe_v6_ok() {
    [ -n "$_Z2K_PPE_V6" ] && { [ "$_Z2K_PPE_V6" = 1 ] && return 0 || return 1; }
    if command -v ip6tables >/dev/null 2>&1 \
        && grep -qx "$PPE_TARGET" /proc/net/ip6_tables_targets 2>/dev/null; then
        _Z2K_PPE_V6=1; return 0
    fi
    _Z2K_PPE_V6=0; return 1
}

# ---- rule presence checks --------------------------------------------------
# De-offload the handshake window of every bypass-port forwarded flow. Both
# PREROUTING (pre-bind) and FORWARD (covers locally-rebound paths). Same shape
# for v4/v6 (multiport is family-agnostic).
_z2k_ppe_args="-p tcp -m multiport --dports $PPE_PORTS -m connskip --connskip $PPE_CONNSKIP -j $PPE_TARGET"

z2k_ppe_rule_present_fwd4() { _z2k_ppe_ipt  -t mangle -C FORWARD    $_z2k_ppe_args; }
z2k_ppe_rule_present_pre4() { _z2k_ppe_ipt  -t mangle -C PREROUTING $_z2k_ppe_args; }
z2k_ppe_rule_present_fwd6() { _z2k_ppe_ipt6 -t mangle -C FORWARD    $_z2k_ppe_args; }
z2k_ppe_rule_present_pre6() { _z2k_ppe_ipt6 -t mangle -C PREROUTING $_z2k_ppe_args; }

# QUIC (UDP) handshake de-offload — same connskip window, restores the HTTP/3
# response so yt_quic rotates. Single port (multiport not needed for one port).
_z2k_ppe_udp_args="-p udp --dport $PPE_QUIC_PORT -m connskip --connskip $PPE_CONNSKIP -j $PPE_TARGET"

z2k_ppe_udp_present_fwd4() { _z2k_ppe_ipt  -t mangle -C FORWARD    $_z2k_ppe_udp_args; }
z2k_ppe_udp_present_pre4() { _z2k_ppe_ipt  -t mangle -C PREROUTING $_z2k_ppe_udp_args; }
z2k_ppe_udp_present_fwd6() { _z2k_ppe_ipt6 -t mangle -C FORWARD    $_z2k_ppe_udp_args; }
z2k_ppe_udp_present_pre6() { _z2k_ppe_ipt6 -t mangle -C PREROUTING $_z2k_ppe_udp_args; }


# Install the rules (idempotent, v4 is the success gate, v6 best-effort).
z2k_ppe_ensure_rules() {
    # Availability first: where the firmware has no `-j PPE` target the legacy rule cannot
    # exist either, so the purge has nothing to do and shouldn't burn syscalls looking.
    z2k_ppe_available || return 1
    _z2k_ppe_purge_legacy_game
    z2k_ppe_user_disabled && return 1
    z2k_ppe_rule_present_pre4 || _z2k_ppe_ipt -t mangle -I PREROUTING $_z2k_ppe_args
    z2k_ppe_rule_present_fwd4 || _z2k_ppe_ipt -t mangle -I FORWARD    $_z2k_ppe_args
    if z2k_ppe_v6_ok; then
        z2k_ppe_rule_present_pre6 || _z2k_ppe_ipt6 -t mangle -I PREROUTING $_z2k_ppe_args
        z2k_ppe_rule_present_fwd6 || _z2k_ppe_ipt6 -t mangle -I FORWARD    $_z2k_ppe_args
    fi
    # QUIC (UDP/443) handshake de-offload — enables yt_quic native rotation.
    if z2k_ppe_quic_enabled; then
        z2k_ppe_udp_present_pre4 || _z2k_ppe_ipt -t mangle -I PREROUTING $_z2k_ppe_udp_args
        z2k_ppe_udp_present_fwd4 || _z2k_ppe_ipt -t mangle -I FORWARD    $_z2k_ppe_udp_args
        if z2k_ppe_v6_ok; then
            z2k_ppe_udp_present_pre6 || _z2k_ppe_ipt6 -t mangle -I PREROUTING $_z2k_ppe_udp_args
            z2k_ppe_udp_present_fwd6 || _z2k_ppe_ipt6 -t mangle -I FORWARD    $_z2k_ppe_udp_args
        fi
    fi
    z2k_ppe_rule_present_pre4 && z2k_ppe_rule_present_fwd4
}

# Remove the rules (loops in case of duplicates). v4 + v6.
z2k_ppe_remove_rules() {
    while z2k_ppe_rule_present_pre4; do _z2k_ppe_ipt -t mangle -D PREROUTING $_z2k_ppe_args; done
    while z2k_ppe_rule_present_fwd4; do _z2k_ppe_ipt -t mangle -D FORWARD    $_z2k_ppe_args; done
    while z2k_ppe_udp_present_pre4; do _z2k_ppe_ipt -t mangle -D PREROUTING $_z2k_ppe_udp_args; done
    while z2k_ppe_udp_present_fwd4; do _z2k_ppe_ipt -t mangle -D FORWARD    $_z2k_ppe_udp_args; done
    if command -v ip6tables >/dev/null 2>&1; then
        while z2k_ppe_rule_present_pre6; do _z2k_ppe_ipt6 -t mangle -D PREROUTING $_z2k_ppe_args; done
        while z2k_ppe_rule_present_fwd6; do _z2k_ppe_ipt6 -t mangle -D FORWARD    $_z2k_ppe_args; done
        while z2k_ppe_udp_present_pre6; do _z2k_ppe_ipt6 -t mangle -D PREROUTING $_z2k_ppe_udp_args; done
        while z2k_ppe_udp_present_fwd6; do _z2k_ppe_ipt6 -t mangle -D FORWARD    $_z2k_ppe_udp_args; done
    fi
    return 0
}
