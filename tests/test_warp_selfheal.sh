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

# Stub usque binary for enrollment tests: count `register` calls; create the session file
# (arg after --config) iff the success flag is present, to simulate reg success/failure.
USQUE_BIN="$SB/usque-stub"
USQUE_SESSION="$SB/session.conf"
WARP_REG_COUNT="$SB/regcount"
WARP_REG_STAMP="$SB/reg.stamp"
WARP_REG_COOLDOWN=600
WARP_REG_DIRECT_TRIES=3
WARP_VPS_PROXY="http://z2kwarp:pw@vps.example:8119"
REG_CALLS="$SB/reg_calls"; : > "$REG_CALLS"
REG_SUCCEED_FLAG="$SB/reg_succeed"
export REG_CALLS REG_SUCCEED_FLAG
cat > "$USQUE_BIN" <<'EOF'
#!/bin/sh
[ "$1" = register ] && echo x >> "$REG_CALLS"
if [ -f "$REG_SUCCEED_FLAG" ]; then
    cfg=""; p=""
    for a in "$@"; do [ "$p" = --config ] && cfg="$a"; p="$a"; done
    [ -n "$cfg" ] && echo "stub-session-key" > "$cfg"
fi
exit 0
EOF
chmod 755 "$USQUE_BIN"
regcalls() { wc -l < "$REG_CALLS" | tr -d ' '; }

# Controllable `ip` stub for warp_link_up link-state tests. State file holds up|down|gone.
IP_LINK_STATE="$SB/ip_link_state"
IP_LINK_SET="$SB/ip_link_set_calls"; : > "$IP_LINK_SET"
ip() {
    if [ "$1" = link ] && [ "$2" = show ] && [ "$3" = "$WARP_IFACE" ]; then
        case "$(cat "$IP_LINK_STATE" 2>/dev/null)" in
            gone) return 1 ;;
            up)   echo "96: $WARP_IFACE: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280"; return 0 ;;
            *)    echo "96: $WARP_IFACE: <POINTOPOINT,MULTICAST,NOARP> mtu 1280"; return 0 ;;
        esac
    fi
    if [ "$1" = link ] && [ "$2" = set ] && [ "$3" = "$WARP_IFACE" ]; then
        echo x >> "$IP_LINK_SET"; echo up > "$IP_LINK_STATE"; return 0
    fi
    return 0
}
linksets() { wc -l < "$IP_LINK_SET" | tr -d ' '; }

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

# ---- warp_enroll_or_fallback / warp_vps_register (date still mocked -> FAKE_NOW) ----
printf "\n--- R1: session.conf exists -> already enrolled (rc=1), counter reset ---\n"
echo "existing-key" > "$USQUE_SESSION"; echo "2" > "$WARP_REG_COUNT"; : > "$RESTARTS"; : > "$REG_CALLS"
warp_enroll_or_fallback; rc=$?
assert_eq "R1 rc=1 (already enrolled)"      "1" "$rc"
assert_eq "R1 counter file removed"         "0" "$( [ -f "$WARP_REG_COUNT" ] && echo 1 || echo 0 )"
assert_eq "R1 no restart + no register"     "0-0" "$(kicks)-$(regcalls)"

printf "\n--- R2: no session, under direct tries -> direct `usque register`, NO restart, counter++ ---\n"
# The direct retry runs `usque register` itself instead of restarting S51usque: same HTTPS
# attempt against the reg API (so autocircular still gets to rotate), none of the NDM
# interface churn a restart-per-tick caused while enrollment kept failing.
rm -f "$USQUE_SESSION" "$WARP_REG_COUNT" "$WARP_REG_STAMP" "$REG_SUCCEED_FLAG"; : > "$RESTARTS"; : > "$REG_CALLS"
warp_enroll_or_fallback; rc=$?
assert_eq "R2 rc=0 (handled)"               "0" "$rc"
assert_eq "R2 one direct register call"     "1" "$(regcalls)"
assert_eq "R2 no usque restart on failure"  "0" "$(kicks)"
assert_eq "R2 counter now 1"                "1" "$(cat "$WARP_REG_COUNT" 2>/dev/null)"

