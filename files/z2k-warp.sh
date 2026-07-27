#!/bin/sh
# /opt/zapret2/z2k-warp.sh — game-mode-over-WARP for z2k: ROUTING ONLY.
#
# The TUNNEL LIFECYCLE is ours: /opt/etc/init.d/S51z2k-warp supervises upstream's `usque`
# engine, owns the interface name and address, configures NDM only after the tun device
# exists, and stops cleanly. The usque-keenetic package is no longer used — it only
# repackaged the same upstream binary while adding the init script whose assumptions caused
# every WARP failure we chased (see that init for the itemised list).
# Everything else is pure routing:
#   enable)   ensure installed, policy-route the curated game ipset (z2k_warp) via the tun,
#             then VERIFY end-to-end and report honestly (rc 0 live / 2 up-but-dead / 1 hard fail).
#   disable)  drop the route; the tunnel keeps running idle.
#   selfheal) install usque if it is missing, re-assert a route an NDM firewall reload wiped,
#             plus cases 2/3 above.
#
# LIVENESS IS PROVEN, NOT ASSUMED. Every "is the tunnel up?" question here is answered by an
# end-to-end probe through opkgtun0 (warp_tunnel_live), never by the presence of an address:
# NDM assigns that address at start time regardless of whether the MASQUE session to Cloudflare
# ever established, so "has an address" was reporting dead tunnels as healthy — the panel said
# "работает", nothing ever self-healed, and users were told to reboot.
#
# WHY MASQUE-over-HTTP/2: RU 5-tuple-blocks WARP WireGuard (UDP 2408) and throttles QUIC;
# only usque MASQUE over TCP 443 connects (proven warp=on, colo=Moscow).

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"

# ---- tunables (environment overrides win; the config file is NOT read here,
# only GAME_WARP_ENABLED is grepped from it) -----------------------------------
# Interface name. OUR init picks it once and records it; we just read that. (It used to be
# derived from the package's usque.conf, which re-derived "first free opkgtunN" on every
# install — that is how a leftover interface silently relocated the real tunnel.)
WARP_IFACE_DEFAULT="${WARP_IFACE_DEFAULT:-opkgtun0}"
warp_resolve_iface() {
    local i
    i=$(cat "$WARP_DIR/iface" 2>/dev/null)
    case "$i" in
        opkgtun[0-9]*) printf '%s' "$i" ;;
        *)             printf '%s' "$WARP_IFACE_DEFAULT" ;;
    esac
}
WARP_TABLE="${WARP_TABLE:-989}"                 # dedicated route table
WARP_MARK="${WARP_MARK:-0x989}"
# Explicit ip-rule preference — see warp_pbr_up.
WARP_RULE_PREF="${WARP_RULE_PREF:-90}"
# Must match the init's MTU. 1280 is the only value upstream supports in h2 mode.
WARP_MTU="${WARP_MTU:-1280}"                 # fwmark for the ip rule
WARP_IPSET="${WARP_IPSET:-z2k_warp}"            # game-server ipset routed via WARP
WARP_LIST="${WARP_LIST:-$ZAPRET2_DIR/lists/game-warp-ips.txt}"   # legacy shipped list — now only the migration seed
WARP_LISTS_DIR="${WARP_LISTS_DIR:-$ZAPRET2_DIR/lists/warp}"      # user-owned lists (webpanel «WARP» section), ALL *.txt loaded
# OUR init, not the package's. The engine binary stays upstream's usque; everything about
# starting it, naming the interface, configuring NDM and stopping cleanly is ours now —
# see files/init.d/S51z2k-warp for why each of those was taken over.
USQUE_INIT="${USQUE_INIT:-/opt/etc/init.d/S51z2k-warp}"
PKG_INIT="/opt/etc/init.d/S51usque"          # legacy usque-keenetic service, migrated away from
# OUTSIDE $ZAPRET2_DIR on purpose. A reinstall renames the whole tree away and deletes it, so
# state kept there is destroyed on every update: the WARP device key would be burned and
# re-registered each time, dropping a working tunnel. The package kept its key in /opt/etc for
# the same reason. z2k_warp_adopt_legacy_state() migrates anything left in the old location.
WARP_DIR="${WARP_DIR:-/opt/etc/z2k-warp}"
WARP_DIR_LEGACY="${WARP_DIR_LEGACY:-$ZAPRET2_DIR/warp}"
USQUE_VERSION="${USQUE_VERSION:-4.2.1}"
# An explicit WARP_IFACE from the environment is a deliberate override and is never
# auto-resolved over (tests and manual overrides depend on that).
if [ -n "$WARP_IFACE" ]; then
    _WARP_IFACE_FIXED=1
else
    WARP_IFACE=$(warp_resolve_iface)
fi
WARP_KICK_COOLDOWN="${WARP_KICK_COOLDOWN:-300}"     # min seconds between down-tunnel usque restarts
# Cooldown stamps live under $ZAPRET2_DIR, NOT /tmp: a reboot must not reset a guard whose
# entire job is to stop us hammering a blocked endpoint (a boot loop would otherwise get a
# free restart on every pass). They are written at most once per cooldown — and not at all
# while things are healthy — so the flash-write cost is ~1 per 5 min in the worst case.
WARP_KICK_STAMP="${WARP_KICK_STAMP:-$ZAPRET2_DIR/.z2k-warp-kick}"

