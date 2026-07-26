#!/bin/sh
# tests/test_contains_differential.sh
#
# contains() is the single highest-risk part of the restart-latency change: it
# replaces a primitive that UPSTREAM code (common/list.sh, common/installer.sh,
# blockcheck2*) calls, and that code is not ours. The rewrite was
#
#     OLD   [ "${1#*$2}" != "$1" ]          <- glob pattern, $2 UNQUOTED
#     NEW   case "$1" in *"$2"*) ...        <- glob pattern, $2 QUOTED
#
# so this suite does not test "the new one works". It tests EQUIVALENCE to the
# old one over everything a caller can produce, and it PINS the exact set of
# inputs where the two disagree, with a justification for each.
#
# The theorem the suite establishes:
#
#     For every non-empty needle containing none of  *  ?  [  \
#     OLD and NEW return the same exit code, for every haystack.
#
# Everything outside that set is enumerated case by case in DIVERGENCE TABLE
# below and cross-checked against every real call site in the engine.
#
# WHAT IS *NOT* COVERED BY AN AUTOMATED RUN (router-only):
#   - BusyBox ash itself. There is no busybox on a dev Mac; the closest local
#     proxy is dash, which shares ash's ancestry and (verified) its quadratic
#     ${1#*$2}. The suite runs the whole differential under EVERY local shell it
#     can find and requires them to agree, which is the best available proxy.
#     Validated by hand on the production aarch64 Keenetic, BusyBox 1.37.0,
#     2026-07-25 - 0 BAD, divergence set identical to the table below, fuzz
#     7128+7128 pairs / 0 literal divergence, contains_old at 32 KB = 3000 ms
#     vs contains_new 0 ms. Repeat with:
#       ssh root@router 'cat > /tmp/tcd.sh' < tests/test_contains_differential.sh
#       # write the shipped contains() to /tmp/impl.sh renamed contains_new
#       ssh root@router 'Z2K_ROLE=driver Z2K_IMPL=/tmp/impl.sh \
#           Z2K_SECTIONS="corpus fuzz perf" Z2K_PERF_OLD=1 /bin/sh /tmp/tcd.sh'
#     Expect: no BAD/LITDIV/NEWBAD lines, "CASES 63", "FUZZ * 7128 * 0".
#   - The absolute 25.1s -> 1.73s restart figure. That is wall-clock on a live
#     aarch64 Keenetic and cannot be reproduced off-box.
#
# ------------------------------------------------------------------ DIVERGENCE
# label                   old new  reachable by a real caller?   verdict
# empty-hay-empty-needle  1   1    NO (see CALL SITES below)     NO DIVERGENCE (guard added)
# empty-needle            1   1    NO                            NO DIVERGENCE (guard added)
# bs-needle-escape        0   1    NO                            FIX (old matched a phantom)
# bs-needle-literal       1   0    NO                            FIX (old missed a real hit)
# bs-needle-alone         -   0    NO   NOT PINNED: old is shell-dependent (see corpus)
# glob-star-needle        0   1    NO                            FIX (old expanded the needle)
# glob-star-only-hit      1   0    NO                            FIX (old missed a literal '*')
# glob-question-needle    0   1    NO                            FIX
# glob-class-needle       0   1    NO                            FIX
# glob-class-neg-needle   0   1    NO                            FIX
# site-base-with-meta     0   1    NO (no install path has one)  FIX
# unterminated '[' needle  ?   0   NO                            NOT PINNED: old is
#                                       shell-dependent (dash 1, bash/ash 0), so it is
#                                       covered by the fuzz property, not by a value.
# (rc 0 = "found", rc 1 = "not found", i.e. shell truth)
#
# Only two contains() needles in the whole engine are bare variables
# (HOSTLIST_MARKER, HOSTLIST_NOAUTO_MARKER); both are assigned non-empty
# literals at file scope in common/list.sh lines 1-2, above every function in
# that file. Every other needle is a string literal or carries a literal
# prefix. Hence "reachable = NO" throughout, asserted in section 5.
#
# ------------------------------------------------------------------ CALL SITES
# Every contains() invocation in the engine, needle side (19 sites, 10 needles):
#   common/base.sh          "--ipset"  "--ipset=$ZAPRET_BASE"
#                           "--ipset-exclude=$ZAPRET_BASE"
#                           "--hostlist=$ZAPRET_BASE"
#                           "--hostlist-exclude=$ZAPRET_BASE"
#   common/list.sh          "$HOSTLIST_MARKER"  "$HOSTLIST_NOAUTO_MARKER"
#   common/installer.sh     " "  (x2)
#   blockcheck2.sh          nft
#   blockcheck2.d/standard  tcp_md5  (x9)
# Section 5 re-derives that list from the tree at run time and fails if a new
# needle shape appears (e.g. after an upstream merge).
#
# POSIX sh. Style: tests/test_nfqueue_selfheal.sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-${Z2K_INIT_UNDER_TEST:-$HERE/files/S99zapret2.new}}"
# Overridable so the CI condition (engine repo absent) is reproducible locally:
#     Z2K_FORK_DIR=/nonexistent sh tests/test_contains_differential.sh
FORK="${Z2K_FORK_DIR:-$HERE/../zapret2-z2k-fork}"
BASE="$FORK/common/base.sh"

