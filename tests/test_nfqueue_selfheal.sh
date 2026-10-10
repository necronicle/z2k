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
[ "\$1" = start_fw ] && {
    echo x >> "$CNT"
    [ -n "\${REPAIR_MARKER:-}" ] && : > "\$REPAIR_MARKER"
}
exit 0
EOF
chmod +x "$INIT"

# mock bin: iptables (NFQ copies of an NFQUEUE line), pidof, ip (default route)
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/run"
cat > "$BIN/iptables" <<'EOF'
#!/bin/sh
# only care about `-t mangle -S`. IPT_FAIL=1 simulates an xtables-lock race
# (dump exits non-zero) so we can assert the false-drop guard.
[ "${IPT_FAIL:-0}" = 1 ] && exit 1
# RULES — настоящий вид правил (как в `iptables -t mangle -S` на Keenetic):
# «POSTROUTING:tcp INPUT:udp ...». Без RULES — NFQ безликих строк.
if [ -n "${RULES:-}" ]; then
    for r in $RULES; do
        c=${r%%:*}; p=${r#*:}
        case "$c" in
            POSTROUTING) echo "-A POSTROUTING -o eth3 -p $p -m set --match-set zport_$p dst -j NFQUEUE --queue-num 200 --queue-bypass" ;;
            *) echo "-A $c -i eth3 -p $p -m set --match-set zport_$p src -j NFQUEUE --queue-num 200 --queue-bypass" ;;
        esac
    done
    exit 0
fi
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
# Main-table reads can be supplied independently from the old default-selector
# fallback. This catches accidental policy-table discovery and failed-read storms.
case "$1" in -6) fam=6 ;; *) fam=4 ;; esac
eval fail=\${ROUTE${fam}_FAIL:-0}
[ "$fail" = 1 ] && exit 1
case "$*" in
    *'route show table main'*) eval file=\${ROUTE${fam}_MAIN_FILE:-} ;;
    *) eval file=\${ROUTE${fam}_DEFAULT_FILE:-} ;;
esac
if [ -n "$file" ]; then cat "$file"; exit 0; fi
case "$fam" in
  6) [ "${ROUTE6_OK:-0}" = 1 ] && echo "default via fe80::1 dev eth3" ;;
  *) [ "${ROUTE_OK:-1}" = 1 ] && echo "default via 10.0.0.1 dev eth3" ;;
esac
exit 0
EOF
# pgrep — ВТОРАЯ ветка nfqws2_alive(), и без стаба она уходит в НАСТОЯЩУЮ
# таблицу процессов. На маке и в CI там nfqws2 нет, и дыры не видно; на роутере
# он живой, поэтому «nfqws2 down» превращалось в «жив», самолечение срабатывало
# и проверка краснела. Тест обязан быть герметичным ОТ окружения, а не «обычно
# совпадать» с ним.
cat > "$BIN/pgrep" <<'EOF'
#!/bin/sh
[ "${PIDOF_OK:-1}" = 1 ] || exit 1
echo 12345
exit 0
EOF
chmod +x "$BIN/iptables" "$BIN/ip6tables" "$BIN/pidof" "$BIN/ip" "$BIN/pgrep"

CFG="$TMP/config"; printf 'ENABLED=1\n' > "$CFG"
LOCK="$TMP/lock"; LAST="$TMP/last"; LOG="$TMP/log"