# ---- liveness ----------------------------------------------------------------
# "opkgtun0 has an address" is NOT proof the tunnel works. That address is assigned by NDM
# (S51usque fn_setup_tun_interface) at start time, whether or not the MASQUE session to
# Cloudflare ever established. A usque that runs but never connected therefore reads as
# perfectly healthy: the panel says "работает", selfheal sees address+link and never kicks
# it, and the user stares at a dead WARP forever with every log claiming success. So prove
# it END-TO-END — fetch Cloudflare's own trace endpoint THROUGH the interface and require
# warp=on. `curl --interface` is SO_BINDTODEVICE, so the probe cannot silently leak out the
# WAN and report a false positive. Addressed by IP, never by name: a DNS hiccup must not be
# mistaken for a dead tunnel (1.1.1.1's certificate carries the IP in its SANs, so TLS still
# verifies). Same lesson as the rt-proxy probe — a handshake that completes is not a path
# that carries data.
WARP_PROBE_URL="${WARP_PROBE_URL:-https://1.1.1.1/cdn-cgi/trace}"
WARP_PROBE_TIMEOUT="${WARP_PROBE_TIMEOUT:-8}"
# Volatile on purpose: it is a freshness cache for the webpanel (which must never block on a
# probe of its own), rewritten every selfheal tick. Persisting it would be pure flash wear.
WARP_LIVE_STAMP="${WARP_LIVE_STAMP:-/tmp/z2k-warp-live}"        # "<epoch> <0|1>"
WARP_LIVE_MAXAGE="${WARP_LIVE_MAXAGE:-180}"                     # older than this = "unknown", not "dead"
# usque's MASQUE session is DROPPED BY CLOUDFLARE ON IDLE (upstream documents the
# H3_NO_ERROR disconnect) and usque re-establishes it when outgoing traffic appears. So a
# single failed probe means "it was asleep", not "it is broken" — the probe itself is the
# wake-up. Probe twice before believing anything, and only tear routing down after several
# consecutive failures: pulling the route on the first miss removes the very traffic that
# would have woken the tunnel, and restarting the daemon costs ~30s of downtime to fix a
# condition that resolves itself on the next packet.
WARP_PROBE_RETRY_WAIT="${WARP_PROBE_RETRY_WAIT:-3}"
# Ceiling for the FINAL probe only — see warp_tunnel_live_retry.
WARP_PROBE_SLOW_TIMEOUT="${WARP_PROBE_SLOW_TIMEOUT:-20}"
# Off by default: selfheal must stay cheap. `enable` turns it on for its own run.
WARP_PROBE_ESCALATE="${WARP_PROBE_ESCALATE:-0}"             # seconds between the wake attempt and the verdict
# How long `enable` may spend BRINGING THE TUNNEL UP before it returns a final no.
# It is a budget for fixing, not for waiting: each round restarts what is dead, waits
# for the device, and probes. The old behaviour spent 35 s and then told the user to
# come back later, which is the one outcome that helps nobody.
WARP_ENABLE_BUDGET="${WARP_ENABLE_BUDGET:-120}"
# Hard iteration cap, independent of the clock — see the note in warp_enable.
WARP_ENABLE_ATTEMPTS="${WARP_ENABLE_ATTEMPTS:-4}"
# Probe timeout for the ENABLE path only. The global one (8 s) stays as it is: selfheal
# runs it on every tick and must not block the scheduler.
#
# Upstream's author, issue #49: after an idle period Cloudflare's limiting kicks in and
# "new requests start to work after like 10-20s of waiting". Our 8 s ceiling cannot span
# that window, so a tunnel that is merely waking up is declared dead — which matches every
# field log: session "Connected", probe times out, restarts make it worse because each one
# puts the tunnel back into idle. NOT reproducible on a healthy router (the probe answers
# in 0 s there), so this is upstream's documented behaviour rather than our measurement.
#
# 20 s x2 with a 2 s gap fits ~3 attempts into the 120 s budget, so the escalation ladder
# still runs.
WARP_ENABLE_PROBE_TIMEOUT="${WARP_ENABLE_PROBE_TIMEOUT:-20}"
WARP_ENABLE_RETRY_WAIT="${WARP_ENABLE_RETRY_WAIT:-2}"
# Endpoint variants, tried ONLY after a healthy device still carries no traffic — i.e.
# the ISP is blocking Cloudflare's MASQUE endpoint, which no amount of restarting fixes.
# Empty by default in every sense: nothing here runs, and no file is created, unless the
# tunnel has already failed. A router whose tunnel comes up never touches this.
#
# Each entry is IP[:PORT]. Both were verified to reach "Tunnel established" from a real
# Keenetic; 2408 and 4500 do not accept TCP at all (they are the WireGuard ports) and are
# deliberately not listed — guessing candidates would waste the budget.
# ONLY the documented endpoint, on alternative PORTS. 188.114.98.1/96.1 were mine and they
# were wrong: measured, they answer our SNI with "alert 40 handshake failure" and no
# certificate, and with the correct SNI they present a DIFFERENT public key which usque's
# pinning rejects. They are WireGuard-range addresses, not HTTP/2 MASQUE endpoints — the
# upstream wiki says h2 endpoints must be read off the official client, and the maintainer
# declines to support arbitrary Cloudflare addresses. A router that got pinned to one of
# them produced exactly the field symptom.
WARP_ENDPOINTS="${WARP_ENDPOINTS:-162.159.198.2:8443}"
WARP_ALT_CONF="${WARP_ALT_CONF:-$WARP_DIR/session.alt.conf}"
WARP_ALT_PORT="${WARP_ALT_PORT:-$WARP_DIR/port}"
# How long a pinned endpoint variant may keep failing before selfheal drops it. Not zero:
# `enable` sets a variant and then probes for up to two minutes, and selfheal runs every
# minute — expiring it instantly would have the two fighting over the same file.
WARP_VARIANT_TTL="${WARP_VARIANT_TTL:-600}"
WARP_FAIL_THRESHOLD="${WARP_FAIL_THRESHOLD:-3}"                 # consecutive failed ticks before failing open
WARP_FAIL_STREAK="${WARP_FAIL_STREAK:-/tmp/z2k-warp-failstreak}"
# Self-heal may install usque (see warp_selfheal) — cooldown-guarded, because the .ipk is
# ~14 MB and a router that cannot fetch it must not re-try every minute.
WARP_INSTALL_STAMP="${WARP_INSTALL_STAMP:-$ZAPRET2_DIR/.z2k-warp-install}"
WARP_INSTALL_COOLDOWN="${WARP_INSTALL_COOLDOWN:-600}"
# One-shot marker for the r-62 legacy-NAT purge (see warp_purge_legacy_nat).
WARP_LEGACY_MARK="${WARP_LEGACY_MARK:-$ZAPRET2_DIR/.z2k-warp-legacy-purged}"
USQUE_BIN="${USQUE_BIN:-/opt/sbin/z2k-usque}"
USQUE_SESSION="${USQUE_SESSION:-$WARP_DIR/session.conf}"
# WARP enrollment fallback. usque enrolls a device by POSTing to api.cloudflareclient.com;
# some ISPs DPI-block that endpoint (TLS handshake timeout) → no session.conf → no tunnel.
# The direct enroll IS desynced (cloudflareclient.com is in the bypass hostlist); if it still
# can't punch through after WARP_REG_DIRECT_TRIES attempts, enroll THROUGH the VPS relay — a
# restricted CONNECT proxy (only api.cloudflareclient.com:443) that reaches the CF reg API.
# Fallback-only: most routers enroll directly (correct region) and never touch the VPS.
WARP_VPS_PROXY="${WARP_VPS_PROXY:-http://z2kwarp:z2kW4rpR3g2026@213.176.74.63:8119}"
WARP_REG_DIRECT_TRIES="${WARP_REG_DIRECT_TRIES:-3}"
WARP_REG_COUNT="${WARP_REG_COUNT:-/tmp/z2k-warp-regcount}"   # in-progress counter, volatile by design
WARP_REG_STAMP="${WARP_REG_STAMP:-$ZAPRET2_DIR/.z2k-warp-reg}"
WARP_REG_COOLDOWN="${WARP_REG_COOLDOWN:-600}"       # min seconds between VPS-relay enroll attempts

_wlog() { echo "[z2k-warp] $*" >&2; }

warp_flag() { grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d ' '; }

# Monotonic-ish "now", or empty when the clock is unreadable. Callers that guard a
# destructive action must treat empty as "do nothing" rather than "cooldown elapsed".
_warp_now() {
    local n; n=$(date +%s 2>/dev/null) || return 1
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$n"
}

# Shared cooldown gate: returns 0 (proceed) only when $1's stamp is older than $2 seconds,
# and stamps it BEFORE returning. A stamp we cannot write means "do not proceed" — otherwise
# a read-only / full filesystem would silently turn every guarded action into a per-tick storm.
# File mtime in epoch seconds. BusyBox `stat -c` is not guaranteed on Entware, so fall
# back to a find-based comparison rather than assuming a tool that may be absent.
_warp_mtime() {
    local f="$1" v
    v=$(stat -c %Y "$f" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) printf '%s' "$v"; return 0 ;; esac
    v=$(date -r "$f" +%s 2>/dev/null)
    case "$v" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$v"; return 0 ;; esac
}

_warp_cooldown_ok() {
    local stamp="$1" cool="$2" now last
    now=$(_warp_now) || return 1
    if [ -f "$stamp" ]; then
        last=$(cat "$stamp" 2>/dev/null)
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        # A future stamp (router clock skewed ahead at boot, before NTP pulls it back) would
        # keep now-last negative forever and wedge recovery — treat it as no stamp at all.
        [ "$last" -gt "$now" ] && last=0
        [ $((now - last)) -lt "$cool" ] && return 1
    fi
    { echo "$now" > "$stamp"; } 2>/dev/null || return 1
    return 0
}

