#!/bin/sh
# tests/run_all.sh - Test runner for z2k integration tests
# Run: sh tests/run_all.sh
# POSIX sh compatible (busybox ash).

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
TOTAL_SUITES=0
FAILED_SUITES=""
SKIPPED_SUITES=""

# Z2K_STRICT_SKIP=1 — пропуск считается провалом.
#
# Обычный прогон на ноутбуке разработчика законно пропускает часть проверок
# (нет node, нет python3, нет соседнего репозитория с движком), и падать на
# этом было бы ложной тревогой. А вот в CI, где окружение мы задаём сами,
# пропуск означает, что проверка не выполнялась НИ РАЗУ ни у кого. Гейт
# включается там, а не здесь: строгость по месту, а не по умолчанию.
Z2K_STRICT_SKIP="${Z2K_STRICT_SKIP:-0}"

# Длительность КАЖДОГО набора. Сегодня один набор съедал 85% времени прогона, и
# чтобы это увидеть, пришлось руками разбирать лог CI по временным меткам —
# сам раннер показывает только общее время джоба. Теперь цена каждого набора
# видна сразу, а самые дорогие печатаются отдельным списком.
TIMINGS="${TMPDIR:-/tmp}/z2k-suite-timings.$$"
: > "$TIMINGS"
SKIPLOG="${TMPDIR:-/tmp}/z2k-suite-skips.$$"
: > "$SKIPLOG"
trap 'rm -f "$TIMINGS" "$SKIPLOG"' EXIT INT TERM
# Бюджет на набор. Не гейт (падать из-за медленной машины — ложная тревога),
# но громкая отметка: набор дороже минуты почти всегда ждёт по часам вместо
# того, чтобы что-то проверять.
SUITE_BUDGET="${Z2K_SUITE_BUDGET:-60}"

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Каким интерпретатором гонять сами наборы. На ubuntu-latest /bin/sh — это
# dash, на macOS — bash, и наборы под ними расходятся не косметически (см.
# шапку tests/lib/common.sh). Переменная наследуется внутрь каждого набора и
# оттуда — во вложенные оболочки, поэтому один и тот же прогон можно повторить
# в диалекте CI, не правя ни одного теста.
. "$TESTS_DIR/lib/common.sh"
printf 'Интерпретатор наборов: %s\n\n' "$Z2K_TEST_SH"

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "  z2k Integration Test Suite\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

# Z2K_SKIP_SUITES — набор имён через пробел, которые в ЭТОМ окружении
# проверить нечем. Пропуск объявляется вслух и не засчитывается пройденным:
# прогон на роутере не везёт с собой builds/ (194 МБ против 226 МБ в tmpfs),
# и без этой строки два набора отдавали 42 красных «файла нет», маскируя
# настоящие находки.
for test_file in "$TESTS_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue

    suite_name=$(basename "$test_file" .sh)
    case " ${Z2K_SKIP_SUITES:-} " in
        *" $suite_name "*)
            TOTAL_SUITES=$((TOTAL_SUITES + 1))
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
            SKIPPED_SUITES="$SKIPPED_SUITES $suite_name"
            printf '>>> Skipping %s (Z2K_SKIP_SUITES)\n' "$suite_name"
            printf '  [SKIP] набор целиком: в этом окружении проверять нечем\n' >> "$SKIPLOG"
            continue ;;
    esac
    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    printf ">>> Running %s ...\n" "$suite_name"
    printf '%s\n' "----------------------------------------------------"

    _t0=$(date +%s)
    output=$("$Z2K_TEST_SH" "$test_file" 2>&1)
    rc=$?
    _elapsed=$(( $(date +%s) - _t0 ))
    printf '%s\t%s\n' "$_elapsed" "$suite_name" >> "$TIMINGS"

    # Use heredoc to safely print output that may start with dashes
    if [ -n "$output" ]; then
        cat <<Z2KOUT
