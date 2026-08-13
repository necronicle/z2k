#!/bin/sh
# tests/test_restart_portability.sh
# ---------------------------------------------------------------------------
# The restart-latency fix (25.1 s -> 1.73 s) is shell-construct-heavy, and the
# three shells it must survive are NOT the same shell:
#
#   * BusyBox ash 1.37.0   - the router. `#!/bin/sh` on Keenetic resolves to an
#                            "NDM Shell Wrapper" which execs /opt/bin/sh
#                            (busybox) when /opt is mounted, /bin/ash otherwise.
#   * dash                 - Ubuntu CI's /bin/sh, and `sh tests/run_all.sh`.
#   * bash                 - what a developer's `sh` is on macOS.
#
# test_restart_latency.sh already guards the LATENCY (contains() is not
# quadratic, no blocking flat sleeps, the 3 s deadline stays 3 s). This file
# guards the opposite failure: the fix is correct in one shell and silently
# wrong in another. Every check below runs the REAL functions, extracted from
# the shipped script, in EVERY sh-family interpreter present, and requires
# byte-identical output.
#
# Constructs under audit (all introduced or relied on by the fix):
#   1. `local a="$1" b="${2:-3}" c=0 d`  - multiple declarators + assignment.
#      Not POSIX; ash/dash/bash all have it, but they disagree on whether a
#      value-less declarator is UNSET (ash, dash) or SET-EMPTY (bash), and
#      historically on whether `local x=$y` field-splits.
#   2. `case "$1" in *"$2"*)`            - quoted needle inside a case pattern.
#   3. `command -v usleep`               - capability probe + its cache.
#   4. `while read -r q rest; ... done 2>/dev/null < file` with `return` from
#      the INNER loop, and the redirect ORDER (see note 4 below).
#   5. `( sleep 1; ... ) >/dev/null 2>&1 &` - fire-and-forget backgrounding.
#   6. `$(( ))`, `${2:-3}`, `[ ... ]`, `case "$DAEMONBASE" in nfqws2)`.
#
# zsh is deliberately NOT in the main matrix: S99zapret2 is `#!/bin/sh` and is
# never executed by zsh. It IS checked for contains() alone, because a macOS
# developer may `. common/base.sh` from an interactive zsh. zsh's divergence on
# construct 4 (it reports a failed input redirect regardless of redirect order)
# is documented in the report, not asserted here.
#
# POSIX sh. Exits non-zero on any failure.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-${Z2K_INIT_UNDER_TEST:-$HERE/files/S99zapret2.new}}"
BASE="$HERE/../zapret2-z2k-fork/common/base.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rport.XXXXXX") || exit 1
kill_pidfiles() {
    # One pid per file. Read them explicitly rather than an unquoted
    # `kill $(cat ...)`: the word splitting was intended, but shellcheck cannot
    # tell that from a typo and CI runs with --severity=warning.
    for _pf in "$TMP"/pids/*; do
        [ -f "$_pf" ] || continue
        read -r _p < "$_pf" 2>/dev/null || continue
        [ -n "$_p" ] && kill "$_p" 2>/dev/null
    done
    return 0
}
trap 'kill_pidfiles; rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$INIT" ] || { printf '[FAIL] %s missing\n' "$INIT"; exit 1; }

# ---------------------------------------------------------------- extraction ---
# Pull a function body out of the shipped script without executing the script
# (S99zapret2.new sources /opt/zapret2/common/* and would die instantly here).
# Comments are KEPT: these bodies are sourced, not grepped, and the comments
# carry the rationale a reader needs when a case goes red.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1; print; next }
        inf && /^}/ { print; exit }
        inf { print }
    ' "$2"
}

# ------------------------------------------------------------ shell discovery ---
# Dedupe by inode so /bin/sh -> dash (Ubuntu) is not counted as a second
# interpreter for free. NB /bin/sh on macOS is bash-in-posix-mode and on
# Keenetic is the NDM wrapper: both are genuinely distinct personalities and
# both keep their own inode, so they stay in the list.
SHELLS=""; SHELL_N=0; SEEN_INO=" "
for cand in /bin/dash /bin/bash /bin/sh /bin/ash /opt/bin/sh /usr/bin/dash /usr/local/bin/dash; do
    [ -x "$cand" ] || continue
    ino=$(ls -i "$cand" 2>/dev/null | awk '{print $1}')
    [ -n "$ino" ] || ino="$cand"
    case "$SEEN_INO" in *" $ino "*) continue ;; esac
    SEEN_INO="$SEEN_INO$ino "
    SHELLS="$SHELLS $cand"; SHELL_N=$((SHELL_N+1))
done
printf '# interpreters under test (%d):%s\n' "$SHELL_N" "$SHELLS"
# A one-shell run would make every "identical in every shell" claim vacuous.
if [ "$SHELL_N" -ge 2 ]; then
    ok "matrix has >=2 distinct sh interpreters ($SHELL_N)"
else
    no "matrix has >=2 distinct sh interpreters" ">=2" "$SHELL_N"
fi

# A label that stays UNIQUE per interpreter. basename() is not enough: on the
# router /bin/sh and /opt/bin/sh are two different entry points that both
# basename to "sh", which silently collided two rows (and two scratch files)
# into one on the first router run.
shlabel() { printf '%s' "$1" | sed 's#^/##; s#/#-#g'; }

# Run $2 under every interpreter; every one must print exactly $3 on stdout.
# stderr is folded in ON PURPOSE for most cases - a construct that "works" but
# spews to stderr is not portable, it is just quiet on one box.
matrix() { # $1 label  $2 script  $3 expected (stdout+stderr)
    _lbl="$1"; _scr="$2"; _exp="$3"
    for _sh in $SHELLS; do
        _out=$("$_sh" "$_scr" 2>&1)
        if [ "$_out" = "$_exp" ]; then
            ok "$_lbl [$(shlabel "$_sh")]"
        else
            no "$_lbl [$(shlabel "$_sh")]" "$(printf '%s' "$_exp" | tr '\n' '/')" \
               "$(printf '%s' "$_out" | tr '\n' '/')"
        fi
    done
}

# ===========================================================================
# 0. the shipped files must PARSE in every interpreter
# ===========================================================================
# Cheapest possible portability net, and the one that catches the whole class
# of "works on my bash" bashisms before any behaviour is even reached. bash
# accepts things dash and BusyBox ash reject outright (a stray backtick pair,
# [[ ]], arrays, `function f()`), and S99zapret2.new is `#!/bin/sh` on a box
# where sh IS BusyBox ash. Interpreters whose -n is not a syntax-check (the
# Keenetic /bin/sh NDM wrapper rejects the option) are skipped by probe.
for sh_ in $SHELLS; do
    "$sh_" -n /dev/null >/dev/null 2>&1 || {
        printf '# %s: no usable -n, syntax gate skipped\n' "$sh_"; continue; }
    for f in "$INIT" "$BASE"; do
        [ -f "$f" ] || continue
        if err=$("$sh_" -n "$f" 2>&1) && [ -z "$err" ]; then
            ok "$(basename "$f") parses clean [$(shlabel "$sh_")]"
        else
            no "$(basename "$f") parses clean [$(shlabel "$sh_")]" "no output, rc 0" "$err"
        fi
    done
done

# ===========================================================================
# 1. case "$1" in *"$2"*  - the quoted needle must be LITERAL, in every shell
# ===========================================================================
# The old form was `[ "${1#*$2}" != "$1" ]`, where $2 is unquoted inside a
# parameter expansion pattern and is therefore a GLOB. nfqws2 option strings
# carry paths and blob names; a needle containing [ or * matched spuriously.
# Confirmed on the router: contains_old abc '[a-z]' -> TRUE.
# This is the only assertion here that overlaps test_restart_latency, and the
# overlap is the point: that file proves it once, this one proves it per shell.
for src in "$INIT" "$BASE"; do
    lbl=$(basename "$src")
    [ -f "$src" ] || { printf '# %s absent (fork not checked out) - skipped\n' "$lbl"; continue; }
    extract_fn contains "$src" > "$TMP/contains_$lbl.sh"
    [ -s "$TMP/contains_$lbl.sh" ] || { no "$lbl: contains() extractable" "a body" "empty"; continue; }
    # Cases 7/10: an empty needle is FALSE by CONTRACT, not by accident. The
    # guard in contains() keeps exact parity with the old prefix-strip form
    # (which reported not-found for ""), where a bare case-glob would say found.
    # Pinned per shell because a shell mis-handling [ -n "" ] flips it silently.
    # NB these heredocs are UNQUOTED (they interpolate $TMP), so their bodies
    # must stay free of backticks and $( ) - a stray pair here parses as a
    # command substitution and takes the rest of the file with it. dash and
    # BusyBox ash reject it; bash does not, so `dash -n` is the gate.
    cat > "$TMP/p1_$lbl.sh" <<EOF
. "$TMP/contains_$lbl.sh"
contains abc '[a-z]'        && echo 1BAD || echo 1ok
contains abc 'a*c'          && echo 2BAD || echo 2ok
contains 'a[a-z]c' '[a-z]'  && echo 3ok  || echo 3BAD
contains xy '?'             && echo 4BAD || echo 4ok
contains 'x?y' '?'          && echo 5ok  || echo 5BAD
contains 'a*c' 'a*c'        && echo 6ok  || echo 6BAD
contains abc ''             && echo 7BAD || echo 7ok
contains '' ''              && echo 10BAD || echo 10ok
contains '' a               && echo 8BAD || echo 8ok
contains 'x--dpi-desync=fake y' '--dpi-desync=fake' && echo 9ok || echo 9BAD
EOF
    matrix "$lbl: contains() needle is literal, not a glob" "$TMP/p1_$lbl.sh" \
"1ok
2ok
3ok
4ok
5ok
6ok
7ok
10ok
8ok
9ok"
    # zsh is not in the matrix but a dev may source base.sh interactively.
    if [ -x /bin/zsh ]; then
        out=$(/bin/zsh "$TMP/p1_$lbl.sh" 2>&1 | tr '\n' ' ')
        case "$out" in
            *BAD*) no "$lbl: contains() literal under zsh (interactive dev shell)" "no BAD" "$out" ;;
            *)     ok "$lbl: contains() literal under zsh (interactive dev shell)" ;;
        esac
    fi
done

# ===========================================================================
# 2. local: multi-declarator + assignment + ${:-} + $(( )) + no leakage
# ===========================================================================
# `local pid="$1" max="${2:-3}" i=0 n` is not POSIX. Three things must hold
# identically everywhere, and only the third is mutation-provable - the first
# two are compatibility PROBES (no source change can make them fail; a shell
# without `local` can). They are still worth running: they are exactly what
# breaks when the script is moved to a new box.
#   a) all four declarators take effect, `${2:-3}` defaults, `$(( ))` computes;
#   b) the value-less declarator (`n`) is never READ before it is assigned -
#      ash and dash leave it UNSET where bash leaves it SET-EMPTY, so a read
#      would diverge under `set -u`;
#   c) the locals do NOT leak into the caller. Drop the `local` keyword and
#      z2k_wait_gone's `i`/`n` clobber the caller's - THAT is mutation-provable
#      and it is also the portability question (a shell lacking `local` leaks).
{ extract_fn z2k_pid_running "$INIT"; echo; extract_fn z2k_fracsleep_avail "$INIT"; echo; extract_fn z2k_wait_gone "$INIT"; } > "$TMP/wg.sh"
[ -s "$TMP/wg.sh" ] || no "z2k_wait_gone extractable" "a body" "empty"

cat > "$TMP/p2.sh" <<EOF
Z2K_FRACSLEEP=0
. "$TMP/wg.sh"
# Counter deliberately NOT named i/n/pid/max: those are the function's locals.
P=0
sleep()  { P=\$((P+1)); }
usleep() { P=\$((P+1)); }

# (a) explicit max, whole-second path: 3 s deadline == 3 polls.
P=0; z2k_wait_gone \$\$ 3; echo "explicit rc=\$? polls=\$P"
# (a) \${2:-3} default must be the same 3.
P=0; z2k_wait_gone \$\$;   echo "default  rc=\$? polls=\$P"
# (a) and it must scale, proving max is a real declarator not a literal.
P=0; z2k_wait_gone \$\$ 5; echo "max5     rc=\$? polls=\$P"
# (a) \$(( max * 20 )) on the fractional path.
Z2K_FRACSLEEP=1
P=0; z2k_wait_gone \$\$ 3; echo "frac     rc=\$? polls=\$P"
Z2K_FRACSLEEP=0
# already-dead pid: zero polls, success.
P=0; z2k_wait_gone 2147483646 3; echo "dead     rc=\$? polls=\$P"

# (b) no read of an unassigned declarator on either branch.
set -u
P=0; Z2K_FRACSLEEP=0; z2k_wait_gone \$\$ 2 >/dev/null 2>&1; echo "setu-whole rc=\$?"
P=0; Z2K_FRACSLEEP=1; z2k_wait_gone \$\$ 1 >/dev/null 2>&1; echo "setu-frac  rc=\$?"
set +u
Z2K_FRACSLEEP=0

# (c) caller's variables survive the call.
i=OUTER_I; n=OUTER_N; pid=OUTER_PID; max=OUTER_MAX
P=0; z2k_wait_gone \$\$ 1 >/dev/null 2>&1
echo "leak i=\$i n=\$n pid=\$pid max=\$max"
EOF
matrix "local: multi-declarator, \${:-} default, \$(( )), no leakage" "$TMP/p2.sh" \
"explicit rc=1 polls=3
default  rc=1 polls=3
max5     rc=1 polls=5
frac     rc=1 polls=60
dead     rc=0 polls=0
setu-whole rc=1
setu-frac  rc=1
leak i=OUTER_I n=OUTER_N pid=OUTER_PID max=OUTER_MAX"

# ===========================================================================
# 3. command -v usleep, and the cache that must NOT be a subshell
# ===========================================================================
# `[ -n "$Z2K_FRACSLEEP" ] || { ...; }` is a BRACE group on purpose. Written as
# `( ... )` the assignment happens in a subshell, the cache never sticks, and
# every poll iteration re-forks `command -v`. Prove the cache by deleting the
# probe target between the two calls.
# PATH is pinned to a directory that holds only the probe target, so a real
# /usr/bin/usleep on the CI host cannot make the negative case pass by accident.
# The cache is then proved by FLIPPING PATH between calls - no external command
# is needed, which matters because these PATHs contain no rm/ls at all.
mkdir -p "$TMP/withu" "$TMP/nou"
printf '#!/bin/sh\nexit 0\n' > "$TMP/withu/usleep"; chmod +x "$TMP/withu/usleep"
extract_fn z2k_fracsleep_avail "$INIT" > "$TMP/fs.sh"
cat > "$TMP/p3.sh" <<EOF
. "$TMP/fs.sh"
PATH="$TMP/withu"; export PATH
Z2K_FRACSLEEP=
z2k_fracsleep_avail; echo "have-usleep rc=\$? cache=\$Z2K_FRACSLEEP"
PATH="$TMP/nou"; export PATH             # probe target now unreachable...
z2k_fracsleep_avail; echo "cached1     rc=\$? cache=\$Z2K_FRACSLEEP"
Z2K_FRACSLEEP=                           # ...until the cache is cleared
z2k_fracsleep_avail; echo "no-usleep   rc=\$? cache=\$Z2K_FRACSLEEP"
PATH="$TMP/withu"; export PATH           # and it sticks the other way too
z2k_fracsleep_avail; echo "cached0     rc=\$? cache=\$Z2K_FRACSLEEP"
EOF
matrix "command -v probe + brace-group cache" "$TMP/p3.sh" \
"have-usleep rc=0 cache=1
cached1     rc=0 cache=1
no-usleep   rc=1 cache=0
cached0     rc=1 cache=0"

# ===========================================================================
# 4. while read < file: `return` must exit the FUNCTION, and a missing file
#    must stay silent
# ===========================================================================
# 4a. `return` from the INNER loop has to unwind the whole function. If the
#     loop were ever fed by a pipeline (`cat f | while read`), the return would
#     exit only the subshell and the outer poll would keep spinning to the
#     deadline - which is exactly what "polls=0 on a hit" distinguishes.
# 4b. Redirect ORDER. Redirections apply left to right, so the shipped-and-
#     fixed `done 2>/dev/null < FILE` sends the open failure to /dev/null,
#     while `done < FILE 2>/dev/null` prints "can't open ..." on the inherited
#     fd 2 - 60 lines per daemon start on a box with no nfnetlink_queue procfs.
#     Verified on BusyBox ash 1.37.0, dash and bash.
# The hardcoded /proc path is rewritten to a fixture; the redirect ORDER and
# the loop structure are preserved verbatim, which is what is under test.
extract_fn z2k_wait_queue_bound "$INIT" \
  | sed 's#/proc/net/netfilter/nfnetlink_queue#"$Z2K_TEST_QFILE"#' > "$TMP/wqb_body.sh"
grep -q 'Z2K_TEST_QFILE' "$TMP/wqb_body.sh" \
  && ok "z2k_wait_queue_bound: proc path rewritten for fixture" \
  || no "z2k_wait_queue_bound: proc path rewritten for fixture" "1 substitution" "0"
{ extract_fn z2k_pid_running "$INIT"; echo
  extract_fn z2k_fracsleep_avail "$INIT"; echo
  cat "$TMP/wqb_body.sh"; } > "$TMP/wqb.sh"

# Fixture shaped like the real file: leading whitespace, queue num first field.
# Fixture is written INSIDE p4.sh below: column 2 is the owning pid and
# z2k_wait_queue_bound matches on it, so it must be that script's own $$,
# not this one's.

cat > "$TMP/p4.sh" <<EOF
Z2K_FRACSLEEP=0
Z2K_TEST_QFILE="$TMP/nfq"
. "$TMP/wqb.sh"
P=0
sleep()  { P=\$((P+1)); }
usleep() { P=\$((P+1)); }
# hit on the FIRST line, hit on a LATER line: both must return immediately.
printf '  200  %s     0 2 65531     0     0      191  1\n  300  %s     0 2 65531     0     0        7  1\n' "\$\$" "\$\$" > "\$Z2K_TEST_QFILE"
P=0; z2k_wait_queue_bound \$\$ 200 3; echo "hit-first rc=\$? polls=\$P"
P=0; z2k_wait_queue_bound \$\$ 300 3; echo "hit-later rc=\$? polls=\$P"
# miss: polls to the deadline and a timeout is NOT an error (rc=0 by design).
P=0; z2k_wait_queue_bound \$\$ 999 3; echo "miss      rc=\$? polls=\$P"
# fractional path scales the poll count, not the deadline.
Z2K_FRACSLEEP=1
P=0; z2k_wait_queue_bound \$\$ 999 3; echo "miss-frac rc=\$? polls=\$P"
Z2K_FRACSLEEP=0
# daemon already dead -> rc=1, no polling.
P=0; z2k_wait_queue_bound 2147483646 200 3; echo "deadpid   rc=\$? polls=\$P"
# caller's q/rest/i/n survive (read + local interaction).
q=OUTER_Q; rest=OUTER_REST
P=0; z2k_wait_queue_bound \$\$ 200 3 >/dev/null 2>&1
echo "leak q=\$q rest=\$rest"
EOF
matrix "wait_queue_bound: return exits the function, timeout is not an error" "$TMP/p4.sh" \
"hit-first rc=0 polls=0
hit-later rc=0 polls=0
miss      rc=0 polls=3
miss-frac rc=0 polls=60
deadpid   rc=1 polls=0
leak q=OUTER_Q rest=OUTER_REST"

# 4b as its own case: stderr must be EMPTY when the proc file does not exist.
cat > "$TMP/p4b.sh" <<EOF
Z2K_FRACSLEEP=0
Z2K_TEST_QFILE="$TMP/definitely-absent"
. "$TMP/wqb.sh"
P=0
sleep() { P=\$((P+1)); }
z2k_wait_queue_bound \$\$ 200 2 >/dev/null
echo "polls=\$P" >&2
EOF
for sh_ in $SHELLS; do
    err=$("$sh_" "$TMP/p4b.sh" 2>&1 >/dev/null)
    if [ "$err" = "polls=2" ]; then
        ok "no nfnetlink_queue procfs -> stderr clean, deadline honoured [$(shlabel "$sh_")]"
    else
        no "no nfnetlink_queue procfs -> stderr clean, deadline honoured [$(shlabel "$sh_")]" \
           "polls=2" "$(printf '%s' "$err" | tr '\n' '/')"
    fi
done
# Source-level belt to the behavioural braces: the order must not drift back.
if extract_fn z2k_wait_queue_bound "$INIT" | grep -q 'done[[:space:]]*2>/dev/null[[:space:]]*<'; then
    ok "z2k_wait_queue_bound: 2>/dev/null precedes the input redirect"
else
    no "z2k_wait_queue_bound: 2>/dev/null precedes the input redirect" \
       "done 2>/dev/null < FILE" "$(extract_fn z2k_wait_queue_bound "$INIT" | grep -n 'done.*<' | tr '\n' '/')"
fi

# ===========================================================================
# 5. ( sleep 1; ... ) >/dev/null 2>&1 &  - fire and forget
# ===========================================================================
# Two independent properties, both load-bearing:
#   * the >/dev/null 2>&1 is NOT cosmetic. A background child that inherits the
#     parent's stdout keeps a command substitution around the caller open until
#     it exits - `out=$(/opt/etc/init.d/S99zapret2 restart)` (webpanel, menu.sh)
#     would pay the full `sleep 1` back. Verified: without the redirect all four
#     shells block. Discriminated WITHOUT a timer: if the parent really did not
#     wait, the marker file still has exactly ONE line when it returns.
#   * the child must outlive the parent and still do its work.
extract_fn repair_autocircular_files_after_daemon_start "$INIT" > "$TMP/repair.sh"
[ -s "$TMP/repair.sh" ] || no "repair_autocircular... extractable" "a body" "empty"
MARKS=""
for sh_ in $SHELLS; do
    sl=$(shlabel "$sh_")
    mk="$TMP/mark.$sl"; : > "$mk"; MARKS="$MARKS $mk"
    cat > "$TMP/p5.$sl.sh" <<EOF
ensure_autocircular_files() { echo x >> "$mk"; }
. "$TMP/repair.sh"
repair_autocircular_files_after_daemon_start
echo INLINE
EOF
    out=$("$sh_" "$TMP/p5.$sl.sh" 2>&1)
    n=$(wc -l < "$mk" | tr -d ' ')
    if [ "$out" = "INLINE" ] && [ "$n" = "1" ]; then
        ok "backgrounded re-apply does not block the caller [$sl]"
    else
        no "backgrounded re-apply does not block the caller [$sl]" \
           "INLINE/marks=1" "$out/marks=$n"
    fi
done
sleep 2   # one wait for all shells, not one per shell
for mk in $MARKS; do
    n=$(wc -l < "$mk" | tr -d ' ')
    if [ "$n" = "2" ]; then
        ok "backgrounded child outlives the parent and re-applies [${mk##*/mark.}]"
    else
        no "backgrounded child outlives the parent and re-applies [${mk##*/mark.}]" 2 "$n"
    fi
