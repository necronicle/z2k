#!/bin/sh
# tests/test_restart_helpers.sh
# Unit tests for the three wait helpers added to files/S99zapret2.new when the
# service restart was cut from 25.1 s to 1.73 s:
#
#   z2k_fracsleep_avail   - probe-once/cache "do we have sub-second sleep?"
#   z2k_wait_gone         - bounded wait for a pid to die (replaces `sleep 3`)
#   z2k_wait_queue_bound  - bounded wait for nfqws2's NFQUEUE to appear
#                           (replaces `sleep 1`)
#
# THE PROPERTY THAT MATTERS MOST: both waits are bounded in WALL-CLOCK TIME, not
# in iterations. With fractional sleep they poll max*20 times at 50 ms; WITHOUT
# it they must poll max times at 1 s. Keeping the max*20 count on a box with no
# usleep would turn a 3 s SIGKILL deadline into 60 s and stall every restart and
# every self-heal behind one wedged daemon (OOM, MIPS async-preempt). That exact
# mistake was caught in review, so both branches assert the poll COUNT and the
# resulting time budget.
#
# The helpers are pulled out of the init script textually - the script exits
# early unless /opt/zapret2 exists, so it cannot be sourced on a dev box.
#
# POSIX sh. Set Z2K_INIT to point at a mutated copy (used by the mutation
# harness to prove every assertion below can actually go red).

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-${Z2K_INIT_UNDER_TEST:-$HERE/files/S99zapret2.new}}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rhelp.XXXXXX") || exit 1
# snip() runs every case in a CHILD shell, so anything the stubs need to hand
# back through the filesystem must be reachable there. Without this export the
# usleep stub wrote to "/usleep_us" and failed silently, and the deadline budget
# read back empty.
export TMP
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

[ -f "$INIT" ] || { printf '[FAIL] init script not found: %s\n' "$INIT"; exit 1; }

# Child snippets run under dash when available (closest local stand-in for the
# router's BusyBox ash: real `local`, no bash-isms). Falls back to /bin/sh, which
# IS ash on the router.
TSH=$(command -v dash 2>/dev/null) || TSH=/bin/sh
[ -x "$TSH" ] || TSH=/bin/sh

# ---------------------------------------------------------------- extract ---
# Pull one function out of the script without executing it. Comments are
# stripped so that a mutation's leftover commentary can never satisfy a check.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1; print; next }
        inf && /^}/ { print; exit }
        inf { print }
    ' "$2" | grep -v '^[[:space:]]*#'
}

LIB="$TMP/lib.sh"
{
    # the global the probe caches into, taken verbatim from the script
    grep -E '^Z2K_FRACSLEEP=' "$INIT" | head -1
    extract_fn z2k_fracsleep_avail  "$INIT"; echo
    extract_fn z2k_pid_running      "$INIT"; echo
    extract_fn z2k_wait_gone        "$INIT"; echo
    extract_fn z2k_wait_queue_bound "$INIT"; echo
} > "$LIB"

for f in z2k_fracsleep_avail z2k_wait_gone z2k_wait_queue_bound; do
    if grep -q "^$f()" "$LIB"; then ok "extracted $f()"
    else no "extracted $f()" "a definition" "none"; fi
done
# Guard against the extractor silently returning a stub: the real bodies poll.
grep -q 'kill -0' "$LIB"     && ok "extraction kept the liveness poll" \
                             || no "extraction kept the liveness poll" "kill -0" "absent"
# Syntax check, where the shell has one. Keenetic's /bin/sh rejects -n
# ("Invalid option", rc 245), so probe for the capability instead of assuming it.
printf 'true\n' > "$TMP/probe.sh"
if "$TSH" -n "$TMP/probe.sh" 2>/dev/null; then
    "$TSH" -n "$LIB" 2>/dev/null && ok "extracted helpers parse as POSIX sh" \
                                 || no "extracted helpers parse as POSIX sh" 0 "$?"
else
    ok "extracted helpers parse as POSIX sh (skipped: $TSH has no -n mode)"
