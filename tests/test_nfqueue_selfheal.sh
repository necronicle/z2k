#!/bin/sh
# tests/test_nfqueue_selfheal.sh
# z2k-nfqueue-selfheal.sh must re-apply the firewall (restart_fw) ONLY when
# nfqws2 is running, the WAN is present, the feature is enabled, and the NFQUEUE
# rules are gone (count==0) — and must coalesce with the netfilter.d hook via the
# shared restart-fw mutex + debounce. Runs the real script with env-overridden
# paths + mock iptables/pidof/ip on PATH + a counting mock INIT_SCRIPT. POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
SH="$HERE/files/z2k-nfqueue-selfheal.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nfqheal.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

# counting mock INIT_SCRIPT (one line per restart_fw)
CNT="$TMP/count"; : > "$CNT"
INIT="$TMP/S99zapret2"
cat > "$INIT" <<EOF
#!/bin/sh
[ "\$1" = start_fw ] && echo x >> "$CNT"
exit 0
EOF
chmod +x "$INIT"

# mock bin: iptables (NFQ copies of an NFQUEUE line), pidof, ip (default route)
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/iptables" <<'EOF'
#!/bin/sh
# only care about `-t mangle -S`. IPT_FAIL=1 simulates an xtables-lock race
# (dump exits non-zero) so we can assert the false-drop guard.
[ "${IPT_FAIL:-0}" = 1 ] && exit 1
n="${NFQ:-0}"; i=0
while [ "$i" -lt "$n" ]; do echo "-A POSTROUTING -j NFQUEUE --queue-num 200 --queue-bypass"; i=$((i+1)); done
exit 0
EOF
cat > "$BIN/pidof" <<'EOF'
#!/bin/sh
[ "${PIDOF_OK:-1}" = 1 ] && { echo 12345; exit 0; }
exit 1
EOF
cat > "$BIN/ip6tables" <<'EOF'
#!/bin/sh
# only care about `-t mangle -S`
n="${NFQ6:-0}"; i=0
while [ "$i" -lt "$n" ]; do echo "-A POSTROUTING -j NFQUEUE --queue-num 200 --queue-bypass"; i=$((i+1)); done
exit 0
EOF
cat > "$BIN/ip" <<'EOF'
#!/bin/sh
# "ip -4 route show default" / "ip -6 route show default"
case "$1" in
  -6) [ "${ROUTE6_OK:-0}" = 1 ] && echo "default via fe80::1 dev eth3" ;;
  *)  [ "${ROUTE_OK:-1}" = 1 ] && echo "default via 10.0.0.1 dev eth3" ;;
esac
exit 0
EOF
chmod +x "$BIN/iptables" "$BIN/ip6tables" "$BIN/pidof" "$BIN/ip"

CFG="$TMP/config"; printf 'ENABLED=1\n' > "$CFG"
LOCK="$TMP/lock"; LAST="$TMP/last"; LOG="$TMP/log"

# PATH includes /opt/sbin so the script skips its own PATH-prepend and our $BIN
# mocks win over any real iptables/ip on the CI host.
run() {  # env: NFQ, NFQ6 (def NFQ), PIDOF_OK, ROUTE_OK (v4 def 1), ROUTE6_OK (v6 def 0)
    env NFQ="${NFQ:-0}" NFQ6="${NFQ6:-${NFQ:-0}}" PIDOF_OK="${PIDOF_OK:-1}" \
        ROUTE_OK="${ROUTE_OK:-1}" ROUTE6_OK="${ROUTE6_OK:-0}" IPT_FAIL="${IPT_FAIL:-0}" \
        PATH="$BIN:/opt/sbin:/opt/bin:$PATH" \
        INIT_SCRIPT="$INIT" ZAPRET_CONFIG="$CFG" \
        RESTART_FW_LOCK="$LOCK" RESTART_FW_LAST="$LAST" \
        MIN_INTERVAL="${MI:-15}" LOCK_STALE="${LS:-60}" SELFHEAL_LOG="$LOG" \
        CONFIRM_SETTLE="${CS:-0}" \
        sh "$SH"
}
count() { wc -l < "$CNT" | tr -d ' '; }
# Hermetic: a var-assignment PREFIX on a function call persists in the shell
# (POSIX behaviour) — e.g. `IPT_FAIL=1 run` would leak into the next test. Clear
# every toggle so each case starts from run()'s documented defaults.
reset() { : > "$CNT"; rm -rf "$LOCK"; rm -f "$LAST"; unset NFQ NFQ6 PIDOF_OK ROUTE_OK ROUTE6_OK IPT_FAIL MI LS CS; }

