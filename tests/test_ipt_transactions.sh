#!/bin/sh
# Stateful, isolated checks for common/ipt.sh. No real firewall command is run:
# iptables/ip6tables are a file-backed mock on PATH. The transaction lock is a
# kernel flock; util-linux flock is used when present, otherwise a python3
# double with the same -n/-w/--help surface. FLOCK_IMPL=python|busybox forces a
# double ("busybox" has no -w, like the BusyBox applet); FLOCK_IMPL=real uses
# whatever flock is installed (e.g. the BusyBox applet itself).

HERE=$(cd "$(dirname "$0")/.." && pwd)
IPT_SH=${IPT_SH:-$HERE/common/ipt.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ipt-transactions.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

BIN="$TMP/bin"
NOFL="$TMP/nofl"
STATE="$TMP/state"
export STATE
mkdir -p "$BIN" "$NOFL"
cat > "$BIN/iptables-mock" <<'MOCK'
#!/bin/sh
family=${0##*/}
case "$family" in ip6tables) rules="$STATE/rules6" ;; *) rules="$STATE/rules4" ;; esac
[ -f "$rules" ] || : > "$rules"
{
    printf 'call'
    for arg do printf ' <%s>' "$arg"; done
    printf '\n'
} >> "$STATE/calls"
waited=0
op=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -w) waited=1; shift ;;
        -C|-I|-A|-D) op=$1; shift; break ;;
        *) shift ;;
    esac
done
key=$*
# OVERLAP_CHECK: a transaction is "in flight" from its -C until the -C that
# ends it (present/error) or its mutation. A second -C meanwhile = overlap.
inflight_end() { [ "${OVERLAP_CHECK:-0}" = 1 ] && rmdir "$STATE/inflight" 2>/dev/null; :; }
if [ "$op" = -C ] && [ "${OVERLAP_CHECK:-0}" = 1 ]; then
    mkdir "$STATE/inflight" 2>/dev/null || echo OVERLAP >> "$STATE/overlap"
fi
# Sleeps close inherited descriptors: like a real single-process iptables,
# killing the mock must release whatever it inherited.
hold() { echo $$ > "$STATE/$1"; sleep "$2" 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; }
[ "$op" = -C ] && [ -n "${HOLD_C:-}" ] && hold cpid "$HOLD_C"
[ "$op" = -C ] && [ "${CHECK_ERROR:-0}" != 0 ] && { inflight_end; exit "$CHECK_ERROR"; }
if [ "$op" = -C ] && [ "${CONTENTION:-0}" = 1 ] && [ "$waited" = 0 ] && grep -F -x -q -- "$key" "$rules"; then
    inflight_end
    exit 4
fi
if [ "$op" = -C ] && [ "${BARRIER:-0}" = 1 ]; then
    : > "$STATE/check.$$"
    count=$(find "$STATE" -name 'check.*' -type f | wc -l | tr -d ' ')
    [ "$count" -ge 2 ] || sleep 1
fi
case "$op" in
    -C)
        if grep -F -x -q -- "$key" "$rules"; then inflight_end; exit 0; fi
        exit 1
        ;;
    -I|-A|-D)
        [ -n "${HOLD_MUT:-}" ] && hold mutpid "$HOLD_MUT"
        [ "${MUTATE_ERROR:-0}" = 0 ] || { inflight_end; exit "$MUTATE_ERROR"; }
        while ! mkdir "$STATE/mutation.lock" 2>/dev/null; do :; done
        if [ "$op" = -I ]; then
            { printf '%s\n' "$key"; cat "$rules"; } > "$rules.$$"
            mv "$rules.$$" "$rules"
        elif [ "$op" = -A ]; then
            printf '%s\n' "$key" >> "$rules"
        else
            awk -v key="$key" '$0 == key && !done { done=1; next } { print }' "$rules" > "$rules.$$"
            mv "$rules.$$" "$rules"
        fi
        rmdir "$STATE/mutation.lock"
        inflight_end
        exit 0
        ;;
    *) exit 2 ;;
