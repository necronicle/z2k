#!/bin/sh
# z2k-classify-inject.sh — seamless strategy injection helper.
#
# Backed by a content-addressed strategy DB instead of strats_new2.txt
# regen+restart cycles. Each persisted winner becomes a row in the
# strategies catalog (deduped by family+params); each domain points
# at one strategy_id in the domains map. The Lua handler at slot=48
# reads both files (5-sec TTL cache) and applies the right strategy
# per host with no service interruption.
#
# Operations:
#
#   apply <profile_key> <domain>
#       Read $Z2K_STRATEGY (e.g.
#         --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=6
#       ).  Decompose into family + key=value params, write to
#       /tmp/z2k-classify-dynparams (atomic temp+rename) plus
#       target_host=<domain>. Pin (profile_key, domain) → handler
#       slot in state.tsv. NO restart, NO DB write.
#
#   revert <profile_key> <domain>
#       Truncate dynparams. Unpin state.tsv ONLY if domain is not in
#       the persistent DB (otherwise leave the pin in place so the
#       handler keeps applying its persisted strategy).
#
#   persist <profile_key> <domain>
#       Read $Z2K_STRATEGY. Lookup matching {family, params} in
#       strategies.tsv → reuse id if dup, else assign next sequential
#       id and append. Update domains.tsv with (host, id). Pin
#       state.tsv to the handler slot. Clear dynparams. NO restart.
#       Returns the assigned strategy_id (capped at 254).

set -eu

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
LISTS_DIR="${ZAPRET2_DIR}/lists"
DYNPARAMS_FILE="/tmp/z2k-classify-dynparams"
SLOTS_FILE="${ZAPRET2_DIR}/dynamic-slots.conf"
STATE_DIR="/opt/zapret2/extra_strats/cache/autocircular"
STATE_FILE="$STATE_DIR/state.tsv"
DB_STRATEGIES="${LISTS_DIR}/z2k-classify-strategies.tsv"
DB_DOMAINS="${LISTS_DIR}/z2k-classify-domains.tsv"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Resolve handler slot id from /opt/zapret2/dynamic-slots.conf.
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

# Normalize Z2K_STRATEGY into (family, params). Strips :strategy=N if
# the generator emitted one. Used by both apply (transient dynparams)
# and persist (DB row).
parse_strategy() {
    s_body=$(printf '%s' "$Z2K_STRATEGY" | sed 's/^--lua-desync=//')
    family_action=$(printf '%s' "$s_body" | cut -d: -f1)
    family=$(action_to_family "$family_action")
    if [ -z "$family" ]; then
        echo "z2k-classify-inject: unknown action '$family_action'" >&2
        return 1
    fi
    rest=$(printf '%s' "$s_body" | cut -d: -f2-)
    # Strip any :strategy=N (the slot id is owned by the helper, not
    # the generator's recipe output).
    params=$(printf '%s' "$rest" | sed 's/:strategy=[0-9]*//g')
    PARSED_FAMILY=$family
    PARSED_PARAMS=$params
}

# /tmp dynparams for transient generator runs.
write_dynparams() {
    target_host=$1
    parse_strategy || return 1

    tmp="${DYNPARAMS_FILE}.tmp.$$"
    {
        printf '# z2k-classify dynparams (transient — generator test)\n'
        printf 'family=%s\n' "$PARSED_FAMILY"
        printf 'target_host=%s\n' "$target_host"
        # Split params on ':' and emit one key=value per line for the
        # Lua loader's KEY=VAL grammar.
        IFS=:
        for kv in $PARSED_PARAMS; do
            [ -z "$kv" ] && continue
            case "$kv" in
                *=*) printf '%s\n' "$kv" ;;
                *)   printf '%s=\n' "$kv" ;;  # flag-only (e.g. badsum)
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

# state.tsv pin (atomic).
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

# -----------------------------------------------------------------------------
# DB ops
# -----------------------------------------------------------------------------

