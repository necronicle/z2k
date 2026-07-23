#!/bin/sh
# /opt/zapret2/z2k-warp.sh — game-mode-over-WARP for z2k: ROUTING ONLY.
#
# The tunnel itself is owned by the usque-keenetic package: its S51usque init brings the
# MASQUE-over-HTTP/2 tunnel up on opkgtun0 at boot. z2k does NOT lifecycle-manage usque
# per-toggle — gratuitous restarts are what raced the "first enable needs a reboot" saga
# (install-on-toggle vs scheduler selfheal, fn_setup vs the tun device). z2k restarts usque
# ONLY in three bounded, guarded cases, NEVER per-toggle:
#   1. one-time install — fetch .ipk, force HTTP/2 (RU needs MASQUE over TCP; the package
#      default QUIC/UDP is throttled), and patch a race in the package's own S51usque.
#   2. one-time IFACE_IP migration — the package auto-picks opkgtun0's local address from
#      172.16.1.100-200, which COLLIDES with Keenetic's built-in VPN servers (SSTP/L2TP
#      default to the same 172.16.1.x pool) → NDM address collision, the tunnel won't come
#      up cleanly. Pin it to a subnet nothing on Keenetic defaults to (guarded: writes once).
#   3. down-tunnel recovery — if WARP is on but opkgtun0 has no address, nudge usque the way
#      a manual "usque off/on" does (the package does NOT self-retry a failed/raced start,
#      which is why the manual toggle heals it). COOLDOWN-guarded so a genuinely-blocked
#      endpoint isn't hammered — no restart storm.
# Everything else is pure routing:
#   enable)   ensure installed, policy-route the curated game ipset (z2k_warp) via the tun.
#   disable)  drop the route; the tunnel keeps running idle.
#   selfheal) re-assert a route an NDM firewall reload wiped, plus cases 2/3 above.
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
# opkgtun0 local address. The package auto-picks the first free host in 172.16.1.100-200,
# which collides with Keenetic's built-in VPN servers (SSTP/L2TP default to 172.16.1.x).
# Pin it out of that pool. A user-set IFACE_IP in usque.conf always wins (we never clobber it).
WARP_IFACE_IP="${WARP_IFACE_IP:-172.16.240.1}"
WARP_KICK_COOLDOWN="${WARP_KICK_COOLDOWN:-300}"     # min seconds between down-tunnel usque restarts
WARP_KICK_STAMP="${WARP_KICK_STAMP:-/tmp/z2k-warp-kick.stamp}"
USQUE_BIN="${USQUE_BIN:-/opt/usr/bin/usque}"
USQUE_SESSION="${USQUE_SESSION:-/opt/etc/usque/session.conf}"
# WARP enrollment fallback. usque enrolls a device by POSTing to api.cloudflareclient.com;
# some ISPs DPI-block that endpoint (TLS handshake timeout) → no session.conf → no tunnel.
# The direct enroll IS desynced (cloudflareclient.com is in the bypass hostlist); if it still
# can't punch through after WARP_REG_DIRECT_TRIES attempts, enroll THROUGH the VPS relay — a
# restricted CONNECT proxy (only api.cloudflareclient.com:443) that reaches the CF reg API.
# Fallback-only: most routers enroll directly (correct region) and never touch the VPS.
WARP_VPS_PROXY="${WARP_VPS_PROXY:-http://z2kwarp:z2kW4rpR3g2026@213.176.74.63:8119}"
WARP_REG_DIRECT_TRIES="${WARP_REG_DIRECT_TRIES:-3}"
WARP_REG_COUNT="${WARP_REG_COUNT:-/tmp/z2k-warp-regcount}"
WARP_REG_STAMP="${WARP_REG_STAMP:-/tmp/z2k-warp-reg.stamp}"
WARP_REG_COOLDOWN="${WARP_REG_COOLDOWN:-600}"       # min seconds between VPS-relay enroll attempts

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
       && grep -q '_z2kw=0' "$USQUE_INIT" 2>/dev/null \
       && grep -q '^IFACE_IP=' "$USQUE_CONF" 2>/dev/null; then
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
    # Move opkgtun0 off the 172.16.1.x pool the package auto-picks (collides with Keenetic
    # SSTP/L2TP VPN servers). The single restart below applies both HTTP/2 and this.
    warp_write_iface_ip
    # ONE restart so the package brings the tunnel up on HTTP/2 (+ pinned address) with the
    # race patch. A one-off at install/setup, never per toggle; the package's S51usque owns
    # the tunnel from here on, including every boot.
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

