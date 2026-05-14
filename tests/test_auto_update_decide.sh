#!/bin/sh
# tests/test_auto_update_decide.sh — unit tests for au_decide / au_entry_bool /
# au_apply_reinstall integration with the optional "reset_state" history flag.
#
# Run: sh tests/test_auto_update_decide.sh
# Exit 0 on green, 1 on failure. Picked up by tests/run_all.sh via the
# test_*.sh glob.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolate from any real /opt/zapret2 state — point auto_update at a temp
# scratch dir so we never touch a real installation.
AU_TMP="$(mktemp -d -t z2k_au_test.XXXXXX)"
trap 'rm -rf "$AU_TMP"' EXIT INT TERM
export Z2K_AU_TMP_DIR="$AU_TMP"
export Z2K_AU_LOG_FILE="$AU_TMP/log"
export Z2K_AU_INSTALLED_TAG_FILE="$AU_TMP/installed"
# au_log writes to stderr; redirect to a file so test stdout stays clean.
# shellcheck disable=SC1091
. "$PROJECT_ROOT/lib/auto_update.sh" 2>/dev/null || true

PASS=0
FAIL=0

check() {
    name="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "[PASS] $name"
    else
        FAIL=$((FAIL + 1))
        echo "[FAIL] $name"
        echo "       expected: $expected"
        echo "       actual:   $actual"
    fi
}

# ----- au_entry_bool ------------------------------------------------------

# Boolean true is recognised, false and missing both yield empty.
got=$(au_entry_bool '{"v":"x","type":"reinstall","reset_state":true}' "reset_state")
check "au_entry_bool: true → 'true'" "true" "$got"

got=$(au_entry_bool '{"v":"x","type":"reinstall","reset_state":false}' "reset_state")
check "au_entry_bool: false → empty" "" "$got"

got=$(au_entry_bool '{"v":"x","type":"reinstall"}' "reset_state")
check "au_entry_bool: missing field → empty" "" "$got"

# Don't confuse with quoted string "true" (that's au_entry_field territory).
got=$(au_entry_bool '{"v":"x","reset_state":"true"}' "reset_state")
check "au_entry_bool: quoted 'true' string → empty" "" "$got"

# ----- au_decide integration ---------------------------------------------

# Helper: render a manifest JSON into AU_TMP and call au_decide.
write_manifest() {
    cat > "$AU_TMP/manifest.json"
}