# --- 1) the bug condition: nfqws2 up, WAN up, enabled, 0 NFQUEUE -> restart_fw
reset; NFQ=0 PIDOF_OK=1 ROUTE_OK=1 run
n=$(count); [ "$n" = "1" ] && ok "0 rules + nfqws2 up + WAN -> restart_fw" || no "heal fires" "1" "$n"
[ ! -d "$LOCK" ] && ok "mutex released after run" || no "mutex released" "absent" "present"

# --- 2) rules present -> no-op --------------------------------------------
reset; NFQ=6 PIDOF_OK=1 ROUTE_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "rules present -> no restart_fw" || no "rules present noop" "0" "$n"

# --- 3) nfqws2 down -> no-op (never queue to a dead consumer) --------------
reset; NFQ=0 PIDOF_OK=0 ROUTE_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "nfqws2 down -> no restart_fw" || no "nfqws2 down noop" "0" "$n"

# --- 4) WAN down (no route, no WAN_IFACE) -> no-op (avoid restart storm) ---
reset; NFQ=0 PIDOF_OK=1 ROUTE_OK=0 run
n=$(count); [ "$n" = "0" ] && ok "WAN down -> no restart_fw" || no "WAN down noop" "0" "$n"

# --- 5) WAN_IFACE in config satisfies WAN even with no default route -------
reset; printf 'ENABLED=1\nWAN_IFACE=ppp0\n' > "$CFG"
NFQ=0 PIDOF_OK=1 ROUTE_OK=0 run
n=$(count); [ "$n" = "1" ] && ok "WAN_IFACE set -> heal fires without default route" || no "WAN_IFACE heals" "1" "$n"
printf 'ENABLED=1\n' > "$CFG"

# --- 6) disabled -> no-op --------------------------------------------------
reset; printf 'ENABLED=0\n' > "$CFG"
NFQ=0 PIDOF_OK=1 ROUTE_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "ENABLED=0 -> no restart_fw" || no "disabled noop" "0" "$n"
printf 'ENABLED=1\n' > "$CFG"

# --- 7) debounce: fresh RESTART_FW_LAST (hook just ran) -> skip ------------
reset; date +%s > "$LAST"
NFQ=0 PIDOF_OK=1 ROUTE_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "fresh restart-fw debounce -> skip" || no "debounce skip" "0" "$n"

# --- 8) mutex busy (hook re-applying) -> skip ------------------------------
reset; mkdir -p "$LOCK"
NFQ=0 PIDOF_OK=1 ROUTE_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "mutex held -> skip (coalesced)" || no "mutex skip" "0" "$n"

# --- 9) stale lock (>LOCK_STALE) is cleared, then heal fires ---------------
reset; mkdir -p "$LOCK"; touch -d '2000-01-01' "$LOCK" 2>/dev/null || touch -t 200001010000 "$LOCK" 2>/dev/null
NFQ=0 PIDOF_OK=1 ROUTE_OK=1 LS=60 run
n=$(count); [ "$n" = "1" ] && ok "stale mutex cleared -> heal fires" || no "stale mutex" "1" "$n"

# --- 10) both families healthy (v6 route up + v6 rules) -> no-op ----------
reset; NFQ=6 NFQ6=6 PIDOF_OK=1 ROUTE_OK=1 ROUTE6_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "v4+v6 rules present -> no restart_fw" || no "dualstack noop" "0" "$n"

# --- 11) v6 route UP but v6 NFQUEUE gone (v6 active) -> heal (v6 boot-race) -
reset; NFQ=6 NFQ6=0 PIDOF_OK=1 ROUTE_OK=1 ROUTE6_OK=1 run
n=$(count); [ "$n" = "1" ] && ok "v6-only NFQUEUE loss w/ v6 WAN -> restart_fw" || no "v6 loss heals" "1" "$n"

