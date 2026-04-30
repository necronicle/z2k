#!/bin/sh
# tests/test_rotate_rkn_tcp_ts_slots.sh — rkn_tcp tcp_ts slot rotation.
# Run: sh tests/test_rotate_rkn_tcp_ts_slots.sh
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
        printf "[FAIL] %s:\n  expected: %s\n  actual:   %s\n" "$desc" "$expected" "$actual"
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
            printf "[FAIL] %s: missing '%s'\n" "$desc" "$needle"
            ;;
    esac
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: unexpected '%s'\n" "$desc" "$needle"
            ;;
        *)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
    esac
}

# Local copy — kept in sync with lib/config_official.sh.
rotate_rkn_tcp_ts_slots() {
    local input="$1"
    local out=""
    local token=""
    local strategy_id=""
    local new_ts=""
    for token in $input; do
        case "$token" in
            *:tcp_ts=-1000:*|*:tcp_ts=-1000)
                strategy_id=$(printf '%s' "$token" | sed -n 's/.*:strategy=\([0-9][0-9]*\).*/\1/p')
                case "$strategy_id" in
                    11) new_ts="-43210" ;;
                    24) new_ts="-7777"  ;;
                    28) new_ts="-10000" ;;
                    35) new_ts="-43210" ;;
                    *)  new_ts=""       ;;
                esac
                if [ -n "$new_ts" ]; then
                    token=$(printf '%s' "$token" | sed -e "s/:tcp_ts=-1000:/:tcp_ts=${new_ts}:/g" -e "s/:tcp_ts=-1000\$/:tcp_ts=${new_ts}/")
                fi
                ;;
        esac
        out="${out:+$out }$token"
    done
    printf '%s' "$out"
}

printf "\n--- rotate_rkn_tcp_ts_slots: target slots ---\n"

# Slot 11 → -43210
T11="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:repeats=6:tcp_ts=-1000:strategy=11"
R11=$(rotate_rkn_tcp_ts_slots "$T11")
assert_contains "slot 11: rewritten to -43210" "tcp_ts=-43210" "$R11"
assert_not_contains "slot 11: original -1000 gone" "tcp_ts=-1000" "$R11"

# Slot 24 → -7777
T24="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:repeats=6:tcp_ts=-1000:strategy=24"
R24=$(rotate_rkn_tcp_ts_slots "$T24")
assert_contains "slot 24: rewritten to -7777" "tcp_ts=-7777" "$R24"

# Slot 28 → -10000
T28="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:repeats=6:tcp_ts=-1000:strategy=28"
R28=$(rotate_rkn_tcp_ts_slots "$T28")
assert_contains "slot 28: rewritten to -10000" "tcp_ts=-10000" "$R28"

# Slot 35 → -43210
T35="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:repeats=6:tcp_ts=-1000:strategy=35"
R35=$(rotate_rkn_tcp_ts_slots "$T35")
assert_contains "slot 35: rewritten to -43210" "tcp_ts=-43210" "$R35"

printf "\n--- rotate_rkn_tcp_ts_slots: untouched slots ---\n"

# Slots NOT in rotation must keep -1000
for slot in 1 5 10 12 14 25; do
    T="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:tcp_ts=-1000:strategy=$slot"
    R=$(rotate_rkn_tcp_ts_slots "$T")
    assert_contains "slot $slot: untouched (keeps -1000)" "tcp_ts=-1000" "$R"
done

printf "\n--- rotate_rkn_tcp_ts_slots: edge cases ---\n"

# Token without tcp_ts — passthrough
T_NOTS="--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:strategy=11"
R_NOTS=$(rotate_rkn_tcp_ts_slots "$T_NOTS")
assert_eq "no tcp_ts: passthrough" "$T_NOTS" "$R_NOTS"

# tcp_ts at end of token (no trailing colon)
T_END="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:strategy=11:tcp_ts=-1000"
R_END=$(rotate_rkn_tcp_ts_slots "$T_END")
assert_contains "tcp_ts at end: rewritten" "tcp_ts=-43210" "$R_END"
assert_not_contains "tcp_ts at end: -1000 gone" "tcp_ts=-1000" "$R_END"

# Idempotency: second pass changes nothing
R_IDEM=$(rotate_rkn_tcp_ts_slots "$R11")
assert_eq "idempotent: 2nd pass = 1st pass" "$R11" "$R_IDEM"

# Empty input
R_EMPTY=$(rotate_rkn_tcp_ts_slots "")
assert_eq "empty input: empty output" "" "$R_EMPTY"

# Different value tcp_ts (e.g. -43210 already there) — untouched
T_ALREADY="--lua-desync=fake:payload=tls_client_hello:dir=out:tcp_ts=-43210:strategy=11"
R_ALREADY=$(rotate_rkn_tcp_ts_slots "$T_ALREADY")
assert_eq "non-(-1000) value: passthrough" "$T_ALREADY" "$R_ALREADY"

printf "\n--- rotate_rkn_tcp_ts_slots: multi-token rotator ---\n"

# Realistic mini-rotator: slot 1, 11, 24 in one input. Only 11+24 rotate.
MULTI="--lua-desync=fake:payload=tls_client_hello:dir=out:tcp_ts=-1000:strategy=1 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:tcp_ts=-1000:strategy=11 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:tcp_ts=-1000:strategy=24"
R_MULTI=$(rotate_rkn_tcp_ts_slots "$MULTI")
assert_contains "multi: slot=1 keeps -1000" "tcp_ts=-1000:strategy=1" "$R_MULTI"
assert_contains "multi: slot=11 has -43210" "tcp_ts=-43210:strategy=11" "$R_MULTI"
assert_contains "multi: slot=24 has -7777" "tcp_ts=-7777:strategy=24" "$R_MULTI"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
