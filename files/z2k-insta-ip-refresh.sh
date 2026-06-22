#!/bin/sh
# /opt/zapret2/z2k-insta-ip-refresh.sh — refresh Instagram/cdninstagram
# ip host records from a fresh DNS lookup on the EU-egress VPS.
#
# Background: Keenetic users get Instagram via ndmc `ip host` static
# overrides (provider DNS pollutes A records). install.sh bakes in a
# snapshot of edge IPs from the install date, but Meta rotates these
# edges constantly — within weeks the cached IPs drift to dead nodes.
# Dead IPs cause TLS-handshake timeouts on background app connections,
# which the autocircular failure detector reads as "strategy not
# bypassing DPI" and rotates a perfectly working strategy needlessly.
#
# This script: hits the VPS /resolve endpoint (HMAC-authenticated),
# rewrites `ip host` entries for the 7 insta hostnames, flushes stale
# conntrack so apps reconnect through new IPs.
#
# Honors:
#  - Z2K_INSTA_IP_REFRESH=0 in /opt/zapret2/config  →  skip
#  - zero existing ndmc records for instagram/cdninstagram (= user
#    pressed [I] Clear in menu)                      →  skip
#
# Called from z2k-update-lists.sh after the geosite refresh, and once
# from install.sh on fresh install (to replace the previously-baked-in
# defaults with live edges).

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

LOG="/tmp/z2k-log/z2k-insta-refresh.log"
# CWE-59: root-owned 0700 log dir
# CWE-59: /tmp/z2k-log должен быть чистым root-owned каталогом. symlink /
# не-каталог / чужой владелец = возможная подмена атакующим (с planted
# symlink'ами внутри) → снести и создать заново. busybox `stat -c` нет —
# владельца берём из `ls -ld`.
if [ -L /tmp/z2k-log ] || { [ -e /tmp/z2k-log ] && [ ! -d /tmp/z2k-log ]; } || \
   { [ -d /tmp/z2k-log ] && [ "$(ls -ld /tmp/z2k-log 2>/dev/null | awk '{print $3}')" != root ]; }; then
    rm -rf /tmp/z2k-log 2>/dev/null
fi
mkdir -p /tmp/z2k-log 2>/dev/null && chown root /tmp/z2k-log 2>/dev/null
chmod 700 /tmp/z2k-log 2>/dev/null
CONFIG="/opt/zapret2/config"
RELAY_URL="https://213.176.74.63.nip.io/resolve"
# Dedicated /resolve secret, DECOUPLED from the tunnel secret (Mark 2026-06-20).
# Rotating the tunnel credential must not break Instagram IP refresh, and this
# low-value secret — it only gates a public DNS A-record lookup, not the Telegram
# relay — living here in a public shell file must NOT grant tunnel access. The VPS
# validates it via the relay's --resolve-secret. Override via Z2K_RESOLVE_SECRET
# in /opt/zapret2/config to rotate without editing this file.
SECRET=$(awk -F= '/^Z2K_RESOLVE_SECRET=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG" 2>/dev/null)
[ -z "$SECRET" ] && SECRET="57745177a4b883471a4ddc6124a1df6fec77e790729e074ed34dc434f7cdb6f2"

# Hosts we manage. Must match the VPS-side whitelist (insta apex +
# *.instagram.com / *.cdninstagram.com suffixes).
HOSTS="instagram.com www.instagram.com graph.instagram.com api.instagram.com instagram.c10r.instagram.com static.cdninstagram.com scontent.cdninstagram.com"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG"
}

# Rotate log if it grew over 64KB.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null)" -gt 65536 ]; then
    mv -f "$LOG" "${LOG}.old" 2>/dev/null
fi

log "=== refresh start ==="

# 1. Explicit user disable wins.
if [ -f "$CONFIG" ]; then
    flag=$(awk -F= '/^Z2K_INSTA_IP_REFRESH=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG")
    if [ "$flag" = "0" ]; then
        log "Z2K_INSTA_IP_REFRESH=0 — disabled by user, exit"
        exit 0
    fi
fi

# 2. ndmc must be present (this is Keenetic-only).
if ! command -v ndmc >/dev/null 2>&1; then
    log "ndmc not found — not on Keenetic, exit"
    exit 0
fi

# 3. If the user has zero ip host records for insta, they cleared them
#    via menu [I] — respect that, do not resurrect.
existing=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
    | awk '/^ip host/ && ($3 ~ /(^|\.)instagram\.com$/ || $3 ~ /(^|\.)cdninstagram\.com$/) {print}')
