#!/bin/sh
# tests/test_inject_cond_tcp_has_ts.sh — cond_tcp_has_ts gating injector.
# Run: sh tests/test_inject_cond_tcp_has_ts.sh
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
            printf "[FAIL] %s: missing '%s' in:\n  %s\n" "$desc" "$needle" "$haystack"
            ;;
    esac
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: unexpected '%s' in:\n  %s\n" "$desc" "$needle" "$haystack"
            ;;
        *)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
    esac
}

count_substring() {
    # Count non-overlapping occurrences of $needle in $haystack
    local needle="$1" haystack="$2"
    local n=0
    while :; do
        case "$haystack" in
            *"$needle"*)
                haystack="${haystack#*"$needle"}"
                n=$((n + 1))
                ;;
            *) break ;;
        esac
    done
    echo "$n"
}

# Local copy — kept in sync with lib/config_official.sh inject_cond_tcp_has_ts.
inject_cond_tcp_has_ts() {
    local input="$1"
    local out=""
    local token=""
    local sid=""
    local strat_ts_map=""
    local cur_sid=""
    local cur_buf_ts=""
    local cur_buf_nots=""
    local cur_ts_count=0
    local cur=""
    local in_ts_map=""
    local t=""
    local twin=""
    local ifs_save=""

    for token in $input; do
        case "$token" in
            *:tcp_ts=*) ;;
            *) continue ;;
        esac
        case "$token" in
            *:cond=cond_tcp_has_ts*) continue ;;
        esac
        case "$token" in
            *:strategy=*)
                sid=$(printf '%s' "$token" | sed -n 's/.*:strategy=\([0-9][0-9]*\).*/\1/p')
                ;;
            *) continue ;;
        esac
        [ -z "$sid" ] && continue
        case " $strat_ts_map " in
            *" $sid:"*)
                cur=$(printf '%s' "$strat_ts_map" | sed -n "s/.* $sid:\([0-9]*\).*/\1/p")
                strat_ts_map=$(printf '%s' "$strat_ts_map" | sed "s/ $sid:[0-9]*/ $sid:$((cur+1))/")
                ;;
            *)
                strat_ts_map="$strat_ts_map $sid:1"
                ;;
        esac
    done

    for token in $input; do
        case "$token" in
            *:strategy=*)
                sid=$(printf '%s' "$token" | sed -n 's/.*:strategy=\([0-9][0-9]*\).*/\1/p')
                ;;
            *)
                if [ -n "$cur_sid" ]; then
                    if [ "$cur_ts_count" -gt 0 ]; then
                        out="${out:+$out }--lua-desync=per_instance_condition:instances=$((2*cur_ts_count)):strategy=$cur_sid"
                        ifs_save="$IFS"
                        IFS='
'
                        for t in $cur_buf_ts; do
                            out="$out ${t}:cond=cond_tcp_has_ts"
                            twin=$(printf '%s' "$t" | sed -e 's/:tcp_ts=[^:]*:/:/g' -e 's/:tcp_ts=[^:]*$//')
                            out="$out ${twin}:cond=cond_tcp_has_ts:cond_neg"
                        done
                        for t in $cur_buf_nots; do out="$out $t"; done
                        IFS="$ifs_save"
                    else
                        ifs_save="$IFS"
                        IFS='
'
                        for t in $cur_buf_nots; do out="${out:+$out }$t"; done
                        IFS="$ifs_save"
                    fi
                    cur_buf_ts=""; cur_buf_nots=""; cur_ts_count=0; cur_sid=""
                fi
                out="${out:+$out }$token"
                continue
                ;;
        esac

        if [ -n "$cur_sid" ] && [ "$sid" != "$cur_sid" ]; then
            if [ "$cur_ts_count" -gt 0 ]; then
                out="${out:+$out }--lua-desync=per_instance_condition:instances=$((2*cur_ts_count)):strategy=$cur_sid"
                ifs_save="$IFS"
                IFS='
