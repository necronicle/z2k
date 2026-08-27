#!/bin/sh
# tests/test_restart_callsites.sh
# Integration tests for the FOUR call sites the restart-latency change touched in
# files/S99zapret2.new (25.1 s -> 1.73 s on a live aarch64 Keenetic):
#
#   stop_daemon_by_pidfile                        sleep 3  -> z2k_wait_gone
#   run_daemon                                    sleep 1  -> case $DAEMONBASE
#   repair_autocircular_files_after_daemon_start  sleep 1  -> ( sleep 1; ... ) &
#   restart                                       sleep 2  -> usleep 200000
#   start                                         duplicate ensure_autocircular_files removed
#
# Method: the functions under test are lifted verbatim out of the init script
# (which cannot be sourced - it exits unless /opt/zapret2 exists and it sources
# a dozen engine files) and driven in a hermetic sh with counting stubs, mock
# daemons on PATH and temp pid dirs, in the style of test_nfqueue_selfheal.sh.
#
# Every assertion here has been shown to go RED when its hunk is reverted; the
# ones that are invariance guards instead (behaviour the change must NOT alter)
# are marked INVARIANT and were proved by mutating the function they cover.
#
# Point the whole battery at a mutated copy with:
#     Z2K_INIT_UNDER_TEST=/tmp/mutant.sh sh tests/test_restart_callsites.sh
#
# HISTORY - two real defects this battery found in the change, both now fixed and
# both re-verified on the live router:
#
#   * run_daemon watched "${QNUM:-200}" - the STANDARD instance's queue - even for
#     a custom.d daemon told --qnum=65301 (custom.sh allocates 65300-65399), so
#     readiness was decided by an unrelated daemon. Fixed: the queue is derived
#     from the daemon's own argument string.
#   * z2k_wait_queue_bound matched the queue NUMBER only, so an instance whose
#     queue was already bound by another process returned on its first iteration
#     having run no external command. The shell had then not reaped the just-died
#     child, `kill -0` answered for a zombie, and a failed start was reported as
#     "started" with a stale pidfile. Fixed: the match now requires queue AND
#     owner (column 2 = netlink peer portid = the binding pid). Because the wait
#     no longer short-circuits, its usleep runs, the child is reaped and `kill -0`
#     tells the truth - so the old `sleep 1`'s guarantee survives without paying
#     any settle. Re-verified on 192.168.1.1 against the deployed script: a daemon
#     that exits(1) immediately yields "ERROR: Daemon 99 failed to start", rc=1,
#     pidfile removed; a live one yields rc=0.
#
# ROUTER-ONLY (cannot be checked here, no BusyBox/procfs/real usleep locally) -
# all four confirmed on 192.168.1.1 while writing this file:
#   [x] /opt/bin/usleep exists            -> the fractional branch is the live one
#   [x] BusyBox sleep rejects "0.1"       -> the usleep dependency is real
#   [x] /proc/net/netfilter/nfnetlink_queue: field 1 is the queue number
#   [x] ash keeps an unreaped child visible to kill -0 (the zombie above)
#   [ ] end-to-end `time S99zapret2 restart` on the live box (covered by
#       test_restart_latency.sh / the 1.73 s measurement, not re-measured here)
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-${Z2K_INIT_UNDER_TEST:-$HERE/files/S99zapret2.new}}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rcs.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export TMP

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$INIT" ] || { printf '[FAIL] init script not found: %s\n' "$INIT"; exit 1; }

# ------------------------------------------------------------------ helpers --
# Lift one function body out of the script without executing the script.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

# load_fns OUTFILE name...   -> sourceable file with those functions
load_fns() {
    _out=$1; shift
    : > "$_out"
    for _f in "$@"; do
        extract_fn "$_f" "$INIT" >> "$_out"
        printf '\n' >> "$_out"
        grep -q "^$_f()" "$_out" || { printf '[FAIL] harness: %s() not found in %s\n' "$_f" "$INIT"; FAIL=$((FAIL+1)); }
    done
}

# field VALUE from a `k=v k=v` line in captured output
val() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }
has() { printf '%s\n' "$1" | grep -q "$2"; }

# ------------------------------------------------------------------- mocks ---
BIN="$TMP/bin"; DEADBIN="$TMP/bin_dead"; mkdir -p "$BIN" "$DEADBIN"
# instant, counting usleep: keeps the fractional branch under test on hosts that
# have no usleep, without paying 50 ms x 60 polls. Never used on the router runs
# below that measure wall clock - those drop $BIN from PATH on purpose.
cat > "$BIN/usleep" <<EOF
#!/bin/sh
echo "\$1" >> "$TMP/usleep.log"
exit 0
EOF
# A REAL sub-second usleep for the two wall-clock cases, installed only where the
# host has none (the router has /opt/bin/usleep and keeps it). Without this the
# fallback `sleep 1` is what gets timed, which is both a second slower than the
# path the router takes and too close to the 1 s fence to be stable under load.
SLOWBIN="$TMP/bin_slow"; mkdir -p "$SLOWBIN"
if command -v usleep >/dev/null 2>&1; then
    SLOWPATH="$PATH"
else
    cat > "$SLOWBIN/usleep" <<'EOF'
