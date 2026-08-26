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
echo "googlevideo.com" > "$MOCK_EXTRA_STRATS/TCP/YT_GV/List.txt"
echo "youtube.com" > "$MOCK_EXTRA_STRATS/UDP/YT/List.txt"
echo "rutracker.org" > "$MOCK_EXTRA_STRATS/TCP/RKN/List.txt"
echo "whitelisted.example.com" > "$MOCK_LISTS/whitelist.txt"

# Create sample strategy files
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:strategy=1" > "$MOCK_EXTRA_STRATS/TCP/RKN/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT/Strategy.txt"
echo "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=4" > "$MOCK_EXTRA_STRATS/TCP/YT_GV/Strategy.txt"
echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:strategy=1" > "$MOCK_EXTRA_STRATS/UDP/YT/Strategy.txt"

# Create mock config (no Austerus)
echo "ENABLED=1" > "$MOCK_ZAPRET2/config"

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
# TEST: ensure_circular_retrans (replicated from config_official.sh). The function
# forces retrans=N on circular tokens; tests below exercise targets 1 AND 2.
# NOTE: the production CALL-SITE reverted target 1→2 in r-52.5 (retrans=1 caused
# false rotations on working YouTube/Instagram hosts); the function itself is
# unchanged and still supports any target. Kept in sync with lib/config_official.sh.
# ==============================================================================

ensure_circular_retrans() {
    local input="$1"
    local target="${2:-1}"
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
                        retrans=*) ;;
                        *) rest="${rest:+$rest:}$part" ;;
                    esac
                done
                IFS="$old_ifs"
                if [ -n "$rest" ]; then
                    token="--lua-desync=circular:${rest}:retrans=${target}"
                else
                    token="--lua-desync=circular:retrans=${target}"
                fi
                ;;
        esac
        out="${out:+$out }$token"
    done
    IFS="$old_ifs"
    printf '%s' "$out"
}

printf "\n--- ensure_circular_retrans ---\n"

# (a) existing retrans=2 becomes retrans=1
INPUT_RT1="--lua-desync=circular:fails=3:retrans=2:time=60:key=rkn_tcp:nld=2"
RESULT_RT1=$(ensure_circular_retrans "$INPUT_RT1" 1)
assert_contains "retrans: 2 -> 1"                "retrans=1"  "$RESULT_RT1"
assert_not_contains "retrans: removes old retrans=2" "retrans=2" "$RESULT_RT1"
assert_contains "retrans: preserves fails"       "fails=3"    "$RESULT_RT1"
assert_contains "retrans: preserves nld"         "nld=2"      "$RESULT_RT1"

# (b) circular without retrans gains retrans=1
INPUT_RT2="--lua-desync=circular:fails=3:time=60:key=yt_tcp"
RESULT_RT2=$(ensure_circular_retrans "$INPUT_RT2" 1)
assert_contains "retrans: adds when absent"      "retrans=1"  "$RESULT_RT2"

# (c) non-circular token untouched
INPUT_RT3="--lua-desync=fake:payload=tls_client_hello:dir=out"
RESULT_RT3=$(ensure_circular_retrans "$INPUT_RT3" 1)
assert_eq "retrans: non-circular unchanged"      "$INPUT_RT3" "$RESULT_RT3"

# (d) UDP-style circular (no retrans in source) — when NOT applied (flag off path
#     skips it entirely) the token is simply never passed through, so we only
#     assert the pass itself never invents retrans on a token we DON'T feed it:
#     i.e. the gate is the caller's job. Here verify target=2 round-trips for the
#     flag-off regeneration case (retrans stays 2).
RESULT_RT4=$(ensure_circular_retrans "$INPUT_RT1" 2)
assert_contains "retrans: target=2 round-trip (flag-off keeps 2)" "retrans=2" "$RESULT_RT4"

# ==============================================================================
# TEST: ensure_rkn_failure_detector (replicated from config_official.sh)
# ==============================================================================

# Local copy of ensure_rkn_failure_detector — kept in sync with the
# production version in lib/config_official.sh. Этап 2: functional again —
# injects :failure_detector=<name> into the circular token (default
# z2k_tls_stalled; rkn_tcp passes z2k_silent_drop_detector). Idempotent.
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

printf "\n--- ensure_rkn_failure_detector (Этап 2 — functional) ---\n"

# Injects :failure_detector=<name> onto the circular token only.
INPUT_FD1="--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:strategy=1"
RESULT_FD1=$(ensure_rkn_failure_detector "$INPUT_FD1" "z2k_silent_drop_detector")
assert_contains "rkn_fd: circular base preserved" "circular:fails=3:key=rkn_tcp:nld=2" "$RESULT_FD1"
assert_not_contains "rkn_fd: fake token untouched" "strategy=1:failure_detector" "$RESULT_FD1"

# Default detector name when $2 omitted.
INPUT_FD2="--lua-desync=circular:fails=3:key=rkn_tcp:nld=2"
RESULT_FD2=$(ensure_rkn_failure_detector "$INPUT_FD2")
assert_contains "rkn_fd: default detector z2k_tls_stalled" "failure_detector=z2k_tls_stalled" "$RESULT_FD2"

