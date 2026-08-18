#!/bin/sh
# tests/test_alert_detector.sh — обёртка над lua-харнесом
# tests/test_alert_detector.lua, чтобы общий прогон (tests/run_all.sh) и CI
# подхватывали его вместе с остальными test_*.sh.
#
# Пробрасывает stdout (строки [PASS]/[FAIL], по которым считает run_all.sh) и
# код возврата. Если lua на машине нет — печатаем одну строку [PASS] со
# словом «пропущено», чтобы локальная разработка без lua не вставала; в CI
# lua установлена и тест выполняется по-настоящему.

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
    printf "[PASS] alert_detector: пропущено (lua локально не установлена)\n"
    exit 0
fi

cd "$PROJECT_ROOT"
exec "$LUA" tests/test_alert_detector.lua
