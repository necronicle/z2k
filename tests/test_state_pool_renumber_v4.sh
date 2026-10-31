#!/bin/sh
# tests/test_state_pool_renumber_v4.sh
#
# 31.10.2026: пул quic пересобран из QUIC-страт референсного набора один в один
# (10 плеч вместо 18). state.tsv помнит НОМЕР плеча, поэтому init переносит
# номера до подъёма демона: автоматические записи стираются — порядок другой,
# хост начинает подбор с первого плеча; замороженные человеком переносятся туда,
# где стоит та же техника, а замороженные на снятом плече стираются — номер
# указывал бы на чужую технику.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^_z2k_migrate_pool_renumber(_v[0-9]+)?\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/migrate.sh"
. "$TMP/migrate.sh"
ZAPRET_BASE=$TMP/base
Z2K_STATE_FALLBACK=$TMP/fallback.tsv
export ZAPRET_BASE Z2K_STATE_FALLBACK
mkdir -p "$ZAPRET_BASE/extra_strats/cache/autocircular" "$ZAPRET_BASE/state"
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
for v in v1 v2 v3; do : > "$ZAPRET_BASE/state/pool-renumber-$v.done"; done
{
printf '# z2k autocircular state (persisted circular nstrategy)\n# key\thost\tstrategy\tts\tmode\tsni\n'
printf 'quic\tf18.example|4\t18\t100\tfrozen\tya.ru\n'
printf 'quic\tf1.example|4\t1\t100\tfrozen\t\n'
printf 'quic\tf15.example|4\t15\t100\tfrozen\t\n'
printf 'quic\tf2.example|4\t2\t100\tfrozen\t\n'
printf 'quic\ta6.example|4\t6\t100\tauto\t\n'
printf 'rkn_tcp\tr.example|4\t5\t100\tauto\t\n'
printf 'discord_udp\tnohost\t2\t100\tauto\t\n'
} > "$STATE"
cp "$STATE" "$TMP/original"
printf '# z2k autocircular state\nquic\tfb.example|4\t11\t100\tfrozen\t\n' > "$Z2K_STATE_FALLBACK"

_z2k_migrate_pool_renumber_v4

check "замороженное 18 (google x6 + send/drop) -> 1"  quic 'f18.example|4' 1
check "замороженное 1 (google x11 + send/drop) -> 2"  quic 'f1.example|4'  2
check "замороженное 15 (udplen 25) -> 8"              quic 'f15.example|4' 8
check "замороженное на снятом плече 2 стёрто"         quic 'f2.example|4'  ABSENT
check "автоматическое стёрто"                         quic 'a6.example|4'  ABSENT
check "rkn не тронут"                                 rkn_tcp 'r.example|4' 5
check "голос не тронут"                               discord_udp nohost 2
if awk -F'\t' '$2=="f18.example|4" && $5=="frozen" && $6=="ya.ru" {f=1} END{exit !f}' "$STATE"; then ok "режим и имя заморозки сохранены"; else no "режим и имя заморозки сохранены"; fi
if awk -F'\t' '$1=="quic" && $2=="fb.example|4" && $3==10 {f=1} END{exit !f}' "$Z2K_STATE_FALLBACK"; then ok "запасной файл перенесён тоже"; else no "запасной файл перенесён тоже"; fi
if cmp -s "$TMP/original" "$STATE.pre-renumber-v4"; then ok "снимок до переноса рядом"; else no "снимок до переноса рядом"; fi
if [ -f "$ZAPRET_BASE/state/pool-renumber-v4.done" ]; then ok "отметка v4 поставлена"; else no "отметка v4 поставлена"; fi
cp "$STATE" "$TMP/once"
_z2k_migrate_pool_renumber_v4
if cmp -s "$TMP/once" "$STATE"; then ok "повторный прогон под отметкой ничего не меняет"; else no "повторный прогон под отметкой ничего не меняет"; fi

# Таблица обязана соответствовать пулу: покрывает все 18 старых номеров, ведёт в 1..10.
ARGS=$(awk '/^\[quic_autocircular\]/{a=1;next} a && /^args=/{print;exit}' "$ROOT/quic_strats.ini")
max=$(printf '%s' "$ARGS" | grep -o ':strategy=[0-9]*' | sed 's/.*=//' | sort -n | tail -1)
[ "$max" = 10 ] && ok "в пуле quic 10 плеч" || no "в пуле quic 10 плеч (got $max)"
MAP=$(awk "/^_z2k_migrate_pool_renumber_v4/,/^}/" "$ROOT/files/S99zapret2.new" | grep -o "local quic_map='[^']*'" | sed "s/.*='//;s/'//")
olds=$(printf '%s' "$MAP" | tr ',' '\n' | cut -d= -f1 | sort -n | tr '\n' ' ')
[ "$olds" = "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 " ] && ok "таблица покрывает все 18 старых номеров" || no "таблица покрывает все 18 старых номеров ($olds)"
mx=$(printf '%s' "$MAP" | tr ',' '\n' | cut -d= -f2 | grep -v x | sort -n | tail -1)
[ "$mx" = 10 ] && ok "таблица ведёт в 1..10" || no "таблица ведёт в 1..10 (max $mx)"
if awk '/_z2k_migrate_pool_renumber_v3$/{v3=NR} /_z2k_migrate_pool_renumber_v4$/{v4=NR} END{exit !(v3 && v4 > v3)}' "$ROOT/files/S99zapret2.new"; then
    ok "init вызывает v4 после v3"; else no "init вызывает v4 после v3"; fi

printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