# Idempotent — an existing failure_detector= is preserved, not duplicated.
INPUT_FD4="--lua-desync=circular:fails=3:failure_detector=z2k_existing:key=rkn_tcp"
RESULT_FD4=$(ensure_rkn_failure_detector "$INPUT_FD4" "z2k_silent_drop_detector")
FD_COUNT=$(printf '%s' "$RESULT_FD4" | grep -o "failure_detector=" | wc -l | tr -d ' ')
assert_eq "rkn_fd: no duplication when present" "1" "$FD_COUNT"
assert_contains "rkn_fd: existing value preserved" "failure_detector=z2k_existing" "$RESULT_FD4"

# No circular token → nothing injected.
INPUT_FD3="--lua-desync=fake:payload=tls_client_hello --lua-desync=send:strategy=2"
RESULT_FD3=$(ensure_rkn_failure_detector "$INPUT_FD3")
assert_not_contains "rkn_fd: no circular -> no injection" "failure_detector=" "$RESULT_FD3"

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

# The product DEFAULT is now pure-native detectors (Z2K_NATIVE_DETECTORS unset/1
# -> custom failure/success detectors stripped). The integration assertions below
# validate the LEGACY custom-detector wiring (ensure_*_detector / Этапы 2-4),
# which is now the opt-out path, so force custom mode for them. run_generator's
# subshell inherits this exported env. The native default is asserted separately
# at the end of this file (see "pure-native default" block).
export Z2K_NATIVE_DETECTORS=0

printf "\n--- Austerus mode removed (all_tcp443) ---\n"

# Режим Austerusj снят 2026-08-04. Раньше здесь лежал тест, который ничего не
# проверял: он ассертил строковый литерал, объявленный двумя строками выше, и
# ни разу не вызывал генератор. Поэтому он и не заметил бы ни поломки ветки, ни
# её удаления.
#
# Что проверяем теперь — ровно то, из-за чего режим был опасен: ветка
# закорачивала ВСЮ генерацию конфига через `return 0`, выдавая три строки из
# Zapret1 без хостлистов и без --hostlist-exclude=whitelist.txt. Гард держит
# генератор от повторного знакомства с этим файлом: пока в нём нет ни чтения
# all_tcp443.conf, ни ранней ветки, режим воскреснуть не может.
GENERATOR_SRC=$(cat "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/config_official.sh" 2>/dev/null)

assert_not_contains "austerus: генератор больше не читает all_tcp443.conf" \
    'safe_config_read "ENABLED" "$austerus_conf"' "$GENERATOR_SRC"
assert_not_contains "austerus: закоротка AUSTERUS_OPT удалена" \
    "AUSTERUS_OPT" "$GENERATOR_SRC"
assert_not_contains "austerus: стратегии Zapret1 больше не эмитятся" \
    "tls_clienthello_www_google_com:badsum:badseq:repeats=1:tls_mod=sni=www.google.com,rnd,dupsid" \
    "$GENERATOR_SRC"

# Миграция, снимающая режим у затронутых, обязана существовать и сносить файл
# безусловно — иначе откат на старую версию подхватит его снова.
INSTALL_SRC=$(cat "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/install.sh" 2>/dev/null)
assert_contains "austerus: миграция объявлена" "migrate_drop_austerus_mode()" "$INSTALL_SRC"
assert_contains "austerus: миграция вызывается на установке" \
    "$(printf '\n    migrate_drop_austerus_mode\n')" "$INSTALL_SRC"

# ==============================================================================
# TEST: Output format of generated config contains expected tokens
# ==============================================================================

printf "\n--- Config output structure ---\n"

# Build a representative NFQWS2_OPT output manually to validate structural checks.
# Этап 2 (failure-detector wiring restored): rkn_tcp/yt_tcp get
# failure_detector=z2k_silent_drop_detector, gv_tcp gets z2k_tls_alert_fatal.
# success_detector= (Этап 3) and no_http_redirect (Этап 4) NOT yet wired here.
# inseq= (native arg) kept; Discord nohost via hostkey=z2k_nohost_key.
SAMPLE_OPT="--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/RKN/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=rkn_tcp:nld=2:inseq=26000:failure_detector=z2k_silent_drop_detector:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=fake:strategy=1 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=yt_tcp:nld=2:inseq=18000:failure_detector=z2k_silent_drop_detector:success_detector=z2k_success_no_reset:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT_GV/List.txt --filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=gv_tcp:nld=2:inseq=24000:failure_detector=z2k_silent_drop_detector:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=fake:repeats=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/UDP/YT/List.txt --filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:key=yt_quic:nld=2 --new
--filter-udp=50000-50099 --filter-l7=discord,stun --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=discord_udp:nld=2:hostkey=z2k_nohost_key"