# PATH includes /opt/sbin so the script skips its own PATH-prepend and our $BIN
# mocks win over any real iptables/ip on the CI host.
run() {  # env: NFQ, NFQ6 (def NFQ), PIDOF_OK, ROUTE_OK (v4 def 1), ROUTE6_OK (v6 def 0)
    env NFQ="${NFQ:-0}" NFQ6="${NFQ6:-${NFQ:-0}}" RULES="${RULES:-}" PIDOF_OK="${PIDOF_OK:-1}" \
        ROUTE_OK="${ROUTE_OK:-1}" ROUTE6_OK="${ROUTE6_OK:-0}" IPT_FAIL="${IPT_FAIL:-0}" RULES6="${RULES6:-}" \
        ROUTE4_FAIL="${ROUTE4_FAIL:-0}" ROUTE6_FAIL="${ROUTE6_FAIL:-0}" \
        ROUTE4_MAIN_FILE="${ROUTE4_MAIN_FILE:-}" ROUTE4_DEFAULT_FILE="${ROUTE4_DEFAULT_FILE:-}" \
        ROUTE6_MAIN_FILE="${ROUTE6_MAIN_FILE:-}" ROUTE6_DEFAULT_FILE="${ROUTE6_DEFAULT_FILE:-}" \
        REPAIR_MARKER="${REPAIR_MARKER:-}" \
        PATH="$BIN:/opt/sbin:/opt/bin:$PATH" \
        INIT_SCRIPT="$INIT" ZAPRET_CONFIG="$CFG" Z2K_WAN_LIB="$HERE/lib/wan.sh" \
        RESTART_FW_LOCK="$LOCK" RESTART_FW_LAST="$LAST" \
        MIN_INTERVAL="${MI:-15}" LOCK_STALE="${LS:-60}" SELFHEAL_LOG="$LOG" \
        Z2K_TEST_NOW_SHIFT="${Z2K_TEST_NOW_SHIFT:-}" \
        NFQWS2_PIDFILES="$TMP/run/nfqws2_*.pid $TMP/run/nfqws2.pid" \
        CONFIRM_SETTLE="${CS:-0}" \
        NF_SYSCTL_DIR="${NF_SYSCTL_DIR:-$TMP/no-such-sysctl}" \
        sh "$SH"
}
count() { wc -l < "$CNT" | tr -d ' '; }
# Hermetic: a var-assignment PREFIX on a function call persists in the shell
# (POSIX behaviour) — e.g. `IPT_FAIL=1 run` would leak into the next test. Clear
# every toggle so each case starts from run()'s documented defaults.
reset() { : > "$CNT"; rm -rf "$LOCK"; rm -f "$LAST"; rm -f "$LOG" "$TMP/repaired"; unset NFQ NFQ6 RULES PIDOF_OK ROUTE_OK ROUTE6_OK ROUTE4_FAIL ROUTE6_FAIL ROUTE4_MAIN_FILE ROUTE4_DEFAULT_FILE ROUTE6_MAIN_FILE ROUTE6_DEFAULT_FILE REPAIR_MARKER IPT_FAIL MI LS CS NF_SYSCTL_DIR; }

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
# Замок старим СДВИГОМ «СЕЙЧАС»: busybox touch не знает ни -d, ни -t, и на
# роутере обе половины прежней строки молча не срабатывали. Самолечение считает
# возраст как now - `date -r ЗАМОК`, поэтому сдвиг эквивалентен.
reset; mkdir -p "$LOCK"; z2k_write_date_stub "$BIN/date"
# Сдвиг ставим и снимаем явно: присваивание перед вызовом функции в POSIX sh
# остаётся в окружении до конца скрипта и утекло бы в следующие секции.
Z2K_TEST_NOW_SHIFT=86400; NFQ=0 PIDOF_OK=1 ROUTE_OK=1 LS=60 run; unset Z2K_TEST_NOW_SHIFT
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

# --- 19) ПРОПАЛО ОДНО ПРАВИЛО ИЗ ШЕСТИ (поле 15.09.2026). Исходящее TCP ушло,
#   осталось пять: не ниже порога, прежний код молчал, а весь исходящий HTTPS
#   шёл мимо обхода. Сверка по конфигу обязана это увидеть.
FULL="POSTROUTING:tcp POSTROUTING:udp INPUT:tcp INPUT:udp FORWARD:tcp FORWARD:udp"
cat > "$CFG" <<'CFGEOF'
ENABLED=1
NFQWS2_ENABLE=1
NFQWS2_PORTS_TCP="80,443,2053,2083,2087,2096,5222,8443"
NFQWS2_PORTS_UDP="443,50000-50099,1400,3478-3481,5349,19294-19344"
NFQWS2_TCP_PKT_OUT="20"
NFQWS2_TCP_PKT_IN="10"
NFQWS2_UDP_PKT_OUT="8"
NFQWS2_UDP_PKT_IN="8"
CFGEOF
reset; RULES="$FULL" run
n=$(count); [ "$n" = "0" ] && ok "полный набор по конфигу -> no-op" || no "полный набор" "0" "$n"
reset; RULES="POSTROUTING:udp INPUT:tcp INPUT:udp FORWARD:tcp FORWARD:udp" run
n=$(count); [ "$n" = "1" ] && ok "пропало исходящее TCP (5 из 6) -> heal fires" || no "исходящее TCP" "1" "$n"
grep -q "нет правила POSTROUTING tcp" "$LOG" 2>/dev/null \
    && ok "в журнале названо, какого правила нет" || no "причина в журнале" "POSTROUTING tcp" "$(cat "$LOG" 2>/dev/null)"
reset; RULES="POSTROUTING:tcp POSTROUTING:udp INPUT:tcp INPUT:udp FORWARD:tcp" run
n=$(count); [ "$n" = "1" ] && ok "пропало входящее UDP в FORWARD -> heal fires" || no "входящее UDP FORWARD" "1" "$n"