esac
MOCK
cp "$BIN/iptables-mock" "$BIN/iptables"
cp "$BIN/iptables-mock" "$BIN/ip6tables"
cat > "$BIN/opkg" <<'MOCK'
#!/bin/sh
echo "opkg $*" >> "$STATE/opkg"
exit 1
MOCK

PY=$(command -v python3)
# Sub-second steps only where the host sleep takes them (router BusyBox does
# not); otherwise every step becomes whole seconds and the suite just runs
# slower (Z2K_TEST_FRAC_SLEEP=0 forces that). Durations: POLL wait loops, SETTLE let a background holder start,
# STAGGER delay the second contender, HOLD/LONG keep a transaction in flight.
_probe=0.01
if [ "${Z2K_TEST_FRAC_SLEEP:-}" != 0 ] && sleep "$_probe" 2>/dev/null; then
    T_POLL=0.05 T_SETTLE=0.3 T_STAGGER=0.2 T_HOLD=0.3 T_LONG=0.6
else
    T_POLL=1 T_SETTLE=1 T_STAGGER=1 T_HOLD=1 T_LONG=2
fi
write_flock_double() {   # $1 = target, $2 = 1 if -w is supported
    [ -n "$PY" ] || { printf 'python3 is required for the flock test double\n' >&2; exit 1; }
    cat > "$1" <<EOF
#!$PY
import fcntl, sys, time
HAS_W = $2
args = sys.argv[1:]
if args and args[0] == '--help':
    print('Usage: flock [options] <fd>\n -n, --nonblock\n' + (' -w, --timeout <secs>\n' if HAS_W else ''))
    sys.exit(0)
limit = None
if args and args[0] == '-n':
    limit = 0
    args = args[1:]
elif args and args[0] == '-w':
    if not HAS_W:
        sys.stderr.write('flock: invalid option -- w\n')
        sys.exit(1)
    limit = float(args[1])
    args = args[2:]
fd = int(args[0])
deadline = None if limit is None else time.monotonic() + limit
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        if deadline is not None and time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.01)
EOF
    chmod +x "$1"
}
REAL_FLOCK=$(command -v flock 2>/dev/null)
case "${FLOCK_IMPL:-auto}" in
    auto)
        if [ -n "$REAL_FLOCK" ] && "$REAL_FLOCK" --help 2>&1 | grep -q -- '--timeout'; then
            ln -s "$REAL_FLOCK" "$BIN/flock"; FLOCK_KIND=util-linux
        else
            write_flock_double "$BIN/flock" 1; FLOCK_KIND=python-double
        fi ;;
    real) [ -n "$REAL_FLOCK" ] || exit 1; ln -s "$REAL_FLOCK" "$BIN/flock"; FLOCK_KIND="real:$REAL_FLOCK" ;;
    python) write_flock_double "$BIN/flock" 1; FLOCK_KIND=python-double ;;
    busybox) write_flock_double "$BIN/flock" 0; FLOCK_KIND=busybox-double ;;
    *) printf 'unknown FLOCK_IMPL\n' >&2; exit 1 ;;
esac
printf 'flock under test: %s\n' "$FLOCK_KIND"
chmod +x "$BIN/iptables" "$BIN/ip6tables" "$BIN/opkg"
# A PATH with every tool the mock and helpers need, except flock.
for tool in sh grep find wc tr cat mv mkdir rmdir awk sleep rm; do
    p=$(command -v "$tool") && ln -s "$p" "$NOFL/$tool"
done
for tool in iptables ip6tables opkg; do ln -s "$BIN/$tool" "$NOFL/$tool"; done
PATH="$BIN:$PATH"
export PATH
Z2K_IPT_LOCK="$TMP/transaction.flock"
Z2K_IPT_LOCK_TIMEOUT=2
export Z2K_IPT_LOCK Z2K_IPT_LOCK_TIMEOUT
# shellcheck source=common/ipt.sh
. "$IPT_SH"