printf "\n--- R2b: direct enroll SUCCEEDS -> session written + exactly one usque restart ---\n"
rm -f "$USQUE_SESSION" "$WARP_REG_COUNT"; : > "$RESTARTS"; : > "$REG_CALLS"; touch "$REG_SUCCEED_FLAG"
warp_enroll_or_fallback; rc=$?
assert_eq "R2b rc=0 (handled)"              "0" "$rc"
assert_eq "R2b session.conf created"        "1" "$( [ -s "$USQUE_SESSION" ] && echo 1 || echo 0 )"
assert_eq "R2b exactly one restart"         "1" "$(kicks)"
rm -f "$REG_SUCCEED_FLAG"

printf "\n--- R3: no session, direct tries exhausted -> VPS register attempted ---\n"
rm -f "$USQUE_SESSION" "$WARP_REG_STAMP" "$REG_SUCCEED_FLAG"; echo "3" > "$WARP_REG_COUNT"; : > "$RESTARTS"; : > "$REG_CALLS"
warp_enroll_or_fallback; rc=$?
assert_eq "R3 rc=0 (handled)"               "0" "$rc"
assert_eq "R3 one VPS register call"        "1" "$(regcalls)"

printf "\n--- R3b: after the VPS round the counter RESETS -> direct is tried again ---\n"
# Never defect to the relay for good: a dead/rotated relay must not leave the router
# permanently unenrollable once the ISP stops blocking the reg API.
assert_eq "R3b counter reset to 0"          "0" "$(cat "$WARP_REG_COUNT" 2>/dev/null)"
rm -f "$USQUE_SESSION"; : > "$REG_CALLS"; : > "$RESTARTS"
warp_enroll_or_fallback >/dev/null 2>&1
assert_eq "R3b next round goes direct"      "1" "$(regcalls)"
assert_eq "R3b counter back to 1"           "1" "$(cat "$WARP_REG_COUNT" 2>/dev/null)"

printf "\n--- R4: VPS register cooldown -> no register within window ---\n"
rm -f "$USQUE_SESSION"; : > "$REG_CALLS"; echo "$NOW" > "$WARP_REG_STAMP"
warp_vps_register; rc=$?
assert_eq "R4 rc=1 (cooldown)"              "1" "$rc"
assert_eq "R4 zero register calls"          "0" "$(regcalls)"

printf "\n--- R5: VPS register success -> session written, usque restarted, rc=0 ---\n"
rm -f "$USQUE_SESSION" "$WARP_REG_STAMP"; : > "$RESTARTS"; : > "$REG_CALLS"; touch "$REG_SUCCEED_FLAG"
warp_vps_register; rc=$?
assert_eq "R5 rc=0 (enrolled via VPS)"      "0" "$rc"
assert_eq "R5 session.conf created"         "1" "$( [ -s "$USQUE_SESSION" ] && echo 1 || echo 0 )"
assert_eq "R5 usque restarted"              "1" "$(kicks)"
rm -f "$REG_SUCCEED_FLAG"

# ---- warp_link_up (opkgtun0 link flakiness) ----
printf "\n--- L1: link down + device present -> brought up (1 set call) ---\n"
echo down > "$IP_LINK_STATE"; : > "$IP_LINK_SET"
warp_link_up; rc=$?
assert_eq "L1 rc=0"                          "0" "$rc"
assert_eq "L1 ip link set up called once"    "1" "$(linksets)"
assert_eq "L1 link now up"                   "up" "$(cat "$IP_LINK_STATE")"

printf "\n--- L2: link already up -> no-op (0 set calls) ---\n"
echo up > "$IP_LINK_STATE"; : > "$IP_LINK_SET"
warp_link_up; rc=$?
assert_eq "L2 rc=0"                          "0" "$rc"
assert_eq "L2 no set call (already up)"      "0" "$(linksets)"

