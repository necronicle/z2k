#!/bin/sh
# tests/test_state_pool_renumber_v5.sh
#
# 31.10.2026: пул quic — выпущенный набор на 18 плеч, плечи-копии референсных
# страт доведены до точного совпадения, две недостающие дописаны в конец (20).
# p-87.4 по ошибке сократил пул до 10 плеч, и его миграция v4 перевела
# состояние в нумерацию 1..10. Охраняется:
#   * после v4 все десять номеров переезжают на места тех же техник, и
#     автоматические записи тоже — ничего не стирается;
#   * без v4 (p-87.4 не доехал, свежая установка) нумерация уже совпадает с
#     новой, state.tsv не трогается, ставится только отметка;
#   * init больше не вызывает v4.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^_z2k_migrate_pool_renumber(_v[0-9]+)?\(\)/,/^}/' "$ROOT/files/S99zapret2.new" > "$TMP/migrate.sh"
. "$TMP/migrate.sh"
ZAPRET_BASE=$TMP/base
Z2K_STATE_FALLBACK=$TMP/fallback.tsv
export ZAPRET_BASE Z2K_STATE_FALLBACK
STATE=$ZAPRET_BASE/extra_strats/cache/autocircular/state.tsv
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }
check() { # check <desc> <key> <host> <ожидаемый номер>
    if awk -F'\t' -v k="$2" -v h="$3" -v s="$4" '$1==k && $2==h && $3==s {f=1} END{exit !f}' "$STATE"; then ok "$1"; else no "$1"; fi
}
fresh() {
    rm -rf "$ZAPRET_BASE"
    mkdir -p "$ZAPRET_BASE/extra_strats/cache/autocircular" "$ZAPRET_BASE/state"
    for v in v1 v2 v3; do : > "$ZAPRET_BASE/state/pool-renumber-$v.done"; done
    {
    printf '# z2k autocircular state (persisted circular nstrategy)\n# key\thost\tstrategy\tts\tmode\tsni\n'
    printf 'quic\ta1.example|4\t1\t100\tauto\t\n'
    printf 'quic\tf2.example|4\t2\t100\tfrozen\tya.ru\n'
    printf 'quic\ta5.example|4\t5\t100\tauto\t\n'
    printf 'quic\ta10.example|4\t10\t100\tauto\t\n'
    printf 'rkn_tcp\tr.example|4\t5\t100\tauto\t\n'
    printf 'discord_udp\tnohost\t2\t100\tauto\t\n'
    } > "$STATE"
    printf '# z2k autocircular state\nquic\tfb.example|4\t4\t100\tfrozen\t\n' > "$Z2K_STATE_FALLBACK"
}

# --- роутер прошёл v4 (p-87.4): нумерация 1..10 -> места тех же техник ---
fresh
: > "$ZAPRET_BASE/state/pool-renumber-v4.done"
cp "$STATE" "$TMP/original"
_z2k_migrate_pool_renumber_v5
check "после v4: 1 (google x6 + send/drop) -> 18"          quic 'a1.example|4'  18
check "после v4: замороженное 2 (google x11) -> 1"          quic 'f2.example|4'  1
check "после v4: 5 (ipfrag2) -> 19"                          quic 'a5.example|4'  19
check "после v4: 10 (google x8) -> 11"                       quic 'a10.example|4' 11
check "после v4: rkn не тронут"                              rkn_tcp 'r.example|4' 5
check "после v4: голос не тронут"                            discord_udp nohost 2
if awk -F'\t' '$2=="f2.example|4" && $5=="frozen" && $6=="ya.ru" {f=1} END{exit !f}' "$STATE"; then ok "режим и имя заморозки сохранены"; else no "режим и имя заморозки сохранены"; fi
if [ "$(awk -F'\t' '$1=="quic"' "$STATE" | wc -l | tr -d ' ')" = 4 ]; then ok "после v4: ни одна запись quic не стёрта"; else no "после v4: ни одна запись quic не стёрта"; fi
if awk -F'\t' '$1=="quic" && $2=="fb.example|4" && $3==20 {f=1} END{exit !f}' "$Z2K_STATE_FALLBACK"; then ok "запасной файл перенесён тоже (4 -> 20)"; else no "запасной файл перенесён тоже (4 -> 20)"; fi
if cmp -s "$TMP/original" "$STATE.pre-renumber-v5"; then ok "снимок до переноса рядом"; else no "снимок до переноса рядом"; fi
cp "$STATE" "$TMP/once"
_z2k_migrate_pool_renumber_v5
if cmp -s "$TMP/once" "$STATE"; then ok "повторный прогон под отметкой ничего не меняет"; else no "повторный прогон под отметкой ничего не меняет"; fi

# --- роутер без v4: нумерация выпущенного пула совпадает с новой ---
fresh
cp "$STATE" "$TMP/original"
_z2k_migrate_pool_renumber_v5
if cmp -s "$TMP/original" "$STATE"; then ok "без v4: state.tsv не тронут"; else no "без v4: state.tsv не тронут"; fi
if [ -f "$ZAPRET_BASE/state/pool-renumber-v5.done" ]; then ok "без v4: отметка v5 поставлена"; else no "без v4: отметка v5 поставлена"; fi

# --- таблица и вызовы ---
ARGS=$(awk '/^\[quic_autocircular\]/{a=1;next} a && /^args=/{print;exit}' "$ROOT/quic_strats.ini")
max=$(printf '%s' "$ARGS" | grep -o ':strategy=[0-9]*' | sed 's/.*=//' | sort -n | tail -1)
[ "$max" = 20 ] && ok "в пуле quic 20 плеч" || no "в пуле quic 20 плеч (got $max)"
MAP=$(awk "/^_z2k_migrate_pool_renumber_v5/,/^}/" "$ROOT/files/S99zapret2.new" | grep -o "local quic_map='[^']*'" | sed "s/.*='//;s/'//")
olds=$(printf '%s' "$MAP" | tr ',' '\n' | cut -d= -f1 | sort -n | tr '\n' ' ')
[ "$olds" = "1 2 3 4 5 6 7 8 9 10 " ] && ok "таблица покрывает все 10 номеров p-87.4" || no "таблица покрывает все 10 номеров p-87.4 ($olds)"
news=$(printf '%s' "$MAP" | tr ',' '\n' | cut -d= -f2 | sort -n | uniq -d)
[ -z "$news" ] && ok "в таблице нет двух номеров на одно место" || no "в таблице нет двух номеров на одно место ($news)"
if grep -q '^    _z2k_migrate_pool_renumber_v4$' "$ROOT/files/S99zapret2.new"; then no "init больше не вызывает v4"; else ok "init больше не вызывает v4"; fi
if awk '/_z2k_migrate_pool_renumber_v3$/{v3=NR} /_z2k_migrate_pool_renumber_v5$/{v5=NR} END{exit !(v3 && v5 > v3)}' "$ROOT/files/S99zapret2.new"; then
    ok "init вызывает v5 после v3"; else no "init вызывает v5 после v3"; fi

printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
