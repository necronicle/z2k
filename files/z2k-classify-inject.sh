#!/bin/sh
# z2k-classify-inject.sh — strategy injection helper for z2k-classify.
#
# Three operations:
#   apply <profile_key> <domain>
#       Read $Z2K_STRATEGY (full --lua-desync=... line, no strategy=N).
#       Append it to the autocircular block matching profile_key in
#       /opt/zapret2/strats_new2.txt as `:strategy=200`. Regen config.
#       Restart S99zapret2. Exit 0 on success.
#
#   revert <profile_key> <domain>
#       Remove the `:strategy=200` instance from strats_new2.txt for
#       the given profile_key block. Regen + restart. Exit 0.
#
#   persist <profile_key> <domain>
#       Read $Z2K_STRATEGY. Append to autocircular block as the next
#       available strategy=N (max existing + 1). Update state.tsv pin
#       to that N. Regen + restart. Exit code = N (1..254).
#
# strats_new2.txt format reminder:
#   manual_autocircular_rkn ipv4 example.com : nfqws2 ... --new
#   manual_autocircular_yt  ipv4 example.com : nfqws2 ... --new
#   manual_autocircular_gv  ipv4 example.com : nfqws2 ... --new
#
# Mapping profile_key → block prefix:
#   rkn_tcp     → manual_autocircular_rkn
#   google_tls  → manual_autocircular_yt    (and gv via merge)
#   cdn_tls     → no block in strats_new2 — strategies are inline in
#                 lib/config_official.sh. Inject path different (TODO).

set -eu

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
STRATS_FILE="${ZAPRET2_DIR}/strats_new2.txt"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
DYNAMIC_SLOT=200

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

profile_to_block_prefix() {
    case "$1" in
        rkn_tcp)    echo "manual_autocircular_rkn" ;;
        google_tls) echo "manual_autocircular_yt" ;;
        # cdn_tls strategies live in lib/config_official.sh inline,
        # not in strats_new2.txt. For now we proxy via rkn_tcp block
        # so the strategy goes into a different rotator but at least
        # gets active (pin-based probe works regardless of block).
        cdn_tls)    echo "manual_autocircular_rkn" ;;
        *)          echo "" ;;
    esac
}

# Find max strategy=N already in the autocircular block.
max_strategy_in_block() {
    block_prefix=$1
    awk -v p="$block_prefix" '
        $0 ~ "^"p" " {
            n = 0
            while (match($0, /:strategy=[0-9]+/)) {
                v = substr($0, RSTART+10, RLENGTH-10) + 0
                if (v > n && v < 200) n = v  # ignore reserved DYNAMIC_SLOT 200+
                $0 = substr($0, RSTART+RLENGTH)
            }
            print n
            exit
        }
    ' "$STRATS_FILE"
}

# Strip any `:strategy=N` from the strategy string (caller may have
# included one; we set our own).
strip_strategy_tag() {
    printf '%s' "$1" | sed 's/:strategy=[0-9]*//g'
}

# Append a strategy line to the autocircular block. Atomic write.
append_to_block() {
    block_prefix=$1
    new_strategy_with_id=$2
    tmp="${STRATS_FILE}.tmp.$$"
    awk -v p="$block_prefix" -v s="$new_strategy_with_id" '
        $0 ~ "^"p" " {
            print $0 " " s
            next
        }
        { print }
    ' "$STRATS_FILE" > "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$STRATS_FILE"
    return 0
}

# Drop any strategy with the given strategy=N from the autocircular
# block. Used for revert (N=DYNAMIC_SLOT) and clean-up.
drop_strategy_from_block() {
    block_prefix=$1
    drop_id=$2
    tmp="${STRATS_FILE}.tmp.$$"
    awk -v p="$block_prefix" -v sid="$drop_id" '
        $0 ~ "^"p" " {
            # Tokenize on space, drop tokens that contain :strategy=<sid>
            # (one --lua-desync= token == one strategy instance).
            n = split($0, tokens, " ")
            out = ""
            i = 1
            while (i <= n) {
                t = tokens[i]
                # Group token with the next ones that are continuation
                # of the same --lua-desync= until we hit another --
                while (i + 1 <= n && substr(tokens[i+1], 1, 2) != "--") {
                    t = t " " tokens[++i]
                }
                # Check if this --lua-desync= group has :strategy=sid
                pat = ":strategy=" sid "$"
                pat2 = ":strategy=" sid ":"
                if (t ~ pat || t ~ pat2) {
                    # skip this token group
                } else {
                    out = (out == "" ? t : out " " t)
                }
                i++
            }
            print out
            next
        }
        { print }
    ' "$STRATS_FILE" > "$tmp"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$STRATS_FILE"
    return 0
}