reset() {
    rm -rf "$STATE" "$Z2K_IPT_LOCK"
    mkdir -p "$STATE"
    : > "$STATE/rules4"
    : > "$STATE/rules6"
    : > "$STATE/calls"
    FW_EXTRA_PRE=
    FW_EXTRA_POST=
    unset CONTENTION CHECK_ERROR BARRIER MUTATE_ERROR OVERLAP_CHECK HOLD_C HOLD_MUT RECLAIM_BARRIER
    Z2K_IPT_LOCK_TIMEOUT=2
    export Z2K_IPT_LOCK_TIMEOUT
}
count4() { grep -F -x -c -- "$1" "$STATE/rules4" 2>/dev/null; }
count6() { grep -F -x -c -- "$1" "$STATE/rules6" 2>/dev/null; }
wait_flag_count() { grep -c '<-w>' "$STATE/calls" 2>/dev/null; }
wait_file() { n=0; while [ ! -s "$1" ] && [ "$n" -lt 200 ]; do sleep "$T_POLL"; n=$((n + 1)); done; }
lock_free() { ( flock -n 7 ) 7>>"$Z2K_IPT_LOCK" && echo free || echo held; }
overlaps() { if [ -f "$STATE/overlap" ]; then wc -l < "$STATE/overlap" | tr -d ' '; else echo 0; fi; }
# A test-only kill wrapper: if an implementation decides ownership from
# "kill -0 <pid>", both contenders are released together and the second one
# acts T_STAGGER later. It never fires for an implementation that does not ask.
kill() {
    if [ "$1" = -0 ] && [ "${RECLAIM_BARRIER:-0}" = 1 ]; then
        : > "$STATE/killchk.$(mktemp -u XXXXXX)"
        n=0
        while [ "$(find "$STATE" -name 'killchk.*' | wc -l | tr -d ' ')" -lt 2 ] && [ "$n" -lt 100 ]; do
            sleep "$T_POLL"; n=$((n + 1))
        done
        mkdir "$STATE/killfirst" 2>/dev/null || sleep "$T_STAGGER"
    fi
    command kill "$@"
}

RULE4='INPUT -p tcp --dport 443 -j NFQUEUE'
RULE4A='POSTROUTING -p udp --dport 443 -j NFQUEUE'
RULE6='INPUT -p tcp --dport 443 -j NFQUEUE'
RULE6A='POSTROUTING -p udp --dport 443 -j NFQUEUE'

# --- -w and status handling --------------------------------------------------
# Removing -w from any check or mutation must fail these counters.
reset
ipt INPUT -p tcp --dport 443 -j NFQUEUE
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE
ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'IPv4/IPv6 insert and append transactions always wait' 8 "$(wait_flag_count)"
reset
printf '%s\n' "$RULE4" > "$STATE/rules4"
printf '%s\n' "$RULE6" > "$STATE/rules6"
ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
ipt6_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'IPv4/IPv6 deletion checks, mutations, and final absence checks always wait' 6 "$(wait_flag_count)"

# Original bug: lock error 4 on -C is treated as absence and duplicates a rule.
reset
printf '%s\n' "$RULE4" "$RULE4A" > "$STATE/rules4"
CONTENTION=1 ipt INPUT -p tcp --dport 443 -j NFQUEUE
CONTENTION=1 ipta POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'contended ipt check cannot duplicate an existing rule' 1 "$(count4 "$RULE4")"
eq 'contended ipta check cannot duplicate an existing rule' 1 "$(count4 "$RULE4A")"
reset
printf '%s\n' "$RULE6" "$RULE6A" > "$STATE/rules6"
CONTENTION=1 ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
CONTENTION=1 ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'contended IPv6 insert cannot duplicate an existing rule' 1 "$(count6 "$RULE6")"
eq 'contended IPv6 append cannot duplicate an existing rule' 1 "$(count6 "$RULE6A")"

