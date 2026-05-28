#!/bin/sh
# tests/test_z2k_state_persist.sh — wrapper for the Lua test harness
# tests/test_z2k_state_persist.lua (persist-only rotator state.tsv).
# Routes state.tsv (and the /tmp fallback) into an isolated tmp dir via
# Z2K_STATE_DIR_OVERRIDE / Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE so the real
# /opt/zapret2 state — and any shared /tmp fallback — is never touched.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LUA=""
for candidate in lua lua5.3 lua5.4 lua5.1; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LUA="$candidate"
        break
    fi
done

if [ -z "$LUA" ]; then
    printf "[PASS] z2k_state_persist: skipped (lua not installed locally)\n"
    exit 0
fi

TEST_DIR="/tmp/z2k-state-persist-test-$$"
mkdir -p "$TEST_DIR/fallback"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT INT TERM HUP

cd "$PROJECT_ROOT"
Z2K_STATE_DIR_OVERRIDE="$TEST_DIR" \
Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TEST_DIR/fallback" \
    "$LUA" tests/test_z2k_state_persist.lua
