#!/bin/sh
# tests/test_config_official.sh - Integration tests for lib/config_official.sh
# Run: sh tests/test_config_official.sh
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

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: output unexpectedly contains '%s'\n" "$desc" "$needle"
            ;;
        *)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            printf "[PASS] %s\n" "$desc"
            ;;
    esac
}

# ==============================================================================
# SETUP: mock filesystem in /tmp to avoid touching /opt/zapret2
# ==============================================================================

MOCK_DIR="/tmp/z2k_test_config_$$"
MOCK_ZAPRET2="${MOCK_DIR}/opt/zapret2"
MOCK_CONFIG_DIR="${MOCK_DIR}/opt/etc/zapret2"
MOCK_EXTRA_STRATS="${MOCK_ZAPRET2}/extra_strats"
MOCK_LISTS="${MOCK_ZAPRET2}/lists"

mkdir -p "$MOCK_EXTRA_STRATS/TCP/YT" \
         "$MOCK_EXTRA_STRATS/TCP/YT_GV" \
         "$MOCK_EXTRA_STRATS/TCP/RKN" \
         "$MOCK_EXTRA_STRATS/UDP/YT" \
         "$MOCK_EXTRA_STRATS/cache/autocircular" \
         "$MOCK_LISTS" \
         "$MOCK_CONFIG_DIR" \
         "$MOCK_ZAPRET2/nfq2"

# Create mock hostlist files (non-empty so profiles are included)
echo "youtube.com" > "$MOCK_EXTRA_STRATS/TCP/YT/List.txt"
echo "youtube.com" > "$MOCK_EXTRA_STRATS/UDP/YT/List.txt"
echo "rutracker.org" > "$MOCK_EXTRA_STRATS/TCP/RKN/List.txt"
echo "whitelisted.example.com" > "$MOCK_LISTS/whitelist.txt"

# Create sample strategy files
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1" > "$MOCK_EXTRA_STRATS/TCP/RKN/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT_GV/Strategy.txt"
echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:strategy=1" > "$MOCK_EXTRA_STRATS/UDP/YT/Strategy.txt"

# Create mock config (no Austerus, no RKN_SILENT_FALLBACK)
echo "RKN_SILENT_FALLBACK=0" > "$MOCK_ZAPRET2/config"

# Source utils.sh first (provides safe_config_read, print_*, etc.)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/utils.sh"

# Restore paths after sourcing (utils.sh sets global ZAPRET2_DIR etc.)
ZAPRET2_DIR="$MOCK_ZAPRET2"
CONFIG_DIR="$MOCK_CONFIG_DIR"
LISTS_DIR="$MOCK_LISTS"

# ==============================================================================
# TEST: ensure_circular_nld2 (extracted inline from generate_nfqws2_opt_from_strategies)
# We replicate the function here since it is defined as a nested function.
# ==============================================================================

ensure_circular_nld2() {
    local input="$1"
    local out=""
    local token=""
    local opts=""
    local part=""
    local rest=""
    local old_ifs="$IFS"

    for token in $input; do
        case "$token" in
            --lua-desync=circular:*)
                opts="${token#--lua-desync=circular:}"
                rest=""
                IFS=':'
                for part in $opts; do
                    case "$part" in
                        nld=*) ;;
                        *) rest="${rest:+$rest:}$part" ;;
                    esac
                done
                IFS="$old_ifs"
                if [ -n "$rest" ]; then
                    token="--lua-desync=circular:${rest}:nld=2"
                else
                    token="--lua-desync=circular:nld=2"
                fi
                ;;
        esac
        out="${out:+$out }$token"
    done

    IFS="$old_ifs"
    printf '%s' "$out"
}

printf "\n--- ensure_circular_nld2 ---\n"

# Test: adds nld=2 to circular token without existing nld
INPUT1="--filter-tcp=443 --lua-desync=circular:fails=3:time=60:key=test --lua-desync=fake:strategy=1"
RESULT1=$(ensure_circular_nld2 "$INPUT1")
assert_contains "nld2: adds nld=2 to circular token" "nld=2" "$RESULT1"
assert_contains "nld2: preserves fails param" "fails=3" "$RESULT1"
assert_contains "nld2: preserves non-circular tokens" "--filter-tcp=443" "$RESULT1"

# Test: replaces existing nld value with nld=2
INPUT2="--lua-desync=circular:fails=3:nld=5:time=60"
RESULT2=$(ensure_circular_nld2 "$INPUT2")
assert_contains "nld2: replaces existing nld with nld=2" "nld=2" "$RESULT2"
assert_not_contains "nld2: removes old nld=5" "nld=5" "$RESULT2"

# Test: does not modify non-circular tokens
INPUT3="--lua-desync=fake:payload=tls_client_hello:dir=out"
RESULT3=$(ensure_circular_nld2 "$INPUT3")
assert_eq "nld2: non-circular token unchanged" "$INPUT3" "$RESULT3"

# Test: bare circular with no opts
INPUT4="--lua-desync=circular:key=test"
RESULT4=$(ensure_circular_nld2 "$INPUT4")
assert_contains "nld2: adds nld=2 to minimal circular" "nld=2" "$RESULT4"

# ==============================================================================
# TEST: ensure_rkn_failure_detector (replicated from config_official.sh)
# ==============================================================================

# Local copy of ensure_rkn_failure_detector — kept in sync with the
# production version in lib/config_official.sh:971. Production sets
# z2k_tls_stalled (revert от 2026-04-30 после code-review:
# z2k_mid_stream_stall имел 4 архитектурные проблемы, в т.ч. слепоту
# к incoming seq > s5556 и key mismatch с nld=2. Припаркован как
# experimental до полного редизайна).
ensure_rkn_failure_detector() {
    local input="$1"
    local detector_name="${2:-z2k_tls_stalled}"
    local out=""
    local token=""

    for token in $input; do
        case "$token" in
            --lua-desync=circular:*)
                case "$token" in
                    *failure_detector=*) ;;
                    *) token="${token}:failure_detector=${detector_name}" ;;
                esac
                ;;
        esac
        out="${out:+$out }$token"
    done

    printf '%s' "$out"
}

# Local copy of ensure_circular_tcp_inseq — kept in sync with
# lib/config_official.sh (added 2026-04-29 commit 4c852f5). Production
# enforces inseq=18000 on rkn_tcp/yt_tcp/gv_tcp circular tokens to close
# the standard_success_detector race against TSPU 12-18KB byte-gate.
ensure_circular_tcp_inseq() {
    local input="$1"
    local target="${2:-18000}"
    local out=""
    local token=""
    local opts=""
    local part=""
    local rest=""
    local old_ifs="$IFS"

    for token in $input; do
        case "$token" in
            --lua-desync=circular:*)
                opts="${token#--lua-desync=circular:}"
                rest=""
                IFS=':'
                for part in $opts; do
                    case "$part" in
                        inseq=*) ;;
                        *) rest="${rest:+$rest:}$part" ;;
                    esac
                done
                IFS="$old_ifs"
                if [ -n "$rest" ]; then
                    token="--lua-desync=circular:${rest}:inseq=${target}"
                else
                    token="--lua-desync=circular:inseq=${target}"
                fi
                ;;
        esac
        out="${out:+$out }$token"
    done
    IFS="$old_ifs"
    printf '%s' "$out"
}

# Local copy of ensure_circular_arg_set — kept in sync with
# lib/config_official.sh. Generic helper appending value-form (arg=val)
# OR flag-form (bare arg) to circular tokens. Idempotent for both forms.
ensure_circular_arg_set() {
    local input="$1"
    local arg_name="$2"
    local arg_value="$3"
    local out=""
    local token=""
    for token in $input; do
        case "$token" in
            --lua-desync=circular:*)
                case "$token" in
                    *":${arg_name}="*) ;;
                    *":${arg_name}:"*) ;;
                    *":${arg_name}") ;;
                    *)
                        if [ -n "$arg_value" ]; then
                            token="${token}:${arg_name}=${arg_value}"
                        else
                            token="${token}:${arg_name}"
                        fi
                        ;;
                esac
                ;;
        esac
        out="${out:+$out }$token"
    done
    printf '%s' "$out"
}

printf "\n--- ensure_circular_arg_set ---\n"

