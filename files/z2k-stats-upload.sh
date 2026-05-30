#!/bin/sh
# z2k-stats-upload.sh — anonymized strategy-stats uploader (client side).
#
# Sends a privacy-preserving snapshot of which rotation strategy each pool
# landed on, so the project can see (in aggregate, across opted-in devices)
# which strategies actually hold traffic and which never play — and reorder
# rotation profiles accordingly. See vps-stats/ for the server side.
#
# WHAT LEAVES THE DEVICE (and nothing else):
#   * pool key      — e.g. yt_quic / rkn_tcp / yt_tcp  (a strategy bucket name)
#   * strategy slot — the integer rotation slot the pool currently sits on
#   * dwell         — seconds the slot has been stable (now - last-change ts)
# WHAT NEVER LEAVES THE DEVICE:
#   * the host/domain column of state.tsv (the sites you visit) — dropped here;
#   * your IP / provider / region — never read, and the server discards the
#     source IP on receipt;
#   * ANY device identifier — no serial, no MAC, no install-id, not even a random
#     nonce. Per the privacy audit, a stable id would make uploads longitudinally
#     joinable and re-introduce identity. Uploads are ~1/day so no de-dup key is
#     needed; the server treats each upload as one anonymous device-day sample.
#
# Controlled by Z2K_STATS (default 1/ON). Set Z2K_STATS=0 in the config or via
# the menu / webpanel toggle to opt out. Every failure path is a silent no-op:
# this script must NEVER affect the bypass.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

ZAPRET2_DIR="/opt/zapret2"
CONFIG="${ZAPRET2_DIR}/config"
STATE_TSV="${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv"

# Endpoint + anti-abuse token. The token is a spam speed-bump (the payload is
# anonymized), not a secret; it can be rotated by setting Z2K_STATS_TOKEN /
# Z2K_STATS_ENDPOINT in the config without a code release.
ENDPOINT="http://213.176.74.63:8088/stats"
TOKEN="z2kstats-pub-1"

# --- read overridable settings + the on/off flag from config -----------------
Z2K_STATS=1
if [ -f "$CONFIG" ]; then
    _v=$(grep '^Z2K_STATS=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2 | tr -dc '0-9')
    [ -n "$_v" ] && Z2K_STATS="$_v"
    _e=$(grep '^Z2K_STATS_ENDPOINT=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$_e" ] && ENDPOINT="$_e"
    _t=$(grep '^Z2K_STATS_TOKEN=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$_t" ] && TOKEN="$_t"
fi

# Opt-out short-circuit.
[ "$Z2K_STATS" = "1" ] || exit 0
[ -f "$STATE_TSV" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

NOW=$(date +%s)

# --- build anonymized rows: DROP host ($2) entirely --------------------------
# state.tsv line: pool<TAB>host<TAB>strategy<TAB>ts  (# comments skipped)
rows=$(awk -F'\t' -v now="$NOW" '
    /^#/ { next }
    NF >= 3 {
        pool=$1; strat=$3; ts=$4
        if (pool == "" || strat !~ /^[0-9]+$/) next
        if (ts !~ /^[0-9]+$/) ts=now
        dwell = now - ts; if (dwell < 0) dwell = 0
        # $2 (host) is deliberately NEVER referenced.
        printf "%s{\"pool\":\"%s\",\"strategy\":%s,\"dwell\":%s}", sep, pool, strat, dwell
        sep = ","
    }
' "$STATE_TSV" 2>/dev/null)
[ -n "$rows" ] || exit 0

payload="{\"schema\":1,\"rows\":[${rows}]}"

# --- POST: short timeout, silent failure -------------------------------------
curl -s -o /dev/null -m 12 --connect-timeout 6 \
    -X POST "$ENDPOINT" \
    -H "X-Z2K-Token: ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null 2>&1 || true

exit 0