# The ENGINE lives in a separate repository (necronicle/zapret2-z2k), checked out
# next to this one on a dev box and simply absent in CI. Its assertions are then
# SKIPPED, never failed — but counted and printed, because a silent skip is how a
# suite quietly stops testing anything. Everything about OUR files stays hard.
FORK_PRESENT=0
[ -f "$BASE" ] && FORK_PRESENT=1

# =============================================================================
# DRIVER MODE
# =============================================================================
# The script re-executes itself under each available shell with Z2K_ROLE=driver.
# The driver sources ONE extracted contains() (renamed contains_new) plus the
# verbatim pre-fix implementation (contains_old) and emits machine-readable
# lines. Keeping it in this file means the corpus is written once, and the
# corpus runs in-process so arbitrary bytes can be passed as arguments without
# a quoting round-trip.
if [ "$Z2K_ROLE" = driver ]; then

LC_ALL=C; export LC_ALL
# Byte semantics, deliberately: the router runs in C locale, and pinning it
# makes the high-byte / UTF-8 cases deterministic instead of libc-dependent.

# The pre-fix upstream implementation, verbatim from zapret2 common/base.sh.
contains_old()
{
	[ "${1#*$2}" != "$1" ]
}

# The shipped implementation, extracted from the file under test.
. "$Z2K_IMPL"

# Which sections to run. The >=64 KB differential is split out because
# contains_old is quadratic there BY CONSTRUCTION - running it for every
# (implementation x shell) pair would add minutes to the suite for no extra
# information, since input SIZE has no shell-dependent semantics. It runs once,
# on the shell where the quadratic form is cheapest.
SECTIONS=${Z2K_SECTIONS:-"corpus fuzz perf"}
has_section() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }

# Millisecond clock where the platform has one, whole seconds where it does not
# (BSD date, BusyBox date without %N). Everything that consumes now_ms accounts
# for the coarse case explicitly.
NS=0
_t=$(date +%s%N 2>/dev/null)
case "$_t" in ''|*[!0-9]*) ;; *) [ "${#_t}" -ge 16 ] && NS=1 ;; esac
now_ms() {
    if [ "$NS" = 1 ]; then echo $(( $(date +%s%N) / 1000000 ))
    else echo $(( $(date +%s) * 1000 )); fi
}

CASES=0
c() {
	# $1 label  $2 want_old  $3 want_new  $4 haystack  $5 needle
	contains_old "$4" "$5"; o=$?
	contains_new "$4" "$5"; n=$?
	CASES=$((CASES+1))
	if [ "$o" != "$2" ] || [ "$n" != "$3" ]; then
		echo "BAD $1 want=$2/$3 got=$o/$n"
	fi
	if [ "$o" != "$n" ]; then
		echo "DIV $1"
	fi
	return 0
}

NL=$(printf '\nx'); NL=${NL%x}
TAB=$(printf '\tx'); TAB=${TAB%x}
HI=$(printf '\377x'); HI=${HI%x}
BS='\'
Q='"'
SQ="'"

if has_section corpus; then
# ---------------------------------------------------------------- 1. basics --
c empty-hay-empty-needle   1 1 ""        ""
c empty-hay                1 1 ""        "x"
c empty-needle             1 1 "abc"     ""
c needle-eq-haystack       0 0 "abc"     "abc"
c at-start                 0 0 "abcdef"  "abc"
c at-end                   0 0 "abcdef"  "def"
c in-middle                0 0 "abcdef"  "cd"
c absent                   1 1 "abcdef"  "xyz"
c repeated-needle          0 0 "abcabcabc" "abc"
c single-char-hit          0 0 "abc"     "b"
c single-char-miss         1 1 "abc"     "z"
c needle-longer            1 1 "ab"      "abcdef"
c needle-longer-prefix     1 1 "abc"     "abcd"
c overlapping-prefix       0 0 "aab"     "ab"
c near-miss-suffix         1 1 "abcde"   "cdx"
c whole-haystack-is-needle 0 0 "x"       "x"

# ------------------------------------------------------- 2. awkward bytes ----
c newline-hit          0 0 "a${NL}b${NL}c" "${NL}b"
c newline-miss         1 1 "a${NL}b"       "${NL}z"
c newline-only-needle  0 0 "a${NL}b"       "${NL}"
c tab-hit              0 0 "a${TAB}b"      "${TAB}b"
c tab-miss             1 1 "a b"           "${TAB}"
c space-hit            0 0 "--a b --c"     " "
c space-miss           1 1 "--a-b--c"      " "
c dquote               0 0 "a${Q}b${SQ}c"  "${Q}b${SQ}"
c dollar-literal       0 0 'a$b'           '$b'
c backtick-literal     0 0 'a`b'           '`b'
c brace                0 0 "a{b}c"         "{b}"
c caret                0 0 "a^b"           "^b"
c percent              0 0 "a%b"           "%b"
c tilde                0 0 "a~b"           "~b"
c utf8-hit             0 0 "привет мир"    "вет"
c utf8-miss            1 1 "привет"        "зззз"
c highbyte-hit         0 0 "a${HI}b"       "${HI}b"
c highbyte-miss        1 1 "aXb"           "${HI}"