done

# ===========================================================================
# 6. run_daemon: case "$DAEMONBASE" dispatch + ${QNUM:-200}
# ===========================================================================
# nfqws2 gets the positive readiness wait; everything else keeps `sleep 1`.
# Runs the REAL run_daemon with a stub binary, stub PIDDIR and traced waits.
# z2k_daemon_err_file/_explain — зависимости run_daemon с 2026-08-13 (stderr
# демона больше не выбрасывается). Без них перенаправление 2>"$ERRFILE" уходит в
# пустое имя, старт «проваливается» на ровном месте, и тест меряет обвязку.
{ extract_fn z2k_pid_running "$INIT"; echo
  extract_fn z2k_daemon_err_file "$INIT"; echo
  extract_fn z2k_daemon_explain "$INIT"; echo
  extract_fn run_daemon "$INIT"; } > "$TMP/rd.sh"
[ -s "$TMP/rd.sh" ] || no "run_daemon extractable" "a body" "empty"
mkdir -p "$TMP/bin" "$TMP/pids"
for b in nfqws2 tpws2; do
    printf '#!/bin/sh\nexec sleep 5\n' > "$TMP/bin/$b"; chmod +x "$TMP/bin/$b"
done
# run_daemon's own chatter goes to /dev/null; the stubs record to a trace file
# instead of stdout so the two streams do not have to be untangled.
cat > "$TMP/p6.sh" <<EOF
PIDDIR="$TMP/pids"
TR="$TMP/rd.trace"; : > "\$TR"
QNUM=200
z2k_wait_queue_bound() {
    echo "QWAIT pid_ok=\$(kill -0 "\$1" 2>/dev/null && echo y || echo n) q=\$2 max=\$3" >> "\$TR"
    return 0
}
sleep() { echo "SLEEP \$1" >> "\$TR"; }
. "$TMP/rd.sh"
run_daemon 0 "$TMP/bin/nfqws2" "--qnum=200" >/dev/null 2>&1; echo "nfqws2 rc=\$?" >> "\$TR"
run_daemon 0 "$TMP/bin/tpws2"  ""            >/dev/null 2>&1; echo "tpws2  rc=\$?" >> "\$TR"
unset QNUM
run_daemon 1 "$TMP/bin/nfqws2" "" >/dev/null 2>&1; echo "noqnum rc=\$?" >> "\$TR"
cat "\$TR"
EOF
matrix "run_daemon: nfqws2 -> queue wait, others -> sleep 1, QNUM default 200" "$TMP/p6.sh" \
"QWAIT pid_ok=y q=200 max=3
nfqws2 rc=0
SLEEP 1
tpws2  rc=0
QWAIT pid_ok=y q=200 max=3
noqnum rc=0"
kill_pidfiles

