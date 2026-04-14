#!/bin/sh
# z2k-diag.sh — one-shot diagnostics snapshot for user support.
#
# Prints a compact summary of everything we usually ask a user about
# when triaging an issue: version, arch, service state, iptables rule
# counts, tunnel health, autocircular state, recent log tails.
#
# Designed to fit in a single Telegram message (~4000 chars) when
# typical. If a section grows large (e.g. big state.tsv), it's
# truncated with a trailing "... (N more lines)" marker.
#
# Usage:
#   sh /opt/zapret2/z2k-diag.sh          # full snapshot to stdout
#   sh /opt/zapret2/z2k-diag.sh --short  # compact: versions + service
#   sh /opt/zapret2/z2k-diag.sh --json   # machine-readable (for webpanel)
#
# Exit codes:
#   0 — diagnostics printed (even if some sub-probes failed)
#   1 — fatal: cannot even locate /opt/zapret2

set -u

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
VPS_IP="${VPS_IP:-213.176.74.63}"

MODE="full"
case "${1:-}" in
    --short) MODE="short" ;;
    --json)  MODE="json" ;;
    -h|--help)
        cat <<EOF
z2k-diag.sh — diagnostics snapshot

Usage:
  z2k-diag.sh             Full snapshot to stdout
  z2k-diag.sh --short     Versions + service state only
  z2k-diag.sh --json      Machine-readable JSON (for webpanel)
  z2k-diag.sh --help      This help
EOF
        exit 0
        ;;
esac

# Bail early if z2k isn't installed at all.
if [ ! -d "$ZAPRET2_DIR" ]; then
    echo "z2k-diag: $ZAPRET2_DIR does not exist — z2k not installed?" >&2
    exit 1
fi

# Safe config read — no `source` (config file may have shell metacharacters).
safe_read() {
    local key="$1"
    local file="$2"
    local default="${3:-}"
    [ -r "$file" ] || { printf '%s' "$default"; return; }
    local val
    val=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | sed "s/^${key}=//" | tr -d '"')
    [ -z "$val" ] && val="$default"
    printf '%s' "$val"
}

# Resolve the Entware arch (e.g. mipsel-3.4_kn) via opkg, quiet fallback to uname -m.
get_entware_arch() {
    local opkg_bin="opkg"
    [ -x /opt/bin/opkg ] && opkg_bin="/opt/bin/opkg"
    command -v "$opkg_bin" >/dev/null 2>&1 || { uname -m 2>/dev/null; return; }
    "$opkg_bin" print-architecture 2>/dev/null | awk '
        $1 == "arch" && $2 != "all" {
            prio = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
            if (prio >= max) { max = prio; arch = $2 }
        }
        END { if (arch != "") print arch; else print ""; }
    ' || uname -m 2>/dev/null
}

# Primary LAN IP (prefer RFC1918 over the public WAN default-route source).
get_lan_ip() {
    local ip
    ip=$(ip -4 addr show 2>/dev/null \
        | awk '/inet (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/ {split($2,a,"/"); print a[1]; exit}')
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    fi
    printf '%s' "${ip:-unknown}"
}

# Ping VPS (5 packets, short timeout), return "avg_rtt_ms loss_pct" or "-- --".
ping_vps_rtt() {
    local out
    out=$(ping -c 5 -W 2 "$VPS_IP" 2>/dev/null | tail -3) || { printf -- '-- --'; return; }
    local loss rtt
    loss=$(printf '%s\n' "$out" | grep -oE '[0-9]+% packet loss' | head -1 | tr -d '% packetloss ' || true)
    rtt=$(printf '%s\n' "$out" | grep -oE 'min/avg/max[^=]*= *[0-9.]+/[0-9.]+' | head -1 | awk -F'/' '{print $(NF)}' || true)
    [ -z "$loss" ] && loss="--"
    [ -z "$rtt" ] && rtt="--"
    printf '%s %s' "$rtt" "$loss"
}

# Shortened file tail with "... (N more)" marker if truncated.
short_tail() {
    local file="$1"
    local lines="${2:-10}"
    [ -r "$file" ] || { echo "(file missing: $file)"; return; }
    local total
    total=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        echo "(empty)"
        return
    fi
    if [ "$total" -gt "$lines" ]; then
        local extra=$((total - lines))
        echo "(... first ${extra} older lines skipped)"
    fi
    tail -n "$lines" "$file" 2>/dev/null
}

