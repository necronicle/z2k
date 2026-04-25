#!/bin/sh
# z2k-classify-inject.sh — seamless strategy injection helper.
#
# The C-level z2k-classify generator calls this script. Handler slot
# id (e.g. strategy=48 in rkn_tcp) is emitted by config_official.sh
# into /opt/zapret2/dynamic-slots.conf at install/regen time. We
# look it up and pin (profile_key, host) → slot in state.tsv.
#
# Operations:
#
#   apply <profile_key> <domain>
#       Read $Z2K_STRATEGY (e.g.
#         --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=6
#       ).  Decompose into family + key=value params, write to
#       /tmp/z2k-classify-dynparams (atomic temp+rename) plus
#       target_host=<domain>.  Pin (profile_key, domain) → slot in
#       state.tsv. NO nfqws2 restart — handler reads dynparams
#       per-packet (1-sec TTL cache).
#
#   revert <profile_key> <domain>
#       Remove the state.tsv pin. Truncate dynparams file. NO restart.
#
#   persist <profile_key> <domain>
#       Read $Z2K_STRATEGY, append it to the matching autocircular
#       block in strats_new2.txt as the next available strategy=N
#       (sequential, before our handler slot). Update state.tsv pin
#       to that new id, clear dynparams. Regen config + restart
#       S99zapret2 ONCE so the new permanent strategy joins the
#       rotator. Returns N (capped at 254 to fit exit code).
#
# Cost:
#   apply / revert  : ~1 sec (file write + cache TTL settle).
#                     ZERO interruption to other LAN users' bypass.
#   persist         : ~5 sec ONE-TIME at the end of a winning run.

set -eu

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
STRATS_FILE="${ZAPRET2_DIR}/strats_new2.txt"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
DYNPARAMS_FILE="/tmp/z2k-classify-dynparams"
SLOTS_FILE="${ZAPRET2_DIR}/dynamic-slots.conf"
STATE_DIR="/opt/zapret2/extra_strats/cache/autocircular"
STATE_FILE="$STATE_DIR/state.tsv"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

profile_to_block_prefix() {
    case "$1" in
        rkn_tcp)        echo "manual_autocircular_rkn" ;;
        google_tls|youtube_tcp)  echo "manual_autocircular_yt" ;;
        youtube_gv_tcp) echo "manual_autocircular_gv" ;;
        cdn_tls)        echo "manual_autocircular_rkn" ;;
        *)              echo "" ;;
    esac
}

# Resolve handler slot id from /opt/zapret2/dynamic-slots.conf.
# That file is regenerated every time config_official runs, so the
# slot id always matches what nfqws2 currently has loaded.
slot_for_profile() {
    profile_key=$1
    [ -f "$SLOTS_FILE" ] || return 1
    awk -F= -v k="$profile_key" '$1 == k { print $2; exit }' "$SLOTS_FILE"
}

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
# the dynparams file. Includes target_host=<domain> so the Lua handler
# only fires on the connections we pinned.
write_dynparams() {
    target_host=$1
    s="$Z2K_STRATEGY"

    s_body=$(printf '%s' "$s" | sed 's/^--lua-desync=//')
    action=$(printf '%s' "$s_body" | cut -d: -f1)
    family=$(action_to_family "$action")
    if [ -z "$family" ]; then
        echo "z2k-classify-inject: unknown action '$action' in Z2K_STRATEGY" >&2
        return 1
    fi
    rest=$(printf '%s' "$s_body" | cut -d: -f2-)

    tmp="${DYNPARAMS_FILE}.tmp.$$"
    {
        printf '# z2k-classify dynparams (auto-generated)\n'
        printf 'family=%s\n' "$family"
        printf 'target_host=%s\n' "$target_host"
        IFS=:
        for kv in $rest; do
            [ -z "$kv" ] && continue
            case "$kv" in
                strategy=*) ;;
                *=*) printf '%s\n' "$kv" ;;
                *)   printf '%s=\n' "$kv" ;;
            esac
        done
        unset IFS
    } > "$tmp"
    mv -f "$tmp" "$DYNPARAMS_FILE"
    chmod 0644 "$DYNPARAMS_FILE" 2>/dev/null || true
}

clear_dynparams() {
    : > "$DYNPARAMS_FILE" 2>/dev/null || true
}

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

strip_strategy_tag() {
    printf '%s' "$1" | sed 's/:strategy=[0-9]*//g'
}

# Find max permanent strategy=N (excluding our handler slot) within a
# block. Used by persist op to pick the next free slot.
max_permanent_strategy_in_block() {
    block_prefix=$1
    handler_slot=$2
    awk -v p="$block_prefix" -v hs="$handler_slot" '
        $0 ~ "^"p" " {
            n = 0
            line = $0
            while (match(line, /:strategy=[0-9]+/)) {
                v = substr(line, RSTART+10, RLENGTH-10) + 0
                if (v > n && v != hs) n = v
                line = substr(line, RSTART+RLENGTH)
            }
            print n
            exit
        }
    ' "$STRATS_FILE"
}

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

    slot=$(slot_for_profile "$profile_key")
    if [ -z "$slot" ]; then
        echo "z2k-classify-inject: no handler slot for profile=$profile_key (regen config first)" >&2
        return 1
    fi

    write_dynparams "$domain" || return 1
    state_pin "$profile_key" "$domain" "$slot"
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

    handler_slot=$(slot_for_profile "$profile_key")
    [ -n "$handler_slot" ] || handler_slot=0

    strategy=$(strip_strategy_tag "$Z2K_STRATEGY")

    cur_max=$(max_permanent_strategy_in_block "$block_prefix" "$handler_slot")
    [ -z "$cur_max" ] && cur_max=0
    next_id=$((cur_max + 1))
    if [ "$next_id" -gt 199 ]; then
        echo "no free permanent strategy slot below 200 for $block_prefix" >&2
        return 1
    fi

    new_with_id="${strategy}:strategy=${next_id}"
    append_to_block "$block_prefix" "$new_with_id" || return 1

    state_pin "$profile_key" "$domain" "$next_id"
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
USAGE
        exit 2
        ;;
esac