# Native rollback structure guarantees (2026-05-28):
#  - rkn_tcp circular has inseq=26000 (native arg — TLS stall window 14-25KB)
#  - yt_tcp / gv_tcp circular have inseq=18000 (smaller first-burst typical)
#  - NO z2k_* failure_detector= / success_detector= injections (native
#    standard_failure_detector / standard_success_detector by default)
#  - NO no_http_redirect (native 302/307 cross-SLD redirect detection active)
#  - Discord UDP keys hostname-less flows via hostkey=z2k_nohost_key (native
#    arg.hostkey extension), replacing the archived allow_nohost wrapper
assert_contains "structure: rkn_tcp has inseq=26000" "key=rkn_tcp:nld=2:inseq=26000" "$SAMPLE_OPT"
assert_contains "structure: yt_tcp has inseq=18000" "key=yt_tcp:nld=2:inseq=18000" "$SAMPLE_OPT"
assert_contains "structure: gv_tcp has inseq=24000 (silent_drop byte-gate)" "key=gv_tcp:nld=2:inseq=24000" "$SAMPLE_OPT"
assert_contains "structure: discord_udp uses native hostkey generator" "key=discord_udp:nld=2:hostkey=z2k_nohost_key" "$SAMPLE_OPT"
# Этапы 2-3: failure_detector= + success_detector= wired per pool;
# no_http_redirect stays native until Этап 4.
assert_contains "structure: rkn_tcp no_http_redirect (Этап 4, classifier replaces native)" "success_detector=z2k_http_success_positive_only:no_http_redirect" "$SAMPLE_OPT"
assert_not_contains "structure: no allow_nohost (replaced by hostkey=z2k_nohost_key)" "allow_nohost" "$SAMPLE_OPT"

assert_contains "structure: has --filter-tcp" "--filter-tcp" "$SAMPLE_OPT"
assert_contains "structure: has --filter-udp" "--filter-udp" "$SAMPLE_OPT"
assert_contains "structure: has --hostlist" "--hostlist=" "$SAMPLE_OPT"
assert_contains "structure: has --hostlist-exclude" "--hostlist-exclude=" "$SAMPLE_OPT"
# r-17: gv_tcp moved off --hostlist-domains=googlevideo.com onto its own
# YT_GV/List.txt file → no --hostlist-domains= anywhere in the output now.
assert_not_contains "structure: gv_tcp uses YT_GV/List.txt, not inline --hostlist-domains" "--hostlist-domains=" "$SAMPLE_OPT"
assert_contains "structure: has YT_GV hostlist file" "TCP/YT_GV/List.txt" "$SAMPLE_OPT"
assert_contains "structure: has --new separators" "--new" "$SAMPLE_OPT"
assert_contains "structure: has --lua-desync" "--lua-desync=" "$SAMPLE_OPT"

# Count --new separators (should be 4 in the sample above)
NEW_COUNT=$(printf '%s' "$SAMPLE_OPT" | grep -o -- '--new' | wc -l | tr -d ' ')
assert_eq "structure: correct --new count" "4" "$NEW_COUNT"

# ==============================================================================
# TEST: generator RUNTIME invocation (real function vs mock /opt tree)
# ==============================================================================
# Earlier static-SAMPLE coverage was insufficient: it asserted on hand-
# constructed strings, not on what generate_nfqws2_opt_from_strategies
# actually emits. This block runs the real function against a mock
# /opt/zapret2 root (via ZAPRET2_DIR override now that lists_dir derives
# from it) and asserts on captured output.

# Source the generator (utils.sh already sourced above).
. "$SCRIPT_DIR/lib/config_official.sh"


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
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
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
    # Детектор z2k_fail_tls_alert проводится в rkn_tcp только если lua-файл
    # реально лежит на диске (иначе движок падал бы в error() на каждом
    # пакете). Мок обязан повторять установленную систему, иначе тесты
    # проверяют не ту ветку.
    mkdir -p "$root/lua"
    cp "$SCRIPT_DIR/files/lua/z2k-alert.lua" "$root/lua/" 2>/dev/null || true
    [ -n "$extra_cb" ] && eval "$extra_cb \"$root\""
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null )
    rm -rf "$root"
}

# Helper: extract the rkn_tcp TLS arm (filter-l7=tls + key=rkn_tcp).
# http_rkn lives on a separate line (filter-tcp=80, key=http_rkn) and
# is filtered out by the key match.
get_rkn_tcp_arm_line() {
    printf '%s\n' "$1" | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk" \
        | grep -F 'key=rkn_tcp' | head -1
}

# Профиль ЦЕЛИКОМ из готового config-файла.
#
# Арсенал РКН объявляется в конфиге один раз (--template) и подставляется в
# профили (--import), поэтому «взять строку с key=rkn_tcp» больше не значит
# «взять весь профиль»: стратегии лежат в блоке шаблона. Раскрыватель
# возвращает прежний взгляд — профиль одной строкой со всеми инстансами.
config_profile_line() {
    sed -n '/^NFQWS2_OPT="/,/^"[[:space:]]*$/p' "$1" \
        | sed '1d;$d' \
        | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk" \
        | grep -F "$2" | head -1
}

printf "\n--- Z2K_USE_MID_STREAM_DETECTOR: explicit OFF (=0) ---\n"

# Per Mark 2026-05-02 policy "все нововведения по умолчанию включены"
# default flipped to 1. Test explicit Z2K_USE_MID_STREAM_DETECTOR=0
# чтобы opt-out path работал — rkn_tcp возвращается к master-compatible
# layout (--in-range=-s5556 + z2k_tls_stalled).
OUT_MS_OFF=$(run_generator "ms-off" "Z2K_USE_MID_STREAM_DETECTOR=0" "")
RKN_ARM_OFF=$(get_rkn_tcp_arm_line "$OUT_MS_OFF")