# The usque-keenetic package assigns opkgtun0 an address but does NOT reliably bring the
# link UP — it flaps up/down across (re)starts. A down link WITH an address routes nothing
# and makes `ip route ... dev opkgtun0` fail ("Network is down"), so the tunnel reads as
# "не запущен" in the panel even though usque is running. Bring the link up if the device
# exists but isn't UP. Routing-layer only — does not touch usque's tunnel or lifecycle.
warp_link_up() {
    ip link show "$WARP_IFACE" >/dev/null 2>&1 || return 1           # device not created yet
    ip link show "$WARP_IFACE" 2>/dev/null | grep -qw UP && return 0 # already UP (word match, not LOWER_UP)
    _wlog "$WARP_IFACE link is down — bringing it up"
    ip link set "$WARP_IFACE" up 2>/dev/null
}

# ---- policy routing (split-tunnel) — this is the ONLY thing the toggle does --
warp_pbr_up() {
    warp_link_up   # the package often leaves opkgtun0's link DOWN; route add needs it UP
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
    # warp_install may have restarted usque (IFACE_IP migration). Give opkgtun0 a moment to
    # come up (address + link UP) so the route lands on a live interface instead of racing a
    # not-yet-ready one — otherwise the panel shows "не запущен" until the next selfheal tick.
    local _wait=0
    while [ "$_wait" -lt 25 ]; do
        warp_link_up
        ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet ' \
            && ip link show "$WARP_IFACE" 2>/dev/null | grep -qw UP && break
        _wait=$((_wait + 1)); sleep 1
    done
    warp_pbr_up
    _wlog "game WARP mode ON (route → $WARP_IFACE, ipset=$WARP_IPSET)"
}

warp_disable() {
    _wlog "disable"
    warp_pbr_down          # tunnel keeps running idle; re-enable just re-adds the route
    _wlog "game WARP mode OFF"
}

# Case 2 (see header): pin opkgtun0 off the 172.16.1.x pool the package auto-picks, which
# collides with Keenetic's SSTP/L2TP VPN servers. Appends IFACE_IP to usque.conf ONLY if
# neither the user nor a prior run already set one — so it's one-time and never clobbers a
# user's own choice. Returns 0 iff it wrote (the caller must then restart usque to apply it).
warp_write_iface_ip() {
    [ -f "$USQUE_CONF" ] || return 1
    grep -q '^IFACE_IP=' "$USQUE_CONF" 2>/dev/null && return 1
    printf '%s\n' "IFACE_IP=\"$WARP_IFACE_IP\"  # z2k: off Keenetic SSTP/VPN 172.16.1.x" >> "$USQUE_CONF" \
        || return 1
    _wlog "pinned opkgtun0 IFACE_IP=$WARP_IFACE_IP (package auto-picks SSTP-colliding 172.16.1.x)"
    return 0
}

# Case 3 (see header): the tunnel is down and the package does not self-retry — restart usque
# the way a manual "usque off/on" does. COOLDOWN-guarded via a stamp file so a genuinely-
# blocked endpoint gets at most one restart per WARP_KICK_COOLDOWN, never a storm.
warp_usque_kick() {
    [ -x "$USQUE_INIT" ] || return 0
    local now last
    now=$(date +%s 2>/dev/null) || return 0
    case "$now" in ''|*[!0-9]*) return 0 ;; esac
    if [ -f "$WARP_KICK_STAMP" ]; then
        last=$(cat "$WARP_KICK_STAMP" 2>/dev/null)
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        # A future stamp (router clock skewed ahead at boot, before NTP corrects it back)
        # would keep now-last negative forever and wedge recovery — treat it as no stamp.
        [ "$last" -gt "$now" ] && last=0
        [ $((now - last)) -lt "$WARP_KICK_COOLDOWN" ] && return 0
    fi
    # Persist the stamp BEFORE restarting; if it can't be written (read-only / full /tmp under
    # OOM pressure) do NOT restart — otherwise a down tunnel would restart usque every tick, the
    # exact storm the cooldown exists to prevent.
    { echo "$now" > "$WARP_KICK_STAMP"; } 2>/dev/null || return 0
    _wlog "opkgtun0 down — restarting usque to reconnect (cooldown ${WARP_KICK_COOLDOWN}s)"
    "$USQUE_INIT" restart >/dev/null 2>&1
}