# --- 20) Чего конфиг не требует, того не ждём: иначе вечный re-apply.
reset; sed -i.bak 's/^NFQWS2_PORTS_UDP=.*/NFQWS2_PORTS_UDP=""/' "$CFG"
RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" run
n=$(count); [ "$n" = "0" ] && ok "UDP-портов нет -> UDP-правил не ждём" || no "пустые UDP-порты" "0" "$n"
reset; sed -i.bak 's/^NFQWS2_PORTS_UDP=.*/NFQWS2_PORTS_UDP="443"/; s/^NFQWS2_UDP_PKT_OUT=.*/NFQWS2_UDP_PKT_OUT="0"/; s/^NFQWS2_UDP_PKT_IN=.*/NFQWS2_UDP_PKT_IN="0"/' "$CFG"
RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" run
n=$(count); [ "$n" = "0" ] && ok "UDP_PKT_OUT/IN=0 -> UDP-правил не ждём" || no "нулевые окна UDP" "0" "$n"
# Пустой PKT_IN берёт значение PKT_OUT — входящие ОБЯЗАНЫ быть.
reset; sed -i.bak 's/^NFQWS2_TCP_PKT_IN=.*/NFQWS2_TCP_PKT_IN=""/' "$CFG"
RULES="POSTROUTING:tcp" run
n=$(count); [ "$n" = "1" ] && ok "пустой TCP_PKT_IN = PKT_OUT -> входящие TCP ждём" || no "PKT_IN по OUT" "1" "$n"
reset; sed -i.bak 's/^NFQWS2_ENABLE=.*/NFQWS2_ENABLE=0/' "$CFG"
RULES="POSTROUTING:tcp INPUT:tcp" run
n=$(count); [ "$n" = "0" ] && ok "NFQWS2_ENABLE=0 -> по конфигу ничего не ждём" || no "NFQWS2_ENABLE=0" "0" "$n"
rm -f "$CFG.bak"

# --- 21) v6 активен: пропало исходящее TCP только в v6 -> heal.
cat > "$CFG" <<'CFGEOF'
ENABLED=1
NFQWS2_PORTS_TCP="443"
NFQWS2_TCP_PKT_OUT="20"
CFGEOF
cat > "$BIN/ip6tables" <<'EOF6'
#!/bin/sh
for r in ${RULES6:-}; do
    c=${r%%:*}; p=${r#*:}
    case "$c" in POSTROUTING) d=-o ;; *) d=-i ;; esac
    echo "-A $c $d eth3 -p $p -m set --match-set zport6_$p dst -j NFQUEUE --queue-num 200 --queue-bypass"
done
exit 0
EOF6
chmod +x "$BIN/ip6tables"
reset; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" RULES6="INPUT:tcp FORWARD:tcp" ROUTE6_OK=1 run
n=$(count); [ "$n" = "1" ] && ok "v6: пропало исходящее TCP -> heal fires" || no "v6 исходящее TCP" "1" "$n"
reset; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" RULES6="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" ROUTE6_OK=1 run
n=$(count); [ "$n" = "0" ] && ok "v6: полный набор -> no-op" || no "v6 полный набор" "0" "$n"
unset RULES6
printf 'ENABLED=1\n' > "$CFG"

# Main-table topology is the source of truth for repair. Two main defaults must
# both be covered, while policy-only modem/VPN routes must not trigger repair.
cat > "$TMP/main-two" <<'EOF'
default dev eth3
default dev usb0
EOF
cp "$TMP/main-two" "$TMP/default-two"
printf 'ENABLED=1\nNFQWS2_PORTS_TCP=443\nNFQWS2_TCP_PKT_OUT=9\nNFQWS2_TCP_PKT_IN=10\n' > "$CFG"
reset; ROUTE4_MAIN_FILE="$TMP/main-two"; ROUTE4_DEFAULT_FILE="$TMP/default-two"; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" run
n=$(count); [ "$n" = 1 ] && ok 'second main-table WAN without rules triggers repair' || no 'missing second main WAN' 1 "$n"
grep -q 'на usb0' "$LOG" && ok 'repair identifies missing WAN' || no 'WAN diagnosis' usb0 missing

cat > "$TMP/main-primary" <<'EOF'
default dev eth3
EOF
cat > "$TMP/default-policy" <<'EOF'
default dev eth3
default dev usb0 table 16400
default dev arbitrary-vpn table 16401
EOF
reset; ROUTE4_MAIN_FILE="$TMP/main-primary"; ROUTE4_DEFAULT_FILE="$TMP/default-policy"; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" run
n=$(count); [ "$n" = 0 ] && ok 'policy-only modem and arbitrary VPN do not trigger repair' || no 'policy-only WAN ignored' 0 "$n"