fi

# --------------------------------------------------- queue-file indirection ---
# z2k_wait_queue_bound hardcodes /proc/net/netfilter/nfnetlink_queue. There is no
# way to fake that path on a dev box (macOS has no /proc; Linux CI cannot bind a
# file over it unprivileged), so the PARSING tests run against a copy in which
# only that one path is rewritten to $Z2K_QFILE. Everything else - the loop, the
# liveness check, the comparison, the return values - is the shipped code. The
# rewrite is verified to touch exactly one line, so it cannot smuggle in a fix.
# What is NOT covered locally: that the real procfs file has the format assumed.
# That is a router-only check (see QA note at the bottom of this file).
QPROC='/proc/net/netfilter/nfnetlink_queue'
QLIB="$TMP/qlib.sh"
nref=$(grep -c "$QPROC" "$LIB")
eq "queue file referenced exactly once in the helper" 1 "$nref"
sed "s#$QPROC#\"\$Z2K_QFILE\"#g" "$LIB" > "$QLIB"
# Line-by-line compare in awk: BusyBox `diff` emits a UNIFIED diff by default,
# so counting '^[<>]' silently returns 0 there and the guard would pass blind.
ndiff=$(awk 'NR==FNR{a[FNR]=$0;n=FNR;next}
             {if(a[FNR]!=$0)d++}
             END{if(FNR!=n)d=-1; print d+0}' "$LIB" "$QLIB")
eq "path rewrite touches exactly one line" 1 "$ndiff"

# ------------------------------------------------------------------ runner ---
# snip: read a script from stdin, run it, capture last stdout line into $out and
# the exit status into $rc.
out=; rc=0
snip() { cat > "$TMP/t.sh"; out=$("$TSH" "$TMP/t.sh" 2>"$TMP/err" | tail -1); rc=$?; }

# -------------------------------------------------------- pid state (procfs) ---
# z2k_pid_running exists because `kill -0` SUCCEEDS for a zombie: a daemon that
# exited but has not been reaped yet answers "alive", which is how an instantly
# failing start got reported as a successful one. The Z/X/x check IS that fix, and
# it can only be observed where /proc/<pid>/stat is readable - so, exactly as with
# the queue file above, only that one path is rewritten and the rewrite is verified
# to touch the lines it claims. Every case below uses a LIVE pid ($$ of the child
# shell), so `kill -0` always succeeds and the verdict can come from nowhere but
# the stat fixture: drop the Z check and the first three rows flip.
PLIB="$TMP/plib.sh"
nref=$(grep -cF '"/proc/$1/stat"' "$LIB")
eq "pid stat path referenced exactly twice in the helper" 2 "$nref"
sed 's#"/proc/\$1/stat"#"$Z2K_PROCPID/$1/stat"#g' "$LIB" > "$PLIB"
ndiff=$(awk 'NR==FNR{a[FNR]=$0;n=FNR;next}
             {if(a[FNR]!=$0)d++}
             END{if(FNR!=n)d=-1; print d+0}' "$LIB" "$PLIB")
eq "pid stat rewrite touches exactly two lines" 2 "$ndiff"

PROCPID="$TMP/procpid"; mkdir -p "$PROCPID"
# pid_case LABEL STAT-TAIL WANT-RC   (STAT-TAIL is everything after the pid field)
pid_case() {
    snip <<EOF
Z2K_PROCPID="$PROCPID"
. "$PLIB"
mkdir -p "\$Z2K_PROCPID/\$\$"
printf '%s $2\n' "\$\$" > "\$Z2K_PROCPID/\$\$/stat"
z2k_pid_running \$\$; echo "rc=\$?"
EOF
    eq "$1" "rc=$3" "$out"
}
pid_case "a zombie is NOT running (the whole point of the helper)" '(nfqws2) Z 1 0 0 0 -1 0' 1
pid_case "a dead X process is not running"                         '(nfqws2) X 1 0 0 0 -1 0' 1
pid_case "a dead x process is not running"                         '(nfqws2) x 1 0 0 0 -1 0' 1
pid_case "a sleeping process IS running"                           '(nfqws2) S 1 0 0 0 -1 0' 0
pid_case "a runnable process IS running"                           '(nfqws2) R 1 0 0 0 -1 0' 0
pid_case "a disk-sleep process IS running"                         '(nfqws2) D 1 0 0 0 -1 0' 0
# Linux writes the comm field in parens VERBATIM, so a name containing parens and
# spaces shifts every positional field. Splitting on whitespace would read "Z" out
# of the wrong column; the helper anchors on the LAST ')' instead.
pid_case "a name containing parens and spaces still parses (last paren wins)" \
         '(nf) qws (2)) Z 1 0 0 0 -1 0' 1
pid_case "the same awkward name is not misread as dead when alive" \
         '(nf) qws (2)) S 1 0 0 0 -1 0' 0

# No procfs at all: the helper must fall back to kill -0 rather than declare a
# live daemon dead. This is the branch every non-Linux host takes.
snip <<EOF
Z2K_PROCPID="$PROCPID/absent"
. "$PLIB"
z2k_pid_running \$\$; echo "rc=\$?"
EOF
eq "no procfs entry falls back to kill -0 (says running)" "rc=0" "$out"

# ...and the fallback must not run the other way: a pid that is really gone stays
# gone even if a stale entry claims it is sleeping. kill -0 is checked FIRST.
snip <<EOF
Z2K_PROCPID="$PROCPID"
. "$PLIB"
"$TSH" -c 'exit 0' & d=\$!
wait \$d 2>/dev/null
mkdir -p "\$Z2K_PROCPID/\$d"
printf '%s (nfqws2) S 1 0 0 0 -1 0\n' "\$d" > "\$Z2K_PROCPID/\$d/stat"
z2k_pid_running \$d; echo "rc=\$?"
EOF
eq "a reaped pid stays dead despite a stale S entry (kill -0 gates first)" "rc=1" "$out"

# Stub preamble. NB THE COUNTER NAMES: z2k_wait_gone declares `local pid max i n`
# and z2k_wait_queue_bound declares `local pid qnum max i n q rest`. Under sh's
# dynamic scoping a stub that incremented a variable called n/i/pid/max/q/rest
# would be writing the FUNCTION'S local, not ours - the count would be clobbered
# on every call and the test would read back garbage (or worse, quietly agree).
# Hence the Z2K_TEST_ prefix on every counter.
PRE='
Z2K_TEST_SLEEPS=0
Z2K_TEST_USLEEPS=0
Z2K_TEST_KILLS=0
Z2K_TEST_ALIVE=999999
sleep()  { Z2K_TEST_SLEEPS=$((Z2K_TEST_SLEEPS+1)); printf %s "$1" > "$TMP/sleep_s"; return 0; }
# Argument recorded for the same reason as usleep: a budget computed from a
# literal 1000 in this file cannot notice the code changing to `sleep 10`.
usleep() { Z2K_TEST_USLEEPS=$((Z2K_TEST_USLEEPS+1)); printf %s "$1" > "$TMP/usleep_us"; return 0; }
# ^ the ARGUMENT is recorded, not just the call count. Deriving the deadline
# from it is what makes it falsifiable: while the budget assertion multiplied
# polls by a literal 50 living in this file, changing the code to
# `usleep 5000000` stretched the 3 s deadline to 300 s and the suite stayed
# green. Written to a file because snip() runs each case in a child shell.
kill()   { Z2K_TEST_KILLS=$((Z2K_TEST_KILLS+1)); [ "$Z2K_TEST_KILLS" -le "$Z2K_TEST_ALIVE" ]; }
'

# real usleep(1) does not exist on macOS and BusyBox `sleep` rejects fractions,
# so the wall-clock test of the FRACTIONAL branch only runs where a fractional
# sleep genuinely exists. Detected, never faked.
FRAC_HOST=0
if sleep 0.05 2>/dev/null; then FRAC_HOST=1; fi
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/empty"
# NB: must NOT delegate to `sleep` — $BIN also holds a counting `sleep` mock, so
# `exec sleep ...` made this stub inherit the mock's exit status. Harmless while
# z2k_fracsleep_avail only did `command -v`, fatal once it probes by EXECUTING.
printf '#!/bin/sh\nexit 0\n' > "$BIN/usleep"; chmod +x "$BIN/usleep"

# ==============================================================================
# 1. z2k_fracsleep_avail - probe once, cache, always leave a definite answer
# ==============================================================================

snip <<EOF
. "$LIB"
PATH="$BIN"
z2k_fracsleep_avail; a=\$?
echo "\$a \$Z2K_FRACSLEEP"
EOF
eq "fracsleep: usleep on PATH -> true, cached as 1" "0 1" "$out"

snip <<EOF
. "$LIB"
PATH="$TMP/empty"
z2k_fracsleep_avail; a=\$?
echo "\$a \$Z2K_FRACSLEEP"
EOF
eq "fracsleep: usleep absent -> false, cached as 0" "1 0" "$out"

# Caching: probe once. Second call must NOT re-probe, so removing usleep from
# PATH between calls must not change the answer.
snip <<EOF
. "$LIB"
PATH="$BIN"
z2k_fracsleep_avail; a=\$?
PATH="$TMP/empty"
z2k_fracsleep_avail; b=\$?
echo "\$a \$b \$Z2K_FRACSLEEP"
EOF
eq "fracsleep: probes once and caches (PATH change after first call is ignored)" "0 0 1" "$out"

# ...and the negative cache sticks too, which is what lets callers/tests pin the
# branch by presetting the variable.
snip <<EOF
. "$LIB"
Z2K_FRACSLEEP=0
PATH="$BIN"
z2k_fracsleep_avail; a=\$?
echo "\$a \$Z2K_FRACSLEEP"
EOF
eq "fracsleep: preset 0 is honoured (no re-probe even with usleep present)" "1 0" "$out"

# Never leaves the cache unset: callers branch on it, an empty value would make
# every call re-probe (and, under set -u, abort the init script).
for pathspec in "$BIN" "$TMP/empty"; do
    label=$([ "$pathspec" = "$BIN" ] && echo "usleep present" || echo "usleep absent")
    snip <<EOF
. "$LIB"
unset Z2K_FRACSLEEP
PATH="$pathspec"
z2k_fracsleep_avail
echo "[\${Z2K_FRACSLEEP-UNSET}]"
EOF
    case "$out" in
        "[0]"|"[1]") ok "fracsleep: Z2K_FRACSLEEP is never left unset ($label)" ;;
        *) no "fracsleep: Z2K_FRACSLEEP is never left unset ($label)" "[0] or [1]" "$out" ;;
    esac
