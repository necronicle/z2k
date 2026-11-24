#!/bin/sh
# tests/test_diag_autopilot.sh — проверка секции «=== Автопилот видео YouTube ===» в files/z2k-diag.sh.

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected '%s', got '%s'\n" "$1" "$2" "$3"; }

assert_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *)      fail "$1" "contains '$2'" "$3" ;;
    esac
}
assert_not_contains() {
    case "$3" in
        *"$2"*) fail "$1" "not contains '$2'" "$3" ;;
        *)      pass "$1" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

ZAPRET2_DIR="$SB/opt/zapret2";                  export ZAPRET2_DIR
INIT_SCRIPT="$SB/S99";                          export INIT_SCRIPT
Z2K_GV_POLICY_FILE="$SB/z2k-gv-policy.dat";     export Z2K_GV_POLICY_FILE
Z2K_GV_OBSERVED_FILE="$SB/z2k-gv-observed.tsv"; export Z2K_GV_OBSERVED_FILE

mkdir -p "$ZAPRET2_DIR/lua" "$SB/bin"
: > "$ZAPRET2_DIR/lua/z2k-gv-autopilot.lua"
: > "$ZAPRET2_DIR/lua/z2k-preflight.lua"
printf '#!/bin/sh\nexit 0\n' > "$INIT_SCRIPT"
chmod +x "$INIT_SCRIPT"

# Extract print_youtube_autopilot and print_preflight so test works standalone in POSIX sh
FN_EXTRACT="$SB/diag_funcs.sh"
awk '/^print_youtube_autopilot\(\)/,/^print_preflight\(\)/{ if (!/^print_preflight\(\)/) print } /^print_preflight\(\)/,/^}/' \
    "$SCRIPT_DIR/files/z2k-diag.sh" > "$FN_EXTRACT"

# 1. Отсутствует policy.dat
printf 'Z2K_YT_AUTOPILOT=auto\nZ2K_GV_SERVER_REPLY2=1\nZ2K_YT_QUIC_OFF=0\nZ2K_QUIC_OFF=0\n' > "$ZAPRET2_DIR/config"
rm -f "$Z2K_GV_POLICY_FILE" "$Z2K_GV_OBSERVED_FILE"
OUT1=$(ZAPRET2_DIR="$ZAPRET2_DIR" Z2K_GV_POLICY_FILE="$Z2K_GV_POLICY_FILE" Z2K_GV_OBSERVED_FILE="$Z2K_GV_OBSERVED_FILE" \
    "$Z2K_TEST_SH" -c '. "$0"; print_youtube_autopilot; print_preflight' "$FN_EXTRACT")
assert_contains "missing policy: section header" "=== Автопилот видео YouTube ===" "$OUT1"
assert_contains "missing policy: flags"          "autopilot=auto server_reply2=1" "$OUT1"
assert_contains "missing policy: absent notice"  "политика          : отсутствует" "$OUT1"
assert_contains "missing policy: lua present"    "модуль Lua        : есть" "$OUT1"

# 2. Заполненный policy.dat + observed.tsv
cat > "$Z2K_GV_POLICY_FILE" <<'POL'
type=header	version=1	updated=1790005000	usable_v4=3	usable_v6=1	baseline_rtt_ms=24	ggc_rtt_ms=4	global_quic_blocked=1	preflight_sni=www.google.com	resyn_delay_ms=105	preflight_giveup_ms=850	ggc_stall_guard_ms=1350
type=prefix	addr=178.219.240.0/24	kind=isp	verdict=good_ggc	quic_ok=1	rtt_ms=4
type=prefix	addr=142.250.74.0/24	kind=google	verdict=bad_bypassable	quic_ok=0	rtt_ms=30
type=ip	addr=178.219.240.10	kind=isp	verdict=good_ggc	quic_ok=1	rtt_ms=4
type=ip	addr=178.219.240.11	kind=isp	verdict=dead_l3	quic_ok=0	rtt_ms=0
type=ip	addr=142.250.74.10	kind=google	verdict=good_direct	quic_ok=1	rtt_ms=25
type=ip	addr=142.250.74.11	kind=google	verdict=bad_bypassable	quic_ok=0	rtt_ms=30
type=ip	addr=142.250.74.12	kind=google	verdict=bad_unbypassable	quic_ok=0	rtt_ms=35
type=ip	addr=142.250.74.13	kind=google	verdict=dead_ggc	quic_ok=0	rtt_ms=0
type=ip	addr=172.217.20.14	kind=play	verdict=good_direct	quic_ok=1	rtt_ms=26
POL
printf '178.219.240.10\trr1.googlevideo.com\n172.217.20.14\tgvt1.com\n' > "$Z2K_GV_OBSERVED_FILE"
cat >> "$ZAPRET2_DIR/config" <<'CFG'
Z2K_GV_PREFLIGHT_MODE=off
NFQWS2_OPT="--lua-desync=z2k_autopilot_quic --lua-desync=z2k_autopilot_tcp_fastfail --lua-desync=z2k_autopilot_stall_guard --lua-desync=z2k_autopilot_observe"
CFG
OUT2=$(ZAPRET2_DIR="$ZAPRET2_DIR" Z2K_GV_POLICY_FILE="$Z2K_GV_POLICY_FILE" Z2K_GV_OBSERVED_FILE="$Z2K_GV_OBSERVED_FILE" \
    PATH="$SB/bin:$PATH" "$Z2K_TEST_SH" -c '. "$0"; print_youtube_autopilot; print_preflight' "$FN_EXTRACT")
