#!/bin/sh
# tests/test_restart_latency.sh
# Guards the restart hot path against the two regressions that made a service
# restart take 25 s on a live Keenetic (measured 2026-07-25):
#
#   1. contains() implemented as [ "${1#*$2}" != "$1" ] — BusyBox ash's `#*`
#      shortest-prefix strip is QUADRATIC in ${#1}. Against a ~29 KB
#      NFQWS2_OPT one miss cost 2.8-4.9 s, and the daemon start path runs five
#      of them: ~17 s of the 25 s. `case` is a single match attempt.
#   2. Flat `sleep N` where a condition poll belongs (7.00 s total). nfqws2
#      exits on SIGTERM in ~0.05 s, so `sleep 3` after kill wasted ~2.95 s.
#
# Both are cheap to reintroduce by accident (the upstream engine still ships the
# quadratic contains, and `sleep` is the obvious thing to write), so this test
# asserts BEHAVIOUR, not just the source text. POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-${Z2K_INIT_UNDER_TEST:-$HERE/files/S99zapret2.new}}"
# Захардкоженный "../zapret2-z2k-fork" был верен только для дев-машины, где форк
# лежит РЯДОМ с этим репо. ci.yml чекаутит форк ВНУТРЬ рабочего каталога
# (path: zapret2-z2k-fork) и передаёт путь через Z2K_FORK_DIR — этот тест его
# игнорировал, поэтому "фикс от 2026-08-08" (см. ci.yml) реально работал только
# для test_contains_differential.sh, а этот файл в CI молча скипал base.sh
# каждый прогон, что и подтвердил живой ран ("Total skipped: 6").
BASE="${Z2K_FORK_DIR:-$HERE/../zapret2-z2k-fork}/common/base.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rlat.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
# A skip is NOT a pass. Counting it as one is how the engine-side half of this
# change ended up unguarded: CI checks out only this repo, so ../zapret2-z2k-fork
# is absent there and every base.sh assertion silently "passed". Skips are
# reported separately and never touch PASS.
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s\n' "$1"; }

# ---------------------------------------------------------------- helpers ---
# Pull a single function body out of a script without executing the script.
# Comments are stripped: this file documents the old quadratic form verbatim in
# a comment, and a naive grep for it would match the explanation rather than the
# code. Assert on code only.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1; print; next }
        inf && /^}/ { print; exit }
        inf { print }
    ' "$2" | grep -v '^[[:space:]]*#'
}

# ------------------------------------------- 1. contains() is not quadratic ---
# Behavioural check: build a large haystack and assert a MISS returns fast.
# The quadratic form takes seconds here; `case` takes milliseconds. We assert
# on wall-clock with a generous ceiling so the test is not flaky on slow CI,
# while still being ~100x below the regression's cost.
for src in "$INIT" "$BASE"; do
    label=$(basename "$src")
    if [ ! -f "$src" ]; then
        skip "$label: not checked out here (engine lives in a separate repo)"
        continue
    fi
    fn=$(extract_fn contains "$src")
    if [ -z "$fn" ]; then
        no "$label: contains() found" "a definition" "none"
        continue
    fi
    # The quadratic form is a one-liner test; the fast form uses `case`.
    if printf '%s' "$fn" | grep -q '#\*\$2'; then
        no "$label: contains() uses case-glob, not prefix-strip" "case" "\${1#*\$2}"
    else
        ok "$label: contains() uses case-glob, not prefix-strip"
    fi

    # And prove it behaves: 64 KB haystack, needle absent.
    cat > "$TMP/c.sh" <<EOF
$fn
h=\$(awk 'BEGIN{s="";while(length(s)<65536)s=s "--filter-tcp=443 --dpi-desync=fake ";print s}')
contains "\$h" "zzz-definitely-not-present" && exit 3
exit 0
EOF
    t0=$(date +%s)
    sh "$TMP/c.sh"; rc=$?
    t1=$(date +%s)
    el=$((t1-t0))
    [ "$rc" = 0 ] && ok "$label: contains() miss returns false on 64 KB" \
                  || no "$label: contains() miss returns false on 64 KB" 0 "$rc"
    # Quadratic on 64 KB is >15 s even on a fast x86 runner; 5 s is a safe fence.
    [ "$el" -le 5 ] && ok "$label: 64 KB miss under 5 s (was quadratic: minutes)" \
                    || no "$label: 64 KB miss under 5 s (was quadratic: minutes)" "<=5s" "${el}s"

    # Glob-injection: needle with metacharacters must be matched literally.
    cat > "$TMP/g.sh" <<EOF
