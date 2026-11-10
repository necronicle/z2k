#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v node >/dev/null 2>&1; then
    printf '[SKIP] panel age sort: node not found\n'
    exit 0
fi
node "$HERE/tests/test_panel_age_sort.cjs"