done

# ==============================================================================
# 2. z2k_wait_gone - returns as soon as the pid is gone, bounded in TIME
# ==============================================================================

# --- 2a. already gone: zero sleeps of either kind, in BOTH branches -----------
for frac in 1 0; do
    snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=$frac
Z2K_TEST_ALIVE=0
z2k_wait_gone 12345 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_SLEEPS \$Z2K_TEST_KILLS"
EOF
    eq "wait_gone[frac=$frac]: pid already gone -> rc 0, zero sleeps, one probe" \
       "0 0 0 1" "$out"
done

# --- 2b. dies mid-wait: returns on the poll that sees it gone ----------------
snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=1
Z2K_TEST_ALIVE=5
z2k_wait_gone 12345 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_SLEEPS"
EOF
eq "wait_gone[frac=1]: pid dies at poll 6 -> rc 0 after exactly 5 waits (not 60)" \
   "0 5 0" "$out"

snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=0
Z2K_TEST_ALIVE=2
z2k_wait_gone 12345 5; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_SLEEPS"
EOF
eq "wait_gone[frac=0]: pid dies at poll 3 -> rc 0 after exactly 2 waits (not 5)" \
   "0 0 2" "$out"

# --- 2c. never dies: rc 1, and THE DEADLINE HOLDS IN WALL-CLOCK -------------
# This is the assertion that catches the iteration-count-capped bug: keeping
# n = max*20 in the no-usleep branch yields 60 polls x 1 s = 60 s for a 3 s
# deadline. Both branches must come out to the same millisecond budget.
frac_polls=; nonfrac_polls=
snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=1
z2k_wait_gone 12345 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_SLEEPS"
EOF
eq "wait_gone[frac=1]: wedged pid -> rc 1 after 60 x 50 ms polls" "1 60 0" "$out"
frac_polls=$(printf '%s' "$out" | cut -d' ' -f2)
# Field 4 is the microsecond argument the CODE handed usleep. Deriving the
# budget from it is what makes the deadline falsifiable.
frac_us=$(cat "$TMP/usleep_us" 2>/dev/null)

snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=0
z2k_wait_gone 12345 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_SLEEPS"
EOF
eq "wait_gone[frac=0]: wedged pid -> rc 1 after 3 x 1 s polls (NOT 60)" "1 0 3" "$out"
nonfrac_polls=$(printf '%s' "$out" | cut -d' ' -f3)
nonfrac_s=$(cat "$TMP/sleep_s" 2>/dev/null)

case "$frac_polls$nonfrac_polls$frac_us$nonfrac_s" in
    *[!0-9]*|"") no "wait_gone: both branches spend the same 3000 ms" "3000/3000" "unparsable" ;;
    *)
        # The per-poll interval is READ BACK from the code (the stub records the
        # argument z2k_wait_gone actually passed), not hardcoded here. With a
        # test-side 50 the whole assertion was blind: changing the code to
        # `usleep 5000000` turned the 3 s deadline into 300 s and stayed green.
        eq "wait_gone: fractional branch budget = polls x REAL usleep arg = 3000 ms" \
           3000000 "$((frac_polls * frac_us))"
        eq "wait_gone: non-fractional branch budget = polls x REAL sleep arg = 3 s" \
           3 "$((nonfrac_polls * nonfrac_s))"
        ;;
esac

# scales with max, still equal budgets (5 s -> 100 x 50 ms == 5 x 1 s)
snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=1
z2k_wait_gone 12345 5
echo "\$Z2K_TEST_USLEEPS"
EOF
eq "wait_gone[frac=1]: max=5 -> 100 polls (5000 ms)" 100 "$out"
snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=0
z2k_wait_gone 12345 5
echo "\$Z2K_TEST_SLEEPS"
EOF
eq "wait_gone[frac=0]: max=5 -> 5 polls (5000 ms)" 5 "$out"

