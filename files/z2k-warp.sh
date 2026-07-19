#!/bin/sh
# /opt/zapret2/z2k-warp.sh — game-mode-over-WARP engine for z2k.
#
# WHY (evidence, tested on a RU Keenetic 2026-07-19):
#   Cloudflare WARP native WireGuard (UDP 2408) is 5-tuple-blocked from RU —
#   handshake gets zero response, and nfqws2 desync (ipfrag/fake/udplen ×all)
#   does NOT pierce it (not a signature-DPI block). MASQUE over QUIC (UDP 443)
#   is throttled too. Only MASQUE over HTTP/2 (TCP 443) works — proven
#   warp=on, colo=Moscow, ~28 Mbit/s. So the engine is `usque` (userspace
#   MASQUE client, from the usque-keenetic package), NOT native WireGuard.
#   The KeeneticOS WireGuard component is NOT required (usque uses a TUN dev).
#
# WHAT: bring up the usque WARP tunnel (opkgtun0) and policy-route ONLY a
#   curated game-server ipset (z2k_warp) through it; everything else stays on
#   the direct WAN path. TG relay / VPS / normal traffic are never touched.
#   A single flag GAME_WARP_ENABLED (in /opt/zapret2/config) drives it, wired
#   to the webpanel + terminal toggle. Independent of the nfqws2 desync layer.
#
# Reused conventions: ZAPRET2_DIR default (feedback), iptables -w (xtables-lock),
#   /bin/ndmc + LD_LIBRARY_PATH= guard, netfilter.d + scheduler self-heal.

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"

# ---- tunables (config overrides win) -----------------------------------------
WARP_IFACE="${WARP_IFACE:-opkgtun0}"            # usque nativetun interface
WARP_TABLE="${WARP_TABLE:-989}"                 # dedicated route table
WARP_MARK="${WARP_MARK:-0x989}"                 # fwmark for the ip rule (avoids z2k 0x40000000 + NDM low marks)
WARP_IPSET="${WARP_IPSET:-z2k_warp}"            # game-server ipset routed via WARP
WARP_LIST="${WARP_LIST:-$ZAPRET2_DIR/lists/game-warp-ips.txt}"  # sanitized game CIDRs (shipped + refreshed)
USQUE_INIT="/opt/etc/init.d/S51usque"
USQUE_CONF="/opt/etc/usque/usque.conf"
USQUE_IPK_URL="https://side-effect-tm.github.io/usque-keenetic/all/usque-keenetic_0.3.0_all_entware.ipk"

_wlog() { echo "[z2k-warp] $*" >&2; }
_ndmc() { LD_LIBRARY_PATH= /bin/ndmc -c "$1" 2>/dev/null; }

warp_flag() {
    # read GAME_WARP_ENABLED (default 0)
    grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d ' '
}