# --- 12) v6 rules gone but DISABLE_IPV6=1 -> no-op (v6 off, don't care) ----
reset; printf 'ENABLED=1\nDISABLE_IPV6=1\n' > "$CFG"
NFQ=6 NFQ6=0 PIDOF_OK=1 ROUTE_OK=1 ROUTE6_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "DISABLE_IPV6=1 -> v6 loss ignored" || no "v6 disabled noop" "0" "$n"
printf 'ENABLED=1\n' > "$CFG"

# --- 13) REGRESSION: v6 active + v6 rules 0 but NO v6 route -> no-op -------
#   (v6 enabled in config, ISP gives no v6 -> get_wan_ifaces6 empty -> post6
#    correctly skips -> 0 v6 rules is NORMAL, must NOT restart_fw. This is the
#    live-router false-positive the first v6 patch would have caused.)
reset; NFQ=6 NFQ6=0 PIDOF_OK=1 ROUTE_OK=1 ROUTE6_OK=0 run
n=$(count); [ "$n" = "0" ] && ok "v6 enabled but no v6 WAN -> no restart_fw" || no "v6 no-WAN noop" "0" "$n"

# --- 14) FALSE-DROP guard: iptables -S fails on an xtables-lock race with NDM.
#   A failed dump must NOT read as "0 NFQUEUE rules" (that was the phantom
#   ~280x/day storm: -w-less dump + `|| true` swallowed the lock error). With the
#   guard, dump-fail -> state unknown -> NOT missing -> no re-apply. On the old
#   code this fired (count=1); the fix makes it a no-op.
reset; NFQ=0 IPT_FAIL=1 PIDOF_OK=1 ROUTE_OK=1 ROUTE6_OK=0 run
n=$(count); [ "$n" = "0" ] && ok "dump-fail (lock race) -> no false restart_fw" || no "false-drop guard" "0" "$n"

# --- 15) PARTIAL wipe (issue #23): a sustained ~5s NDM regen collapses NFQUEUE
#   to 1 (below the active-family floor of 3). The old `-eq 0` gate was blind to
#   this and left YouTube dead until a manual S99zapret2 restart. NFQ_FLOOR=2 now
#   treats a stuck count of 1 as missing and heals it.
reset; NFQ=1 PIDOF_OK=1 ROUTE_OK=1 run
n=$(count); [ "$n" = "1" ] && ok "partial wipe v4 (count==1 < floor) -> heal fires (#23)" || no "v4 partial heals" "1" "$n"

# --- 16) FIX #1: DISABLE_IPV4=1 must NOT fire on a below-floor v4 count. start_fw
#   builds NO v4 NFQUEUE when v4 is disabled, so 0 v4 rules is NORMAL, not a wipe.
#   Without the DISABLE_IPV4 gate this re-applies EVERY tick forever (v4 route up +
#   0 rules < floor). Both families disabled here -> isolates the guard.
reset; printf 'ENABLED=1\nDISABLE_IPV4=1\nDISABLE_IPV6=1\n' > "$CFG"
NFQ=0 NFQ6=0 PIDOF_OK=1 ROUTE_OK=1 ROUTE6_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "DISABLE_IPV4=1 + 0 v4 rules -> no re-apply (fix #1)" || no "DISABLE_IPV4 guard" "0" "$n"
printf 'ENABLED=1\n' > "$CFG"

# --- 17) floor boundary: count == NFQ_FLOOR is HEALTHY (not < floor) -> no-op.
#   Guards an off-by-one that would heal a legit minimal box forever.
reset; NFQ=2 PIDOF_OK=1 ROUTE_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "count == floor (2) -> no re-apply" || no "floor boundary noop" "0" "$n"

# --- 18) PARTIAL wipe on v6 (v6 active): v4 full, v6 stuck at 1 -> heal (per-family floor)
reset; NFQ=6 NFQ6=1 PIDOF_OK=1 ROUTE_OK=1 ROUTE6_OK=1 run
n=$(count); [ "$n" = "1" ] && ok "partial wipe v6 (count==1 < floor) -> heal fires" || no "v6 partial heals" "1" "$n"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
