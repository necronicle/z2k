#!/bin/sh
# tests/test_diag_errors_window.sh — раздел ошибок показывает СВЕЖЕЕ, а не всё.
#
# ЗАЧЕМ. Секция «errors across all logs» брала `tail -40` СОВПАВШИХ строк за всю
# историю файла. В тихом журнале сорок ошибок набираются за месяцы: в отчёте от
# 2026-08-27 первой строкой стояла «manifest fetch failed» от 28 ИЮНЯ — рядом со
# свежими и неотличимо от них. Владелец потратил внимание на ошибку opkg,
# которая с тем же успехом могла быть двухмесячной.
#
# Окно — по ВРЕМЕНИ. Строка без даты наследует дату предыдущей датированной:
# ретраи и продолжения печатаются без штампа, но относятся к тому же событию.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIAG="$ROOT/files/z2k-diag.sh"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

# Помощник берём ИЗ ИСХОДНИКА: копия разошлась бы с оригиналом на первой правке.
sed -n '/^Z2K_ERR_DAYS=/,/^}/p' "$DIAG" > "$SB/fn.sh"
[ -s "$SB/fn.sh" ] || { printf '[FAIL] z2k_recent_lines не извлёкся\n'; exit 1; }

_old=$(z2k_test_stamp 60 | cut -c1-8)       # YYYYMMDD 60 суток назад
_old="$(echo "$_old" | cut -c1-4)-$(echo "$_old" | cut -c5-6)-$(echo "$_old" | cut -c7-8)"
_new=$(z2k_test_stamp 1  | cut -c1-8)
_new="$(echo "$_new" | cut -c1-4)-$(echo "$_new" | cut -c5-6)-$(echo "$_new" | cut -c7-8)"

cat > "$SB/log" <<INNER
[$_old 02:00:04] manifest fetch failed
 * opkg_download: Failed to download http://bin.entware.net/x/Packages.gz
[$_new 03:27:29] сходимость: не скачался files/lists/warp-endpoints.txt
 * продолжение без даты: rollback restoring
INNER

_out=$(sh -c ". '$SB/fn.sh'; z2k_recent_lines '$SB/log'")

case "$_out" in
    *"manifest fetch failed"*) no "двухмесячная ошибка отброшена" "нет её" "есть" ;;
    *) ok "двухмесячная ошибка отброшена" ;;
esac
case "$_out" in
    *"opkg_download"*) no "хвост старого события отброшен вместе с ним" "нет" "есть" ;;
    *) ok "хвост старого события отброшен вместе с ним" ;;
esac
case "$_out" in
    *"warp-endpoints"*) ok "свежая ошибка показана" ;;
    *) no "свежая ошибка показана" "есть" "нет" ;;
esac
case "$_out" in
    *"продолжение без даты"*) ok "недатированное продолжение свежего события сохранено" ;;
    *) no "недатированное продолжение свежего события сохранено" "есть" "нет" ;;
esac

# Окно настраивается: с Z2K_ERR_DAYS=90 старая строка обязана вернуться.
_wide=$(sh -c ". '$SB/fn.sh'; Z2K_ERR_DAYS=90 z2k_recent_lines '$SB/log'")
case "$_wide" in
    *"manifest fetch failed"*) ok "ширина окна настраивается" ;;
    *) no "ширина окна настраивается" "старая строка вернулась" "нет" ;;
esac

# Дата через СЛЭШ (журнал туннеля на Go) обязана распознаваться: иначе
# tg-tunnel.log выпадал бы из раздела ошибок целиком.
printf '%s 15:10:22 [tunnel] регистрация не удалась\n' "$(echo "$_new" | tr - /)" > "$SB/slash"
printf '%s 10:00:00 [tunnel] старая ошибка\n' "$(echo "$_old" | tr - /)" >> "$SB/slash"
_sl=$(sh -c ". '$SB/fn.sh'; z2k_recent_lines '$SB/slash'")
case "$_sl" in
    *"регистрация не удалась"*) ok "дата через слэш распознана" ;;
    *) no "дата через слэш распознана" "свежая строка есть" "нет" ;;
esac
case "$_sl" in
    *"старая ошибка"*) no "старое со слэшем тоже отброшено" "нет" "есть" ;;
    *) ok "старое со слэшем тоже отброшено" ;;
esac

# Журнал без единой даты не должен молча съедаться целиком.
printf 'plain error line\nanother failure\n' > "$SB/nodate"
_nd=$(sh -c ". '$SB/fn.sh'; z2k_recent_lines '$SB/nodate'")
assert_eq "журнал без дат: строк не показываем, но и не падаем" "0" "$(printf '%s' "$_nd" | grep -c . )"

# Секция действительно зовёт помощника, а не старый grep по всему файлу.
assert_eq "секция ошибок ходит через окно" "1" \
    "$(sed -n '/^_print_errors_section/,/^}/p' "$DIAG" | grep -c 'z2k_recent_lines')"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
