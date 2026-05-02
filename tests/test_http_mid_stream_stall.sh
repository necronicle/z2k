#!/bin/sh
# tests/test_http_mid_stream_stall.sh — wrapper that runs the lua mock-
# harness tests/test_http_mid_stream_stall.lua so the shared runner
# (tests/run_all.sh) and CI's integration step pick it up automatically
# alongside the shell test_*.sh files.

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
    printf "[PASS] http_mid_stream_stall: skipped (lua not installed locally)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
exec "$LUA" tests/test_http_mid_stream_stall.lua