# =============================================================================
# SECTION: version + host
# =============================================================================
print_version_host() {
    printf '=== z2k diag / %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now)"
    local version
    version=$(safe_read "Z2K_VERSION" "/tmp/z2k/lib/utils.sh" "unknown")
    [ "$version" = "unknown" ] && [ -r "/opt/zapret2/z2k-version" ] && \
        version=$(cat /opt/zapret2/z2k-version 2>/dev/null)
    printf 'z2k version       : %s\n' "$version"

    local kernel
    kernel=$(uname -rsm 2>/dev/null)
    printf 'kernel            : %s\n' "$kernel"

    local sysinfo
    sysinfo=$(grep -iE 'system type|cpu model' /proc/cpuinfo 2>/dev/null | head -2 | paste -sd'; ' - 2>/dev/null || true)
    [ -n "$sysinfo" ] && printf 'cpu               : %s\n' "$sysinfo"

    local entw
    entw=$(get_entware_arch)
    printf 'entware arch      : %s\n' "${entw:-unknown}"

    local nfqws_bin="${ZAPRET2_DIR}/nfq2/nfqws2"
    local nfqws_ver
    if [ -x "$nfqws_bin" ]; then
        nfqws_ver=$("$nfqws_bin" --version 2>&1 | head -1 || true)
        [ -z "$nfqws_ver" ] && nfqws_ver="(no --version output)"
    else
        nfqws_ver="(nfqws2 binary missing at $nfqws_bin)"
    fi
    printf 'nfqws2            : %s\n' "$nfqws_ver"

    local lan_ip
    lan_ip=$(get_lan_ip)
    printf 'LAN IP            : %s\n' "$lan_ip"
}

# =============================================================================
# SECTION: service state + config flags
# =============================================================================
print_service() {
    printf '\n=== service ===\n'
    local nfqws_pids
    nfqws_pids=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | tr '\n' ' ')
    if [ -n "$nfqws_pids" ]; then
        printf 'nfqws2 PIDs       : %s\n' "${nfqws_pids% }"
        # Uptime of first PID
        local pid_first
        pid_first=$(echo "$nfqws_pids" | awk '{print $1}')
        if [ -r "/proc/$pid_first/stat" ]; then
            local etime
            etime=$(ps -o etime= -p "$pid_first" 2>/dev/null | tr -d ' ' || true)
            [ -n "$etime" ] && printf 'nfqws2 uptime     : %s\n' "$etime"
        fi
    else
        printf 'nfqws2 PIDs       : (not running)\n'
    fi

    local cfg="${ZAPRET2_DIR}/config"
    if [ -r "$cfg" ]; then
        printf 'config flags      : '
        local flags=""
        for k in GAME_MODE_ENABLED ROBLOX_UDP_BYPASS RKN_SILENT_FALLBACK DROP_DPI_RST GEOSITE_ENABLED; do
            local v
            v=$(safe_read "$k" "$cfg" "-")
            flags="$flags $k=$v"
        done
        printf '%s\n' "$flags"
    else
        printf 'config flags      : (config missing at %s)\n' "$cfg"
    fi
}

# =============================================================================
# SECTION: iptables rules
# =============================================================================
print_iptables() {
    printf '\n=== iptables ===\n'
    # grep -c already prints a number and returns exit 1 on 0 matches —
    # wrap in `|| true` so set -u / set -e friends don't abort and so the
    # caller variable is a clean integer.
    local nfq_mangle nfq_prerouting tg_redirect_pre tg_redirect_out
    nfq_mangle=$( (iptables -t mangle -L POSTROUTING -n 2>/dev/null || true) | grep -c NFQUEUE || true)
    nfq_prerouting=$( (iptables -t mangle -L PREROUTING -n 2>/dev/null || true) | grep -c NFQUEUE || true)
    tg_redirect_pre=$( (iptables -t nat -L PREROUTING -n 2>/dev/null || true) | grep -c 'redir ports 1443' || true)
    tg_redirect_out=$( (iptables -t nat -L OUTPUT -n 2>/dev/null || true) | grep -c 'redir ports 1443' || true)
    : "${nfq_mangle:=0}"
    : "${nfq_prerouting:=0}"
    : "${tg_redirect_pre:=0}"
    : "${tg_redirect_out:=0}"
    printf 'NFQUEUE postroute : %s\n' "$nfq_mangle"
    printf 'NFQUEUE prerouting: %s\n' "$nfq_prerouting"
    printf 'TG REDIR PREROUT  : %s  (expected 10 if tunnel enabled)\n' "$tg_redirect_pre"
    printf 'TG REDIR OUTPUT   : %s  (expected 10 if tunnel enabled)\n' "$tg_redirect_out"
    if [ -e /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh ]; then
        printf 'NDM hook          : installed\n'
    else
        printf 'NDM hook          : NOT installed (TG rules may get wiped on network events)\n'
    fi
}

