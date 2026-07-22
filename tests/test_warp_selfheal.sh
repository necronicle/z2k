#!/bin/sh
# tests/test_warp_selfheal.sh — HARD test of the two usque-restarting paths added
# to z2k-warp.sh (p-64.1): the one-time IFACE_IP subnet migration (warp_write_iface_ip)
# and the cooldown-guarded down-tunnel kick (warp_usque_kick). Both restart usque, so
# this locks their guards — a regression here reintroduces the r-61.x restart storm or
# clobbers a user's own IFACE_IP. Drives the REAL functions (sourced with
# Z2K_WARP_SOURCE_ONLY=1) with a stubbed S51usque. POSIX sh (busybox ash) compatible.

TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# Source the real script as a library (dispatch guarded off).
Z2K_WARP_SOURCE_ONLY=1
export Z2K_WARP_SOURCE_ONLY
# shellcheck disable=SC1091
. "$SCRIPT_DIR/files/z2k-warp.sh"

# Re-point globals at the sandbox AFTER sourcing (the script hard-codes /opt paths).
USQUE_CONF="$SB/usque.conf"
USQUE_INIT="$SB/S51usque"
WARP_KICK_STAMP="$SB/kick.stamp"
WARP_KICK_COOLDOWN=300
WARP_IFACE_IP="172.16.240.1"

# Stub S51usque: count every `restart` invocation.
RESTARTS="$SB/restart_count"
: > "$RESTARTS"
cat > "$USQUE_INIT" <<EOF
#!/bin/sh
[ "\$1" = restart ] && echo x >> "$RESTARTS"
exit 0
EOF
chmod 755 "$USQUE_INIT"
kicks() { wc -l < "$RESTARTS" | tr -d ' '; }
ifip_lines() { c=$(grep -cE '^IFACE_IP=' "$USQUE_CONF" 2>/dev/null); echo "${c:-0}"; }

# ---- warp_write_iface_ip -----------------------------------------------------
printf "\n--- W1: fresh conf (only commented default) -> writes our IFACE_IP, rc=0 ---\n"
printf '%s\n' '# usque config' '# IFACE_IP="172.16.0.1"' 'HTTP2_ENABLE=1' > "$USQUE_CONF"
warp_write_iface_ip; rc=$?
assert_eq "W1 rc=0 (wrote)"                 "0" "$rc"
assert_eq "W1 exactly one IFACE_IP= line"   "1" "$(ifip_lines)"
assert_eq "W1 value is our pin"             "172.16.240.1" "$(grep -E '^IFACE_IP=' "$USQUE_CONF" | sed 's/^IFACE_IP="\([^"]*\)".*/\1/')"

printf "\n--- W2: run again -> idempotent (rc=1, no second line) ---\n"
warp_write_iface_ip; rc=$?
assert_eq "W2 rc=1 (nothing to do)"         "1" "$rc"
assert_eq "W2 still exactly one line"       "1" "$(ifip_lines)"

printf "\n--- W3: user already set their own IFACE_IP -> never clobbered ---\n"
printf '%s\n' 'HTTP2_ENABLE=1' 'IFACE_IP="10.9.9.9"' > "$USQUE_CONF"
warp_write_iface_ip; rc=$?
assert_eq "W3 rc=1 (respects user)"         "1" "$rc"
assert_eq "W3 user value untouched"         "10.9.9.9" "$(grep -E '^IFACE_IP=' "$USQUE_CONF" | sed 's/^IFACE_IP="\([^"]*\)".*/\1/')"

printf "\n--- W4: commented-out IFACE_IP is NOT a match -> writes ---\n"
printf '%s\n' '#IFACE_IP="1.2.3.4"' '  # IFACE_IP="5.6.7.8"' > "$USQUE_CONF"
warp_write_iface_ip; rc=$?
assert_eq "W4 rc=0 (commented ignored)"     "0" "$rc"
assert_eq "W4 our pin appended"             "172.16.240.1" "$(grep -E '^IFACE_IP=' "$USQUE_CONF" | sed 's/^IFACE_IP="\([^"]*\)".*/\1/')"

printf "\n--- W5: missing conf -> rc=1, no crash ---\n"
rm -f "$USQUE_CONF"
warp_write_iface_ip; rc=$?
assert_eq "W5 rc=1 (no conf)"               "1" "$rc"

# ---- warp_usque_kick (cooldown) ----------------------------------------------
# Deterministic clock: shadow `date` so warp_usque_kick's `date +%s` returns a fixed
# value. With the real clock, the 299s-vs-300s boundary (K3) flaked on wall-clock drift
# between capturing NOW here and the kick reading date +%s a second later.
FAKE_NOW=1700000000
date() { echo "$FAKE_NOW"; }
NOW="$FAKE_NOW"
printf "\n--- K1: no stamp -> kicks + writes stamp ---\n"
rm -f "$WARP_KICK_STAMP"; : > "$RESTARTS"
warp_usque_kick
assert_eq "K1 one restart"                  "1" "$(kicks)"
assert_eq "K1 stamp written"                "1" "$( [ -f "$WARP_KICK_STAMP" ] && echo 1 || echo 0 )"

printf "\n--- K2: fresh stamp (age 0) -> cooldown, NO kick ---\n"
: > "$RESTARTS"; echo "$NOW" > "$WARP_KICK_STAMP"
warp_usque_kick
assert_eq "K2 zero restarts (in cooldown)"  "0" "$(kicks)"

printf "\n--- K3: stamp just inside cooldown (age 299 < 300) -> NO kick ---\n"
: > "$RESTARTS"; echo "$((NOW - 299))" > "$WARP_KICK_STAMP"
warp_usque_kick
assert_eq "K3 zero restarts"                "0" "$(kicks)"

printf "\n--- K4: stale stamp (age 1000 >= 300) -> kicks ---\n"
: > "$RESTARTS"; echo "$((NOW - 1000))" > "$WARP_KICK_STAMP"
warp_usque_kick
assert_eq "K4 one restart (cooldown elapsed)" "1" "$(kicks)"

printf "\n--- K5: corrupt stamp (non-numeric) -> treated as age-infinite, kicks ---\n"
: > "$RESTARTS"; echo "garbage" > "$WARP_KICK_STAMP"
warp_usque_kick
assert_eq "K5 one restart (bad stamp)"      "1" "$(kicks)"

printf "\n--- K6: no S51usque present -> no-op, no crash ---\n"
: > "$RESTARTS"; rm -f "$WARP_KICK_STAMP"
_saved="$USQUE_INIT"; USQUE_INIT="$SB/nope"
warp_usque_kick; rc=$?
USQUE_INIT="$_saved"
assert_eq "K6 rc=0 (graceful)"              "0" "$rc"
assert_eq "K6 zero restarts"                "0" "$(kicks)"

printf "\n--- K7: future stamp (clock skewed ahead at boot) -> reset, kicks ---\n"
: > "$RESTARTS"; echo "$((NOW + 100000))" > "$WARP_KICK_STAMP"
warp_usque_kick
assert_eq "K7 one restart (future stamp reset)" "1" "$(kicks)"

printf "\n--- K8: stamp unwritable (read-only/full /tmp) -> NO restart (storm guard) ---\n"
: > "$RESTARTS"
_savedstamp="$WARP_KICK_STAMP"; WARP_KICK_STAMP="$SB/no-such-dir/kick.stamp"
warp_usque_kick
WARP_KICK_STAMP="$_savedstamp"
assert_eq "K8 zero restarts (stamp write failed)" "0" "$(kicks)"

printf "\n=== warp selfheal tests: %d passed, %d failed ===\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
