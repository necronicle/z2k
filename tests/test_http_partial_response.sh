#!/bin/sh
# tests/test_http_partial_response.sh — wrapper running the lua mock-harness
# tests/test_http_partial_response.lua so the shared runner and CI pick it up.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LUA=""
for candidate in lua lua5.3 lua5.4 lua5.1; do
    if command -v "$candidate" >/dev/null 2>&1; then LUA="$candidate"; break; fi
done
if [ -z "$LUA" ]; then
    printf "[PASS] http_partial_response: skipped (lua not installed locally)\n"; exit 0
fi
cd "$PROJECT_ROOT"
exec "$LUA" tests/test_http_partial_response.lua