#!/bin/sh
# LC_ALL=C is load-bearing: awk's %f honours the locale, so on a ru_RU/de_DE
# runner this printed "0,200" and `sleep 0,200` then FAILED. The old
# `&& sleep "$s" || sleep 1` swallowed that failure into a full second, so every
# emulated usleep cost 1 s and the wall-clock fences below measured ~20x the
# real settle. Fail loudly instead of silently substituting a second.
s=$(LC_ALL=C awk -v u="$1" 'BEGIN{printf "%.3f", u/1000000}' 2>/dev/null)
if [ -z "$s" ]; then echo "usleep-emul: awk failed" >&2; exit 1; fi
if ! sleep "$s" 2>/dev/null; then
    echo "usleep-emul: this sh cannot sleep '$s' (fractional unsupported?)" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$SLOWBIN/usleep"
    SLOWPATH="$SLOWBIN:$PATH"
fi
export SLOWPATH

printf '#!/bin/sh\nexec sleep 300\n' > "$BIN/nfqws2"
printf '#!/bin/sh\nexec sleep 300\n' > "$BIN/tpws2"
# The dead stub leaves a ZOMBIE procfs entry behind, exactly as a process that has
# exited but not yet been reaped does. Without one this host has no procfs at all,
# z2k_pid_running degrades to its `kill -0` fallback, and `kill -0` SUCCEEDS for an
# unreaped zombie - so whether the shell had already reaped the child by the time
# run_daemon looked was a race, and the death assertions below failed about one run
# in ten (observed on both the patched and the unpatched script, so it was the test
# that was wrong, not the code). The fixture makes the zombie branch - the very
# thing the production fix added - deterministic AND actually executed off-router,
# where it was previously never reached.
PROCPID="$TMP/procpid"; mkdir -p "$PROCPID"
DEADFLAG="$TMP/deadflag"
cat > "$DEADBIN/nfqws2" <<EOF
#!/bin/sh
mkdir -p "$PROCPID/\$\$" 2>/dev/null
printf '%s (nfqws2) Z 1 %s %s 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 0\n' "\$\$" "\$\$" "\$\$" > "$PROCPID/\$\$/stat"
: > "$DEADFLAG"
exit 1
EOF
# ...and a usleep that BLOCKS on that flag the first time it is called. run_daemon
# offers exactly one synchronisation point after the spawn - z2k_fracsleep_avail
# probes by running `usleep 1` before the poll loop starts - and without it the
# assertions below were a pure race: the counting usleep stub is instant, so the
# whole 3 s wait completed in milliseconds and the parent inspected a child that
# had not been scheduled yet. On the router the same wait really takes 3 s and the
# child is long dead, which is why this only ever misfired off-router. The flag is
# written by the child AFTER its stat fixture, so once it exists the fixture is
# there too: both the precondition (the child has exited) and the observation (a Z
# entry) are facts by the time run_daemon decides, in either queue state.
DEATHBIN="$TMP/bin_death"; mkdir -p "$DEATHBIN"
cat > "$DEATHBIN/usleep" <<EOF
#!/bin/sh
i=0
# Без дробей и без /bin/sleep: у busybox дробь — «invalid number», а /bin на
# Keenetic это демоны прошивки. Крутим пустой цикл, он и был здесь смыслом —
# дождаться флага, не завися от точности сна.
while [ ! -e "$DEADFLAG" ] && [ \$i -lt 30000 ]; do i=\$((i+1)); done
exit 0
EOF
chmod +x "$BIN/usleep" "$BIN/nfqws2" "$BIN/tpws2" "$DEADBIN/nfqws2" "$DEATHBIN/usleep"
export BIN DEADBIN PROCPID DEADFLAG DEATHBIN

# a pid that is guaranteed dead (spawned, killed, reaped by init)
DEADPID=$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')
kill -9 "$DEADPID" 2>/dev/null
_i=0; while [ "$_i" -lt 50 ]; do kill -0 "$DEADPID" 2>/dev/null || break; _i=$((_i+1)); done
export DEADPID

# ==============================================================================
# 1. stop_daemon_by_pidfile
# ==============================================================================
FNS_STOP="$TMP/fns_stop.sh"
load_fns "$FNS_STOP" z2k_pid_running z2k_fracsleep_avail z2k_wait_gone stop_daemon_by_pidfile
export FNS_STOP

# --- 1a. deterministic signal/poll accounting -------------------------------
# `kill` and the sleeps are counting stubs, so no real process and no real time
# is involved: what is asserted is the exact syscall shape of the stop path.
cat > "$TMP/c_stop_stub.sh" <<'EOF'
. "$FNS_STOP"
mode=$1; Z2K_FRACSLEEP=$2
SIG="$TMP/sig.log"; : > "$SIG"
KZ=0; POLLS=0; SLEEPS=
# NB: counters must not be named pid/max/i/n - z2k_wait_gone declares those
# `local`, and under sh dynamic scoping a stub would write the function's local.
kill() {
    case "$1" in
        -0) if [ "$mode" = stubborn ]; then return 0; fi
            KZ=$((KZ+1)); [ "$KZ" -le 1 ] ;;
        -9) printf 'SIGKILL %s\n' "$2" >> "$SIG" ;;
        *)  printf 'SIGTERM %s\n' "$1" >> "$SIG" ;;
    esac
}
usleep() { POLLS=$((POLLS+1)); }
sleep()  { POLLS=$((POLLS+1)); SLEEPS="$SLEEPS$1,"; }
printf '4242\n' > "$TMP/d.pid"
stop_daemon_by_pidfile "$TMP/d.pid"; rc=$?
printf 'rc=%s polls=%s sleeps=%s pidfile=%s term=%s kill9=%s\n' \
    "$rc" "$POLLS" "${SLEEPS:-none}" \
    "$([ -e "$TMP/d.pid" ] && echo present || echo removed)" \
    "$(grep -c '^SIGTERM 4242$' "$SIG")" "$(grep -c '^SIGKILL 4242$' "$SIG")"