'
                for t in $cur_buf_ts; do
                    out="$out ${t}:cond=cond_tcp_has_ts"
                    twin=$(printf '%s' "$t" | sed -e 's/:tcp_ts=[^:]*:/:/g' -e 's/:tcp_ts=[^:]*$//')
                    out="$out ${twin}:cond=cond_tcp_has_ts:cond_neg"
                done
                for t in $cur_buf_nots; do out="$out $t"; done
                IFS="$ifs_save"
            else
                ifs_save="$IFS"
                IFS='
'
                for t in $cur_buf_nots; do out="${out:+$out }$t"; done
                IFS="$ifs_save"
            fi
            cur_buf_ts=""; cur_buf_nots=""; cur_ts_count=0
        fi
        cur_sid="$sid"

        in_ts_map=""
        case " $strat_ts_map " in
            *" $sid:"*) in_ts_map="1" ;;
        esac

        if [ -z "$in_ts_map" ]; then
            cur_buf_nots="${cur_buf_nots:+$cur_buf_nots
}$token"
            continue
        fi

        case "$token" in
            *:cond=cond_tcp_has_ts*)
                cur_buf_nots="${cur_buf_nots:+$cur_buf_nots
}$token"
                continue
                ;;
        esac

        case "$token" in
            *:tcp_ts=*)
                cur_buf_ts="${cur_buf_ts:+$cur_buf_ts
}$token"
                cur_ts_count=$((cur_ts_count + 1))
                ;;
            *)
                cur_buf_nots="${cur_buf_nots:+$cur_buf_nots
}$token"
                ;;
        esac
    done

    if [ -n "$cur_sid" ]; then
        if [ "$cur_ts_count" -gt 0 ]; then
            out="${out:+$out }--lua-desync=per_instance_condition:instances=$((2*cur_ts_count)):strategy=$cur_sid"
            ifs_save="$IFS"
            IFS='
'
            for t in $cur_buf_ts; do
                out="$out ${t}:cond=cond_tcp_has_ts"
                twin=$(printf '%s' "$t" | sed -e 's/:tcp_ts=[^:]*:/:/g' -e 's/:tcp_ts=[^:]*$//')
                out="$out ${twin}:cond=cond_tcp_has_ts:cond_neg"
            done
            for t in $cur_buf_nots; do out="$out $t"; done
            IFS="$ifs_save"
        else
            ifs_save="$IFS"
            IFS='
'
            for t in $cur_buf_nots; do out="${out:+$out }$t"; done
            IFS="$ifs_save"
        fi
    fi

    printf '%s' "$out"
}

# ============================================================================
printf "\n--- single-TS slot (basic case) ---\n"
# ============================================================================

INPUT_S1="--lua-desync=fake:payload=tls_client_hello:tcp_ts=-1000:strategy=11"
OUT_S1=$(inject_cond_tcp_has_ts "$INPUT_S1")

assert_contains "single-TS: per_instance_condition emitted" "per_instance_condition:instances=2:strategy=11" "$OUT_S1"
assert_contains "single-TS: original gets cond" ":tcp_ts=-1000:strategy=11:cond=cond_tcp_has_ts" "$OUT_S1"
assert_contains "single-TS: twin emitted with cond_neg" ":strategy=11:cond=cond_tcp_has_ts:cond_neg" "$OUT_S1"
# Twin must NOT have tcp_ts
TWIN_FROM_S1=$(printf '%s' "$OUT_S1" | tr ' ' '\n' | grep "cond_neg")
assert_not_contains "single-TS: twin has no tcp_ts" "tcp_ts=" "$TWIN_FROM_S1"

# ============================================================================
printf "\n--- multi-TS slot (3 TS-fakes) ---\n"
# ============================================================================

