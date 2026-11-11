#!/bin/sh
# Execute the shipped migration on the owner's out30 sample, without live state.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
awk '/^_z2k_migrate_gv_named_state_v1\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/migrate.sh"
. "$TMP/migrate.sh"
ZAPRET_BASE=$TMP/install
Z2K_STATE_FALLBACK=$TMP/fallback.tsv
export ZAPRET_BASE Z2K_STATE_FALLBACK
mkdir -p "$ZAPRET_BASE/extra_strats/cache/autocircular"
STATE=$ZAPRET_BASE/extra_strats/cache/autocircular/state.tsv
MARKER=$ZAPRET_BASE/state/gv-named-state-v1.done
cp "${1:-$ROOT/tests/fixtures/gv_state_all.tsv}" "$STATE"
[ "$(wc -l < "$STATE" | tr -d ' ')" = 164 ]
cat >> "$STATE" <<'EOF'
gv_tcp	192.0.2.1|4	3	123	frozen	pinned.example
gv_tcp	2001:db8::1|6	4	124	frozen	
gv_tcp	other.example|6	5	125	frozen	
rkn_tcp	192.0.2.2|4	2	126	auto	
gv_tcp	legacy.example|4	1	127
EOF
cp "$STATE" "$Z2K_STATE_FALLBACK"
cp "$STATE" "$TMP/original"
cat > "$TMP/expected" <<'EOF'
gv_tcp	googlevideo.com|4	7	1794347895	auto	
gv_tcp	googlevideo.com|6	2	1794300663	auto	
gv_tcp	youtube.com|4	1	1794347950	auto	
gv_tcp	youtube.com|6	1	1794347683	auto	
gv_tcp	192.0.2.1|4	3	123	frozen	pinned.example
gv_tcp	2001:db8::1|6	4	124	frozen	
gv_tcp	other.example|6	5	125	frozen	
rkn_tcp	192.0.2.2|4	2	126	auto	
EOF
# A held primary lock prevents completion and leaves it untouched.
printf '%s' "$(date +%s)" > "$STATE.lock"
if _z2k_migrate_gv_named_state_v1; then echo '[FAIL] ignored primary lock'; exit 1; fi
[ ! -e "$MARKER" ]
cmp "$TMP/original" "$STATE"
# Exercise startup's failure gate before either daemon mode can be spawned.
awk '/^start_daemons\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/start.sh"
. "$TMP/start.sh"
_z2k_migrate_gv_named_state_v2() { _z2k_migrate_gv_named_state_v1; }
z2k_daemon_fail_reset() { :; }
ensure_autocircular_files() { :; }
_z2k_migrate_rotator_sld() { :; }
standard_mode_daemons() { touch "$TMP/started"; }
custom_runner() { touch "$TMP/started"; }
if start_daemons; then echo '[FAIL] startup accepted migration failure'; exit 1; fi
[ ! -e "$TMP/started" ]
rm "$STATE.lock"
# A held fallback lock allows partial progress, never a completion marker.
cp "$TMP/original" "$Z2K_STATE_FALLBACK"
printf '%s' "$(date +%s)" > "$Z2K_STATE_FALLBACK.lock"
if _z2k_migrate_gv_named_state_v1; then echo '[FAIL] ignored fallback lock'; exit 1; fi
[ ! -e "$MARKER" ]
cmp "$TMP/original" "$Z2K_STATE_FALLBACK"
rm "$Z2K_STATE_FALLBACK.lock"
_z2k_migrate_gv_named_state_v1
[ -f "$MARKER" ]
sort "$TMP/expected" > "$TMP/expected.sorted"
sort "$STATE" > "$TMP/actual.sorted"
cmp "$TMP/expected.sorted" "$TMP/actual.sorted"
cmp "$STATE" "$Z2K_STATE_FALLBACK"
cmp "$TMP/original" "$STATE.pre-gv-named-v1"
cmp "$TMP/original" "$Z2K_STATE_FALLBACK.pre-gv-named-v1"
cp "$STATE" "$TMP/once"
_z2k_migrate_gv_named_state_v1
cmp "$TMP/once" "$STATE"
cmp "$TMP/once" "$Z2K_STATE_FALLBACK"
# A snapshot from an interrupted attempt cannot suppress filtering on retry.
rm "$MARKER"
cp "$TMP/original" "$STATE"
_z2k_migrate_gv_named_state_v1
cmp "$TMP/once" "$STATE"
cmp "$TMP/original" "$STATE.pre-gv-named-v1"
# Removing every row is valid; empty output must not be treated as failure.
rm "$MARKER"
printf 'gv_tcp\t192.0.2.9|4\t1\t100\tauto\n' > "$STATE"
_z2k_migrate_gv_named_state_v1
[ ! -s "$STATE" ]
[ -f "$MARKER" ]
# Startup runs SLD normalization first: c.youtube.com is a valid GV service,
# and must become youtube.com rather than be discarded as an unrelated name.
awk '/^_z2k_migrate_rotator_sld\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/sld.sh"
. "$TMP/sld.sh"
PIDDIR=$TMP/pids
mkdir -p "$PIDDIR"
rm "$MARKER" "$Z2K_STATE_FALLBACK"
printf 'gv_tcp\tc.youtube.com|6\t3\t100\tauto\n' > "$STATE"
_z2k_migrate_rotator_sld
_z2k_migrate_gv_named_state_v1
printf 'gv_tcp\tyoutube.com|6\t3\t100\tauto\n' > "$TMP/normalized"
sed '/^#/d' "$STATE" > "$TMP/service"
cmp "$TMP/normalized" "$TMP/service"
printf '[PASS] GV sample: 160 auto rows removed; four service keys and frozen retained; locks, fallback, snapshots, retries and empty output\n'
