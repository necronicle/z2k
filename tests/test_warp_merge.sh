#!/bin/sh
# tests/test_warp_merge.sh — HARD test of the WARP game-list 3-way merge in
# z2k-update-lists.sh::update_warp_game_list. Drives the REAL function (sourced
# with Z2K_UL_SOURCE_ONLY=1) with a stubbed update_list feeding controlled
# "upstream" fixtures, and asserts that user removals AND additions survive
# every refresh, plus tombstone (full-delete) and baseline-loss behaviour.
# POSIX sh (busybox ash) compatible.

TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}
has()    { grep -qxF "$2" "$1" 2>/dev/null && echo 1 || echo 0; }   # line present in file
setof()  { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sort | tr '\n' ',' ; }  # sorted CSV of content lines

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# Source the real script as a library (main() guarded off).
Z2K_UL_SOURCE_ONLY=1
export Z2K_UL_SOURCE_ONLY
# shellcheck disable=SC1091
. "$SCRIPT_DIR/files/z2k-update-lists.sh"

# Re-point globals at the sandbox AFTER sourcing (the script hard-codes
# ZAPRET2_DIR=/opt/zapret2 at load time).
ZAPRET2_DIR="$SB/opt/zapret2"
LOG_FILE="$SB/update-lists.log"
Z2K_WARP_MIN=1              # tiny fixtures; bypass the 100-line sanity floor
WDIR="$ZAPRET2_DIR/lists/warp"
DEST="$WDIR/game-warp-ips.txt"
BASE="$WDIR/.game-warp-ips.base"
TOMB="$WDIR/.game-warp-ips.removed"
mkdir -p "$WDIR"

# Stub update_list: place the current UPSTREAM fixture at $3 (the raw path),
# return UL_RC (2=changed, 0=unchanged, 1=fail) like the real one.
UPSTREAM="$SB/upstream.txt"
UL_RC=2
update_list() { cp -f "$UPSTREAM" "$3" 2>/dev/null; return "${UL_RC:-2}"; }

# Drive one refresh with a given upstream set + rc.
refresh() { printf '%s\n' "$1" > "$UPSTREAM"; UL_RC="${2:-2}"; update_warp_game_list >/dev/null 2>&1; }
# Simulate the webpanel editing dest (user's live edit).
user_set() { printf '%s\n' "$1" > "$DEST"; }

A=10.0.0.1; B=10.0.0.2; C=10.0.0.3; D=10.0.0.4; E=10.0.0.5
X=192.168.5.5; Y=172.16.9.9   # user-added customs

printf "\n--- S1: first run seeds dest+base from upstream ---\n"
refresh "$A
$B
$C" 2
assert_eq "S1 dest = {A,B,C}"  "$A,$B,$C,"  "$(setof "$DEST")"
assert_eq "S1 base = {A,B,C}"  "$A,$B,$C,"  "$(setof "$BASE")"

printf "\n--- S2: user removes B; upstream unchanged (rc=0) → edit untouched ---\n"
user_set "$A
$C"
refresh "$A
$B
$C" 0
assert_eq "S2 dest still {A,C} (fast-path, no merge)" "$A,$C,"     "$(setof "$DEST")"
assert_eq "S2 base still {A,B,C}"                     "$A,$B,$C,"  "$(setof "$BASE")"

printf "\n--- S3: upstream adds D → user's removal of B survives, D flows in ---\n"
refresh "$A
$B
$C
$D" 2
assert_eq "S3 B stays removed" "0" "$(has "$DEST" "$B")"
assert_eq "S3 D added"         "1" "$(has "$DEST" "$D")"
assert_eq "S3 dest = {A,C,D}"  "$A,$C,$D,"       "$(setof "$DEST")"
assert_eq "S3 base = {A,B,C,D}" "$A,$B,$C,$D,"   "$(setof "$BASE")"

printf "\n--- S4/S5: user adds custom X; upstream drops nothing, adds E ---\n"
user_set "$A
$C
$D
$X"
refresh "$A
$C
$D
$E" 2       # upstream: B already gone, +E
assert_eq "S5 user add X survives" "1" "$(has "$DEST" "$X")"
assert_eq "S5 upstream E flows in" "1" "$(has "$DEST" "$E")"
assert_eq "S5 B still absent"      "0" "$(has "$DEST" "$B")"
assert_eq "S5 dest = {A,C,D,E,X}"  "$A,$C,$D,$E,$X," "$(setof "$DEST")"

printf "\n--- S6: idempotent re-run with SAME upstream (rc=2) is stable ---\n"
BEFORE="$(setof "$DEST")"
refresh "$A
$C
$D
$E" 2
assert_eq "S6 dest unchanged on identical upstream" "$BEFORE" "$(setof "$DEST")"

