#!/bin/sh
# tests/test_module_matrix.sh — ни один Go-модуль не может выпасть из автоматики.
#
# ПОЧЕМУ ЭТОТ ТЕСТ СУЩЕСТВУЕТ.
#
# Списки модулей в CI, в сканере уязвимостей и в dependabot перечислены РУКАМИ,
# в трёх разных файлах. Это уже подводило дважды:
#
#   * rt-proxy месяцами жил вне CI;
#   * z2k-verify, появившись 2026-08-08, не попал ни в одну из трёх матриц —
#     причём в сканере он не попал прямо под комментарием «все четыре модуля, а
#     не те, что вспомнили».
#
# Цена именно у z2k-verify максимальная в проекте: его sha256 запинен в z2k.sh,
# и роутер с защёлкнутым храповиком без работающего проверяльщика отвергает
# манифест. Одна несобравшаяся арка = обновления встали одновременно у всей этой
# части парка.
#
# Поэтому список здесь НЕ перечисляется, а вычисляется из дерева: модуль — это
# каталог с go.mod. Добавили модуль и забыли про матрицы — тест краснеет.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CI="$ROOT/.github/workflows/ci.yml"
SEC="$ROOT/.github/workflows/security.yml"
DEP="$ROOT/.github/dependabot.yml"
for f in "$CI" "$SEC" "$DEP"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

# --- Модули = каталоги с go.mod ------------------------------------------------
MODULES=""
for _m in "$ROOT"/*/go.mod; do
    [ -f "$_m" ] || continue
    _d=$(dirname "$_m"); MODULES="$MODULES $(basename "$_d")"
done
MODULES=$(printf '%s' "$MODULES" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort)

_count=$(printf '%s\n' "$MODULES" | grep -c .)
if [ "$_count" -ge 5 ]; then
    ok "модули найдены по go.mod ($_count): $(printf '%s' "$MODULES" | tr '\n' ' ')"
else
    no "модули найдены по go.mod" "минимум 5" "$_count"
fi

# --- 1. Матрица сборки CI ------------------------------------------------------
_line=$(grep -n 'module: \[' "$CI" | head -1 | cut -d: -f2-)
for m in $MODULES; do
    case "$_line" in
        *"$m"*) ;;
        *) no "модуль $m в матрице CI" "есть в module: [...]" "нет" ;;
    esac
done
printf '%s' "$_line" | grep -q 'module' && ok "матрица CI разобрана"

# --- 2. Кросс-сборка под арки --------------------------------------------------
#
# Попасть в матрицу мало: без ветки в case модуль соберётся только под хост, а
# на роутер уезжает не хост. Именно так шесть из девяти арок z2k-detect не
# компилировались в CI вовсе.
for m in $MODULES; do
    if grep -qE "^[[:space:]]*$m\)[[:space:]]+TARGETS=" "$CI"; then
        :
    else
        no "модуль $m кросс-собирается в CI" "ветка $m) TARGETS=" "нет"
    fi
done
ok "ветки кросс-сборки проверены"

# --- 3. Сканер уязвимостей -----------------------------------------------------
_scan=$(grep -n 'for m in ' "$SEC" | head -1 | cut -d: -f2-)
for m in $MODULES; do
    case "$_scan" in
        *"$m"*) ;;
        *) no "модуль $m в сканере уязвимостей" "есть в цикле govulncheck" "нет" ;;
    esac
done
ok "список сканера проверен"

# --- 4. Dependabot -------------------------------------------------------------
#
# Модуль вне dependabot — это модуль с вечно замороженными зависимостями, про
# который никто не узнает: обновления приходят PR'ами, а PR не приходит.
for m in $MODULES; do
    if grep -qE "^[[:space:]]*-[[:space:]]*/${m}[[:space:]]*$" "$DEP"; then
        :
    else
        no "модуль $m в dependabot" "строка - /$m" "нет"
    fi
done
ok "список dependabot проверен"

# --- 5. У каждого модуля есть свои тесты ---------------------------------------
#
# Модуль без единого теста проходит CI зелёным, ничего при этом не проверив.
for m in $MODULES; do
    if find "$ROOT/$m" -name '*_test.go' -print -quit 2>/dev/null | grep -q .; then
        :
    else
        no "у модуля $m есть go-тесты" "хотя бы один *_test.go" "ни одного"
    fi
done
ok "наличие тестов проверено"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