# ---- usque engine ------------------------------------------------------------
# Install the usque-keenetic package if absent. Keenetic's opkg wget can't do
# the GitHub-Pages https feed ("not an http or ftp url"), so we curl the .ipk
# (curl has TLS, works from RU) and opkg-install the local file. HTTP/2 MUST be
# on: default HTTP2_ENABLE=0 uses QUIC/UDP which RU throttles → dead.
warp_ensure_usque() {
    if [ ! -x "$USQUE_INIT" ]; then
        # Serialize the install: a boot-time `enable` and a scheduler `selfheal`
        # firing in the same first-install window must NOT run two opkg installs at
        # once. Winner of the mkdir-lock installs; loser waits for it rather than
        # racing opkg or failing spuriously.
        if mkdir /tmp/z2k-warp-install.lock 2>/dev/null; then
            _wlog "usque-keenetic not installed — fetching .ipk"
            local ipk=/tmp/usque-keenetic.ipk
            if command -v z2k_fetch >/dev/null 2>&1; then
                z2k_fetch "$USQUE_IPK_URL" "$ipk" || curl -sSL --max-time 60 "$USQUE_IPK_URL" -o "$ipk"
            else
                curl -sSL --max-time 60 "$USQUE_IPK_URL" -o "$ipk"
            fi
            if [ -s "$ipk" ]; then
                opkg install "$ipk" >/tmp/z2k-warp-install.log 2>&1
            else
                _wlog "ipk download failed"
            fi
            rmdir /tmp/z2k-warp-install.lock 2>/dev/null
        else
            _wlog "usque install already in progress — waiting"
            local w=0
            while [ ! -x "$USQUE_INIT" ] && [ $w -lt 90 ]; do w=$((w+1)); sleep 1; done
        fi
        [ -x "$USQUE_INIT" ] || { _wlog "usque install failed/absent (see /tmp/z2k-warp-install.log)"; return 1; }
    fi
    # force HTTP/2 (TCP 443) — the only RU-viable transport
    if grep -q '^HTTP2_ENABLE=' "$USQUE_CONF" 2>/dev/null; then
        sed -i 's/^HTTP2_ENABLE=.*/HTTP2_ENABLE=1/' "$USQUE_CONF"
    else
        echo 'HTTP2_ENABLE=1' >> "$USQUE_CONF"
    fi
    # pick up the real usque interface name from the package config
    local ifc; ifc=$(grep -m1 '^IFACE=' "$USQUE_CONF" 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$ifc" ] && WARP_IFACE="$ifc"
    return 0
}

warp_usque_running() { ps w 2>/dev/null | grep -q '[u]sque nativetun'; }

# poll up to $1 seconds for the WARP interface to carry an IPv4 address
warp_wait_addr() {
    local i=0
    while [ "$i" -lt "$1" ]; do
        ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet ' && return 0
        i=$((i+1)); sleep 1
    done
    ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet '
}

# Serialize usque (re)starts: a boot-time enable and the scheduler's first selfheal can
# otherwise drive two concurrent S51usque restarts on the same daemon (fn_stop+fn_start
# racing → double-spawn / mutual-kill → wedged tunnel). mkdir is the atomic lock.
warp_usque_restart() {
    if mkdir /tmp/z2k-warp-up.lock 2>/dev/null; then
        "$USQUE_INIT" restart >/dev/null 2>&1
        rmdir /tmp/z2k-warp-up.lock 2>/dev/null
    else
        local w=0
        while [ -d /tmp/z2k-warp-up.lock ] && [ "$w" -lt 20 ]; do w=$((w+1)); sleep 1; done
    fi
}

warp_up() {
    warp_ensure_usque || return 1
    # Already running with an interface address → leave the tunnel alone. We do NOT
    # health-check here: warp_healthy's probe to cloudflare.com only crosses the tun
    # AFTER warp_pbr_up (cloudflare.com is in the routed ipset), so a check here would
    # always false-fail and trigger needless restarts that destabilise the bring-up
    # (the "won't turn on" bug). Tunnel health is verified in warp_enable, after the
    # route is up, by warp_verify_tunnel.
    if warp_usque_running && ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet '; then
        return 0
    fi
    warp_usque_restart
    warp_wait_addr 20 || { _wlog "warp iface $WARP_IFACE has no address"; return 1; }
    return 0
}

# Hard-stop usque (used only on a real teardown; the toggle-off path leaves usque
# running and just drops the route). S51usque's pidfile-based stop can miss orphans.
warp_down_usque() {
    [ -x "$USQUE_INIT" ] && "$USQUE_INIT" stop >/dev/null 2>&1
    local p
    for p in $(ps w 2>/dev/null | grep '[u]sque nativetun' | awk '{print $1}'); do kill "$p" 2>/dev/null; done
}

# ---- game ipset --------------------------------------------------------------
warp_ipset_load() {
    ipset create "$WARP_IPSET" hash:net family inet 2>/dev/null
    ipset flush "$WARP_IPSET" 2>/dev/null
    [ -s "$WARP_LIST" ] || { _wlog "game list $WARP_LIST missing/empty"; return 1; }
    # restore stream (fast bulk load); list is pre-sanitized at build time
    { echo "flush $WARP_IPSET"
      awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$/{print "add '"$WARP_IPSET"' "$0" -exist"}' "$WARP_LIST"
    } | ipset restore -exist 2>/dev/null
    local n; n=$(ipset list "$WARP_IPSET" 2>/dev/null | grep -c '/')
    _wlog "game ipset loaded: $n entries"
    return 0
}

# ---- policy routing (split-tunnel) ------------------------------------------
warp_pbr_up() {
    # route table pointing default at the WARP tun
    ip route replace default dev "$WARP_IFACE" table "$WARP_TABLE" 2>/dev/null
    ip rule show 2>/dev/null | grep -q "fwmark $WARP_MARK " || ip rule add fwmark "$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    # MASQUERADE onto the tun — MANDATORY. Packets policy-routed into the usque TUN
    # still carry the WAN source IP; without SNAT to the tun's own address the return
    # path is broken and everything routed through WARP blackholes (the wedge we hit).
    iptables -w -t nat -C POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null \
        || iptables -w -t nat -A POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null
    # Mark game-ipset dst ONLY in PREROUTING (forwarded LAN-client traffic — the
    # PS5/phones). We deliberately do NOT mark OUTPUT (router-origin): policy-routing
    # a LOCALLY-generated packet into the TUN breaks its reply path (the socket
    # expects the reply on the normal route), which blackholes the router's OWN
    # CF/AWS access (github fetches, webpanel assets, etc.). The router doesn't need
    # game routing anyway — only clients do. Forwarded traffic + MASQUERADE is the
    # standard, working VPN split-tunnel path.
    iptables -w -t mangle -C PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null \
        || iptables -w -t mangle -A PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null
    # MSS clamp on the tun so game TCP doesn't PMTU-blackhole behind MASQUE
    iptables -w -t mangle -C FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -w -t mangle -A FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
}

warp_pbr_down() {
    local ch
    for ch in OUTPUT PREROUTING; do   # OUTPUT drained too, to clean any legacy rule from older builds
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

# ---- lifecycle ---------------------------------------------------------------
warp_enable() {
    _wlog "enable"
    warp_up          || { _wlog "warp_up failed"; return 1; }
    warp_ipset_load  || return 1
    warp_pbr_up
    # Verify the tunnel actually forwards NOW that the route is up. If it genuinely
    # won't come up (e.g. CF throttle), fail + tear the route back down so the caller
    # reverts the flag — the UI must never claim ON over a dead/blackholing tunnel.
    if warp_verify_tunnel; then
        _wlog "game WARP mode ON (iface=$WARP_IFACE ipset=$WARP_IPSET)"
        return 0
    fi
    _wlog "tunnel would not come up (warp!=on) — enable failed"
    warp_pbr_down
    return 1
}

warp_disable() {
    _wlog "disable"
    # Drop ONLY the split-tunnel route; leave usque running (idle). Re-enable then just
    # re-adds the route — no usque restart, so it's instant and reliable. usque
    # nativetun idles with no traffic routed to it, so it costs ~nothing.
    warp_pbr_down
    rm -f /tmp/z2k-warp-lastrestart 2>/dev/null
    _wlog "game WARP mode OFF"
}

# Is the tunnel actually PASSING traffic (not just process-alive)? usque can wedge
# — process up, MASQUE connection dead — which blackholes everything routed through
# it. Since option-2 routes broad CF/AWS, a wedged tunnel = most of the web dies, so
# this health probe (warp=on via the tun) is load-bearing, not cosmetic.
warp_healthy() {
    curl -sS --max-time 8 --interface "$WARP_IFACE" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^warp=on'
}

# Confirm the tunnel forwards — VALID ONLY after warp_pbr_up (the probe crosses the tun
# only once cloudflare.com's ipset route is up). usque nativetun idles until traffic, so
# the first probes prime the reconnect; poll a few times, then one clean restart.
warp_verify_tunnel() {
    local i=0
    while [ "$i" -lt 6 ]; do warp_healthy && return 0; i=$((i+1)); sleep 2; done
    _wlog "tunnel not warp=on after route up — one clean usque restart + re-prime"
    warp_usque_restart; warp_wait_addr 15
    i=0
    while [ "$i" -lt 6 ]; do warp_healthy && return 0; i=$((i+1)); sleep 2; done
    return 1
}

# Re-apply after NDM firewall reload / WAN flap (scheduler + netfilter.d call this).
warp_selfheal() {
    [ "$(warp_flag)" = "1" ] || return 0
    warp_usque_running || warp_up || return 1
    ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet ' || return 0
    ipset list "$WARP_IPSET" >/dev/null 2>&1 || warp_ipset_load
    # Re-assert the split-tunnel BEFORE probing. warp_pbr_up is idempotent; running it
    # every tick heals an NDM reload / usque-restart that dropped the table-989 route.
    # It MUST come before warp_healthy — the probe only crosses the tun when the route
    # is up, so probing first would read a route-drop as a wedged tunnel and needlessly
    # restart usque.
    warp_pbr_up
    if ! warp_healthy; then
        sleep 3
        warp_healthy && return 0
        # Genuinely wedged (route is up, tunnel still dead). Restart once per 5 min so a
        # persistent non-tunnel probe failure can't thrash-restart a working tunnel.
        local now last stamp=/tmp/z2k-warp-lastrestart
        now=$(date +%s 2>/dev/null || echo 0)
        last=$(cat "$stamp" 2>/dev/null || echo 0)
        if [ "$now" = "0" ] || [ $((now - last)) -ge 300 ]; then
            _wlog "tunnel wedged (warp!=on) — restarting usque"
            echo "$now" > "$stamp"
            warp_usque_restart; sleep 6
            warp_pbr_up   # a usque restart drops the table-989 route
        else
            _wlog "tunnel unhealthy but restarted <5min ago — not thrashing"
        fi
    fi
}

case "$1" in
    enable)   warp_enable ;;
    disable)  warp_disable ;;
    selfheal) warp_selfheal ;;
    ipset)    warp_ipset_load ;;
    status)
        echo "flag=$(warp_flag) usque=$(warp_usque_running && echo up || echo down) iface=$WARP_IFACE addr=$(ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1) ipset=$(ipset list "$WARP_IPSET" 2>/dev/null | grep -c '/')"
        ;;
    *) echo "usage: $0 {enable|disable|selfheal|ipset|status}" >&2; exit 1 ;;
esac
