#!/bin/sh
# /opt/zapret2/z2k-discord-voice-pin.sh — pin Discord voice servers
# (finland*.discord.media) to a known-good Cloudflare edge via ndmc `ip host`,
# ONE-TO-ONE with Flowseal's .service/hosts (same 200 domains, same IP).
#
# Why: Discord voice media (finlandNNNNN.discord.media) is Cloudflare-fronted.
# On ISPs that block the resolved edge IPs or poison discord.media DNS, voice
# won't connect even with the packet-level desync. Flowseal's Windows build
# ships a hosts file pinning all 200 finland voice nodes to one working CF edge
# (104.25.158.178). This is the router-native equivalent: mirror those exact
# pins into the NDM resolver so every LAN client on the router's DNS reaches
# the working edge. Composes with the nfqws2 keepalive desync on the voice
# ports (port-based / IP-agnostic — both layers apply, like Flowseal).
#
# Source of truth = Flowseal .service/hosts, mirrored by z2k-update-lists.sh
# into lists/flowseal_discord_voice_hosts.txt as "<ip> <host>" lines. So the
# pins stay byte-for-byte Flowseal's and auto-track their CF-edge rotations on
# each list refresh.
#
# Honors:
#   Z2K_DISCORD_VOICE_PIN=0 in /opt/zapret2/config  -> remove our pins, skip
#   dead CF edge (health-check fails)               -> remove our pins, skip
#                                                      (fall back to normal DNS;
#                                                       never pin to a dead IP)
#
# Called from z2k-update-lists.sh (after the list refresh) and install.sh.
# NDM-native: pins persist via `system configuration save` (survive reboot /
# NDM reconfig wipe — unlike iptables rules). Identified solely by the
# finland*.discord.media host pattern, so it never collides with the VPS-IP /
# github / ndmc-managed.txt cleanups in install.sh.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

# Paths are env-overridable (defaults are production; tests point them at a
# sandbox and stub ndmc/curl).
CONFIG="${Z2K_DVP_CONFIG:-/opt/zapret2/config}"
LIST="${Z2K_DVP_LIST:-/opt/zapret2/lists/flowseal_discord_voice_hosts.txt}"
HC_PORT="${Z2K_DVP_HC_PORT:-443}"
LOG="${Z2K_DVP_LOG:-/tmp/z2k-log/z2k-discord-voice-pin.log}"

# root-owned 0700 log dir (CWE-59), same guard as z2k-insta-ip-refresh.sh
if [ -L /tmp/z2k-log ] || { [ -e /tmp/z2k-log ] && [ ! -d /tmp/z2k-log ]; } || \
   { [ -d /tmp/z2k-log ] && [ "$(ls -ld /tmp/z2k-log 2>/dev/null | awk '{print $3}')" != root ]; }; then
    rm -rf /tmp/z2k-log 2>/dev/null
fi
mkdir -p /tmp/z2k-log 2>/dev/null && chown root /tmp/z2k-log 2>/dev/null
chmod 700 /tmp/z2k-log 2>/dev/null

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG"; }
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null)" -gt 65536 ]; then
    mv -f "$LOG" "${LOG}.old" 2>/dev/null
fi

# Remove every finland*.discord.media ip host record we manage, then persist.
remove_all_pins() {
    local present
    present=$(ndmc -c "show running-config" 2>/dev/null \
        | awk '/^ip host/ && $3 ~ /^finland[0-9]+\.discord\.media$/ {print $3" "$4}')
    [ -z "$present" ] && { log "no finland pins to remove"; return 0; }
    local IFS_orig="$IFS" line
    IFS='
'
    for line in $present; do
        IFS="$IFS_orig"
        ndmc -c "no ip host $line" >/dev/null 2>&1 && log "  - $line"
        IFS='
'
    done
    IFS="$IFS_orig"
    ndmc -c "system configuration save" >/dev/null 2>&1
    return 0
}

log "=== discord voice pin start ==="

# 0. Keenetic-only.
if ! command -v ndmc >/dev/null 2>&1; then
    log "ndmc not found — not on Keenetic, exit"
    exit 0
