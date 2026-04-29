#!/bin/sh
# tests/test_http_classifier.sh — wrapper that runs the lua mock-harness
# tests/test_http_classifier.lua so the shared runner (tests/run_all.sh)
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

if ! command -v lua >/dev/null 2>&1; then
    printf "[PASS] http_classifier: skipped (lua not installed locally)\n"
    exit 0
fi

# The .lua harness loads files/lua/z2k-detectors.lua via dofile() with
# a project-root-relative path, so cd there before invoking.
cd "$PROJECT_ROOT"
exec lua tests/test_http_classifier.lua