# ===========================================================================
# 7. restart(): the fractional settle degrades to whole seconds, never to zero
# ===========================================================================
# `if z2k_fracsleep_avail; then usleep 200000 2>/dev/null || sleep 1; else sleep 1; fi`
# On a box without usleep the settle must still HAPPEN (netfilter teardown), and
# on a box where usleep exists but fails at runtime the `||` must catch it.
extract_fn restart "$INIT" > "$TMP/restart_body.sh"
cat > "$TMP/p7.sh" <<EOF
. "$TMP/fs.sh"
T=""
stop()  { T="\${T}stop "; }
start() { T="\${T}start"; }
sleep()  { T="\${T}sleep\$1 "; }
usleep() { T="\${T}usleep\$1 "; return \${USLEEP_RC:-0}; }
. "$TMP/restart_body.sh"
Z2K_FRACSLEEP=1; T=""; restart; echo "frac    [\$T]"
Z2K_FRACSLEEP=0; T=""; restart; echo "nofrac  [\$T]"
Z2K_FRACSLEEP=1; USLEEP_RC=1; T=""; restart; echo "usleepfail [\$T]"
EOF
matrix "restart(): settle degrades to sleep 1, never to nothing" "$TMP/p7.sh" \
"frac    [stop usleep200000 start]
nofrac  [stop sleep1 start]
usleepfail [stop usleep200000 sleep1 start]"

