#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^_z2k_migrate_rotator_sld\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/migrate.sh"
. "$TMP/migrate.sh"
ZAPRET_BASE=$TMP/base
Z2K_STATE_FALLBACK=$TMP/fallback.tsv
export ZAPRET_BASE Z2K_STATE_FALLBACK
mkdir -p "$ZAPRET_BASE/extra_strats/cache/autocircular"
STATE=$ZAPRET_BASE/extra_strats/cache/autocircular/state.tsv
printf 'rkn_tcp\tapi.discord.com|4\t2\t100\tfrozen\tgood.example\nrkn_tcp\tcdn.discord.com|4\t4\t200\tauto\t\nrkn_tcp\tapi.discord.com|6\t5\t110\tauto\t\nquic\tcdn.discord.com|4\t3\t200\tauto\t\ndiscord_udp\tnohost\t1\t200\tfrozen\t\nrkn_tcp\t1.2.3.4|4\t1\t200\tauto\t\n' > "$STATE"
printf 'rkn_tcp\twww.discord.com|4\t6\t150\tfrozen\tnew.example\n' > "$Z2K_STATE_FALLBACK"
cp "$STATE" "$TMP/original"
_z2k_migrate_rotator_sld
awk -F '\t' '$1=="rkn_tcp" && $2=="discord.com|4" && $3==6 && $5=="frozen" && $6=="new.example" {ok=1} END{exit !ok}' "$STATE"
[ "$(awk '!/^#/ && NF{n++} END{print n}' "$STATE")" = 5 ]
cmp "$STATE" "$Z2K_STATE_FALLBACK"
cmp "$TMP/original" "$STATE.pre-86.2"
grep -q '1.2.3.4|4' "$STATE"
cp "$STATE" "$TMP/once"
_z2k_migrate_rotator_sld
cmp "$TMP/once" "$STATE"
# A lock held by the panel must prevent both migration and completion marker.
rm "$ZAPRET_BASE/state/domain-sld-v1.done"
printf '%s' "$(date +%s)" > "$STATE.lock"
if _z2k_migrate_rotator_sld; then echo '[FAIL] ignored state lock'; exit 1; fi
[ ! -e "$ZAPRET_BASE/state/domain-sld-v1.done" ]
cmp "$TMP/once" "$STATE"
# Exercise the real startup order: preparation must not erase the panel lock,
# and a failed migration must not launch either standard or custom daemons.
awk '/^ensure_autocircular_files\(\)/,/^}/; /^start_daemons\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/start.sh"
. "$TMP/start.sh"
z2k_daemon_fail_reset() { :; }
standard_mode_daemons() { touch "$TMP/started"; }
custom_runner() { touch "$TMP/started"; }
if start_daemons; then echo '[FAIL] startup accepted failed migration'; exit 1; fi
[ ! -e "$TMP/started" ]
[ -f "$STATE.lock" ]
cmp "$TMP/once" "$STATE"
# A stale timestamp can be recovered; a running old daemon cannot be migrated.
printf '1' > "$STATE.lock"
PIDDIR=$TMP/pids; mkdir -p "$PIDDIR"
printf '%s' "$$" > "$PIDDIR/nfqws2_test.pid"
if _z2k_migrate_rotator_sld; then echo '[FAIL] migrated a running daemon'; exit 1; fi
rm "$PIDDIR/nfqws2_test.pid"
_z2k_migrate_rotator_sld
[ -f "$ZAPRET_BASE/state/domain-sld-v1.done" ]
rm "$ZAPRET_BASE/state/domain-sld-v1.done"
: > "$STATE.lock"
_z2k_migrate_rotator_sld
[ ! -e "$STATE.lock" ]
[ -f "$ZAPRET_BASE/state/domain-sld-v1.done" ]
printf '[PASS] merge keeps frozen strategy, family, pool, IP, SNI, backup and lock; idempotent\nPASSED: 1\nFAILED: 0\n'
