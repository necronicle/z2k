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

# ----- summary ------------------------------------------------------------

echo "--- summary ---"
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ] || exit 1
exit 0
