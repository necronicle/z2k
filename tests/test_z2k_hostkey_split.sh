#!/bin/sh
# tests/test_z2k_hostkey_split.sh — обёртка над lua-харнесом
# tests/test_z2k_hostkey_split.lua, чтобы общий прогон (tests/run_all.sh) и CI
# видели его как обычный набор. Считает run_all.sh по строкам [PASS]/[FAIL],
# которые печатает сам харнес. Без lua — [SKIP] (засчитывается и печатается
# поимённо, не маскируется под [PASS]): в CI lua есть.
LUA=""
for c in lua5.3 lua5.4 lua luajit; do
    if command -v "$c" >/dev/null 2>&1; then LUA=$c; break; fi
done
if [ -z "$LUA" ]; then
    printf '[SKIP] lua не найден — test_z2k_hostkey_split.lua не запущен\n'
    exit 0
fi
cd "$(dirname "$0")/.." || exit 1
exec "$LUA" tests/test_z2k_hostkey_split.lua