# The first tick repairs the missing main-table leg. The init stub marks that
# side effect; with debounce disabled, the next tick independently sees full coverage.
cat > "$BIN/iptables" <<EOF
#!/bin/sh
for r in \${RULES:-}; do
    c=\${r%%:*}; p=\${r#*:}
    case "\$c" in POSTROUTING) d=-o ;; *) d=-i ;; esac
    echo "-A \$c \$d eth3 -p \$p -j NFQUEUE --queue-num 200 --queue-bypass"
    [ -f "$TMP/repaired" ] && echo "-A \$c \$d usb0 -p \$p -j NFQUEUE --queue-num 200 --queue-bypass"
done
exit 0
EOF
chmod +x "$BIN/iptables"
reset; MI=0; REPAIR_MARKER="$TMP/repaired"; ROUTE4_MAIN_FILE="$TMP/main-two"; ROUTE4_DEFAULT_FILE="$TMP/default-two"; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" run
RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" run
n=$(count); [ "$n" = 1 ] && ok 'repaired second main WAN is idle on the next tick' || no 'post-repair idle' 1 "$n"

# Empty and failed IPv6 route reads are both non-actionable and cannot storm.
reset; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" ROUTE_OK=1 ROUTE6_OK=0 run
n=$(count); [ "$n" = 0 ] && ok 'empty IPv6 main table does not storm' || no 'empty IPv6 no storm' 0 "$n"
reset; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" ROUTE_OK=1 ROUTE6_FAIL=1 run
n=$(count); [ "$n" = 0 ] && ok 'failed IPv6 route read does not storm' || no 'failed IPv6 no storm' 0 "$n"

printf 'ENABLED=1\nDISABLE_IPV6=1\nWAN_IFACE=eth3\nNFQWS2_PORTS_TCP=443\nNFQWS2_TCP_PKT_OUT=9\nNFQWS2_TCP_PKT_IN=10\n' > "$CFG"
reset; RULES="POSTROUTING:tcp INPUT:tcp FORWARD:tcp" run
n=$(count); [ "$n" = 0 ] && ok 'manual override does not demand other policy WANs' || no 'override' 0 "$n"

# --- 22) fastnat: тик возвращает nf_conntrack_fastnat=0 без регена и без start_fw.
# По исходникам ядра Keenetic при fastnat=1 поток после 6 пакетов в обе стороны
# уходит мимо NFQUEUE; start_fw ставит 0, но только по регену. Селфхил — страховка.
printf 'ENABLED=1\n' > "$CFG"
SYS="$TMP/sysctl"; mkdir -p "$SYS"
# мок iptables с раздела 19 печатает только правила из RULES — даём полный набор,
# чтобы единственным действием тика был возврат sysctl.
OK6="POSTROUTING:tcp POSTROUTING:udp INPUT:tcp INPUT:udp FORWARD:tcp FORWARD:udp"
reset; printf '1\n' > "$SYS/nf_conntrack_fastnat"; printf '1\n' > "$SYS/nf_conntrack_fastnat_xfrm"
RULES="$OK6" NF_SYSCTL_DIR="$SYS" run
v=$(cat "$SYS/nf_conntrack_fastnat"); [ "$v" = 0 ] && ok "fastnat 1 -> 0 возвращён тиком" || no "fastnat reassert" 0 "$v"
v=$(cat "$SYS/nf_conntrack_fastnat_xfrm"); [ "$v" = 0 ] && ok "fastnat_xfrm 1 -> 0 возвращён тиком" || no "fastnat_xfrm reassert" 0 "$v"
grep -q 'nf_conntrack_fastnat был' "$LOG" 2>/dev/null && ok "возврат fastnat записан в журнал" || no "fastnat log" "строка" "нет"
n=$(count); [ "$n" = 0 ] && ok "возврат fastnat не зовёт start_fw" || no "fastnat no start_fw" 0 "$n"
# уже 0 — ни записи, ни строки в журнале
reset; printf '0\n' > "$SYS/nf_conntrack_fastnat"; printf '0\n' > "$SYS/nf_conntrack_fastnat_xfrm"
RULES="$OK6" NF_SYSCTL_DIR="$SYS" run
if [ -f "$LOG" ] && grep -q fastnat "$LOG"; then no "fastnat quiet" "нет строки" "есть"; else ok "fastnat уже 0 -> тишина"; fi
# движок выключен — ускорение пользователю нужно, sysctl не трогаем
reset; printf '1\n' > "$SYS/nf_conntrack_fastnat"
RULES="$OK6" PIDOF_OK=0 NF_SYSCTL_DIR="$SYS" run
v=$(cat "$SYS/nf_conntrack_fastnat"); [ "$v" = 1 ] && ok "nfqws2 down -> fastnat не трогаем" || no "fastnat untouched when down" 1 "$v"
reset

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