INPUT_M3="--lua-desync=fake:blob=A:tcp_ts=-1000:strategy=12 --lua-desync=fake:blob=B:tcp_ts=-2000:strategy=12 --lua-desync=fake:blob=C:tcp_ts=-3000:strategy=12"
OUT_M3=$(inject_cond_tcp_has_ts "$INPUT_M3")

assert_contains "multi-TS: instances=6 (2*3)" "per_instance_condition:instances=6:strategy=12" "$OUT_M3"
N_COND=$(count_substring ":cond=cond_tcp_has_ts:cond_neg" "$OUT_M3")
assert_eq "multi-TS: 3 cond_neg twins emitted" "3" "$N_COND"
N_PIC=$(count_substring "per_instance_condition" "$OUT_M3")
assert_eq "multi-TS: per_instance_condition emitted ONCE per slot" "1" "$N_PIC"

# ============================================================================
printf "\n--- mixed slot: TS + non-TS (colleague's regression) ---\n"
# ============================================================================

# Реальный паттерн strategy=11 в нашем rkn_tcp Strategy.txt:
# 2 fake+tcp_ts + 1 fakedsplit (non-TS).
INPUT_MIX="--lua-desync=fake:blob=stun:tcp_ts=-43210:strategy=11 --lua-desync=fake:blob=tls_clienthello_www_google_com:tcp_ts=-43210:strategy=11 --lua-desync=fakedsplit:pos=1:strategy=11"
OUT_MIX=$(inject_cond_tcp_has_ts "$INPUT_MIX")