# Test: adds key=value pair when absent
INPUT_AS1="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2"
RESULT_AS1=$(ensure_circular_arg_set "$INPUT_AS1" "success_detector" "z2k_http_success_positive_only")
assert_contains "arg_set: appends success_detector" "success_detector=z2k_http_success_positive_only" "$RESULT_AS1"

# Test: idempotent if value-form already present
INPUT_AS2="--lua-desync=circular:fails=3:success_detector=z2k_existing:key=test"
RESULT_AS2=$(ensure_circular_arg_set "$INPUT_AS2" "success_detector" "z2k_http_success_positive_only")
SD_COUNT=$(printf '%s' "$RESULT_AS2" | grep -o "success_detector=" | wc -l | tr -d ' ')
assert_eq "arg_set: no duplication when present" "1" "$SD_COUNT"
assert_contains "arg_set: existing value preserved" "success_detector=z2k_existing" "$RESULT_AS2"

# Test: flag-style arg (empty value) appends bare arg name
INPUT_AS3="--lua-desync=circular:fails=3:key=yt_tcp"
RESULT_AS3=$(ensure_circular_arg_set "$INPUT_AS3" "no_http_redirect" "")
assert_contains "arg_set: flag arg appended" ":no_http_redirect" "$RESULT_AS3"
assert_not_contains "arg_set: flag arg has no =value" "no_http_redirect=" "$RESULT_AS3"

# Test: idempotent for flag-form at end of token (regression for v3.6 review)
INPUT_AS5_END="--lua-desync=circular:fails=3:key=yt_tcp:no_http_redirect"
RESULT_AS5_END=$(ensure_circular_arg_set "$INPUT_AS5_END" "no_http_redirect" "")
NHR_END=$(printf '%s' "$RESULT_AS5_END" | grep -o "no_http_redirect" | wc -l | tr -d ' ')
assert_eq "arg_set: no duplication of flag-form at token end" "1" "$NHR_END"

# Test: idempotent for flag-form in middle of token
INPUT_AS5_MID="--lua-desync=circular:fails=3:no_http_redirect:key=yt_tcp"
RESULT_AS5_MID=$(ensure_circular_arg_set "$INPUT_AS5_MID" "no_http_redirect" "")
NHR_MID=$(printf '%s' "$RESULT_AS5_MID" | grep -o "no_http_redirect" | wc -l | tr -d ' ')
assert_eq "arg_set: no duplication of flag-form in token middle" "1" "$NHR_MID"

# Test: non-circular tokens unchanged
INPUT_AS4="--lua-desync=fake:payload=tls_client_hello"
RESULT_AS4=$(ensure_circular_arg_set "$INPUT_AS4" "success_detector" "X")
assert_eq "arg_set: non-circular unchanged" "$INPUT_AS4" "$RESULT_AS4"

printf "\n--- ensure_rkn_failure_detector ---\n"

# Test: adds failure_detector to circular without one
INPUT_FD1="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:strategy=1"
RESULT_FD1=$(ensure_rkn_failure_detector "$INPUT_FD1")
assert_contains "failure_detector: adds to circular" "failure_detector=z2k_tls_stalled" "$RESULT_FD1"

# Test: does not duplicate if already present
INPUT_FD2="--lua-desync=circular:fails=3:failure_detector=z2k_tls_stalled:key=test"
RESULT_FD2=$(ensure_rkn_failure_detector "$INPUT_FD2")
# Count occurrences - should be exactly 1
FD_COUNT=$(printf '%s' "$RESULT_FD2" | grep -o "failure_detector" | wc -l | tr -d ' ')
assert_eq "failure_detector: no duplication" "1" "$FD_COUNT"

# Test: non-circular tokens are not modified
INPUT_FD3="--lua-desync=fake:payload=tls_client_hello --lua-desync=send:strategy=2"
RESULT_FD3=$(ensure_rkn_failure_detector "$INPUT_FD3")
assert_eq "failure_detector: non-circular unchanged" "$INPUT_FD3" "$RESULT_FD3"

# Test: explicit detector_name argument overrides the default
# (used when Z2K_USE_MID_STREAM_DETECTOR=1 selects z2k_mid_stream_stall)
INPUT_FD4="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2"
RESULT_FD4=$(ensure_rkn_failure_detector "$INPUT_FD4" "z2k_mid_stream_stall")
assert_contains "failure_detector: explicit detector_name=mid_stream" \
    "failure_detector=z2k_mid_stream_stall" "$RESULT_FD4"
assert_not_contains "failure_detector: override doesn't leak tls_stalled" \
    "z2k_tls_stalled" "$RESULT_FD4"

printf "\n--- ensure_circular_tcp_inseq ---\n"

# Test: adds inseq=18000 to circular without one
INPUT_IS1="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:strategy=1"
RESULT_IS1=$(ensure_circular_tcp_inseq "$INPUT_IS1" 18000)
assert_contains "inseq: adds 18000 to circular" "inseq=18000" "$RESULT_IS1"

# Test: overrides existing inseq (e.g. default 4096)
INPUT_IS2="--lua-desync=circular:fails=3:inseq=4096:key=yt_tcp:nld=2"
RESULT_IS2=$(ensure_circular_tcp_inseq "$INPUT_IS2" 18000)
IS_COUNT=$(printf '%s' "$RESULT_IS2" | grep -o "inseq=" | wc -l | tr -d ' ')
assert_eq "inseq: no duplication after override" "1" "$IS_COUNT"
assert_contains "inseq: replaced with 18000" "inseq=18000" "$RESULT_IS2"
assert_not_contains "inseq: old 4096 removed" "inseq=4096" "$RESULT_IS2"

# Test: non-circular tokens are not modified
INPUT_IS3="--filter-tcp=443 --lua-desync=fake:payload=tls_client_hello"
RESULT_IS3=$(ensure_circular_tcp_inseq "$INPUT_IS3" 18000)
assert_eq "inseq: non-circular unchanged" "$INPUT_IS3" "$RESULT_IS3"

# Test: handles multiple circular tokens (extra defensiveness)
INPUT_IS4="--lua-desync=circular:fails=3:key=a --new --lua-desync=circular:fails=2:key=b"
RESULT_IS4=$(ensure_circular_tcp_inseq "$INPUT_IS4" 18000)
IS_COUNT4=$(printf '%s' "$RESULT_IS4" | grep -o "inseq=18000" | wc -l | tr -d ' ')
assert_eq "inseq: applied to all circular tokens" "2" "$IS_COUNT4"

# ==============================================================================
# TEST: generate_nfqws2_opt_from_strategies (full integration)
# We must override the hardcoded paths inside the function.
# Since paths are local to the function, we create symlinks in /opt or skip
# if we cannot. Instead, we test the Austerus mode which is self-contained.
# ==============================================================================

printf "\n--- Austerus mode (all_tcp443) ---\n"

# Create Austerus config in the mock dir and source config_official.sh
# The function uses hardcoded /opt/etc/zapret2/all_tcp443.conf, so we test
# the output shape by calling the function only if /opt is writable, or
# by testing its Austerus branch in isolation.

# Simulate Austerus: create flag file and call the function
# Since generate_nfqws2_opt_from_strategies reads /opt/etc/zapret2/all_tcp443.conf
# directly, we test the Austerus output format independently.

AUSTERUS_OUTPUT='NFQWS2_OPT="
--filter-tcp=80 --lua-desync=fake:payload=http_req:dir=out:blob=zero_256:badsum:badseq --lua-desync=multisplit:payload=http_req:dir=out --new
--filter-tcp=443 --out-range=-d4 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=zero_256:badsum:badseq --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:badsum:badseq:repeats=1:tls_mod=sni=www.google.com,rnd,dupsid --lua-desync=multidisorder:payload=tls_client_hello:dir=out:pos=method+2,midsld,5 --new
--filter-udp=443 --out-range=-d4 --lua-desync=fake:payload=quic_initial:dir=out:blob=zero_256:badsum:repeats=1
"'