# --- 2d. edge maxima --------------------------------------------------------
# max=0 must not sleep at all, and must still answer correctly - the post-loop
# kill -0 is what makes max=0 a pure liveness probe rather than an automatic 1.
for frac in 1 0; do
    snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=$frac
z2k_wait_gone 12345 0; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_SLEEPS"
EOF
    eq "wait_gone[frac=$frac]: max=0 + alive -> rc 1, zero sleeps" "1 0 0" "$out"

    snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=$frac
Z2K_TEST_ALIVE=0
z2k_wait_gone 12345 0; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_SLEEPS"
EOF
    eq "wait_gone[frac=$frac]: max=0 + gone -> rc 0, zero sleeps" "0 0 0" "$out"
done

snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=1
z2k_wait_gone 12345 1; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "wait_gone[frac=1]: max=1 -> rc 1 after 20 polls (1000 ms)" "1 20" "$out"

snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=0
z2k_wait_gone 12345 1; r=\$?
echo "\$r \$Z2K_TEST_SLEEPS"
EOF
eq "wait_gone[frac=0]: max=1 -> rc 1 after 1 poll (1000 ms)" "1 1" "$out"

# default max is 3 s - the SIGKILL deadline the caller relies on
snip <<EOF
. "$LIB"
$PRE
Z2K_FRACSLEEP=0
z2k_wait_gone 12345; r=\$?
echo "\$r \$Z2K_TEST_SLEEPS"
EOF
eq "wait_gone: omitted max defaults to 3 s" "1 3" "$out"

