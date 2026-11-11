#!/bin/sh
# Execute S99 migration/start/restart and the shipped persistence bridge.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export ZAPRET_BASE="$TMP/install" PIDDIR="$TMP/pids"
export Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TMP/fallback"
export Z2K_STATE_DIR_OVERRIDE="$ZAPRET_BASE/extra_strats/cache/autocircular"
export Z2K_STATE_FALLBACK="$TMP/fallback/z2k-autocircular-state.tsv"
mkdir -p "$Z2K_STATE_DIR_OVERRIDE" "$TMP/fallback" "$PIDDIR" "$ZAPRET_BASE/state"
STATE=$Z2K_STATE_DIR_OVERRIDE/state.tsv
for fn in _z2k_migrate_gv_named_state_v1 _z2k_migrate_gv_named_state_v2 start_daemons stop_daemons restart_daemons; do
    awk -v fn="$fn()" '$0==fn {p=1} p {print} p && /^}/ {exit}' files/S99zapret2.new >> "$TMP/functions.sh"
done
. "$TMP/functions.sh"
printf 'gv_tcp\t192.0.2.1|4\t1\t1794352923\tauto\t\n' > "$TMP/junk"
cat > "$TMP/keep" <<'ROWS'
gv_tcp	googlevideo.com|6	8	99	auto	
gv_tcp	youtube.com|4	9	98	auto	
gv_tcp	googlevideo.com|4	7	100	auto	
gv_tcp	youtube.com|6	2	101	auto	
gv_tcp	gvt1.com|4	3	102	auto	
gv_tcp	gvt1.com|6	4	103	auto	
gv_tcp	192.0.2.2|4	5	104	frozen	pin.example
gv_tcp	2001:db8::1|6	6	105	frozen	
gv_tcp	frozen.example|6	9	107	frozen	
rkn_tcp	192.0.2.3|4	7	106	auto	
ROWS
# Reproduce the v1 hole: cleanup succeeds initially without a preexisting marker,
# but a subsequent restoration is accepted by real persist and v1 skips it.
cp "$TMP/junk" "$STATE"
_z2k_migrate_gv_named_state_v1
[ ! -s "$STATE" ]
cp "$TMP/junk" "$STATE"
_z2k_migrate_gv_named_state_v1
cmp "$TMP/junk" "$STATE"
Z2K_GV_TEST_PHASE=repro lua tests/test_gv_named_state_v2.lua
printf '[PASS] v1 first pass cleans; v1 marker permits restored state (persist behavior printed above)\n'
cat "$TMP/keep" "$TMP/junk" > "$STATE"
cp "$STATE" "$Z2K_STATE_FALLBACK"
cp "$STATE" "$STATE.pre-renumber-v1"
cp "$STATE" "$STATE.pre-gv-named-v1"
# Orphans without pidfiles must block migration too.
z2k_pids_by_comm() { echo 99999; }
if _z2k_migrate_gv_named_state_v2; then echo '[FAIL] ignored orphan'; exit 1; fi
z2k_pids_by_comm() { :; }
# Fresh lock must fail without marking completion.
printf '%s' "$(date +%s)" > "$Z2K_STATE_FALLBACK.lock"
if _z2k_migrate_gv_named_state_v2; then echo '[FAIL] ignored lock'; exit 1; fi
[ ! -e "$ZAPRET_BASE/state/gv-named-state-v2.done" ]
rm "$Z2K_STATE_FALLBACK.lock"
printf '%s' "$$" > "$PIDDIR/nfqws2_test.pid"
if _z2k_migrate_gv_named_state_v2; then echo '[FAIL] migrated under live engine'; exit 1; fi
[ ! -e "$ZAPRET_BASE/state/gv-named-state-v2.done" ]
# The updater's shipped restart-service function must issue a full restart.
awk '/^au_step_restart_service\(\)/,/^}/' lib/auto_update.sh > "$TMP/update-restart.sh"
. "$TMP/update-restart.sh"
INIT_SCRIPT=$TMP/init
export Z2K_GV_RESTART_LOG="$TMP/restart-verb"
printf '#!/bin/sh\nprintf "%%s\n" "$1" > "$Z2K_GV_RESTART_LOG"\n' > "$INIT_SCRIPT"
au_step_restart_service
[ "$(cat "$Z2K_GV_RESTART_LOG")" = restart ]
# Execute actual restart_daemons -> stop_daemons -> start_daemons. Model the
# old engine's last disk write in stop_all_nfqws, before cleanup may run.
stop_all_nfqws() { cat "$TMP/keep" "$TMP/junk" > "$STATE"; rm "$PIDDIR/nfqws2_test.pid"; }
custom_runner() { :; }
z2k_daemon_fail_reset() { :; }
ensure_autocircular_files() { :; }
_z2k_migrate_rotator_sld() { :; }
_z2k_retire_cf_extra_state() { :; }
ensure_autohostlist_files() { :; }
z2k_preflight_v6_gate() { :; }
z2k_gvsub_ensure_ipfile() { :; }
repair_autocircular_files_after_daemon_start() { :; }
z2k_daemon_fail_count() { echo 0; }
standard_mode_daemons() { cmp "$TMP/keep" "$STATE"; touch "$TMP/started"; }
restart_daemons
[ -f "$TMP/started" ]
[ -f "$ZAPRET_BASE/state/gv-named-state-v2.done" ]
for f in "$STATE" "$Z2K_STATE_FALLBACK" "$STATE".pre-* "$Z2K_STATE_FALLBACK".pre-*; do
    [ -f "$f" ] || continue
    cmp "$TMP/keep" "$f"