assert_contains "full policy: usable caches" "IPv4=3, IPv6=1" "$OUT2"
assert_contains "full policy: safety fuse active" "Safety Fuse       : АКТИВЕН (4 >= 1)" "$OUT2"
assert_contains "full policy: global_quic_blocked" "РЕЖЕТСЯ -> TCP (global_quic_blocked=1)" "$OUT2"
assert_contains "full policy: RTT & SNI" "baseline_rtt=24мс, ggc_rtt=4мс, preflight_sni=www.google.com" "$OUT2"
assert_contains "full policy: timings" "resyn_delay=105мс, giveup=850мс, stall_guard=1350мс" "$OUT2"
assert_contains "full policy: prefix summary" "префиксы (2)     : isp[good=1 bad=0 dead=0] google[good=0 byp=1 unbyp=0 dead=0]" "$OUT2"
assert_contains "full policy: ip summary" "адреса (7)       : isp[good=1 bad=0 dead=1] google[good=1 byp=1 unbyp=1 dead=1] play=1 quic_ok=3" "$OUT2"
assert_contains "full policy: DoH/DoT count" "наблюдения DoH/DoT: 2" "$OUT2"
assert_contains "preflight_mode=off recognized" "Z2K_GV_PREFLIGHT_MODE=off" "$OUT2"
assert_not_contains "preflight_mode=off no false РАСХОЖДЕНИЕ" "РАСХОЖДЕНИЕ" "$OUT2"

# 3. Safety Fuse fail-open & gvsub off / YouTube category off warnings
printf 'type=header\tupdated=1790005000\tusable_v4=0\tusable_v6=0\tbaseline_rtt_ms=0\tggc_rtt_ms=0\tglobal_quic_blocked=0\tpreflight_sni=www.google.com\n' > "$Z2K_GV_POLICY_FILE"
OUT3=$(ZAPRET2_DIR="$ZAPRET2_DIR" Z2K_GV_POLICY_FILE="$Z2K_GV_POLICY_FILE" Z2K_GV_OBSERVED_FILE="$Z2K_GV_OBSERVED_FILE" \
    "$Z2K_TEST_SH" -c '. "$0"; print_youtube_autopilot' "$FN_EXTRACT")
assert_contains "fail-open printed when 0+0" "Safety Fuse       : FAIL-OPEN" "$OUT3"

printf 'Z2K_YT_AUTOPILOT=auto\nZ2K_GV_SERVER_REPLY2=0\n' > "$ZAPRET2_DIR/config"
OUT4=$(ZAPRET2_DIR="$ZAPRET2_DIR" Z2K_GV_POLICY_FILE="$Z2K_GV_POLICY_FILE" Z2K_GV_OBSERVED_FILE="$Z2K_GV_OBSERVED_FILE" \
    "$Z2K_TEST_SH" -c '. "$0"; print_youtube_autopilot' "$FN_EXTRACT")
assert_contains "warns when gvsub disabled under autopilot" "gvsub отключён (Z2K_GV_SERVER_REPLY2=0)" "$OUT4"

printf 'Z2K_CATEGORY_YOUTUBE=0\nZ2K_YT_AUTOPILOT=auto\nZ2K_GV_SERVER_REPLY2=1\n' > "$ZAPRET2_DIR/config"
OUT5=$(ZAPRET2_DIR="$ZAPRET2_DIR" Z2K_GV_POLICY_FILE="$Z2K_GV_POLICY_FILE" Z2K_GV_OBSERVED_FILE="$Z2K_GV_OBSERVED_FILE" \
    "$Z2K_TEST_SH" -c '. "$0"; print_youtube_autopilot' "$FN_EXTRACT")
assert_contains "prints category youtube off note" "категория YouTube : выключена" "$OUT5"

# 4. Real z2k-diag.sh --short runs cleanly
if ZAPRET2_DIR="$ZAPRET2_DIR" "$Z2K_TEST_SH" "$SCRIPT_DIR/files/z2k-diag.sh" --short >/dev/null 2>&1; then
    pass "z2k-diag.sh --short exits 0"
else
    fail "z2k-diag.sh --short" "exit 0" "non-zero"
fi

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