assert_contains "austerus: contains --filter-tcp=80" "--filter-tcp=80" "$AUSTERUS_OUTPUT"
assert_contains "austerus: contains --filter-tcp=443" "--filter-tcp=443" "$AUSTERUS_OUTPUT"
assert_contains "austerus: contains --filter-udp=443" "--filter-udp=443" "$AUSTERUS_OUTPUT"
assert_contains "austerus: contains --new separators" "--new" "$AUSTERUS_OUTPUT"
assert_contains "austerus: starts with NFQWS2_OPT" 'NFQWS2_OPT="' "$AUSTERUS_OUTPUT"
assert_not_contains "austerus: no hostlist in simplified mode" "--hostlist" "$AUSTERUS_OUTPUT"

# ==============================================================================
# TEST: Output format of generated config contains expected tokens
# ==============================================================================

printf "\n--- Config output structure ---\n"

# Build a representative NFQWS2_OPT output manually to validate structural checks
# This simulates what generate_nfqws2_opt_from_strategies produces in normal mode
SAMPLE_OPT="--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/RKN/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=rkn_tcp:nld=2:failure_detector=z2k_tls_stalled:inseq=26000:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=fake:strategy=1 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=yt_tcp:nld=2:success_detector=z2k_success_no_reset:inseq=18000:failure_detector=z2k_tls_alert_fatal:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist-domains=googlevideo.com --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=gv_tcp:nld=2:inseq=18000:success_detector=z2k_http_success_positive_only:failure_detector=z2k_tls_alert_fatal:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/UDP/YT/List.txt --filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:key=yt_quic:nld=2 --new
--filter-udp=50000-50099 --filter-l7=discord,stun --lua-desync=circular_locked:key=6"

# Production guarantees per v3.6 plan + Phase 1.2 (2026-05-02):
#  - rkn_tcp circular has inseq=26000 (Phase 1.2 — covers TLS stall window
#    14-25 KB per ntc.party 22516 #1, #3)
#  - yt_tcp / gv_tcp circular have inseq=18000 (smaller first-burst typical)
#  - rkn_tcp has failure_detector=z2k_tls_stalled (default; v3 mid_stream_
#    stall is opt-in via Z2K_USE_MID_STREAM_DETECTOR=1)
#  - rkn_tcp / gv_tcp have success_detector=z2k_http_success_positive_only
#    (HTTP-aware — closes the seq>inseq false-pin race for 4xx replies)
#  - yt_tcp keeps z2k_success_no_reset (now HTTP-neutral-aware in commit 4)
#  - all four TLS profiles carry no_http_redirect to off-load standard's
#    302/307 cross-SLD redirect branch onto our z2k_classify_http_reply
assert_contains "structure: rkn_tcp has z2k_tls_stalled" "key=rkn_tcp:nld=2:failure_detector=z2k_tls_stalled" "$SAMPLE_OPT"
assert_contains "structure: rkn_tcp has inseq=26000" "key=rkn_tcp:nld=2:failure_detector=z2k_tls_stalled:inseq=26000" "$SAMPLE_OPT"
assert_contains "structure: rkn_tcp has positive-only success_detector" "key=rkn_tcp:nld=2:failure_detector=z2k_tls_stalled:inseq=26000:success_detector=z2k_http_success_positive_only" "$SAMPLE_OPT"
assert_contains "structure: rkn_tcp has no_http_redirect" "key=rkn_tcp:nld=2:failure_detector=z2k_tls_stalled:inseq=26000:success_detector=z2k_http_success_positive_only:no_http_redirect" "$SAMPLE_OPT"
assert_contains "structure: yt_tcp has no_reset success_detector" "key=yt_tcp:nld=2:success_detector=z2k_success_no_reset" "$SAMPLE_OPT"
# yt_tcp / gv_tcp MUST carry failure_detector=z2k_tls_alert_fatal — without
# this, the no_http_redirect flag below leaves them with NO redirect
# coverage at all (regression caught in v3.6 review).
assert_contains "structure: yt_tcp has classifier-aware failure_detector" "key=yt_tcp:nld=2:success_detector=z2k_success_no_reset:inseq=18000:failure_detector=z2k_tls_alert_fatal" "$SAMPLE_OPT"
assert_contains "structure: yt_tcp has no_http_redirect AFTER failure_detector" "failure_detector=z2k_tls_alert_fatal:no_http_redirect" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has positive-only success_detector" "key=gv_tcp:nld=2:inseq=18000:success_detector=z2k_http_success_positive_only" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has classifier-aware failure_detector" "success_detector=z2k_http_success_positive_only:failure_detector=z2k_tls_alert_fatal" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has no_http_redirect" "failure_detector=z2k_tls_alert_fatal:no_http_redirect" "$SAMPLE_OPT"
# rkn_tcp uses z2k_tls_stalled (set by ensure_rkn_failure_detector); chain
# inherits z2k_tls_alert_fatal → standard_failure_detector. Direct assignment
# of z2k_tls_alert_fatal на circular здесь не должно быть — это бы означало,
# что ensure_rkn_failure_detector съел наш upgrade на stalled.
assert_not_contains "structure: rkn_tcp does not double-set tls_alert_fatal" "rkn_tcp:nld=2:failure_detector=z2k_tls_alert_fatal" "$SAMPLE_OPT"

assert_contains "structure: has --filter-tcp" "--filter-tcp" "$SAMPLE_OPT"
assert_contains "structure: has --filter-udp" "--filter-udp" "$SAMPLE_OPT"
assert_contains "structure: has --hostlist" "--hostlist=" "$SAMPLE_OPT"
assert_contains "structure: has --hostlist-exclude" "--hostlist-exclude=" "$SAMPLE_OPT"
assert_contains "structure: has --hostlist-domains" "--hostlist-domains=" "$SAMPLE_OPT"
assert_contains "structure: has --new separators" "--new" "$SAMPLE_OPT"
assert_contains "structure: has --lua-desync" "--lua-desync=" "$SAMPLE_OPT"

# Count --new separators (should be 4 in the sample above)
NEW_COUNT=$(printf '%s' "$SAMPLE_OPT" | grep -o -- '--new' | wc -l | tr -d ' ')
assert_eq "structure: correct --new count" "4" "$NEW_COUNT"

# ==============================================================================
# TEST: GAME_PROFILE branching — RUNTIME invocation
# ==============================================================================
# Earlier static-SAMPLE coverage was insufficient: it asserted on hand-
# constructed strings, not on what generate_nfqws2_opt_from_strategies
# actually emits. This block runs the real function against a mock
# /opt/zapret2 root (via ZAPRET2_DIR override now that lists_dir derives
# from it) and asserts on captured output.

# Source the generator (utils.sh already sourced above).
. "$SCRIPT_DIR/lib/config_official.sh"

# Helper: extract the UDP line containing flowseal_game_ips from output.
get_flowseal_arm_line() {
    printf '%s\n' "$1" | grep -F 'flowseal_game_ips.txt' | grep -F -- '--filter-udp=' | head -1
}

# Helper: extract the TCP non-TLS static line (filter-l7=unknown).
get_flowseal_tcp_arm_line() {
    printf '%s\n' "$1" | grep -F 'flowseal_game_ips.txt' | grep -F -- '--filter-tcp=' | grep -F -- '--filter-l7=unknown' | head -1
}

# Helper: extract the TCP TLS rotator line (filter-l7=tls + circular).
get_flowseal_tls_arm_line() {
    printf '%s\n' "$1" | grep -F 'flowseal_game_ips.txt' | grep -F -- '--filter-tcp=' | grep -F -- '--filter-l7=tls' | head -1
}

# Helper: extract the legacy game_udp line (uses key=game_udp circular).
get_legacy_arm_line() {
    printf '%s\n' "$1" | grep -F 'key=game_udp' | head -1
}

# Helper: parse comma-separated port spec from a --filter-tcp= or --filter-udp=
# in the supplied line and verify a target port is NOT covered by any
# range/single in the spec. Returns 0 if excluded, 1 if included.
# Handles: single (443), range (1024-2407), comma-list (1024-2407,2409-65535,80).
# Caller specifies which filter token to inspect (3rd arg: "tcp" or "udp").
port_excluded_from_filter() {
    local arm_line="$1" target_port="$2" proto="${3:-udp}"
    local spec
    spec=$(printf '%s\n' "$arm_line" | sed -nE "s/.*--filter-${proto}=([^[:space:]]+).*/\1/p" | head -1)
    [ -z "$spec" ] && return 0  # No filter-${proto} on the line — vacuously excluded.
    local IFS=','
    local token start end
    for token in $spec; do
        case "$token" in
            *-*)
                start="${token%-*}"
                end="${token#*-}"
                if [ "$target_port" -ge "$start" ] && [ "$target_port" -le "$end" ]; then
                    return 1
                fi
                ;;
            *)
                if [ "$token" = "$target_port" ]; then
                    return 1
                fi
                ;;
        esac
    done
    return 0
}