reset
ipt INPUT -p tcp --dport 443 -j NFQUEUE
ipt INPUT -p tcp --dport 443 -j NFQUEUE
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE
ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'ordinary missing then existing IPv4 insert is idempotent' 1 "$(count4 "$RULE4")"
eq 'ordinary missing IPv4 append adds one' 1 "$(count4 "$RULE4A")"
eq 'ordinary missing IPv6 insert adds one' 1 "$(count6 "$RULE6")"
eq 'ordinary missing IPv6 append adds one' 1 "$(count6 "$RULE6A")"

reset
ipt INPUT -j A
ipt INPUT -j B
ipta INPUT -j C
ipt6a INPUT -j X
ipt6 INPUT -j Y
eq 'insert goes to the top and append to the end (IPv4)' 'INPUT -j B|INPUT -j A|INPUT -j C|' "$(tr '\n' '|' < "$STATE/rules4")"
eq 'insert goes to the top and append to the end (IPv6)' 'INPUT -j Y|INPUT -j X|' "$(tr '\n' '|' < "$STATE/rules6")"

for err in 2 4; do
    reset
    CHECK_ERROR=$err ipt INPUT -p tcp --dport 443 -j NFQUEUE
    rc=$?
    eq "IPv4 check error $err is returned" "$err" "$rc"
    eq "IPv4 check error $err cannot insert" 0 "$(count4 "$RULE4")"
    CHECK_ERROR=$err ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
    rc=$?
    eq "IPv6 check error $err is returned" "$err" "$rc"
    eq "IPv6 check error $err cannot insert" 0 "$(count6 "$RULE6")"
    printf '%s\n' "$RULE4" > "$STATE/rules4"
    CHECK_ERROR=$err ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
    rc=$?
    eq "IPv4 deletion check error $err is returned" "$err" "$rc"
    eq "IPv4 deletion check error $err deletes nothing" 1 "$(count4 "$RULE4")"
done

reset
MUTATE_ERROR=2 ipt INPUT -p tcp --dport 443 -j NFQUEUE
eq 'mutation error is returned' 2 "$?"
eq 'mutation error releases the transaction lock' free "$(lock_free)"
printf '%s\n' "$RULE4" > "$STATE/rules4"
MUTATE_ERROR=3 ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'deletion mutation error is returned' 3 "$?"

# --- concurrency -------------------------------------------------------------
# The barrier makes both original checks observe absence before either insert.
# The transaction lock makes the second check run after the first insert.
# Waits here span several held transactions; BusyBox flock polls once a second.
reset
BARRIER=1 Z2K_IPT_LOCK_TIMEOUT=10; export BARRIER Z2K_IPT_LOCK_TIMEOUT
ipt INPUT -p tcp --dport 443 -j NFQUEUE & p1=$!
ipt INPUT -p tcp --dport 443 -j NFQUEUE & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
unset BARRIER
eq 'concurrent ipt callers both succeed' '0 0' "$r1 $r2"
eq 'concurrent ipt apply leaves exactly one rule' 1 "$(count4 "$RULE4")"
reset
BARRIER=1 Z2K_IPT_LOCK_TIMEOUT=10; export BARRIER Z2K_IPT_LOCK_TIMEOUT
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE & p1=$!
ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE & p3=$!
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
wait "$p3"
unset BARRIER
eq 'concurrent ipta callers both succeed' '0 0' "$r1 $r2"
eq 'concurrent ipta apply leaves exactly one rule' 1 "$(count4 "$RULE4A")"
reset
OVERLAP_CHECK=1 HOLD_C=$T_HOLD Z2K_IPT_LOCK_TIMEOUT=10; export OVERLAP_CHECK HOLD_C Z2K_IPT_LOCK_TIMEOUT
for i in 1 2 3 4; do ipt6 INPUT -p tcp --dport 443 -j NFQUEUE & done
wait
eq 'four concurrent IPv6 transactions never overlap' 0 "$(overlaps)"
eq 'four concurrent IPv6 transactions leave one rule' 1 "$(count6 "$RULE6")"

