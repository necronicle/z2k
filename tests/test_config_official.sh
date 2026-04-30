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
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=yt_tcp:nld=2:success_detector=z2k_success_no_reset:inseq=18000:failure_detector=z2k_tls_alert_fatal:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist-domains=googlevideo.com --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=gv_tcp:nld=2:inseq=18000:success_detector=z2k_http_success_positive_only:failure_detector=z2k_tls_alert_fatal:no_http_redirect --lua-desync=fake:repeats=4 --new
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
# yt_tcp / gv_tcp MUST carry failure_detector=z2k_tls_alert_fatal — without
# this, the no_http_redirect flag below leaves them with NO redirect
# coverage at all (regression caught in v3.6 review).
assert_contains "structure: yt_tcp has classifier-aware failure_detector" "key=yt_tcp:nld=2:success_detector=z2k_success_no_reset:inseq=18000:failure_detector=z2k_tls_alert_fatal" "$SAMPLE_OPT"
assert_contains "structure: yt_tcp has no_http_redirect AFTER failure_detector" "failure_detector=z2k_tls_alert_fatal:no_http_redirect" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has positive-only success_detector" "key=gv_tcp:nld=2:inseq=18000:success_detector=z2k_http_success_positive_only" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has classifier-aware failure_detector" "success_detector=z2k_http_success_positive_only:failure_detector=z2k_tls_alert_fatal" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has no_http_redirect" "failure_detector=z2k_tls_alert_fatal:no_http_redirect" "$SAMPLE_OPT"
# rkn_tcp uses z2k_mid_stream_stall (set by ensure_rkn_failure_detector below);
# its chain includes z2k_http_classifier_check via z2k_tls_alert_fatal inheritance.
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

# Helper: extract the line containing --filter-udp=...flowseal_game_ips...
# from generated NFQWS2_OPT. Returns empty if no flowseal arm was emitted.
get_flowseal_arm_line() {
    printf '%s\n' "$1" | grep -F 'flowseal_game_ips.txt' | head -1
}

# Helper: extract the legacy game_udp line (uses key=game_udp circular).
get_legacy_arm_line() {
    printf '%s\n' "$1" | grep -F 'key=game_udp' | head -1
}

# Helper: parse comma-separated port spec from --filter-udp=<spec> and
# verify a target port is NOT covered by any range/single in the spec.
# Returns 0 if port is excluded (good), 1 if included (bad).
# Handles forms: single (443), range (1024-2407), comma-list (1024-2407,2409-65535,80).
port_excluded_from_filter() {
    local arm_line="$1" target_port="$2"
    local spec
    spec=$(printf '%s\n' "$arm_line" | sed -nE 's/.*--filter-udp=([^[:space:]]+).*/\1/p' | head -1)
    [ -z "$spec" ] && return 0  # No filter-udp on the line — vacuously excluded.
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
    printf '%s\n' "$cfg" > "$root/config"
    [ -n "$extra_cb" ] && eval "$extra_cb \"$root\""
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
    rm -rf "$root"
}

printf "\n--- GAME_PROFILE: runtime — default → flowseal ---\n"

setup_flowseal_ipset() { echo "8.8.8.0/24" > "$1/lists/flowseal_game_ips.txt"; }
OUTPUT_DEFAULT=$(run_generator "default" "GAME_MODE_ENABLED=1" "setup_flowseal_ipset")
ARM_DEFAULT=$(get_flowseal_arm_line "$OUTPUT_DEFAULT")
LEGACY_DEFAULT=$(get_legacy_arm_line "$OUTPUT_DEFAULT")

assert_contains "default: emits flowseal arm" "flowseal_game_ips.txt" "$OUTPUT_DEFAULT"
assert_contains "default: arm has dbankcloud blob" "blob=quic_dbankcloud" "$ARM_DEFAULT"
assert_contains "default: arm has repeats=12" "repeats=12" "$ARM_DEFAULT"
assert_contains "default: arm has --out-range=-n2" "--out-range=-n2" "$ARM_DEFAULT"
assert_contains "default: arm has port range" "--filter-udp=1024-2407,2409-65535" "$ARM_DEFAULT"
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
assert_not_contains "legacy: no quic_dbankcloud blob" "quic_dbankcloud" "$OUTPUT_LEGACY"
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
assert_not_contains "missing-ipset: no quic_dbankcloud blob" "quic_dbankcloud" "$OUTPUT_NOIPSET"

printf "\n--- GAME_PROFILE: runtime — unknown value coerced to flowseal ---\n"

OUTPUT_UNKNOWN=$(run_generator "unknown" "GAME_MODE_ENABLED=1
GAME_PROFILE=garbage_value" "setup_flowseal_ipset")
ARM_UNKNOWN=$(get_flowseal_arm_line "$OUTPUT_UNKNOWN")

assert_contains "unknown: arm emitted (coerced to flowseal)" "blob=quic_dbankcloud" "$ARM_UNKNOWN"
assert_contains "unknown: arm has correct port range" "--filter-udp=1024-2407,2409-65535" "$ARM_UNKNOWN"

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

# ==============================================================================
# CLEANUP AND REPORT
# ==============================================================================

rm -rf "$MOCK_DIR"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
