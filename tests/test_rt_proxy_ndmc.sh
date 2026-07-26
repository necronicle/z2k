#!/bin/sh
# tests/test_rt_proxy_ndmc.sh
#
# Every ndmc call in S96z2k-rt-proxy must clear LD_LIBRARY_PATH for that call.
#
# This is asserted BEHAVIOURALLY, not by grepping the source: a mock ndmc records
# the LD_LIBRARY_PATH it actually saw plus its argv, and the test drives the real
# dns_override_set / dns_override_clear with a poisoned environment. Grepping for
# the literal prefix would pass for a call that is prefixed but reached through a
# wrapper that re-exports the path, and would fail for a correct call written any
# other way.
#
# WHY IT MATTERS - measured on the owner's router (KeenOS 5.01.C.1.0-0, 2026-07-26),
# not quoted from a code comment:
#
#   LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib  ndmc -c "ip host ..."  -> rc=1, NO record
#   (unset)                                ndmc -c "ip host ..."  -> rc=0, record created
#
# ndmc picks up Entware's incompatible OpenSSL and dies with
# "system failed [0xcffd0062] / Cli::Main: failed to initialize". The live rt-proxy
# supervisor really does carry LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib (read from
# /proc/<pid>/environ), and `>/dev/null 2>&1` hid the failure.
#
# The bug was INVOCATION-DEPENDENT, which is why it survived: at boot rc.unslung
# sets LD_LIBRARY_PATH="" so the pins were written and looked fine, while a restart
# from the scheduler / install.sh / auto-update / an ssh shell silently did nothing.
# The damaging half is the CLEAR path: a failed clear leaves rutracker pinned to the
# sentinel 10.171.171.171 with no daemon listening, so the site stays dead.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
S96=${Z2K_S96_UNDER_TEST:-"$HERE/files/init.d/S96z2k-rt-proxy"}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rtndmc.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$S96" ] || { printf '[FAIL] not found: %s\n' "$S96"; exit 1; }

# --- mock ndmc: records the env it was handed, then succeeds -----------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/ndmc" <<EOF
#!/bin/sh
# One line per call: the LD_LIBRARY_PATH this process actually inherited, then argv.
printf 'LLP=[%s] ARGV=[%s]\n' "\${LD_LIBRARY_PATH-UNSET}" "\$*" >> "$TMP/ndmc.log"
exit 0
EOF
chmod +x "$BIN/ndmc"

# Handles BOTH shell brace styles: `f() {` (used in S96) and `f()` + `{` on the
# next line (used in S99zapret2.new). Matching only the latter is why the first
# run of this test reported "found in S96: none" for functions that plainly exist.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*\\{?[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

for fn in dns_override_set dns_override_clear; do
    body=$(extract_fn "$fn" "$S96")
    if [ -z "$body" ]; then
        no "$fn: found in S96" "a definition" "none"
        continue
    fi
    : > "$TMP/ndmc.log"
    # Poison the environment exactly the way the live supervisor is poisoned.
    cat > "$TMP/drive.sh" <<EOF
LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib
export LD_LIBRARY_PATH
DOMAINS="rutracker.org www.rutracker.org rutracker.wiki"
SENTINEL="10.171.171.171"
$body
$fn
EOF
    PATH="$BIN:$PATH" sh "$TMP/drive.sh" >/dev/null 2>&1

    calls=$(wc -l < "$TMP/ndmc.log" | tr -d ' ')
    # 3 domains + 1 "system configuration save"
    [ "$calls" = 4 ] && ok "$fn: made all 4 ndmc calls (3 domains + save)" \
                     || no "$fn: made all 4 ndmc calls (3 domains + save)" 4 "$calls"

    # THE assertion: not one call may see a non-empty LD_LIBRARY_PATH.
    # NB no `|| echo 0`: grep -c ALREADY prints 0 and exits 1 when it matches
    # nothing, so the fallback appended a SECOND zero and the comparison against
    # "0" failed against the literal "0\n0" - a green fix looked red.
    leaked=$(grep -c 'LLP=\[/opt' "$TMP/ndmc.log" 2>/dev/null); leaked=${leaked:-0}
    [ "$leaked" = 0 ] && ok "$fn: no ndmc call inherited Entware's LD_LIBRARY_PATH" \
                      || no "$fn: no ndmc call inherited Entware's LD_LIBRARY_PATH" 0 "$leaked"

    # ...and the save must be covered too - it was one of the four bare calls.
    saveline=$(grep 'system configuration save' "$TMP/ndmc.log" 2>/dev/null)
    case "$saveline" in
        *'LLP=[]'*|*'LLP=[UNSET]'*) ok "$fn: the config-save call is covered as well" ;;
        '')                         no "$fn: the config-save call is covered as well" "one save call" "none" ;;
        *)                          no "$fn: the config-save call is covered as well" "LLP empty" "$saveline" ;;
    esac

    # Every domain reached ndmc, so a prefix fix cannot have dropped one.
    for d in rutracker.org www.rutracker.org rutracker.wiki; do
        grep -q "$d" "$TMP/ndmc.log" \
            && ok "$fn: $d passed to ndmc" \
            || no "$fn: $d passed to ndmc" "present" "missing"
    done
done

# --- the clear path must really remove, not just be called ------------------
# A `no ip host` is what un-pins the sentinel; assert the verb, because a clear
# that silently degrades to a set would leave the site dead in the worst way.
body=$(extract_fn dns_override_clear "$S96")
: > "$TMP/ndmc.log"
cat > "$TMP/drive2.sh" <<EOF
LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib
export LD_LIBRARY_PATH
DOMAINS="rutracker.org"
SENTINEL="10.171.171.171"
$body
dns_override_clear
EOF
PATH="$BIN:$PATH" sh "$TMP/drive2.sh" >/dev/null 2>&1
if grep -q 'ARGV=\[-c no ip host rutracker.org 10.171.171.171\]' "$TMP/ndmc.log"; then
    ok "clear path issues 'no ip host <domain> <sentinel>'"
else
    no "clear path issues 'no ip host <domain> <sentinel>'" "no ip host ..." "$(tr '\n' ';' < "$TMP/ndmc.log")"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
