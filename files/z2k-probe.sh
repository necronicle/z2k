#!/bin/sh
# z2k-probe.sh — active strategy probe for a single host.
#
# Phase 10 of the z2k anti-ТСПУ patch program. Iterates through every
# strategy defined in the autocircular profile (rkn_tcp by default),
# pins each one to the target host for the duration of one probe, and
# measures throughput via a timed 100 KB HTTPS download. Ranks the
# strategies by observed throughput and prints a top-N table.
#
# Design — *no service stop*:
#   Earlier z2k blockcheck paths (lib/strategies.sh:run_blockcheck_modern)
#   stop /opt/etc/init.d/S99zapret2 for the duration of the probe because
#   they run upstream blockcheck2.sh which needs exclusive NFQUEUE. This
#   is unacceptable for a tool intended for everyday debugging. Instead
#   we lean on the autocircular pin mechanism already in place:
#   writing a single row to state.tsv makes z2k-autocircular.lua use
#   that specific strategy for the next outgoing ClientHello to the
#   matching host, without touching the rest of the flow table. The
#   main nfqws2 keeps handling everything else while we iterate.
#
# Usage:
#   z2k-probe <host>               # rkn_tcp profile, 45 strategies, print top 5
#   z2k-probe <host> --profile=yt_tcp
#   z2k-probe <host> --apply       # after the ranking, pin the winner
#                                    permanently in state.tsv
#
# Limitations:
#   1. Probe traffic uses whichever strategy is pinned, so a user on a
#      different device hitting the same host during the probe gets the
#      probe strategy instead of the autocircular rotation. Duration is
#      ~45 iterations × 3s each ≈ 2 minutes. Acceptable trade-off.
#   2. "Throughput" is measured over a 100 KB body — CDN edge caching
#      and route variance contribute noise. Results are indicative,
#      not exact. Run 2–3 times and intersect if one result looks off.
#   3. Only probes TLS strategies (--filter-l7=tls) — the rkn_tcp and
#      yt_tcp profiles. QUIC profiles not yet supported (different
#      state.tsv key structure).

set -eu

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

ZAPRET_BASE="${ZAPRET_BASE:-/opt/zapret2}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
PROBE_RANGE_BYTES="${PROBE_RANGE_BYTES:-102400}"      # 100 KB
PROBE_TOP_N="${PROBE_TOP_N:-5}"
STATE_DIR="$ZAPRET_BASE/extra_strats/cache/autocircular"
STATE_TSV="$STATE_DIR/state.tsv"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: z2k-probe <host> [--profile=KEY] [--apply]

Iterates every strategy in the given autocircular profile (default:
rkn_tcp), pins each one to <host> in state.tsv, measures download
throughput via a 100 KB curl, ranks the results, and prints the top 5.

With --apply the best strategy is left pinned in state.tsv after the
probe completes. Without --apply the original state.tsv is restored.

Environment overrides:
  PROBE_TIMEOUT       per-iteration curl timeout, seconds (default 8)
  PROBE_RANGE_BYTES   body size to download per iteration (default 102400)
  PROBE_TOP_N         how many rows to show in the ranking (default 5)
USAGE
}

host=""
profile="rkn_tcp"
apply_mode="0"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        --profile=*)
            profile="${arg#--profile=}"
            ;;
        --apply)
            apply_mode="1"
            ;;
        -*)
            echo "z2k-probe: unknown option '$arg'" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -z "$host" ]; then
                host="$arg"
            else
                echo "z2k-probe: only one host allowed" >&2
                exit 2
            fi
            ;;
    esac
done

if [ -z "$host" ]; then
    usage >&2
    exit 2
fi

# Normalize host to the form z2k-autocircular.lua uses as state.tsv key:
# strip any URL scheme / path, keep just the bare hostname.
host=$(printf '%s' "$host" | sed -e 's|^https\?://||' -e 's|/.*$||')

# -----------------------------------------------------------------------------
# Derive strategy list from the profile's Strategy.txt
# -----------------------------------------------------------------------------

case "$profile" in
    rkn_tcp)  strategy_file="$ZAPRET_BASE/extra_strats/TCP/RKN/Strategy.txt" ;;
    yt_tcp)   strategy_file="$ZAPRET_BASE/extra_strats/TCP/YT/Strategy.txt"  ;;
    gv_tcp)   strategy_file="$ZAPRET_BASE/extra_strats/TCP/YT_GV/Strategy.txt" ;;
    *)
        echo "z2k-probe: unsupported profile '$profile' (expected rkn_tcp/yt_tcp/gv_tcp)" >&2
        exit 2
        ;;
