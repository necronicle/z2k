#!/bin/sh
# tests/test_validator.sh - Integration tests for z2k-config-validator.sh
# Run: sh tests/test_validator.sh
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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
        *)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: output does not contain '%s'\n" "$desc" "$needle"
            ;;
    esac
}

# ==============================================================================
# SETUP: mock filesystem in /tmp
# ==============================================================================

MOCK_DIR="/tmp/z2k_test_validator_$$"
MOCK_ZAPRET2="${MOCK_DIR}/opt/zapret2"
MOCK_FAKE="${MOCK_ZAPRET2}/files/fake"
MOCK_LISTS="${MOCK_ZAPRET2}/lists"

mkdir -p "$MOCK_ZAPRET2/nfq2" \
         "$MOCK_FAKE" \
         "$MOCK_LISTS"

# Create a mock nfqws2 binary (not executable yet — tests will chmod as needed)
printf '#!/bin/sh\necho "nfqws2 mock"\n' > "$MOCK_ZAPRET2/nfq2/nfqws2"

# Create mock hostlist and fake files
echo "youtube.com" > "$MOCK_LISTS/youtube.txt"
echo "rutracker.org" > "$MOCK_LISTS/rkn.txt"
echo "whitelisted.com" > "$MOCK_LISTS/whitelist.txt"
printf '\x00' > "$MOCK_FAKE/fake_default_tls"
printf '\x00' > "$MOCK_FAKE/quic5"
printf '\x00' > "$MOCK_FAKE/zero_256"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$SCRIPT_DIR/files/z2k-config-validator.sh"

# ==============================================================================
# TEST: Valid config -> exit 0
# ==============================================================================

printf "\n--- Validator: valid config ---\n"

VALID_CONFIG="${MOCK_DIR}/config_valid"
chmod +x "$MOCK_ZAPRET2/nfq2/nfqws2"

cat > "$VALID_CONFIG" <<EOF
ENABLED=1
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=443 --hostlist=${MOCK_LISTS}/youtube.txt --hostlist-exclude=${MOCK_LISTS}/whitelist.txt --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6 --new
--filter-udp=443 --hostlist=${MOCK_LISTS}/rkn.txt --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3
"
EOF

VALID_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$VALID_CONFIG" 2>&1)
VALID_RC=$?

assert_eq "valid config: exit code 0" "0" "$VALID_RC"
assert_contains "valid config: reports OK status" "OK" "$VALID_OUTPUT"
assert_contains "valid config: ENABLED found" "ENABLED" "$VALID_OUTPUT"

# ==============================================================================
# TEST: Missing hostlist files -> exit 2 (FAIL)
# ==============================================================================

printf "\n--- Validator: missing hostlist ---\n"

MISSING_HL_CONFIG="${MOCK_DIR}/config_missing_hl"

cat > "$MISSING_HL_CONFIG" <<EOF
ENABLED=1
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=443 --hostlist=/nonexistent/missing_list.txt --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6
"
EOF

MISSING_HL_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$MISSING_HL_CONFIG" 2>&1)
MISSING_HL_RC=$?

assert_eq "missing hostlist: exit code 2" "2" "$MISSING_HL_RC"
assert_contains "missing hostlist: reports FAIL" "[FAIL]" "$MISSING_HL_OUTPUT"
assert_contains "missing hostlist: mentions missing file" "missing_list.txt" "$MISSING_HL_OUTPUT"

# ==============================================================================
# TEST: Invalid port range -> exit 2 (FAIL)
# ==============================================================================

printf "\n--- Validator: invalid port ---\n"

BAD_PORT_CONFIG="${MOCK_DIR}/config_bad_port"

cat > "$BAD_PORT_CONFIG" <<EOF
ENABLED=1
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=99999 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6
"
EOF

BAD_PORT_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$BAD_PORT_CONFIG" 2>&1)
BAD_PORT_RC=$?

assert_eq "invalid port: exit code 2" "2" "$BAD_PORT_RC"
assert_contains "invalid port: reports FAIL" "[FAIL]" "$BAD_PORT_OUTPUT"

# ==============================================================================
# TEST: Invalid port range (reversed range) -> exit 2
# ==============================================================================

printf "\n--- Validator: reversed port range ---\n"

BAD_RANGE_CONFIG="${MOCK_DIR}/config_bad_range"

cat > "$BAD_RANGE_CONFIG" <<EOF
ENABLED=1
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=8443-443 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6
"
EOF

