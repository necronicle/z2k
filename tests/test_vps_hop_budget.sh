#!/bin/sh
# tests/test_vps_hop_budget.sh — первичный хоп через наш VPS обязан иметь один
# бюджет во всех местах, где он используется.
#
# ЧТО СЛУЧИЛОСЬ (issue #46, 31.08.2026). Скачивание релиза давало
# «Connection timed out after 3002 milliseconds» и уходило на запасной путь.
# Причина — разные бюджеты на ОДИН И ТОТ ЖЕ хоп: штатный z2k_fetch давал восемь
# секунд в две попытки, а скачивание релиза — три в одну.
#
# Почему именно три секунды губительны: ретрансмиссии SYN приходят на первой и
# третьей секунде, то есть бюджет исчерпан ровно в момент второй попытки. Одна
# потеря SYN — и первичный путь объявлен мёртвым.
#
# Тест исполняемый: вычитывает значения из обоих файлов и сравнивает их.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fetch_ct=$(sed -n 's/.*Z2K_FETCH_VPS_CONNECT_TIMEOUT:-\([0-9]*\)}.*/\1/p' "$ROOT/lib/utils.sh" | head -1)
rel_ct=$(sed -n 's/.*Z2K_VPS_CONNECT_TIMEOUT:-\([0-9]*\)}.*/\1/p' "$ROOT/lib/install.sh" | head -1)

[ -n "$fetch_ct" ] || bad "не нашёл бюджет слоя 0 в lib/utils.sh"
[ -n "$rel_ct" ]   || bad "не нашёл бюджет скачивания релиза в lib/install.sh"

if [ -n "$fetch_ct" ] && [ -n "$rel_ct" ]; then
    if [ "$fetch_ct" = "$rel_ct" ]; then
        ok "бюджет хопа одинаков в обоих местах ($fetch_ct с)"
    else
        bad "бюджеты разошлись: z2k_fetch $fetch_ct с, скачивание релиза $rel_ct с"
    fi
fi

# Ниже четырёх секунд бюджет бессмыслен: одна потеря SYN его гарантированно
# съедает (ретрансмиссии на 1-й и 3-й секунде).
for v in "$fetch_ct" "$rel_ct"; do
    [ -n "$v" ] || continue
    if [ "$v" -ge 4 ] 2>/dev/null; then
        ok "бюджет $v с переживает одну потерю SYN"
    else
        bad "бюджет $v с не переживает ни одной потери SYN"
    fi
done

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
