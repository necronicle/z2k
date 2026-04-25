#!/bin/sh
# z2k-classify-drift.sh — nightly drift detector.
#
# Runs z2k-classify on a curated set of "watch" domains, compares the
# block_type of each domain to yesterday's run, and logs drift events
# (block_type changed, or strategy that worked yesterday no longer
# works today) to /opt/var/log/z2k-classify-drift.log for morning
# review.
#
# Cron entry (registered by lib/install.sh):
#   30 4 * * * /opt/zapret2/z2k-classify-drift.sh
#
# Why 04:30 — runs after z2k-update-lists.sh (04:00) so any domain-
# list refreshes are already applied to the rotator profiles before
# we probe.
#
# Watch list:
#   1. Top-N most-classified domains from /opt/var/log/z2k-classify.log
#      invocations in last 7 days (real users' pain points)
#   2. Hard-coded canary list as fallback when invocation log is empty
#      or thin (so first-week-after-install drift is still detected)
#
# Output:
#   /opt/var/log/z2k-classify-drift.log — drift events only (compact)
#   /opt/var/log/z2k-classify-history.tsv — last-known block_type per
#     domain. Format: <domain>\t<block_type>\t<unix_ts>

set -eu

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CLASSIFY_BIN="${ZAPRET2_DIR}/z2k-classify"
INVOKE_LOG="/opt/var/log/z2k-classify.log"
DRIFT_LOG="/opt/var/log/z2k-classify-drift.log"
HISTORY_TSV="/opt/var/log/z2k-classify-history.tsv"
MAX_DOMAINS="${MAX_DOMAINS:-12}"
MAX_LOG_LINES="${MAX_LOG_LINES:-500}"

# Canary list — checked when invocation log doesn't have enough data.
# Mix of common-blocked (RKN-listed) and never-blocked sites so we
# can also detect the inverse drift (was-OK → now-broken).
CANARIES="
linkedin.com
rutracker.org
habr.com
chatgpt.com
github.com
dash.cloudflare.com
vercel.com
huggingface.co
"

# -----------------------------------------------------------------------------
# Bail-out paths
# -----------------------------------------------------------------------------

if [ ! -x "$CLASSIFY_BIN" ]; then
    # Don't fail loudly — drift cron is opportunistic, not critical.
    # Just leave a note in the drift log if it exists, then exit.
    [ -d "$(dirname "$DRIFT_LOG")" ] && {
        printf '%s | SKIP: %s missing or not executable\n' \
            "$(date -Iseconds 2>/dev/null || date)" "$CLASSIFY_BIN" \
            >> "$DRIFT_LOG" 2>/dev/null || true
    }
    exit 0
fi

mkdir -p /opt/var/log 2>/dev/null || true

# -----------------------------------------------------------------------------
# Build watch list
# -----------------------------------------------------------------------------

watch_list_tmp=$(mktemp 2>/dev/null || echo "/tmp/z2k-classify-drift-watch.$$")
trap 'rm -f "$watch_list_tmp"' EXIT INT TERM