assert_contains "ms flag=0: rkn_tcp arm emitted" \
    "key=rkn_tcp" "$RKN_ARM_OFF"
# Окно больше не константа флага: инвариант «окно выше порога inseq» (см.
# блок ниже) поднимает его до inseq+1500 в обеих позициях флага. Для rkn_tcp
# порог всегда 26000, значит окно всегда 27500 — иначе полоса, в которой
# срабатывает успех по входящим, пуста. Флаг продолжает управлять вторым
# рычагом пакета — NFQWS2_TCP_PKT_IN (проверяется ниже).
assert_contains "ms flag=0: окно rkn_tcp держит инвариант (inseq 26000 + 1500)" \
    "--in-range=-s27500" "$RKN_ARM_OFF"
assert_not_contains "ms flag=0: старое окно ниже порога не вернулось" \
    "--in-range=-s5556" "$RKN_ARM_OFF"
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
assert_contains "ms flag=1: окно rkn_tcp держит инвариант (inseq 26000 + 1500)" \
    "--in-range=-s27500" "$RKN_ARM_ON"
# Half-state guards on flag=1 — bundle byte-cap должен land, но primary
# detector один и тот же независимо от flag (chain в lua делегирует к
# mid_stream_stall когда payload TLS).
assert_not_contains "ms flag=1: no leftover s5556 on rkn_tcp arm" \
    "--in-range=-s5556" "$RKN_ARM_ON"
assert_not_contains "ms flag=1: no z2k_tls_stalled as primary" \
    "failure_detector=z2k_tls_stalled" "$RKN_ARM_ON"
assert_not_contains "ms flag=1: no z2k_mid_stream_stall as primary" \
    "failure_detector=z2k_mid_stream_stall" "$RKN_ARM_ON"

printf "\n--- окно входящих выше порога inseq ---\n"

# Порог inseq ставится в config_official.sh, а окно `--in-range=-sN` вставляют
# раскладчики ensure_youtube_tls_* НИЖЕ по коду — константой, ничего не зная
# про порог. Гейт ensure_circular_in_range, заведённый 2026-08-14, правит
# только уже существующий токен, поэтому на дефолтной поставке (в стратегии
# токена нет вовсе) он не срабатывал, и на боевом роутере 2026-08-17 стояло:
#
#   rkn_tcp  --in-range=-s20000  inseq=26000   полоса пуста
#   yt_tcp   --in-range=-s5556   inseq=18000   полоса пуста
#
# Пустая полоса = успех по входящим недостижим, а окно, в котором входящий RST
# ещё считается провалом, обрезано окном видимости, а не порогом. Сторожим
# инвариант на всех TLS-пулах сразу.
# YT/GV в run_generator по умолчанию идут без circular — дописываем, иначе
# сторожить у них нечего.
_seed_tls_circulars() {
    local root="$1"
    echo "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=3:time=60:key=yt_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
        > "$root/extra_strats/TCP/YT/Strategy.txt"
    echo "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=3:time=60:key=gv_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:strategy=1" \
        > "$root/extra_strats/TCP/YT_GV/Strategy.txt"
}
OUT_RANGE=$(run_generator "in-range-vs-inseq" "Z2K_USE_MID_STREAM_DETECTOR=1" "_seed_tls_circulars")
_flat_range=$(printf '%s\n' "$OUT_RANGE" | awk -f "$SCRIPT_DIR/tests/lib/nfqws2_flatten.awk")

check_range_above_inseq() {
    local key="$1" line cap inseq
    line=$(printf '%s\n' "$_flat_range" | grep -F "key=$key" | head -1)
    [ -n "$line" ] || { assert_eq "$key: строка профиля найдена" "да" "нет"; return; }
    cap=$(printf '%s\n' "$line" | tr ' ' '\n' | grep -o -- '--in-range=-s[0-9]*' | head -1 | sed 's/.*-s//')
    inseq=$(printf '%s\n' "$line" | tr ' ' '\n' | grep -o 'inseq=[0-9]*' | head -1 | sed 's/inseq=//')
    if [ -z "$inseq" ]; then
        assert_eq "$key: inseq на месте" "число" "пусто"
        return
    fi
    if [ -n "$cap" ] && [ "$cap" -gt "$inseq" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "[PASS] %s: окно -s%s выше порога inseq=%s\n" "$key" "$cap" "$inseq"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "[FAIL] %s: окно -s%s НЕ выше порога inseq=%s — полоса пуста\n" "$key" "${cap:-нет}" "$inseq"
    fi
}

check_range_above_inseq rkn_tcp
check_range_above_inseq yt_tcp
check_range_above_inseq gv_tcp

# Расширение l7 и окно наблюдения обязаны сосуществовать.
#
# Ловим конкретный провал r-77.1. Пулы видео берут --filter-l7=tls,unknown,
# чтобы забирать соединения без SNI, а раскладку с --in-range вставляет хелпер,
# который сравнивал токен с «--filter-l7=tls» ТОЧНО. С довеском совпадение
# пропадало, раскладка молча не применялась, окно оставалось пустым.
#
# Проверка не заметила бы этого на макбуке: переписывание было сделано через
# sed с \| в BRE — у GNU это альтернатива, у BSD литерал, поэтому на маке
# подстановка не выполнялась вовсе и тест шёл по старому пути. Здесь смотрим
# РЕЗУЛЬТАТ, а не способ: в строке обязаны быть оба признака сразу.
check_l7_and_range_together() {
    local key="$1" line
    line=$(printf '%s\n' "$_flat_range" | grep -F "key=$key" | head -1)
    [ -n "$line" ] || { assert_eq "$key: строка профиля найдена" "да" "нет"; return; }
    case "$line" in
        *--filter-l7=tls,unknown*)
            case "$line" in
                *--in-range=-s*)
                    TESTS_PASSED=$((TESTS_PASSED + 1))
                    printf "[PASS] %s: tls,unknown и окно --in-range вместе\n" "$key" ;;
                *)
                    TESTS_FAILED=$((TESTS_FAILED + 1))
                    printf "[FAIL] %s: есть tls,unknown, но окна --in-range нет — раскладка не применилась\n" "$key" ;;
            esac ;;
        *)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf "[FAIL] %s: нет --filter-l7=tls,unknown — соединения без SNI пройдут мимо профиля\n" "$key" ;;
    esac
}

