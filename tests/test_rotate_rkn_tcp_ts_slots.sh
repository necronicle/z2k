#!/bin/sh
# tests/test_rotate_rkn_tcp_ts_slots.sh — значения tcp_ts живут в пуле, а не в
# таблице слотов генератора.
#
# ЧТО БЫЛО. Генератор находил токены с выгоревшим `tcp_ts=-1000` и подставлял
# альтернативные значения по таблице «номер стратегии → значение» из
# четырнадцати слотов. Связь держалась на ПОРЯДКЕ стратегий в пуле: любая
# вставка или перестановка молча уводила значения на чужие стратегии. Именно
# так однажды и вышло — strategy=37 (hostfakesplit host=ozon.ru) прикусила
# браузер. К моменту снятия пять слотов таблицы уже указывали в пустоту:
# токенов с такими номерами в пуле не осталось.
#
# ЧТО СТАЛО. Значения записаны прямо в пул (strats_new2.txt, манифест rkn) и
# доезжают до Strategy.txt как есть. Генератор их не трогает вообще.
# Сгенерированный NFQWS2_OPT при снятии не изменился ни на байт, а поведение
# проверено на живом роутере: девять затронутых стратегий по отдельности дают
# на meduza.io ровно тот же результат, что и до правки.
#
# ЧТО ОХРАНЯЕТСЯ ЗДЕСЬ:
#
#   1. В генераторе больше нет ни функции ротации, ни карты номеров — иначе
#      мина вернётся вместе с ними.
#   2. В пуле rkn tcp_ts только -600000 — умолчание nfqws1 из первоисточников
#      (пул собран заново 30.10.2026); своё значение на плече — возврат
#      разнесения по слотам.
#   3. Генератор оставляет tcp_ts как в пуле.
#
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0

ok()  { TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"; }
no()  { TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s (want=%s got=%s)\n" "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CFG="$ROOT/lib/config_official.sh"
POOLS="$ROOT/strats_new2.txt"
for f in "$CFG" "$POOLS"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

# Строка манифеста РКН — та, что уезжает в extra_strats/TCP/RKN/Strategy.txt
# (lib/strategies.sh: rkn=1).
RKN_LINE=$(grep '^manual_autocircular_rkn' "$POOLS" | head -1)
[ -n "$RKN_LINE" ] || { printf '[FAIL] в пуле нет строки manual_autocircular_rkn\n'; exit 1; }

# --- 1. Ротации в генераторе больше нет --------------------------------------
if grep -q 'rotate_rkn_tcp_ts_slots' "$CFG"; then
    no "функция ротации снята" "нет упоминаний" "ещё в генераторе"
else
    ok "функция ротации снята из генератора"
fi
# Карта номеров — вторая половина той же мины. Ищем характерную пару
# «номер) new_ts=».
if grep -qE '^[[:space:]]*[0-9]+\)[[:space:]]*new_ts=' "$CFG"; then
    no "карта номер→значение снята" "нет" "карта ещё на месте"
else
    ok "карта «номер стратегии → значение» снята"
fi

# --- 2. Значения tcp_ts в пуле — из первоисточников ---------------------------
#
# 30.10.2026 пул rkn собран заново из референсных наборов один в один, и
# таблица, и её разнесённые по слотам значения ушли вместе с прежними плечами.
# Фулинг ts в плечах winws — это умолчание nfqws1 -600000, у плеч nfqws2 tcp_ts
# не встречается. Своё значение на одном плече — признак, что разнесение
# вернулось и плечо разошлось с первоисточником.
_vals=$(printf '%s' "$RKN_LINE" | tr ' :' '\n\n' | grep '^tcp_ts=' | sort -u | tr '\n' ' ')
if [ "$_vals" = "tcp_ts=-600000 " ]; then
    ok "в пуле rkn tcp_ts только -600000 (умолчание nfqws1)"
else
    no "в пуле rkn tcp_ts только -600000" "tcp_ts=-600000" "$_vals"
fi

# --- 5. Генератор больше не переписывает tcp_ts ------------------------------
#
# Прямая проверка на поведении: кладём в пул-подделку стратегию с -1000 на
# «слотовом» номере и убеждаемся, что на выходе он таким и остался.
# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$CFG" >/dev/null 2>&1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/extra_strats/TCP/RKN" "$TMP/extra_strats/TCP/YT" \
         "$TMP/extra_strats/TCP/YT_GV" "$TMP/extra_strats/UDP/YT" "$TMP/lists"
echo rutracker.org > "$TMP/extra_strats/TCP/RKN/List.txt"
echo w > "$TMP/lists/whitelist.txt"
printf '%s\n' '--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:time=60:key=rkn_tcp --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:tcp_ts=-1000:strategy=11' \
    > "$TMP/extra_strats/TCP/RKN/Strategy.txt"
: > "$TMP/config"
OUT=$( ZAPRET2_DIR="$TMP" generate_nfqws2_opt_from_strategies 2>/dev/null )
case "$OUT" in
    *tcp_ts=-1000*) ok "генератор оставляет tcp_ts как в пуле" ;;
    *) no "генератор не переписывает tcp_ts" "-1000 доехало как есть" "переписано — таблица вернулась" ;;
esac

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
[ "$TESTS_FAILED" -eq 0 ]