# --------------------------------------------------- 3. glob metacharacters --
# The OLD form interpolated $2 UNQUOTED into a pattern, so a needle carrying a
# metacharacter was expanded instead of matched. Option strings carry
# filesystem paths, so this was a latent correctness bug, not a nicety.
c glob-star-needle       0 1 "abc"     "a*c"     # phantom hit under OLD
c glob-star-literal      0 0 "a*c"     "a*c"     # both find the real one
c glob-star-only-miss    1 1 "abc"     "*"       # OLD: '*' strips shortest = ""
c glob-star-only-hit     1 0 "a*c"     "*"       # OLD misses the literal '*'
c glob-star-trailing     1 1 "abc"     "z*"
c glob-question-needle   0 1 "abc"     "a?c"     # phantom hit under OLD
c glob-question-literal  0 0 "a?c"     "a?c"
c glob-class-needle      0 1 "abc"     "[a-z]"   # phantom hit under OLD
c glob-class-literal     0 0 "x[a-z]y" "[a-z]"   # same verdict, different reason
c glob-class-neg-needle  0 1 "abc"     "[!x]"    # phantom hit under OLD
c glob-rbracket-plain    0 0 "a]b"     "]b"      # ']' alone is literal in glob
c bs-needle-escape       0 1 "ab"      "a${BS}b" # OLD read '\b' as literal 'b'
c bs-needle-literal      1 0 "a${BS}b" "a${BS}b" # OLD could not see a real '\'
# NOT pinned: a needle that is a LONE backslash ("a\b" / "\"). old's verdict is
# shell-dependent — every shell on the dev host (dash, bash, /bin/sh) answers "not
# found", Ubuntu's dash answers "found", because a trailing backslash in the
# unquoted ${1#*$2} pattern is an incomplete escape and what that means is left to
# the implementation. That platform-dependence IS the indictment of the old form,
# but it cannot be pinned as a value. new answers "found" everywhere, which the
# metacharacter bucket of the fuzz below still exercises as a property.
# NOT pinned: an UNTERMINATED '[' in the needle ("a[b" / "[b"). dash treats the
# whole pattern as a failed match, bash treats '[' literally, so old's verdict
# is shell-dependent. It stays inside the metacharacter bucket of the fuzz
# below, which asserts a property rather than a value.

# ------------------------------------------------- 5. real engine call sites --
# The real needles, against the real NFQWS2_OPT shape. Fixture is a trimmed
# copy of the live 28956-byte NFQWS2_OPT from the production Keenetic
# (2026-07-25): same alphabet, same embedded newlines between profiles, same
# /opt/zapret2 paths. Trimmed so CI can run offline in milliseconds.
OPT=$(cat <<'Z2KFIX'
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/RKN/List.txt --hostlist=/opt/zapret2/extra_strats/TCP_Discord.txt --hostlist=/opt/zapret2/lists/extra-domains.txt --hostlist=/opt/zapret2/lists/discovered-domains.txt --filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --out-range=-s34228 --in-range=-s20000 --lua-desync=circular:fails=3:maxseq=16384:time=60:key=rkn_tcp:nld=2:inseq=26000:retrans=2 --in-range=x --payload=tls_client_hello --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6-10:tcp_ts=-1000:tls_mod=rnd,dupsid,sni=www.google.com:strategy=1:fool=z2k_dynamic_ttl --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=681:seqovl_pattern=tls_clienthello_www_google_com:strategy=1 --lua-desync=hostfakesplit:payload=tls_client_hello:dir=out:host=rzd.ru:seqovl=726:badsum:strategy=2:fool=z2k_dynamic_ttl:tcp_seq=0:tcp_ack=-66000 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1:strategy=4 --new
--hostlist-exclude=/opt/zapret2/lists/whitelist.txt --hostlist=/opt/zapret2/extra_strats/TCP/YT/List.txt --filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello,empty --out-range=-s34228 --in-range=-s5556 --lua-desync=circular:fails=3:maxseq=16384:time=60:key=yt_tcp:nld=2:inseq=18000:retrans=2 --in-range=x --payload=tls_client_hello --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1:strategy=6 --new
--filter-udp=50000-50100,1400,3478-3481,5349,19294-19344 --filter-l7=discord,stun --out-range=-d4 --payload=discord_ip_discovery,stun --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=discord_udp:nld=2:hostkey=z2k_nohost_key --new
--filter-tcp=80 --hostlist=/opt/zapret2/lists/extra-domains.txt --in-range=-s5556 --payload=http_req,empty,http_reply --lua-desync=http_methodeol:payload=http_req:dir=out:strategy=1 --in-range=x
Z2KFIX
)
ZAPRET_BASE=/opt/zapret2
HOSTLIST_MARKER="<HOSTLIST>"
HOSTLIST_NOAUTO_MARKER="<HOSTLIST_NOAUTO>"