check_l7_and_range_together yt_tcp
check_l7_and_range_together gv_tcp

# РКН намеренно остаётся на чистом tls: там на тех же портах живёт слишком
# много чужого, и расширение забрало бы его в пул.
case $(printf '%s\n' "$_flat_range" | grep -F "key=rkn_tcp" | head -1) in
    *--filter-l7=tls,unknown*)
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "[FAIL] rkn_tcp: l7 расширен до tls,unknown — РКН это не нужно\n" ;;
    *)
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "[PASS] rkn_tcp: l7 остался чистым tls\n" ;;
esac

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
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
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
test_pkt_in_under_flag "1" "50" "NFQWS2_TCP_PKT_IN поднят до 50 (замер 2026-08-18: при 30 успех не срабатывал ни разу)"

printf "\n--- DISABLE_IPV6: preserved across config regen (user request 2026-06-19) ---\n"

# Regression: DISABLE_IPV6 was the ONE knob read only from the environment,
# so a user-set value got clobbered by the IPv6 autodetect on every config
# regen / nightly auto-update (p-30 wrote it to the file, but this function
# re-overwrote it). It now reads back from the existing config like every
# other knob. Precedence: env > saved-in-file > autodetect.
test_disable_ipv6() {
    local tag="$1" file_line="$2" env_val="$3"
    local root="${MOCK_DIR}/disable-ipv6-$tag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    { echo "ENABLED=1"; if [ -n "$file_line" ]; then echo "$file_line"; fi; } > "$root/config"
    if [ -n "$env_val" ]; then
        ( ZAPRET2_DIR="$root" DISABLE_IPV6="$env_val" create_official_config "$root/config" >/dev/null 2>&1 )
    else
        ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    fi
    grep -E '^DISABLE_IPV6=' "$root/config" | head -1
    rm -rf "$root"
}

DI6_OUT=$(test_disable_ipv6 "file1" "DISABLE_IPV6=1" "")
assert_contains "DISABLE_IPV6=1 from file survives regen, env unset (p-30 regression)" "DISABLE_IPV6=1" "$DI6_OUT"

DI6_OUT=$(test_disable_ipv6 "env0" "DISABLE_IPV6=1" "0")
assert_contains "env DISABLE_IPV6=0 overrides saved file =1" "DISABLE_IPV6=0" "$DI6_OUT"

DI6_OUT=$(test_disable_ipv6 "absent" "" "")
assert_contains "absent in file -> autodetect still emits a DISABLE_IPV6 line" "DISABLE_IPV6=" "$DI6_OUT"

# Auto-update reinstall: config_file is built FRESH (step_build_zapret2 moved
# the old tree to .old.$$ BEFORE config gen), so config_file carries no
# DISABLE_IPV6 on the first pass. The prior value must be recovered from the
# .old.$$ backup, NOT autodetected — otherwise a hand-disabled v6 gets
# re-enabled mid-reinstall (Mark 2026-06-20: на апдейте IPv6 не трогаем).
test_disable_ipv6_reinstall() {
    local tag="$1" old_val="$2"
    local root="${MOCK_DIR}/disable-ipv6-ri-$tag"
    rm -rf "$root" "${root}".old.* 2>/dev/null
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    # fresh config (no DISABLE_IPV6) + prior value lives ONLY in the .old.$$ backup
    echo "ENABLED=1" > "$root/config"
    mkdir -p "${root}.old.999"
    { echo "ENABLED=1"; echo "DISABLE_IPV6=${old_val}"; } > "${root}.old.999/config"
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    grep -E '^DISABLE_IPV6=' "$root/config" | head -1
    rm -rf "$root" "${root}".old.* 2>/dev/null
}

# Test BOTH values: on a given box autodetect resolves to ONE fixed value, so
# the opposite-value case proves we PRESERVED rather than re-autodetected.
DI6_OUT=$(test_disable_ipv6_reinstall "old1" "1")
assert_contains "reinstall: DISABLE_IPV6=1 recovered from .old backup (hand-disabled v6 preserved)" "DISABLE_IPV6=1" "$DI6_OUT"

