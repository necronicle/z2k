#!/bin/sh
# tests/test_state_pool_renumber_migration.sh
#
# 23.10.2026: rkn_tcp потерял плечи 10/40/45/46 и получил новые (55), yt_tcp и
# gv_tcp получили одиннадцать новых (33), quic — девять (18); 26.10 все четыре
# пула выстроены по качеству из замера, у yt и gv порядок разный. state.tsv
# хранит НОМЕР плеча, поэтому init переносит номера по полной таблице до
# подъёма демона. Проверяем таблицу на границах, стирание снятых плеч, слитый
# ключ google_tls (каждая половина своей таблицей), quic, голосовой пул
# (25.10: авто стирается, замороженное переносится),
# автоматические записи пулов TCP и QUIC стираются (26.10: пулы переставлены),
# замороженные переносятся; запасной файл в tmpfs, снимок до переноса, идемпотентность и уважение к
# чужому замку.
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
printf 'rkn_tcp\tkeep5.example|4\t5\t100\tfrozen\t\n'
printf 'rkn_tcp\tkeep9.example|4\t9\t100\tfrozen\t\n'
printf 'rkn_tcp\tgone10.example|4\t10\t100\tfrozen\tgone10.example\n'
printf 'rkn_tcp\tshift11.example|4\t11\t100\tfrozen\t\n'
printf 'rkn_tcp\tshift13.example|4\t13\t100\tfrozen\tshift13.example\n'
printf 'rkn_tcp\tshift24.example|4\t24\t100\tfrozen\t\n'
printf 'rkn_tcp\tgone40.example|4\t40\t100\tfrozen\t\n'
printf 'rkn_tcp\tshift44.example|4\t44\t100\tfrozen\t\n'
printf 'rkn_tcp\tgone46.example|4\t46\t100\tfrozen\t\n'
printf 'rkn_tcp\tshift47.example|4\t47\t100\tfrozen\t\n'
printf 'rkn_tcp\tlast50.example|4\t50\t100\tfrozen\t\n'
printf 'yt_tcp\tyt1.example|4\t1\t100\tfrozen\t\n'
printf 'yt_tcp\tyt2.example|4\t2\t100\tfrozen\t\n'
printf 'yt_tcp\tyt11.example|4\t11\t100\tfrozen\t\n'
printf 'yt_tcp\tyt12.example|4\t12\t100\tfrozen\t\n'
printf 'gv_tcp\tgv22.example|4\t22\t100\tfrozen\tgv22.example\n'
printf 'google_tls\tmerged-yt22.example|4\t22\t100\tfrozen\t\n'
printf 'google_tls\tmerged-gv1.example|4\t23\t100\tfrozen\t\n'
printf 'google_tls\tmerged-gv22.example|4\t44\t100\tfrozen\t\n'
printf 'quic\tquic.example|4\t7\t100\tfrozen\t\n'
printf 'discord_udp\tnohost\t4\t100\tauto\t\n'
printf 'rkn_tcp\tauto-rkn_tcp.example|4\t5\t100\tauto\t\n'
printf 'yt_tcp\tauto-yt_tcp.example|4\t2\t100\tauto\t\n'
printf 'gv_tcp\tauto-gv_tcp.example|4\t22\t100\tauto\t\n'
printf 'google_tls\tauto-google_tls.example|4\t23\t100\tauto\t\n'
printf 'quic\tauto-quic.example|4\t7\t100\tauto\t\n'
printf 'discord_udp\tvoice-frozen1\t1\t100\tfrozen\t\n'
printf 'discord_udp\tvoice-frozen3\t3\t100\tfrozen\t\n'
printf 'discord_udp\tvoice-frozen6\t6\t100\tfrozen\t\n'
} > "$STATE"
printf 'rkn_tcp\tfb.example|4\t24\t100\tfrozen\t\n' > "$Z2K_STATE_FALLBACK"
cp "$STATE" "$TMP/original"

_z2k_migrate_pool_renumber_v1

