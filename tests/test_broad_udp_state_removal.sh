#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT HUP INT TERM
ZAPRET_BASE="$T/base"; EXTRA_STRATS_DIR="$ZAPRET_BASE/extra_strats"; Z2K_STATE_FALLBACK="$T/fallback.tsv"
mkdir -p "$ZAPRET_BASE/state" "$EXTRA_STRATS_DIR/cache/autocircular"
eval "$(awk '/^_z2k_migrate_broad_udp_removal_v1\(\)/,/^}/' files/S99zapret2.new)"
command -v _z2k_migrate_broad_udp_removal_v1 >/dev/null || { echo 'FAIL: retirement migration missing'; exit 1; }
state="$EXTRA_STRATS_DIR/cache/autocircular/state.tsv"
printf '# header\nrkn_tcp\tx|4\t3\t10\tfrozen\tx\nmy_pool\tx|4\t1\t10\tauto\tx\n' > "$T/expected"
cat "$T/expected" > "$state"
for key in udp_misc circular_2_1 circular_7_1 circular_8_1 circular_99_12; do printf '%s\tx|4\t2\t10\tfrozen\tx\n' "$key" >> "$state"; done
cp "$state" "$Z2K_STATE_FALLBACK"; cp "$state" "$state.pre-renumber-v1"; cp "$state" "$Z2K_STATE_FALLBACK.pre-client-role-v1"
_z2k_migrate_broad_udp_removal_v1
for f in "$state" "$Z2K_STATE_FALLBACK" "$state".pre-* "$Z2K_STATE_FALLBACK".pre-*; do cmp "$f" "$T/expected"; done
[ -f "$ZAPRET_BASE/state/broad-udp-removal-v1.done" ]
_z2k_migrate_broad_udp_removal_v1
# Restored snapshots must not resurrect retired rows even with .done.
printf 'circular_3_1\tx|4\t2\t10\tauto\tx\n' >> "$state.pre-renumber-v1"
_z2k_migrate_broad_udp_removal_v1
cmp "$state.pre-renumber-v1" "$T/expected"
# A live persistence writer blocks migration; marker must not claim success.
date +%s > "$state.lock"
if _z2k_migrate_broad_udp_removal_v1; then exit 1; fi
[ ! -f "$ZAPRET_BASE/state/broad-udp-removal-v1.done" ]; rm "$state.lock"
_z2k_migrate_broad_udp_removal_v1
# A crashed persistence writer must not block service startup forever.
printf '1' > "$state.lock"
_z2k_migrate_broad_udp_removal_v1
[ ! -f "$state.lock" ]
. tests/lib/common.sh
printf 'partial-write' > "$state.lock"
if z2k_backdate "$state.lock" 200001010000; then
    _z2k_migrate_broad_udp_removal_v1
    [ ! -f "$state.lock" ]
else
    rm -f "$state.lock"
fi
# Manual profiles need the same protection as custom strategy files.
NFQWS2_OPT='--filter-tcp=443 --lua-desync=circular:fails=2 --lua-desync=fake'
cp "$state" "$T/before-manual"
if _z2k_migrate_broad_udp_removal_v1; then exit 1; fi
cmp "$state" "$T/before-manual"
[ ! -f "$ZAPRET_BASE/state/broad-udp-removal-v1.done" ]
unset NFQWS2_OPT
# Unnamed user pools make historical positional attribution ambiguous: preserve
# them and require a retry after explicit attribution, rather than delete them.
mkdir -p "$ZAPRET_BASE/lists/custom-strategies"
printf '%s\n' '--lua-desync=circular:fails=2 --lua-desync=fake' > "$ZAPRET_BASE/lists/custom-strategies/rkn_tcp.txt"
cp "$state" "$T/before-ambiguous"
if _z2k_migrate_broad_udp_removal_v1; then exit 1; fi
cmp "$state" "$T/before-ambiguous"
[ ! -f "$ZAPRET_BASE/state/broad-udp-removal-v1.done" ]
# getopt also accepts a separate option argument in inactive custom pools.
printf '%s\n' '--lua-desync circular:fails=2 --lua-desync fake' > "$ZAPRET_BASE/lists/custom-strategies/rkn_tcp.txt"
if _z2k_migrate_broad_udp_removal_v1; then exit 1; fi
cmp "$state" "$T/before-ambiguous"
printf 'state removal: primary/fallback/snapshots, frozen fields, retry and idempotence OK\n'