printf "\n--- L3: device gone -> rc=1, no set call ---\n"
echo gone > "$IP_LINK_STATE"; : > "$IP_LINK_SET"
warp_link_up; rc=$?
assert_eq "L3 rc=1 (no device)"              "1" "$rc"
assert_eq "L3 no set call"                   "0" "$(linksets)"

# ---- warp_usque_restart (stale running-config trap) ----
# S51usque sources usque.conf THEN usque.conf.run, and .run wins. It is removed only by
# fn_stop_internal, which `fn_stop` skips when the daemon is already dead — so a crashed
# daemon leaves a .run pinning the OLD address and our IFACE_IP pin never applies. Every
# restart we issue must drop it first.
USQUE_RUNCONF="$SB/usque.conf.run"
printf "\n--- U1: stale .run is removed before the restart ---\n"
: > "$RESTARTS"; echo 'IFACE_IP="172.16.1.100"' > "$USQUE_RUNCONF"
warp_usque_restart; rc=$?
assert_eq "U1 rc=0"                          "0" "$rc"
assert_eq "U1 stale .run gone"               "0" "$( [ -f "$USQUE_RUNCONF" ] && echo 1 || echo 0 )"
assert_eq "U1 usque restarted once"          "1" "$(kicks)"

printf "\n--- U2: no .run present -> still restarts, no crash ---\n"
: > "$RESTARTS"; rm -f "$USQUE_RUNCONF"
warp_usque_restart; rc=$?
assert_eq "U2 rc=0"                          "0" "$rc"
assert_eq "U2 usque restarted once"          "1" "$(kicks)"

printf "\n--- U3: no S51usque -> rc=1, no restart ---\n"
: > "$RESTARTS"; _saved="$USQUE_INIT"; USQUE_INIT="$SB/nope"
warp_usque_restart; rc=$?
USQUE_INIT="$_saved"
assert_eq "U3 rc=1 (nothing to restart)"     "1" "$rc"
assert_eq "U3 zero restarts"                 "0" "$(kicks)"

# ---- warp_tunnel_live / warp_live_cached (end-to-end liveness) ----
# The whole point: "opkgtun0 has an address" is not proof the tunnel carries traffic.
WARP_LIVE_STAMP="$SB/live.stamp"
WARP_LIVE_MAXAGE=180
CURL_OUT="$SB/curl_out"
curl() { cat "$CURL_OUT" 2>/dev/null; }   # shadows the real binary for the probe only

printf "\n--- P1: probe sees warp=on -> live, verdict cached as 1 ---\n"
echo up > "$IP_LINK_STATE"; printf 'colo=DME\nwarp=on\n' > "$CURL_OUT"; rm -f "$WARP_LIVE_STAMP"
warp_tunnel_live; rc=$?
assert_eq "P1 rc=0 (live)"                   "0" "$rc"
assert_eq "P1 cached verdict is 1"           "1" "$(warp_live_cached)"

printf "\n--- P2: interface up but warp=off -> DEAD (this is the case nothing caught) ---\n"
printf 'colo=DME\nwarp=off\n' > "$CURL_OUT"
warp_tunnel_live; rc=$?
assert_eq "P2 rc=1 (dead despite live iface)" "1" "$rc"
assert_eq "P2 cached verdict is 0"           "0" "$(warp_live_cached)"

printf "\n--- P3: probe returns nothing (tunnel black-holes) -> dead ---\n"
: > "$CURL_OUT"
warp_tunnel_live; rc=$?
assert_eq "P3 rc=1 (no answer = dead)"       "1" "$rc"

printf "\n--- P4: device gone -> dead without probing ---\n"
echo gone > "$IP_LINK_STATE"; printf 'warp=on\n' > "$CURL_OUT"
warp_tunnel_live; rc=$?
assert_eq "P4 rc=1 (no device)"              "1" "$rc"
echo up > "$IP_LINK_STATE"