printf "\n--- S7: user-added comment line is preserved across refresh ---\n"
printf '%s\n# my note\n%s\n' "$A" "$C" > "$DEST"    # user keeps A, C, adds a comment
cp -f "$DEST" /dev/null 2>/dev/null
BASEBEF="$(setof "$BASE")"
refresh "$A
$C
$E" 2
assert_eq "S7 comment survives merge" "1" "$(grep -cxF '# my note' "$DEST")"

printf "\n--- S8: full delete (tombstone) → refresh does NOT resurrect ---\n"
# Simulate webpanel warp_list_delete of the managed list.
rm -f "$DEST" "$BASE"; : > "$TOMB"
refresh "$A
$B
$C" 2
assert_eq "S8 list stays deleted"     "0" "$([ -f "$DEST" ] && echo 1 || echo 0)"
assert_eq "S8 tombstone still present" "1" "$([ -f "$TOMB" ] && echo 1 || echo 0)"

printf "\n--- S9: user re-creates the list → tombstone cleared, refresh proceeds ---\n"
rm -f "$TOMB"                 # warp_list_save clears the tombstone
user_set "$Y"                # user re-creates with a custom pick
refresh "$A
$B" 2
assert_eq "S9 tombstone gone"          "0" "$([ -f "$TOMB" ] && echo 1 || echo 0)"
assert_eq "S9 user's Y preserved"      "1" "$(has "$DEST" "$Y")"

printf "\n--- S10: baseline lost but dest edited → user removal recovered ---\n"
# Fresh managed list, user removed B, then base disappears (reinstall w/o restore).
rm -rf "$WDIR"; mkdir -p "$WDIR"
printf '%s\n%s\n' "$A" "$C" > "$DEST"      # user's edited list (B removed), NO base
refresh "$A
$B
$C" 2
assert_eq "S10 B stays removed w/o base"   "0" "$(has "$DEST" "$B")"
assert_eq "S10 A,C preserved w/o base"     "$A,$C," "$(setof "$DEST")"
assert_eq "S10 base re-established"         "1" "$([ -f "$BASE" ] && echo 1 || echo 0)"

printf "\n--- S11: fetch failure (rc=1) touches nothing ---\n"
GOOD="$(setof "$DEST")"
refresh "$A
$B
$C
$D" 1
assert_eq "S11 dest unchanged on fetch fail" "$GOOD" "$(setof "$DEST")"

printf "\n--- S12: install.sh preserves baseline+tombstone across reinstall ---\n"
# Static assertion: both the backup and restore blocks copy the two dotfiles.
assert_eq "backup copies .base+.removed" "2" \
  "$(grep -c '\.game-warp-ips\.\(base\|removed\)' "$SCRIPT_DIR/lib/install.sh" | head -1; )"
BK=$(awk '/warp-lists\// && /\.game-warp-ips\./' "$SCRIPT_DIR/lib/install.sh" | grep -c 'for _wm')
assert_eq "backup+restore both loop the dotfiles" "2" \
  "$(grep -c 'for _wm in .game-warp-ips.base .game-warp-ips.removed' "$SCRIPT_DIR/lib/install.sh")"

printf "\n--- S13: add-only (no removals) + upstream adds a new line same cycle ---\n"
# The real-world common case: user added a custom, and next refresh upstream
# also gained a game. Empty user_removed must NOT eat the upstream.
rm -rf "$WDIR"; mkdir -p "$WDIR"
refresh "$A
$B" 2                          # seed {A,B}
user_set "$A
$B
$X"                              # user adds custom X (removes nothing)
refresh "$A
$B
$C" 2                          # upstream adds C
assert_eq "S13 upstream C flows in" "1" "$(has "$DEST" "$C")"
assert_eq "S13 user X survives"     "1" "$(has "$DEST" "$X")"
assert_eq "S13 A,B intact"          "$A,$B,$C,$X," "$(setof "$DEST")"

printf "\n--- S14: adopt-then-drop — user addition survives upstream adopting then dropping it ---\n"
# Regression for the review finding: user_added computed vs CURRENT upstream
# (dest - san), not the baseline, so a line the community list adopts then
# removes stays because it is still the user's.
rm -rf "$WDIR"; mkdir -p "$WDIR"
refresh "$A
$B" 2                            # seed {A,B}
user_set "$A
$B
$X"                                # user adds custom X
refresh "$A
$B
$X" 2                            # upstream ADOPTS X
assert_eq "S14 X present after adopt" "1" "$(has "$DEST" "$X")"
refresh "$A
$B" 2                            # upstream DROPS X again
assert_eq "S14 X SURVIVES upstream drop" "1" "$(has "$DEST" "$X")"
assert_eq "S14 dest = {A,B,X}" "$A,$B,$X," "$(setof "$DEST")"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