# Regen config + restart nfqws2. ~3-5 sec on Keenetic.
regen_and_restart() {
    sh -c '
        export ZAPRET2_DIR=/opt/zapret2
        export LISTS_DIR=/opt/zapret2/lists
        export EXTRA_STRATS_DIR=/opt/zapret2/extra_strats
        for m in utils system_init install strategies config config_official; do
            . /tmp/z2k/lib/${m}.sh 2>/dev/null
        done
        create_official_config /opt/zapret2/config >/dev/null 2>&1
    '
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
        # Brief settle window — circular needs a fresh flow to pick
        # up state.tsv pin.
        sleep 2
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Operations
# -----------------------------------------------------------------------------

op_apply() {
    profile_key=$1
    domain=$2
    block_prefix=$(profile_to_block_prefix "$profile_key")
    [ -n "$block_prefix" ] || { echo "unknown profile_key: $profile_key" >&2; return 1; }
    [ -n "${Z2K_STRATEGY:-}" ] || { echo "Z2K_STRATEGY env var not set" >&2; return 1; }

    strategy=$(strip_strategy_tag "$Z2K_STRATEGY")
    new_with_id="${strategy}:strategy=${DYNAMIC_SLOT}"

    # Always remove any leftover dynamic-slot strategy first to keep
    # idempotence when called repeatedly.
    drop_strategy_from_block "$block_prefix" "$DYNAMIC_SLOT" >/dev/null 2>&1 || true

    append_to_block "$block_prefix" "$new_with_id" || return 1
    regen_and_restart
    return 0
}

op_revert() {
    profile_key=$1
    domain=$2
    block_prefix=$(profile_to_block_prefix "$profile_key")
    [ -n "$block_prefix" ] || return 1

    drop_strategy_from_block "$block_prefix" "$DYNAMIC_SLOT" || return 1
    regen_and_restart
    return 0
}

op_persist() {
    profile_key=$1
    domain=$2
    block_prefix=$(profile_to_block_prefix "$profile_key")
    [ -n "$block_prefix" ] || return 1
    [ -n "${Z2K_STRATEGY:-}" ] || return 1

    strategy=$(strip_strategy_tag "$Z2K_STRATEGY")

    # Remove the dynamic-slot version (we're promoting it).
    drop_strategy_from_block "$block_prefix" "$DYNAMIC_SLOT" >/dev/null 2>&1 || true

    # Find next available strategy=N.
    cur_max=$(max_strategy_in_block "$block_prefix")
    [ -z "$cur_max" ] && cur_max=0
    next_id=$((cur_max + 1))
    if [ "$next_id" -gt 199 ]; then
        echo "no free strategy slot below 200 for $block_prefix" >&2
        return 1
    fi

    new_with_id="${strategy}:strategy=${next_id}"
    append_to_block "$block_prefix" "$new_with_id" || return 1

    # Update state.tsv pin to the new permanent ID.
    state_dir="/opt/zapret2/extra_strats/cache/autocircular"
    state_file="$state_dir/state.tsv"
    if [ -d "$state_dir" ] && [ -f "$state_file" ]; then
        ts=$(date +%s)
        tmp="$state_file.tmp.$$"
        awk -v p="$profile_key" -v h="$domain" -v s="$next_id" -v ts="$ts" '
            BEGIN { printed = 0 }
            /^#/ { print; next }
            $1 == p && $2 == h {
                printf "%s\t%s\t%s\t%s\n", p, h, s, ts
                printed = 1
                next
            }
            { print }
            END { if (!printed) printf "%s\t%s\t%s\t%s\n", p, h, s, ts }
        ' "$state_file" > "$tmp" && mv -f "$tmp" "$state_file"
    fi

    regen_and_restart

    # Exit code carries the strategy ID (capped at 254).
    [ "$next_id" -gt 254 ] && next_id=254
    return "$next_id"
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

case "${1:-}" in
    apply)   op_apply "$2" "$3" ;;
    revert)  op_revert "$2" "$3" ;;
    persist) op_persist "$2" "$3" ;;
    *)
        cat <<USAGE >&2
Usage: $0 apply|revert|persist <profile_key> <domain>
  apply   — env Z2K_STRATEGY=<--lua-desync=...> ; injects as strategy=$DYNAMIC_SLOT
  revert  — removes the strategy=$DYNAMIC_SLOT entry
  persist — env Z2K_STRATEGY=<...> ; appends as next available strategy=N,
            updates state.tsv pin, returns N as exit code
USAGE
        exit 2
        ;;
esac
