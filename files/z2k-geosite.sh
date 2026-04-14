#!/bin/sh
# z2k-geosite.sh — fetch v2fly domain-list-community categories and
# convert them to nfqws2 plain-text hostlist format.
#
# Why: the extra_strats/TCP/<cat>/List.txt files are manually curated
# (e.g. TCP/RKN/List.txt is 125k lines of boilerplate). v2fly/domain-list-
# community maintains the same kind of data as daily-updated community
# input files. This script pulls those files, expands `include:` chains,
# strips `regexp:` / `keyword:` lines nfqws2 can't handle, drops `@attr`
# tags, and writes the result to /opt/zapret2/files/lists/extra_strats/GEO/
# as a staging ground. Phase 2 does NOT overwrite the existing production
# lists — that's an opt-in Phase 3 step.
#
# Usage:
#   z2k-geosite.sh fetch            fetch all default categories, write
#                                   staging files
#   z2k-geosite.sh fetch <cat> ...  fetch specific categories
#   z2k-geosite.sh list             print known default categories
#   z2k-geosite.sh show <cat>       fetch+parse one category, print to
#                                   stdout without writing
#   z2k-geosite.sh status           show which staging files exist and
#                                   line counts
#   z2k-geosite.sh --help
#
# Exit codes:
#   0   — success
#   1   — fatal (missing curl, unwritable dir, etc.)
#   2   — partial: some categories failed but others succeeded

set -u

BASE_URL="${GEOSITE_BASE_URL:-https://raw.githubusercontent.com/v2fly/domain-list-community/master/data}"
ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
STAGING_DIR="${ZAPRET2_DIR}/files/lists/extra_strats/GEO"
TMP_DIR="/tmp/z2k-geosite.$$"

# Known-to-z2k default categories. Deliberately small set to validate the
# pipeline. Add more via config or CLI args as needed.
DEFAULT_CATEGORIES="telegram discord cloudflare speedtest"

# Max recursion depth for include: chains (defensive against cycles)
MAX_DEPTH=10

cleanup() {
    [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

die() {
    echo "z2k-geosite: $1" >&2
    exit 1
}

log() {
    echo "[geosite] $1" >&2
}

ensure_deps() {
    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v awk  >/dev/null 2>&1 || die "awk not found"
    command -v sort >/dev/null 2>&1 || die "sort not found"
}

# Fetch a single category file into a specific local path.
# Returns 0 on success, non-zero otherwise.
fetch_raw() {
    local cat="$1"
    local dest="$2"
    curl -fsSL --connect-timeout 10 --max-time 60 \
        "${BASE_URL}/${cat}" -o "$dest"
}

# Expand `include:` directives recursively into $output_file.
# Arguments: source_file  output_file  visited_file  depth
# Writes only non-include lines to output; follows include: to fetch
# sub-categories if not yet visited.
expand_one() {
    local input="$1"
    local output="$2"
    local visited="$3"
    local depth="${4:-0}"

    if [ "$depth" -gt "$MAX_DEPTH" ]; then
        log "max depth reached at $input — skipping deeper includes"
        return
    fi

    # Read line by line
    while IFS= read -r line; do
        # Strip CRLF if any
        line="${line%
}"
        case "$line" in
            '' | '#'*)
                # skip empty and comment lines
                continue
                ;;
            'include:'*)
                # Extract category name: "include:X" or "include:X @attr"
                local sub
                sub=$(printf '%s' "$line" | sed 's/^include://' | awk '{print $1}')
                [ -z "$sub" ] && continue
                # Cycle check
                if grep -qxF "$sub" "$visited" 2>/dev/null; then
                    continue
                fi
                printf '%s\n' "$sub" >> "$visited"
                # Fetch sub-category if not already cached
                local sub_file="$TMP_DIR/raw_$sub"
                if [ ! -f "$sub_file" ]; then
                    if ! fetch_raw "$sub" "$sub_file"; then
                        log "  include:$sub fetch failed, skipping"
                        continue
                    fi
                fi
                expand_one "$sub_file" "$output" "$visited" "$((depth + 1))"
                ;;
            *)
                # Plain domain line (maybe with regexp:/keyword:/full: prefix
                # and optional @attr tags). Write to output as-is, filtering
                # happens in a later pass.
                printf '%s\n' "$line" >> "$output"
                ;;
        esac
    done < "$input"
}