# --- 2e. REAL processes, REAL clock (no stubs) ------------------------------
# Double-fork so the child is orphaned and reaped by init: a direct background
# child would linger as a zombie, and kill -0 succeeds on a zombie, which would
# make this pass for the wrong reason.
snip <<EOF
. "$LIB"
Z2K_FRACSLEEP=0
p=\$(sh -c 'sleep 1 >/dev/null 2>&1 & echo \$!')
t0=\$(date +%s)
z2k_wait_gone "\$p" 8; r=\$?
t1=\$(date +%s)
echo "\$r \$((t1-t0))"
EOF
set -- $out
r=$1; el=$2
if [ "$r" = 0 ] && [ "${el:-99}" -ge 1 ] && [ "$el" -le 3 ]; then
    ok "wait_gone: real pid, real clock -> returns on death (~1 s), not at the 8 s deadline (${el}s)"
else
    no "wait_gone: real pid, real clock -> returns on death, not at deadline" "rc0 1-3s" "rc$r ${el}s"
fi

snip <<EOF
. "$LIB"
Z2K_FRACSLEEP=0
t0=\$(date +%s)
z2k_wait_gone \$\$ 2; r=\$?
t1=\$(date +%s)
echo "\$r \$((t1-t0))"
EOF
set -- $out
r=$1; el=$2
if [ "$r" = 1 ] && [ "${el:-99}" -ge 1 ] && [ "$el" -le 4 ]; then
    ok "wait_gone[frac=0]: immortal pid, real clock -> rc 1 at ~2 s, not 40 s (${el}s)"
else
    no "wait_gone[frac=0]: immortal pid, real clock -> rc 1 at ~2 s" "rc1 1-4s" "rc$r ${el}s"
fi

if [ "$FRAC_HOST" = 1 ]; then
    # 20 x 50 ms via a real fractional-sleep shim: ~1 s, definitely not 20 s.
    snip <<EOF
. "$LIB"
PATH="$BIN:\$PATH"
Z2K_FRACSLEEP=1
t0=\$(date +%s)
z2k_wait_gone \$\$ 1; r=\$?
t1=\$(date +%s)
echo "\$r \$((t1-t0))"
EOF
    set -- $out
    r=$1; el=$2
    if [ "$r" = 1 ] && [ "${el:-99}" -le 5 ]; then
        ok "wait_gone[frac=1]: immortal pid, real usleep -> rc 1 within ~1 s (${el}s)"
    else
        no "wait_gone[frac=1]: immortal pid, real usleep -> rc 1 within ~1 s" "rc1 <=5s" "rc$r ${el}s"
    fi
else
    ok "wait_gone[frac=1]: real-clock check skipped (no fractional sleep on this host) - router-only"
fi

# ==============================================================================
# 3. z2k_wait_queue_bound - positive readiness, never a hard error on timeout
# ==============================================================================
# Real /proc/net/netfilter/nfnetlink_queue line, captured from the live Keenetic
# (aarch64, 4.9-ndm-5) on 2026-07-25:
#     "  200  23879     0 2 65531     0     0       64  1"
# Note the LEADING SPACES and the padded columns: a `grep "^$qnum "` would miss
# every one of them. `read -r q owner rest` is what makes it work, so the fixture
# is byte-faithful to the router.
#
# COLUMN 2 IS THE OWNING PID and z2k_wait_queue_bound matches on it, so every
# fixture must name the pid the test hands the function (12345 here) - otherwise
# nothing matches and every assertion below degrades to "timed out".
QF="$TMP/qfile"
mk_qfile() { : > "$QF"; for n in "$@"; do printf '%5d %6d %5d %1d %5d %5d %5d %10d %2d\n' "$n" "${QOWNER:-12345}" 0 2 65531 0 0 64 1 >> "$QF"; done; }

