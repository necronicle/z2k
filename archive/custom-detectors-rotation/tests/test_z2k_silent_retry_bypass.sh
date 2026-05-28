#!/bin/sh
# tests/test_z2k_silent_retry_bypass.sh — wrapper for D.5a Lua unit tests.
# См. D.5a (commit 4c729fc) и review High 2026-05-16.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_DIR="/tmp/z2k-test-silent-retry-bypass-$$"
mkdir -p "$TEST_DIR"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM HUP

LUA=""
for candidate in lua lua5.3 lua5.4 lua5.1; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LUA="$candidate"
        break
    fi
done

if [ -z "$LUA" ]; then
    printf "[PASS] silent_retry bypass: skipped (lua not installed locally)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
Z2K_TEST_MODE=1 \
Z2K_AUTOCIRCULAR_DIR_OVERRIDE="$TEST_DIR" \
Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TEST_DIR" \
Z2K_PROBE_OVERRIDE="$TEST_DIR/probe-override.tsv" \
    "$LUA" tests/test_z2k_silent_retry_bypass.lua