# --- lock lifecycle ----------------------------------------------------------
reset
ipt INPUT -p tcp --dport 443 -j NFQUEUE
[ -f "$Z2K_IPT_LOCK" ] && kept=yes || kept=no
eq 'lock file is kept (one inode for every waiter)' yes "$kept"
eq 'lock is released after a transaction' free "$(lock_free)"
case "$(grep -o '/tmp/zapret2-ipt.flock' "$IPT_SH" | head -1)" in
    /tmp/zapret2-ipt.flock) ok 'default lock is a dedicated z2k file' ;;
    *) no 'default lock is a dedicated z2k file' /tmp/zapret2-ipt.flock missing ;;
esac
for other in /run/xtables.lock /var/run/xtables.lock /tmp/zapret2-restart-fw.lock; do
    if grep -q -F "\"\${Z2K_IPT_LOCK:-$other}\"" "$IPT_SH"; then no "transaction lock is not $other" distinct same; else ok "transaction lock is not $other"; fi
done

# A live holder: bounded wait, then fail closed without mutating.
reset
( flock -n 7 && sleep 3 7>&-; : ) 7>>"$Z2K_IPT_LOCK" & holder=$!
sleep "$T_SETTLE"
Z2K_IPT_LOCK_TIMEOUT=1 ipt INPUT -p tcp --dport 443 -j NFQUEUE
rc=$?
eq 'live holder: wait is bounded and returns 4' 4 "$rc"
eq 'live holder: nothing is inserted' 0 "$(count4 "$RULE4")"
eq 'live holder: no iptables call is made' 0 "$(wc -l < "$STATE/calls" | tr -d ' ')"
command kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
ipt INPUT -p tcp --dport 443 -j NFQUEUE
eq 'after the holder ends the next transaction works' '0 1' "$? $(count4 "$RULE4")"

# A holder that releases within the timeout: the waiter proceeds.
reset
( flock -n 7 && sleep 2 7>&-; : ) 7>>"$Z2K_IPT_LOCK" & holder=$!
sleep "$T_SETTLE"
Z2K_IPT_LOCK_TIMEOUT=5 ipt INPUT -p tcp --dport 443 -j NFQUEUE
eq 'waiter proceeds once a short holder releases' '0 1' "$? $(count4 "$RULE4")"
wait "$holder" 2>/dev/null

# Process death mid-transaction releases the lock; no owner bookkeeping.
for sig in TERM KILL; do
    reset
    HOLD_MUT=5; export HOLD_MUT
    ipt INPUT -p tcp --dport 443 -j NFQUEUE & victim=$!
    wait_file "$STATE/mutpid"
    command kill -s "$sig" "$victim" "$(cat "$STATE/mutpid")" 2>/dev/null
    wait "$victim" 2>/dev/null
    unset HOLD_MUT
    Z2K_IPT_LOCK_TIMEOUT=2 ipt INPUT -p tcp --dport 443 -j NFQUEUE
    eq "SIG$sig of a holder releases the lock for the next transaction" '0 1' "$? $(count4 "$RULE4")"
done

# The caller dies but its in-flight iptables child still runs: the child keeps
# the lock until it finishes, so the next transaction sees its rule.
reset
HOLD_MUT=1; export HOLD_MUT
ipt INPUT -p tcp --dport 443 -j NFQUEUE & victim=$!
wait_file "$STATE/mutpid"
command kill -s KILL "$victim" 2>/dev/null
wait "$victim" 2>/dev/null
unset HOLD_MUT
Z2K_IPT_LOCK_TIMEOUT=5 ipt INPUT -p tcp --dport 443 -j NFQUEUE
eq 'orphaned in-flight mutation is waited for, not duplicated' '0 1' "$? $(count4 "$RULE4")"

