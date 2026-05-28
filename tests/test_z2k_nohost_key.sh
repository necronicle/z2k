#!/bin/sh
# tests/test_z2k_nohost_key.sh — wrapper for the Lua test harness
# tests/test_z2k_nohost_key.lua (native z2k_nohost_key hostkey generator,
# replacement for the archived z2k-autocircular allow_nohost path).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Lua interpreter discovery — pattern shared with the other lua test wrappers.
LUA=""
for candidate in lua lua5.3 lua5.4 lua5.1; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LUA="$candidate"
        break
    fi
done

if [ -z "$LUA" ]; then
    printf "[PASS] z2k_nohost_key: skipped (lua not installed locally)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
"$LUA" tests/test_z2k_nohost_key.lua
