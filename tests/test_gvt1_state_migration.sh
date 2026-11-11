#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
awk '/^_z2k_migrate_gvt1_state_v1\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/migrate.sh"
. "$TMP/migrate.sh"
command -v _z2k_migrate_gvt1_state_v1 >/dev/null || { echo '[FAIL] no gvt1 migration'; exit 1; }
ZAPRET_BASE=$TMP/install
Z2K_STATE_FALLBACK=$TMP/fallback/z2k-autocircular-state.tsv
mkdir -p "$ZAPRET_BASE/extra_strats/cache/autocircular" "$TMP/fallback"
STATE=$ZAPRET_BASE/extra_strats/cache/autocircular/state.tsv
MARKER=$ZAPRET_BASE/state/gvt1-state-v1.done
printf '# header\nquic\tnotgvt1.com|4\t2\t100\tauto\t\nrkn_tcp\tgvt1.com.example|6\t3\t200\tfrozen\t\n' > "$TMP/expected"
cp "$TMP/expected" "$TMP/original"
for pool in rkn_tcp http_rkn quic gv_tcp yt_tcp other_pool; do
    for host in 'gvt1.com|4' 'gvt1.com|6' 'rr.gvt1.com|4' '*.gvt1.com|6' 'RR.GVT1.COM|6'; do
        printf '%s\t%s\t5\t300\tfrozen\t\n' "$pool" "$host" >> "$TMP/original"
    done
done
for f in "$STATE" "$STATE.pre-renumber-v1" "$STATE.pre-gv-named-v1" "$Z2K_STATE_FALLBACK" "$Z2K_STATE_FALLBACK.pre-gv-named-v1"; do cp "$TMP/original" "$f"; done
printf '%s' "$(date +%s)" > "$STATE.lock"
if _z2k_migrate_gvt1_state_v1; then echo '[FAIL] ignored lock'; exit 1; fi
[ ! -e "$MARKER" ]
cmp "$TMP/original" "$STATE"
# The real startup gate must refuse to reach daemon launch after cleanup fails.
awk '/^start_daemons\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/start.sh"
. "$TMP/start.sh"
z2k_daemon_fail_reset() { :; }
ensure_autocircular_files() { :; }
_z2k_migrate_rotator_sld() { touch "$TMP/too-late"; }
if start_daemons; then echo '[FAIL] startup ignored migration failure'; exit 1; fi
[ ! -e "$TMP/too-late" ]
rm "$STATE.lock"
cp "$TMP/original" "$Z2K_STATE_FALLBACK"
# Partial progress cannot create the done marker; retry cleans the locked file.
printf '%s' "$(date +%s)" > "$Z2K_STATE_FALLBACK.lock"
if _z2k_migrate_gvt1_state_v1; then echo '[FAIL] ignored fallback lock'; exit 1; fi
[ ! -e "$MARKER" ]
cmp "$TMP/original" "$Z2K_STATE_FALLBACK"
rm "$Z2K_STATE_FALLBACK.lock"
_z2k_migrate_gvt1_state_v1
[ -f "$MARKER" ]
for f in "$STATE" "$STATE".pre-* "$Z2K_STATE_FALLBACK" "$Z2K_STATE_FALLBACK".pre-*; do cmp "$TMP/expected" "$f"; done
# done marker really prevents another pass.
printf 'quic\tgvt1.com|4\t1\t400\tauto\t\n' >> "$STATE"
cp "$STATE" "$TMP/once"
_z2k_migrate_gvt1_state_v1
cmp "$TMP/once" "$STATE"
echo '[PASS] gvt1 migration all pools/snapshots/lock/idempotence'