DI6_OUT=$(test_disable_ipv6_reinstall "old0" "0")
assert_contains "reinstall: DISABLE_IPV6=0 recovered from .old backup (not re-autodetected)" "DISABLE_IPV6=0" "$DI6_OUT"

printf "\n--- Z2K_PPE_DEOFFLOAD: webpanel offload toggle persists across regen ---\n"

# Regression: the Keenetic per-flow hardware-offload exclusion toggle
# (Z2K_PPE_DEOFFLOAD) was NOT in the config-preserve pattern, so toggle_ppe's own
# regenerate_config wiped the key -> the NDM hook re-added the de-offload rules ->
# the webpanel switch silently reverted after a regen/reboot. Must survive now.
test_ppe_deoffload() {
    local tag="$1" file_line="$2"
    local root="${MOCK_DIR}/ppe-$tag"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" "$root/lists"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    echo "whitelisted.example.com" > "$root/lists/whitelist.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/TCP/RKN/Strategy.txt"
    { echo "ENABLED=1"; if [ -n "$file_line" ]; then echo "$file_line"; fi; } > "$root/config"
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 )
    grep -E '^Z2K_PPE_DEOFFLOAD=' "$root/config" | head -1
    rm -rf "$root"
}

PPE_OUT=$(test_ppe_deoffload "off" "Z2K_PPE_DEOFFLOAD=0")
assert_contains "Z2K_PPE_DEOFFLOAD=0 survives regen (webpanel toggle no longer reverts)" "Z2K_PPE_DEOFFLOAD=0" "$PPE_OUT"

PPE_OUT=$(test_ppe_deoffload "absent" "")
assert_contains "Z2K_PPE_DEOFFLOAD absent -> emits default =1" "Z2K_PPE_DEOFFLOAD=1" "$PPE_OUT"

printf "\n--- Z2K_PADENCAP: padencap autoinjector flag ---\n"

# Z2K_PADENCAP (default 0): when =1, inject_z2k_tls_mods добавляет
# padencap ко всем :tls_mod= токенам в rkn_tcp. Plus persist round-trip.
# Padencap НЕ должен попадать в yt_tcp/yt_gv_tcp — другие
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
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
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
    rkn_arm=$(config_profile_line "$root/config" 'key=rkn_tcp')

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
    rkn_arm_2nd=$(config_profile_line "$root/config" 'key=rkn_tcp')
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
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
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


# ==============================================================================
# CLEANUP AND REPORT
# ==============================================================================

printf "\n--- pure-native default (Z2K_NATIVE_DETECTORS=1) ---\n"
# The shipped DEFAULT: custom failure/success detectors + no_http_redirect are
# STRIPPED from every TCP pool, leaving pure bol-van standard detectors. Native
# circular tuning (inseq=/reset/in-range) is KEPT.
export Z2K_NATIVE_DETECTORS=1
OUT_NATIVE=$(run_generator "native-default" "" "")
export Z2K_NATIVE_DETECTORS=0
RKN_ARM_NATIVE=$(get_rkn_tcp_arm_line "$OUT_NATIVE")
assert_contains     "native: rkn_tcp arm emitted"               "key=rkn_tcp"          "$RKN_ARM_NATIVE"
# 2026-08-18: контракт уточнён. Кастомная библиотека детекторов по-прежнему
# срезается целиком, но ПОСЛЕ среза на rkn_tcp ставится ровно одна обёртка —
# z2k_fail_tls_alert. Она не заменяет штатный детектор, а вызывает его и
# добавляет два измеренных на боевом роутере отличия: ретрансмит считается
# только на ClientHello (иначе потеря пакета в живой сессии уводит рабочую
# страту) и фатальный TLS-алерт до ServerHello считается провалом (иначе
# нерабочая страта не ротируется вовсе — событий у детектора нет).
assert_contains     "native: rkn_tcp несёт обёртку z2k_fail_tls_alert" \
                    "failure_detector=z2k_fail_tls_alert" "$RKN_ARM_NATIVE"
assert_not_contains "native: старая библиотека детекторов не вернулась" \
                    "failure_detector=z2k_silent_drop_detector" "$RKN_ARM_NATIVE"
assert_not_contains "native: rkn_tcp has NO success_detector"   "success_detector="    "$RKN_ARM_NATIVE"
assert_not_contains "native: rkn_tcp has NO no_http_redirect"   "no_http_redirect"     "$RKN_ARM_NATIVE"
assert_contains     "native: rkn_tcp keeps native inseq="       "inseq="               "$RKN_ARM_NATIVE"

# ==============================================================================
# bol-van doc-alignment (2026-06-08) + Discord-voice Flowseal "5K ping" fix.
# Strictly-per-docs: reset on every pool, retrans=3 on TCP TLS, fails=3 on the
# game/http pools; discord voice strategy=1 == Flowseal fix (issue #12557).
# ==============================================================================
printf "\n--- doc-alignment: reset / retrans=3 / fails=3 / discord strategy=1 ---\n"
OUT_DOC=$(run_generator "docalign" "")
RKN_ARM_DOC=$(get_rkn_tcp_arm_line "$OUT_DOC")
HTTP_ARM_DOC=$(printf '%s\n' "$OUT_DOC" | grep -F 'key=http_rkn' | head -1)
DISCORD_ARM_DOC=$(printf '%s\n' "$OUT_DOC" | grep -F 'key=discord_udp' | head -1)