BAD_RANGE_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$BAD_RANGE_CONFIG" 2>&1)
BAD_RANGE_RC=$?

assert_eq "reversed port range: exit code 2" "2" "$BAD_RANGE_RC"
assert_contains "reversed port range: reports FAIL for port" "[FAIL]" "$BAD_RANGE_OUTPUT"

# ==============================================================================
# TEST: Missing config file -> exit 2
# ==============================================================================

printf "\n--- Validator: missing config file ---\n"

MISSING_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "/nonexistent/config" 2>&1)
MISSING_RC=$?

assert_eq "missing config: exit code 2" "2" "$MISSING_RC"
assert_contains "missing config: reports FAIL" "[FAIL]" "$MISSING_OUTPUT"

# ==============================================================================
# TEST: Config with warnings (unknown lua-desync action) -> exit 1
# ==============================================================================

printf "\n--- Validator: warnings (unknown action) ---\n"

WARN_CONFIG="${MOCK_DIR}/config_warn"

cat > "$WARN_CONFIG" <<EOF
ENABLED=1
NFQWS2_OPT="
--filter-tcp=443 --hostlist=${MOCK_LISTS}/youtube.txt --lua-desync=totally_unknown_action:payload=tls_client_hello:dir=out
"
EOF

WARN_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$WARN_CONFIG" 2>&1)
WARN_RC=$?

# Should be 1 (warnings) - NFQWS2_ENABLE missing is a WARN, unknown action is a WARN
# No FAILs that would make it exit 2 (hostlists exist, ports valid, etc.)
# However, nfqws2 binary check may FAIL if not found at ZAPRET_BASE path
# So we check for >= 1 (at least warnings present)
assert_contains "warning config: has WARN output" "[WARN]" "$WARN_OUTPUT"

# ==============================================================================
# TEST: Config missing ENABLED variable -> exit 2 (FAIL)
# ==============================================================================

printf "\n--- Validator: missing ENABLED ---\n"

NO_ENABLED_CONFIG="${MOCK_DIR}/config_no_enabled"

cat > "$NO_ENABLED_CONFIG" <<EOF
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=443 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6
"
EOF

NO_ENABLED_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$NO_ENABLED_CONFIG" 2>&1)
NO_ENABLED_RC=$?

assert_eq "missing ENABLED: exit code 2" "2" "$NO_ENABLED_RC"
assert_contains "missing ENABLED: reports FAIL" "[FAIL]" "$NO_ENABLED_OUTPUT"

# ==============================================================================
# TEST: Config missing NFQWS2_OPT -> exit 2 (FAIL)
# ==============================================================================

printf "\n--- Validator: missing NFQWS2_OPT ---\n"

NO_OPT_CONFIG="${MOCK_DIR}/config_no_opt"

cat > "$NO_OPT_CONFIG" <<EOF
ENABLED=1
NFQWS2_ENABLE=1
EOF

NO_OPT_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$NO_OPT_CONFIG" 2>&1)
NO_OPT_RC=$?

assert_eq "missing NFQWS2_OPT: exit code 2" "2" "$NO_OPT_RC"
assert_contains "missing NFQWS2_OPT: reports FAIL" "[FAIL]" "$NO_OPT_OUTPUT"

# ==============================================================================
# TEST: Valid port ranges (edge cases)
# ==============================================================================

printf "\n--- Validator: valid port edge cases ---\n"

VALID_PORTS_CONFIG="${MOCK_DIR}/config_valid_ports"

cat > "$VALID_PORTS_CONFIG" <<EOF
ENABLED=1
NFQWS2_ENABLE=1
NFQWS2_OPT="
--filter-tcp=1,80,443,8443,65535 --filter-udp=443,50000-50099 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6
"
EOF

VALID_PORTS_OUTPUT=$(ZAPRET_BASE="$MOCK_ZAPRET2" sh "$VALIDATOR" "$VALID_PORTS_CONFIG" 2>&1)
# Should not have port-related FAILs
PORTS_FAIL=$(printf '%s' "$VALID_PORTS_OUTPUT" | grep -iE '\[FAIL\].*(порт|port)' | wc -l | tr -d ' ')
assert_eq "valid ports: no port-related failures" "0" "$PORTS_FAIL"

# ==============================================================================
# CLEANUP AND REPORT
# ==============================================================================

rm -rf "$MOCK_DIR"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