EOF

out=$(sh "$TMP/c_stop_stub.sh" fast 1 2>&1)
[ "$(val "$out" term)" = 1 ] && ok "stop: sends exactly one SIGTERM to the pid" \
    || no "stop: sends exactly one SIGTERM to the pid" 1 "$(val "$out" term)"
[ "$(val "$out" polls)" = 0 ] && ok "stop: fast death returns without a single poll (was sleep 3)" \
    || no "stop: fast death returns without a single poll (was sleep 3)" 0 "$(val "$out" polls)"
[ "$(val "$out" sleeps)" = none ] && ok "stop: fast death sleeps for nothing at all" \
    || no "stop: fast death sleeps for nothing at all" none "$(val "$out" sleeps)"
[ "$(val "$out" kill9)" = 0 ] && ok "stop: no SIGKILL when SIGTERM worked (INVARIANT)" \
    || no "stop: no SIGKILL when SIGTERM worked (INVARIANT)" 0 "$(val "$out" kill9)"
[ "$(val "$out" pidfile)" = removed ] && ok "stop: pidfile removed after a normal stop (INVARIANT)" \
    || no "stop: pidfile removed after a normal stop (INVARIANT)" removed "$(val "$out" pidfile)"

out=$(sh "$TMP/c_stop_stub.sh" stubborn 1 2>&1)
[ "$(val "$out" kill9)" = 1 ] && ok "stop: SIGKILL after the deadline when SIGTERM is ignored (INVARIANT)" \
    || no "stop: SIGKILL after the deadline when SIGTERM is ignored (INVARIANT)" 1 "$(val "$out" kill9)"
[ "$(val "$out" polls)" = 60 ] && ok "stop: stubborn daemon polls 3 s / 50 ms = 60 times, then gives up" \
    || no "stop: stubborn daemon polls 3 s / 50 ms = 60 times, then gives up" 60 "$(val "$out" polls)"
[ "$(val "$out" pidfile)" = removed ] && ok "stop: pidfile removed even after SIGKILL (INVARIANT)" \
    || no "stop: pidfile removed even after SIGKILL (INVARIANT)" removed "$(val "$out" pidfile)"

out=$(sh "$TMP/c_stop_stub.sh" stubborn 0 2>&1)
[ "$(val "$out" sleeps)" = "1,1,1," ] && ok "stop: no-usleep box keeps the 3 s ceiling as 3x sleep 1" \
    || no "stop: no-usleep box keeps the 3 s ceiling as 3x sleep 1" "1,1,1," "$(val "$out" sleeps)"
[ "$(val "$out" kill9)" = 1 ] && ok "stop: SIGKILL still fires on the no-usleep path (INVARIANT)" \
    || no "stop: SIGKILL still fires on the no-usleep path (INVARIANT)" 1 "$(val "$out" kill9)"

# --- 1b. real process, real clock -------------------------------------------
# The counting mocks are deliberately NOT on PATH here: real signals, a real
# process and a real sub-second usleep, so this measures the wall clock the
# router actually pays on the fractional path.
cat > "$TMP/c_stop_real.sh" <<'EOF'
. "$FNS_STOP"
# The victim runs under a tiny reaper (`... & echo $!; wait`) instead of being
# our own child or an orphan. Both alternatives make the measurement depend on
# something other than the code under test: our own child stays a zombie (a
# zombie still answers kill -0, so the wait would run to the SIGKILL deadline
# every time), and an orphan waits on init/launchd to reap it - which on a busy
# macOS host takes long enough to fail a 1 s fence roughly one run in four. A
# dedicated parent sitting in wait() frees the pid the moment it dies.
rm -f "$TMP/victim.pid"
sh -c 'sleep 300 >/dev/null 2>&1 & echo $! > "$TMP/victim.pid"; wait' >/dev/null 2>&1 &
i=0
while [ ! -s "$TMP/victim.pid" ] && [ "$i" -lt 100 ]; do
    usleep 20000 2>/dev/null || sleep 1
    i=$((i+1))
done
pid=$(cat "$TMP/victim.pid" 2>/dev/null)
# prealive guards the whole case: if the victim never came up, every assertion
# below would pass for the wrong reason (nothing to signal, nothing to wait for).
kill -0 "$pid" 2>/dev/null && prealive=yes || prealive=no
printf '%s\n' "$pid" > "$TMP/r.pid"
t0=$(date +%s)
stop_daemon_by_pidfile "$TMP/r.pid"; rc=$?
t1=$(date +%s)
kill -0 "$pid" 2>/dev/null && alive=yes || alive=no
kill -9 "$pid" 2>/dev/null
printf 'rc=%s elapsed=%s prealive=%s alive=%s pidfile=%s\n' "$rc" "$((t1-t0))" "$prealive" "$alive" \
    "$([ -e "$TMP/r.pid" ] && echo present || echo removed)"
