#!/bin/sh
# /opt/zapret2/z2k-warp.sh — game-mode-over-WARP for z2k: ROUTING ONLY.
#
# The tunnel itself is owned ENTIRELY by the usque-keenetic package: its own S51usque
# init brings the MASQUE-over-HTTP/2 tunnel up on opkgtun0 at boot and keeps it there.
# z2k does NOT start / restart / heal / lifecycle-manage usque — wrapping the package's
# lifecycle is exactly what raced it (the "first enable needs a reboot" saga: install-
# on-toggle vs scheduler selfheal, fn_setup vs the tun device, etc.). Our job is only:
#   install)  one-time — fetch the .ipk + opkg-install it, force HTTP/2 (RU needs MASQUE
#             over TCP; the package default is QUIC/UDP, which RU throttles), and patch a
#             race in the package's own S51usque. Called from install.sh at z2k setup.
#   enable)   ensure installed, then policy-route the curated game ipset (z2k_warp)
#             through the tunnel. Pure routing after the one-time install.
#   disable)  drop the route; the tunnel keeps running idle.
#   selfheal) re-assert the route an NDM firewall reload wiped. Never touches usque.
#
# WHY MASQUE-over-HTTP/2: RU 5-tuple-blocks WARP WireGuard (UDP 2408) and throttles QUIC;
# only usque MASQUE over TCP 443 connects (proven warp=on, colo=Moscow).

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"

# ---- tunables (environment overrides win; the config file is NOT read here,
# only GAME_WARP_ENABLED is grepped from it) -----------------------------------
WARP_IFACE="${WARP_IFACE:-opkgtun0}"            # usque tun interface (package-owned)
WARP_TABLE="${WARP_TABLE:-989}"                 # dedicated route table
WARP_MARK="${WARP_MARK:-0x989}"                 # fwmark for the ip rule
WARP_IPSET="${WARP_IPSET:-z2k_warp}"            # game-server ipset routed via WARP
WARP_LIST="${WARP_LIST:-$ZAPRET2_DIR/lists/game-warp-ips.txt}"   # legacy shipped list — now only the migration seed
WARP_LISTS_DIR="${WARP_LISTS_DIR:-$ZAPRET2_DIR/lists/warp}"      # user-owned lists (webpanel «WARP» section), ALL *.txt loaded
USQUE_INIT="/opt/etc/init.d/S51usque"
USQUE_CONF="/opt/etc/usque/usque.conf"
USQUE_IPK_URL="https://side-effect-tm.github.io/usque-keenetic/all/usque-keenetic_0.3.0_all_entware.ipk"

_wlog() { echo "[z2k-warp] $*" >&2; }

warp_flag() { grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d ' '; }

# ---- one-time install (NOT lifecycle management) -----------------------------
# Fetch + opkg-install the usque package, force HTTP/2, and fix a race in its own
# S51usque (fn_setup_tun_interface configures the NDM interface right after start-stop-
# daemon backgrounds the usque daemon — before that daemon created the opkgtun0 tun
# device → NDM "no such device" → fn_start kills usque → reboot needed; we inject a wait
# for the tun netdev before that ndmc config). Fully IDEMPOTENT — a no-op once usque is
# installed, HTTP/2 is on and S51usque is patched, so it never restarts usque per-toggle.
warp_install() {
    if [ -x "$USQUE_INIT" ] \
       && grep -q '^HTTP2_ENABLE=1' "$USQUE_CONF" 2>/dev/null \
       && grep -q '_z2kw=0' "$USQUE_INIT" 2>/dev/null; then
        return 0
    fi
    if [ ! -x "$USQUE_INIT" ]; then
        # Keenetic's opkg wget can't fetch the GitHub-Pages https feed; curl (TLS, works
        # from RU) the .ipk and opkg-install the local file.
        _wlog "installing usque-keenetic (.ipk)"
        ipk=/tmp/usque-keenetic.ipk
        if command -v z2k_fetch >/dev/null 2>&1; then
            z2k_fetch "$USQUE_IPK_URL" "$ipk" || curl -sSL --max-time 60 "$USQUE_IPK_URL" -o "$ipk"
        else
            curl -sSL --max-time 60 "$USQUE_IPK_URL" -o "$ipk"
        fi
        [ -s "$ipk" ] && opkg install "$ipk" >/tmp/z2k-warp-install.log 2>&1
        [ -x "$USQUE_INIT" ] || { _wlog "usque install failed (see /tmp/z2k-warp-install.log)"; return 1; }
    fi
    # Fix the package's tun-device race (idempotent; re-applied because a package upgrade
    # overwrites S51usque). busybox `sleep` is integer-only.
    if ! grep -q '_z2kw=0' "$USQUE_INIT" 2>/dev/null; then
        sed -i '/echo "Setup tun interface/a\    _z2kw=0; while [ $_z2kw -lt 30 ] \&\& ! ip link show "$IFACE" >/dev/null 2>&1; do _z2kw=$((_z2kw+1)); sleep 1; done' "$USQUE_INIT" 2>/dev/null
    fi
    # Force MASQUE over HTTP/2 (TCP 443): package default HTTP2_ENABLE=0 uses QUIC/UDP,
    # which RU throttles → the tunnel never connects.
    if grep -q '^HTTP2_ENABLE=' "$USQUE_CONF" 2>/dev/null; then
        sed -i 's/^HTTP2_ENABLE=.*/HTTP2_ENABLE=1/' "$USQUE_CONF"
    else
        echo 'HTTP2_ENABLE=1' >> "$USQUE_CONF"
    fi
    # ONE restart so the package brings the tunnel up on HTTP/2 with the race patch. This
    # is the ONLY time z2k (re)starts usque — a one-off at install/setup, never per toggle;
    # the package's S51usque owns the tunnel from here on, including every boot.
    "$USQUE_INIT" restart >/dev/null 2>&1
    _wlog "usque installed + HTTP/2 forced"
    return 0
}