# Two contenders right after a holder died mid-transaction (the state the
# removed PID lock tried to "reclaim"): exactly one runs at a time.
reset
HOLD_C=5; export HOLD_C
ipt INPUT -p tcp --dport 443 -j NFQUEUE & victim=$!
wait_file "$STATE/cpid"
command kill -s KILL "$victim" "$(cat "$STATE/cpid")" 2>/dev/null
wait "$victim" 2>/dev/null
unset HOLD_C
if [ -d "$Z2K_IPT_LOCK" ]; then
    # a directory lock left by a separate caller process whose PID is now dead
    sh -c 'exit 0' & dead=$!; wait "$dead"
    echo "$dead" > "$Z2K_IPT_LOCK/pid"
fi
: > "$STATE/calls"
rm -rf "$STATE/inflight" "$STATE/overlap"
OVERLAP_CHECK=1 HOLD_C=$T_LONG RECLAIM_BARRIER=1 Z2K_IPT_LOCK_TIMEOUT=10
export OVERLAP_CHECK HOLD_C RECLAIM_BARRIER Z2K_IPT_LOCK_TIMEOUT
ipt INPUT -p tcp --dport 443 -j NFQUEUE & a=$!
ipt INPUT -p tcp --dport 443 -j NFQUEUE & b=$!
wait "$a"; ra=$?
wait "$b"; rb=$?
eq 'two contenders after a dead holder both succeed' '0 0' "$ra $rb"
eq 'two contenders after a dead holder never overlap' 0 "$(overlaps)"
eq 'two contenders after a dead holder insert once' 1 "$(count4 "$RULE4")"

# --- caller environment ------------------------------------------------------
reset
exec 8>"$TMP/caller8"
ipt INPUT -p tcp --dport 443 -j NFQUEUE
echo caller-data >&8
exec 8>&-
eq "caller's descriptor 8 survives a transaction" caller-data "$(cat "$TMP/caller8")"
eq 'nothing is written into the lock file' 0 "$(wc -c < "$Z2K_IPT_LOCK" | tr -d ' ')"

# set -e callers: ordinary absent/existing rules must not abort the caller,
# and an error status must leave the lock usable.
reset
out=$(sh -e -c '. "$1"; ipt INPUT -p tcp --dport 443 -j NFQUEUE; ipt INPUT -p tcp --dport 443 -j NFQUEUE; ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE; echo reached' sh "$IPT_SH" 2>&1)
eq 'set -e caller survives absent-then-existing rules' reached "$out"
eq 'set -e caller inserts once' 1 "$(count4 "$RULE4")"
out=$(sh -e -c '. "$1"; ipt_del INPUT -p tcp --dport 443 -j NFQUEUE; echo reached' sh "$IPT_SH" 2>&1)
eq 'set -e caller: deleting an existing rule continues' reached "$out"
out=$(CHECK_ERROR=2 sh -e -c '. "$1"; if ipt INPUT -p tcp --dport 443 -j NFQUEUE; then echo bad; else echo "rc=$?"; fi' sh "$IPT_SH" 2>&1)
eq 'set -e caller sees a check error as a status' rc=2 "$out"
eq 'set -e error path releases the lock' free "$(lock_free)"
out=$(sh -e -c '. "$1"; ipt INPUT -p tcp --dport 443 -j NFQUEUE; echo reached' sh "$IPT_SH" 2>&1)
eq 'set -e caller works after an error' reached "$out"

