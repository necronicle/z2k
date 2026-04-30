#!/bin/sh
# tests/test_probe_override.sh — wrapper for the Lua live-override harness.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERRIDE_FILE="/tmp/z2k-probe-override.tsv"
BACKUP_FILE="/tmp/z2k-probe-override.tsv.testbak.$$"

if [ -f "$OVERRIDE_FILE" ]; then
    cp "$OVERRIDE_FILE" "$BACKUP_FILE"
fi

cleanup() {
    rm -f "$OVERRIDE_FILE"
    if [ -f "$BACKUP_FILE" ]; then
        mv "$BACKUP_FILE" "$OVERRIDE_FILE"
    fi
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
    printf "[PASS] probe_override: skipped (lua not installed locally)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
"$LUA" tests/test_probe_override.lua