# has_bad_ws_options(), common/base.sh:444-453 - the 5 calls the daemon start
# path runs 3 times. Values are pinned, not just compared: the point of the
# change was to keep every one of these decisions bit-identical.
c site-ipset            1 1 "$OPT" "--ipset"
c site-ipset-base       1 1 "$OPT" "--ipset=$ZAPRET_BASE"
c site-ipset-excl-base  1 1 "$OPT" "--ipset-exclude=$ZAPRET_BASE"
c site-hostlist-base    0 0 "$OPT" "--hostlist=$ZAPRET_BASE"
c site-hostlist-ex-base 0 0 "$OPT" "--hostlist-exclude=$ZAPRET_BASE"
# filter_apply_hostlist_target(), common/list.sh:30 - run twice per start.
c site-marker           1 1 "$OPT" "$HOSTLIST_MARKER"
c site-marker-noauto    1 1 "$OPT" "$HOSTLIST_NOAUTO_MARKER"
# ...and the same two against a template that still carries the markers.
c site-marker-present   0 0 "--filter-tcp=443 <HOSTLIST> --new" "$HOSTLIST_MARKER"
c site-marker-noauto-present 0 0 "--filter-tcp=80 <HOSTLIST_NOAUTO>" "$HOSTLIST_NOAUTO_MARKER"
# common/installer.sh:57,148
c site-space-in-value   0 0 "iptables nft" " "
c site-space-absent     1 1 "/opt/zapret2"  " "
# blockcheck2.sh:1478
c site-nft-yes          0 0 "/usr/sbin/xtables-nft-multi" "nft"
c site-nft-no           1 1 "/usr/sbin/xtables-legacy-multi" "nft"
# blockcheck2.d/standard/*.sh - $fooling is a comma list
c site-tcp-md5-yes      0 0 "badseq,tcp_md5,ts" "tcp_md5"
c site-tcp-md5-no       1 1 "badseq,ts,badsum"  "tcp_md5"
# Hypothetical but legal install path with a glob metacharacter. OLD would have
# reported a false positive here; NEW is correct. No production router uses such
# a path, which is why this is a fix and not a regression.
c site-base-with-meta   0 1 "--ipset=/opt/zap2" "--ipset=/opt/zap[2]"

echo "CASES $CASES"
fi

# --------------------------------------------------------- 4. large inputs ---
# >=64 KB haystacks. Run once (see SECTIONS above). Sizes are the real thing:
# the live NFQWS2_OPT on the production Keenetic is 28956 bytes and the option
# string is what these calls are actually handed.
if has_section big; then
CASES=0
BIG=$(awk 'BEGIN{s="";while(length(s)<65536)s=s "--filter-tcp=443 --lua-desync=fake:blob=x ";print s}')
KB1=$(awk 'BEGIN{s="";while(length(s)<1024)s=s "--filter-tcp=443 --lua-desync=fake:blob=x ";print s}')
echo "BIGLEN ${#BIG}"
c big-miss        1 1 "$BIG"                   "zzz-definitely-not-present"
c big-hit-start   0 0 "MARKER$BIG"             "MARKER"
c big-hit-end     0 0 "${BIG}MARKER"           "MARKER"
c big-hit-middle  0 0 "${BIG}MARKER${BIG}"     "MARKER"
c big-needle-longer-than-haystack 1 1 "short"  "$BIG"
c big-needle-tail 0 0 "$BIG"                   "--lua-desync=fake:blob=x "
# needle == haystack is measured at 1 KB, not 64 KB, ON PURPOSE: the OLD form
# turns "$1" into a 64 KB glob pattern and costs 4.9 s at 8 KB, ~80 s at 32 KB
# and minutes at 64 KB on this box. Differential coverage of that shape stops
# where it stops being computable; the 64 KB variant is asserted below against
# the NEW implementation alone, with its expected value hard-coded.
c big-needle-eq-1k 0 0 "$KB1"                  "$KB1"
echo "BIGCASES $CASES"

# NEW-only, 64 KB+, absolute expected values. These exist because the OLD form
# cannot be run here in finite time - stated plainly rather than skipped.
#
# Fuse first: needle==haystack at 64/128 KB is exactly the shape that costs
# MINUTES under a quadratic implementation. If the file under test has been
# reverted, running these would hang the suite instead of failing it, so probe
# at 8 KB and refuse rather than wedge. A refusal is reported as a failure.
nbad=0
n1() { contains_new "$2" "$3"; [ "$?" = "$4" ] || { echo "NEWBAD $1"; nbad=$((nbad+1)); }; return 0; }
KB8=$(awk 'BEGIN{s="";while(length(s)<8192)s=s "--filter-tcp=443 --lua-desync=fake:blob=x ";print s}')
f0=$(now_ms 2>/dev/null || date +%s); contains_new "$KB8" "$KB8"; f1=$(now_ms 2>/dev/null || date +%s)
if [ $((f1-f0)) -gt 250 ]; then
    echo "NEWBAD implementation-is-quadratic-8KB-self-match-took-$((f1-f0))ms"
    echo "NEWONLY 99"
else
    n1 new-eq-64k       "$BIG"               "$BIG"      0
    n1 new-eq-128k      "${BIG}${BIG}"       "${BIG}${BIG}" 0
    n1 new-128k-miss    "${BIG}${BIG}"       "zzz-none"  1
    n1 new-128k-hit-mid "${BIG}MARKER${BIG}" "MARKER"    0
    echo "NEWONLY $nbad"
fi
fi