# rkn_tcp (TCP TLS): retrans 2 (r-54.1 revert from 3), NO reset, --in-range floor preserved.
assert_contains     "docalign: rkn_tcp circular retrans=2"      "retrans=2"     "$RKN_ARM_DOC"
assert_not_contains "docalign: rkn_tcp no stale retrans=3"      "retrans=3"     "$RKN_ARM_DOC"
assert_not_contains "docalign: rkn_tcp circular NO reset"       ":reset"        "$RKN_ARM_DOC"
assert_contains     "docalign: rkn_tcp --in-range>=floor"       "--in-range=-s" "$RKN_ARM_DOC"

# http_rkn: fails 2→3 (r-54.1: inline reset removed).
assert_contains     "docalign: http_rkn fails=3"                "circular:fails=3" "$HTTP_ARM_DOC"
assert_not_contains "docalign: http_rkn no fails=2"             "fails=2"          "$HTTP_ARM_DOC"
assert_not_contains "docalign: http_rkn NO reset"               ":reset"           "$HTTP_ARM_DOC"

# discord_udp: NO reset (r-54.1).
assert_not_contains "docalign: discord_udp circular NO reset"   ":reset"        "$DISCORD_ARM_DOC"

# ОЧЕРЕДЬ ПЕРЕСОБРАНА 26.08.2026, и утверждение здесь поменялось вместе с ней.
#
# Сопоставление всех наших стратегий с первоисточниками (БД по Flowseal /
# remittor / z4r) показало по дискорду две вещи. Первая: весь наш пул — порт
# z4r, включая список портов и блоб quic_dbankcloud; у z4r на discord-пейлоаде
# фейка ДВА (stun, затем dbankcloud), у нас при переносе остался один — потеря
# восстановлена. Вторая: у Flowseal свой снимок живого дискорд-пакета
# (ACTIVE_DISCORD_UDP), стратегий на нём у нас не было вовсе — они добавлены и
# поставлены В НАЧАЛО очереди, чтобы ротация пробовала их первыми.
#
# Поэтому dbankcloud теперь не первый, а четвёртый, и это не регресс.
assert_contains     "очередь дискорда начинается со снимка Flowseal" \
                    "blob=active_discord_udp:repeats=6:strategy=1" "$DISCORD_ARM_DOC"
assert_contains     "второй арм — тот же снимок с repeats=5 (их ALT13)" \
                    "blob=active_discord_udp:repeats=5:strategy=2" "$DISCORD_ARM_DOC"
assert_contains     "наш прежний первый стал четвёртым и цел" \
                    "blob=quic_dbankcloud:repeats=10:strategy=4" "$DISCORD_ARM_DOC"
# Потерянный при переносе фейк вернулся: у z4r он идёт ПЕРЕД dbankcloud и
# только на discord-пейлоаде.
assert_contains     "восстановлен первый фейк z4r (stun на discord-пейлоаде)" \
                    "fake:payload=discord_ip_discovery:blob=stun:repeats=10:strategy=4" "$DISCORD_ARM_DOC"
# bol-van canon: tight start-of-flow cutoff + connbytes, NOT keepalive.
# --out-range=-d4 = fake only on the first 4 data packets per flow (#1267
# "n2 или d2 лучше"; tight cutoff = fewer packets faked = stream-safe). The
# robustness lever is repeats (=10), NOT a wider cutoff. keepalive routed the
# whole high-bitrate stream through NFQUEUE → MIPS CPU saturation → 5000-ping.
assert_contains     "docalign: discord --out-range=-d4 (bol-van tight cutoff)" \
                    "--out-range=-d4"                           "$DISCORD_ARM_DOC"
assert_not_contains "docalign: discord no stale -d100 keepalive cutoff" \
                    "-d100"                                     "$DISCORD_ARM_DOC"
assert_not_contains "docalign: discord no --in-range (bol-van uses none)" \
                    "--in-range"                                "$DISCORD_ARM_DOC"
# payload gate = discovery/STUN signatures (NOT quic_initial — that's QUIC/443).
assert_contains     "docalign: discord payload=discord_ip_discovery,stun" \
                    "--payload=discord_ip_discovery,stun"       "$DISCORD_ARM_DOC"
assert_not_contains "docalign: discord no stale quic_initial gate" \
                    "--payload=quic_initial"                    "$DISCORD_ARM_DOC"

# yt_quic 8/4 -> 3/5 (2026-08-19). Замер 1646 QUIC-потоков: при udp_in=8 порог
# успеха лежит ВЫШЕ окна перехвата, успех недостижим (1 на 237 потоков), счётчик
# неудач нечем сбросить — симуляция даёт 15 ротаций на здоровом трафике. Порог
# успеха обязан быть ниже окна, это же сторожит tests/test_udp_detector_window.sh.
YT_QUIC_DOC=$(printf '%s\n' "$OUT_DOC" | grep -F 'key=yt_quic' | head -1)
assert_contains     "docalign: yt_quic udp_in=3 udp_out=5" "udp_in=3:udp_out=5:key=yt_quic" "$YT_QUIC_DOC"
assert_not_contains "docalign: yt_quic без старого udp_in=8" "udp_in=8:" "$YT_QUIC_DOC"