# EVERY engine restart goes through here, so the reasons live in one place. Our init owns
# stop/start cleanly, so this is now a plain restart — no more clearing the package's
# usque.conf.run behind its back.
# Build an endpoint variant and restart onto it. The ORIGINAL session.conf is only ever
# READ — it holds the device key, and rewriting it is the one mistake here that would cost
# a user their registration rather than merely a session. usque takes the variant with -c.
warp_variant_apply() {
    local spec="$1" ip port cur
    ip=${spec%%:*}
    port=${spec#*:}; [ "$port" = "$spec" ] && port=443
    [ -s "$USQUE_SESSION" ] || return 1
    cur=$(sed -n 's/.*"endpoint_h2_v4"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$USQUE_SESSION" | head -1)
    [ -n "$cur" ] || return 1
    # Substitute the ADDRESS ONLY, and verify the copy still looks like the original
    # config: a mangled variant would take the tunnel down for a reason nobody could see.
    # Anchored on the endpoint_h2_v4 line, dots escaped, one substitution. The old form
    # was `s/$cur/$ip/g` — unanchored, dots as wildcards, global: it would happily rewrite
    # any other field that happened to contain the same digits.
    local esc
    esc=$(printf '%s' "$cur" | sed 's/\./\\./g')
    sed "s#\(\"endpoint_h2_v4\"[[:space:]]*:[[:space:]]*\"\)$esc\(\"\)#\1$ip\2#" \
        "$USQUE_SESSION" > "$WARP_ALT_CONF.tmp" 2>/dev/null || return 1
    if ! grep -q "\"endpoint_h2_v4\"[[:space:]]*:[[:space:]]*\"$ip\"" "$WARP_ALT_CONF.tmp" \
       || ! grep -q '"private_key"' "$WARP_ALT_CONF.tmp"; then
        rm -f "$WARP_ALT_CONF.tmp"; return 1
    fi
    mv "$WARP_ALT_CONF.tmp" "$WARP_ALT_CONF" 2>/dev/null || return 1
    printf '%s' "$port" > "$WARP_ALT_PORT" 2>/dev/null
    _wlog "пробую другой адрес Cloudflare: $ip:$port"
    warp_usque_restart
}

# Back to stock. Called when no variant helped, so a router is never left pinned to an
# endpoint that did not work either.
# Drop a pinned variant that has had its chance and is not delivering.
#
# THE BUG THIS EXISTS FOR: the init prefers session.alt.conf unconditionally and forever
# (S51z2k-warp), while warp_variant_clear used to be reachable only from the final failure
# branch of `enable`. Any other exit — budget spent elsewhere, process killed, reboot, boot
# time enable — left the pin in place permanently, and every later start went to an
# endpoint we now know answers "tls: handshake failure". Reproduced on a live router: the
# engine came up with --config .../session.alt.conf against 188.114.98.1 and stayed there
# across restarts. That is the field report "restarting does not help" in one line.
warp_variant_expire() {
    local age now mt
    [ -f "$WARP_ALT_CONF" ] || return 0
    # Still delivering? Leave it alone — a variant that works is the point.
    [ "$(warp_live_cached)" = 1 ] && return 0
    now=$(_warp_now) || return 0
    mt=$(_warp_mtime "$WARP_ALT_CONF") || return 0
    age=$((now - mt))
    [ "$age" -ge 0 ] || { warp_variant_clear; return 0; }   # clock skew: do not keep it
    [ "$age" -lt "$WARP_VARIANT_TTL" ] && return 0
    _wlog "запасной адрес не помогает уже ${age}с — снимаю пин"
    warp_variant_clear
}

warp_variant_clear() {
    [ -f "$WARP_ALT_CONF" ] || [ -f "$WARP_ALT_PORT" ] || return 0
    rm -f "$WARP_ALT_CONF" "$WARP_ALT_PORT" 2>/dev/null
    _wlog "ни один запасной адрес не помог — возвращаю штатный"
    warp_usque_restart
}

warp_usque_restart() {
    [ -x "$USQUE_INIT" ] || return 1
    "$USQUE_INIT" restart >/dev/null 2>&1
    return 0
}

# ---- liveness probe ----------------------------------------------------------
warp_live_record() {
    local now; now=$(_warp_now) || return 0
    { echo "$now $1" > "$WARP_LIVE_STAMP"; } 2>/dev/null || true
}

# Read the cached verdict: prints "1" (live), "0" (dead) or "" (unknown / too old to trust).
# The webpanel uses this — a status call must never block on an 8-second probe.
warp_live_cached() {
    local now line ts val
    [ -f "$WARP_LIVE_STAMP" ] || return 0
    line=$(cat "$WARP_LIVE_STAMP" 2>/dev/null) || return 0
    ts=${line%% *}; val=${line##* }
    case "$ts" in ''|*[!0-9]*) return 0 ;; esac
    case "$val" in 0|1) ;; *) return 0 ;; esac
    now=$(_warp_now) || return 0
    [ "$ts" -gt "$now" ] && return 0
    [ $((now - ts)) -gt "$WARP_LIVE_MAXAGE" ] && return 0
    printf '%s' "$val"
}

# The real thing: does traffic actually reach Cloudflare THROUGH the tunnel? Records the
# verdict for the panel. Returns 0 = live, 1 = dead.
# WHY the tunnel is not carrying traffic. Set on every failing path below, and printed
# by the caller.
#
# This exists because "the tunnel is not carrying traffic yet" was printed for FIVE
# different causes — no interface, no address, link down, engine not running, no
# registration, and a probe that simply failed — and they were indistinguishable to
# the user and to us. Four separate root causes have been fixed under that one
# sentence (subnet collision, blocked registration, link never raised, overridden
# address) and every report still arrived looking identical, so each one restarted
# from "send me the log". The verdict knows all of this at the moment it decides;
# it just used to throw it away.
WARP_LIVE_WHY=""

# Explain a failed verdict. DIAGNOSIS ONLY — it never decides anything.
#
# The first version of this put these checks INSIDE warp_tunnel_live, which changed the
# meaning of a function selfheal calls on every tick: a momentarily missing pidof would
# have read as "dead" and could have torn routing down. The verdict stays exactly what it
# always was (the probe), and the explanation is separate.
# The ENGINE's own last words. Our checks can only get as far as "the device is fine and
# data still does not flow" — why is known only to usque, and it says so plainly:
#     Establishing MASQUE connection to 162.159.198.2:443
#     Connected to MASQUE server
#     Tunnel connection lost: ... EOF. Reconnecting...
#     Tunnel idle. Waiting for outbound activity before reconnecting...
# We already capture that output (the supervisor appends it to this log). Not showing it
# meant every "device is up, traffic does not flow" report still needed one more round
# trip to the user, which is the whole problem this diagnostics work exists to remove.
#
# "Hop Limit too small" is filtered: it is multicast (mDNS/SSDP, TTL=1 by standard)
# hitting a MULTICAST-flagged tun, it appears on perfectly healthy tunnels, and it repeats
# often enough to bury the one line that matters.
WARP_ENGINE_LOG="${WARP_ENGINE_LOG:-/tmp/z2k-log/z2k-warp.log}"
warp_engine_tail() {
    [ -f "$WARP_ENGINE_LOG" ] || return 0
    # Anywhere on the line, not just at the start: our init prefixes its own log with a
    # date, so "^\[z2k-warp\]" let those through and a field log ended up reporting OUR
    # line as if the engine had said it.
    grep -v '\[z2k-warp\]' "$WARP_ENGINE_LOG" 2>/dev/null \
        | grep -v 'Hop Limit too small' \
        | sed -n 's/[[:space:]]*$//; /./p' \
        | tail -1
}

# Did the engine actually establish a MASQUE session? Decided by the LAST of the
# success/failure markers, so a stale success from an hour ago cannot mask a current
# failure.
#
# This matters because rotating the endpoint is only sensible when the endpoint is the
# problem. A field log showed the stock endpoint reporting "Connected to MASQUE server"
# while the probe still timed out — the session was up and the traffic inside it was being
# filtered — and rotating away from it produced "tls: handshake failure" on the
# alternatives, i.e. we made a working handshake worse for no reason.
warp_engine_connected() {
    local last
    [ -f "$WARP_ENGINE_LOG" ] || return 1
    last=$(grep -v '\[z2k-warp\]' "$WARP_ENGINE_LOG" 2>/dev/null \
           | grep -E 'Connected to MASQUE server|Failed to connect tunnel|Tunnel connection failed|Tunnel connection lost' \
           | tail -1)
    # "Tunnel established" is NOT a success marker: usque prints it unconditionally BEFORE
    # it dials anything (cmd/nativetun.go). Treating it as proof of a live session is what
    # made us skip endpoint variants, burn a re-registration and tell users "your provider
    # is filtering it" — all off a line that means nothing. Only the HTTP 200 on CONNECT-IP
    # counts, and "Tunnel connection failed" (a non-200 from Cloudflare) is a failure we
    # were not detecting at all.
    case "$last" in
        *"Connected to MASQUE server"*) return 0 ;;
    esac
    return 1
}

