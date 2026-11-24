#!/bin/sh
# tests/test_autopilot_panel.sh — обёртка для запуска DOM-тестов карточки автопилота в node.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v node >/dev/null 2>&1; then
    printf '[SKIP] autopilot panel UI tests: node not found\n'
    printf '\nPASSED: 0\nFAILED: 0\nSKIPPED: 1\n'
    exit 0
fi
node "$HERE/tests/test_autopilot_panel.cjs"