EOF
out=$(PATH="$SLOWPATH" sh "$TMP/c_stop_real.sh" 2>&1)
el=$(val "$out" elapsed)
[ "$(val "$out" prealive)" = yes ] && ok "stop: harness really had a live daemon to stop" \
    || no "stop: harness really had a live daemon to stop" yes "$(val "$out" prealive)"
[ "${el:-99}" -le 1 ] && ok "stop: real SIGTERM-able daemon stops in <=1 s (was 3 s)" \
    || no "stop: real SIGTERM-able daemon stops in <=1 s (was 3 s)" "<=1" "$el"
[ "$(val "$out" alive)" = no ] && ok "stop: the daemon is really gone when the call returns" \
    || no "stop: the daemon is really gone when the call returns" no "$(val "$out" alive)"
[ "$(val "$out" pidfile)" = removed ] && ok "stop: pidfile removed (real process path)" \
    || no "stop: pidfile removed (real process path)" removed "$(val "$out" pidfile)"

# --- 1c. degenerate pidfiles: ALWAYS removed, never a stray signal ----------
# Pre-existing behaviour; asserted so the diff is shown not to have changed it.
cat > "$TMP/c_stop_edge.sh" <<'EOF'
. "$FNS_STOP"
SIG="$TMP/esig.log"; : > "$SIG"
kill() { printf '%s\n' "$*" >> "$SIG"; return 1; }   # nothing is alive; record all
f="$TMP/e.pid"; rm -f "$f"
case "$1" in
    empty)   : > "$f" ;;
    blank)   printf '   \n' > "$f" ;;
    garbage) printf 'not-a-pid\n' > "$f" ;;
    dead)    printf '%s\n' "$DEADPID" > "$f" ;;
    missing) : ;;
esac
stop_daemon_by_pidfile "$f"; rc=$?
printf 'rc=%s pidfile=%s term=%s kill9=%s\n' "$rc" \
    "$([ -e "$f" ] && echo present || echo removed)" \
    "$(grep -cv '^-' "$SIG")" "$(grep -c '^-9' "$SIG")"
EOF
for m in empty blank garbage dead; do
    out=$(sh "$TMP/c_stop_edge.sh" "$m" 2>&1)
    [ "$(val "$out" pidfile)" = removed ] && ok "stop: $m pidfile is removed (INVARIANT)" \
        || no "stop: $m pidfile is removed (INVARIANT)" removed "$(val "$out" pidfile)"
    [ "$(val "$out" term)" = 0 ] && ok "stop: $m pidfile sends no signal (INVARIANT)" \
        || no "stop: $m pidfile sends no signal (INVARIANT)" 0 "$(val "$out" term)"
done
out=$(sh "$TMP/c_stop_edge.sh" missing 2>&1)
if [ "$(val "$out" rc)" = 0 ] && [ "$(val "$out" term)" = 0 ] && [ "$(val "$out" pidfile)" = removed ]; then
    ok "stop: absent pidfile is a silent no-op (INVARIANT)"
else
    no "stop: absent pidfile is a silent no-op (INVARIANT)" "rc=0 term=0 absent" "$out"
fi

# ==============================================================================
# 2. run_daemon
# ==============================================================================
FNS_RUN="$TMP/fns_run.sh"
# z2k_daemon_err_file / z2k_daemon_explain — зависимости run_daemon с 2026-08-13:
# демон запускается со stderr в файл, чтобы причина отказа не пропадала. Без них
# извлечённый run_daemon падает на «command not found», и обвязка проверяет не
# то, что выполняется на роутере.
load_fns "$FNS_RUN" z2k_pid_running z2k_fracsleep_avail z2k_wait_queue_bound \
                    z2k_daemon_err_file z2k_daemon_explain run_daemon
export FNS_RUN
# Same functions, but with the hardcoded proc path repointed at a fixture so the
# real z2k_wait_queue_bound can run off-router. ONLY that literal is rewritten.
FNS_RUN_PROC="$TMP/fns_run_proc.sh"
PROCFIX="$TMP/nfnetlink_queue"
sed -e "s|< /proc/net/netfilter/nfnetlink_queue|< \"$PROCFIX\"|" \
    -e 's|"/proc/\$1/stat"|"$PROCPID/$1/stat"|g' "$FNS_RUN" > "$FNS_RUN_PROC"
export FNS_RUN_PROC PROCFIX

# Behavioural self-check of that second rewrite: with a fixture in place the
# zombie branch must be what decides, not the `kill -0` fallback. The SAME live
# pid must read as dead with a Z entry and alive with an S entry, so a rewrite
# that silently failed (fixture never opened) cannot satisfy both.
cat > "$TMP/c_zombie.sh" <<'EOF'
. "$FNS_RUN_PROC"
mkdir -p "$PROCPID/$$"
printf '%s (nfqws2) Z 1 0 0 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0\n' "$$" > "$PROCPID/$$/stat"
z2k_pid_running $$; echo "zomb=$?"
printf '%s (nfqws2) S 1 0 0 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0\n' "$$" > "$PROCPID/$$/stat"
z2k_pid_running $$; echo "live=$?"
rm -rf "$PROCPID/$$"
EOF
out=$(PATH="$BIN:$PATH" sh "$TMP/c_zombie.sh" 2>&1)
if [ "$(val "$out" zomb)" = 1 ] && [ "$(val "$out" live)" = 0 ]; then
    ok "harness: the procfs fixture drives z2k_pid_running (Z=dead, S=alive)"