$output
Z2KOUT
    fi

    # Extract passed/failed counts from the output
    suite_passed=$(printf '%s' "$output" | grep -c '^\[PASS\]')
    suite_failed=$(printf '%s' "$output" | grep -c '^\[FAIL\]')

    # Пропуски СЧИТАЕМ. Раньше грепались только PASS и FAIL, а [SKIP] не
    # попадал ни в счётчик, ни в SUMMARY, ни в код возврата — то есть зелёный
    # прогон одинаково выглядел и когда всё проверено, и когда половина
    # проверок не выполнялась. Набор пропусков при этом РАЗНЫЙ в каждой среде
    # (нет node, нет python3, нет соседнего репозитория с движком), так что
    # никто не мог назвать, что именно проверено в CI. Пропуск — это не
    # «прошло», и теперь он виден.
    suite_skipped=$(printf '%s' "$output" | grep -c '^\[SKIP\]')
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + suite_skipped))
    if [ "$suite_skipped" -gt 0 ]; then
        SKIPPED_SUITES="$SKIPPED_SUITES $suite_name:$suite_skipped"
        printf '%s\n' "$output" | grep '^\[SKIP\]' >> "$SKIPLOG"
    fi

    TOTAL_PASSED=$((TOTAL_PASSED + suite_passed))
    TOTAL_FAILED=$((TOTAL_FAILED + suite_failed))

    if [ "$rc" -ne 0 ]; then
        FAILED_SUITES="$FAILED_SUITES $suite_name"
    fi

    printf "\n"
done

# ==============================================================================
# ACCEPTANCE SPECS (Gherkin)
# ==============================================================================
# Discovered separately because it is not named test_*.sh — and it must run in CI, or the
# feature files become documentation nobody executes. The runner treats an unmapped step and
# a zero-step scenario as FAILURES, so a spec that silently stops checking anything is red.
if [ -f "$TESTS_DIR/bdd.sh" ]; then
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    printf "\n▶ acceptance specs (bdd)\n"
    bdd_out=$("$Z2K_TEST_SH" "$TESTS_DIR/bdd.sh" 2>&1)
    bdd_rc=$?
    bdd_pass=$(printf '%s' "$bdd_out" | sed -n 's/.*BDD: \([0-9]*\) steps passed.*/\1/p')
    bdd_fail=$(printf '%s' "$bdd_out" | sed -n 's/.*steps passed, \([0-9]*\) failed.*/\1/p')
    TOTAL_PASSED=$((TOTAL_PASSED + ${bdd_pass:-0}))
    TOTAL_FAILED=$((TOTAL_FAILED + ${bdd_fail:-0}))
    if [ "$bdd_rc" -ne 0 ]; then
        FAILED_SUITES="$FAILED_SUITES bdd"
        printf '%s\n' "$bdd_out"
    else
        printf "  %s steps passed\n" "${bdd_pass:-0}"
    fi
fi

# ==============================================================================
# SUMMARY
# ==============================================================================

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "  SUMMARY\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Test suites run: %d\n" "$TOTAL_SUITES"
_total_time=$(awk -F'\t' '{s+=$1} END{print s+0}' "$TIMINGS" 2>/dev/null)
printf "Общее время:     %d c\n" "${_total_time:-0}"
_slow=$(sort -rn "$TIMINGS" 2>/dev/null | awk -F'\t' -v b="$SUITE_BUDGET" '$1 >= b {printf "  %4d c  %s\n", $1, $2}')
if [ -n "$_slow" ]; then
    printf "\nНаборы дороже %s c (проверьте, не ждут ли они по часам):\n%s\n" "$SUITE_BUDGET" "$_slow"
fi
printf "Total passed:    %d\n" "$TOTAL_PASSED"
printf "Total failed:    %d\n" "$TOTAL_FAILED"
printf "Total skipped:   %d\n" "$TOTAL_SKIPPED"

if [ -n "$FAILED_SUITES" ]; then
    printf "Failed suites:  %s\n" "$FAILED_SUITES"
fi

# Пропуски печатаем поимённо: «сколько» без «чего именно» ничего не говорит,
# а решение «это законный пропуск или дыра в покрытии» принимается по причине.
if [ "$TOTAL_SKIPPED" -gt 0 ]; then
    printf "\nПропущенные проверки (НЕ засчитаны как пройденные):\n"
    sed 's/^/  /' "$SKIPLOG" 2>/dev/null
    printf "  наборы: %s\n" "$SKIPPED_SUITES"
fi

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

_skip_gate=0
if [ "$Z2K_STRICT_SKIP" = "1" ] && [ "$TOTAL_SKIPPED" -gt 0 ]; then
    _skip_gate=1
    printf "STRICT: пропуски запрещены в этом окружении (Z2K_STRICT_SKIP=1)\n"
fi

if [ "$TOTAL_FAILED" -eq 0 ] && [ -z "$FAILED_SUITES" ] && [ "$_skip_gate" -eq 0 ]; then
    printf "RESULT: ALL TESTS PASSED\n"
    exit 0
else
    printf "RESULT: SOME TESTS FAILED\n"
    exit 1
fi