warp_explain_dead() {
    local rc="$1" body="$2" eng
    if ! ip link show "$WARP_IFACE" >/dev/null 2>&1; then
        printf 'интерфейс %s не существует — usque не создал устройство' "$WARP_IFACE"; return 0
    fi
    if ! ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet '; then
        printf 'на %s нет IPv4-адреса — NDM не применил конфигурацию интерфейса' "$WARP_IFACE"; return 0
    fi
    if ! ip link show "$WARP_IFACE" 2>/dev/null | grep -qw UP; then
        printf 'линк %s не поднят (нет UP)' "$WARP_IFACE"; return 0
    fi
    if ! warp_usque_running; then
        printf 'движок usque не запущен'; return 0
    fi
    # From here the device, the address, the link and the engine process are all fine, so
    # the answer is in what the engine is doing — append its last line.
    eng=$(warp_engine_tail)
    if [ "$rc" != 0 ]; then
        # 28 = timed out, 6/7 = could not resolve/connect. Naming the code is what turns
        # "not carrying traffic" into something answerable without asking for a log.
        printf 'проба через %s не прошла: curl rc=%s (28=таймаут %sс, 6/7=не достучался) — устройство есть, трафик через него не идёт' \
               "$WARP_IFACE" "$rc" "$WARP_PROBE_TIMEOUT"
        [ -n "$eng" ] && printf '; движок: %s' "$eng"
        return 0
    fi
    if [ -z "$body" ]; then
        printf 'проба через %s вернула пустой ответ — соединение есть, данных нет' "$WARP_IFACE"
        [ -n "$eng" ] && printf '; движок: %s' "$eng"
        return 0
    fi
    # We reached Cloudflare THROUGH the tunnel and it says the traffic is not WARP: the
    # interface works, the MASQUE session does not. Usually a dead registration.
    printf 'Cloudflare отвечает через %s, но WARP не активен (%s) — вероятно нерабочая регистрация' \
           "$WARP_IFACE" "$(printf '%s' "$body" | grep -m1 '^warp=' || echo 'строки warp= нет')"
}

warp_tunnel_live() {
    WARP_LIVE_WHY=""
    if ! ip link show "$WARP_IFACE" >/dev/null 2>&1; then
        WARP_LIVE_WHY=$(warp_explain_dead 0 "")
        warp_live_record 0; return 1
    fi
    # No curl means we cannot prove anything. Never report "dead" on missing tooling — that
    # would turn a probe failure into a restart storm against a perfectly good tunnel.
    command -v curl >/dev/null 2>&1 || return 0
    local body rc
    body=$(curl -4 --interface "$WARP_IFACE" -s --max-time "$WARP_PROBE_TIMEOUT" \
                "$WARP_PROBE_URL" 2>/dev/null); rc=$?
    case "$body" in
        *warp=on*) warp_live_record 1; return 0 ;;
    esac
    WARP_LIVE_WHY=$(warp_explain_dead "$rc" "$body")
    warp_live_record 0
    return 1
}

# The verdict callers should use. A single probe answers "is it awake RIGHT NOW", which is
# the wrong question: after an idle drop the FIRST request is what makes usque rebuild the
# session, so it legitimately fails while doing its job. Ask again after a pause and judge
# on that.
warp_tunnel_live_retry() {
    warp_tunnel_live && return 0
    sleep "$WARP_PROBE_RETRY_WAIT"
    warp_tunnel_live && return 0
    # A third, SLOWER probe — but only where someone is waiting for a verdict.
    [ "$WARP_PROBE_ESCALATE" = 1 ] || return 1
    # LAST attempt gets a longer ceiling. Cloudflare penalises the wake-up after an idle
    # period — upstream #49 measures 10-20 s before new requests start working — and the
    # per-tick 8 s probe cannot span that, so a merely sleeping tunnel is recorded dead and
    # "repaired" by a restart that idles it again. Raising the ceiling for EVERY probe would
    # block the scheduler for 20 s a tick — a down tunnel would eat 36 s of every 60 s tick,
    # and selfheal already tolerates a false "dead" (it needs WARP_FAIL_THRESHOLD in a row
    # before it tears routing down). So the escalation is opt-in and only `enable` asks for
    # it: there a user is sitting in front of a blocking request waiting for an answer, and
    # spending 20 s to avoid a wrong one is the right trade.
    local _saved="$WARP_PROBE_TIMEOUT"
    WARP_PROBE_TIMEOUT="$WARP_PROBE_SLOW_TIMEOUT"
    warp_tunnel_live; local _rc=$?
    WARP_PROBE_TIMEOUT="$_saved"
    return "$_rc"
}

# Is the usque DAEMON running? Not "does the interface exist" — the package leaves its NDM
# interface behind when the daemon is gone. Separates "nothing is running, just start it"
# from "it runs but the tunnel is unhealthy": very different problems, very different cures.
warp_usque_running() {
    [ -x "$USQUE_BIN" ] || return 1
    pidof "$(basename "$USQUE_BIN")" >/dev/null 2>&1
}