done
# The actual rerun recovery consumes the cleaned pre-renumber snapshot and
# cannot revive its former IP rows, even if its own marker is removed later.
awk '/^_z2k_restore_state_after_rerun_v1\(\)/,/^}/' files/S99zapret2.new > "$TMP/restore.sh"
. "$TMP/restore.sh"
: > "$ZAPRET_BASE/state/pool-renumber-v1.done"
date() { if [ "${1:-}" = -r ]; then echo 1794352923; else command date "$@"; fi; }
_z2k_restore_state_after_rerun_v1
cmp "$TMP/keep" "$STATE"
# A stale lock left by an old engine must not strand the next update.
printf '1' > "$STATE.lock"
_z2k_migrate_gv_named_state_v2
[ ! -e "$STATE.lock" ]
: > "$STATE.lock"
_z2k_migrate_gv_named_state_v2
[ ! -e "$STATE.lock" ]
# Even restoration WITH the v2 marker cannot bypass the cleanup on next start.
cat "$TMP/junk" >> "$STATE"
_z2k_migrate_gv_named_state_v2
cmp "$TMP/keep" "$STATE"
# Runtime import, disk merge and direct save must enforce the same invariant.
cat "$TMP/keep" "$TMP/junk" > "$STATE"
cp "$STATE" "$Z2K_STATE_FALLBACK"
Z2K_GV_TEST_PHASE=fix lua tests/test_gv_named_state_v2.lua
# Exercise the real SLD -> v2 order for all three supported service domains.
awk '/^_z2k_migrate_rotator_sld\(\)/,/^}/' files/S99zapret2.new > "$TMP/sld.sh"
. "$TMP/sld.sh"
rm -f "$ZAPRET_BASE/state/domain-sld-v1.done" "$Z2K_STATE_FALLBACK"
printf 'gv_tcp\tc.youtube.com|6\t3\t100\tauto\n' > "$STATE"
printf 'gv_tcp\trr1.googlevideo.com|4\t4\t101\tauto\n' >> "$STATE"
printf 'gv_tcp\trr1.gvt1.com|6\t5\t102\tauto\n' >> "$STATE"
_z2k_migrate_rotator_sld
_z2k_migrate_gv_named_state_v2
[ "$(awk -F '\t' '$1=="gv_tcp" {n++} END {print n+0}' "$STATE")" = 3 ]
for service in 'youtube.com|6' 'googlevideo.com|4' 'gvt1.com|6'; do
    awk -F '\t' -v host="$service" '$1=="gv_tcp" && $2==host {found=1} END {exit !found}' "$STATE"
done
# A valid cleanup can produce an empty primary and fallback.
cp "$TMP/junk" "$STATE"
cp "$TMP/junk" "$Z2K_STATE_FALLBACK"
_z2k_migrate_gv_named_state_v2
[ ! -s "$STATE" ] && [ ! -s "$Z2K_STATE_FALLBACK" ]
printf '[PASS] v2 restart order, v1/v2 markers, locks, live-engine gate, snapshots, fallback and runtime restores\n'