esac

if [ ! -f "$strategy_file" ]; then
    echo "z2k-probe: strategy file not found: $strategy_file" >&2
    exit 1
fi

strategies=$(grep -o 'strategy=[0-9]*' "$strategy_file" | sort -t= -k2 -n -u | cut -d= -f2)
strategy_count=$(printf '%s\n' "$strategies" | wc -l)

if [ "$strategy_count" -lt 1 ]; then
    echo "z2k-probe: no strategies parsed from $strategy_file" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Backup state.tsv and register a cleanup trap so the probe is safe
# to kill mid-run. The trap restores the original file even on Ctrl-C.
# -----------------------------------------------------------------------------

# Single-instance lock. Two concurrent probes would race on state.tsv
# pins — the second one's tmp file clobbers the first's, and each trap
# cleanup restores its own backup, leaving state.tsv in an unpredictable
# mix. The webpanel "Start" button can also double-fire if the user
# clicks repeatedly before the modal opens, so this lock is a hard
# backstop: second probe refuses to start and prints a clear message.
LOCK_FILE="${Z2K_PROBE_LOCK:-/tmp/z2k-probe.lock}"
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        echo "z2k-probe: already running (pid $lock_pid). Wait for it to finish or kill it." >&2
        exit 1
    fi
    # Stale lock from a crashed previous run — clear it.
    rm -f "$LOCK_FILE"
fi
echo "$$" > "$LOCK_FILE"

work_dir=$(mktemp -d 2>/dev/null || mktemp -d -t z2kprobe)
state_backup="$work_dir/state.tsv.bak"
results_file="$work_dir/results.tsv"
: > "$results_file"

if [ -f "$STATE_TSV" ]; then
    cp "$STATE_TSV" "$state_backup"
else
    : > "$state_backup"
fi

cleanup() {
    # On any exit (success, failure, signal) restore the state.tsv
    # unless --apply mode is on AND we have a winning strategy pinned.
    if [ "$apply_mode" != "1" ] || [ ! -f "$work_dir/applied.flag" ]; then
        if [ -f "$state_backup" ]; then
            cp "$state_backup" "$STATE_TSV" 2>/dev/null || true
        fi
    fi
    rm -rf "$work_dir"
    # Only release the lock if WE own it (avoid a crashed-then-restarted
    # probe wiping the lock of a legitimate parallel instance that
    # somehow slipped through).
    if [ -f "$LOCK_FILE" ]; then
        owner=$(cat "$LOCK_FILE" 2>/dev/null)
        [ "$owner" = "$$" ] && rm -f "$LOCK_FILE"
    fi
}
trap cleanup EXIT INT TERM HUP

# -----------------------------------------------------------------------------
# Pin one strategy for the target host. Rewrites state.tsv atomically
# to avoid torn reads by the running autocircular Lua code.
# -----------------------------------------------------------------------------

pin_strategy() {
    s="$1"
    ts=$(date +%s 2>/dev/null || echo 0)
    tmp="$STATE_TSV.probe.$$.tmp"

    # autocircular creates STATE_DIR lazily on first write — it may not
    # exist yet on a freshly installed router, or may have been wiped
    # by a reinstall. Ensure it's there before we redirect, otherwise
    # the `> "$tmp"` below silently fails on busybox sh and the
    # follow-up mv blows up with "No such file or directory".
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null || {
            echo "z2k-probe: cannot create state dir $STATE_DIR" >&2
            return 1
        }
    fi

    # Start from the backup (original state) and overwrite/add our row.
    # Preserves all other hosts' pins while we mutate just this one.
    # Single awk pass avoids set -e tripping on grep -v returning 1
    # when the backup contains only comments or nothing to filter.
    {
        printf '# z2k autocircular state (persisted circular nstrategy)\n'
        if [ -s "$state_backup" ]; then
            awk -v p="$profile" -v h="$host" '
                /^#/ { next }
                /^[[:space:]]*$/ { next }
                {
                    n = split($0, f, "\t")
                    if (n >= 2 && f[1] == p && f[2] == h) next
                    print $0
                }
            ' "$state_backup"
        fi
        printf '%s\t%s\t%s\t%s\n' "$profile" "$host" "$s" "$ts"
    } > "$tmp"

    # Guard against the redirect silently producing nothing (e.g. a
    # concurrent FS hiccup) — check the tmp file is there before mv,
    # otherwise print a clear diagnostic instead of the cryptic
    # "can't rename: No such file or directory" from mv.
    if [ ! -f "$tmp" ]; then
        echo "z2k-probe: pin_strategy: failed to create $tmp" >&2
        return 1
    fi
    mv "$tmp" "$STATE_TSV"
}