assert_contains "mix: instances=4 (2 TS pairs)" "per_instance_condition:instances=4:strategy=11" "$OUT_MIX"
assert_contains "mix: fakedsplit preserved" "fakedsplit:pos=1:strategy=11" "$OUT_MIX"
# Critical: fakedsplit MUST come AFTER all conditional pairs (i.e. AFTER position
# of last cond_neg twin). Else it falls inside instances=4 window и попадёт под
# "no cond → skipping" в zapret-auto.lua:489-491. Это и есть colleague's
# regression test на subtle bug.
LAST_TWIN_POS=$(printf '%s' "$OUT_MIX" | awk -v RS=' ' '/cond_neg/{p=NR} END{print p}')
FAKEDSPLIT_POS=$(printf '%s' "$OUT_MIX" | awk -v RS=' ' '/fakedsplit/{print NR; exit}')
if [ "$FAKEDSPLIT_POS" -gt "$LAST_TWIN_POS" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "[PASS] mix: fakedsplit lands AFTER conditional window (pos %s > last twin pos %s)\n" \
        "$FAKEDSPLIT_POS" "$LAST_TWIN_POS"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "[FAIL] mix: fakedsplit position %s NOT after last twin position %s — regression!\n" \
        "$FAKEDSPLIT_POS" "$LAST_TWIN_POS"
fi

# Fakedsplit MUST NOT have cond — otherwise per_instance_condition would
# try to gate it (it shouldn't, but defense-in-depth).
FAKEDSPLIT_TOKEN=$(printf '%s' "$OUT_MIX" | tr ' ' '\n' | grep "fakedsplit")
assert_not_contains "mix: fakedsplit has no cond decoration" "cond=" "$FAKEDSPLIT_TOKEN"

# ============================================================================
printf "\n--- non-TS-only slot (passthrough) ---\n"
# ============================================================================

INPUT_NTS="--lua-desync=multisplit:pos=1:strategy=4 --lua-desync=fakedsplit:pos=2:strategy=4"
OUT_NTS=$(inject_cond_tcp_has_ts "$INPUT_NTS")

assert_eq "non-TS slot: passthrough unchanged" "$INPUT_NTS" "$OUT_NTS"
assert_not_contains "non-TS slot: no per_instance_condition" "per_instance_condition" "$OUT_NTS"

# ============================================================================
printf "\n--- pre-strategy tokens (circular header) preserved ---\n"
# ============================================================================

INPUT_HDR="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:tcp_ts=-1000:strategy=1"
OUT_HDR=$(inject_cond_tcp_has_ts "$INPUT_HDR")

assert_contains "header: --filter-tcp preserved" "--filter-tcp=443" "$OUT_HDR"
assert_contains "header: --lua-desync=circular preserved" "--lua-desync=circular:fails=3:key=rkn_tcp:nld=2" "$OUT_HDR"
# Critical: per_instance_condition must come AFTER circular header but BEFORE
# the strategy=1 instance.
PIC_POS_HDR=$(printf '%s' "$OUT_HDR" | awk -v RS=' ' '/per_instance_condition/{print NR; exit}')
CIRC_POS_HDR=$(printf '%s' "$OUT_HDR" | awk -v RS=' ' '/circular:fails/{print NR; exit}')
S1_POS=$(printf '%s' "$OUT_HDR" | awk -v RS=' ' '/cond=cond_tcp_has_ts$/{print NR; exit}')
if [ "$PIC_POS_HDR" -gt "$CIRC_POS_HDR" ] && [ "$PIC_POS_HDR" -lt "$S1_POS" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "[PASS] header: per_instance_condition between circular and TS-instance\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "[FAIL] header: ordering wrong (pic=%s circ=%s s1=%s)\n" "$PIC_POS_HDR" "$CIRC_POS_HDR" "$S1_POS"
fi

# ============================================================================
printf "\n--- multi-slot input ---\n"
# ============================================================================

INPUT_MULTI="--lua-desync=fake:tcp_ts=-1000:strategy=1 --lua-desync=fake:tcp_ts=-1000:strategy=2 --lua-desync=multisplit:pos=1:strategy=3 --lua-desync=fake:tcp_ts=-2000:strategy=4 --lua-desync=fake:tcp_ts=-3000:strategy=4"
OUT_MULTI=$(inject_cond_tcp_has_ts "$INPUT_MULTI")

assert_contains "multi: slot=1 has per_instance_condition" "per_instance_condition:instances=2:strategy=1" "$OUT_MULTI"
assert_contains "multi: slot=2 has per_instance_condition" "per_instance_condition:instances=2:strategy=2" "$OUT_MULTI"
assert_contains "multi: slot=4 has per_instance_condition (instances=4)" "per_instance_condition:instances=4:strategy=4" "$OUT_MULTI"
assert_not_contains "multi: slot=3 (non-TS) has NO per_instance_condition" "per_instance_condition:instances=0" "$OUT_MULTI"
assert_not_contains "multi: slot=3 (non-TS) has NO per_instance_condition strategy=3" "per_instance_condition:instances=2:strategy=3" "$OUT_MULTI"
# slot 3 multisplit must remain unchanged (no cond decoration)
MULTISPLIT_TOK=$(printf '%s' "$OUT_MULTI" | tr ' ' '\n' | grep "multisplit:pos=1:strategy=3")
assert_not_contains "multi: slot=3 multisplit untouched" "cond" "$MULTISPLIT_TOK"

# Strategy ID preservation: input had {1,2,3,4}, output must have all.
for s in 1 2 3 4; do
    assert_contains "multi: strategy=$s preserved" "strategy=$s" "$OUT_MULTI"
done

# ============================================================================
printf "\n--- idempotency ---\n"
# ============================================================================

OUT_RUN1=$(inject_cond_tcp_has_ts "$INPUT_MIX")
OUT_RUN2=$(inject_cond_tcp_has_ts "$OUT_RUN1")
assert_eq "idempotency: 2nd pass = 1st pass" "$OUT_RUN1" "$OUT_RUN2"

# ============================================================================
printf "\n--- edge: tcp_ts at end of token (no trailing colon) ---\n"
# ============================================================================

INPUT_END="--lua-desync=fake:strategy=11:tcp_ts=-1000"
OUT_END=$(inject_cond_tcp_has_ts "$INPUT_END")
assert_contains "tcp_ts-at-end: cond appended" ":tcp_ts=-1000:cond=cond_tcp_has_ts" "$OUT_END"
TWIN_END=$(printf '%s' "$OUT_END" | tr ' ' '\n' | grep "cond_neg")
assert_not_contains "tcp_ts-at-end: twin has no tcp_ts" "tcp_ts=" "$TWIN_END"

# ============================================================================
printf "\n--- edge: hostfakesplit with tcp_ts ---\n"
# ============================================================================

# В Strategy.txt 2 hostfakesplit-токена с tcp_ts. Нужно покрыть.
INPUT_HFS="--lua-desync=hostfakesplit:host=ozon.ru:tcp_ts=-1000:badsum:strategy=37"
OUT_HFS=$(inject_cond_tcp_has_ts "$INPUT_HFS")
assert_contains "hostfakesplit: cond appended" "hostfakesplit:host=ozon.ru:tcp_ts=-1000:badsum:strategy=37:cond=cond_tcp_has_ts" "$OUT_HFS"
assert_contains "hostfakesplit: per_instance_condition emitted" "per_instance_condition:instances=2:strategy=37" "$OUT_HFS"
TWIN_HFS=$(printf '%s' "$OUT_HFS" | tr ' ' '\n' | grep "cond_neg")
assert_contains "hostfakesplit: twin retains host=ozon.ru" "host=ozon.ru" "$TWIN_HFS"
assert_contains "hostfakesplit: twin retains badsum" "badsum" "$TWIN_HFS"
assert_not_contains "hostfakesplit: twin has no tcp_ts" "tcp_ts=" "$TWIN_HFS"

# ============================================================================
printf "\n--- edge: empty input ---\n"
# ============================================================================

OUT_EMPTY=$(inject_cond_tcp_has_ts "")
assert_eq "empty input: empty output" "" "$OUT_EMPTY"

# ============================================================================
printf "\n--- edge: token without strategy= ---\n"
# ============================================================================

# luaexec / per_instance_condition / circular header — нет strategy=N. Проходят
# через injector неизменными (закрывают группу но не buffer'ятся в неё).
INPUT_NO_STRAT="--filter-tcp=443 --lua-desync=fake:tcp_ts=-1000:strategy=1 --lua-desync=luaexec:code=foo"
OUT_NO_STRAT=$(inject_cond_tcp_has_ts "$INPUT_NO_STRAT")
assert_contains "no-strategy token: passes through" "luaexec:code=foo" "$OUT_NO_STRAT"

# ============================================================================
printf "\n--- safety: every tcp_ts has cond=cond_tcp_has_ts ---\n"
# ============================================================================

# Realistic-ish multi-slot input mirroring Strategy.txt structure.
INPUT_REAL="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:tcp_ts=-1000:strategy=1 --lua-desync=fake:tcp_ts=-43210:strategy=11 --lua-desync=fake:tcp_ts=-43210:strategy=11 --lua-desync=fakedsplit:pos=1:strategy=11 --lua-desync=fake:tcp_ts=-7777:strategy=24 --lua-desync=hostfakesplit:host=ozon.ru:tcp_ts=-100000:badsum:strategy=37"
OUT_REAL=$(inject_cond_tcp_has_ts "$INPUT_REAL")

# Every original tcp_ts token should now end with cond=cond_tcp_has_ts (NOT cond_neg).
# Walk tokens, find those with tcp_ts, ensure they have cond=cond_tcp_has_ts AND not :cond_neg
NAKED_TS=0
for tok in $OUT_REAL; do
    case "$tok" in
        *":tcp_ts="*)
            case "$tok" in
                *":cond=cond_tcp_has_ts"*) ;;
                *) NAKED_TS=$((NAKED_TS + 1)) ;;
            esac
            ;;
    esac
done
assert_eq "safety: no naked tcp_ts (every TS-token has cond)" "0" "$NAKED_TS"

# ============================================================================
printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
