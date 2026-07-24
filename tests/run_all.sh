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
    printf '%s\n' "----------------------------------------------------"

    output=$(sh "$test_file" 2>&1)
    rc=$?

    # Use heredoc to safely print output that may start with dashes
    if [ -n "$output" ]; then
        cat <<Z2KOUT
$output
Z2KOUT
    fi

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
# ACCEPTANCE SPECS (Gherkin)
# ==============================================================================
# Discovered separately because it is not named test_*.sh — and it must run in CI, or the
# feature files become documentation nobody executes. The runner treats an unmapped step and
# a zero-step scenario as FAILURES, so a spec that silently stops checking anything is red.
if [ -f "$TESTS_DIR/bdd.sh" ]; then
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    printf "\n▶ acceptance specs (bdd)\n"
    bdd_out=$(sh "$TESTS_DIR/bdd.sh" 2>&1)
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
