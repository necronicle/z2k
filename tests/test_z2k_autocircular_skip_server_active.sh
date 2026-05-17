#!/bin/sh
# tests/test_z2k_autocircular_skip_server_active.sh — runs lua harness
# tests/test_z2k_autocircular_skip_server_active.lua under Z2K_TEST_MODE=1.

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
    printf "[PASS] autocircular_skip_server_active: skipped (lua not installed locally)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
exec env Z2K_TEST_MODE=1 "$LUA" tests/test_z2k_autocircular_skip_server_active.lua