printf "\n--- C1: stale verdict reads as UNKNOWN, never as dead ---\n"
echo "$((FAKE_NOW - 1000)) 1" > "$WARP_LIVE_STAMP"
assert_eq "C1 too old -> empty (unknown)"    "" "$(warp_live_cached)"

printf "\n--- C2: corrupt / missing stamp -> unknown ---\n"
echo "garbage" > "$WARP_LIVE_STAMP"
assert_eq "C2 corrupt -> empty"              "" "$(warp_live_cached)"
rm -f "$WARP_LIVE_STAMP"
assert_eq "C2 missing -> empty"              "" "$(warp_live_cached)"

# ---- interface name is package-owned (found by the on-router E2E) ----
# The package's postinst takes the first FREE opkgtunN, so a router carrying a leftover
# opkgtun0 gets the real tunnel on opkgtun1. Hard-coding opkgtun0 routed and probed an orphan.
printf "\n--- I1: IFACE from usque.conf wins over the opkgtun0 default ---\n"
printf '%s\n' 'IFACE="opkgtun1"' 'HTTP2_ENABLE=1' > "$USQUE_CONF"
assert_eq "I1 resolves opkgtun1"             "opkgtun1" "$(warp_resolve_iface)"

printf "\n--- I2: missing / junk IFACE falls back to the default ---\n"
printf '%s\n' 'HTTP2_ENABLE=1' > "$USQUE_CONF"
assert_eq "I2 no IFACE -> default"           "opkgtun0" "$(warp_resolve_iface)"
printf '%s\n' 'IFACE="../etc/passwd"' > "$USQUE_CONF"
assert_eq "I2 junk IFACE -> default"         "opkgtun0" "$(warp_resolve_iface)"

# ---- IFACE_IP conflict healing (the failure NDM reported verbatim on the E2E) ----
#   Network::Interface::Ip error: "OpkgTun1": network 172.16.240.1/32 conflicts with
#   interface "OpkgTun0"
# A leftover interface holding the pinned address makes `interface up` fail, so the tunnel
# can never come up. The pin has to step aside.
ip_addr_show_out="$SB/ipaddr"
ip() {
    if [ "$1" = "-o" ]; then cat "$ip_addr_show_out" 2>/dev/null; return 0; fi
    if [ "$1" = link ] && [ "$2" = show ] && [ "$3" = "$WARP_IFACE" ]; then
        case "$(cat "$IP_LINK_STATE" 2>/dev/null)" in
            gone) return 1 ;;
            up)   echo "96: $WARP_IFACE: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280"; return 0 ;;
            *)    echo "96: $WARP_IFACE: <POINTOPOINT,MULTICAST,NOARP> mtu 1280"; return 0 ;;
        esac
    fi
    if [ "$1" = link ] && [ "$2" = set ] && [ "$3" = "$WARP_IFACE" ]; then
        echo x >> "$IP_LINK_SET"; echo up > "$IP_LINK_STATE"; return 0
    fi
    return 0
}
WARP_IFACE=opkgtun1
WARP_IFACE_IP=172.16.240.1
WARP_IFACE_IP_NET=172.16.240

printf "\n--- N1: pinned address free -> used as-is ---\n"
: > "$ip_addr_show_out"
assert_eq "N1 no conflict"                   "172.16.240.1" "$(warp_free_iface_ip)"

printf "\n--- N2: leftover interface holds the pin -> next free host chosen ---\n"
printf '40: opkgtun0    inet 172.16.240.1/32 scope global opkgtun0\n' > "$ip_addr_show_out"
assert_eq "N2 steps aside to .2"             "172.16.240.2" "$(warp_free_iface_ip)"

printf "\n--- N3: OUR OWN interface holding it is NOT a conflict ---\n"
printf '41: opkgtun1    inet 172.16.240.1/32 scope global opkgtun1\n' > "$ip_addr_show_out"
assert_eq "N3 keeps .1"                      "172.16.240.1" "$(warp_free_iface_ip)"

