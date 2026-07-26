#!/bin/sh
# tests/router_adverse_restart.sh
#
# ROUTER-ONLY. Deliberately NOT named test_*.sh: tests/run_all.sh globs test_*.sh
# and this needs a live Keenetic (BusyBox ash, real /proc/net/netfilter/
# nfnetlink_queue, real usleep, a real nfqws2). Run it on the box:
#     sh /tmp/router_adverse_restart.sh
#
# Covers the adverse paths the CI batteries cannot reach: a wedged daemon that
# ignores SIGTERM, a box without fractional sleep, a queue that never binds, and
# restart churn. Restores everything it touches; leaves the service healthy.
#
# COUNTING NOTE (learned the hard way, 2026-07-25): BusyBox pgrep here has no
# -c at all (usage is [-flanovx], it exits 1), and -x did not match nfqws2
# either; `pgrep -f nfq2/nfqws2` additionally matches the ssh shell running this
# script and reports phantom extras. /proc/*/comm is the only trustworthy count.

INIT=${INIT:-/opt/etc/init.d/S99zapret2}
UPT() { read u _ < /proc/uptime; echo "$u"; }
el() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
between() { awk -v e="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(e>=lo && e<=hi)}'; }

P=0; F=0
ok() { P=$((P+1)); printf '[PASS] %s\n' "$1"; }
no() { F=$((F+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

count_nfqws() {
    n=0
    for d in /proc/[0-9]*; do
        [ -r "$d/comm" ] || continue
        read c < "$d/comm" 2>/dev/null
        [ "$c" = nfqws2 ] && n=$((n+1))
    done
    echo "$n"
}

[ -x "$INIT" ] || { echo "SKIP: $INIT not present — not a router?"; exit 0; }

HLP=/tmp/.z2k_helpers.$$
extract() {
    awk -v fn="$1" '$0 ~ "^"fn"\\(\\)[ \t]*$"{i=1;print;next} i&&/^}/{print;exit} i{print}' "$INIT"
}
{ extract z2k_fracsleep_avail; echo; extract z2k_wait_gone; echo; extract z2k_wait_queue_bound; } > "$HLP"
# shellcheck disable=SC1090
. "$HLP"
trap 'rm -f "$HLP" /tmp/.z2k_nb.$$' EXIT

echo "=== 1. wedged daemon: SIGSTOP so SIGTERM cannot land -> must hit the 3 s ceiling ==="
VP=$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')
kill -STOP "$VP" 2>/dev/null
t0=$(UPT); kill -TERM "$VP" 2>/dev/null; z2k_wait_gone "$VP" 3; rc=$?; t1=$(UPT); E=$(el "$t0" "$t1")
between "$E" 2.8 3.6 && ok "deadline held at ~3 s (not 60 s)" || no "deadline ~3 s" "2.8-3.6" "$E"
[ "$rc" = 1 ] && ok "rc=1 for a process that never died" || no "rc=1" 1 "$rc"
kill -CONT "$VP" 2>/dev/null; kill -9 "$VP" 2>/dev/null

echo "=== 2. fast death: must return at once, not wait out the ceiling ==="
VP=$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')
t0=$(UPT); kill -TERM "$VP" 2>/dev/null; z2k_wait_gone "$VP" 3; rc=$?; t1=$(UPT); E=$(el "$t0" "$t1")
between "$E" 0 0.5 && ok "returned fast ($E s)" || no "fast return" "<=0.5" "$E"
[ "$rc" = 0 ] && ok "rc=0 once the process is gone" || no "rc=0" 0 "$rc"

echo "=== 3. no fractional sleep: the 3 s deadline must NOT stretch ==="
cat > /tmp/.z2k_nb.$$ <<NB
Z2K_FRACSLEEP=0
. "$HLP"
VP=\$(sh -c 'sleep 300 >/dev/null 2>&1 & echo \$!')
kill -STOP "\$VP" 2>/dev/null
read a _ < /proc/uptime
kill -TERM "\$VP" 2>/dev/null
z2k_wait_gone "\$VP" 3
read b _ < /proc/uptime
kill -CONT "\$VP" 2>/dev/null; kill -9 "\$VP" 2>/dev/null
awk -v x=\$a -v y=\$b 'BEGIN{printf "%.2f\n", y-x}'
NB
E=$(sh /tmp/.z2k_nb.$$ 2>/dev/null | tail -1)
between "$E" 2.5 4.5 && ok "deadline holds without usleep ($E s, not 60 s)" || no "deadline w/o usleep" "2.5-4.5" "$E"

NFPID=$(cat /var/run/nfqws2_1.pid 2>/dev/null)
if [ -n "$NFPID" ] && kill -0 "$NFPID" 2>/dev/null; then
    echo "=== 4. queue wait: real qnum matches at once; wrong qnums time out (no substring match) ==="
    QN=$(awk 'NR==1{print $1}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null)
    t0=$(UPT); z2k_wait_queue_bound "$NFPID" "$QN" 3; rc=$?; t1=$(UPT); E=$(el "$t0" "$t1")
    between "$E" 0 0.3 && [ "$rc" = 0 ] && ok "bound queue $QN found immediately ($E s)" \
                                       || no "bound queue found immediately" "<=0.3s rc=0" "$E rc=$rc"
    # A naive substring/grep match would make these hit instantly. They must time out.
    for bad in "${QN}0" "${QN%?}" 0; do
        [ -n "$bad" ] || continue
        t0=$(UPT); z2k_wait_queue_bound "$NFPID" "$bad" 1; rc=$?; t1=$(UPT); E=$(el "$t0" "$t1")
        between "$E" 0.8 2.0 && ok "qnum=$bad did NOT falsely match (timed out $E s)" \
                             || no "qnum=$bad must not match" "0.8-2.0s" "$E"
        [ "$rc" = 0 ] && ok "qnum=$bad timeout is not an error (rc=0)" || no "timeout rc=0" 0 "$rc"
    done

    echo "=== 5. dead pid while waiting for the queue -> rc=1 ==="
    VP=$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!'); kill -9 "$VP" 2>/dev/null; sleep 1
    z2k_wait_queue_bound "$VP" 65534 2; rc=$?
    [ "$rc" = 1 ] && ok "dead daemon -> rc=1" || no "dead daemon rc=1" 1 "$rc"
else
    echo "SKIP 4-5: nfqws2 not running"
fi

echo "=== 6. restart churn: 5 in a row, no leaked daemons/pidfiles/zombies ==="
i=1
while [ "$i" -le 5 ]; do
    t0=$(UPT); "$INIT" restart >/dev/null 2>&1; t1=$(UPT)
    printf '  #%d %s s  daemons=%s pidfiles=%s\n' "$i" "$(el "$t0" "$t1")" \
        "$(count_nfqws)" "$(ls /var/run/nfqws2_*.pid 2>/dev/null | wc -l)"
    i=$((i+1))
done
N=$(count_nfqws)
[ "$N" = 1 ] && ok "exactly one nfqws2 after churn" || no "one nfqws2" 1 "$N"
PF=$(ls /var/run/nfqws2_*.pid 2>/dev/null | wc -l)
[ "$PF" = 1 ] && ok "exactly one pidfile" || no "one pidfile" 1 "$PF"
Z=0
for d in /proc/[0-9]*; do
    [ -r "$d/stat" ] || continue
    s=$(awk '{print $3}' "$d/stat" 2>/dev/null)
    [ "$s" = Z ] && Z=$((Z+1))
done
[ "$Z" = 0 ] && ok "no zombies" || no "no zombies" 0 "$Z"

echo "=== 7. health ==="
"$INIT" status 2>&1 | head -3
echo "  queue: $(cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null)"
echo "  NFQUEUE rules: $(iptables-save 2>/dev/null | grep -c NFQUEUE)"

printf '\nPASSED: %d\nFAILED: %d\n' "$P" "$F"
[ "$F" = 0 ]