_warp_streak_get() {
    local n; n=$(cat "$WARP_FAIL_STREAK" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}
_warp_streak_set() { { echo "$1" > "$WARP_FAIL_STREAK"; } 2>/dev/null || true; }

# ---- engine provisioning ------------------------------------------------------
# We ship the LIFECYCLE; the engine is upstream's usque binary, taken straight from its
# release. We no longer install the usque-keenetic package: it only ever repackaged this
# same binary (its Makefile literally curls the release zip) and added the init script whose
# every assumption bit us. Dropping it removes the sed-patching of a third-party script, the
# interface-name lottery and the usque.conf.run trap in one go.
warp_arch() {
    local a
    a=$(grep -hoE 'mipselsf|mipsel|mips64el|mips64|mips|aarch64|armv7|armv5|x86_64|i[36]86' \
            /opt/etc/opkg.conf /opt/etc/opkg/*.conf 2>/dev/null | head -1)
    [ -n "$a" ] || a=$(uname -m)
    case "$a" in
        aarch64|arm64)      printf 'arm64' ;;
        mipselsf|mipsel)    printf 'mipsle' ;;
        mips64el)           printf 'mips64le' ;;
        mips64)             printf 'mips64' ;;
        mips)               # big-endian unless the SoC says otherwise (MediaTek is LE)
            grep -qiE 'system type.*MediaTek' /proc/cpuinfo 2>/dev/null && printf 'mipsle' || printf 'mips' ;;
        armv7*)             printf 'armv7' ;;
        armv5*|armv6*)      printf 'armv5' ;;
        x86_64)             printf 'amd64' ;;
        i386|i686)          printf '386' ;;
        *)                  printf '' ;;
    esac
}

# One-time migration of state written by the first version of this wrapper, which kept it
# inside $ZAPRET2_DIR and therefore lost it on the next reinstall.
warp_adopt_legacy_state() {
    [ -d "$WARP_DIR_LEGACY" ] || return 0
    mkdir -p "$WARP_DIR" 2>/dev/null || return 0
    for f in session.conf iface addr; do
        [ -s "$WARP_DIR_LEGACY/$f" ] || continue
        [ -s "$WARP_DIR/$f" ] && continue
        cp -f "$WARP_DIR_LEGACY/$f" "$WARP_DIR/$f" 2>/dev/null && _wlog "migrated warp state: $f"
    done
    chmod 600 "$WARP_DIR/session.conf" 2>/dev/null
    return 0
}

warp_install() {
    warp_adopt_legacy_state
    [ -x "$USQUE_BIN" ] && return 0
    mkdir -p "$WARP_DIR" 2>/dev/null
    # A user upgrading from the package already has the engine on disk — adopt it instead of
    # re-downloading 5 MB over a link that may be exactly what is broken.
    if [ -x /opt/usr/bin/usque ]; then
        cp -f /opt/usr/bin/usque "$USQUE_BIN" 2>/dev/null && chmod 755 "$USQUE_BIN" 2>/dev/null \
            && { _wlog "adopted the existing usque engine"; return 0; }
    fi
    local arch url zip
    arch=$(warp_arch)
    [ -n "$arch" ] || { _wlog "unsupported architecture for the WARP engine"; return 1; }
    url="https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}/usque_${USQUE_VERSION}_linux_${arch}.zip"
    zip="/tmp/z2k-usque.zip"
    _wlog "fetching WARP engine usque ${USQUE_VERSION} ($arch)"
    rm -f "$zip"
    if command -v z2k_fetch >/dev/null 2>&1; then
        z2k_fetch "$url" "$zip" || curl -sSL --max-time 180 "$url" -o "$zip"
    else
        curl -sSL --max-time 180 "$url" -o "$zip"
    fi
    [ -s "$zip" ] || { _wlog "engine download failed"; return 1; }
    command -v unzip >/dev/null 2>&1 || { _wlog "unzip missing — cannot unpack the engine"; rm -f "$zip"; return 1; }
    rm -f /tmp/usque
    if ! unzip -o -q "$zip" usque -d /tmp 2>/dev/null; then
        _wlog "engine archive is corrupt (unzip failed)"; rm -f "$zip" /tmp/usque; return 1
    fi
    rm -f "$zip"
    [ -s /tmp/usque ] || { _wlog "engine archive did not contain the binary"; return 1; }
    chmod 755 /tmp/usque 2>/dev/null
    # SMOKE-TEST before installing. A truncated download (ENOSPC in tmpfs is routine on these
    # routers) yields a non-empty file that passes every other check — and once it is in place
    # warp_install short-circuits on its existence FOREVER, so the mode never recovers.
    if ! /tmp/usque --help >/dev/null 2>&1; then
        _wlog "downloaded engine does not run (truncated or wrong architecture) — discarding"
        rm -f /tmp/usque; return 1
    fi
    mv -f /tmp/usque "$USQUE_BIN" 2>/dev/null || { _wlog "cannot install the engine to $USQUE_BIN"; return 1; }
    chmod 755 "$USQUE_BIN" 2>/dev/null
    _wlog "WARP engine installed: $USQUE_BIN"
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

# r-62 migration, ONE-SHOT. We used to MASQUERADE and MSS-clamp opkgtun0 ourselves; that
# was a mistake — opkgtun0 is a Keenetic GLOBAL interface, so NDM already NATs it and
# clamps its MSS (`ip tcp adjust-mss pmtu`, S51usque fn_setup_tun_interface), and ours was
# a redundant double-SNAT. The rules are gone; this only drains them off routers upgraded
# from the old code. Nothing recreates them, so once drained it never needs running again
# — hence the marker. It used to sit inside warp_pbr_up, i.e. two iptables round-trips
# every selfheal tick, forever, for a migration that is finished after one.
# Does NDM actually NAT this interface? The r-62 decision to drop our own MASQUERADE rests
# entirely on "opkgtun0 is a GLOBAL interface, so NDM already NATs it" — never checked at
# runtime. It stops being true the moment `ip global` is not applied, which is exactly the
# state the iproute2 fallback leaves the interface in when NDM refuses. Forwarded LAN
# traffic then enters the tunnel with a 192.168.x.x source and dies, while our probe —
# bound to the device and sourced from the tunnel address — still reports warp=on. That gap
# is how "the panel says it works" and "the internet is down" can both be true.
warp_nat_present() {
    iptables -w -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-o $WARP_IFACE .*MASQUERADE"
}

warp_nat_install() {
    iptables -w -t nat -C POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null \
        || iptables -w -t nat -A POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null
    iptables -w -t mangle -C FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -w -t mangle -A FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    _wlog "NDM не NAT-ит $WARP_IFACE — поставил свой MASQUERADE и MSS-клэмп"
}

# Keep NAT present whoever provides it.
warp_nat_ensure() {
    warp_nat_present && return 0
    warp_nat_install
}

warp_purge_legacy_nat() {
    [ -f "$WARP_LEGACY_MARK" ] && return 0
    # Only drop ours when NDM's is actually there to take over.
    if ! warp_nat_present; then
        _wlog "пропускаю чистку старого NAT: у NDM своего нет, наш нужен"
        return 0
    fi
    while iptables -w -t nat -C POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null; do
        iptables -w -t nat -D POSTROUTING -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null || break
    done
    while iptables -w -t mangle -C FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
        iptables -w -t mangle -D FORWARD -o "$WARP_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || break
    done
    # `touch`, NOT `: > file` — see the identical note in z2k-ppe-deoffload.sh: `:` is a POSIX
    # special built-in, so a failed redirection on it EXITS the shell (dash / busybox ash),
    # and no `2>/dev/null || true` can save you. An unwritable marker must degrade to
    # "purge runs again next time", never to "the script dies here".
    touch "$WARP_LEGACY_MARK" 2>/dev/null || true
    return 0
}

# ---- policy routing (split-tunnel) — this is the ONLY thing the toggle does --
# The device MTU must never exceed what the engine can read. usque truncates anything
# larger than its own MTU without a word, and h2 mode has no PMTU discovery to notice.
# NDM re-creates the interface on its own schedule and does not always carry the MTU with
# it, so this is re-asserted rather than set once.
# Keep OUR OWN tunnel handshake out of the bypass.
#
# The MASQUE session is plain TLS to a Cloudflare address, and z2k desyncs TLS. Today it
# survives only because the SNI we front with (ozon.ru) happens to sit in the shipped
# whitelist — an undocumented coupling: a user editing the whitelist in the web panel would
# start desyncing our own tunnel and have no way to know why.
#
# The engine already ships the mechanism for this: every NFQUEUE rule carries
# `-m set ! --match-set nozapret dst`, so putting the endpoint address in that set excludes
# it from all of them at once, without adding a rule or touching the bypass chain. Re-added
# on every tick because the set is the engine's and does not survive its restarts.
warp_endpoint_nozapret() {
    local cfg="$USQUE_SESSION" ip
    [ -s "$WARP_ALT_CONF" ] && cfg="$WARP_ALT_CONF"
    [ -s "$cfg" ] || return 0
    ip=$(sed -n 's/.*"endpoint_h2_v4"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$cfg" 2>/dev/null | head -1)
    case "$ip" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
        *) return 0 ;;
    esac
    ipset list -n nozapret >/dev/null 2>&1 || return 0
    ipset test nozapret "$ip" >/dev/null 2>&1 && return 0
    ipset add nozapret "$ip" 2>/dev/null && _wlog "адрес туннеля $ip исключён из обхода (nozapret)"
}

warp_mtu_ensure() {
    local cur
    cur=$(ip -o link show "$WARP_IFACE" 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p')
    case "$cur" in ''|*[!0-9]*) return 0 ;; esac
    [ "$cur" -le "$WARP_MTU" ] && return 0
    _wlog "MTU $WARP_IFACE = $cur больше $WARP_MTU — движок будет резать пакеты, исправляю"
    ip link set dev "$WARP_IFACE" mtu "$WARP_MTU" 2>/dev/null
}

warp_pbr_up() {
    warp_endpoint_nozapret
    warp_mtu_ensure
    warp_link_up   # the package often leaves opkgtun0's link DOWN; route add needs it UP
    # Steer ONLY the marked game traffic out the WARP tun. No NAT, no MSS clamp — NDM does
    # both natively for a global interface (see warp_purge_legacy_nat).
    # split-tunnel: fwmark → table → opkgtun0
    ip route replace default dev "$WARP_IFACE" table "$WARP_TABLE" 2>/dev/null
    # Explicit pref: Keenetic's own policy rules live at 100-4096, and an unspecified
    # preference leaves it to chance whether ours is consulted before them. Explicit mask:
    # `fwmark VAL` alone demands the rest of the mark word be zero.
    ip rule show 2>/dev/null | grep -q "fwmark $WARP_MARK" \
        || ip rule add pref "$WARP_RULE_PREF" fwmark "$WARP_MARK/$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    # Mark game-ipset dst ONLY in PREROUTING (forwarded LAN-client traffic — PS5/phones).
    # NOT OUTPUT (router-origin) — routing a locally-generated packet into the TUN breaks
    # its reply path and blackholes the router's own CF/AWS access (github / VPS fetches).
    # --set-xmark with a mask: --set-mark CLOBBERS the whole mark word, wiping any other
    # mark already on the packet (Keenetic sets its own).
    iptables -w -t mangle -C PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-xmark "$WARP_MARK/$WARP_MARK" 2>/dev/null \
        || iptables -w -t mangle -A PREROUTING -m set --match-set "$WARP_IPSET" dst -j MARK --set-xmark "$WARP_MARK/$WARP_MARK" 2>/dev/null
    # Forwarded traffic needs NAT, whoever owns it.
    warp_nat_ensure
}

warp_pbr_down() {
    for ch in OUTPUT PREROUTING; do   # OUTPUT drained too, to clean any legacy rule
        while iptables -w -t mangle -C "$ch" -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null; do
            iptables -w -t mangle -D "$ch" -m set --match-set "$WARP_IPSET" dst -j MARK --set-mark "$WARP_MARK" 2>/dev/null || break
        done
    done
    warp_purge_legacy_nat   # no-op once the r-62 drain has run
    ip rule del fwmark "$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
    ip route flush table "$WARP_TABLE" 2>/dev/null
}

# ---- toggle (routing only) ---------------------------------------------------
# Exit codes are the contract with the webpanel/menu toggles:
#   0 — mode on AND the tunnel is verified carrying traffic,
#   1 — HARD failure, nothing to recover from (no usque, ipset unusable): caller reverts the flag,
#   2 — mode on, routing applied, but the tunnel is not up YET. The flag stays ON on purpose:
#       enrollment/reconnect is exactly what selfheal exists for, and reverting the flag would
#       switch off the only thing that can still fix it. The caller must SAY SO instead of
#       reporting success — the old code returned 0 here unconditionally, which is why the UI
#       cheerfully claimed "включено" over a stone-dead tunnel and the revert branches in
#       actions.sh / menu.sh were unreachable code.
warp_enable() {
    _wlog "enable"
    warp_install || { _wlog "usque not available — режим не включён"; return 1; }
    warp_ipset_load || return 1
    warp_purge_legacy_nat
    # Make sure the daemon is actually RUNNING. warp_install is a no-op once the package is
    # installed and configured, and nothing else here starts usque — the package starts it at
    # boot and that was the only path. So enabling the mode on a router whose daemon is
    # stopped (manual stop, a crash, an earlier disable) sat waiting for an interface that was
    # never going to appear, then reported "not up yet" forever while self-heal's kick sat
    # behind its cooldown. The user just asked for the tunnel: start it, now, unconditionally.
    # Ask whether the ENGINE is running, never whether the interface exists: a leftover
    # opkgtunN from an earlier install answers "yes" while nothing is actually running, which
    # is exactly how this silently did nothing at all.
    if ! warp_usque_running; then
        _wlog "WARP engine is not running — starting it"
        warp_usque_restart
    fi
    # Our init records the interface it chose; adopt it now that it has started.
    [ -n "$_WARP_IFACE_FIXED" ] || WARP_IFACE=$(warp_resolve_iface)
    # DRIVE TO A VERDICT. Either the tunnel carries traffic when this returns, or it does
    # not and we say why — never "проверьте статус через минуту". That sentence handed the
    # user back a problem we had just detected and that they cannot act on, and they do not
    # come back to look; they file a report that looks exactly like the previous five.
    #
    # For contrast: the upstream package (usque-keenetic 0.3.0, fn_start) starts the daemon,
    # configures the NDM interface and reports success WITHOUT EVER CHECKING that anything
    # flows — no wait, no link-up, no probe. That is why it looks problem-free: a dead
    # tunnel there is silent. Checking is right. Ending the check with "try again later" was
    # not.
    #
    # Every iteration does the recovery itself and escalates, so the budget is spent fixing
    # rather than waiting. Progress is printed as it goes: the webpanel is blocking on this
    # request and lighttpd only drops a CGI that goes quiet, not one that takes a while.
    # BOUNDED TWICE, on purpose. The time budget alone is not enough: _warp_now falls back
    # to 0 when `date` is unavailable, so on such a box the deadline would never arrive and
    # enable would loop forever holding the webpanel request open. Caught by the test suite
    # hanging, which is exactly the failure a user would have seen.
    # Widen the probe for this path only — see WARP_ENABLE_PROBE_TIMEOUT.
    WARP_PROBE_TIMEOUT="$WARP_ENABLE_PROBE_TIMEOUT"
    WARP_PROBE_RETRY_WAIT="$WARP_ENABLE_RETRY_WAIT"
    WARP_PROBE_ESCALATE=1
    local deadline now attempt=0 kicked=0 vidx=0 cand= reregged=0
    now=$(_warp_now 2>/dev/null || echo 0)
    deadline=$(( now + WARP_ENABLE_BUDGET ))
    while [ "$attempt" -lt "$WARP_ENABLE_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        # The engine must be running before anything can appear. Re-checked every round:
        # it may have died between rounds, and a wedged one is what the kick below fixes.
        if ! warp_usque_running; then
            _wlog "движок usque не запущен — запускаю (попытка $attempt)"
            warp_usque_restart
        fi
        # Device, link, address — what usque and NDM must produce. A cold start genuinely
        # takes ~30 s, so this is patient, but it is not the whole budget.
        local w=0
        while [ "$w" -lt 25 ]; do
            warp_link_up
            ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -q 'inet ' \
                && ip link show "$WARP_IFACE" 2>/dev/null | grep -qw UP && break
            w=$((w + 1)); sleep 1
        done
        # Verify BEFORE steering anything into the tunnel — see the fail-open note in
        # warp_selfheal. A dead tunnel with routing applied blackholes every network in
        # the list instead of merely leaving them un-tunnelled.
        # _retry, not a bare probe: Cloudflare drops the MASQUE session on idle and usque
        # re-establishes it when traffic appears, so the FIRST probe is the wake-up and the
        # second is the verdict. Skipping that reported a sleeping tunnel as broken.
        if warp_tunnel_live_retry; then
            _warp_streak_set 0
            warp_pbr_up
            # Whatever got us here is now the working configuration; the kept-aside
            # registration is no longer needed.
            rm -f "$USQUE_SESSION.prev" 2>/dev/null
            _wlog "готово: туннель работает (warp=on через $WARP_IFACE, ipset=$WARP_IPSET)"
            return 0
        fi
        _wlog "попытка $attempt не удалась: $WARP_LIVE_WHY"
        now=$(_warp_now 2>/dev/null || echo 0)
        [ "$now" -lt "$deadline" ] || break
        # ESCALATE. Restarting the engine is what fixes a wedged MASQUE session — it is
        # exactly what a user does by toggling usque off and on — and it is done ONCE, so a
        # genuinely broken registration is not hammered for the whole budget.
        if [ "$kicked" = 0 ]; then
            kicked=1
            _wlog "перезапускаю движок и пробую снова"
            warp_usque_restart
        else
            # The restart did not help. If the DEVICE is healthy and it is the data path
            # that is dead, the endpoint itself is the suspect — that is the ISP blocking
            # Cloudflare, and no further restarting will change it. Gated on the reason:
            # rotating the endpoint when the problem is "no address" would waste the
            # budget on the wrong layer.
            case "$WARP_LIVE_WHY" in
                *"проба через"*|*"WARP не активен"*)
                    # Only when the ENDPOINT is the suspect. If the engine reports a
                    # established MASQUE session and the probe still fails, the endpoint
                    # is reachable and the traffic inside the tunnel is what is being
                    # filtered — rotating then swapped a working handshake for
                    # "tls: handshake failure" on the alternatives, observed in the field.
                    if warp_engine_connected; then
                        # The endpoint is reachable and the tunnel still carries nothing.
                        # Rotating addresses here made things worse in the field; the one
                        # thing upstream reports as helping is a fresh registration, so
                        # try that instead — once, with the old one kept aside.
                        _wlog "сессия к Cloudflare устанавливается, значит адрес ни при чём — запасные не пробую"
                        if [ "$reregged" = 0 ]; then
                            reregged=1
                            warp_reregister_guarded || true
                        fi
                        sleep 3
                        continue
                    fi
                    vidx=$((vidx + 1))
                    # shellcheck disable=SC2086  # candidate list is deliberately split
                    set -- $WARP_ENDPOINTS
                    if [ "$vidx" -le "$#" ]; then
                        eval "cand=\${$vidx}"
                        warp_variant_apply "$cand" || _wlog "вариант $cand применить не удалось"
                    fi
                    ;;
            esac
        fi
        sleep 3
    done
    # FINAL, and it is a no: routing stays off, traffic goes direct, and the reason is the
    # last thing the user reads.
    warp_pbr_down
    # Never leave the router pinned to a variant that did not work either.
    warp_variant_clear
    # The fresh registration did not help either — leave the user with the one they had.
    warp_reregister_rollback
    if warp_engine_connected; then
        # Cloudflare accepted the CONNECT-IP request and traffic still does not pass. State
        # what is observed, and stop short of naming a culprit: the previous wording blamed
        # the provider, and it was derived from a marker that turned out to mean nothing
        # ("Tunnel established" is printed before any dialling). MTU, a pinned endpoint and
        # a filtered path all look identical from here.
        _wlog "сессия к Cloudflare установлена, но трафик внутри туннеля не проходит"
        _wlog "режим включён, трафик идёт напрямую; z2k продолжит попытки в фоне"
    else
        _wlog "туннель НЕ поднялся за ${WARP_ENABLE_BUDGET}с — режим включён, но трафик идёт напрямую"
    fi
    _wlog "причина: ${WARP_LIVE_WHY:-неизвестна}"
    return 2
}

warp_disable() {
    _wlog "disable"
    warp_pbr_down          # tunnel keeps running idle; re-enable just re-adds the route
    # Drop the cached verdict rather than leaving a stale one: with the mode off nothing
    # probes any more. Absent == unknown, which is the truth. (Deliberately NOT inside
    # warp_pbr_down — the fail-open path tears routing down while KEEPING the "dead"
    # verdict, which is exactly what the panel must show.)
    rm -f "$WARP_LIVE_STAMP" 2>/dev/null
    _wlog "game WARP mode OFF"
}

# user's own choice. Returns 0 iff it wrote (the caller must then restart usque to apply it).
# Case 3 (see header): the tunnel is down and the package does not self-retry — restart usque
# the way a manual "usque off/on" does. COOLDOWN-guarded via a stamp file so a genuinely-
# blocked endpoint gets at most one restart per WARP_KICK_COOLDOWN, never a storm.
warp_usque_kick() {
    [ -x "$USQUE_INIT" ] || return 0
    # The stamp is written BEFORE the restart, and an unwritable stamp means "don't restart":
    # otherwise a dead tunnel plus a full/read-only filesystem would restart usque every tick,
    # the exact storm the cooldown exists to prevent.
    _warp_cooldown_ok "$WARP_KICK_STAMP" "$WARP_KICK_COOLDOWN" || return 0
    _wlog "tunnel dead — restarting usque to reconnect (cooldown ${WARP_KICK_COOLDOWN}s)"
    warp_usque_restart
    return 0
}

# Enrollment fallback: enroll a device THROUGH the VPS relay when the direct (desynced) enroll
# can't reach api.cloudflareclient.com. usque honours HTTPS_PROXY, so we just point it at the
# restricted CONNECT proxy. COOLDOWN-guarded. On success writes session.conf and restarts usque.
warp_vps_register() {
    [ -x "$USQUE_BIN" ] || return 1
    [ -n "$WARP_VPS_PROXY" ] || return 1
    _warp_cooldown_ok "$WARP_REG_STAMP" "$WARP_REG_COOLDOWN" || return 1
    _wlog "direct enroll blocked — enrolling via VPS relay"
    HTTPS_PROXY="$WARP_VPS_PROXY" https_proxy="$WARP_VPS_PROXY" \
        "$USQUE_BIN" register --accept-tos --config "$USQUE_SESSION" >/dev/null 2>&1
    if [ -s "$USQUE_SESSION" ]; then
        _wlog "VPS enrollment OK — restarting usque"
        warp_usque_restart
        return 0
    fi
    _wlog "VPS enrollment failed"
    return 1
}

# Direct (desynced, region-correct) enrollment. We run `usque register` OURSELVES instead of
# restarting S51usque and letting its fn_create_session_if_required do it: the restart cost a
# full NDM interface teardown/bring-up on EVERY retry — one per selfheal tick for as long as
# enrollment kept failing — while producing exactly the same HTTPS attempt against
# api.cloudflareclient.com that lets autocircular rotate a strategy on it. Same signal, none
# of the churn; only a SUCCESSFUL enrollment restarts usque, once.
warp_register_direct() {
    [ -x "$USQUE_BIN" ] || return 1
    "$USQUE_BIN" register --accept-tos --config "$USQUE_SESSION" >/dev/null 2>&1
    [ -s "$USQUE_SESSION" ] || return 1
    _wlog "direct enrollment OK — restarting usque"
    warp_usque_restart
    return 0
}

# LAST-RESORT re-enrollment, for the one shape where upstream says it helps: the session
# establishes ("Connected to MASQUE server") and nothing passes through it. usque's author
# on issue #73 — same "tls: handshake failure" we saw — reports it works with a NEWLY
# GENERATED config, and notes Cloudflare rolled out PQC crypto that older registrations
# predate.
#
# This burns the device key, so it is fenced hard: the previous registration is copied
# aside FIRST and put back if the new one does not fix anything, the existing enrollment
# cooldown applies, and the caller runs it at most once. Losing a registration to a guess
# would be a worse outcome than the problem.
warp_reregister_guarded() {
    [ -x "$USQUE_BIN" ] || return 1
    [ -s "$USQUE_SESSION" ] || return 1
    _warp_cooldown_ok "$WARP_REG_STAMP" "$WARP_REG_COOLDOWN" || {
        _wlog "перерегистрация под кулдауном — пропускаю"; return 1; }
    cp -f "$USQUE_SESSION" "$USQUE_SESSION.prev" 2>/dev/null || return 1
    # Drop any endpoint variant FIRST. A fresh registration writes session.conf, but the
    # init prefers session.alt.conf when it exists — so without this the engine would keep
    # starting on the old pinned config with the OLD key, and "re-registration did not
    # help" would be structurally guaranteed. That is the field report, exactly.
    warp_variant_clear
    _wlog "сессия встаёт, но трафика нет — пробую свежую регистрацию (прежняя сохранена)"
    "$USQUE_BIN" register --accept-tos --config "$USQUE_SESSION" >/dev/null 2>&1
    # A truncated or key-less config is worse than the old one: put it back at once.
    if [ ! -s "$USQUE_SESSION" ] || ! grep -q '"private_key"' "$USQUE_SESSION" 2>/dev/null; then
        _wlog "регистрация не удалась — возвращаю прежнюю"
        cp -f "$USQUE_SESSION.prev" "$USQUE_SESSION" 2>/dev/null
        rm -f "$USQUE_SESSION.prev"
        return 1
    fi
    warp_usque_restart
    return 0
}

# Put the previous registration back when the fresh one did not help either — the user is
# then exactly where they started rather than one device key poorer.
warp_reregister_rollback() {
    [ -s "$USQUE_SESSION.prev" ] || return 0
    cp -f "$USQUE_SESSION.prev" "$USQUE_SESSION" 2>/dev/null
    rm -f "$USQUE_SESSION.prev"
    _wlog "свежая регистрация не помогла — вернул прежнюю"
    warp_usque_restart
}

# Enrollment gate. No session.conf means the device was never enrolled, so the tunnel can't
# exist. Give the DIRECT enroll (desynced, region-correct) a few tries first — each S51usque
# restart re-runs `usque register` and lets autocircular rotate the strategy on
# cloudflareclient.com — then fall back to the VPS relay only for routers whose ISP blocks the
# reg API outright. Returns 0 when it handled enrollment this tick (selfheal should stop),
# 1 when already enrolled (selfheal proceeds to route).
warp_enroll_or_fallback() {
    # Adopt any key we already own before burning a new Cloudflare device. Adoption used to
    # live only in the init's start path, which self-heal never reaches — so a router whose
    # state was wiped kept registering fresh devices every tick.
    warp_adopt_legacy_state
    if [ ! -s "$USQUE_SESSION" ] && [ -s /opt/etc/usque/session.conf ]; then
        mkdir -p "$WARP_DIR" 2>/dev/null
        cp -f /opt/etc/usque/session.conf "$USQUE_SESSION" 2>/dev/null && \
            { chmod 600 "$USQUE_SESSION" 2>/dev/null; _wlog "adopted the usque package device key"; }
    fi
    if [ -s "$USQUE_SESSION" ]; then
        [ -f "$WARP_REG_COUNT" ] && rm -f "$WARP_REG_COUNT" 2>/dev/null
        return 1
    fi
    local n
    n=$(cat "$WARP_REG_COUNT" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -lt "$WARP_REG_DIRECT_TRIES" ]; then
        { echo $((n + 1)) > "$WARP_REG_COUNT"; } 2>/dev/null
        _wlog "no session.conf — direct enroll retry $((n + 1))/$WARP_REG_DIRECT_TRIES (desync)"
        warp_register_direct
    else
        warp_vps_register
        # ALTERNATE, don't defect for good: reset the counter so the direct path gets another
        # round. The old code walked one way — after three direct failures it never tried
        # direct again and pinned all hope on the relay, so a relay that is down, rate-limited
        # or whose credentials rotated left the router permanently unenrollable, even after the
        # ISP stopped blocking the reg API.
        { echo 0 > "$WARP_REG_COUNT"; } 2>/dev/null
    fi
    return 0
}

# Re-assert the split-tunnel route an NDM firewall reload / WAN flap wiped, and — unlike the
# old route-only version — recover a tunnel the package left dead (missing install, wrong
# subnet, unenrolled, or up-but-not-carrying-traffic), which is what forced users to toggle
# usque by hand. Called ~every minute by the scheduler.
warp_selfheal() {
    [ "$(warp_flag)" = "1" ] || return 0
    # A pinned endpoint variant that is not delivering must not survive here forever.
    warp_variant_expire
    # And the device MTU must not drift above what the engine can read.
    warp_mtu_ensure
    # Our own handshake must stay out of the bypass, whatever the whitelist says.
    warp_endpoint_nozapret
    # One-shot r-62 drain, marker-guarded (one file test per tick once done). It has to be
    # reachable from here, not only from the toggle: a router upgraded with the mode already
    # ON would otherwise keep double-NATing until somebody happened to toggle it off and on.
    warp_purge_legacy_nat
    # Case 0: usque is not installed at all. This used to be unreachable here — warp_install
    # was only ever called from `enable`, and the boot path (S99zapret2 backgrounds
    # `z2k-warp.sh enable`) runs when the WAN is often not up yet, so its .ipk fetch fails and
    # nothing ever retried. The mode then stayed flagged ON and stone dead until somebody
    # toggled it by hand — which is precisely why "в консоли включил и заработало". Retry here,
    # cooldown-guarded because the package is ~14 MB.
    # Gate on the ENGINE, not on our init: install.sh deploys S51z2k-warp unconditionally, so
    # testing the init made this branch permanently unreachable and self-heal could never
    # provision a missing engine — the mode would sit flagged ON and dead forever.
    if [ ! -x "$USQUE_BIN" ]; then
        _warp_cooldown_ok "$WARP_INSTALL_STAMP" "$WARP_INSTALL_COOLDOWN" || return 0
        _wlog "usque missing while WARP is enabled — installing"
        warp_install || return 0
        return 0    # the install path already restarted usque; assert routing next tick
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
        warp_live_record 0
        warp_usque_kick
        return 0
    fi
    # Case 4 — the one nothing used to catch. Address + link UP proves only that NDM
    # configured the interface, not that the MASQUE session to Cloudflare exists. usque
    # running-but-never-connected (blocked endpoint, expired device key, wedged after a WAN
    # flap) looked healthy to every check above, so the tunnel stayed dead indefinitely while
    # the panel showed "работает".
    #
    # FAIL OPEN. Routing is asserted ONLY while the tunnel is proven to carry traffic, and
    # torn down the moment it is not. Steering the game ipset into a tun whose session is
    # dead does not degrade those destinations — it BLACKHOLES them, and the list is tens of
    # thousands of networks (Cloudflare, AWS, Sony, Epic). Going direct means a game server
    # blocked by IP stays blocked, which is the pre-WARP status quo; blackholing takes out
    # half the internet for every device behind the router. The kick stays cooldown-guarded,
    # so recovery keeps being attempted without a restart storm.
    if warp_tunnel_live_retry; then
        _warp_streak_set 0
        ipset list "$WARP_IPSET" >/dev/null 2>&1 || warp_ipset_load
        warp_pbr_up
        return 0
    fi
    local streak; streak=$(( $(_warp_streak_get) + 1 ))
    _warp_streak_set "$streak"
    # The daemon being GONE is not the same failure as the tunnel being unhealthy. Starting a
    # stopped daemon is cheap and always right, so it is not cooldown-guarded; hammering a
    # running-but-blocked one is what the cooldown exists to prevent.
    if ! warp_usque_running; then
        _wlog "usque is not running — starting it (attempt $streak)"
        warp_usque_restart
    else
        warp_usque_kick
    fi
    # Fail open only after SUSTAINED failure. Tearing the route down on the first miss is
    # counter-productive: usque rebuilds the session when outgoing traffic appears, and the
    # route is what carries that traffic. Give it a few ticks before choosing the blackhole
    # guard over the recovery path.
    if [ "$streak" -ge "$WARP_FAIL_THRESHOLD" ]; then
        _wlog "tunnel still not carrying traffic after $streak checks — routing torn down (traffic goes direct) while we reconnect"
        warp_pbr_down
    fi
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
        echo "flag=$(warp_flag) iface=$WARP_IFACE addr=$(ip -o addr show "$WARP_IFACE" 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1) ipset=$(warp_ipset_count) live=$(warp_live_cached)"
        ;;
    # Force a fresh end-to-end probe (menu / support diagnostics). Prints on/off and sets the
    # exit code, so it is usable both by a human and by `if sh z2k-warp.sh probe; then`.
    probe)
        if warp_tunnel_live; then echo "warp=on"; else echo "warp=off"; exit 1; fi
        ;;
    *) echo "usage: $0 {install|enable|disable|selfheal|ipset|migrate|status|probe}" >&2; exit 1 ;;
esac