printf "\n--- N4: conflicting IFACE_IP already in usque.conf gets HEALED ---\n"
printf '40: opkgtun0    inet 172.16.240.1/32 scope global opkgtun0\n' > "$ip_addr_show_out"
printf '%s\n' 'IFACE="opkgtun1"' 'IFACE_IP="172.16.240.1"' > "$USQUE_CONF"
warp_write_iface_ip; rc=$?
assert_eq "N4 rc=0 (rewrote)"                "0" "$rc"
assert_eq "N4 moved off the conflict"        "172.16.240.2" "$(grep -E '^IFACE_IP=' "$USQUE_CONF" | sed 's/^IFACE_IP="\([^"]*\)".*/\1/')"
assert_eq "N4 still exactly one line"        "1" "$(ifip_lines)"

printf "\n--- N5: a NON-conflicting value (incl. the user's own) is never touched ---\n"
printf '%s\n' 'IFACE="opkgtun1"' 'IFACE_IP="10.9.9.9"' > "$USQUE_CONF"
warp_write_iface_ip; rc=$?
assert_eq "N5 rc=1 (left alone)"             "1" "$rc"
assert_eq "N5 user value intact"             "10.9.9.9" "$(grep -E '^IFACE_IP=' "$USQUE_CONF" | sed 's/^IFACE_IP="\([^"]*\)".*/\1/')"

# ---- FAIL OPEN: routing must never point into a tunnel that is not carrying traffic ----
# Field failure, r-65: the tunnel died, routing stayed applied, and every destination in the
# ipset (tens of thousands of Cloudflare/AWS/Sony/Epic networks) was blackholed instead of
# merely going untunnelled. Going direct is the pre-WARP status quo; blackholing is an outage.
PBR_UP_CALLS="$SB/pbr_up"; PBR_DOWN_CALLS="$SB/pbr_down"
: > "$PBR_UP_CALLS"; : > "$PBR_DOWN_CALLS"
warp_pbr_up()   { echo x >> "$PBR_UP_CALLS"; }
warp_pbr_down() { echo x >> "$PBR_DOWN_CALLS"; }
warp_ipset_load() { :; }
ipset() { return 0; }
warp_flag() { echo 1; }
warp_write_iface_ip() { return 1; }
warp_enroll_or_fallback() { return 1; }
warp_link_up() { return 0; }
ip() {   # interface present, addressed and UP — the "looks perfectly healthy" case
    if [ "$1" = "-o" ]; then echo "44: $WARP_IFACE    inet 172.16.240.2/32 scope global $WARP_IFACE"; return 0; fi
    if [ "$1" = link ]; then echo "44: $WARP_IFACE: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280"; return 0; fi
    return 0
}

printf "\n--- F1: probe says DEAD -> routing torn down, usque kicked ---\n"
: > "$PBR_UP_CALLS"; : > "$PBR_DOWN_CALLS"; : > "$RESTARTS"; rm -f "$WARP_KICK_STAMP"
warp_tunnel_live() { return 1; }
warp_selfheal
assert_eq "F1 routing NOT applied"           "0" "$(wc -l < "$PBR_UP_CALLS" | tr -d ' ')"
assert_eq "F1 routing torn down"             "1" "$(wc -l < "$PBR_DOWN_CALLS" | tr -d ' ')"
assert_eq "F1 usque kicked"                  "1" "$(kicks)"

printf "\n--- F2: probe says LIVE -> routing applied, no kick ---\n"
: > "$PBR_UP_CALLS"; : > "$PBR_DOWN_CALLS"; : > "$RESTARTS"; rm -f "$WARP_KICK_STAMP"
warp_tunnel_live() { return 0; }
warp_selfheal
assert_eq "F2 routing applied"               "1" "$(wc -l < "$PBR_UP_CALLS" | tr -d ' ')"
assert_eq "F2 routing NOT torn down"         "0" "$(wc -l < "$PBR_DOWN_CALLS" | tr -d ' ')"
assert_eq "F2 no kick on a healthy tunnel"   "0" "$(kicks)"

printf "\n=== warp selfheal tests: %d passed, %d failed ===\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
