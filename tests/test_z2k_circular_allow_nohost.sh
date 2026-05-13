#!/bin/sh
# tests/test_z2k_circular_allow_nohost.sh — wrapper for the Lua test harness.
# См. PLAN_orchestrator_replacement.md B1 + Тесты section.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolated test directory — prod /opt/zapret2/... не трогаем.
TEST_DIR="/tmp/z2k-test-allow-nohost-$$"
mkdir -p "$TEST_DIR"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM HUP

# Lua interpreter discovery — pattern from test_probe_override.sh.
LUA=""
for candidate in lua lua5.3 lua5.4 lua5.1; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LUA="$candidate"
        break
    fi
done

if [ -z "$LUA" ]; then
    printf "[PASS] allow_nohost: skipped (lua not installed locally)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
# Route lua paths к $TEST_DIR через env override'ы (см. B1 "Env override
# для test isolation"). Никакого backup/restore production state — wrapper
# в prod state вообще не лезет.
Z2K_AUTOCIRCULAR_DIR_OVERRIDE="$TEST_DIR" \
Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TEST_DIR" \
Z2K_PROBE_OVERRIDE="$TEST_DIR/probe-override.tsv" \
    "$LUA" tests/test_z2k_circular_allow_nohost.lua
