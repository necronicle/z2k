#!/bin/sh
# tests/test_init_rst_filter.sh - RST_FILTER mapping in S99zapret2.new
# Run: sh tests/test_init_rst_filter.sh
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "[PASS] %s\n" "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "[FAIL] %s: expected '%s', got '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# Local copy of the init-script mapping. Keep in sync with files/S99zapret2.new.
rst_filter_opt() {
    local RST_FILTER="${1:-0}"
    local NFQWS2_OPT_BASE=""

    case "$RST_FILTER" in
        1|on|true|yes)
            NFQWS2_OPT_BASE="$NFQWS2_OPT_BASE --rst-filter=on"
            ;;
        aggressive|agg|aggro)
            NFQWS2_OPT_BASE="$NFQWS2_OPT_BASE --rst-filter=aggressive"
            ;;
    esac

    printf '%s' "$NFQWS2_OPT_BASE"
}

printf "\n--- S99zapret2 RST_FILTER mapping ---\n"

assert_eq "RST_FILTER unset/default: no --rst-filter" "" "$(rst_filter_opt "")"
assert_eq "RST_FILTER=0: no --rst-filter" "" "$(rst_filter_opt "0")"
assert_eq "RST_FILTER=off: no --rst-filter" "" "$(rst_filter_opt "off")"
assert_eq "RST_FILTER=1: on" " --rst-filter=on" "$(rst_filter_opt "1")"
assert_eq "RST_FILTER=on: on" " --rst-filter=on" "$(rst_filter_opt "on")"
assert_eq "RST_FILTER=yes: on" " --rst-filter=on" "$(rst_filter_opt "yes")"
assert_eq "RST_FILTER=aggressive: aggressive" " --rst-filter=aggressive" "$(rst_filter_opt "aggressive")"
assert_eq "RST_FILTER=agg: aggressive" " --rst-filter=aggressive" "$(rst_filter_opt "agg")"
assert_eq "RST_FILTER=aggro: aggressive" " --rst-filter=aggressive" "$(rst_filter_opt "aggro")"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