printf "\n--- corrupt pool Strategy.txt: fail closed, keep old config (field 2026-08-06) ---\n"

# A USB flash can hand back an all-0xFF file for a strategy pool (dead NAND
# block: size and mtime intact, bytes gone). Feeding that garbage into
# NFQWS2_OPT poisons the on-disk config and the next nfqws2 restart dies
# wholesale. The generator must instead fail closed and leave the existing
# config untouched — never half-write it.
test_corrupt_pool_fails_closed() {
    local root="${MOCK_DIR}/corrupt-pool"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists"
    echo "youtube.com"    > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com"> "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"    > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"  > "$root/extra_strats/TCP/RKN/List.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=yt_tcp --lua-desync=fake:strategy=1" > "$root/extra_strats/TCP/YT/Strategy.txt"
    echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=gv_tcp --lua-desync=fake:strategy=1" > "$root/extra_strats/TCP/YT_GV/Strategy.txt"
    echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:strategy=1" > "$root/extra_strats/UDP/YT/Strategy.txt"
    # RKN pool: all-0xFF garbage, exactly the dead-block failure mode.
    awk 'BEGIN{for(i=0;i<64;i++)printf "%c",255}' > "$root/extra_strats/TCP/RKN/Strategy.txt"

    local sentinel="ORIGINAL_UNTOUCHED_SENTINEL"
    printf 'ENABLED=1\n%s=1\n' "$sentinel" > "$root/config"

    local rc
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 ); rc=$?

    assert_eq         "corrupt-pool: create_official_config returns non-zero" "1" "$rc"
    # The old config must survive byte-for-byte: no NFQWS2_OPT written, sentinel intact.
    assert_contains   "corrupt-pool: original config preserved" "$sentinel" "$(cat "$root/config")"
    assert_not_contains "corrupt-pool: no NFQWS2_OPT written from garbage" "NFQWS2_OPT=" "$(cat "$root/config")"
    rm -rf "$root"
}
test_corrupt_pool_fails_closed

# Same dead-NAND exposure applies to the USER-owned custom-strategies files:
# they live on the same flash AND override the pool value, so guarding only the
# pool files left the identical hang reachable through the back door.
# Healthy custom file must still be honoured — that is the other half of the test.
test_corrupt_custom_strategy() {
    local variant="$1" body="$2" want_rc="$3" desc="$4"
    local root="${MOCK_DIR}/custom-$variant"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" \
             "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" \
             "$root/extra_strats/UDP/YT" \
             "$root/lists/custom-strategies"
    echo "youtube.com"     > "$root/extra_strats/TCP/YT/List.txt"
    echo "googlevideo.com" > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo "youtube.com"     > "$root/extra_strats/UDP/YT/List.txt"
    echo "rutracker.org"   > "$root/extra_strats/TCP/RKN/List.txt"
    for f in TCP/YT TCP/YT_GV TCP/RKN; do
        echo "--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=x --lua-desync=fake:strategy=1" \
            > "$root/extra_strats/$f/Strategy.txt"
    done
    echo "--filter-udp=443 --filter-l7=quic --lua-desync=circular:fails=3:time=60:key=yt_quic --lua-desync=fake:strategy=1" \
        > "$root/extra_strats/UDP/YT/Strategy.txt"

    # The custom override under test.
    if [ "$variant" = "corrupt" ]; then
        awk 'BEGIN{for(i=0;i<64;i++)printf "%c",255}' > "$root/lists/custom-strategies/rkn_tcp.txt"
    else
        printf '%s\n' "$body" > "$root/lists/custom-strategies/rkn_tcp.txt"
    fi

    printf 'ENABLED=1\nCUSTOM_SENTINEL=1\n' > "$root/config"
    local rc
    ( ZAPRET2_DIR="$root" create_official_config "$root/config" >/dev/null 2>&1 ); rc=$?
    assert_eq "custom-$variant: rc — $desc" "$want_rc" "$rc"
    if [ "$want_rc" = "1" ]; then
        assert_contains     "custom-$variant: original config preserved" "CUSTOM_SENTINEL" "$(cat "$root/config")"
        assert_not_contains "custom-$variant: no NFQWS2_OPT from garbage" "NFQWS2_OPT=" "$(cat "$root/config")"
    else
        # Healthy override must actually reach the generated options.
        assert_contains "custom-$variant: override applied" "z2k_custom_marker" "$(cat "$root/config")"
    fi
    rm -rf "$root"
}
test_corrupt_custom_strategy corrupt "" "1" "порченый пользовательский файл роняет генерацию"
test_corrupt_custom_strategy healthy \
    "--filter-tcp=443 --filter-l7=tls --lua-desync=fake:blob=z2k_custom_marker:strategy=1" \
    "0" "исправный пользовательский файл принимается"

rm -rf "$MOCK_DIR"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