else
    no "harness: the procfs fixture drives z2k_pid_running (Z=dead, S=alive)" "zomb=1 live=0" "$out"
fi
# Behavioural self-check of that substitution. A timeout is NOT an error in
# z2k_wait_queue_bound, so a fixture it cannot read still returns 0 - the only
# way to tell "matched the queue" from "gave up" is the poll count. 0-1 polls
# means the first read saw the queue (0 if the read precedes the poll-sleep, 1 if
# it follows it); 20 means the fixture was never read and the two death cases
# below would be proving nothing.
cat > "$TMP/c_fixture.sh" <<'EOF'
. "$FNS_RUN_PROC"
# Column 2 is the owning pid: z2k_wait_queue_bound matches queue AND owner, so
# the fixture must name the very pid we hand it or nothing will ever match.
printf '  777  %s     0 2 65531     0     0      358  1\n' "$$" > "$PROCFIX"
: > "$TMP/usleep.log"
z2k_wait_queue_bound $$ 777 1; rc=$?
printf 'rc=%s polls=%s\n' "$rc" "$(wc -l < "$TMP/usleep.log" | tr -d ' ')"
EOF
out=$(PATH="$BIN:$PATH" sh "$TMP/c_fixture.sh" 2>&1)
pv=$(val "$out" polls)
if [ "$(val "$out" rc)" = 0 ] && [ "${pv:-99}" -le 1 ]; then
    ok "harness: the queue fixture is really being read (matched immediately)"
else
    no "harness: the queue fixture is really being read (matched immediately)" "rc=0 polls<=1" "$out"
fi

# --- 1b. a queue owned by ANOTHER process must NOT count as ours -------------
# z2k_wait_queue_bound matches queue number AND owner (column 2 = netlink peer
# portid = the binding pid). Matching the number alone would let a custom.d
# instance "become ready" the instant it saw the MAIN daemon's queue, which
# also collapses the window in which an instantly-dying daemon is caught. The
# qnum-routing tests below happen to pass without the owner check (they use a
# non-matching qnum), so this is the only assertion that pins it.
cat > "$TMP/c_foreign_owner.sh" <<'EOF'
. "$FNS_RUN_PROC"
# Right queue, WRONG owner: a live pid that is not us.
sleep 30 & other=$!
printf '  777  %s     0 2 65531     0     0      358  1\n' "$other" > "$PROCFIX"
: > "$TMP/usleep.log"
z2k_wait_queue_bound $$ 777 1; rc=$?
kill $other 2>/dev/null
printf 'rc=%s polls=%s\n' "$rc" "$(wc -l < "$TMP/usleep.log" | tr -d ' ')"
EOF
out=$(PATH="$BIN:$PATH" sh "$TMP/c_foreign_owner.sh" 2>&1)
pv=$(val "$out" polls)
# Must NOT short-circuit: it has to keep polling to the deadline (20 at 50 ms).
if [ "${pv:-0}" -ge 5 ]; then
    ok "wait_queue_bound: a queue owned by another pid is not accepted as ours"
else
    no "wait_queue_bound: a queue owned by another pid is not accepted as ours" \
       "polls>=5 (kept waiting)" "$out"
fi
# ...and the same fixture WITH our own pid must match at once, proving the
# assertion above fails for the right reason (owner mismatch, not a dead fixture).
cat > "$TMP/c_own_owner.sh" <<'EOF'
. "$FNS_RUN_PROC"
printf '  777  %s     0 2 65531     0     0      358  1\n' "$$" > "$PROCFIX"
: > "$TMP/usleep.log"
z2k_wait_queue_bound $$ 777 1; rc=$?
printf 'rc=%s polls=%s\n' "$rc" "$(wc -l < "$TMP/usleep.log" | tr -d ' ')"
EOF
out=$(PATH="$BIN:$PATH" sh "$TMP/c_own_owner.sh" 2>&1)
pv=$(val "$out" polls)
if [ "$(val "$out" rc)" = 0 ] && [ "${pv:-99}" -le 1 ]; then
    ok "wait_queue_bound: the same fixture owned by US matches immediately"
else
    no "wait_queue_bound: the same fixture owned by US matches immediately" "rc=0 polls<=1" "$out"
fi

# --- 2a. the DAEMONBASE case: both arms -------------------------------------
cat > "$TMP/c_run_route.sh" <<'EOF'
. "$FNS_RUN"
PIDDIR="$TMP/pids"; mkdir -p "$PIDDIR"
CALLS="$TMP/calls"; : > "$CALLS"
QNUM=200
DAEMON=$1; DBASE=$(basename "$DAEMON"); PF="$PIDDIR/${DBASE}_7.pid"; rm -f "$PF"
# The wait stub records what it was handed AND what the pidfile held when it ran
# - that is the proof the pidfile is written before the wait, not after.
z2k_wait_queue_bound() {
    printf 'wqb=%s\n' "$*" >> "$CALLS"
    printf 'wqbpidfile=%s\n' "$(cat "$PF" 2>/dev/null)" >> "$CALLS"
    return 0
}
sleep() { printf 'slept=%s\n' "$1" >> "$CALLS"; command sleep "$@"; }
run_daemon 7 "$DAEMON" "--qnum=65301 --x"; rc=$?
printf 'rc=%s pid=%s\n' "$rc" "$(cat "$PF" 2>/dev/null)"
cat "$CALLS"
p=$(cat "$PF" 2>/dev/null); [ -n "$p" ] && kill -9 "$p" 2>/dev/null
exit 0
EOF

