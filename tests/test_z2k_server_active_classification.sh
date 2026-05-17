#!/bin/sh
# tests/test_z2k_server_active_classification.sh — runs the lua harness
# tests/test_z2k_server_active_classification.lua. Pattern mirrors
# test_http_classifier.sh.

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
    printf "[PASS] server_active_classification: skipped (lua not installed locally)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
exec "$LUA" tests/test_z2k_server_active_classification.lua