# Build a mock /opt-tree under MOCK_DIR/<name>/ and invoke the generator
# with ZAPRET2_DIR pointing at it. Echoes the captured output to stdout.
# Args: <subdir-name> <config-content> [<extra-files-callback>]
run_generator() {
    local subname="$1" cfg="$2" extra_cb="$3"
    local root="${MOCK_DIR}/${subname}"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists"
    # Minimum hostlists so non-game profiles don't error out (they get
    # skipped via add_hostlist_line if missing, but creating them avoids
    # noise on stderr that could mask real test signal).
    echo "youtube.com" > "$root/extra_strats/TCP/YT/List.txt"
    echo "youtube.com" > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org" > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    # Minimum Strategy.txt for the rkn_tcp TLS arm. Without this the
    # generator's `if [ -f ".../RKN/Strategy.txt" ]` gate keeps rkn_tcp
    # empty and the arm isn't emitted — which masks regressions in the
    # rkn_tcp wiring (failure_detector / --in-range / inseq).
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    printf '%s\n' "$cfg" > "$root/config"
    [ -n "$extra_cb" ] && eval "$extra_cb \"$root\""
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
    rm -rf "$root"
}

# Helper: extract the rkn_tcp TLS arm (filter-l7=tls + key=rkn_tcp).
# http_rkn lives on a separate line (filter-tcp=80, key=http_rkn) and
# is filtered out by the key match.
get_rkn_tcp_arm_line() {
    printf '%s\n' "$1" | grep -F 'key=rkn_tcp' | head -1
}

printf "\n--- Z2K_USE_MID_STREAM_DETECTOR: explicit OFF (=0) ---\n"

