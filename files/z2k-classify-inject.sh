#!/bin/sh
# z2k-classify-inject.sh — seamless strategy injection helper.
#
# Operations:
#   apply <profile_key> <domain>
#       Read $Z2K_STRATEGY (e.g.
#         --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=6
#       ). Decompose into family + key=value params. Write to
#       /tmp/z2k-classify-dynparams. Pin (profile_key, domain) → 200
#       in state.tsv so the next flow uses the dynamic slot. NO
#       restart of nfqws2 — handler reads dynparams per-packet (1-sec
#       TTL cache).
#
#   revert <profile_key> <domain>
#       Remove the state.tsv pin. Truncate dynparams file (handler
#       sees empty params and becomes a silent no-op until next apply).
#       NO restart.
#
#   persist <profile_key> <domain>
#       Read $Z2K_STRATEGY. Append it to the matching autocircular
#       block in strats_new2.txt as the next available strategy=N
#       (max existing under 200 + 1). Update state.tsv pin to that
#       new ID. Regen config + restart S99zapret2 ONCE so the new
#       permanent strategy gets loaded into nfqws2's strategy table.
#       Returns N as exit code.
#
# Performance vs old restart-cycle:
#   apply/revert: ~0.5 sec (just file writes + sleep for autocircular
#     to pick up state.tsv on next flow). NO interruption to other users.
#   persist: ~5 sec ONE-TIME at end of probe session.

set -eu

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
STRATS_FILE="${ZAPRET2_DIR}/strats_new2.txt"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
DYNPARAMS_FILE="/tmp/z2k-classify-dynparams"
DYNAMIC_SLOT=200
STATE_DIR="/opt/zapret2/extra_strats/cache/autocircular"
STATE_FILE="$STATE_DIR/state.tsv"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

profile_to_block_prefix() {
    case "$1" in
        rkn_tcp)    echo "manual_autocircular_rkn" ;;
        google_tls) echo "manual_autocircular_yt" ;;
        cdn_tls)    echo "manual_autocircular_rkn" ;;  # cdn inline; route via rkn block
        *)          echo "" ;;
    esac
}

# Map an action keyword (fake/multisplit/etc.) to the family= value our
# Lua handler expects. Keep in sync with z2k-dynamic-strategy.lua.
action_to_family() {
    case "$1" in
        fake)            echo "fake" ;;
        multisplit)      echo "multisplit" ;;
        hostfakesplit)   echo "hostfakesplit" ;;
        multidisorder)   echo "multidisorder" ;;
        *)               echo "" ;;
    esac
}

# Parse $Z2K_STRATEGY into family + key=value pairs and write them to
# the dynparams file. Format: one key=value per line.
write_dynparams() {
    s="$Z2K_STRATEGY"

    # Strip leading "--lua-desync="
    s_body=$(printf '%s' "$s" | sed 's/^--lua-desync=//')

    # First colon-separated chunk is the action keyword.
    action=$(printf '%s' "$s_body" | cut -d: -f1)
    family=$(action_to_family "$action")
    if [ -z "$family" ]; then
        echo "z2k-classify-inject: unknown action '$action' in Z2K_STRATEGY" >&2
        return 1
    fi

    rest=$(printf '%s' "$s_body" | cut -d: -f2-)

    # Atomic write: write to tmp, rename. Lua handler caches 1 sec so
    # in-flight reads of the old file aren't a problem.
    tmp="${DYNPARAMS_FILE}.tmp.$$"
    {
        printf '# z2k-classify dynparams (auto-generated)\n'
        printf 'family=%s\n' "$family"
        # Split rest on ':' and emit one key=value per line. Some
        # tokens may be flag-only (e.g. badsum). For those we emit
        # "key=" so the handler still sees the key as present.
        IFS=:
        for kv in $rest; do
            [ -z "$kv" ] && continue
            case "$kv" in
                *=*) printf '%s\n' "$kv" ;;
                *)   printf '%s=\n' "$kv" ;;  # flag-only, e.g. badsum
            esac
        done
        unset IFS
    } > "$tmp"
    mv -f "$tmp" "$DYNPARAMS_FILE"
    chmod 0644 "$DYNPARAMS_FILE" 2>/dev/null || true
}

