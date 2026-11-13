#!/bin/sh
# Execute the shipped cleanup and update step selection, without live paths.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT HUP INT TERM
ZAPRET_BASE=$T/install
EXTRA_STRATS_DIR=$ZAPRET_BASE/extra_strats
Z2K_STATE_FALLBACK=$T/fallback/state.tsv
export ZAPRET_BASE EXTRA_STRATS_DIR Z2K_STATE_FALLBACK
mkdir -p "$ZAPRET_BASE/state" "$EXTRA_STRATS_DIR/cache/autocircular" "$T/fallback"
state=$EXTRA_STRATS_DIR/cache/autocircular/state.tsv
printf 'rkn_tcp\texample.org|4\t2\t100\tfrozen\t\tclient-policy-v2\n' > "$state"
cp "$state" "$Z2K_STATE_FALLBACK"
cp "$state" "$T/expected"
for f in client-role.tsv client-role-topology.tsv client-role-status.txt client-role-v1.done; do
    : > "$ZAPRET_BASE/state/$f"
done
: > "$ZAPRET_BASE/state/pool-renumber-v5.done"
: > "$ZAPRET_BASE/config.pre-client-role"
for f in "$state" "$Z2K_STATE_FALLBACK"; do
    : > "$f.pre-client-role-v1"
    : > "$f.client-role-quarantine.tsv"
done
awk '/^_z2k_cleanup_retired_role\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$T/cleanup.sh"
. "$T/cleanup.sh"
NFQWS2_OPT='--filter-tcp=443 --lua-desync=z2k_client_guard --lua-desync=circular:key=rkn_tcp --new --lua-desync z2k_client_guard:x=1 --lua-desync=fake'
NFQWS2_OPT_BASE="--lua-init=@$ZAPRET_BASE/lua/z2k-client-role.lua --user=nobody"
_z2k_cleanup_retired_role
_z2k_cleanup_retired_role
case "$NFQWS2_OPT $NFQWS2_OPT_BASE" in *z2k_client_guard*|*z2k-client-role.lua*) exit 1 ;; esac
case "$NFQWS2_OPT" in *--lua-desync=circular:key=rkn_tcp*--lua-desync=fake*) ;; *) exit 1 ;; esac
[ "$NFQWS2_OPT_BASE" = '--user=nobody' ]
[ -f "$ZAPRET_BASE/state/pool-renumber-v5.done" ]
[ ! -e "$ZAPRET_BASE/config.pre-client-role" ]
for f in "$ZAPRET_BASE/state/"client-role* "$state.pre-client-role-v1" "$state.client-role-quarantine.tsv" "$Z2K_STATE_FALLBACK.pre-client-role-v1" "$Z2K_STATE_FALLBACK.client-role-quarantine.tsv"; do [ ! -e "$f" ]; done
cmp "$state" "$T/expected"
cmp "$Z2K_STATE_FALLBACK" "$T/expected"
# Dispatch actual startup until the engine boundary, rejecting unknown actions.
awk '/^start_daemons\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$T/start.sh"
. "$T/start.sh"
z2k_daemon_fail_reset() { :; }
stop_all_nfqws() { :; }
ensure_autocircular_files() { :; }
_z2k_migrate_broad_udp_removal_v1() { :; }
_z2k_migrate_rotator_sld() { :; }
_z2k_migrate_gv_named_state_v1() { :; }
_z2k_retire_cf_extra_state() { :; }
ensure_autohostlist_files() { :; }
z2k_preflight_v6_gate() { :; }
z2k_gvsub_ensure_ipfile() { :; }
# Subshell exits at the launch boundary; unknown retired action is a failure.
standard_mode_daemons() {
    case "$NFQWS2_OPT $NFQWS2_OPT_BASE" in *z2k_client_guard*|*z2k-client-role.lua*) exit 1 ;; esac
    touch "$T/launched"; exit 0
}
custom_runner() { standard_mode_daemons; }
NFQWS2_OPT='--filter-tcp=443 --lua-desync=z2k_client_guard --lua-desync=fake'
MODE_FILTER=none
( start_daemons )
[ -f "$T/launched" ]
. "$ROOT/lib/release_map.sh"
z2k_steps_for lib/config_official.sh > "$T/steps"
grep -qx regen-config "$T/steps"
. "$ROOT/lib/auto_update.sh"
# Exercise the updater dispatch with its real regen step and a local generator.
au_gen_libs_source() { :; }
create_official_config() { printf 'regenerated\n' > "$1"; }
ZAPRET2_DIR=$ZAPRET_BASE
au_step_regen_config
grep -qx regenerated "$ZAPRET_BASE/config"
echo '[PASS] retired role cleanup, old-config startup, state preservation and updater regen'