# ===========================================================================
# 8. PLATFORM PROBE: constructs used verbatim by the fix, in isolation
#    NB these are the only assertions in this file that NO source change can
#    turn red - they interrogate the interpreter, not the code. They earn
#    their place as the canary for a new box/toolchain (a shell without
#    POSIX $(( )) or `local` fails here first, with a readable message
#    instead of a wall of downstream noise). Everything else in this file
#    is mutation-proved; see the battery report.
# ===========================================================================
cat > "$TMP/p8.sh" <<'EOF'
m=3;  echo "arith $(( m * 20 ))"
set --; echo "posdefault ${2:-3}"
i=0; n=60; [ "$i" -lt "$n" ] && echo "lt ok"
[ "$Z2K_NEVER_SET" = 1 ] || echo "unset-cmp ok"
for d in nfqws2 tpws2 z2k-helper; do
    case "$d" in nfqws2) echo "$d qwait" ;; *) echo "$d sleep" ;; esac
done
# `kill -0 ""` is the one construct that genuinely DIVERGES: BusyBox ash reads
# "" as pid 0 (the process group) and SUCCEEDS, dash/bash/zsh fail. Not reached
# in the shipped code (stop_daemon_by_pidfile gates on [ -n "$PID" ] and
# run_daemon uses $!), so what is asserted is the property that must hold
# EVERYWHERE: an empty pid must not make the wait unbounded.
echo "kill0-empty $(kill -0 "" 2>/dev/null && echo ok-or-fail || echo ok-or-fail)"
EOF
matrix "PLATFORM PROBE: arith/\${:-}/[ ]/case-dispatch primitives" "$TMP/p8.sh" \
"arith 60
posdefault 3
lt ok
unset-cmp ok
nfqws2 qwait
tpws2 sleep
z2k-helper sleep
kill0-empty ok-or-fail"

