#!/bin/sh
# tests/test_utils.sh - Unit tests for lib/utils.sh
# Run: sh tests/test_utils.sh

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

# Source utils.sh (mock functions it depends on)
WORK_DIR="/tmp/z2k_test_$$"
LIB_DIR="${WORK_DIR}/lib"
mkdir -p "$LIB_DIR"

# Load utils
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/utils.sh"

# ==============================================================================
# TEST: safe_config_read
# ==============================================================================

TEST_CONFIG="${WORK_DIR}/test_config"

cat > "$TEST_CONFIG" <<'EOF'
ENABLED=1
DROP_DPI_RST=0
SOME_VALUE="hello world"
QUOTED='single quoted'
SPACED_KEY = value_with_spaces
# COMMENTED=should_not_read
EMPTY_VALUE=
INJECT=1; rm -rf /
EOF

assert_eq "safe_config_read: simple value" \
    "1" "$(safe_config_read "ENABLED" "$TEST_CONFIG")"

assert_eq "safe_config_read: zero value" \
    "0" "$(safe_config_read "DROP_DPI_RST" "$TEST_CONFIG")"

assert_eq "safe_config_read: double quoted" \
    "hello world" "$(safe_config_read "SOME_VALUE" "$TEST_CONFIG")"

assert_eq "safe_config_read: single quoted" \
    "single quoted" "$(safe_config_read "QUOTED" "$TEST_CONFIG")"

assert_eq "safe_config_read: missing key returns default" \
    "mydefault" "$(safe_config_read "NONEXISTENT" "$TEST_CONFIG" "mydefault")"

assert_eq "safe_config_read: missing file returns default" \
    "fallback" "$(safe_config_read "KEY" "/nonexistent/file" "fallback")"

assert_eq "safe_config_read: empty value" \
    "" "$(safe_config_read "EMPTY_VALUE" "$TEST_CONFIG")"

# Injection attempt: should return literal text, not execute
INJECT_VAL=$(safe_config_read "INJECT" "$TEST_CONFIG")
assert_eq "safe_config_read: injection attempt returns literal" \
    "1; rm -rf /" "$INJECT_VAL"

# ==============================================================================
# TEST: map_arch_to_bin_arch
# ==============================================================================

assert_eq "arch: aarch64" "linux-arm64" "$(map_arch_to_bin_arch aarch64)"
assert_eq "arch: armv7l" "linux-arm" "$(map_arch_to_bin_arch armv7l)"
assert_eq "arch: x86_64" "linux-x86_64" "$(map_arch_to_bin_arch x86_64)"
assert_eq "arch: mipsel" "linux-mipsel" "$(map_arch_to_bin_arch mipsel)"
assert_eq "arch: mips64el" "linux-mipsel" "$(map_arch_to_bin_arch mips64el)"
assert_eq "arch: riscv64" "linux-riscv64" "$(map_arch_to_bin_arch riscv64)"

# Unknown arch should return error
map_arch_to_bin_arch "unknown_arch_xyz" >/dev/null 2>&1
assert_eq "arch: unknown returns error" "1" "$?"

# ==============================================================================
# CLEANUP AND REPORT
# ==============================================================================

rm -rf "$WORK_DIR"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