if [ -s "$INVOKE_LOG" ]; then
    # Pull domains from invocation log lines like:
    #   2026-04-25T13:32:48 | invoke linkedin.com --apply
    # Take last 7 days (~10080 lines max), extract first non-flag arg.
    tail -n 10000 "$INVOKE_LOG" 2>/dev/null \
        | awk '
            /\| invoke /  {
                for (i = 1; i <= NF; i++) {
                    if ($i == "invoke" && i + 1 <= NF) {
                        for (j = i + 1; j <= NF; j++) {
                            arg = $j
                            if (substr(arg, 1, 1) != "-" && length(arg) > 0) {
                                # Strip protocol and path, normalize
                                sub(/^https?:\/\//, "", arg)
                                sub(/\/.*$/, "", arg)
                                print arg
                                break
                            }
                        }
                    }
                }
            }
        ' \
        | sort | uniq -c | sort -rn | awk '{print $2}' | head -n "$MAX_DOMAINS" \
        > "$watch_list_tmp"
fi

# If invocation log gave us <3 distinct domains, top up with canaries.
existing=$(wc -l < "$watch_list_tmp" 2>/dev/null || echo 0)
if [ "$existing" -lt 3 ]; then
    {
        cat "$watch_list_tmp" 2>/dev/null
        printf '%s\n' $CANARIES
    } | awk 'NF && !seen[$0]++' | head -n "$MAX_DOMAINS" > "${watch_list_tmp}.new"
    mv -f "${watch_list_tmp}.new" "$watch_list_tmp"
fi

domains_to_probe=$(wc -l < "$watch_list_tmp" 2>/dev/null || echo 0)
if [ "$domains_to_probe" = "0" ]; then
    printf '%s | SKIP: no domains to probe (canary list empty?)\n' \
        "$(date -Iseconds 2>/dev/null || date)" \
        >> "$DRIFT_LOG" 2>/dev/null || true
    exit 0
fi

# -----------------------------------------------------------------------------
# Compare-and-log loop
# -----------------------------------------------------------------------------

ts=$(date +%s 2>/dev/null || echo 0)
ts_iso=$(date -Iseconds 2>/dev/null || date)

# Spend at most 5 min total on the cron — stop early if we've used it.
deadline=$((ts + 300))

# Per-domain processing.
process_domain() {
    domain=$1

    [ -n "$domain" ] || return 0
    case "$domain" in
        ""|"#"*|*[\ \	]*) return 0 ;;
    esac

    now=$(date +%s 2>/dev/null || echo 0)
    [ "$now" -gt "$deadline" ] && return 0

    # Read previous block_type for this domain from history.
    prev_block=""
    if [ -s "$HISTORY_TSV" ]; then
        prev_block=$(awk -v d="$domain" -F '\t' '$1==d {b=$2} END {print b}' "$HISTORY_TSV")
    fi

    # Run classify in JSON mode, capture block_type and reason. We use
    # --timeout=20 so a single bad domain can't stall the entire cron.
    out=$("$CLASSIFY_BIN" "$domain" --json --timeout=20 2>/dev/null) || out=""
    if [ -z "$out" ]; then
        cur_block="error"
    else
        cur_block=$(printf '%s' "$out" | sed -n 's/.*"block_type":"\([^"]*\)".*/\1/p')
        [ -z "$cur_block" ] && cur_block="parse_error"
    fi

    # Drift detection rules. Log only meaningful events:
    #   - First-time observation of a domain (prev empty)
    #   - block_type changed since last run
    #   - now=error AND prev=non-error  (probe/network broke)
    #   - now=non-error AND prev=error  (recovered)
    if [ -z "$prev_block" ]; then
        printf '%s | NEW %s: %s\n' "$ts_iso" "$domain" "$cur_block" \
            >> "$DRIFT_LOG"
    elif [ "$prev_block" != "$cur_block" ]; then
        printf '%s | DRIFT %s: %s -> %s\n' \
            "$ts_iso" "$domain" "$prev_block" "$cur_block" \
            >> "$DRIFT_LOG"
    fi

    # Update history (replace prior row for this domain, append new).
    if [ -s "$HISTORY_TSV" ]; then
        awk -v d="$domain" -F '\t' '$1!=d' "$HISTORY_TSV" > "${HISTORY_TSV}.tmp"
    else
        : > "${HISTORY_TSV}.tmp"
    fi
    printf '%s\t%s\t%s\n' "$domain" "$cur_block" "$ts" >> "${HISTORY_TSV}.tmp"
    mv -f "${HISTORY_TSV}.tmp" "$HISTORY_TSV"
}

# Header for this run.
{
    printf '%s | RUN start (%d domain(s) to probe, deadline +5min)\n' \
        "$ts_iso" "$domains_to_probe"
} >> "$DRIFT_LOG"

while IFS= read -r d; do
    process_domain "$d"
done < "$watch_list_tmp"

printf '%s | RUN end\n' "$(date -Iseconds 2>/dev/null || date)" \
    >> "$DRIFT_LOG"

# Rotate drift log if it exceeds MAX_LOG_LINES (keep tail half).
if [ -f "$DRIFT_LOG" ]; then
    lines=$(wc -l < "$DRIFT_LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        keep=$((MAX_LOG_LINES / 2))
        rotated=$(mktemp 2>/dev/null) || rotated="${DRIFT_LOG}.tmp"
        tail -n "$keep" "$DRIFT_LOG" > "$rotated"
        mv -f "$rotated" "$DRIFT_LOG"
    fi
fi

exit 0
