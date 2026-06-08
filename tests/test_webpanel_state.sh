#!/bin/sh
# tests/test_webpanel_state.sh - webpanel rotator state mutation (freeze / manual
# select) + pool parsing. Sources webpanel/cgi/actions.sh as a function library
# and drives state_set / state_read against isolated tmp state files.
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected '%s', got '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    case "$3" in
        *"$2"*) TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1" ;;
        *)      TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: '%s' not in output\n" "$1" "$2" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- isolate state files ---
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
ZAPRET2_DIR="$SB/opt/zapret2"; export ZAPRET2_DIR
mkdir -p "$ZAPRET2_DIR"
STATE_FILE="$SB/state.tsv"
STATE_FILE_FALLBACK="$SB/fallback.tsv"

# Source the function library (defines state_set/state_read/pools_read/etc).
. "$SCRIPT_DIR/webpanel/cgi/actions.sh" 2>/dev/null
# Re-pin the file paths AFTER sourcing (actions.sh sets defaults from ZAPRET2_DIR).
STATE_FILE="$SB/state.tsv"
STATE_FILE_FALLBACK="$SB/fallback.tsv"

# helper: field N of the state_read row matching key+host
row_field() {
    state_read | awk -F'\t' -v k="$1" -v h="$2" -v n="$3" '$1==k && $2==h {print $n}'
}

printf "\n--- state_set: manual select (auto) ---\n"
state_set rkn_tcp example.com 2 auto
assert_eq "set auto: strategy persisted"        "2"    "$(row_field rkn_tcp example.com 3)"
assert_eq "set auto: mode=auto persisted"       "auto" "$(row_field rkn_tcp example.com 5)"

printf "\n--- state_set: freeze ---\n"
state_set discord_udp nohost 3 frozen
assert_eq "freeze: strategy persisted"          "3"      "$(row_field discord_udp nohost 3)"
assert_eq "freeze: mode=frozen persisted"       "frozen" "$(row_field discord_udp nohost 5)"

printf "\n--- state_set: upsert replaces (no duplicate row) ---\n"
state_set discord_udp nohost 5 auto
COUNT=$(state_read | awk -F'\t' '$1=="discord_udp" && $2=="nohost"' | wc -l | tr -d ' ')
assert_eq "upsert: exactly one discord row"     "1"    "$COUNT"
assert_eq "upsert: new strategy"                "5"    "$(row_field discord_udp nohost 3)"
assert_eq "upsert: new mode"                    "auto" "$(row_field discord_udp nohost 5)"

printf "\n--- state_set: validation ---\n"
state_set rkn_tcp host 1 bogus  2>/dev/null; assert_eq "reject bad mode"       "1" "$?"
state_set rkn_tcp host abc auto 2>/dev/null; assert_eq "reject non-numeric"    "1" "$?"
state_set rkn_tcp host 0 auto   2>/dev/null; assert_eq "reject strategy 0"     "1" "$?"
state_set "bad key" host 1 auto 2>/dev/null; assert_eq "reject bad key chars"  "1" "$?"
# Host validation uses _chars_ok (tr), which works on busybox/dash/bash alike —
# so these reject portably (the old [!...|-] glob silently accepted everything).
state_set rkn_tcp 'h;rm'   1 auto   2>/dev/null; assert_eq "reject bad host chars"   "1" "$?"
state_set rkn_tcp 'a&b'    1 auto   2>/dev/null; assert_eq "reject host metachar"    "1" "$?"
state_set rkn_tcp 'host|4' 1 frozen 2>/dev/null; assert_eq "accept host|fam suffix"  "0" "$?"

printf "\n--- state_read tolerates a legacy 4-column row ---\n"
printf '# h\n# h2\nyt_tcp\tyoutube.com\t4\t1000\n' > "$STATE_FILE"
: > "$STATE_FILE_FALLBACK"
assert_eq "legacy 4-col read: strategy" "4" "$(row_field yt_tcp youtube.com 3)"

# ------------------------------------------------------------------------------
# pools_read awk logic (replicated — pools_read itself reads /proc/<nfqws2>/cmdline
# which isn't available under test). Counts DISTINCT strategy=N per circular key.
# ------------------------------------------------------------------------------
printf "\n--- pools_read: distinct strategy count per key ---\n"
CMDLINE="nfqws2 --filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:strategy=1 --lua-desync=split:strategy=2 --lua-desync=fake:strategy=2 --new --filter-udp=50000 --lua-desync=circular:fails=3:key=discord_udp:nld=2:hostkey=z2k_nohost_key --lua-desync=fake:strategy=1 --lua-desync=fake:strategy=2 --lua-desync=fake:strategy=3"
POOLS=$(printf '%s' "$CMDLINE" | awk '
{
    n = split($0, toks, " "); ck = ""
    for (i = 1; i <= n; i++) {
        t = toks[i]
        if (t ~ /^--lua-desync=circular:/) { if (match(t, /key=[a-z0-9_]+/)) ck = substr(t, RSTART+4, RLENGTH-4); else ck = "" }
        else if (t == "--new") { ck = "" }
        if (ck != "" && match(t, /:strategy=[0-9]+/)) { s = substr(t, RSTART+10, RLENGTH-10); kk = ck SUBSEP s; if (!(kk in seen)) { seen[kk] = 1; cnt[ck]++ } }
    }
    for (k in cnt) print k "\t" cnt[k]
}')
assert_contains "pools: rkn_tcp=2 (distinct strategies)"     "rkn_tcp	2"     "$POOLS"
assert_contains "pools: discord_udp=3 (distinct strategies)" "discord_udp	3" "$POOLS"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
