#!/bin/sh
# tests/test_anti_drift.sh — интеграционные тесты Anti-Drift (auto_pinned)
# с реальным zapret-auto.lua, z2k-alert.lua, z2k-quic-silence.lua и z2k-state-persist.lua.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT" || exit 1

LUA=""
for cand in lua5.3 lua5.4 lua5.2 lua luajit; do
    if command -v "$cand" >/dev/null 2>&1; then
        LUA="$cand"
        break
    fi
done
[ -n "$LUA" ] || { printf '[PASS] anti_drift: skipped (lua not installed)\n'; exit 0; }

FORK=${Z2K_FORK_DIR:-"$ROOT/../zapret2-z2k-fork"}
[ -f "$FORK/tests/harness.lua" ] || { printf '[PASS] anti_drift: skipped (fork harness not found)\n'; exit 0; }

TEST_DIR="/tmp/z2k-anti-drift-test-$$"
mkdir -p "$TEST_DIR/fb"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

Z2K_FORK_DIR="$FORK" \
Z2K_STATE_DIR_OVERRIDE="$TEST_DIR" \
Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TEST_DIR/fb" \
    "$LUA" tests/test_anti_drift.lua