# -----------------------------------------------------------------------------
# Run one timed probe to the host and emit a TSV row
#     <strategy>\t<ok>\t<http>\t<bytes>\t<seconds>\t<kbps>
# kbps is bytes/seconds/128 (kilobits per second). ok=1 on http 2xx/3xx.
# -----------------------------------------------------------------------------

probe_one() {
    s="$1"
    pin_strategy "$s"
    # Minimal pause for the pin to land and for any cached flow to
    # cycle out. autocircular reads state.tsv lazily on first flow for
    # the host, so a brand-new TCP connection is enough.
    sleep 0.2 2>/dev/null || sleep 1

    # -r 0-N-1 asks for bytes 0..(N-1) which is a 100 KB range request;
    # most servers honour this (CF/Google both do). Some servers return
    # the full body ignoring the range — we truncate via -o /dev/null
    # and --max-filesize as a safety cap.
    out=$(curl -sk --compressed \
               --max-time "$PROBE_TIMEOUT" \
               --connect-timeout 4 \
               -r "0-$((PROBE_RANGE_BYTES - 1))" \
               --max-filesize $((PROBE_RANGE_BYTES * 2)) \
               -o /dev/null \
               -w '%{http_code} %{size_download} %{time_total}' \
               "https://$host/" 2>/dev/null) || out="000 0 0"

    http=$(printf '%s' "$out" | awk '{print $1}')
    bytes=$(printf '%s' "$out" | awk '{print $2}')
    secs=$(printf '%s' "$out" | awk '{print $3}')

    kbps="0"
    ok="0"
    case "$http" in
        2??|3??) ok="1" ;;
    esac

    if [ "$ok" = "1" ] && [ "${bytes:-0}" -gt 0 ]; then
        # bytes/sec → kbps via awk (busybox lacks floating math)
        kbps=$(awk -v b="$bytes" -v t="$secs" 'BEGIN {
            if (t+0 <= 0) { print 0; exit }
            printf "%d", (b * 8 / t / 1000)
        }')
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$s" "$ok" "$http" "$bytes" "$secs" "$kbps" >> "$results_file"
    printf '  strategy=%-3s %s %-4s %6sB %ss  %skbps\n' \
        "$s" "$ok" "$http" "$bytes" "$secs" "$kbps"
}

# -----------------------------------------------------------------------------
# Main probe loop
# -----------------------------------------------------------------------------

echo "z2k-probe: host=$host profile=$profile strategies=$strategy_count"
echo "z2k-probe: backing up state.tsv → $state_backup"
echo "z2k-probe: iterating strategies (takes ~$((strategy_count * (PROBE_TIMEOUT + 1)))s worst case)"
echo
echo "  strategy    ok http  bytes      time    throughput"
echo "  --------    -- ----  -------    ------  ----------"

for s in $strategies; do
    probe_one "$s"
done

# -----------------------------------------------------------------------------
# Ranking
# -----------------------------------------------------------------------------

echo
echo "z2k-probe: top $PROBE_TOP_N strategies by measured throughput"
echo "  rank strategy  kbps   http   bytes     seconds"
echo "  ---- --------  -----  ----   -------   -------"

# Sort by kbps descending, keep only successful (ok=1) rows, head top N
awk -F'\t' '$2 == "1" && $6 > 0' "$results_file" \
    | sort -t'	' -k6 -n -r \
    | head -n "$PROBE_TOP_N" \
    | awk -F'\t' '{ printf "  %4d %8s  %5s  %-4s   %7s   %s\n", NR, $1, $6, $3, $4, $5 }'

# -----------------------------------------------------------------------------
# Apply best strategy if requested
# -----------------------------------------------------------------------------

if [ "$apply_mode" = "1" ]; then
    best=$(awk -F'\t' '$2 == "1" && $6 > 0' "$results_file" \
           | sort -t'	' -k6 -n -r | head -1 | cut -f1)
    if [ -n "$best" ]; then
        pin_strategy "$best"
        touch "$work_dir/applied.flag"
        echo
        echo "z2k-probe: --apply: pinned strategy=$best for $host in $STATE_TSV"
    else
        echo
        echo "z2k-probe: --apply: no working strategy found, state.tsv left unchanged" >&2
    fi
fi

exit 0