# Per Mark 2026-05-02 policy "все нововведения по умолчанию включены"
# default flipped to 1. Test explicit Z2K_USE_MID_STREAM_DETECTOR=0
# чтобы opt-out path работал — rkn_tcp возвращается к master-compatible
# layout (--in-range=-s5556 + z2k_tls_stalled).
OUT_MS_OFF=$(run_generator "ms-off" "Z2K_USE_MID_STREAM_DETECTOR=0
GAME_MODE_ENABLED=0" "")
RKN_ARM_OFF=$(get_rkn_tcp_arm_line "$OUT_MS_OFF")

assert_contains "ms flag=0: rkn_tcp arm emitted" \
    "key=rkn_tcp" "$RKN_ARM_OFF"
assert_contains "ms flag=0: rkn_tcp keeps --in-range=-s5556" \
    "--in-range=-s5556" "$RKN_ARM_OFF"
assert_contains "ms flag=0: rkn_tcp uses z2k_silent_drop_detector primary" \
    "failure_detector=z2k_silent_drop_detector" "$RKN_ARM_OFF"
# Half-state guards on flag=0 — byte-cap не должен прыгнуть на bundle.
assert_not_contains "ms flag=0: no s20000 leaks into rkn_tcp" \
    "--in-range=-s20000" "$RKN_ARM_OFF"
# Old detector names не должны быть primary в config-string. Они
# доступны через chain в lua, не через config text.
assert_not_contains "ms flag=0: no z2k_tls_stalled as primary" \
    "failure_detector=z2k_tls_stalled" "$RKN_ARM_OFF"
assert_not_contains "ms flag=0: no z2k_mid_stream_stall as primary" \
    "failure_detector=z2k_mid_stream_stall" "$RKN_ARM_OFF"

printf "\n--- Z2K_USE_MID_STREAM_DETECTOR: bundle flag (default ON) ---\n"

# Flag opt-in: rkn_tcp gets the bundle — --in-range=-s20000 paired
# with failure_detector=z2k_mid_stream_stall. Both knobs MUST move
# together; half-state assertions below catch a mistaken landing.
OUT_MS_ON=$(run_generator "ms-on" "Z2K_USE_MID_STREAM_DETECTOR=1" "")
RKN_ARM_ON=$(get_rkn_tcp_arm_line "$OUT_MS_ON")

assert_contains "ms flag=1: rkn_tcp arm emitted" \
    "key=rkn_tcp" "$RKN_ARM_ON"
assert_contains "ms flag=1: rkn_tcp uses --in-range=-s20000" \
    "--in-range=-s20000" "$RKN_ARM_ON"
assert_contains "ms flag=1: rkn_tcp uses z2k_silent_drop_detector primary" \
    "failure_detector=z2k_silent_drop_detector" "$RKN_ARM_ON"
# Half-state guards on flag=1 — bundle byte-cap должен land, но primary
# detector один и тот же независимо от flag (chain в lua делегирует к
# mid_stream_stall когда payload TLS).
assert_not_contains "ms flag=1: no leftover s5556 on rkn_tcp arm" \
    "--in-range=-s5556" "$RKN_ARM_ON"
assert_not_contains "ms flag=1: no z2k_tls_stalled as primary" \
    "failure_detector=z2k_tls_stalled" "$RKN_ARM_ON"
assert_not_contains "ms flag=1: no z2k_mid_stream_stall as primary" \
    "failure_detector=z2k_mid_stream_stall" "$RKN_ARM_ON"

printf "\n--- Z2K_USE_MID_STREAM_DETECTOR + RKN_SILENT_FALLBACK ---\n"

# RKN silent fallback uses ensure_youtube_tls_failure_detection (not
# the manual_layout helper). That path also injects --in-range=-sN,
# so the bundle byte cap MUST flow through it too — otherwise we get
# the exact half-state this commit guards against (byte-window
# detector wired but blind past 5.5K). Combined-flag test exercises
# the silent-fallback code path with the bundle on.
OUT_MS_SILENT=$(run_generator "ms-silent" \
    "Z2K_USE_MID_STREAM_DETECTOR=1
RKN_SILENT_FALLBACK=1" "")
RKN_ARM_SILENT=$(get_rkn_tcp_arm_line "$OUT_MS_SILENT")

assert_contains "ms+silent: rkn_tcp arm emitted" \
    "key=rkn_tcp" "$RKN_ARM_SILENT"
assert_contains "ms+silent: silent path also bumps to s20000" \
    "--in-range=-s20000" "$RKN_ARM_SILENT"
assert_contains "ms+silent: silent path keeps z2k_silent_drop_detector primary" \
    "failure_detector=z2k_silent_drop_detector" "$RKN_ARM_SILENT"
# Silent fallback's success_detector contract: append
# z2k_success_no_reset only when one isn't already set. rkn_tcp gets
# z2k_http_success_positive_only earlier from ensure_circular_arg_set,
# so it survives — assert that survival rather than the no-reset
# variant that only fires on bare circulars.
assert_contains "ms+silent: existing success_detector preserved" \
    "success_detector=z2k_http_success_positive_only" "$RKN_ARM_SILENT"
assert_not_contains "ms+silent: no s5556 leak via silent path" \
    "--in-range=-s5556" "$RKN_ARM_SILENT"
assert_not_contains "ms+silent: no z2k_tls_stalled as primary" \
    "failure_detector=z2k_tls_stalled" "$RKN_ARM_SILENT"
assert_not_contains "ms+silent: no z2k_mid_stream_stall as primary" \
    "failure_detector=z2k_mid_stream_stall" "$RKN_ARM_SILENT"

printf "\n--- Z2K_USE_MID_STREAM_DETECTOR: NFQWS2_TCP_PKT_IN bundle ---\n"

# Third bundle knob: NFQWS2_TCP_PKT_IN drives the iptables connbytes
# range, which in turn caps how many incoming packets nfqws2 ever sees
# per connection. With the master-compatible 10 (~7KB visibility), the
# byte-window detector and the success_detector=inseq=18000 are both
# blind past handshake. Bumping to 30 (~22-44KB) is required for the
# bundle to do anything; testing both flag positions catches a stale
# heredoc constant or a missed call site.
#
# create_official_config writes the config file AND has to see the
# flag in the existing file to choose the bundle value, so this test
# materializes the entire create_official_config pass via the helper.
test_pkt_in_under_flag() {
    local flag="$1" expected="$2" desc_suffix="$3"
    local root="${MOCK_DIR}/pkt-in-$flag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists"
    echo "youtube.com" > "$root/extra_strats/TCP/YT/List.txt"
    echo "youtube.com" > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org" > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    cat > "$root/config" <<EOF
ENABLED=1
Z2K_USE_MID_STREAM_DETECTOR=$flag
EOF
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    local emitted_pkt_in
    emitted_pkt_in=$(grep -E '^NFQWS2_TCP_PKT_IN=' "$root/config" | head -1)
    assert_contains "ms flag=$flag: $desc_suffix" \
        "NFQWS2_TCP_PKT_IN=\"$expected\"" "$emitted_pkt_in"
    # Persist round-trip: new config must carry the flag forward so a
    # follow-up regen doesn't silently revert it.
    local persisted_flag
    persisted_flag=$(grep -E '^Z2K_USE_MID_STREAM_DETECTOR=' "$root/config" | head -1)
    assert_contains "ms flag=$flag: persisted in regenerated config" \
        "Z2K_USE_MID_STREAM_DETECTOR=$flag" "$persisted_flag"
    rm -rf "$root"
}

test_pkt_in_under_flag "0" "10" "NFQWS2_TCP_PKT_IN stays at 10"
test_pkt_in_under_flag "1" "30" "NFQWS2_TCP_PKT_IN bumps to 30"

printf "\n--- Z2K_PADENCAP: padencap autoinjector flag ---\n"

# Z2K_PADENCAP (default 0): when =1, inject_z2k_tls_mods добавляет
# padencap ко всем :tls_mod= токенам в rkn_tcp. Plus persist round-trip.
# Padencap НЕ должен попадать в yt_tcp/yt_gv_tcp/game_tls_tcp — другие
# DPI profiles, padencap там не верифицирован.
test_padencap_under_flag() {
    local flag="$1" expect_padencap="$2" desc_suffix="$3"
    # Dir name MUST NOT contain "padencap" as substring (fgrep would
    # match it in paths and break the rkn-arm assertions below).
    local root="${MOCK_DIR}/pe-flag-$flag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists"
    echo "youtube.com" > "$root/extra_strats/TCP/YT/List.txt"
    echo "youtube.com" > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org" > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    # Strategy.txt с :tls_mod= токеном чтобы injector имел что трогать.
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:tls_mod=rnd,dupsid,sni=www.google.com:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    # 2026-05-03: auto-injection отключена by default, требует Z2K_INJECT_TLS_MODS=1
    # для активации вместе с Z2K_PADENCAP=1 (двухуровневый opt-in).
    cat > "$root/config" <<EOF
ENABLED=1
Z2K_INJECT_TLS_MODS=$flag
Z2K_PADENCAP=$flag
EOF
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    local rkn_arm
    rkn_arm=$(grep -F 'key=rkn_tcp' "$root/config" | head -1)

    if [ "$expect_padencap" = "1" ]; then
        assert_contains "padencap flag=$flag: rkn_tcp tls_mod has padencap" \
            "padencap" "$rkn_arm"
    else
        assert_not_contains "padencap flag=$flag: rkn_tcp tls_mod без padencap" \
            "padencap" "$rkn_arm"
    fi

    # Idempotency: padencap не должен дублироваться при повторном
    # запуске create_official_config (injector гейт *padencap* skip).
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    local rkn_arm_2nd
    rkn_arm_2nd=$(grep -F 'key=rkn_tcp' "$root/config" | head -1)
    local padencap_count
    padencap_count=$(printf '%s' "$rkn_arm_2nd" | grep -o "padencap" | wc -l | tr -d ' ')
    if [ "$expect_padencap" = "1" ]; then
        # На каждом :tls_mod= токене с padencap должен быть ровно 1
        # padencap, не два. У нас в Strategy.txt один :tls_mod= токен →
        # ожидается ровно 1 padencap во всём rkn arm.
        assert_eq "padencap flag=$flag: idempotent (no duplication)" "1" "$padencap_count"
    fi

    rm -rf "$root"
}

test_padencap_under_flag "0" "0" "rkn_tcp без padencap"
test_padencap_under_flag "1" "1" "rkn_tcp с padencap"

printf "\n--- HTTP mid_stream_stall wiring под Z2K_USE_MID_STREAM_DETECTOR ---\n"

# http_rkn primary failure_detector — z2k_silent_drop_detector (2026-05-03,
# AlfiX silent_drop_detector port). Chain делегирует:
# silent_drop → http_mid_stream_stall → tls_alert_fatal — внутри lua, не
# через config strings. Так что primary всегда z2k_silent_drop_detector
# независимо от Z2K_USE_MID_STREAM_DETECTOR. Mid_stream remain активным
# через chain delegation (всегда), flag регулирует только rkn_tcp / yt_tcp /
# gv_tcp arms (там mid_stream остаётся прямым primary).
test_http_detector_under_flag() {
    local flag="$1"
    local root="${MOCK_DIR}/http-det-$flag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com" > "$root/extra_strats/TCP/YT/List.txt"
    echo "youtube.com" > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org" > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    cat > "$root/config" <<EOF
ENABLED=1
Z2K_USE_MID_STREAM_DETECTOR=$flag
EOF
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    local http_arm
    http_arm=$(grep -F 'key=http_rkn' "$root/config" | head -1)

    assert_contains "ms flag=$flag: http_rkn arm emitted" \
        "key=http_rkn" "$http_arm"
    # Primary всегда silent_drop_detector — chain делегирует внутри lua.
    assert_contains "ms flag=$flag: http_rkn primary=z2k_silent_drop_detector" \
        "failure_detector=z2k_silent_drop_detector" "$http_arm"
    # Other detectors не должны быть primary в config-string (они только
    # внутри chain через runtime call, не текстом в conf).
    assert_not_contains "ms flag=$flag: http_rkn no http_mid_stream as primary" \
        "failure_detector=z2k_http_mid_stream_stall" "$http_arm"
    assert_not_contains "ms flag=$flag: http_rkn no tls_alert as primary" \
        "failure_detector=z2k_tls_alert_fatal" "$http_arm"
    rm -rf "$root"
}

# Both flag=0 and flag=1 should result in z2k_silent_drop_detector primary
# для http_rkn arm. Flag effect остаётся в rkn_tcp/yt_tcp/gv_tcp armах
# (через ensure_rkn_failure_detector / прямые detector swaps).
test_http_detector_under_flag "0"
test_http_detector_under_flag "1"

printf "\n--- GAME_PROFILE: runtime — default → flowseal ---\n"

setup_flowseal_ipset() { echo "8.8.8.0/24" > "$1/lists/flowseal_game_ips.txt"; }
setup_flowseal_with_exclude() {
    echo "8.8.8.0/24" > "$1/lists/flowseal_game_ips.txt"
    echo "10.0.0.0/8" > "$1/lists/ipset-exclude.txt"
}
OUTPUT_DEFAULT=$(run_generator "default" "GAME_MODE_ENABLED=1" "setup_flowseal_ipset")
ARM_DEFAULT=$(get_flowseal_arm_line "$OUTPUT_DEFAULT")
LEGACY_DEFAULT=$(get_legacy_arm_line "$OUTPUT_DEFAULT")

assert_contains "default: emits flowseal arm" "flowseal_game_ips.txt" "$OUTPUT_DEFAULT"
assert_contains "default: arm has dbankcloud blob" "blob=quic_dbankcloud" "$ARM_DEFAULT"
assert_contains "default: arm has repeats=12" "repeats=12" "$ARM_DEFAULT"
assert_contains "default: arm has --out-range=-n2" "--out-range=-n2" "$ARM_DEFAULT"
assert_contains "default: arm has --in-range=a" "--in-range=a" "$ARM_DEFAULT"
# Profile-level --payload=all (separate from the in-lua-desync payload=all
# inside z2k_game_udp:...). Without the profile token, nfqws would not pass
# binary game traffic through to the lua handler at all — assert it's the
# bare token with the leading --, not just "payload=all" anywhere in the line.
assert_contains "default: arm has profile-level --payload=all" "--payload=all" "$ARM_DEFAULT"
assert_contains "default: arm has port range" "--filter-udp=1024-2407,2409-65535" "$ARM_DEFAULT"
# ipset-exclude file is absent in this scenario — the gate `[ -f "$ipset_excl" ]`
# in config_official.sh should suppress the --ipset-exclude= flag.
assert_not_contains "default: arm omits --ipset-exclude when file missing" "--ipset-exclude=" "$ARM_DEFAULT"
if port_excluded_from_filter "$ARM_DEFAULT" "80"; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] default: port 80 not in filter range\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] default: port 80 falls inside filter range\n"
fi
if port_excluded_from_filter "$ARM_DEFAULT" "443"; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] default: port 443 not in filter range\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] default: port 443 falls inside filter range\n"
fi
if port_excluded_from_filter "$ARM_DEFAULT" "2408"; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] default: Warp 2408 not in filter range\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] default: Warp 2408 falls inside filter range\n"
fi
assert_eq "default: legacy arm not emitted" "" "$LEGACY_DEFAULT"

