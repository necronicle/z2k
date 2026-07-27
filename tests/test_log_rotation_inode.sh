#!/bin/sh
# tests/test_log_rotation_inode.sh
#
# rotate_log used to do `tail -800 f > f.tmp && mv f.tmp f`.
#
# `mv` REPLACES THE INODE. A daemon that holds the log open with `>>` keeps writing into the
# now-unlinked old inode: its output goes nowhere, forever, while the file on disk looks
# perfectly healthy and even keeps the last 800 lines. Nothing errors, nothing warns.
#
# That is not a hypothetical. The usque engine appends to /tmp/z2k-log/z2k-warp.log for the
# whole life of the process, so after the first rotation its log froze — and several rounds
# of WARP diagnosis were built on lines read out of a file the engine had stopped writing to
# days earlier. We blinded our own instrument and then trusted the readings.
#
# The property asserted here is therefore the INODE, not the content: truncate in place.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
SCHED="${Z2K_SCHED_UNDER_TEST:-$HERE/files/z2k-scheduler.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/lrot.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$SCHED" ] || { printf '[FAIL] missing %s\n' "$SCHED"; exit 1; }

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*\\{?[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

FN="$TMP/fn.sh"
extract_fn rotate_log "$SCHED" > "$FN"
grep -q '^rotate_log()' "$FN" && ok "extracted rotate_log()" \
                              || { no "extracted rotate_log()" "a definition" "none"; exit 1; }

inode_of() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }

# 1200 lines, so the >1000 threshold fires.
LOG="$TMP/engine.log"
i=0; : > "$LOG"
while [ "$i" -lt 1200 ]; do i=$((i + 1)); echo "line $i" >> "$LOG"; done
before=$(inode_of "$LOG")
lines_before=$(wc -l < "$LOG" | tr -d ' ')

# A writer that already has the file open, exactly like the engine does.
exec 9>> "$LOG"

sh -c ". '$FN'; LOG='$LOG'; rotate_log '$LOG'" 2>&1

after=$(inode_of "$LOG")
lines_after=$(wc -l < "$LOG" | tr -d ' ')

[ "$lines_before" -gt 1000 ] && ok "the fixture crossed the rotation threshold ($lines_before)" \
                             || no "the fixture crossed the rotation threshold" ">1000" "$lines_before"
[ "$lines_after" -lt "$lines_before" ] && ok "the log was actually rotated ($lines_before -> $lines_after)" \
                                       || no "the log was actually rotated" "fewer lines" "$lines_after"
# THE assertion.
[ -n "$before" ] && [ "$before" = "$after" ] \
    && ok "the inode is preserved — an open writer keeps writing to the same file" \
    || no "the inode is preserved" "$before" "$after"

# And prove it behaviourally: a write through the already-open descriptor must land in the
# file we can still see. With mv it lands in the unlinked inode and is lost.
echo "after-rotation marker" >&9
exec 9>&-
if grep -q 'after-rotation marker' "$LOG"; then
    ok "a write from the pre-existing descriptor is visible after rotation"
else
    no "a write from the pre-existing descriptor is visible after rotation" "the marker" "lost"
fi

# The implementation must not reintroduce mv.
case "$(cat "$FN")" in
    *"mv "*) no "rotate_log does not use mv on the live log" "no mv" "mv present" ;;
    *)       ok "rotate_log does not use mv on the live log" ;;
esac

# A log under the threshold must be left completely alone (inode and content).
SMALL="$TMP/small.log"
printf 'a\nb\nc\n' > "$SMALL"
si=$(inode_of "$SMALL")
sh -c ". '$FN'; LOG='$SMALL'; rotate_log '$SMALL'" 2>&1
[ "$si" = "$(inode_of "$SMALL")" ] && [ "$(wc -l < "$SMALL" | tr -d ' ')" = 3 ] \
    && ok "a small log is untouched" \
    || no "a small log is untouched" "unchanged" "inode/content changed"

# No leftover temp file next to the log.
ls "$TMP"/*.tmp >/dev/null 2>&1 && no "no .tmp leftovers" "none" "$(ls "$TMP"/*.tmp)" \
                                || ok "no .tmp leftovers"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