# ------------------------------------------------------------ 6. fuzz -------
if has_section fuzz; then
# Two exhaustive sweeps. set -f throughout: several haystacks/needles are
# themselves globs and MUST NOT be pathname-expanded by the loops.
set -f
fuzz() {
    # $1 = "literal" | "meta"; remaining args = alphabet
    mode="$1"; shift
    ftot=0; fdiv_meta=0; fdiv_lit=0
    na=$#
    i=1
    while [ "$i" -le "$na" ]; do
        eval "c1=\${$i}"
        j=0
        while [ "$j" -le "$na" ]; do
            if [ "$j" -eq 0 ]; then c2=''; else eval "c2=\${$j}"; fi
            k=0
            while [ "$k" -le "$na" ]; do
                if [ "$k" -eq 0 ]; then c3=''; else eval "c3=\${$k}"; fi
                nd="$c1$c2$c3"
                for hy in "ab" "a*b" "a?b" "a[b" "a]b" "a\\b" "a-b" "abab" "[a-z]" "xyz" "--hostlist=/opt/zapret2/x.txt"; do
                    contains_old "$hy" "$nd"; o=$?
                    contains_new "$hy" "$nd"; n=$?
                    ftot=$((ftot+1))
                    [ "$o" = "$n" ] && continue
                    case "$nd" in
                        *'*'*|*'?'*|*'['*|*'\'*) fdiv_meta=$((fdiv_meta+1)) ;;
                        *) fdiv_lit=$((fdiv_lit+1)); echo "LITDIV [$hy] [$nd] old=$o new=$n" ;;
                    esac
                done
                k=$((k+1))
            done
            j=$((j+1))
        done
        i=$((i+1))
    done
    echo "FUZZ $mode $ftot $fdiv_meta $fdiv_lit"
}
# Alphabet 1: every glob metacharacter plus ordinary letters. Needles of length
# 1..3 over 8 symbols x 11 haystacks = 7776 pairs. Proves the theorem holds even
# when the HAYSTACK is full of metacharacters, and that metacharacter needles do
# diverge (so the sweep is not blind).
fuzz meta a b '*' '?' '[' ']' '\' '-'
# Alphabet 2: the characters that actually occur in NFQWS2_OPT. Zero divergence
# is required here - this is the production input space.
fuzz literal - = / . ':' ',' ' ' a
set +f
fi

# ------------------------------------------------------- 7. performance -----
if has_section perf; then
# Falsifiable in TWO ways, so it cannot be green for the wrong reason:
#   P1 asserts the shipped implementation is fast;
#   P2 measures the OLD implementation on the SAME box and asserts the harness
#      can actually see the difference. If P2 ever fails, the timer/shell is not
#      discriminating and P1 proves nothing - which is a real failure, not a
#      skip. (zsh's ${1#*$2} is not quadratic; dash/bash/ash all are.)
# With a nanosecond clock 64 KB is enough. With whole-second resolution only,
# use 256 KB so the quadratic form is ~30 s and cannot hide inside one tick.
if [ "$NS" = 1 ]; then PSZ=65536; else PSZ=262144; fi
PBIG=$(awk -v n="$PSZ" 'BEGIN{s="";while(length(s)<n)s=s "--filter-tcp=443 --lua-desync=fake:blob=x ";print s}')
t0=$(now_ms); contains_new "$PBIG" "zzz-definitely-not-present"; prc=$?; t1=$(now_ms)
echo "PERFNEW $((t1-t0)) $PSZ $prc"
if [ "$Z2K_PERF_OLD" = 1 ]; then
    # 32 KB, not 64: the quadratic form costs ~2.9 s here under dash and we only
    # need the ratio, not another 12 s of suite time.
    OBIG=$(awk 'BEGIN{s="";while(length(s)<32768)s=s "--filter-tcp=443 --lua-desync=fake:blob=x ";print s}')
    t0=$(now_ms); contains_new "$OBIG" "zzz-definitely-not-present"; t1=$(now_ms)
    nms=$((t1-t0))
    t0=$(now_ms); contains_old "$OBIG" "zzz-definitely-not-present"; t1=$(now_ms)
    oms=$((t1-t0))
    echo "PERFOLD $oms $nms"
fi
fi
exit 0
fi
# =============================================================================
# END DRIVER MODE
# =============================================================================

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cdiff.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
SKIP=0
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

# The exact set of labels allowed to disagree. Sorted, newline separated.
EXPECTED_DIV='bs-needle-escape
bs-needle-literal
glob-class-needle
glob-class-neg-needle
glob-question-needle
glob-star-needle
glob-star-only-hit
site-base-with-meta'

# Pull one function body out of a script without executing it. Comments are
# stripped: base.sh documents the OLD form verbatim in a comment and a naive
# grep would match the explanation instead of the code.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1; print; next }
        inf && /^}/ { print; exit }
        inf { print }
    ' "$2" | grep -v '^[[:space:]]*#'
}

# ===================================================== 1. source integrity ===
IMPLS=""
for src in "$BASE" "$INIT"; do
    label=$(basename "$src")
    if [ ! -f "$src" ]; then
        if [ "$src" = "$BASE" ] && [ "$FORK_PRESENT" = 0 ]; then
            skip "$label: contains() source integrity" "engine repo not checked out"
        else
            no "$label: present" "a file" "missing"
        fi
        continue
    fi
    fn=$(extract_fn contains "$src")
    if [ -z "$fn" ]; then
        no "$label: contains() definition found" "a definition" "none"
        continue
    fi
    ok "$label: contains() definition found"

    # Normalised body must be exactly the guarded case-glob form with a QUOTED
    # needle. Three separate properties, asserted separately so a failure names
    # which one broke rather than dumping a diff.
    # drop the "contains()" header, the opening "{" and the closing "}", then
    # trim indentation and blank lines so the comparison is layout-insensitive
    body=$(printf '%s\n' "$fn" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                                     -e '/^$/d' -e '/^contains()$/d' \
                                     -e '/^{$/d' -e '/^}$/d')
    want='[ -n "$2" ] || return 1