QPRE='
Z2K_TEST_SLEEPS=0
Z2K_TEST_USLEEPS=0
Z2K_TEST_KILLS=0
Z2K_TEST_ALIVE=999999
sleep()  { Z2K_TEST_SLEEPS=$((Z2K_TEST_SLEEPS+1)); return 0; }
usleep() { Z2K_TEST_USLEEPS=$((Z2K_TEST_USLEEPS+1)); Z2K_TEST_USLEEP_US=$1; return 0; }   # arg recorded: the deadline must be derived from the CODE, not from a constant here
kill()   { Z2K_TEST_KILLS=$((Z2K_TEST_KILLS+1)); [ "$Z2K_TEST_KILLS" -le "$Z2K_TEST_ALIVE" ]; }
'

# --- 3a. queue already bound: return immediately, zero waits ----------------
mk_qfile 200
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_KILLS"
EOF
eq "queue_bound: qnum already bound -> rc 0 immediately, zero waits" "0 0 1" "$out"

# The match must escape the inner `while read` loop AND the function. If the
# read loop were fed by a pipe it would run in a subshell and `return 0` would
# only leave the subshell - the outer loop would spin to the deadline.
mk_qfile 9 77 4242 200
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "queue_bound: match on the LAST line still returns from the function (no subshell)" "0 0" "$out"

# --- 3b. appears mid-wait ---------------------------------------------------
mk_qfile 4242
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
usleep() {
    Z2K_TEST_USLEEPS=\$((Z2K_TEST_USLEEPS+1))
    [ "\$Z2K_TEST_USLEEPS" -eq 3 ] && printf '%5d %6d %5d %1d %5d %5d %5d %10d %2d\n' 200 12345 0 2 0 0 0 64 1 >> "$QF"
    return 0
}
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "queue_bound: qnum appears at poll 4 -> rc 0 after 3 waits (not 60)" "0 3" "$out"

# --- 3c. daemon died during startup -> rc 1 (the ONLY error path) -----------
mk_qfile 4242
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
Z2K_TEST_ALIVE=2
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "queue_bound: pid dies while waiting -> rc 1 (startup crash is reported)" "1 2" "$out"

# --- 3d. timeout is NOT an error -------------------------------------------
# A cold-USB nfqws2 can still be loading 80k hostlines; run_daemon re-checks
# liveness right after. Returning 1 here would make run_daemon's caller treat a
# healthy slow start as a failure.
mk_qfile 4242
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS \$Z2K_TEST_KILLS"
EOF
eq "queue_bound: timeout with pid alive -> rc 0 (slow start is not a failure)" "0 60 60" "$out"

# --- 3e. exact match, not substring ----------------------------------------
# Queue 200 must not be satisfied by a line for 2000, 20, 1200 or 12000. This is
# not academic: a caller-supplied qnum of 2 would otherwise match everything.
mk_qfile 2000 20 1200 12000
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "queue_bound: 200 does NOT match lines for 2000/20/1200/12000 (burns full deadline)" \
   "0 60" "$out"

# positive controls on the same fixture: the real numbers DO match, immediately
for want in 2000 20 12000; do
    snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 $want 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
    eq "queue_bound: exact qnum $want matches on the same fixture (control)" "0 0" "$out"
done

# leading-whitespace tolerance, stated on its own: this is the procfs format.
printf '  200  12345     0 2 65531     0     0       64  1\n' > "$QF"
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "queue_bound: matches the live router line verbatim, leading spaces and all" "0 0" "$out"

# --- 3f. missing / empty queue file: never hang, never error ---------------
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$TMP/definitely-absent"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "queue_bound: queue file absent -> rc 0 after the full deadline, no hang" "0 60" "$out"
if [ -s "$TMP/err" ]; then
    no "queue_bound: absent queue file produces no stderr noise" "" "$(head -1 "$TMP/err")"
else
    ok "queue_bound: absent queue file produces no stderr noise"
fi

: > "$QF"
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
eq "queue_bound: empty queue file -> rc 0 after the full deadline" "0 60" "$out"