# =============================================================================
# SECTION: TG tunnel
# =============================================================================
print_tunnel() {
    printf '\n=== telegram tunnel ===\n'
    local tg_bin="/opt/sbin/tg-mtproxy-client"
    if [ -x "$tg_bin" ]; then
        local md5 size tg_pid
        md5=$(md5sum "$tg_bin" 2>/dev/null | awk '{print $1}')
        size=$(wc -c < "$tg_bin" 2>/dev/null | tr -d ' ')
        printf 'binary            : %s (%s bytes, md5 %s)\n' "$tg_bin" "$size" "$md5"
        tg_pid=$(pgrep -fa tg-mtproxy-client 2>/dev/null | grep -v grep | awk '{print $1}' | head -1)
        if [ -n "$tg_pid" ]; then
            printf 'process           : PID %s\n' "$tg_pid"
        else
            printf 'process           : NOT running\n'
        fi
    else
        printf 'binary            : (not installed)\n'
    fi
    local rtt_and_loss
    rtt_and_loss=$(ping_vps_rtt)
    local vps_rtt vps_loss
    vps_rtt=$(echo "$rtt_and_loss" | awk '{print $1}')
    vps_loss=$(echo "$rtt_and_loss" | awk '{print $2}')
    printf 'VPS ping %s     : avg %s ms, loss %s%%\n' "$VPS_IP" "$vps_rtt" "$vps_loss"
}

# =============================================================================
# SECTION: autocircular state
# =============================================================================
print_rotator() {
    printf '\n=== autocircular state ===\n'
    local state="${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv"
    if [ ! -r "$state" ]; then
        printf '(no state.tsv at %s)\n' "$state"
        return
    fi
    local total
    total=$(grep -cvE '^(#|$)' "$state" 2>/dev/null | tr -d ' ')
    printf 'tracked entries   : %s\n' "${total:-0}"
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        return
    fi
    printf '(first 20 rows: key / host / strategy / ts)\n'
    grep -vE '^(#|$)' "$state" 2>/dev/null | head -20
    if [ "$total" -gt 20 ]; then
        printf '... %s more rows\n' "$((total - 20))"
    fi
}

# =============================================================================
# SECTION: recent logs
# =============================================================================
print_logs() {
    printf '\n=== nfqws2-startup.log (last 15) ===\n'
    short_tail /tmp/nfqws2-startup.log 15

    printf '\n=== tg-tunnel.log (last 10) ===\n'
    short_tail /tmp/tg-tunnel.log 10
}

# =============================================================================
# SECTION: short form (versions + service only, ≤10 lines)
# =============================================================================
print_short() {
    local version entw nfqws_pids lan_ip svc
    version=$(safe_read "Z2K_VERSION" "/tmp/z2k/lib/utils.sh" "unknown")
    entw=$(get_entware_arch)
    nfqws_pids=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    lan_ip=$(get_lan_ip)
    if [ -n "$nfqws_pids" ]; then
        svc="running (PID $(echo "$nfqws_pids" | awk '{print $1}'))"
    else
        svc="down"
    fi
    printf 'z2k=%s arch=%s lan=%s service=%s\n' \
        "$version" "$entw" "$lan_ip" "$svc"
}

# =============================================================================
# SECTION: JSON form (for webpanel /diag endpoint — Phase 3)
# =============================================================================
print_json() {
    # Intentionally minimal — webpanel will use sh-based sections in Phase 3.
    # This is a placeholder so the CLI --json flag doesn't 404 from the start.
    local version nfqws_pids svc
    version=$(safe_read "Z2K_VERSION" "/tmp/z2k/lib/utils.sh" "unknown")
    nfqws_pids=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$nfqws_pids" ]; then
        svc="running"
    else
        svc="down"
    fi
    printf '{"version":"%s","service":"%s","lan_ip":"%s","arch":"%s"}\n' \
        "$version" "$svc" "$(get_lan_ip)" "$(get_entware_arch)"
}

# =============================================================================
# main
# =============================================================================
case "$MODE" in
    short) print_short ;;
    json)  print_json ;;
    full)
        print_version_host
        print_service
        print_iptables
        print_tunnel
        print_rotator
        print_logs
        printf '\n=== end of diag ===\n'
        ;;
esac
