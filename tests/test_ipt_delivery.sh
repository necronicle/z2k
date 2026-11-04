#!/bin/sh
# Delivery contract for the signed common/ipt.sh override.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORK=${Z2K_FORK_DIR:-$ROOT/../zapret2-z2k-fork}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ipt-delivery.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

# shellcheck source=lib/release_map.sh
. "$ROOT/lib/release_map.sh"
eq 'patch map targets the live common/ipt.sh' '/opt/zapret2/common/ipt.sh' "$(ZAPRET2_DIR=/opt/zapret2 z2k_install_paths common/ipt.sh)"
eq 'shell override needs no automatic service restart' '' "$(z2k_steps_for common/ipt.sh)"

# The override replaces the whole fork file, so any later fork change outside
# the transaction helpers would be silently reverted on routers. Outside the
# helper block both files must match; once the fork carries the same helpers
# (it has _ipt_locked), the whole file must match. CI checks out z2k-master.
outside_helpers() {
    awk '/^# z2k: an existence check/ || /^ipt\(\)$/ { skip=1 }
         /^is_ipt_flow_offload_avail\(\)$/ { skip=0 }
         !skip' "$1"
}
if [ -f "$FORK/common/ipt.sh" ]; then
    outside_helpers "$ROOT/common/ipt.sh" > "$TMP/ours"
    outside_helpers "$FORK/common/ipt.sh" > "$TMP/fork"
    if cmp -s "$TMP/ours" "$TMP/fork"; then same=yes; else same=no; fi
    eq 'override matches the fork outside the transaction helpers' yes "$same"
    lines=$(wc -l < "$TMP/ours" | tr -d ' ')
    [ "$lines" -gt 300 ] && ok "helper-block cut keeps the rest of the file ($lines lines)" || \
        no 'helper-block cut keeps the rest of the file' '>300' "$lines"
    if grep -q '^_ipt_locked()' "$FORK/common/ipt.sh"; then
        if cmp -s "$ROOT/common/ipt.sh" "$FORK/common/ipt.sh"; then same=yes; else same=no; fi
        eq 'fork with the fix and override are byte-identical' yes "$same"
    fi
else
    SKIP=$((SKIP + 1)); printf '[SKIP] fork comparison (set Z2K_FORK_DIR)\n'
fi

# Exercise the real installer deployment helper with no network fallback.
# shellcheck source=lib/install.sh
. "$ROOT/lib/install.sh"
z2k_snapshot_external() { return 0; }
print_error() { :; }
print_warning() { :; }
print_info() { :; }
z2k_fetch() { return 1; }
WORK_DIR=$ROOT
mkdir -p "$TMP/target/common"
deploy_critical_file common/ipt.sh "$TMP/target/common/ipt.sh" 644 >/dev/null 2>&1
rc=$?
eq 'fresh-install critical deployment succeeds without network' 0 "$rc"
if cmp -s "$ROOT/common/ipt.sh" "$TMP/target/common/ipt.sh"; then deployed=yes; else deployed=no; fi
eq 'fresh-install target contains the exact shipped bytes' yes "$deployed"

# Verify step_build_zapret2 actually wires that helper after fork extraction.
# From the file, not `type`: dash prints only "is a shell function".
step_body=$(awk '/^step_build_zapret2\(\)/{f=1} f{print} f&&/^}/{exit}' "$ROOT/lib/install.sh")
case "$step_body" in
    *'deploy_critical_file "common/ipt.sh" "${ZAPRET2_DIR}/common/ipt.sh" 644'*) wired=yes ;;
    *) wired=no ;;
esac
eq 'fresh-install build step deploys the override as mode 0644' yes "$wired"

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