# Enrollment fallback: enroll a device THROUGH the VPS relay when the direct (desynced) enroll
# can't reach api.cloudflareclient.com. usque honours HTTPS_PROXY, so we just point it at the
# restricted CONNECT proxy. COOLDOWN-guarded. On success writes session.conf and restarts usque.
warp_vps_register() {
    [ -x "$USQUE_BIN" ] || return 1
    [ -n "$WARP_VPS_PROXY" ] || return 1
    local now last
    now=$(date +%s 2>/dev/null) || return 1
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    if [ -f "$WARP_REG_STAMP" ]; then
        last=$(cat "$WARP_REG_STAMP" 2>/dev/null)
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        [ "$last" -gt "$now" ] && last=0
        [ $((now - last)) -lt "$WARP_REG_COOLDOWN" ] && return 1
    fi
    { echo "$now" > "$WARP_REG_STAMP"; } 2>/dev/null || return 1
    _wlog "direct enroll blocked — enrolling via VPS relay"
    HTTPS_PROXY="$WARP_VPS_PROXY" https_proxy="$WARP_VPS_PROXY" \
        "$USQUE_BIN" register --accept-tos --config "$USQUE_SESSION" >/dev/null 2>&1
    if [ -s "$USQUE_SESSION" ]; then
        _wlog "VPS enrollment OK — restarting usque"
        "$USQUE_INIT" restart >/dev/null 2>&1
        return 0
    fi
    _wlog "VPS enrollment failed"
    return 1
}

# Enrollment gate. No session.conf means the device was never enrolled, so the tunnel can't
# exist. Give the DIRECT enroll (desynced, region-correct) a few tries first — each S51usque
# restart re-runs `usque register` and lets autocircular rotate the strategy on
# cloudflareclient.com — then fall back to the VPS relay only for routers whose ISP blocks the
# reg API outright. Returns 0 when it handled enrollment this tick (selfheal should stop),
# 1 when already enrolled (selfheal proceeds to route).
warp_enroll_or_fallback() {
    if [ -s "$USQUE_SESSION" ]; then
        [ -f "$WARP_REG_COUNT" ] && rm -f "$WARP_REG_COUNT" 2>/dev/null
        return 1
    fi
    local n
    n=$(cat "$WARP_REG_COUNT" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -lt "$WARP_REG_DIRECT_TRIES" ]; then
        { echo $((n + 1)) > "$WARP_REG_COUNT"; } 2>/dev/null
        _wlog "no session.conf — direct enroll retry $((n + 1))/$WARP_REG_DIRECT_TRIES (desync)"
        "$USQUE_INIT" restart >/dev/null 2>&1
    else
        warp_vps_register
    fi
    return 0
}

# Re-assert the split-tunnel route an NDM firewall reload / WAN flap wiped, and — unlike the
# old route-only version — recover a down tunnel (cases 2/3 in the header) that the package
# left dead, which is what forced users to toggle usque by hand. Called ~every minute by the
# scheduler.
warp_selfheal() {
    [ "$(warp_flag)" = "1" ] || return 0
    # Case 2: one-time migration off the SSTP-colliding subnet (restart once to apply).
    if warp_write_iface_ip; then
        "$USQUE_INIT" restart >/dev/null 2>&1
        return 0    # tunnel is restarting on the new address; next tick asserts the route
    fi
    # Enrollment: if there's no session.conf the device was never enrolled (reg API blocked) —
    # retry the direct desynced enroll a few times, then fall back to the VPS relay. Nothing to
    # route/kick until a device key exists, so stop here when this handled it.
    warp_enroll_or_fallback && return 0
    # The package often leaves opkgtun0 with an address but the link DOWN — bring it up so a
    # down-but-present interface is recovered here instead of being read as "up" and left dead.
    warp_link_up
    # Case 3: tunnel not routable — no address, OR the link is still down after the nudge above
    # (device gone / usque wedged). Restart usque (cooldown-guarded); can't route a dead iface.
    if ! ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet ' \
       || ! ip link show "$WARP_IFACE" 2>/dev/null | grep -qw UP; then
        warp_usque_kick
        return 0
    fi
    ipset list "$WARP_IPSET" >/dev/null 2>&1 || warp_ipset_load
    warp_pbr_up
}

# Sourced by tests/test_warp_selfheal.sh to exercise the functions with stubs — skip the
# dispatch so `. z2k-warp.sh` doesn't run anything (mirrors z2k-update-lists.sh).
[ -n "$Z2K_WARP_SOURCE_ONLY" ] && return 0

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
