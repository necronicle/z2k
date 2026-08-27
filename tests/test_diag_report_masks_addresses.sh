#!/bin/sh
# tests/test_diag_report_masks_addresses.sh — файловый отчёт диагностики не
# должен раскрывать адреса НИ В ОДНОЙ секции.
#
# ЗАЧЕМ. Маскировка стояла только в хвостах логов (short_tail), а секция
# «errors across all logs» печатала те же самые строки сырыми. Полевой случай
# 2026-08-22: в отчёте, отправленном в общий чат, адрес релея виден в строке
#
#   [tunnel] регистрация не удалась: Post "https://213.176.74.63.nip.io/register"
#
# из агрегированной секции, тогда как двадцатью строками ниже — в хвосте того
# же самого файла — он уже был замаскирован в x.x.x.x. То есть отчёт сам себе
# противоречил, и половина, которую читают первой, была сырой.
#
# Здесь пинится три вещи:
#   1. в режиме report маскируются ОБЕ секции, а не одна;
#   2. в экранном режиме адреса остаются — там отчёт никуда не уходит, а
#      человеку, который смотрит сам у себя, адреса нужны для разбора;
#   3. маскировка не съедает остальной текст строки (коды, время, причину).
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
. "$ROOT/tests/lib/common.sh"
SRC="${Z2K_DIAG_UNDER_TEST:-$ROOT/files/z2k-diag.sh}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-diagmask.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

[ -f "$SRC" ] || { printf '[FAIL] нет %s\n' "$SRC"; exit 1; }

# --- фикстура: лог ровно той формы, что приехала из поля ---------------------
LOG="$TMP/tg-tunnel.log"
# Дата — ВЧЕРАШНЯЯ, а не зашитая: раздел ошибок с r-80.3 показывает окно в
# несколько суток, и фикстура с фиксированной датой однажды выпала бы из него
# сама собой — тест бы «сломался» без единой правки кода.
_fx=$(z2k_test_stamp 1 | cut -c1-8)
_fx="$(printf '%s' "$_fx" | cut -c1-4)/$(printf '%s' "$_fx" | cut -c5-6)/$(printf '%s' "$_fx" | cut -c7-8)"
cat > "$LOG" <<LOGEOF
$_fx 12:44:08 [tunnel] регистрация не удалась: Post "https://213.176.74.63.nip.io/register": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
$_fx 12:44:20 [tunnel] stream 709: 192.168.1.67:58315 -> 149.154.167.50:443
LOGEOF

# Берём НАСТОЯЩИЕ функции из скрипта: маскировщик и секцию агрегированных
# ошибок. Грепать текст бессмысленно — проверяем то, что реально напечатается.
z2k_extract_fn "$SRC" z2k_mask_addrs        > "$TMP/mask.sh"
z2k_extract_fn "$SRC" _print_errors_section > "$TMP/errsec.sh"
# Секция ходит за строками через окно по времени — помощника тоже берём из
# исходника, иначе она молча вернёт пустоту.
sed -n '/^Z2K_ERR_DAYS=/,/^}/p' "$SRC" >> "$TMP/errsec.sh"

if [ -s "$TMP/mask.sh" ] && [ -s "$TMP/errsec.sh" ]; then
    ok "маскировщик и секция ошибок извлечены"
else
    no "блоки извлечены" "оба непустые" "mask=$(wc -c < "$TMP/mask.sh") err=$(wc -c < "$TMP/errsec.sh")"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"; exit 1
fi

run_section() {  # run_section <MODE>
    env -i PATH="$Z2K_TEST_PATH" MODE="$1" LOGF="$LOG" \
        M="$TMP/mask.sh" E="$TMP/errsec.sh" "$Z2K_TEST_SH" -c '
            . "$M"
            Z2K_DIAG_LOGS="$LOGF"
            ERR_PER_FILE=40
            . "$E"
            _print_errors_section
        ' 2>/dev/null
}

OUT_REPORT=$(run_section report)
OUT_FULL=$(run_section full)

# 1. Отчёт: ни одного сырого адреса.
case "$OUT_REPORT" in
    *213.176.74.63*|*192.168.1.67*|*149.154.167.50*)
        no "в отчёте не осталось сырых адресов" "все замаскированы" \
           "$(printf '%s' "$OUT_REPORT" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tr '\n' ' ')" ;;
    *) ok "в отчёте не осталось сырых адресов" ;;
esac

# 2. Отчёт: маскировка именно применилась, а не секция вышла пустой.
case "$OUT_REPORT" in
    *x.x.x.x*) ok "адреса заменены на x.x.x.x, а не вырезаны вместе со строкой" ;;
    *) no "адреса заменены на x.x.x.x" "x.x.x.x в выводе" "$(printf '%s' "$OUT_REPORT" | head -2)" ;;
esac

# 3. Отчёт: остальной текст строки уцелел — иначе разбирать будет нечего.
case "$OUT_REPORT" in
    *"регистрация не удалась"*"context deadline exceeded"*)
        ok "причина и текст ошибки в строке уцелели" ;;
    *) no "текст ошибки уцелел" "причина на месте" "$(printf '%s' "$OUT_REPORT" | head -2)" ;;
esac

# 4. Экранный режим: адреса на месте. Отчёт никуда не уходит, и человеку,
#    который смотрит у себя, адреса нужны — маскировать их там значит мешать.
case "$OUT_FULL" in
    *213.176.74.63*) ok "в экранном режиме адреса не маскируются" ;;
    *) no "в экранном режиме адреса не маскируются" "сырой адрес" "$(printf '%s' "$OUT_FULL" | head -2)" ;;
esac

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
