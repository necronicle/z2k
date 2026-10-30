#!/bin/sh
# tests/test_state_pool_renumber_v3.sh
#
# 30.10.2026: пул rkn собран заново — прежние плечи сняты все, на их месте
# референсные наборы один в один. Номер в state.tsv указывает на плечо, которого
# больше нет, — у автоматической записи и у замороженной одинаково. Поэтому
# init стирает все строки rkn_tcp до подъёма демона, и хост подбирает плечо
# заново с первого. Остальные пулы не трогаются; v1 и v2 идут раньше.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^_z2k_migrate_pool_renumber(_v[0-9]+)?\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/migrate.sh"
. "$TMP/migrate.sh"
ZAPRET_BASE=$TMP/base
Z2K_STATE_FALLBACK=$TMP/fallback.tsv
export ZAPRET_BASE Z2K_STATE_FALLBACK
mkdir -p "$ZAPRET_BASE/extra_strats/cache/autocircular"
STATE=$ZAPRET_BASE/extra_strats/cache/autocircular/state.tsv
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }
check() { # check <desc> <key> <host> <expected strategy or ABSENT>
    if [ "$4" = ABSENT ]; then
        if awk -F'\t' -v k="$2" -v h="$3" '$1==k && $2==h {f=1} END{exit f}' "$STATE"; then ok "$1"; else no "$1"; fi
    else
        if awk -F'\t' -v k="$2" -v h="$3" -v s="$4" '$1==k && $2==h && $3==s {f=1} END{exit !f}' "$STATE"; then ok "$1"; else no "$1"; fi
    fi
}
{
printf '# z2k autocircular state (persisted circular nstrategy)\n# key\thost\tstrategy\tts\tmode\tsni\n'
printf 'rkn_tcp\tauto.example|4\t7\t100\tauto\t\n'
printf 'rkn_tcp\tfrozen.example|4\t31\t100\tfrozen\twww.sferum.ru\n'
printf 'yt_tcp\tyt.example|4\t5\t100\tauto\t\n'
printf 'gv_tcp\tgv.example|4\t3\t100\tfrozen\t\n'
printf 'quic\tq.example|4\t2\t100\tauto\t\n'
printf 'discord_udp\tnohost\t2\t100\tauto\t\n'
} > "$STATE"
cp "$STATE" "$TMP/original"
printf '# z2k autocircular state\nrkn_tcp\tfb.example|4\t12\t100\tauto\t\n' > "$Z2K_STATE_FALLBACK"
# v1 и v2 уже прошли на этом роутере (p-87.x).
mkdir -p "$ZAPRET_BASE/state"
: > "$ZAPRET_BASE/state/pool-renumber-v1.done"
: > "$ZAPRET_BASE/state/pool-renumber-v2.done"

_z2k_migrate_pool_renumber_v1
_z2k_migrate_pool_renumber_v2
_z2k_migrate_pool_renumber_v3
check "rkn auto row erased"       rkn_tcp 'auto.example|4'   ABSENT
check "rkn frozen row erased"     rkn_tcp 'frozen.example|4' ABSENT
check "yt untouched"              yt_tcp  'yt.example|4'     5
check "gv untouched"              gv_tcp  'gv.example|4'     3
check "quic untouched"            quic    'q.example|4'      2
check "discord voice untouched"   discord_udp nohost         2
if grep -q '^# key' "$STATE"; then ok "header kept"; else no "header kept"; fi
if awk -F'\t' '$1=="rkn_tcp" {f=1} END{exit f}' "$Z2K_STATE_FALLBACK"; then ok "fallback file migrated too"; else no "fallback file migrated too"; fi
if cmp -s "$TMP/original" "$STATE.pre-renumber-v3"; then ok "pre-migration snapshot kept"; else no "pre-migration snapshot kept"; fi
if [ -f "$ZAPRET_BASE/state/pool-renumber-v3.done" ]; then ok "v3 done marker written"; else no "v3 done marker written"; fi
cp "$STATE" "$TMP/once"
printf 'rkn_tcp\tlater.example|4\t3\t200\tauto\t\n' >> "$STATE"
_z2k_migrate_pool_renumber_v3
check "after marker new rkn rows survive" rkn_tcp 'later.example|4' 3

# Свежий роутер с p-86.23: v1 и v2 ещё не прошли — цепочка заканчивается тем же.
rm -rf "$ZAPRET_BASE/state" "$STATE".* "$Z2K_STATE_FALLBACK".*
printf '# z2k autocircular state\nrkn_tcp\told.example|4\t10\t100\tfrozen\t\nquic\tq.example|4\t7\t100\tfrozen\t\n' > "$STATE"
: > "$Z2K_STATE_FALLBACK"
_z2k_migrate_pool_renumber_v1
_z2k_migrate_pool_renumber_v2
_z2k_migrate_pool_renumber_v3
check "chain v1..v3: rkn erased"  rkn_tcp 'old.example|4'    ABSENT
check "chain v1..v3: quic 7 -> 14 -> 15" quic 'q.example|4'  15

# Файл только из строк rkn и без заголовка: после стирания пусто, но перенос
# обязан состояться (пустой результат — законный), иначе строки останутся навсегда.
rm -rf "$ZAPRET_BASE/state" "$STATE".* "$Z2K_STATE_FALLBACK".*
printf 'rkn_tcp\tonly.example|4\t4\t100\tauto\t\n' > "$STATE"
: > "$Z2K_STATE_FALLBACK"
_z2k_migrate_pool_renumber_v3
check "rkn-only file: row erased" rkn_tcp 'only.example|4' ABSENT

# Миграция вызывается из init после v2.
if awk '/_z2k_migrate_pool_renumber_v2$/{v2=NR} /_z2k_migrate_pool_renumber_v3$/{v3=NR} END{exit !(v2 && v3 > v2)}' "$ROOT/files/S99zapret2.new"; then
    ok "init calls v3 after v2"; else no "init calls v3 after v2"; fi

printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