# Installs that predate the flock dependency: no lock, no provisioning, but
# -w and strict statuses still apply.
reset
rm -f "$Z2K_IPT_LOCK"
out=$(PATH="$NOFL" sh -c '. "$1"; command -v flock >/dev/null && echo has-flock
CONTENTION=1 ipt INPUT -p tcp --dport 443 -j NFQUEUE
ipt INPUT -p tcp --dport 443 -j NFQUEUE
CONTENTION=1 ipt INPUT -p tcp --dport 443 -j NFQUEUE
(CHECK_ERROR=2 ipt6 INPUT -p tcp --dport 443 -j NFQUEUE); echo "rc=$?"
ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE; echo "rc=$?"' sh "$IPT_SH" 2>&1)
eq 'without flock: helpers still run and keep statuses' 'rc=2|rc=0|' "$(printf '%s\n' "$out" | tr '\n' '|')"
eq 'without flock: contention still cannot duplicate' 1 "$(count4 "$RULE4")"
eq 'without flock: checks and mutations still wait' 7 "$(wait_flag_count)"
[ -e "$Z2K_IPT_LOCK" ] && made=yes || made=no
eq 'without flock: no lock file is created' no "$made"
[ -f "$STATE/opkg" ] && opkg=called || opkg=none
eq 'helpers never provision packages' none "$opkg"

# An unusable lock path (here: a directory) degrades the same way.
reset
mkdir "$TMP/lockdir"
(Z2K_IPT_LOCK="$TMP/lockdir"; ipt INPUT -p tcp --dport 443 -j NFQUEUE) 2>/dev/null
eq 'unopenable lock path still applies the rule once' '0 1' "$? $(count4 "$RULE4")"

# --- deletion ----------------------------------------------------------------
reset
printf '%s\n%s\n%s\n%s\n' "$RULE4" 'FORWARD -j ACCEPT' "$RULE4" "$RULE4" > "$STATE/rules4"
ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
rc=$?
eq 'explicit deletion succeeds after draining duplicates' 0 "$rc"
eq 'explicit deletion drains every exact IPv4 copy' 0 "$(count4 "$RULE4")"
eq 'explicit IPv4 deletion preserves unrelated rule' 1 "$(count4 'FORWARD -j ACCEPT')"
printf '%s\n%s\n%s\n' "$RULE6" 'FORWARD -j ACCEPT' "$RULE6" > "$STATE/rules6"
ipt6_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'explicit IPv6 deletion drains exact copies' 0 "$(count6 "$RULE6")"
eq 'explicit IPv6 deletion preserves unrelated rule' 1 "$(count6 'FORWARD -j ACCEPT')"
reset
ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'deleting an already absent rule preserves missing status' 1 "$?"
ipt6_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'deleting an already absent IPv6 rule preserves missing status' 1 "$?"

reset
printf '%s\n%s\n' "$RULE4" "$RULE4" > "$STATE/rules4"
ipt INPUT -p tcp --dport 443 -j NFQUEUE
eq 'add-only apply never deletes accumulated copies implicitly' 2 "$(count4 "$RULE4")"

reset
FW_EXTRA_PRE='--pre-one --pre-two'
FW_EXTRA_POST='--post'
ipt INPUT 'argument with spaces' -j NFQUEUE
expected='call <--pre-one> <--pre-two> <-w> <-C> <INPUT> <argument with spaces> <-j> <NFQUEUE> <--post>'
eq 'extra arguments and quoted rule arguments retain their positions' 1 "$(grep -F -x -c -- "$expected" "$STATE/calls")"
expected='call <--pre-one> <--pre-two> <-w> <-I> <INPUT> <argument with spaces> <-j> <NFQUEUE> <--post>'
eq 'extra arguments are kept on the mutation too' 1 "$(grep -F -x -c -- "$expected" "$STATE/calls")"
ipt6 INPUT 'v6 arg' -j NFQUEUE
eq 'IPv6 helpers do not take IPv4 extra arguments' 1 "$(grep -F -x -c -- 'call <-w> <-I> <INPUT> <v6 arg> <-j> <NFQUEUE>' "$STATE/calls")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
