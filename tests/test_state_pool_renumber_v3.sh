#!/bin/sh
# tests/test_state_pool_renumber_v3.sh
#
# 30.10.2026: все три TCP-пула переставлены по замеру на линии владельца
# (rkn 57, yt 41, gv 39 плеч; контроль без обхода 0 с двух концов, лидеры
# перемерены отдельно). state.tsv помнит НОМЕР плеча, поэтому init переносит
# номера до подъёма демона: автоматические записи стираются — номер, подобранный
# в прежнем порядке, это не лучшее плечо, а след прежнего перебора, и хост
# начинает подбор с первого, лучшего; замороженные человеком переносятся по
# таблицам, его выбор техники сохраняется.
#
# Слитый профиль google_tls (Z2K_REFACTOR_PHASE3=1) держит yt как 1..33 и gv как
# 33+n: половины переносятся своими таблицами, gv сдвигается на новый размер yt.
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
check() { # check <desc> <key> <host> <ожидаемый номер|ABSENT>
    if [ "$4" = ABSENT ]; then
        if awk -F'\t' -v k="$2" -v h="$3" '$1==k && $2==h {f=1} END{exit f}' "$STATE"; then ok "$1"; else no "$1"; fi
    else
        if awk -F'\t' -v k="$2" -v h="$3" -v s="$4" '$1==k && $2==h && $3==s {f=1} END{exit !f}' "$STATE"; then ok "$1"; else no "$1"; fi
    fi
}
seed() {
{
printf '# z2k autocircular state (persisted circular nstrategy)\n# key\thost\tstrategy\tts\tmode\tsni\n'
printf 'rkn_tcp\tfrozen28.example|4\t28\t100\tfrozen\tya.ru\n'
printf 'rkn_tcp\tfrozen1.example|4\t1\t100\tfrozen\t\n'
printf 'rkn_tcp\tauto5.example|4\t5\t100\tauto\t\n'
printf 'yt_tcp\tfrozen6.example|4\t6\t100\tfrozen\t\n'
printf 'yt_tcp\tauto1.example|4\t1\t100\tauto\t\n'
printf 'gv_tcp\tfrozen24.example|4\t24\t100\tfrozen\t\n'
printf 'gv_tcp\tauto2.example|4\t2\t100\tauto\t\n'
printf 'google_tls\tytpart.example|4\t6\t100\tfrozen\t\n'
printf 'google_tls\tgvpart.example|4\t57\t100\tfrozen\t\n'
printf 'google_tls\tauto9.example|4\t9\t100\tauto\t\n'
printf 'quic\tq.example|4\t3\t100\tauto\t\n'
printf 'discord_udp\tnohost\t2\t100\tauto\t\n'
} > "$STATE"
}
mkdir -p "$ZAPRET_BASE/state"
: > "$ZAPRET_BASE/state/pool-renumber-v1.done"
: > "$ZAPRET_BASE/state/pool-renumber-v2.done"
seed; cp "$STATE" "$TMP/original"
printf '# z2k autocircular state\nrkn_tcp\tfb.example|4\t21\t100\tfrozen\t\n' > "$Z2K_STATE_FALLBACK"

_z2k_migrate_pool_renumber_v1
_z2k_migrate_pool_renumber_v2
_z2k_migrate_pool_renumber_v3

check "rkn: замороженное 28 -> 1 (лучшее по замеру)" rkn_tcp 'frozen28.example|4' 1
check "rkn: замороженное 1 -> 36"                    rkn_tcp 'frozen1.example|4'  36
check "rkn: автоматическое стёрто"                   rkn_tcp 'auto5.example|4'    ABSENT
check "yt: замороженное 6 -> 1"                      yt_tcp  'frozen6.example|4'  1
check "yt: автоматическое стёрто"                    yt_tcp  'auto1.example|4'    ABSENT
check "gv: замороженное 24 -> 1"                     gv_tcp  'frozen24.example|4' 1
check "gv: автоматическое стёрто"                    gv_tcp  'auto2.example|4'    ABSENT
check "google_tls: половина yt, 6 -> 1"              google_tls 'ytpart.example|4' 1
check "google_tls: половина gv, 57 (=gv 24) -> 41+1" google_tls 'gvpart.example|4' 42
check "google_tls: автоматическое стёрто"            google_tls 'auto9.example|4'  ABSENT
check "quic не тронут"                               quic    'q.example|4'        3
check "голос не тронут"                              discord_udp nohost           2
if awk -F'\t' '$2=="frozen28.example|4" && $5=="frozen" && $6=="ya.ru" {f=1} END{exit !f}' "$STATE"; then ok "режим и имя заморозки сохранены"; else no "режим и имя заморозки сохранены"; fi
if awk -F'\t' '$1=="rkn_tcp" && $2=="fb.example|4" && $3==2 {f=1} END{exit !f}' "$Z2K_STATE_FALLBACK"; then ok "запасной файл перенесён тоже"; else no "запасной файл перенесён тоже"; fi
if cmp -s "$TMP/original" "$STATE.pre-renumber-v3"; then ok "снимок до переноса рядом"; else no "снимок до переноса рядом"; fi
if [ -f "$ZAPRET_BASE/state/pool-renumber-v3.done" ]; then ok "отметка v3 поставлена"; else no "отметка v3 поставлена"; fi
cp "$STATE" "$TMP/once"
_z2k_migrate_pool_renumber_v3
if cmp -s "$TMP/once" "$STATE"; then ok "повторный прогон под отметкой ничего не меняет"; else no "повторный прогон под отметкой ничего не меняет"; fi

# Таблицы обязаны соответствовать пулам: максимум нового номера = размер пула.
for p in rkn:57 yt:41 gv:39; do
    k=${p%%:*}; want=${p#*:}
    got=$(grep "key=${k}_tcp" "$ROOT/strats_new2.txt" | grep -o ':strategy=[0-9]*' | sed 's/.*=//' | sort -n | tail -1)
    [ "$got" = "$want" ] && ok "в пуле $k $want плеч" || no "в пуле $k $want плеч (got $got)"
    mx=$(awk "/^_z2k_migrate_pool_renumber_v3/,/^}/" "$ROOT/files/S99zapret2.new" | grep -o "local ${k}_map='[^']*'" | tr ',' '\n' | sed -n 's/.*=\([0-9]*\)$/\1/p' | sort -n | tail -1)
    [ "$mx" = "$want" ] && ok "таблица $k ведёт в 1..$want" || no "таблица $k ведёт в 1..$want (max $mx)"
done
if awk '/_z2k_migrate_pool_renumber_v2$/{v2=NR} /_z2k_migrate_pool_renumber_v3$/{v3=NR} END{exit !(v2 && v3 > v2)}' "$ROOT/files/S99zapret2.new"; then
    ok "init вызывает v3 после v2"; else no "init вызывает v3 после v2"; fi

printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