# Case A: single reinstall entry WITHOUT reset_state → plain reinstall.
write_manifest <<'JSON'
{
  "schema": 1,
  "branch": "z2k-enhanced",
  "current": "r-100",
  "history": [
{"v": "r-99",  "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "x", "desc": "x", "changed_files": ["a"]},
{"v": "r-100", "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "y", "desc": "y", "changed_files": ["b"]}
  ]
}
JSON
verdict=$(au_decide "r-99" "$AU_TMP/manifest.json" | head -1)
check "au_decide: plain reinstall verdict" "reinstall r-100" "$verdict"

# Case B: reinstall WITH reset_state:true → verdict carries flag.
write_manifest <<'JSON'
{
  "schema": 1,
  "branch": "z2k-enhanced",
  "current": "r-101",
  "history": [
{"v": "r-99",  "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "x", "desc": "x", "changed_files": ["a"]},
{"v": "r-101", "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "z", "desc": "z", "reset_state": true, "changed_files": ["c"]}
  ]
}
JSON
verdict=$(au_decide "r-99" "$AU_TMP/manifest.json" | head -1)
check "au_decide: reinstall + reset_state verdict" "reinstall r-101 reset_state" "$verdict"

# Case C: window with reset_state in *earlier* entry, plain entry at current.
# Per au_decide semantics, ANY entry in the diff window triggering
# reset_state should produce reset_state verdict (sticky across window).
write_manifest <<'JSON'
{
  "schema": 1,
  "branch": "z2k-enhanced",
  "current": "r-102",
  "history": [
{"v": "r-99",  "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "x", "desc": "x", "changed_files": ["a"]},
{"v": "r-100", "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "y", "desc": "y", "reset_state": true, "changed_files": ["b"]},
{"v": "r-102", "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "z", "desc": "z", "changed_files": ["c"]}
  ]
}
JSON
verdict=$(au_decide "r-99" "$AU_TMP/manifest.json" | head -1)
check "au_decide: reset_state sticky across window" "reinstall r-102 reset_state" "$verdict"

# Case D: patch-only window with reset_state field — patch verdict, no
# reset_state token. State wipes are reinstall-only by design (patches
# are surgical file replacements, not full reinstalls).
write_manifest <<'JSON'
{
  "schema": 1,
  "branch": "z2k-enhanced",
  "current": "p-103",
  "history": [
{"v": "r-99",  "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "x", "desc": "x", "changed_files": ["a"]},
{"v": "p-103", "type": "patch",     "ts": "2026-05-15T00:00:00Z", "ref": "z", "desc": "z", "reset_state": true, "changed_files": ["c"]}
  ]
}
JSON
verdict=$(au_decide "r-99" "$AU_TMP/manifest.json" | head -1)
check "au_decide: patch-only never wipes (no reset_state token)" "patch p-103" "$verdict"

# Case E: nothing to do (installed == current).
write_manifest <<'JSON'
{
  "schema": 1,
  "branch": "z2k-enhanced",
  "current": "r-99",
  "history": [
{"v": "r-99", "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "x", "desc": "x", "changed_files": ["a"]}
  ]
}
JSON
verdict=$(au_decide "r-99" "$AU_TMP/manifest.json" | head -1)
check "au_decide: no-op when up to date" "none" "$verdict"

# Case F: history-order matching survives mixed p-/r- numbering.
# Regression scenario from 2026-05-15: installed=p-7 (num=7), then
# r-6 (num=6) was released AFTER p-7, then p-8 (num=8). Old numeric-
# compare au_history_entries_after dropped r-6 because 6 < 7. New
# history-order matcher must include r-6 because it appears AFTER
# the p-7 entry in the history array, regardless of its tag number.
write_manifest <<'JSON'
{
  "schema": 1,
  "branch": "z2k-enhanced",
  "current": "p-8",
  "history": [
{"v": "p-6", "type": "patch",     "ts": "2026-05-14T00:00:00Z", "ref": "a", "desc": "a", "changed_files": ["x"]},
{"v": "p-7", "type": "patch",     "ts": "2026-05-14T18:00:00Z", "ref": "b", "desc": "b", "changed_files": ["y"]},
{"v": "r-6", "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "c", "desc": "c", "reset_state": true, "changed_files": ["z"]},
{"v": "p-8", "type": "patch",     "ts": "2026-05-15T01:00:00Z", "ref": "d", "desc": "d", "changed_files": ["w"]}
  ]
}
JSON
verdict=$(au_decide "p-7" "$AU_TMP/manifest.json" | head -1)
check "au_decide: history-order picks r-6 even though num<installed" \
      "reinstall p-8 reset_state" "$verdict"

# Case G: installed tag absent from history (drift / fresh install) —
# everything in history flows into the diff window.
write_manifest <<'JSON'
{
  "schema": 1,
  "branch": "z2k-enhanced",
  "current": "r-100",
  "history": [
{"v": "p-50",  "type": "patch",     "ts": "2026-05-15T00:00:00Z", "ref": "a", "desc": "a", "changed_files": ["x"]},
{"v": "r-100", "type": "reinstall", "ts": "2026-05-15T00:00:00Z", "ref": "b", "desc": "b", "changed_files": ["y"]}
  ]
}
JSON
verdict=$(au_decide "unknown-tag-999" "$AU_TMP/manifest.json" | head -1)
check "au_decide: installed-tag-not-in-history → reinstall to current" \
      "reinstall r-100" "$verdict"

# ----- au_install_paths --------------------------------------------------

check_path() {
    name="$1"; repo="$2"; want="$3"
    got=$(au_install_paths "$repo" | tr '\n' '|')
    check "$name" "$want" "$got"
}

# Existing mappings still work.
check_path "au_install_paths: files/lua/x.lua" \
    "files/lua/foo.lua" "/opt/zapret2/lua/foo.lua|"

# New mappings: lib/*, UPDATES.json, z2k.sh.
check_path "au_install_paths: lib/auto_update.sh" \
    "lib/auto_update.sh" "/opt/zapret2/lib/auto_update.sh|"

check_path "au_install_paths: lib/install.sh" \
    "lib/install.sh" "/opt/zapret2/lib/install.sh|"

check_path "au_install_paths: lib/utils.sh (any lib/ depth)" \
    "lib/utils.sh" "/opt/zapret2/lib/utils.sh|"

check_path "au_install_paths: UPDATES.json" \
    "UPDATES.json" "/opt/zapret2/UPDATES.json|"

check_path "au_install_paths: z2k.sh" \
    "z2k.sh" "/opt/zapret2/z2k.sh|"

# tests/* остаются unmapped (dev-only artifacts), но silent — без шума
# в логе. Просто empty output.
check_path "au_install_paths: tests/* → empty (silent skip)" \
    "tests/test_x.sh" ""

# Unknown paths остаются empty.
check_path "au_install_paths: unknown root file → empty" \
    "RANDOM.txt" ""

# ----- summary ------------------------------------------------------------

echo "--- summary ---"
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ] || exit 1
exit 0