fi

# 1. Explicit user disable wins: strip our pins, fall back to normal DNS.
if [ -f "$CONFIG" ]; then
    flag=$(awk -F= '/^Z2K_DISCORD_VOICE_PIN=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG")
    if [ "$flag" = "0" ]; then
        log "Z2K_DISCORD_VOICE_PIN=0 — disabled by user, removing pins"
        remove_all_pins
        exit 0
    fi
fi

# 2. Need the mirrored Flowseal list.
if [ ! -s "$LIST" ]; then
    log "list $LIST missing/empty — nothing to apply, exit"
    exit 0
fi

# 3. Desired pins as "<host> <ip>" (list is Flowseal's "<ip> <host>" format).
#    All 200 finland nodes point at one CF edge — derive target IP from line 1.
desired=$(awk '$2 ~ /^finland[0-9]+\.discord\.media$/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $2" "$1}' "$LIST")
if [ -z "$desired" ]; then
    log "FAIL: no valid finland*.discord.media lines in list"
    exit 1
fi
target_ip=$(printf '%s\n' "$desired" | awk 'NR==1{print $2}')
want_count=$(printf '%s\n' "$desired" | wc -l | tr -d ' ')
hc_host=$(printf '%s\n' "$desired" | awk 'NR==1{print $1}')
log "desired: $want_count pins -> $target_ip"

# 4. Health-check the CF edge — never pin to a dead IP (this is the only
#    deviation from Flowseal, who trust their static hosts). Any TLS/HTTP
#    response (incl. 403 — voice nodes don't serve GET) = reachable; 000/empty
#    = dead -> remove pins and let normal DNS take over.
code=$(curl -s --max-time 8 --resolve "${hc_host}:${HC_PORT}:${target_ip}" \
        -o /dev/null -w '%{http_code}' "https://${hc_host}" 2>/dev/null)
if [ -z "$code" ] || [ "$code" = "000" ]; then
    log "health-check FAIL: $target_ip unreachable (code='$code') — removing pins"
    remove_all_pins
    exit 0
fi
log "health-check OK: $target_ip reachable (code=$code)"

# 5. Already in the desired state? (same IP + same count -> no-op)
cur_ip=$(ndmc -c "show running-config" 2>/dev/null \
    | awk '/^ip host/ && $3 ~ /^finland[0-9]+\.discord\.media$/ {print $4; exit}')
cur_count=$(ndmc -c "show running-config" 2>/dev/null \
    | awk '/^ip host/ && $3 ~ /^finland[0-9]+\.discord\.media$/' | wc -l | tr -d ' ')
if [ "$cur_ip" = "$target_ip" ] && [ "$cur_count" = "$want_count" ]; then
    log "unchanged: $cur_count pins already -> $target_ip"
    log "=== done (no change) ==="
    exit 0
fi

# 6. (Re)build: drop current finland pins, add the Flowseal set, persist, flush.
log "applying: was ${cur_count:-0} pins -> ${cur_ip:-none}, want $want_count -> $target_ip"
remove_all_pins
added=0 failed=0
tmp_apply="/tmp/z2k-log/.dvp-apply.$$"
printf '%s\n' "$desired" > "$tmp_apply"
while read -r h ip; do
    [ -n "$h" ] && [ -n "$ip" ] || continue
    if ndmc -c "ip host $h $ip" >/dev/null 2>&1; then
        added=$((added + 1))
    else
        failed=$((failed + 1))
        [ "$failed" -le 3 ] && log "  FAIL add $h $ip"
    fi
done < "$tmp_apply"
rm -f "$tmp_apply"
ndmc -c "system configuration save" >/dev/null 2>&1
if [ -n "$cur_ip" ] && [ "$cur_ip" != "$target_ip" ]; then
    conntrack -D -d "$cur_ip" >/dev/null 2>&1 || true
    log "conntrack flushed for old edge $cur_ip"
fi
log "=== done: pinned $added finland nodes -> $target_ip (failed=$failed) ==="
exit 0