case "$1" in *"$2"*) return 0 ;; esac
return 1'
    if [ "$body" = "$want" ]; then
        ok "$label: contains() is the guarded, quoted case-glob form"
    else
        no "$label: contains() is the guarded, quoted case-glob form" "$want" "$body"
    fi
    # The needle must be QUOTED inside the pattern; an unquoted *$2* would
    # re-introduce glob expansion of the needle with none of the speed loss,
    # which the behavioural corpus alone would flag only via the DIV set.
    case "$body" in *'*"$2"*'*) ok "$label: needle is quoted inside the case pattern" ;;
                    *) no "$label: needle is quoted inside the case pattern" '*"$2"*' "$body" ;; esac
    # The empty-needle guard is what keeps parity with the pre-fix form.
    case "$body" in *'[ -n "$2" ]'*) ok "$label: empty-needle guard present (upstream parity)" ;;
                    *) no "$label: empty-needle guard present (upstream parity)" '[ -n "$2" ]' "$body" ;; esac
    # And the quadratic form must be gone.
    case "$body" in *'#*$2'*) no "$label: quadratic prefix-strip is gone" "case glob" '${1#*$2}' ;;
                    *) ok "$label: quadratic prefix-strip is gone" ;; esac

    printf '%s\n' "$fn" | sed '1s/^contains()/contains_new()/' > "$TMP/impl_$label.sh"
    IMPLS="$IMPLS $TMP/impl_$label.sh"
    echo "$body" > "$TMP/body_$label"
done

if [ -f "$TMP/body_base.sh" ] && [ -f "$TMP/body_S99zapret2.new" ]; then
    if cmp -s "$TMP/body_base.sh" "$TMP/body_S99zapret2.new"; then
        ok "engine and init-script contains() bodies are identical"
    else
        no "engine and init-script contains() bodies are identical" "identical" "differ"
    fi
fi

# The shadow only works if it is defined AFTER base.sh is sourced and nothing
# later re-defines it. Both are load-bearing and both are cheap to break.
src_ln=$(grep -n '^\. "\$ZAPRET_BASE/common/base\.sh"' "$INIT" | head -1 | cut -d: -f1)
def_ln=$(grep -n '^contains()' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$src_ln" ] && [ -n "$def_ln" ] && [ "$def_ln" -gt "$src_ln" ]; then
    ok "S99: shadow contains() is defined after base.sh is sourced (line $def_ln > $src_ln)"
else
    no "S99: shadow contains() is defined after base.sh is sourced" "def>src" "$def_ln>$src_ln"
fi
later=$(awk -v d="$def_ln" 'NR>d && /^[[:space:]]*\. "\$ZAPRET_BASE\// {print $2}' "$INIT" \
        | tr -d '"' | sed 's|\$ZAPRET_BASE/||')
redef=0
for f in $later; do
    [ -f "$FORK/$f" ] || continue
    grep -q '^contains()' "$FORK/$f" && { redef=$((redef+1)); echo "  re-defined by $f"; }
done
[ "$redef" = 0 ] && ok "S99: no later-sourced engine file re-defines contains()" \
                 || no "S99: no later-sourced engine file re-defines contains()" 0 "$redef"

if [ "$FORK_PRESENT" = 0 ]; then
    skip "base.sh: rationale for the rewrite is recorded in the source" "engine repo not checked out"
elif grep -q 'quadratic' "$BASE"; then
    ok "base.sh: rationale for the rewrite is recorded in the source"
else
    no "base.sh: rationale for the rewrite is recorded in the source" "comment" "none"
fi

# ============================================== 2-4,6-7. differential run ====
# Every local shell we can find. dash is the closest available proxy for the
# router's BusyBox ash; requiring all of them to agree is what makes the pinned
# table trustworthy off-box.
SHELLS=""
for s in /bin/dash /bin/sh /bin/bash /bin/ash /usr/bin/dash; do
    [ -x "$s" ] || continue
    case " $SHELLS " in *" $s "*) continue ;; esac
    # De-dup: /bin/sh is usually a link to one of the others, and running the same
    # binary twice adds nothing to a differential.
    # NOT `-ef` — it is undefined in POSIX sh (SC3013) and this file is #!/bin/sh.
    # `cmp` is POSIX and answers the question we actually care about: identical
    # bytes means the same shell, whether the duplicate is a symlink or a copy.
    dup=0
    for t in $SHELLS; do cmp -s "$s" "$t" && dup=1; done
    [ "$dup" = 0 ] && SHELLS="$SHELLS $s"
done
[ -n "$SHELLS" ] || SHELLS=/bin/sh
printf '  shells under test:%s\n' "$SHELLS"