# Take an expanded (includes-resolved) file and filter down to plain
# nfqws2-compatible hostlist (one domain per line, sorted + unique).
# Rules:
#   - drop lines starting with `regexp:` or `keyword:` — nfqws2 hostlist
#     doesn't support either
#   - strip leading `full:` — treat full-match the same as subdomain-match
#     (nfqws2 hostlist does suffix matching, which covers both)
#   - strip trailing `@attr` tags (e.g. `google.com @cn`)
#   - drop comments and empty lines
#   - collapse multiple whitespace, take only the first field
#   - sort + dedup
filter_to_hostlist() {
    local input="$1"
    local output="$2"
    grep -vE '^(#|[[:space:]]*$|regexp:|keyword:)' "$input" \
        | sed 's|^full:||' \
        | sed 's|[[:space:]]*@[a-zA-Z0-9_.-]\+||g' \
        | awk '{ if (NF > 0) print $1 }' \
        | sort -u > "$output"
}

# Build a single category staging file.
build_category() {
    local cat="$1"

    local raw="$TMP_DIR/raw_$cat"
    local expanded="$TMP_DIR/exp_$cat"
    local visited="$TMP_DIR/visited_$cat"
    : > "$expanded"
    : > "$visited"

    if ! fetch_raw "$cat" "$raw"; then
        log "fetch failed: $cat"
        return 1
    fi
    # Seed visited with the root to prevent self-include loops
    printf '%s\n' "$cat" > "$visited"
    expand_one "$raw" "$expanded" "$visited" 0

    # Target directory under the staging tree
    mkdir -p "$STAGING_DIR/$cat"
    local target="$STAGING_DIR/$cat/List.txt"
    filter_to_hostlist "$expanded" "$target"

    local lines
    lines=$(wc -l < "$target" 2>/dev/null | tr -d ' ')
    log "$cat — $lines domains → $target"
    return 0
}

cmd_fetch() {
    ensure_deps
    mkdir -p "$STAGING_DIR" "$TMP_DIR" || die "cannot create $STAGING_DIR or $TMP_DIR"

    local cats="$*"
    [ -z "$cats" ] && cats="$DEFAULT_CATEGORIES"

    local total=0
    local ok=0
    local failed=""
    for c in $cats; do
        total=$((total + 1))
        if build_category "$c"; then
            ok=$((ok + 1))
        else
            failed="$failed $c"
        fi
    done

    log "fetched $ok/$total category/categories"
    if [ -n "$failed" ]; then
        log "failed:$failed"
        return 2
    fi
    return 0
}

cmd_list() {
    echo "Default categories:"
    for c in $DEFAULT_CATEGORIES; do
        echo "  - $c"
    done
    echo
    echo "Staging directory: $STAGING_DIR"
    echo "Base URL:          $BASE_URL"
}

cmd_show() {
    local cat="${1:-}"
    [ -z "$cat" ] && die "usage: z2k-geosite.sh show <category>"
    ensure_deps
    mkdir -p "$TMP_DIR" || die "cannot create $TMP_DIR"

    local raw="$TMP_DIR/raw_$cat"
    local expanded="$TMP_DIR/exp_$cat"
    local visited="$TMP_DIR/visited_$cat"
    : > "$expanded"
    : > "$visited"

    if ! fetch_raw "$cat" "$raw"; then
        die "fetch failed: $cat"
    fi
    printf '%s\n' "$cat" > "$visited"
    expand_one "$raw" "$expanded" "$visited" 0

    local out="$TMP_DIR/out_$cat"
    filter_to_hostlist "$expanded" "$out"
    cat "$out"
}

cmd_status() {
    if [ ! -d "$STAGING_DIR" ]; then
        echo "(staging dir $STAGING_DIR does not exist — run: z2k-geosite.sh fetch)"
        return
    fi
    local found=0
    for f in "$STAGING_DIR"/*/List.txt; do
        [ -f "$f" ] || continue
        found=$((found + 1))
        local cat lines size
        cat=$(basename "$(dirname "$f")")
        lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
        printf '%-24s %8s lines  %10s bytes  %s\n' "$cat" "$lines" "$size" "$f"
    done
    [ "$found" = "0" ] && echo "(no staging lists yet — run: z2k-geosite.sh fetch)"
}

usage() {
    sed -n '/^# Usage:/,/^# Exit/ { /^# Exit/d; s/^# \?//; p; }' "$0"
}

MODE="${1:-}"
shift 2>/dev/null || true

case "$MODE" in
    fetch)  cmd_fetch "$@" ;;
    list)   cmd_list ;;
    show)   cmd_show "$@" ;;
    status) cmd_status ;;
    ''|-h|--help)
        usage
        exit 0
        ;;
    *)
        echo "z2k-geosite: unknown command: $MODE" >&2
        usage
        exit 1
        ;;
esac