ensure_db_files() {
    [ -d "$LISTS_DIR" ] || mkdir -p "$LISTS_DIR" 2>/dev/null
    if [ ! -f "$DB_STRATEGIES" ]; then
        {
            printf '# z2k-classify strategy catalog (auto-managed)\n'
            printf '# id\tfamily\tparams\n'
        } > "$DB_STRATEGIES" 2>/dev/null || true
    fi
    if [ ! -f "$DB_DOMAINS" ]; then
        {
            printf '# z2k-classify domain → strategy mapping (auto-managed)\n'
            printf '# host\tstrategy_id\n'
        } > "$DB_DOMAINS" 2>/dev/null || true
    fi
}

# Find existing strategy id by exact (family, params) match. Empty if
# no row matches.
find_strategy_id() {
    family=$1
    params=$2
    [ -s "$DB_STRATEGIES" ] || { echo ""; return 0; }
    awk -v F="$family" -v P="$params" -F '\t' '
        /^#/ { next }
        $2 == F && $3 == P { print $1; exit }
    ' "$DB_STRATEGIES"
}

# Append a new strategy row with id = max(existing) + 1. Returns id.
append_strategy() {
    family=$1
    params=$2
    next_id=$(awk -F '\t' '
        /^#/ { next }
        $1 ~ /^[0-9]+$/ { if ($1 + 0 > max) max = $1 + 0 }
        END { print (max ? max : 0) + 1 }
    ' "$DB_STRATEGIES")
    printf '%s\t%s\t%s\n' "$next_id" "$family" "$params" >> "$DB_STRATEGIES"
    echo "$next_id"
}

# Remove old row for host and append new (host → id) entry.
upsert_domain() {
    host=$1
    strategy_id=$2
    tmp="${DB_DOMAINS}.tmp.$$"
    if [ -s "$DB_DOMAINS" ]; then
        awk -v h="$host" -F '\t' '
            /^#/ { print; next }
            $1 == h { next }
            { print }
        ' "$DB_DOMAINS" > "$tmp"
    else
        {
            printf '# z2k-classify domain → strategy mapping (auto-managed)\n'
            printf '# host\tstrategy_id\n'
        } > "$tmp"
    fi
    printf '%s\t%s\n' "$host" "$strategy_id" >> "$tmp"
    mv -f "$tmp" "$DB_DOMAINS"
}

# Returns 0 if domain has an entry in the DB, 1 otherwise.
domain_in_db() {
    host=$1
    [ -s "$DB_DOMAINS" ] || return 1
    awk -v h="$host" -F '\t' '
        /^#/ { next }
        $1 == h { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$DB_DOMAINS"
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
        echo "z2k-classify-inject: no handler slot for profile=$profile_key" >&2
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
    clear_dynparams

    # If the domain has a persisted DB entry, the pin must STAY so the
    # handler keeps serving its persistent strategy. Only unpin
    # transient (non-persisted) hosts.
    if domain_in_db "$domain"; then
        return 0
    fi
    state_unpin "$profile_key" "$domain"
    return 0
}

op_persist() {
    profile_key=$1
    domain=$2
    [ -n "${Z2K_STRATEGY:-}" ] || return 1

    slot=$(slot_for_profile "$profile_key")
    if [ -z "$slot" ]; then
        echo "z2k-classify-inject: no handler slot for profile=$profile_key" >&2
        return 1
    fi

    parse_strategy || return 1
    ensure_db_files

    strategy_id=$(find_strategy_id "$PARSED_FAMILY" "$PARSED_PARAMS")
    if [ -z "$strategy_id" ]; then
        strategy_id=$(append_strategy "$PARSED_FAMILY" "$PARSED_PARAMS")
    fi

    upsert_domain "$domain" "$strategy_id"

    # Pin permanently. Handler reads DB and applies the right strategy.
    state_pin "$profile_key" "$domain" "$slot"
    clear_dynparams

    [ "$strategy_id" -gt 254 ] && strategy_id=254
    return "$strategy_id"
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
