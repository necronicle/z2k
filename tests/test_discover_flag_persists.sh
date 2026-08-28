#!/bin/sh
# tests/test_discover_flag_persists.sh — Z2K_DISCOVER переживает перегенерацию.
#
# ЗАЧЕМ. Issue #44: человек включает автодетекцию пунктом [T] в меню [Y],
# а после первого же обновления она снова 0. Причина: генератор конфига
# ключ НЕ сохранял — его не было в списке saved_*, — а установка следом
# дописывала «Z2K_DISCOVER=0», если ключа нет. То есть выбор пользователя
# затирался каждой перегенерацией.
#
# Умолчание остаётся 0 намеренно: функция опытная и на эксплуатацию не
# рассчитана. Проверяем ровно две вещи — умолчание выключено, а осознанно
# выставленная единица не теряется.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GEN="$ROOT/lib/config_official.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

# --- 1. Ключ вообще участвует в сохранении -----------------------------------
assert_eq "объявлено умолчание"       "1" "$(grep -c 'local saved_Z2K_DISCOVER=' "$GEN")"
assert_eq "читается из старого конфига" "1" "$(grep -c 'safe_config_read "Z2K_DISCOVER"' "$GEN")"
assert_eq "пишется обратно"            "1" "$(grep -c '^Z2K_DISCOVER=\${saved_Z2K_DISCOVER}' "$GEN")"

# --- 2. Умолчание — выключено -------------------------------------------------
_def=$(grep 'local saved_Z2K_DISCOVER=' "$GEN" | sed 's/.*="\(.*\)".*/\1/')
assert_eq "умолчание выключено (функция опытная)" "0" "$_def"

# --- 3. Единица переживает перегенерацию, ноль остаётся нулём -----------------
#
# Гоняем НАСТОЯЩИЙ safe_config_read из генератора: копия разошлась бы с
# оригиналом на первой правке.
# Функция живёт в lib/utils.sh, а не в генераторе.
sed -n '/^safe_config_read()/,/^}/p' "$ROOT/lib/utils.sh" > "$SB/fn.sh"
[ -s "$SB/fn.sh" ] || { printf '[FAIL] safe_config_read не извлёкся\n'; exit 1; }

printf 'ENABLED=1\nZ2K_DISCOVER=1\n' > "$SB/cfg_on"
printf 'ENABLED=1\nZ2K_DISCOVER=0\n' > "$SB/cfg_off"
: > "$SB/cfg_absent"

read_flag() { sh -c ". '$SB/fn.sh'; safe_config_read Z2K_DISCOVER '$1' 0" 2>/dev/null; }
assert_eq "включённая единица сохраняется" "1" "$(read_flag "$SB/cfg_on")"
assert_eq "ноль остаётся нулём"            "0" "$(read_flag "$SB/cfg_off")"
assert_eq "нет ключа — берём умолчание 0"  "0" "$(read_flag "$SB/cfg_absent")"

# --- 4. Сторож ключей конфига видит новый ключ --------------------------------
#
# test_config_preserves_ui_flags сверяет «прочитано» против «записано».
# Если ключ читают и не пишут (или наоборот) — он это поймает; здесь лишь
# фиксируем, что обе стороны на месте, чтобы поломка была видна именно тут.
_r=$(grep -c 'safe_config_read "Z2K_DISCOVER"' "$GEN")
_w=$(grep -c '^Z2K_DISCOVER=\${saved_Z2K_DISCOVER}' "$GEN")
assert_eq "читается и пишется симметрично" "1:1" "$_r:$_w"

# --- 5. Меню показывает то же умолчание, что и движок ------------------------
#
# Показывать «1» при отсутствующем ключе, когда init считает функцию
# выключенной, — прямой путь к вопросу «а она вообще работает?».
M="$ROOT/lib/menu.sh"
assert_eq "меню по умолчанию показывает выключено" "1" \
    "$(grep -c 'local flag="0"' "$M")"
assert_eq "меню называет функцию опытной" "1" \
    "$(grep -c 'опытная, по умолчанию выключена' "$M")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
