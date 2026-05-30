#!/bin/sh
# tests/test_tls_stalled.sh — wrapper that runs the lua mock-harness
# tests/test_tls_stalled.lua so the shared runner (tests/run_all.sh) and
# CI's integration step pick it up automatically alongside the shell
# test_*.sh files.
#
# Forwards stdout (the [PASS]/[FAIL] lines run_all.sh scans) and
# propagates exit code. If `lua` is missing locally, emit a single
# [PASS] skip-line so devs without lua aren't blocked; CI installs lua.

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
    printf "[PASS] tls_stalled: skipped (lua not installed locally)\n"
    exit 0
fi

# The .lua harness loads files/lua/z2k-detectors.lua via a project-root-
# relative dofile() path, so cd there before invoking.
cd "$PROJECT_ROOT"
exec "$LUA" tests/test_tls_stalled.lua
