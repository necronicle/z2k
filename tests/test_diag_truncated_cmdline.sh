#!/bin/sh
# tests/test_diag_truncated_cmdline.sh — сводка на ядре, обрезающем cmdline.
#
# Ядра до 4.2 отдают в /proc/PID/cmdline только первые 4096 байт. Полевой случай
# 31.10.2026 (MIPS, ядро 3.4, p-87.3): шаблон РКН стоит первым профилем, circular
# — в импортирующем профиле за отсечкой, и сводка выдала «10 плеч в 0 пулах» и
# красное «в движке нет ни одного circular» при живой ротации. При отсечке ровно
# на странице профили берутся из конфига; голова движка (флаги вроде
# --reasm-disable) — по-прежнему из /proc.
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="$HERE/files/z2k-diag.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
for f in nfqws_cmdline nfqws_strategy_counts nfqws_reasm_state; do
    awk "/^$f\\(\\) \\{/,/^\\}/" "$SRC" >> "$TMP/fns.sh"
done

# Профили: шаблон с двумя плечами, импортирующий пул с circular, второй пул.
PROFILES="--template=rkn_arsenal --lua-desync=fake:strategy=1 --lua-desync=multisplit:strategy=2 --new --filter-tcp=443 --lua-desync=circular:key=rkn_tcp --import=rkn_arsenal --new --filter-udp=443 --lua-desync=circular:key=quic --lua-desync=fake:strategy=1 --lua-desync=fake:strategy=2 --lua-desync=fake:strategy=3"
printf 'ENABLED=1\nNFQWS2_OPT="\n%s\n"\n' "$PROFILES" > "$TMP/config"
HEAD="nfqws2 --qnum=200 --lua-init=@/opt/zapret2/lua/zapret-lib.lua"
# Боевая строка, обрезанная ядром ровно на 4096 байтах посреди профилей.
# Набивка подогнана так, чтобы отсечка пришлась посреди профилей (около 3900-го байта).
PAD=$(awk -v n=$((3900 - ${#HEAD} - 15)) 'BEGIN { while (n-- > 0) printf "0" }')
printf '%s --blob=pad:0x%s %s' "$HEAD" "$PAD" "$PROFILES" \
    | tr ' ' '\0' | head -c 4096 > "$TMP/cmd.trunc"
# Короткая строка — не обрезана, читается как есть.
printf '%s %s' "$HEAD --reasm-disable=tls_client_hello" "$PROFILES" | tr ' ' '\0' > "$TMP/cmd.full"

run() { # run <cmdline-файл> <функция>
    env -i PATH="$PATH" SB="$TMP" C="$1" F="$2" sh -c '. "$SB/fns.sh"; Z2K_DIAG_CMDLINE_SRC="$C" Z2K_DIAG_CONFIG_SRC="$SB/config" $F' 2>/dev/null
}

[ "$(wc -c < "$TMP/cmd.trunc" | tr -d ' ')" = 4096 ] || no "харнес: строка обрезана на 4096" 4096 "$(wc -c < "$TMP/cmd.trunc")"
r=$(run "$TMP/cmd.trunc" nfqws_strategy_counts)
[ "$r" = "5 2 0" ] && ok "обрезанная строка: 5 плеч в 2 пулах, мёртвых нет" || no "обрезанная строка: счёт по конфигу" "5 2 0" "$r"
r=$(run "$TMP/cmd.trunc" nfqws_reasm_state)
[ "$r" = "off" ] && ok "обрезанная строка: голова движка читается из /proc" || no "голова из /proc" "off" "$r"
r=$(run "$TMP/cmd.full" nfqws_strategy_counts)
[ "$r" = "5 2 0" ] && ok "полная строка: счёт как прежде" || no "полная строка" "5 2 0" "$r"
r=$(run "$TMP/cmd.full" nfqws_reasm_state)
[ "$r" = "on" ] && ok "полная строка: флаг пересборки виден" || no "флаг пересборки" "on" "$r"

printf '\nИТОГ: %d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
