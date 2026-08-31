#!/bin/sh
# tests/test_portability_traps.sh — ловушки, на которых локально зелено, а в CI
# красно. Каждая внесена сюда ПОСЛЕ того, как обожгла.
#
# Разработка идёт на macOS (BSD-утилиты), роутеры и CI — на busybox и GNU. Беда
# не в том, что команда отсутствует: тогда её отказ уводит на запасную ветку и
# всё работает. Беда, когда она есть и ОТРАБАТЫВАЕТ УСПЕШНО, делая не то.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# --- 1. stat: -f НИКОГДА не должен стоять раньше -c ---------------------------
#
# На BSD `stat -f %m` — время изменения файла. В GNU coreutils `-f` это
# статистика ФАЙЛОВОЙ СИСТЕМЫ, и она завершается УСПЕШНО, отдав блоки и иноды.
# Значит `stat -f %m … || stat -c %Y …` на Linux никогда не дойдёт до второй
# половины и подставит мусор. Правильный порядок обратный: сначала -c (на BSD
# он честно падает), потом -f.
#
# Обожгло 31.08.2026: тест планировщика зеленел на маке и уронил CI.
bad_order=$(grep -rn 'stat -f [^|]*|| *stat -c' --include='*.sh' . 2>/dev/null \
            | grep -v '^\./tests/test_portability_traps\.sh:' || true)
bad_order2=$(grep -rn 'stat -f' files/S99zapret2.new 2>/dev/null \
            | grep -v 'stat -c %Y' || true)
if [ -z "$bad_order" ] && [ -z "$bad_order2" ]; then
    ok "везде stat -c пробуется раньше stat -f"
else
    printf '%s\n%s\n' "$bad_order" "$bad_order2" | grep -v '^$' | while IFS= read -r l; do
        printf '   %s\n' "$l"
    done
    bad "stat -f стоит раньше stat -c — на Linux вернётся статистика ФС, а не время файла"
fi

# Больше правил здесь НЕТ намеренно. Первая версия несла ещё две проверки —
# на `sed -i` и на `grep -P` — и обе оказались ложными тревогами: busybox
# понимает `sed -i` по-GNU, а под `grep -P` попал `pgrep -P`. Сторож, который
# кричит на исправный код, перестают читать; правило попадает сюда только
# после того, как обожгло по-настоящему.

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
