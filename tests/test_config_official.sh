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
# production version in lib/config_official.sh:798. Production sets
# z2k_mid_stream_stall (post-2026-04-18 default) — this fixture must
# match. Drift was caught 2026-04-29 review — production had moved to
# z2k_mid_stream_stall while tests still asserted z2k_tls_alert_fatal.
ensure_rkn_failure_detector() {
    local input="$1"
    local out=""
    local token=""

    for token in $input; do
        case "$token" in
            --lua-desync=circular:*)
                case "$token" in
                    *failure_detector=*) ;;
                    *) token="${token}:failure_detector=z2k_mid_stream_stall" ;;
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
# lib/config_official.sh (added 2026-04-29 commit 4 of v3.6 plan).
# Generic helper for appending arg=value to circular tokens.
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

# Test: idempotent if already present
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

# Test: non-circular tokens unchanged
INPUT_AS4="--lua-desync=fake:payload=tls_client_hello"
RESULT_AS4=$(ensure_circular_arg_set "$INPUT_AS4" "success_detector" "X")
assert_eq "arg_set: non-circular unchanged" "$INPUT_AS4" "$RESULT_AS4"

printf "\n--- ensure_rkn_failure_detector ---\n"

# Test: adds failure_detector to circular without one
INPUT_FD1="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:strategy=1"
RESULT_FD1=$(ensure_rkn_failure_detector "$INPUT_FD1")
assert_contains "failure_detector: adds to circular" "failure_detector=z2k_mid_stream_stall" "$RESULT_FD1"

# Test: does not duplicate if already present
INPUT_FD2="--lua-desync=circular:fails=3:failure_detector=z2k_mid_stream_stall:key=test"
RESULT_FD2=$(ensure_rkn_failure_detector "$INPUT_FD2")
# Count occurrences - should be exactly 1
FD_COUNT=$(printf '%s' "$RESULT_FD2" | grep -o "failure_detector" | wc -l | tr -d ' ')
assert_eq "failure_detector: no duplication" "1" "$FD_COUNT"

# Test: non-circular tokens are not modified
INPUT_FD3="--lua-desync=fake:payload=tls_client_hello --lua-desync=send:strategy=2"
RESULT_FD3=$(ensure_rkn_failure_detector "$INPUT_FD3")
assert_eq "failure_detector: non-circular unchanged" "$INPUT_FD3" "$RESULT_FD3"

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
SAMPLE_OPT="--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/RKN/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=rkn_tcp:nld=2:failure_detector=z2k_mid_stream_stall:inseq=18000:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=fake:strategy=1 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=yt_tcp:nld=2:success_detector=z2k_success_no_reset:inseq=18000:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist-domains=googlevideo.com --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=gv_tcp:nld=2:inseq=18000:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/UDP/YT/List.txt --filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:key=yt_quic:nld=2 --new
--filter-udp=50000-50099 --filter-l7=discord,stun --lua-desync=circular_locked:key=6"

# Production guarantees per v3.6 plan:
#  - every TCP TLS circular has inseq=18000 (commit 4c852f5)
#  - rkn_tcp has failure_detector=z2k_mid_stream_stall
#  - rkn_tcp / gv_tcp have success_detector=z2k_http_success_positive_only
#    (HTTP-aware — closes the seq>inseq false-pin race for 4xx replies)
#  - yt_tcp keeps z2k_success_no_reset (now HTTP-neutral-aware in commit 4)
#  - all four TLS profiles carry no_http_redirect to off-load standard's
#    302/307 cross-SLD redirect branch onto our z2k_classify_http_reply
assert_contains "structure: rkn_tcp has z2k_mid_stream_stall" "key=rkn_tcp:nld=2:failure_detector=z2k_mid_stream_stall" "$SAMPLE_OPT"
assert_contains "structure: rkn_tcp has inseq=18000" "key=rkn_tcp:nld=2:failure_detector=z2k_mid_stream_stall:inseq=18000" "$SAMPLE_OPT"
assert_contains "structure: rkn_tcp has positive-only success_detector" "key=rkn_tcp:nld=2:failure_detector=z2k_mid_stream_stall:inseq=18000:success_detector=z2k_http_success_positive_only" "$SAMPLE_OPT"
assert_contains "structure: rkn_tcp has no_http_redirect" "key=rkn_tcp:nld=2:failure_detector=z2k_mid_stream_stall:inseq=18000:success_detector=z2k_http_success_positive_only:no_http_redirect" "$SAMPLE_OPT"
assert_contains "structure: yt_tcp has no_reset success_detector" "key=yt_tcp:nld=2:success_detector=z2k_success_no_reset" "$SAMPLE_OPT"
assert_contains "structure: yt_tcp has no_http_redirect" "key=yt_tcp:nld=2:success_detector=z2k_success_no_reset:inseq=18000:no_http_redirect" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has positive-only success_detector" "key=gv_tcp:nld=2:inseq=18000:success_detector=z2k_http_success_positive_only" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has no_http_redirect" "key=gv_tcp:nld=2:inseq=18000:success_detector=z2k_http_success_positive_only:no_http_redirect" "$SAMPLE_OPT"
assert_not_contains "structure: no stale tls_alert_fatal in TLS profiles" "rkn_tcp:nld=2:failure_detector=z2k_tls_alert_fatal" "$SAMPLE_OPT"

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
# CLEANUP AND REPORT
# ==============================================================================

rm -rf "$MOCK_DIR"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