out=$(PATH="$BIN:$PATH" sh "$TMP/c_run_route.sh" "$BIN/nfqws2" 2>&1)
pid=$(val "$out" pid)
has "$out" '^wqb=' && ok "run_daemon: nfqws2 waits on z2k_wait_queue_bound" \
    || no "run_daemon: nfqws2 waits on z2k_wait_queue_bound" "wqb called" "not called"
has "$out" '^slept=' && no "run_daemon: nfqws2 arm does NOT fall back to sleep 1" "no sleep" "slept" \
    || ok "run_daemon: nfqws2 arm does NOT fall back to sleep 1"
[ "$(val "$out" wqb)" = "$pid" ] && ok "run_daemon: wait gets the spawned pid" \
    || no "run_daemon: wait gets the spawned pid" "$pid" "$(val "$out" wqb)"
[ "$(val "$out" wqbpidfile)" = "$pid" ] && ok "run_daemon: pidfile is written BEFORE the wait (ordering kept)" \
    || no "run_daemon: pidfile is written BEFORE the wait (ordering kept)" "$pid" "$(val "$out" wqbpidfile)"
has "$out" 'wqb=[0-9]* [0-9]* 3$' && ok "run_daemon: wait is bounded at 3 s" \
    || no "run_daemon: wait is bounded at 3 s" "3" "$(printf '%s' "$out" | sed -n 's/^wqb=//p')"
# The daemon was told --qnum=65301; watching the global QNUM watches SOMEBODY
# ELSE's queue (custom.d instances allocate 65300-65399 while QNUM stays the
# standard instance's), so readiness is decided by an unrelated daemon.
qn=$(printf '%s\n' "$out" | sed -n 's/^wqb=[0-9]* \([0-9]*\) .*/\1/p' | head -1)
[ "$qn" = 65301 ] && ok "run_daemon: waits on the queue THIS daemon was told to bind (--qnum)" \
    || no "run_daemon: waits on the queue THIS daemon was told to bind (--qnum)" 65301 "$qn"
[ "$(val "$out" rc)" = 0 ] && ok "run_daemon: live daemon reported started (INVARIANT)" \
    || no "run_daemon: live daemon reported started (INVARIANT)" 0 "$(val "$out" rc)"

out=$(PATH="$BIN:$PATH" sh "$TMP/c_run_route.sh" "$BIN/tpws2" 2>&1)
[ "$(val "$out" slept)" = 1 ] && ok "run_daemon: non-nfqws2 daemon keeps the old sleep 1" \
    || no "run_daemon: non-nfqws2 daemon keeps the old sleep 1" 1 "$(val "$out" slept)"
has "$out" '^wqb=' && no "run_daemon: non-nfqws2 daemon does not touch the queue wait" "no wqb" "wqb called" \
    || ok "run_daemon: non-nfqws2 daemon does not touch the queue wait"
[ "$(val "$out" rc)" = 0 ] && ok "run_daemon: live non-nfqws2 daemon reported started (INVARIANT)" \
    || no "run_daemon: live non-nfqws2 daemon reported started (INVARIANT)" 0 "$(val "$out" rc)"

# --- 2b. a daemon that dies instantly must still be a FAILURE ---------------
# This is the guarantee the old `sleep 1` gave for free: the foreground sleep
# let the shell reap the dead child, so the following `kill -0` saw ESRCH. Any
# replacement must keep it - a false "started" leaves a stale pidfile, makes
# `status` lie and hides a broken option string.
cat > "$TMP/c_run_death.sh" <<'EOF'
. "$FNS_RUN_PROC"
PIDDIR="$TMP/pids"; mkdir -p "$PIDDIR"
QNUM=200
rm -f "$PIDDIR/nfqws2_9.pid"
out=$(run_daemon 9 "$DEADBIN/nfqws2" "--qnum=65301"; echo "rc=$?")
# zfixt counts the Z entries the child left behind. If the synchronisation above
# ever stops working this drops to 0, so the assertions cannot silently go back
# to being decided by the `kill -0` fallback.
printf '%s pidfile=%s err=%s zfixt=%s\n' "$(printf '%s' "$out" | tr '\n' ' ')" \
    "$([ -e "$PIDDIR/nfqws2_9.pid" ] && echo present || echo removed)" \
    "$(printf '%s' "$out" | grep -c 'failed to start')" \
    "$(grep -l ') Z ' "$PROCPID"/*/stat 2>/dev/null | grep -c .)"
EOF
: > "$PROCFIX"
# The flag must be fresh for every run, or the blocking usleep sees the PREVIOUS
# child's flag and stops synchronising anything.
rm -rf "$PROCPID"; mkdir -p "$PROCPID"; rm -f "$DEADFLAG"
out=$(PATH="$DEATHBIN:$PATH" sh "$TMP/c_run_death.sh" 2>&1)
[ "$(val "$out" zfixt)" -ge 1 ] 2>/dev/null \
    && ok "harness: the dying child really left a Z entry (sync held)" \
    || no "harness: the dying child really left a Z entry (sync held)" ">=1" "$out"