for impl in $IMPLS; do
    ilabel=$(basename "$impl" .sh); ilabel=${ilabel#impl_}
    for sh_bin in $SHELLS; do
        tag="$ilabel@$(basename "$sh_bin")"
        out=$(Z2K_ROLE=driver Z2K_IMPL="$impl" "$sh_bin" "$0" 2>&1)
        drc=$?

        [ "$drc" = 0 ] || { no "$tag: driver ran cleanly" 0 "$drc"; printf '%s\n' "$out" | head -5; continue; }

        # --- named corpus: every pinned old/new pair must hold
        bad=$(printf '%s\n' "$out" | grep '^BAD ' | head -20)
        ncases=$(printf '%s\n' "$out" | sed -n 's/^CASES //p')
        # Floor = the corpus size as written (64). This is a tripwire against the
        # corpus being silently emptied or truncated, so it must track the real
        # count: set too high it fails on a healthy run, set to 0 it guards
        # nothing. Raise it when you add cases.
        if [ -z "$bad" ] && [ "${ncases:-0}" -ge 63 ]; then
            ok "$tag: all $ncases pinned old/new verdicts hold"
        else
            no "$tag: all pinned old/new verdicts hold" "0 BAD, >=63 cases" "$(printf '%s' "$bad" | tr '\n' ';') cases=$ncases"
        fi

        # --- the divergence set is exactly the documented one
        got=$(printf '%s\n' "$out" | sed -n 's/^DIV //p' | sort)
        if [ "$got" = "$EXPECTED_DIV" ]; then
            ok "$tag: divergence set == documented table"
        else
            no "$tag: divergence set == documented table" \
               "$(printf '%s' "$EXPECTED_DIV" | tr '\n' ',')" "$(printf '%s' "$got" | tr '\n' ',')"
        fi

        # --- fuzz: metachar-free needles never diverge; metachar needles do
        fm=$(printf '%s\n' "$out" | sed -n 's/^FUZZ meta //p')
        fl=$(printf '%s\n' "$out" | sed -n 's/^FUZZ literal //p')
        set -- $fm; mtot=$1; mdivm=$2; mdivl=$3
        set -- $fl; ltot=$1; ldivm=$2; ldivl=$3
        if [ "${mdivl:-x}" = 0 ] && [ "${ldivl:-x}" = 0 ] && [ "${ldivm:-x}" = 0 ] \
           && [ "${mtot:-0}" -ge 7000 ] && [ "${ltot:-0}" -ge 7000 ]; then
            ok "$tag: $((mtot+ltot)) fuzz pairs, 0 divergence for metachar-free needles"
        else
            no "$tag: fuzz pairs, 0 divergence for metachar-free needles" "0/0/0" \
               "meta=$fm literal=$fl"
            printf '%s\n' "$out" | grep '^LITDIV' | head -10
        fi
        if [ "${mdivm:-0}" -gt 0 ]; then
            ok "$tag: fuzz is discriminating ($mdivm metachar-needle divergences seen)"
        else
            no "$tag: fuzz is discriminating (metachar-needle divergences seen)" ">0" "${mdivm:-0}"
        fi

        # --- performance
        pn=$(printf '%s\n' "$out" | sed -n 's/^PERFNEW //p')
        set -- $pn; pms=$1; psz=$2; prc=$3
        # Ceiling justification: the shipped form measures 2-4 ms at 64 KB on a
        # 2024 laptop under dash/bash and ~10 ms on the router's aarch64. 500 ms
        # is a ~100x margin for a loaded CI box, while the reverted form costs
        # 1.9 s (bash) / 11.8 s (dash) / >14 s (router, extrapolated from the
        # measured 2.8-4.9 s at 29 KB) - i.e. at least 4x above the ceiling on
        # the FASTEST diverging shell. The 2000 ms variant applies only when the
        # clock has whole-second resolution, and is paired with a 256 KB input
        # where the quadratic form costs ~30 s.
        if [ "$psz" = 65536 ]; then ceil=500; else ceil=2000; fi
        [ "${prc:-1}" = 1 ] && ok "$tag: ${psz}B miss returns false" \
                            || no "$tag: ${psz}B miss returns false" 1 "$prc"
        if [ "${pms:-999999}" -le "$ceil" ]; then
            ok "$tag: ${psz}B miss in ${pms}ms (ceiling ${ceil}ms)"
        else
            no "$tag: ${psz}B miss under ceiling" "<=${ceil}ms" "${pms}ms"
        fi

    done
done

# ------------------------------------- >=64 KB differential + timing self-check
# One extra driver run. Shell choice: the quadratic contains_old costs 11.8 s
# per 64 KB miss under dash but 1.9 s under bash, and input SIZE carries no
# shell-dependent semantics (the per-shell pattern semantics are pinned by the
# corpus above, which runs everywhere). So prefer bash here purely for wall
# clock, and fall back to whatever exists.
BIGSHELL=
for s in /bin/bash /bin/sh /bin/dash; do
    [ -x "$s" ] && { BIGSHELL=$s; break; }
done
bimpl=$(echo $IMPLS | awk '{print $NF}')   # the init script's copy
if [ -n "$BIGSHELL" ] && [ -n "$bimpl" ]; then
    btag="$(basename "$bimpl" .sh)@$(basename "$BIGSHELL")"; btag=${btag#impl_}
    bout=$(Z2K_ROLE=driver Z2K_IMPL="$bimpl" Z2K_SECTIONS="big perf" Z2K_PERF_OLD=1 \
           "$BIGSHELL" "$0" 2>&1)
    bbad=$(printf '%s\n' "$bout" | grep '^BAD ' | head -20)
    bdiv=$(printf '%s\n' "$bout" | grep -c '^DIV ')
    bn=$(printf '%s\n' "$bout" | sed -n 's/^BIGCASES //p')
    blen=$(printf '%s\n' "$bout" | sed -n 's/^BIGLEN //p')
    if [ -z "$bbad" ] && [ "${bdiv:-1}" = 0 ] && [ "${bn:-0}" -ge 7 ] && [ "${blen:-0}" -ge 65536 ]; then
        ok "$btag: $bn cases on a ${blen}-byte haystack, old and new agree exactly"
    else
        no "$btag: >=64 KB haystack differential" "0 BAD, 0 DIV, >=7 cases, >=65536 B" \
           "bad=$(printf '%s' "$bbad" | tr '\n' ';') div=$bdiv cases=$bn len=$blen"
    fi

    nonly=$(printf '%s\n' "$bout" | sed -n 's/^NEWONLY //p')
    if [ "${nonly:-x}" = 0 ]; then
        ok "$btag: 64/128 KB needle==haystack and 128 KB hit/miss (new only, old not computable)"
    else
        no "$btag: 64/128 KB new-only checks" 0 "$nonly $(printf '%s\n' "$bout" | grep '^NEWBAD' | tr '\n' ' ')"
    fi

    po_line=$(printf '%s\n' "$bout" | sed -n 's/^PERFOLD //p')
    if [ -n "$po_line" ]; then
        set -- $po_line; oms=$1; nms=$2
        # Self-check: on THIS box, with THIS clock, the pre-fix form must be
        # visibly worse. If it is not, the ceiling asserted above is decoration
        # and every perf PASS in this file is meaningless - so this is a
        # failure, not a skip.
        if [ "$oms" -ge 250 ] && [ "$oms" -ge $(( (nms + 1) * 20 )) ]; then
            ok "timing harness is discriminating: 32KB old=${oms}ms vs new=${nms}ms"
        else
            no "timing harness is discriminating: pre-fix form must be visibly slower" \
               ">=250ms and >=20x new" "old=${oms}ms new=${nms}ms"
        fi
    else
        no "timing harness self-check ran" "PERFOLD line" "none"
    fi
fi

# ================================================= 5. call-site enumeration ===
# Re-derive every contains() needle from the engine tree. Any needle shape we
# have not reasoned about - in particular a bare $VAR that could be empty, or a
# literal carrying a glob metacharacter - fails here. This is the tripwire for
# an upstream merge introducing a call site the analysis above does not cover.
if [ -d "$FORK/common" ]; then
    NEEDLES="$TMP/needles"
    find "$FORK/common" "$FORK/blockcheck2.d" "$FORK/init.d" -type f 2>/dev/null > "$TMP/files"
    [ -f "$FORK/blockcheck2.sh" ] && echo "$FORK/blockcheck2.sh" >> "$TMP/files"
    : > "$TMP/stripped"
    while IFS= read -r f; do sed 's/#.*//' "$f" >> "$TMP/stripped"; done < "$TMP/files"
    grep -hoE '(^|[^_[:alnum:]])contains[[:space:]]+("[^"]*"|[^[:space:]"]+)[[:space:]]+("[^"]*"|[^[:space:]"&|;)]+)' \
        "$TMP/stripped" \
        | sed -E 's/.*contains[[:space:]]+("[^"]*"|[^[:space:]"]+)[[:space:]]+//' > "$NEEDLES"
    nsites=$(wc -l < "$NEEDLES" | tr -d ' ')
    [ "${nsites:-0}" -ge 19 ] && ok "call sites found in engine tree ($nsites)" \
                              || no "call sites found in engine tree" ">=19" "$nsites"

    # Allowlist: every needle we have differentially proven above.
    ALLOWED='" "
"--hostlist-exclude=$ZAPRET_BASE"
"--hostlist=$ZAPRET_BASE"
"--ipset"
"--ipset-exclude=$ZAPRET_BASE"
"--ipset=$ZAPRET_BASE"
"$HOSTLIST_MARKER"
"$HOSTLIST_NOAUTO_MARKER"
nft
tcp_md5'
    printf '%s\n' "$ALLOWED" > "$TMP/allowed"
    unknown=$(sort -u "$NEEDLES" | while IFS= read -r nd; do
        grep -Fxq -e "$nd" "$TMP/allowed" || printf '%s|' "$nd"
    done)
    [ -z "$unknown" ] && ok "every engine needle is one this suite differentially proved" \
                      || no "every engine needle is one this suite differentially proved" "" "$unknown"

    # No engine needle contains a glob metacharacter, so the deliberate
    # divergence is unreachable in production - the claim the change rests on.
    meta=$(sort -u "$NEEDLES" | grep -E '[*?[\\]' | tr '\n' '|')
    [ -z "$meta" ] && ok "no engine needle carries a glob metacharacter (divergence unreachable)" \
                   || no "no engine needle carries a glob metacharacter" "" "$meta"

    # EMPTY NEEDLE reachability. Only two needles are bare variables. Both are
    # assigned a non-empty literal at file scope in the same file that uses
    # them, before any function definition, so neither can be empty at a call.
    lst="$FORK/common/list.sh"
    for v in HOSTLIST_MARKER HOSTLIST_NOAUTO_MARKER; do
        asn=$(grep -n "^$v=" "$lst" | head -1)
        ln=${asn%%:*}
        val=${asn#*=}
        firstfn=$(grep -n '^[a-zA-Z_][a-zA-Z_0-9]*()' "$lst" | head -1 | cut -d: -f1)
        if [ -n "$asn" ] && [ -n "$val" ] && [ "$val" != '""' ] \
           && [ -n "$firstfn" ] && [ "$ln" -lt "$firstfn" ]; then
            ok "$v is assigned a non-empty literal at file scope (line $ln < first fn $firstfn)"
        else
            no "$v is assigned a non-empty literal at file scope" "top-level non-empty" "$asn"
        fi
    done
    # The remaining variable needle is "--ipset=$ZAPRET_BASE" etc: the literal
    # prefix makes it non-empty no matter what ZAPRET_BASE holds.
    ok "path needles keep a literal prefix, so they are non-empty for any ZAPRET_BASE"
else
    skip "engine call-site enumeration" "engine repo not checked out"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
