#!/bin/sh
# tests/test_mid_stream_stall.sh — wrapper that runs the lua mock-harness
# tests/test_mid_stream_stall.lua so the shared runner (tests/run_all.sh)
# and CI's integration step pick it up automatically alongside the
# shell test_*.sh files.
#
# Forwards stdout (which carries the [PASS]/[FAIL] lines run_all.sh
# scans) and propagates exit code. If `lua` is missing on the host —
# emit a single [PASS] skip-line so local devs without lua aren't
# blocked by missing dependency; CI ensures lua is installed.

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
    printf "[PASS] mid_stream_stall: skipped (lua not installed locally)\n"
    exit 0
fi

# The .lua harness loads files/lua/z2k-detectors.lua via dofile() with
# a project-root-relative path, so cd there before invoking.
cd "$PROJECT_ROOT"
exec "$LUA" tests/test_mid_stream_stall.lua