[ "$(val "$out" rc)" = 1 ] && ok "run_daemon: instant death -> failure (queue not yet bound)" \
    || no "run_daemon: instant death -> failure (queue not yet bound)" 1 "$(val "$out" rc)"
[ "$(val "$out" pidfile)" = removed ] && ok "run_daemon: failed start removes the pidfile" \
    || no "run_daemon: failed start removes the pidfile" removed "$(val "$out" pidfile)"
[ "$(val "$out" err)" = 1 ] && ok "run_daemon: failed start says so on stdout" \
    || no "run_daemon: failed start says so on stdout" 1 "$(val "$out" err)"

# Same, but the watched queue is ALREADY bound (another nfqws2 instance holds
# it - the custom.d case, or a survivor of a half-finished stop). The wait then
# returns on its first iteration, so the ONLY thing standing between the spawn
# and the verdict is z2k_pid_running itself: this is the case the procfs Z check
# exists for, and the one `kill -0` alone gets wrong.
printf '  200  28558     0 2 65531     0     0      358  1\n' > "$PROCFIX"
rm -rf "$PROCPID"; mkdir -p "$PROCPID"; rm -f "$DEADFLAG"
out=$(PATH="$DEATHBIN:$PATH" sh "$TMP/c_run_death.sh" 2>&1)
[ "$(val "$out" zfixt)" -ge 1 ] 2>/dev/null \
    && ok "harness: the dying child left a Z entry (queue already bound)" \
    || no "harness: the dying child left a Z entry (queue already bound)" ">=1" "$out"
[ "$(val "$out" rc)" = 1 ] && ok "run_daemon: instant death -> failure (queue already bound)" \
    || no "run_daemon: instant death -> failure (queue already bound)" 1 "$(val "$out" rc)"
[ "$(val "$out" pidfile)" = removed ] && ok "run_daemon: failed start removes the pidfile (queue already bound)" \
    || no "run_daemon: failed start removes the pidfile (queue already bound)" removed "$(val "$out" pidfile)"

# ==============================================================================
# 3. repair_autocircular_files_after_daemon_start
# ==============================================================================
# Deterministic, no clock: ensure_autocircular_files appends one line per call.
# Exactly one line the instant the function returns proves BOTH that the
# immediate pass ran synchronously (commit 49991d0 guards both sides of the
# exec/lua-init race) AND that the t+1s pass did not block the caller. Two lines
# a moment later prove the deferred pass really executes.
FNS_REPAIR="$TMP/fns_repair.sh"
load_fns "$FNS_REPAIR" repair_autocircular_files_after_daemon_start
export FNS_REPAIR
cat > "$TMP/c_repair.sh" <<'EOF'
. "$FNS_REPAIR"
LOG="$TMP/ensure.log"; : > "$LOG"
ensure_autocircular_files() { printf 'pass\n' >> "$LOG"; }
t0=$(date +%s)
repair_autocircular_files_after_daemon_start; rc=$?
t1=$(date +%s)
at_return=$(wc -l < "$LOG" | tr -d ' ')
i=0
while [ "$i" -lt 40 ]; do
    [ "$(wc -l < "$LOG" | tr -d ' ')" -ge 2 ] && break
    sleep 1; i=$((i+1))
done
printf 'rc=%s atreturn=%s later=%s elapsed=%s\n' "$rc" "$at_return" \
    "$(wc -l < "$LOG" | tr -d ' ')" "$((t1-t0))"
EOF
out=$(sh "$TMP/c_repair.sh" 2>&1)
[ "$(val "$out" atreturn)" = 1 ] && ok "repair: immediate pass ran, deferred one did not block the return" \
    || no "repair: immediate pass ran, deferred one did not block the return" 1 "$(val "$out" atreturn)"
[ "$(val "$out" later)" = 2 ] && ok "repair: the t+1s pass still executes (off the critical path)" \
    || no "repair: the t+1s pass still executes (off the critical path)" 2 "$(val "$out" later)"
[ "$(val "$out" rc)" = 0 ] && ok "repair: returns success (INVARIANT)" \
    || no "repair: returns success (INVARIANT)" 0 "$(val "$out" rc)"

# ==============================================================================
# 4. restart()
# ==============================================================================
FNS_RESTART="$TMP/fns_restart.sh"
load_fns "$FNS_RESTART" z2k_fracsleep_avail restart
export FNS_RESTART
cat > "$TMP/c_restart.sh" <<'EOF'
. "$FNS_RESTART"
[ -n "$1" ] && Z2K_FRACSLEEP=$1
LOG="$TMP/order.log"; : > "$LOG"
: > "$TMP/usleep.log"
SLEPT=
stop()  { printf 'stop\n'  >> "$LOG"; }
start() { printf 'start\n' >> "$LOG"; }
sleep() { SLEPT="$SLEPT$1,"; }
t0=$(date +%s); restart; rc=$?; t1=$(date +%s)
printf 'rc=%s order=%s slept=%s usleep=%s elapsed=%s\n' "$rc" \
    "$(tr '\n' ',' < "$LOG")" "${SLEPT:-none}" \
    "$(tr '\n' ',' < "$TMP/usleep.log" 2>/dev/null)" "$((t1-t0))"
EOF