# The UNMODIFIED helper against the real hardcoded path. On a box with no
# nfnetlink_queue procfs entry this proves the shipped code tolerates its
# absence; where the file exists the answer depends on live state, so it is a
# router-only check instead of a fake local one.
if [ -e "$QPROC" ]; then
    ok "queue_bound: real $QPROC present -> live-state check deferred to the router checklist"
else
    snip <<EOF
. "$LIB"
$QPRE
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_USLEEPS"
EOF
    eq "queue_bound: UNPATCHED helper, real /proc path absent -> rc 0, no hang" "0 60" "$out"
fi

# --- 3g. the deadline, both branches ---------------------------------------
mk_qfile 4242
qf_polls=; qn_polls=
snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=1
z2k_wait_queue_bound 12345 200 3
echo "\$Z2K_TEST_USLEEPS"
EOF
qf_polls=$out
# Same as wait_gone: read the microsecond argument back out of the CODE so the
# budget below is falsifiable rather than a restatement of a literal in this file.
qf_us=$(cat "$TMP/usleep_us" 2>/dev/null)
eq "queue_bound[frac=1]: 3 s deadline = 60 polls" 60 "$qf_polls"

snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=0
z2k_wait_queue_bound 12345 200 3
echo "\$Z2K_TEST_SLEEPS"
EOF
qn_polls=$out
qn_s=$(cat "$TMP/sleep_s" 2>/dev/null)
eq "queue_bound[frac=0]: 3 s deadline = 3 polls (NOT 60 - the 60 s stall bug)" 3 "$qn_polls"

case "$qf_polls$qn_polls$qf_us$qn_s" in
    *[!0-9]*|"") no "queue_bound: both branches spend the same 3000 ms" "3000/3000" "unparsable" ;;
    *)
        eq "queue_bound: fractional branch budget = polls x REAL usleep arg = 3000 ms" 3000000 "$((qf_polls * qf_us))"
        eq "queue_bound: non-fractional branch budget = polls x REAL sleep arg = 3 s" 3 "$((qn_polls * qn_s))"
        ;;
esac

snip <<EOF
. "$QLIB"
$QPRE
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=0
z2k_wait_queue_bound 12345 200
echo "\$Z2K_TEST_SLEEPS"
EOF
eq "queue_bound: omitted max defaults to 3 s" 3 "$out"

# --- 3h. non-fractional branch must still honour its deadline if `sleep`
#         itself fails (busy box, EINTR): the loop is iteration-driven, so a
#         failing sleep can only make it finish EARLIER, never later.
mk_qfile 4242
snip <<EOF
. "$QLIB"
$QPRE
sleep() { Z2K_TEST_SLEEPS=\$((Z2K_TEST_SLEEPS+1)); return 1; }
Z2K_QFILE="$QF"
Z2K_FRACSLEEP=0
z2k_wait_queue_bound 12345 200 3; r=\$?
echo "\$r \$Z2K_TEST_SLEEPS"
EOF
eq "queue_bound[frac=0]: failing sleep does not extend the poll count" "0 3" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

# ==============================================================================
# ROUTER-ONLY CHECKLIST (cannot be asserted on a dev box)
# ==============================================================================
#  R1. BusyBox ash honours `local pid max i n` in these helpers.
#      Verified 2026-07-25 on Keenetic-0235 (BusyBox v1.37.0, 4.9-ndm-5 aarch64):
#        ash -c 'f(){ local a b; a=1; echo ok$a; }; f'  ->  ok1
#  R2. `sleep 0.1` is rejected ("sleep: invalid number '0.1'") and
#      `usleep 50000` returns 0 - i.e. the fractional branch is the live one.
#      Verified on the same box.
#  R3. /proc/net/netfilter/nfnetlink_queue exists and its first column is the
#      queue number, space-padded. Verified live:
#        "  200  23879     0 2 65531     0     0       64  1"
#      The fixture above reproduces that layout byte-for-byte.
#  R4. End-to-end: `S99zapret2 restart` completes in ~1.7 s and
#      /proc/net/netfilter/nfnetlink_queue lists queue $QNUM afterwards.
# ==============================================================================

[ "$FAIL" -eq 0 ]
