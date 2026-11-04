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

if [ -f "$FORK/common/ipt.sh" ]; then
    if cmp -s "$ROOT/common/ipt.sh" "$FORK/common/ipt.sh"; then same=yes; else same=no; fi
    eq 'shipped and fork helper files are byte-identical' yes "$same"
else
    SKIP=$((SKIP + 1)); printf '[SKIP] fork byte comparison (set Z2K_FORK_DIR)\n'
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
step_body=$(type step_build_zapret2 2>/dev/null)
case "$step_body" in
    *'deploy_critical_file "common/ipt.sh" "${ZAPRET2_DIR}/common/ipt.sh" 644'*) wired=yes ;;
    *) wired=no ;;
esac
eq 'fresh-install build step deploys the override as mode 0644' yes "$wired"

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
