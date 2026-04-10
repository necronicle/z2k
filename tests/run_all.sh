#!/bin/sh
# tests/run_all.sh - Test runner for z2k integration tests
# Run: sh tests/run_all.sh
# POSIX sh compatible (busybox ash).

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SUITES=0
FAILED_SUITES=""

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "  z2k Integration Test Suite\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

for test_file in "$TESTS_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue

    suite_name=$(basename "$test_file" .sh)
    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    printf ">>> Running %s ...\n" "$suite_name"
    printf "----------------------------------------------------\n"

    output=$(sh "$test_file" 2>&1)
    rc=$?

    printf "%s\n" "$output"

    # Extract passed/failed counts from the output
    suite_passed=$(printf '%s' "$output" | grep -c '^\[PASS\]')
    suite_failed=$(printf '%s' "$output" | grep -c '^\[FAIL\]')

    TOTAL_PASSED=$((TOTAL_PASSED + suite_passed))
    TOTAL_FAILED=$((TOTAL_FAILED + suite_failed))

    if [ "$rc" -ne 0 ]; then
        FAILED_SUITES="$FAILED_SUITES $suite_name"
    fi

    printf "\n"
done

# ==============================================================================
# SUMMARY
# ==============================================================================

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "  SUMMARY\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Test suites run: %d\n" "$TOTAL_SUITES"
printf "Total passed:    %d\n" "$TOTAL_PASSED"
printf "Total failed:    %d\n" "$TOTAL_FAILED"

if [ -n "$FAILED_SUITES" ]; then
    printf "Failed suites:  %s\n" "$FAILED_SUITES"
fi

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

if [ "$TOTAL_FAILED" -eq 0 ] && [ -z "$FAILED_SUITES" ]; then
    printf "RESULT: ALL TESTS PASSED\n"
    exit 0
else
    printf "RESULT: SOME TESTS FAILED\n"
    exit 1
fi