clear_dynparams() {
    # Truncate but keep the file (the handler tolerates empty/missing).
    : > "$DYNPARAMS_FILE" 2>/dev/null || true
}

# state.tsv pin/unpin (atomic copy-modify-rename). Mirrors C state.c
# semantics so it's safe to call from either side.
state_pin() {
    profile_key=$1; domain=$2; strategy_id=$3
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
    ts=$(date +%s 2>/dev/null || echo 0)
    tmp="${STATE_FILE}.tmp.$$"
    {
        if [ -s "$STATE_FILE" ]; then
            awk -v p="$profile_key" -v h="$domain" -F '\t' '
                /^#/ { print; next }
                $1 == p && $2 == h { next }
                { print }
            ' "$STATE_FILE"
        else
            printf '# z2k autocircular state (persisted circular nstrategy)\n'
            printf '# key\thost\tstrategy\tts\n'
        fi
        printf '%s\t%s\t%s\t%s\n' "$profile_key" "$domain" "$strategy_id" "$ts"
    } > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

state_unpin() {
    profile_key=$1; domain=$2
    [ -s "$STATE_FILE" ] || return 0
    tmp="${STATE_FILE}.tmp.$$"
    awk -v p="$profile_key" -v h="$domain" -F '\t' '
        /^#/ { print; next }
        $1 == p && $2 == h { next }
        { print }
    ' "$STATE_FILE" > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# Strip any embedded :strategy=N from a strategy string.
strip_strategy_tag() {
    printf '%s' "$1" | sed 's/:strategy=[0-9]*//g'
}

# Find max strategy=N within a block, ignoring our reserved 200+ slot.
max_strategy_in_block() {
    block_prefix=$1
    awk -v p="$block_prefix" '
        $0 ~ "^"p" " {
            n = 0
            while (match($0, /:strategy=[0-9]+/)) {
                v = substr($0, RSTART+10, RLENGTH-10) + 0
                if (v > n && v < 200) n = v
                $0 = substr($0, RSTART+RLENGTH)
            }
            print n
            exit
        }
    ' "$STRATS_FILE"
}

# Append a strategy line to the autocircular block (atomic).
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
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STRATS_FILE"
}

# Regen + restart — ONLY used by persist op.
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
        sleep 2
    fi
}

# -----------------------------------------------------------------------------
# Operations
# -----------------------------------------------------------------------------

op_apply() {
    profile_key=$1
    domain=$2
    [ -n "${Z2K_STRATEGY:-}" ] || { echo "Z2K_STRATEGY env var not set" >&2; return 1; }

    write_dynparams || return 1
    state_pin "$profile_key" "$domain" "$DYNAMIC_SLOT"
    # Brief settle so the cached_at timer in z2k-dynamic-strategy.lua
    # crosses TTL on the next packet.
    sleep 1
    return 0
}

op_revert() {
    profile_key=$1
    domain=$2
    state_unpin "$profile_key" "$domain"
    clear_dynparams
    return 0
}

op_persist() {
    profile_key=$1
    domain=$2
    [ -n "${Z2K_STRATEGY:-}" ] || return 1

    block_prefix=$(profile_to_block_prefix "$profile_key")
    [ -n "$block_prefix" ] || return 1

    strategy=$(strip_strategy_tag "$Z2K_STRATEGY")

    # Find next available permanent slot.
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
    state_pin "$profile_key" "$domain" "$next_id"

    # Clear the dynparams (no longer needed for this domain).
    clear_dynparams

    regen_and_restart

    [ "$next_id" -gt 254 ] && next_id=254
    return "$next_id"
}

case "${1:-}" in
    apply)   op_apply "$2" "$3" ;;
    revert)  op_revert "$2" "$3" ;;
    persist) op_persist "$2" "$3" ;;
    *)
        cat <<USAGE >&2
Usage: $0 apply|revert|persist <profile_key> <domain>
  apply   — env Z2K_STRATEGY=<--lua-desync=...> ; writes dynparams + pins slot 200
  revert  — clears dynparams + unpins
  persist — promotes Z2K_STRATEGY to next available permanent strategy=N,
            updates pin, regen+restart. Returns N as exit code.
USAGE
        exit 2
        ;;
esac