out=$(PATH="$BIN:$PATH" sh "$TMP/c_restart.sh" 2>&1)
[ "$(val "$out" order)" = "stop,start," ] && ok "restart: stop then start, exactly once each" \
    || no "restart: stop then start, exactly once each" "stop,start," "$(val "$out" order)"
# z2k_fracsleep_avail now probes by EXECUTING usleep, so the mock records that
# call too. The settle is the LAST entry; pinning the whole log would couple this
# assertion to the probe's argument.
_ulog=$(val "$out" usleep)
case "$_ulog" in
    *200000,) ok "restart: settles with usleep 200000, not sleep 2" ;;
    *)        no "restart: settles with usleep 200000, not sleep 2" "*200000," "$_ulog" ;;
esac
case "$_ulog" in
    1,*) ok "restart: the fracsleep probe executes usleep rather than looking it up" ;;
    *)   no "restart: the fracsleep probe executes usleep rather than looking it up" "1,*" "$_ulog" ;;
esac
[ "$(val "$out" slept)" = none ] && ok "restart: no whole-second sleep when usleep exists" \
    || no "restart: no whole-second sleep when usleep exists" none "$(val "$out" slept)"

out=$(PATH="$BIN:$PATH" sh "$TMP/c_restart.sh" 0 2>&1)
[ "$(val "$out" slept)" = "1," ] && ok "restart: no-usleep box settles with ONE sleep 1 (was sleep 2)" \
    || no "restart: no-usleep box settles with ONE sleep 1 (was sleep 2)" "1," "$(val "$out" slept)"

# real clock, real sleep/usleep of the host
cat > "$TMP/c_restart_real.sh" <<'EOF'
. "$FNS_RESTART"
stop()  { :; }
start() { :; }
t0=$(date +%s); restart; t1=$(date +%s)
printf 'elapsed=%s\n' "$((t1-t0))"
EOF
out=$(PATH="$SLOWPATH" sh "$TMP/c_restart_real.sh" 2>&1)
el=$(val "$out" elapsed)
[ "${el:-99}" -le 1 ] && ok "restart: the settle costs <=1 s of wall clock (was 2 s)" \
    || no "restart: the settle costs <=1 s of wall clock (was 2 s)" "<=1" "$el"

# ==============================================================================
# 5. start() / start_daemons() / restart_daemons()
# ==============================================================================
# The removed duplicate must not have cost coverage: ensure_autocircular_files
# still has to run BEFORE the daemon is spawned on every path that spawns one.
FNS_START="$TMP/fns_start.sh"
load_fns "$FNS_START" start start_daemons stop_daemons restart_daemons
export FNS_START
cat > "$TMP/c_start.sh" <<'EOF'
. "$FNS_START"
TRACE="$TMP/trace.log"; : > "$TRACE"
t() { printf '%s\n' "$1" >> "$TRACE"; }
ENABLED=1; INIT_APPLY_FW=1
load_modules()                    { t load_modules; }
start_fw()                        { t start_fw; }
ensure_autohostlist_files()       { t ensure_autohostlist_files; }
sync_autohostlist_to_rkn()        { t sync_autohostlist_to_rkn; }
ensure_traffic_debug_files()      { t ensure_traffic_debug_files; }
traffic_debug_prepare()           { t traffic_debug_prepare; }
traffic_debug_enable_nfqws2_log() { t traffic_debug_enable_nfqws2_log; }
traffic_debug_tcpdump_start()     { t traffic_debug_tcpdump_start; }
ensure_autocircular_files()       { t ensure_autocircular_files; }
standard_mode_daemons()           { t SPAWN; }
custom_runner()                   { t "custom_runner $1"; }
stop_all_nfqws()                  { t stop_all_nfqws; }
repair_autocircular_files_after_daemon_start() { t repair; }
sleep() { t "sleep $1"; }
"$1" >/dev/null 2>&1
tr '\n' ',' < "$TRACE"
echo
EOF
idx() { printf '%s\n' "$1" | tr ',' '\n' | grep -n "^$2\$" | head -1 | cut -d: -f1; }
cnt() { printf '%s\n' "$1" | tr ',' '\n' | grep -c "^$2\$"; }

for verb in start start_daemons restart_daemons; do
    tr_out=$(sh "$TMP/c_start.sh" "$verb" 2>&1 | tail -1)
    e=$(idx "$tr_out" ensure_autocircular_files); s=$(idx "$tr_out" SPAWN)
    if [ -n "$e" ] && [ -n "$s" ] && [ "$e" -lt "$s" ]; then
        ok "$verb: ensure_autocircular_files runs before the daemon is spawned"
    else
        no "$verb: ensure_autocircular_files runs before the daemon is spawned" "ensure<spawn" "ensure=$e spawn=$s"
    fi
    c=$(cnt "$tr_out" ensure_autocircular_files)
    [ "$c" = 1 ] && ok "$verb: ensure_autocircular_files runs exactly once (duplicate gone)" \
        || no "$verb: ensure_autocircular_files runs exactly once (duplicate gone)" 1 "$c"
    r=$(idx "$tr_out" repair)
    if [ -n "$r" ] && [ -n "$s" ] && [ "$s" -lt "$r" ]; then
        ok "$verb: the post-spawn repair pass still runs after the spawn (INVARIANT)"
    else
        no "$verb: the post-spawn repair pass still runs after the spawn (INVARIANT)" "spawn<repair" "spawn=$s repair=$r"
    fi
done

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