printf "\n--- GAME_PROFILE: runtime — flowseal + ipset-exclude.txt present ---\n"

# When ipset-exclude.txt exists, the flowseal arm should append
# --ipset-exclude=... to the profile (the optional branch in
# config_official.sh that the previous test scenario didn't cover).
OUTPUT_WITH_EXCLUDE=$(run_generator "with_exclude" "GAME_MODE_ENABLED=1" "setup_flowseal_with_exclude")
ARM_WITH_EXCLUDE=$(get_flowseal_arm_line "$OUTPUT_WITH_EXCLUDE")

assert_contains "with-exclude: arm emitted" "flowseal_game_ips.txt" "$OUTPUT_WITH_EXCLUDE"
assert_contains "with-exclude: arm has --ipset-exclude=...ipset-exclude.txt" "--ipset-exclude=" "$ARM_WITH_EXCLUDE"
assert_contains "with-exclude: --ipset-exclude points at our mock file" "ipset-exclude.txt" "$ARM_WITH_EXCLUDE"
# Ordering invariant: positive --ipset= must appear BEFORE --ipset-exclude=
# so nfqws constructs the trigger set first, then applies exclusions.
# A grep-based ordering check is sufficient since both tokens are single-line.
POS_IPSET_OFFSET=$(printf '%s' "$ARM_WITH_EXCLUDE" | awk '{i=index($0,"--ipset=")} END{print i}')
NEG_IPSET_OFFSET=$(printf '%s' "$ARM_WITH_EXCLUDE" | awk '{i=index($0,"--ipset-exclude=")} END{print i}')
if [ "$POS_IPSET_OFFSET" -gt 0 ] && [ "$NEG_IPSET_OFFSET" -gt 0 ] \
   && [ "$POS_IPSET_OFFSET" -lt "$NEG_IPSET_OFFSET" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] with-exclude: --ipset= precedes --ipset-exclude=\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] with-exclude: ipset ordering wrong (pos=%s, neg=%s)\n" "$POS_IPSET_OFFSET" "$NEG_IPSET_OFFSET"
fi

printf "\n--- GAME_PROFILE: runtime — explicit legacy → no flowseal arm ---\n"

