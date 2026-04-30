#!/bin/sh
# tests/test_inject_z2k_range_rand.sh — repeats=N → repeats=N-M conversion.
# Run: sh tests/test_inject_z2k_range_rand.sh
# POSIX sh compatible (busybox ash).
#
# Regression coverage for the 2026-05-01 fix: outer glob
# `*:repeats=*-*) skip` давал false-positive на токенах с любым другим
# полем содержащим `-` (например `tcp_ts=-1000`). Из-за этого все
# fake-токены с negative tcp_ts никогда не получали randomization.

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

# Local copy — kept in sync with lib/config_official.sh.
inject_z2k_range_rand() {
    local input="$1"
    local token=""
    local out=""
    for token in $input; do
        case "$token" in
            --lua-desync=fake:*|\
            --lua-desync=fakedsplit:*|\
            --lua-desync=fakeddisorder:*|\
            --lua-desync=hostfakesplit:*|\
            --lua-desync=syndata:*)
                case "$token" in
                    *:repeats=*)
                        token=$(printf '%s' "$token" | awk '
                            {
                                n = split($0, parts, ":")
                                for (i = 1; i <= n; i++) {
                                    if (parts[i] ~ /^repeats=[0-9]+$/) {
                                        v = substr(parts[i], 9) + 0
                                        lo = (v - 2 < 1) ? 1 : v - 2
                                        hi = v + 2
                                        parts[i] = "repeats=" lo "-" hi
                                    }
                                }
                                out = parts[1]
                                for (i = 2; i <= n; i++) out = out ":" parts[i]
                                print out
                            }
                        ')
                        ;;
                esac
                ;;
        esac
        out="${out:+$out }$token"
    done
    printf '%s' "$out"
}

printf "\n--- baseline: simple fake with repeats=N ---\n"

# repeats=6 → repeats=4-8
T1="--lua-desync=fake:blob=stun:repeats=6:strategy=1"
R1=$(inject_z2k_range_rand "$T1")
assert_eq "simple: repeats=6 → repeats=4-8" \
    "--lua-desync=fake:blob=stun:repeats=4-8:strategy=1" "$R1"

# repeats=1 → repeats=1-3 (lo clamp to 1)
T2="--lua-desync=fake:blob=stun:repeats=1:strategy=1"
R2=$(inject_z2k_range_rand "$T2")
assert_eq "low edge: repeats=1 → repeats=1-3 (lo clamps to 1)" \
    "--lua-desync=fake:blob=stun:repeats=1-3:strategy=1" "$R2"

printf "\n--- regression 2026-05-01: tcp_ts=-N must NOT trigger 'already-range' skip ---\n"

# Это корень бага. Раньше outer глоб *:repeats=*-* срабатывал на `-` в
# `tcp_ts=-1000` и токен пропускался без randomization'а.
T3="--lua-desync=fake:blob=stun:repeats=6:tcp_ts=-1000:strategy=11"
R3=$(inject_z2k_range_rand "$T3")
assert_contains "tcp_ts=-1000: repeats=6 → repeats=4-8 (was skipped pre-fix)" \
    "repeats=4-8" "$R3"
assert_contains "tcp_ts=-1000: tcp_ts preserved" \
    "tcp_ts=-1000" "$R3"

# Negative tcp_seq with bigger negative
T4="--lua-desync=fake:blob=stun:repeats=8:tcp_seq=-66000:strategy=2"
R4=$(inject_z2k_range_rand "$T4")
assert_contains "tcp_seq=-66000: repeats=8 → repeats=6-10" \
    "repeats=6-10" "$R4"

# ip_autottl with hyphen in range syntax
T5="--lua-desync=fake:blob=stun:repeats=4:ip_autottl=-2,3-20:strategy=3"
R5=$(inject_z2k_range_rand "$T5")
assert_contains "ip_autottl=-2,3-20: repeats=4 → repeats=2-6" \
    "repeats=2-6" "$R5"
assert_contains "ip_autottl: preserved" \
    "ip_autottl=-2,3-20" "$R5"

printf "\n--- idempotency: already-randomized token unchanged ---\n"

# Token with repeats=4-8 (range syntax) должен пройти через awk без изменений.
T6="--lua-desync=fake:blob=stun:repeats=4-8:tcp_ts=-1000:strategy=1"
R6=$(inject_z2k_range_rand "$T6")
assert_eq "idempotent: already-range token unchanged" "$T6" "$R6"

# Двойной прогон.
T7="--lua-desync=fake:blob=stun:repeats=6:strategy=1"
R7a=$(inject_z2k_range_rand "$T7")
R7b=$(inject_z2k_range_rand "$R7a")
assert_eq "idempotent: 2nd pass = 1st pass" "$R7a" "$R7b"

printf "\n--- non-fake families untouched ---\n"

# multisplit, multidisorder без repeats= — пройти без изменений.
T8="--lua-desync=multisplit:pos=1:strategy=4 --lua-desync=multidisorder:pos=midsld:strategy=5"
R8=$(inject_z2k_range_rand "$T8")
assert_eq "non-fake families: passthrough" "$T8" "$R8"

printf "\n--- multi-token with mix of TS and non-TS fakes ---\n"

INPUT_MIX="--lua-desync=fake:blob=A:repeats=6:tcp_ts=-1000:strategy=1 --lua-desync=fake:blob=B:repeats=8:strategy=2 --lua-desync=multisplit:pos=1:strategy=3"
OUT_MIX=$(inject_z2k_range_rand "$INPUT_MIX")
assert_contains "multi: TS-fake repeats=6 → repeats=4-8" "blob=A:repeats=4-8:tcp_ts=-1000" "$OUT_MIX"
assert_contains "multi: non-TS fake repeats=8 → repeats=6-10" "blob=B:repeats=6-10:strategy=2" "$OUT_MIX"
assert_contains "multi: multisplit untouched" "multisplit:pos=1:strategy=3" "$OUT_MIX"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