if [ -z "$existing" ]; then
    log "no existing ip host insta records (cleared by user via [I]?) — exit"
    exit 0
fi
log "found existing ip host records: $(printf '%s\n' "$existing" | wc -l | tr -d ' ')"

# 4. Build request body.
body='{"hosts":['
first=1
for h in $HOSTS; do
    if [ "$first" = "1" ]; then
        body="${body}\"${h}\""
        first=0
    else
        body="${body},\"${h}\""
    fi
done
body="${body}]}"

# 5. HMAC-SHA256(secret, body) → hex.
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$SECRET" -hex 2>/dev/null | awk '{print $NF}')
if [ -z "$sig" ]; then
    log "FAIL: openssl HMAC produced empty signature"
    exit 1
fi

# 6. POST to VPS.
response=$(curl -sS --max-time 15 -X POST "$RELAY_URL" \
    -H "Content-Type: application/json" \
    -H "X-Z2K-Auth: $sig" \
    --data "$body" 2>>"$LOG")
if [ -z "$response" ]; then
    log "FAIL: empty response from VPS"
    exit 1
fi
if ! printf '%s' "$response" | grep -q '"results"'; then
    log "FAIL: response without results: $response"
    exit 1
fi

# 7. Parse {"results":{"host":["ip","ip"], ... }} → host<TAB>ip lines.
# Entries are flat (one nesting level), separated by `],` — split there.
parsed=$(printf '%s' "$response" \
    | sed -e 's/.*"results":{//' -e 's/}}$//' \
    | sed -e 's/\],/\n/g' -e 's/\]$//' \
    | awk '
        {
            n1 = index($0, "\"")
            if (n1 == 0) next
            rest = substr($0, n1+1)
            n2 = index(rest, "\"")
            if (n2 == 0) next
            host = substr(rest, 1, n2-1)
            ips = substr(rest, n2+1)
            gsub(/[^0-9.,]/, "", ips)
            n = split(ips, arr, ",")
            for (i=1; i<=n; i++)
                if (arr[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                    print host "\t" arr[i]
        }')

if [ -z "$parsed" ]; then
    log "FAIL: could not parse response: $response"
    exit 1
fi

# 8. Diff & apply per host.
changes=0
touched_ips=""
for h in $HOSTS; do
    new_ips=$(printf '%s\n' "$parsed" | awk -v host="$h" '$1==host {print $2}' | head -3)
    if [ -z "$new_ips" ]; then
        log "skip $h (VPS returned no IPs)"
        continue
    fi
    old_ips=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
        | awk -v host="$h" '/^ip host/ && $3==host {print $4}')

    # Set equality?  Sort both and compare.
    new_sorted=$(printf '%s\n' "$new_ips" | sort -u)
    old_sorted=$(printf '%s\n' "$old_ips" | sort -u)
    if [ -n "$old_ips" ] && [ "$new_sorted" = "$old_sorted" ]; then
        log "unchanged $h: $(echo $new_ips | tr '\n' ' ')"
        continue
    fi

    # Remove ALL old entries for this host.
    for ip in $old_ips; do
        if LD_LIBRARY_PATH= ndmc -c "no ip host $h $ip" >/dev/null 2>&1; then
            log "  - $h $ip"
            touched_ips="$touched_ips $ip"
        else
            log "  FAIL remove $h $ip"
        fi
    done
    # Add fresh entries.
    for ip in $new_ips; do
        if LD_LIBRARY_PATH= ndmc -c "ip host $h $ip" >/dev/null 2>&1; then
            log "  + $h $ip"
        else
            log "  FAIL add $h $ip"
        fi
    done
    changes=$((changes + 1))
done

# 9. Persist & flush conntrack on dropped IPs so apps don't ride dead paths.
if [ "$changes" -gt 0 ]; then
    if LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1; then
        log "ndmc config saved"
    else
        log "WARN: ndmc config save failed"
    fi
    for ip in $touched_ips; do
        conntrack -D -d "$ip" >/dev/null 2>&1 || true
    done
    log "conntrack flushed for old IPs"
fi

log "=== refresh done: $changes host(s) updated ==="
exit 0