check "rkn 5 -> 17"                           rkn_tcp 'keep5.example|4'   17
check "rkn 9 -> 22"                           rkn_tcp 'keep9.example|4'   22
check "rkn 10 (removed) row erased"           rkn_tcp 'gone10.example|4'  ABSENT
check "rkn 11 -> 30"                          rkn_tcp 'shift11.example|4' 30
check "rkn 13 -> 24"                          rkn_tcp 'shift13.example|4' 24
check "rkn 24 -> 31"                          rkn_tcp 'shift24.example|4' 31
check "rkn 40 (removed) row erased"           rkn_tcp 'gone40.example|4'  ABSENT
check "rkn 44 -> 37"                          rkn_tcp 'shift44.example|4' 37
check "rkn 46 (removed) row erased"           rkn_tcp 'gone46.example|4'  ABSENT
check "rkn 47 -> 39"                          rkn_tcp 'shift47.example|4' 39
check "rkn 50 -> 52"                          rkn_tcp 'last50.example|4'  52
check "yt 1 stays 1"                          yt_tcp  'yt1.example|4'     1
check "yt 2 -> 17"                            yt_tcp  'yt2.example|4'     17
check "yt 11 -> 2"                            yt_tcp  'yt11.example|4'    2
check "yt 12 -> 15"                           yt_tcp  'yt12.example|4'    15
check "gv 22 -> 9 (own table, not yt's)"     gv_tcp  'gv22.example|4'    9
check "google_tls yt part 22 -> 4"            google_tls 'merged-yt22.example|4' 4
check "google_tls gv part 23 (gv 1) -> 36"    google_tls 'merged-gv1.example|4'  36
check "google_tls gv part 44 (gv 22) -> 42"   google_tls 'merged-gv22.example|4' 42
check "quic 7 -> 14"                          quic    'quic.example|4'    14
check "discord auto row erased (new blob, start from 1)" discord_udp nohost ABSENT
check "rkn_tcp auto row erased (pool reordered, start from 1)" rkn_tcp 'auto-rkn_tcp.example|4' ABSENT
check "yt_tcp auto row erased (pool reordered, start from 1)" yt_tcp 'auto-yt_tcp.example|4' ABSENT
check "gv_tcp auto row erased (pool reordered, start from 1)" gv_tcp 'auto-gv_tcp.example|4' ABSENT
check "google_tls auto row erased (pool reordered, start from 1)" google_tls 'auto-google_tls.example|4' ABSENT
check "quic auto row erased (pool reordered, start from 1)" quic 'auto-quic.example|4' ABSENT
check "discord frozen 1 -> 2"                discord_udp voice-frozen1 2
check "discord frozen 3 -> 1 (merged into new first)" discord_udp voice-frozen3 1
check "discord frozen 6 stays 6"             discord_udp voice-frozen6 6
if awk -F'\t' '$2=="shift13.example|4" && $5=="frozen" && $6=="shift13.example" {f=1} END{exit !f}' "$STATE"; then ok "frozen mode and sni preserved"; else no "frozen mode and sni preserved"; fi
if [ "$(head -2 "$STATE" | grep -c '^#')" = 2 ]; then ok "header comments kept"; else no "header comments kept"; fi
if awk -F'\t' '$2=="fb.example|4" && $3==31 {f=1} END{exit !f}' "$Z2K_STATE_FALLBACK"; then ok "fallback file in tmpfs migrated too"; else no "fallback file in tmpfs migrated too"; fi
if cmp -s "$TMP/original" "$STATE.pre-renumber-v1"; then ok "pre-migration snapshot kept"; else no "pre-migration snapshot kept"; fi
if [ -f "$ZAPRET_BASE/state/pool-renumber-v1.done" ]; then ok "done marker written"; else no "done marker written"; fi
if [ ! -e "$STATE.lock" ]; then ok "lock released"; else no "lock released"; fi

# Второй запуск ничего не трогает (иначе номера уехали бы дважды).
cp "$STATE" "$TMP/once"
_z2k_migrate_pool_renumber_v1
if cmp -s "$TMP/once" "$STATE"; then ok "idempotent under marker"; else no "idempotent under marker"; fi

# Чужой замок: не мигрируем и отметку не ставим, попробуем на следующем старте.
rm "$ZAPRET_BASE/state/pool-renumber-v1.done"
cp "$TMP/original" "$STATE"
rm -f "$STATE.pre-renumber-v1"
printf '%s' "$(date +%s)" > "$STATE.lock"
_z2k_migrate_pool_renumber_v1
if cmp -s "$TMP/original" "$STATE"; then ok "foreign lock: state untouched"; else no "foreign lock: state untouched"; fi
if [ ! -e "$ZAPRET_BASE/state/pool-renumber-v1.done" ]; then ok "foreign lock: no marker"; else no "foreign lock: no marker"; fi
if [ -f "$STATE.lock" ]; then ok "foreign lock: lock left to its owner"; else no "foreign lock: lock left to its owner"; fi
# Запасной файл замком не был занят и перенесён в первый же заход; повтор
# после снятия замка обязан перенести основной и НЕ тронуть запасной ещё раз.
rm -f "$STATE.lock"
_z2k_migrate_pool_renumber_v1
if cmp -s "$TMP/once" "$STATE"; then ok "retry after lock release migrates"; else no "retry after lock release migrates"; fi
if awk -F'\t' '$2=="fb.example|4" && $3==31 {f=1} END{exit !f}' "$Z2K_STATE_FALLBACK"; then ok "fallback not migrated twice"; else no "fallback not migrated twice"; fi
if [ -f "$ZAPRET_BASE/state/pool-renumber-v1.done" ]; then ok "marker after full retry"; else no "marker after full retry"; fi

# Таблицы в init обязаны соответствовать реальным пулам: максимум номера.
rkn_max=$(grep 'key=rkn_tcp' "$ROOT/strats_new2.txt" | grep -o ':strategy=[0-9]*' | sed 's/.*=//' | sort -n | tail -1)
yt_max=$(grep 'key=yt_tcp' "$ROOT/strats_new2.txt" | grep -o ':strategy=[0-9]*' | sed 's/.*=//' | sort -n | tail -1)
# Таблица v1 переводит номера в пул rkn из 55 плеч. 30.10.2026 к нему добавлены
# два плеча референсного набора (56, 57) — номеров из таблицы это не касается,
# в неё входят только выпущенные 1..50.
[ "$rkn_max" = 57 ] && ok "rkn pool has 57 arms" || no "rkn pool has 57 arms (got $rkn_max)"
# 30.10.2026: в yt и gv дописаны плечи гугловой строки референсного набора,
# которых у нас не было (yt 34..41, gv 34..39). Таблицы v1 это не касается — в
# неё входят только выпущенные номера.
[ "$yt_max" = 41 ] && ok "yt pool has 41 arms" || no "yt pool has 41 arms (got $yt_max)"
gv_max=$(grep 'key=gv_tcp' "$ROOT/strats_new2.txt" | grep -o ':strategy=[0-9]*' | sed 's/.*=//' | sort -n | tail -1)
[ "$gv_max" = 39 ] && ok "gv pool has 39 arms" || no "gv pool has 39 arms (got $gv_max)"
# Пул quic после v1 пересобирался дважды (v2, v4); его размер против своей
# таблицы проверяет tests/test_state_pool_renumber_v4.sh.

printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