# The empty-pid case, asserted for real. `kill` is stubbed to ALWAYS succeed,
# which is precisely BusyBox ash's behaviour for an empty pid (it reads "" as
# pid 0 = the process group) and is not reproducible on dash/bash/zsh, where
# `kill -0 ""` fails and the wait would exit on the first probe. Stubbing makes
# the divergent branch executable on every host: whatever `kill -0` says, the
# whole-second wait must stop at EXACTLY max polls - never max*20, never max+1.
cat > "$TMP/p8b.sh" <<EOF
Z2K_FRACSLEEP=0
. "$TMP/wg.sh"
P=0
kill()  { return 0; }          # emulate BusyBox: an empty pid looks alive
sleep() { P=\$((P+1)); }
P=0; z2k_wait_gone "" 3 >/dev/null 2>&1; echo "empty-pid rc=\$? polls=\$P"
P=0; z2k_wait_gone "" 1 >/dev/null 2>&1; echo "max1      rc=\$? polls=\$P"
EOF
matrix "empty pid looks alive (BusyBox): wait still stops at exactly max" "$TMP/p8b.sh" \
"empty-pid rc=1 polls=3
max1      rc=1 polls=1"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

# ===========================================================================
# ROUTER-ONLY CHECKLIST  (BusyBox ash 1.37.0, Keenetic aarch64, 4.9-ndm-5)
# ===========================================================================
# Everything above runs on dash/bash/macOS-sh. Four things CANNOT be validated
# off-router and must be re-confirmed there after any change to these helpers.
# All commands below are read-only or /tmp-only; none restarts the service.
#
# SSH: sshpass -p '<pw>' ssh -o StrictHostKeyChecking=no \
#        -o UserKnownHostsFile=/dev/null -p 222 root@192.168.1.1
#
# R1. Run THIS suite under the real interpreter. `#!/bin/sh` on Keenetic is an
#     "NDM Shell Wrapper" that execs /opt/bin/sh (busybox) when /opt is
#     mounted, so /bin/sh and /opt/bin/sh are both worth running.
#       tar czf - z2k/files/S99zapret2.new z2k/tests/test_restart_portability.sh \
#           zapret2-z2k-fork/common/base.sh | ssh ... 'cd /tmp && tar xzf -'
#       ssh ... '/bin/sh /tmp/z2k/tests/test_restart_portability.sh'
#     EXPECT: PASSED: 29  FAILED: 0
#     ACTUAL 2026-07-25: PASSED: 29  FAILED: 0, EXIT=0, under BOTH /bin/sh and
#     /opt/bin/sh. NB the router run is 29 not 47: /bin/zsh is absent and the
#     NDM wrapper /bin/sh has no usable -n, so those rows self-skip.
#
# R2. usleep really is an applet, and BusyBox `sleep` really rejects fractions -
#     the entire reason z2k_fracsleep_avail exists.
#       command -v usleep; usleep 50000; echo $?; sleep 0.2; echo $?
#     EXPECT: /opt/bin/usleep / 0 / "sleep: invalid number '0.2'" / 1
#     ACTUAL 2026-07-25: /opt/bin/usleep, rc=0, rc=0 (200000), sleep 0.2 -> rc=1
#     NB usleep lives in /opt/bin. A caller invoked with a PATH that lacks
#     /opt/bin (cron, some NDM hooks) legitimately takes the whole-second path.
#
# R3. The real /proc file, with its real column layout.
#       cat /proc/net/netfilter/nfnetlink_queue
#     EXPECT: one line per bound queue, LEADING WHITESPACE, queue num = $1, so
#             `read -r q rest` yields q=200 (read strips leading IFS blanks).
#     ACTUAL 2026-07-25: "  200    384     0 2 65531     0     0    21646  1"
#     NB the file is mode 0640 root:root - only root can poll it; the init
#     script runs as root, but a non-root caller would silently always time out.
#
# R4. contains() cost on the real CPU with a real 29 KB option string - the
#     17 s that this whole change is about. Off-router shells are far too fast
#     for the quadratic form to show up.
#       H=$(awk 'BEGIN{s="";while(length(s)<29000)s=s "--filter-tcp=443 --dpi-desync=fake --hostlist=/opt/zapret2/ipset/zapret-hosts-user.txt ";print s}')
#       new(){ case "$1" in *"$2"*) return 0;; esac; return 1; }
#       old(){ [ "${1#*$2}" != "$1" ]; }
#       t=$(date +%s); i=0; while [ $i -lt 5 ]; do new "$H" zzz; i=$((i+1)); done; echo new=$(( $(date +%s)-t ))
#       t=$(date +%s); i=0; while [ $i -lt 5 ]; do old "$H" zzz; i=$((i+1)); done; echo old=$(( $(date +%s)-t ))
#     EXPECT: new=0, old >= 15
#     ACTUAL 2026-07-25: new=0 s, old=18 s   (5 misses, 29058-byte haystack)
#
# R5. The one construct that genuinely DIVERGES. BusyBox reads an empty pid as
#     pid 0 (the process group) and SUCCEEDS; dash/bash/zsh fail.
#       kill -0 "" 2>/dev/null; echo "empty=$?"
#     EXPECT (router):  empty=0     EXPECT (dash/bash/zsh): empty=1
#     ACTUAL 2026-07-25: router empty=0, macOS dash/bash/zsh empty=1
#     Not reached in shipped code (stop_daemon_by_pidfile gates on
#     [ -n "$PID" ], run_daemon uses $!), and the section-8 case above proves
#     the wait stays bounded even when kill always succeeds. If a future caller
#     can pass an empty pid, it must gate on -n itself.
