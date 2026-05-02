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
                    # Shifted +1 после strategy=1 prepend (Phase 1.1).
                    12) new_ts="-43210"  ;;
                    16) new_ts="-100000" ;;
                    19) new_ts="-500000" ;;
                    24) new_ts="-43210"  ;;
                    25) new_ts="-7777"   ;;
                    29) new_ts="-10000"  ;;
                    31) new_ts="-7777"   ;;
                    36) new_ts="-43210"  ;;
                    38) new_ts="-100000" ;;
                    43) new_ts="-10000"  ;;
                    # New rotated slots (Phase 1.3).
                    26) new_ts="-43210"  ;;
                    27) new_ts="-10000"  ;;
                    39) new_ts="-7777"   ;;
                    41) new_ts="-100000" ;;
                    *)  new_ts=""        ;;
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

# slot → expected_value map (must match lib/config_official.sh)
# Format: "slot:expected" pairs — drives both positive assertions and the
# multi-token integration test below.
TARGET_SLOTS="12:-43210 16:-100000 19:-500000 24:-43210 25:-7777 29:-10000 31:-7777 36:-43210 38:-100000 43:-10000 26:-43210 27:-10000 39:-7777 41:-100000"

for pair in $TARGET_SLOTS; do
    slot=$(printf '%s' "$pair" | cut -d: -f1)
    want=$(printf '%s' "$pair" | cut -d: -f2)
    T="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:repeats=6:tcp_ts=-1000:strategy=$slot"
    R=$(rotate_rkn_tcp_ts_slots "$T")
    assert_contains "slot $slot: rewritten to $want" "tcp_ts=$want" "$R"
    # Check `tcp_ts=-1000:` (with trailing colon) — needed because some
    # rewrite values like -10000 / -100000 contain `-1000` as a prefix
    # substring. The `:` boundary disambiguates a leftover original from
    # a substring match inside the new value.
    assert_not_contains "slot $slot: original -1000 gone" "tcp_ts=-1000:" "$R"
done

# Keep R12 alias for downstream idempotency assertion below.
# (12 = post-shift первый ротируемый slot, бывший 11.)
R12=$(rotate_rkn_tcp_ts_slots "--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:repeats=6:tcp_ts=-1000:strategy=12")

printf "\n--- rotate_rkn_tcp_ts_slots: untouched slots ---\n"

# Slots NOT in rotation must keep -1000. После Phase 1.1 shift и Phase 1.3
# expansion: новый strategy=1 (rndsni+padencap) untouched by design,
# плюс post-shift пары которые НЕ попали в rotation map.
# Pre-shift untouched-list был {1,5,10,14,25,26,38,39,40,43}.
# После shift +1: {2,6,11,15,26,27,39,40,41,44}.
# Из них 26/27/39/41 теперь ротируемые → убраны.
# Final untouched: {1,2,6,11,15,40,44}.
for slot in 1 2 6 11 15 40 44; do
    T="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:tcp_ts=-1000:strategy=$slot"
    R=$(rotate_rkn_tcp_ts_slots "$T")
    assert_contains "slot $slot: untouched (keeps -1000)" "tcp_ts=-1000" "$R"
done

printf "\n--- rotate_rkn_tcp_ts_slots: edge cases ---\n"

# Token without tcp_ts — passthrough (slot 12 = post-shift первый ротируемый).
T_NOTS="--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:strategy=12"
R_NOTS=$(rotate_rkn_tcp_ts_slots "$T_NOTS")
assert_eq "no tcp_ts: passthrough" "$T_NOTS" "$R_NOTS"

# tcp_ts at end of token (no trailing colon)
T_END="--lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:strategy=12:tcp_ts=-1000"
R_END=$(rotate_rkn_tcp_ts_slots "$T_END")
assert_contains "tcp_ts at end: rewritten" "tcp_ts=-43210" "$R_END"
assert_not_contains "tcp_ts at end: -1000 gone" "tcp_ts=-1000" "$R_END"

# Idempotency: second pass changes nothing
R_IDEM=$(rotate_rkn_tcp_ts_slots "$R12")
assert_eq "idempotent: 2nd pass = 1st pass" "$R12" "$R_IDEM"

# Empty input
R_EMPTY=$(rotate_rkn_tcp_ts_slots "")
assert_eq "empty input: empty output" "" "$R_EMPTY"

# Different value tcp_ts (e.g. -43210 already there) — untouched
T_ALREADY="--lua-desync=fake:payload=tls_client_hello:dir=out:tcp_ts=-43210:strategy=12"
R_ALREADY=$(rotate_rkn_tcp_ts_slots "$T_ALREADY")
assert_eq "non-(-1000) value: passthrough" "$T_ALREADY" "$R_ALREADY"

printf "\n--- rotate_rkn_tcp_ts_slots: multi-token rotator ---\n"

# Realistic mini-rotator after Phase 1.1 shift + Phase 1.3 expansion.
# Slot=1 — новый rndsni+padencap (untouched by design).
# Slots 12/16/25/38/43 — post-shift rotated (бывшие 11/15/24/37/42).
# Slot 26 — новый ротируемый (Phase 1.3 expansion).
MULTI="--lua-desync=fake:payload=tls_client_hello:dir=out:tcp_ts=-1000:strategy=1 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:tcp_ts=-1000:strategy=12 --lua-desync=fake:payload=tls_client_hello:dir=out:host=ya.ru:tcp_ts=-1000:strategy=16 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:tcp_ts=-1000:strategy=25 --lua-desync=hostfakesplit:payload=tls_client_hello:dir=out:host=ozon.ru:tcp_ts=-1000:strategy=38 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:tcp_ts=-1000:strategy=43 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:tcp_ts=-1000:strategy=26"
R_MULTI=$(rotate_rkn_tcp_ts_slots "$MULTI")
assert_contains "multi: slot=1 keeps -1000"   "tcp_ts=-1000:strategy=1"    "$R_MULTI"
assert_contains "multi: slot=12 has -43210"   "tcp_ts=-43210:strategy=12"  "$R_MULTI"
assert_contains "multi: slot=16 has -100000"  "tcp_ts=-100000:strategy=16" "$R_MULTI"
assert_contains "multi: slot=25 has -7777"    "tcp_ts=-7777:strategy=25"   "$R_MULTI"
assert_contains "multi: slot=38 has -100000"  "tcp_ts=-100000:strategy=38" "$R_MULTI"
assert_contains "multi: slot=43 has -10000"   "tcp_ts=-10000:strategy=43"  "$R_MULTI"
assert_contains "multi: slot=26 has -43210 (new rotated)" "tcp_ts=-43210:strategy=26" "$R_MULTI"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