# ---- WARP lists (user-owned) -------------------------------------------------
# All $WARP_LISTS_DIR/*.txt are loaded into the ipset. The dir is user-owned:
# the webpanel «WARP» section CRUDs files here, install/auto-update never write
# into it (install.sh backs it up / restores it across reinstall). One-time
# migration seeds it with a copy of the legacy shipped game list. The EXISTENCE
# of the dir is the "migrated" marker — do NOT re-seed an existing (even empty)
# dir, that would resurrect a list the user deliberately deleted.
warp_lists_migrate() {
    [ -d "$WARP_LISTS_DIR" ] && return 0
    mkdir -p "$WARP_LISTS_DIR" || { _wlog "cannot create $WARP_LISTS_DIR"; return 1; }
    if [ -s "$WARP_LIST" ]; then
        if cp "$WARP_LIST" "$WARP_LISTS_DIR/game-warp-ips.txt" 2>/dev/null; then
            # Seed the 3-way-merge baseline too (see z2k-update-lists.sh
            # update_warp_game_list): the baseline records the last upstream
            # snapshot, so a user edit made BEFORE the first list refresh is
            # correctly preserved instead of being wiped by that refresh.
            cp "$WARP_LIST" "$WARP_LISTS_DIR/.game-warp-ips.base" 2>/dev/null
            _wlog "migrated $WARP_LIST -> $WARP_LISTS_DIR/game-warp-ips.txt"
        fi
    fi
    chmod 644 "$WARP_LISTS_DIR"/*.txt 2>/dev/null
    return 0
}

warp_ipset_count() {
    ipset list "$WARP_IPSET" 2>/dev/null | awk '/^Members:/{m=1;next} m&&NF{n++} END{print n+0}'
}

warp_ipset_load() {
    warp_lists_migrate
    ipset create "$WARP_IPSET" hash:net family inet 2>/dev/null
    ipset list "$WARP_IPSET" >/dev/null 2>&1 || { _wlog "cannot create ipset $WARP_IPSET"; return 1; }
    # Lists are user-edited now, so validate STRICTLY (mirrors the webpanel
    # save-time filter in actions.sh warp_list_save — keep in sync):
    #   - octets 0-255 with NO leading zeros (ipset parses 010.1.2.3 as OCTAL
    #     8.1.2.3 — silently wrong address; 08.8.8.8 doesn't parse at all),
    #   - first octet >= 1, prefix 1-32 (hash:net rejects cidr 0),
    # because ONE line ipset can't parse aborts the whole restore stream.
    # Defence in depth for that abort: load into a TEMP set and atomically
    # `ipset swap` it in — a failed restore then leaves the LIVE set intact
    # instead of the old flush-first stream that left it empty.
    # An empty/absent set of lists is a VALID state (user deleted everything):
    # the set just becomes empty and the PBR marks match nothing.
    local tmpset="${WARP_IPSET}_new"
    ipset destroy "$tmpset" 2>/dev/null
    ipset create "$tmpset" hash:net family inet 2>/dev/null
    ipset list "$tmpset" >/dev/null 2>&1 || { _wlog "cannot create temp ipset $tmpset"; return 1; }
    if cat "$WARP_LISTS_DIR"/*.txt 2>/dev/null | awk -v set="$tmpset" '
        {
            sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
            if ($0 !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/) next
            ip = $0
            if (split($0, halves, "/") == 2) ip = halves[1]
            split(ip, o, ".")
            if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) next
            print "add " set " " $0 " -exist"
        }' | ipset restore -exist 2>/dev/null; then
        ipset swap "$tmpset" "$WARP_IPSET" 2>/dev/null \
            || { _wlog "ipset swap failed — keeping previous set"; ipset destroy "$tmpset" 2>/dev/null; return 1; }
        ipset destroy "$tmpset" 2>/dev/null
        _wlog "warp ipset loaded: $(warp_ipset_count) entries"
    else
        _wlog "ipset restore failed — keeping previous set ($(warp_ipset_count) entries)"
        ipset destroy "$tmpset" 2>/dev/null
        return 1
    fi
}

# ---- policy routing (split-tunnel) — this is the ONLY thing the toggle does --
warp_pbr_up() {
    # Steer ONLY the marked game traffic out the WARP tun. We do NOT MASQUERADE or MSS-clamp:
    # `usque`/opkgtun0 is a Keenetic GLOBAL interface, so NDM NATs it and clamps its MSS
    # (`ip tcp adjust-mss pmtu`) NATIVELY. Verified on-router: forwarded traffic egressing
    # opkgtun0 gets warp=on with ZERO z2k NAT — a z2k MASQUERADE would just be a redundant
    # double-SNAT (that was our mistake). Drain any legacy z2k MASQUERADE/MSS first so a
    # router upgraded from the old code stops double-NATing.
    while iptables -w -t nat -C POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null; do
        iptables -w -t nat -D POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null || break
    done
    while iptables -w -t mangle -C FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
        iptables -w -t mangle -D FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || break
    done
    # split-tunnel: fwmark → table → opkgtun0
    ip route replace default dev "$WARP_IFACE" table "$WARP_TABLE" 2>/dev/null
    ip rule show 2>/dev/null | grep -q "fwmark $WARP_MARK " || ip rule add fwmark "$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    # Mark game-ipset dst ONLY in PREROUTING (forwarded LAN-client traffic — PS5/phones).
    # NOT OUTPUT (router-origin) — routing a locally-generated packet into the TUN breaks
    # its reply path and blackholes the router's own CF/AWS access (github / VPS fetches).
    iptables -w -t mangle -C PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null \
        || iptables -w -t mangle -A PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null
}

warp_pbr_down() {
    for ch in OUTPUT PREROUTING; do   # OUTPUT drained too, to clean any legacy rule
        while iptables -w -t mangle -C "$ch" -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null; do
            iptables -w -t mangle -D "$ch" -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null || break
        done
    done
    while iptables -w -t mangle -C FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
        iptables -w -t mangle -D FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || break
    done
    while iptables -w -t nat -C POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null; do
        iptables -w -t nat -D POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null || break
    done
    ip rule del fwmark "$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    ip route flush table "$WARP_TABLE" 2>/dev/null
}

# ---- toggle (routing only) ---------------------------------------------------
warp_enable() {
    _wlog "enable"
    warp_install || { _wlog "usque not available — режим не включён"; return 1; }
    warp_ipset_load || return 1
    warp_pbr_up
    _wlog "game WARP mode ON (route → $WARP_IFACE, ipset=$WARP_IPSET)"
}

warp_disable() {
    _wlog "disable"
    warp_pbr_down          # tunnel keeps running idle; re-enable just re-adds the route
    _wlog "game WARP mode OFF"
}

# Re-assert the split-tunnel route an NDM firewall reload / WAN flap wiped. ROUTE-ONLY:
# never installs / starts / restarts usque. If the tunnel is not up, that's the
# package's / boot's job — we stay out of the way.
warp_selfheal() {
    [ "$(warp_flag)" = "1" ] || return 0
    ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet ' || return 0
    ipset list "$WARP_IPSET" >/dev/null 2>&1 || warp_ipset_load
    warp_pbr_up
}

case "$1" in
    install)  warp_install ;;
    enable)   warp_enable ;;
    disable)  warp_disable ;;
    selfheal) warp_selfheal ;;
    ipset)    warp_ipset_load ;;
    migrate)  warp_lists_migrate ;;
    status)
        echo "flag=$(warp_flag) iface=$WARP_IFACE addr=$(ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1) ipset=$(warp_ipset_count)"
        ;;
    *) echo "usage: $0 {install|enable|disable|selfheal|ipset|migrate|status}" >&2; exit 1 ;;
esac