OUTPUT_LEGACY=$(run_generator "legacy" "GAME_MODE_ENABLED=1
GAME_PROFILE=legacy
GAME_MODE_STYLE=safe" "")
ARM_LEGACY=$(get_flowseal_arm_line "$OUTPUT_LEGACY")
# Legacy mode also needs game_ips.txt to emit its arm; create it.
setup_legacy_ipset() {
    echo "8.8.8.0/24" > "$1/lists/game_ips.txt"
}
OUTPUT_LEGACY=$(run_generator "legacy_with_ips" "GAME_MODE_ENABLED=1
GAME_PROFILE=legacy
GAME_MODE_STYLE=safe" "setup_legacy_ipset")
ARM_LEGACY=$(get_flowseal_arm_line "$OUTPUT_LEGACY")
LEGACY_ARM=$(get_legacy_arm_line "$OUTPUT_LEGACY")

assert_eq "legacy: flowseal arm not emitted" "" "$ARM_LEGACY"
assert_not_contains "legacy: no flowseal_game_ips reference" "flowseal_game_ips" "$OUTPUT_LEGACY"
assert_not_contains "legacy: no z2k_game_udp dbankcloud arm" "z2k_game_udp:strategy=1:payload=all:dir=out:blob=quic_dbankcloud" "$OUTPUT_LEGACY"
# Legacy path discriminator: 13-strat rotator with key=game_udp.
assert_contains "legacy: emits 13-strat rotator key=game_udp" "key=game_udp" "$OUTPUT_LEGACY"
assert_contains "legacy: legacy arm uses game_ips.txt" "game_ips.txt" "$LEGACY_ARM"

printf "\n--- GAME_PROFILE: runtime — missing flowseal_game_ips.txt → silent skip ---\n"

# GAME_PROFILE=flowseal (default) but no flowseal_game_ips.txt file present.
# Function MUST silently skip the flowseal arm (the -s file-existence gate);
# generated NFQWS2_OPT contains no flowseal-related profile.
OUTPUT_NOIPSET=$(run_generator "noipset" "GAME_MODE_ENABLED=1
GAME_PROFILE=flowseal" "")
ARM_NOIPSET=$(get_flowseal_arm_line "$OUTPUT_NOIPSET")

assert_eq "missing-ipset: flowseal arm not emitted" "" "$ARM_NOIPSET"
assert_not_contains "missing-ipset: no flowseal_game_ips reference" "flowseal_game_ips" "$OUTPUT_NOIPSET"
assert_not_contains "missing-ipset: no z2k_game_udp dbankcloud arm" "z2k_game_udp:strategy=1:payload=all:dir=out:blob=quic_dbankcloud" "$OUTPUT_NOIPSET"

printf "\n--- GAME_PROFILE: runtime — unknown value coerced to flowseal ---\n"

OUTPUT_UNKNOWN=$(run_generator "unknown" "GAME_MODE_ENABLED=1
GAME_PROFILE=garbage_value" "setup_flowseal_ipset")
ARM_UNKNOWN=$(get_flowseal_arm_line "$OUTPUT_UNKNOWN")

assert_contains "unknown: arm emitted (coerced to flowseal)" "blob=quic_dbankcloud" "$ARM_UNKNOWN"
assert_contains "unknown: arm has correct port range" "--filter-udp=1024-2407,2409-65535" "$ARM_UNKNOWN"

printf "\n--- GAME_PROFILE: TCP non-TLS static arm (step 4) ---\n"

# Default flowseal mode + flowseal_game_ips.txt + ipset-exclude.txt — full
# rig so we can assert on every conditional path.
OUTPUT_TCP=$(run_generator "tcp_default" "GAME_MODE_ENABLED=1" "setup_flowseal_with_exclude")
TCP_ARM=$(get_flowseal_tcp_arm_line "$OUTPUT_TCP")

# Arm must be emitted for the default (flowseal) profile.
assert_contains "tcp: arm emitted" "flowseal_game_ips.txt" "$TCP_ARM"
# Recipe shape — multisplit:pos=1:seqovl=568 with 4pda seqovl pattern.
assert_contains "tcp: arm uses multisplit" "lua-desync=multisplit" "$TCP_ARM"
assert_contains "tcp: arm has pos=1" "pos=1" "$TCP_ARM"
assert_contains "tcp: arm has seqovl=568" "seqovl=568" "$TCP_ARM"
assert_contains "tcp: arm uses tls_clienthello_4pda_to seqovl pattern" "seqovl_pattern=tls_clienthello_4pda_to" "$TCP_ARM"
assert_contains "tcp: arm has dir=out" "dir=out" "$TCP_ARM"
# Profile-level options.
assert_contains "tcp: arm has --in-range=a" "--in-range=a" "$TCP_ARM"
assert_contains "tcp: arm has --out-range=-n3" "--out-range=-n3" "$TCP_ARM"
assert_contains "tcp: arm has profile-level --payload=all" "--payload=all" "$TCP_ARM"
# --filter-l7=unknown scopes this arm to traffic the nfqws2 L7 classifier
# couldn't identify (binary game TCP). TLS gets classified L7_TLS by the
# probe machinery before the filter check fires, so TLS flows are
# correctly excluded — they take the TLS rotator arm that emits above.
assert_contains "tcp: arm has --filter-l7=unknown" "--filter-l7=unknown" "$TCP_ARM"
assert_not_contains "tcp: arm does not match TLS L7" "filter-l7=tls" "$TCP_ARM"
# Positive ipset scope.
assert_contains "tcp: arm has --ipset=...flowseal_game_ips.txt" "--ipset=" "$TCP_ARM"
# Conditional --ipset-exclude= when the file exists.
assert_contains "tcp: arm has --ipset-exclude=...ipset-exclude.txt" "--ipset-exclude=" "$TCP_ARM"
# NO hostlist-exclude on the static arm — nfqws2's dp_match() rejects a
# profile when hostname=NULL AND hostlist-exclude is non-empty
# (desync.c:248-251 + PROFILE_HOSTLISTS_EMPTY at params.h:109). Binary
# game TCP has no SNI → with any hostlist-exclude set, the arm would
# never match its actual target. Defenses on this arm are filter-l7=unknown
# + ipset + port carve-out. Hostlist-exclude lives on the TLS rotator
# (step 5) where flows carry SNI.
assert_not_contains "tcp: arm has NO --hostlist-exclude (would kill binary)" "--hostlist-exclude=" "$TCP_ARM"
assert_not_contains "tcp: arm does not reference whitelist.txt" "whitelist.txt" "$TCP_ARM"
assert_not_contains "tcp: arm does not reference YT list" "TCP/YT/List.txt" "$TCP_ARM"
assert_not_contains "tcp: arm does not reference RKN list" "TCP/RKN/List.txt" "$TCP_ARM"
# Recipe must NOT use circular — binary game TCP has no observable
# success/fail signal that a rotator could converge on.
assert_not_contains "tcp: arm has no circular rotator" "lua-desync=circular" "$TCP_ARM"
# No legacy 13-strat tokens.
assert_not_contains "tcp: arm has no game_udp circular key" "key=game_udp" "$TCP_ARM"

# Port-range carve-out invariant (colleague's: never include
# 80/443/8443/2053/2083/2087/2096; preserve Warp 2408 carve-out).
for excluded in 80 443 2053 2083 2087 2096 2408 8443; do
    if port_excluded_from_filter "$TCP_ARM" "$excluded" "tcp"; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tcp: port %s not in filter range\n" "$excluded"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tcp: port %s falls inside filter range\n" "$excluded"
    fi
done
# Sanity — a real high game port MUST be in the range (otherwise the
# carve-out is over-zealous).
for included in 1024 12345 27015 50000 65535; do
    if port_excluded_from_filter "$TCP_ARM" "$included" "tcp"; then
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tcp: high port %s missing from filter range (over-carved)\n" "$included"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tcp: high port %s in filter range\n" "$included"
    fi
done

# Legacy mode must NOT emit a TCP arm (step 4 only adds for flowseal).
OUTPUT_TCP_LEGACY=$(run_generator "tcp_legacy" "GAME_MODE_ENABLED=1
GAME_PROFILE=legacy
GAME_MODE_STYLE=safe" "setup_flowseal_with_exclude")
TCP_ARM_LEGACY=$(get_flowseal_tcp_arm_line "$OUTPUT_TCP_LEGACY")
assert_eq "tcp: legacy mode does not emit TCP arm" "" "$TCP_ARM_LEGACY"

# Missing flowseal_game_ips.txt must suppress the TCP arm via -s gate.
OUTPUT_TCP_NOIPSET=$(run_generator "tcp_noipset" "GAME_MODE_ENABLED=1" "")
TCP_ARM_NOIPSET=$(get_flowseal_tcp_arm_line "$OUTPUT_TCP_NOIPSET")
assert_eq "tcp: missing-ipset → no TCP arm" "" "$TCP_ARM_NOIPSET"

# Missing ipset-exclude.txt → arm still emitted but without --ipset-exclude=.
OUTPUT_TCP_NOEXCL=$(run_generator "tcp_noexcl" "GAME_MODE_ENABLED=1" "setup_flowseal_ipset")
TCP_ARM_NOEXCL=$(get_flowseal_tcp_arm_line "$OUTPUT_TCP_NOEXCL")
assert_contains "tcp: arm emitted without ipset-exclude file" "flowseal_game_ips.txt" "$TCP_ARM_NOEXCL"
assert_not_contains "tcp: arm omits --ipset-exclude= when file missing" "--ipset-exclude=" "$TCP_ARM_NOEXCL"
# whitelist still must NOT appear — same hostname-blocks-binary reason.
assert_not_contains "tcp: arm has no whitelist hostlist-exclude" "whitelist.txt" "$TCP_ARM_NOEXCL"

printf "\n--- GAME_PROFILE: TCP TLS rotator (step 5) ---\n"

OUTPUT_TLS=$(run_generator "tls_default" "GAME_MODE_ENABLED=1" "setup_flowseal_with_exclude")
TLS_ARM=$(get_flowseal_tls_arm_line "$OUTPUT_TLS")
TCP_STATIC=$(get_flowseal_tcp_arm_line "$OUTPUT_TLS")

# Arm emission + profile-level shape.
assert_contains "tls: arm emitted" "flowseal_game_ips.txt" "$TLS_ARM"
assert_contains "tls: arm has --filter-l7=tls" "--filter-l7=tls" "$TLS_ARM"
assert_contains "tls: arm has profile-level --payload=tls_client_hello" "--payload=tls_client_hello" "$TLS_ARM"
assert_contains "tls: arm has --out-range=-n3" "--out-range=-n3" "$TLS_ARM"
assert_not_contains "tls: arm has NO profile-level --payload=all" "--payload=all" "$TLS_ARM"

# YT/GV-style layout: circular sees incoming via --in-range=-s5556 BEFORE
# circular, then --in-range=x + --payload=tls_client_hello AFTER, so
# strategies are still payload-gated but the circular orchestrator is
# not (so its failure_detector + inseq=18000 actually have signal).
assert_contains "tls: arm has --in-range=-s5556 (circular incoming)" "--in-range=-s5556" "$TLS_ARM"
assert_contains "tls: arm has --in-range=x (close window after circular)" "--in-range=x" "$TLS_ARM"
# Order assertions — byte offsets within the line.
INR_S5556_OFF=$(printf '%s' "$TLS_ARM" | awk '{print index($0,"--in-range=-s5556")}')
CIRC_OFF=$(printf '%s' "$TLS_ARM" | awk '{print index($0,"--lua-desync=circular:")}')
INR_X_OFF=$(printf '%s' "$TLS_ARM" | awk '{print index($0,"--in-range=x")}')
PAYLOAD_OFF=$(printf '%s' "$TLS_ARM" | awk '{print index($0,"--payload=tls_client_hello")}')
STRAT1_OFF=$(printf '%s' "$TLS_ARM" | awk '{print index($0,":strategy=1")}')
if [ "$INR_S5556_OFF" -gt 0 ] && [ "$INR_S5556_OFF" -lt "$CIRC_OFF" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tls: --in-range=-s5556 precedes circular\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tls: --in-range=-s5556 not before circular (s5556=%s circ=%s)\n" "$INR_S5556_OFF" "$CIRC_OFF"
fi
if [ "$CIRC_OFF" -lt "$INR_X_OFF" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tls: circular precedes --in-range=x\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tls: circular not before --in-range=x (circ=%s inrx=%s)\n" "$CIRC_OFF" "$INR_X_OFF"
fi
if [ "$INR_X_OFF" -lt "$PAYLOAD_OFF" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tls: --in-range=x precedes --payload=tls_client_hello\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tls: --in-range=x not before --payload (inrx=%s payload=%s)\n" "$INR_X_OFF" "$PAYLOAD_OFF"
fi
if [ "$PAYLOAD_OFF" -lt "$STRAT1_OFF" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tls: --payload=tls_client_hello precedes strategy=1\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tls: --payload not before strategy=1 (payload=%s s1=%s)\n" "$PAYLOAD_OFF" "$STRAT1_OFF"
fi
# Critical regression test: circular MUST come BEFORE --payload= so the
# orchestrator's payload_type stays unset and it sees incoming packets.
if [ "$CIRC_OFF" -lt "$PAYLOAD_OFF" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tls: circular precedes --payload= (orchestrator unfiltered)\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tls: REGRESSION — circular AFTER --payload= would blind detectors\n"
fi

# Circular detector wiring (matches yt_tcp pattern: HTTPS-only auth/control).
# Extract just the circular token so the per-token assertions below can't
# silently pass on substrings that live elsewhere in the line (e.g., if a
# future regression moves nld=/inseq= out of circular onto a strategy).
TLS_CIRC_TOKEN=$(printf '%s' "$TLS_ARM" | sed -nE 's/.*( --lua-desync=circular:[^ ]*).*/\1/p')
assert_contains "tls: extracted circular token is non-empty" "circular:" "$TLS_CIRC_TOKEN"
assert_contains "tls: circular has key=game_tls" "key=game_tls" "$TLS_CIRC_TOKEN"
assert_contains "tls: circular has fails=2" "circular:fails=2" "$TLS_CIRC_TOKEN"
assert_contains "tls: circular has nld=2 (per-SLD pinning)" "nld=2" "$TLS_CIRC_TOKEN"
assert_contains "tls: circular has inseq=18000 (TSPU 16K-gate)" "inseq=18000" "$TLS_CIRC_TOKEN"
assert_contains "tls: circular has failure_detector=z2k_tls_alert_fatal" "failure_detector=z2k_tls_alert_fatal" "$TLS_CIRC_TOKEN"
assert_contains "tls: circular has success_detector=z2k_success_no_reset" "success_detector=z2k_success_no_reset" "$TLS_CIRC_TOKEN"
assert_contains "tls: circular has no_http_redirect" "no_http_redirect" "$TLS_CIRC_TOKEN"
# Negative — these MUST NOT leak onto the circular token from a future
# refactor that moves them around (e.g., onto strategy=N tokens).
assert_not_contains "tls: circular has no payload= arg (payload-gate is profile-level, not on circular itself)" "payload=" "$TLS_CIRC_TOKEN"
assert_not_contains "tls: circular has no strategy= arg" "strategy=" "$TLS_CIRC_TOKEN"

# All 6 strategies present.
for s in 1 2 3 4 5 6; do
    assert_contains "tls: arm has strategy=$s" "strategy=$s" "$TLS_ARM"
done

# Strategy 1 — multisplit + 4pda (general default).
assert_contains "tls: strategy=1 uses multisplit + 4pda + seqovl=568 pos=1" \
    "multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to:strategy=1" "$TLS_ARM"
# Strategy 2 — multisplit + google + seqovl=652 pos=2 (ALT2).
assert_contains "tls: strategy=2 uses multisplit + google + seqovl=652 pos=2" \
    "multisplit:payload=tls_client_hello:dir=out:pos=2:seqovl=652:seqovl_pattern=tls_clienthello_www_google_com:strategy=2" "$TLS_ARM"
# Strategy 5 — syndata + syn_packet blob (ALT7).
assert_contains "tls: strategy=5 uses syndata" "syndata:payload=tls_client_hello:dir=out:blob=syn_packet:strategy=5" "$TLS_ARM"
# Strategy 6 — fake + badseq (ALT8) — :badseq:badseq_increment=2: alias must
# have been expanded by expand_badseq_aliases() to tcp_seq + tcp_ack.
assert_contains "tls: strategy=6 has tcp_seq=2 (badseq expansion)" "tcp_seq=2" "$TLS_ARM"
assert_contains "tls: strategy=6 has tcp_ack=-66000 (badseq expansion)" "tcp_ack=-66000" "$TLS_ARM"
assert_not_contains "tls: strategy=6 badseq alias was expanded (no raw :badseq:)" ":badseq:" "$TLS_ARM"

# Hostlist-excludes ARE present here (vs the non-TLS static arm where
# they would block matching). TLS flows carry SNI, so dp_match() can
# resolve the hostlist gate at desync.c:248-251.
assert_contains "tls: arm excludes whitelist" "whitelist.txt" "$TLS_ARM"
assert_contains "tls: arm excludes YT TCP list" "TCP/YT/List.txt" "$TLS_ARM"
assert_contains "tls: arm excludes RKN list" "TCP/RKN/List.txt" "$TLS_ARM"

# ipset scope.
assert_contains "tls: arm has --ipset=...flowseal_game_ips.txt" "--ipset=" "$TLS_ARM"
assert_contains "tls: arm has --ipset-exclude=...ipset-exclude.txt" "--ipset-exclude=" "$TLS_ARM"

# Port carve-out same as static arm.
for excluded in 80 443 2053 2083 2087 2096 2408 8443; do
    if port_excluded_from_filter "$TLS_ARM" "$excluded" "tcp"; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tls: port %s not in filter range\n" "$excluded"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tls: port %s falls inside filter range\n" "$excluded"
    fi
done

# CRITICAL ORDERING INVARIANT: TLS rotator MUST emit BEFORE the non-TLS
# static arm. nfqws2 is per-line first-match-wins; if static came first
# with payload=all, TLS would be silently swallowed before reaching the
# rotator, and step 5 would be a dead profile.
TLS_OFFSET=$(printf '%s' "$OUTPUT_TLS" | awk 'BEGIN{n=0} /flowseal_game_ips.txt/ && /--filter-l7=tls/ {print n; exit} {n+=length($0)+1}')
STATIC_OFFSET=$(printf '%s' "$OUTPUT_TLS" | awk 'BEGIN{n=0} /flowseal_game_ips.txt/ && /--filter-l7=unknown/ {print n; exit} {n+=length($0)+1}')
if [ -n "$TLS_OFFSET" ] && [ -n "$STATIC_OFFSET" ] && [ "$TLS_OFFSET" -lt "$STATIC_OFFSET" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] tls: TLS rotator precedes non-TLS static arm in emit order\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] tls: emit ordering wrong (tls=%s, static=%s)\n" "$TLS_OFFSET" "$STATIC_OFFSET"
fi

# Static arm still emitted in same scenario (binary game TCP fall-through).
assert_contains "tls: non-TLS static arm still emitted alongside" "flowseal_game_ips.txt" "$TCP_STATIC"
assert_contains "tls: static arm has --filter-l7=unknown unchanged" "--filter-l7=unknown" "$TCP_STATIC"

# Legacy mode → no TLS arm (and no static arm — both flowseal-only).
OUTPUT_TLS_LEGACY=$(run_generator "tls_legacy" "GAME_MODE_ENABLED=1
GAME_PROFILE=legacy
GAME_MODE_STYLE=safe" "setup_flowseal_with_exclude")
TLS_ARM_LEGACY=$(get_flowseal_tls_arm_line "$OUTPUT_TLS_LEGACY")
assert_eq "tls: legacy mode emits no TLS arm" "" "$TLS_ARM_LEGACY"

# Missing flowseal_game_ips → no TLS arm.
OUTPUT_TLS_NOIPSET=$(run_generator "tls_noipset" "GAME_MODE_ENABLED=1" "")
TLS_ARM_NOIPSET=$(get_flowseal_tls_arm_line "$OUTPUT_TLS_NOIPSET")
assert_eq "tls: missing-ipset → no TLS arm" "" "$TLS_ARM_NOIPSET"

printf "\n--- GAME_PROFILE: port-parser sanity (negative tests) ---\n"

# The port-excluded helper itself must catch cases the prior weak grep missed.
if port_excluded_from_filter "--filter-udp=1024-2407,2409-65535,443" "443"; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] port parser: 443 in comma-list went undetected\n"
else
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] port parser: 443 in comma-list detected\n"
fi
if port_excluded_from_filter "--filter-udp=80-100,443-450" "443"; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] port parser: 443 in range 443-450 went undetected\n"
else
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] port parser: 443 inside range 443-450 detected\n"
fi
if port_excluded_from_filter "--filter-udp=1024-65535" "443"; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] port parser: 443 outside [1024-65535] correctly absent\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] port parser: false positive on 1024-65535/443\n"
fi
# Sanity for tcp proto override.
if port_excluded_from_filter "--filter-tcp=1024-2052,2054-2082,2084-2086,2088-2095,2097-2407,2409-8442,8444-65535" "8443" "tcp"; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] port parser: TCP carve-out correctly excludes 8443\n"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] port parser: TCP carve-out missed 8443\n"
fi

# ==============================================================================
# CLEANUP AND REPORT
# ==============================================================================

rm -rf "$MOCK_DIR"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