$fn
contains "abc" "[a-z]" && exit 3
contains "abc" "a*c"   && exit 4
contains "a[a-z]c" "[a-z]" || exit 5
exit 0
EOF
    sh "$TMP/g.sh" && ok "$label: needle treated literally, not as a glob" \
                   || no "$label: needle treated literally, not as a glob" 0 "$?"
    [ "$src" = "$INIT" ] && SHADOW_CHECKED=1
done

# ------------------------------------- 2. no flat sleeps on the hot path ---
# stop_daemon_by_pidfile / run_daemon / restart / repair_... must not block on a
# bare `sleep N` in the foreground. A backgrounded `( sleep 1; ... ) &` is fine —
# it is off the critical path.
check_no_blocking_sleep() {
    fn=$(extract_fn "$1" "$INIT")
    [ -n "$fn" ] || { no "$1: function found" "a definition" "none"; return; }
    # strip backgrounded subshells, then look for a leading bare sleep
    bad=$(printf '%s\n' "$fn" | grep -v '^[[:space:]]*(.*)[[:space:]]*&[[:space:]]*$' \
          | grep -cE '^[[:space:]]*sleep[[:space:]]+[0-9]+[[:space:]]*$')
    [ "$bad" = 0 ] && ok "$1: no blocking flat sleep" \
                   || no "$1: no blocking flat sleep" 0 "$bad"
}
check_no_blocking_sleep stop_daemon_by_pidfile
check_no_blocking_sleep repair_autocircular_files_after_daemon_start

# restart() and run_daemon() may keep a `sleep 1` ONLY as the no-fractional-sleep
# fallback, i.e. guarded by z2k_fracsleep_avail / a case arm. Assert the guard.
for fn_name in restart run_daemon; do
    fn=$(extract_fn "$fn_name" "$INIT")
    if printf '%s\n' "$fn" | grep -qE '^[[:space:]]*sleep[[:space:]]+[0-9]+[[:space:]]*$'; then
        no "$fn_name: bare sleep is guarded by a capability/type check" "guarded" "bare sleep"
    else
        ok "$fn_name: bare sleep is guarded by a capability/type check"
    fi
done

# ----------------------------- 3. the death wait keeps its SIGKILL ceiling ---
# The poll must be bounded in TIME, not in iterations: without fractional sleep
# a 3 s deadline must stay 3 s, or a wedged daemon (OOM / MIPS async-preempt)
# stalls every restart and self-heal. Drive z2k_wait_gone with usleep hidden.
{ extract_fn z2k_pid_running "$INIT"; echo; extract_fn z2k_fracsleep_avail "$INIT"; echo; extract_fn z2k_wait_gone "$INIT"; } > "$TMP/fns.sh"
cat > "$TMP/w.sh" <<EOF
# Z2K_FRACSLEEP=0 simulates a box without usleep, which is the dangerous case:
# the loop must then poll in WHOLE seconds and still stop at the 3 s deadline,
# not keep the fractional poll count and stretch to 60 s.
Z2K_FRACSLEEP=0
. "$TMP/fns.sh"
# Count polls instead of actually waiting. NB: the counter must NOT be named
# n/i/pid/max — z2k_wait_gone declares those \`local\`, and under sh's dynamic
# scoping the stub would increment the function's local, not ours.
Z2K_TEST_POLLS=0
sleep() { Z2K_TEST_POLLS=\$((Z2K_TEST_POLLS+1)); }
z2k_wait_gone \$\$ 3        # \$\$ never dies, so the deadline is what stops it
echo "\$Z2K_TEST_POLLS"
EOF
polls=$(sh "$TMP/w.sh" 2>/dev/null | tail -1)
if [ "$polls" = 3 ]; then
    ok "z2k_wait_gone: 3 s deadline stays 3 polls without fractional sleep"
else
    no "z2k_wait_gone: 3 s deadline stays 3 polls without fractional sleep" 3 "$polls"
fi

# The S99 shadow is in THIS repo and is what actually runs on a router whose
# engine predates the fix, so it must never be skipped - that would leave the
# whole change unguarded wherever the fork is absent. Checked BEFORE the summary
# so the printed counters are the real ones.
if [ "${SHADOW_CHECKED:-0}" != 1 ]; then
    no "the in-repo S99 shadow contains() was asserted" "asserted" "never ran"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
