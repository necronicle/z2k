#!/bin/sh
# tests/test_au_steps.sh — последствия исполняются один раз и в правильном порядке.
#
# Ключевое здесь — ВЕТО валидации. Конфиг не прошёл проверку, а перезапуск всё
# равно случился — это роутер без обхода до утра. Поэтому «шаг провалился»
# обязано означать «дальше не идём», а не «идём и надеемся».
#
# И второе: неизвестный шаг. Релиз может объявить действие, которого этот
# исполнитель не знает (роутер отстал на десяток версий). Единственный честный
# ответ — «не могу, нужна полная переустановка», а не тихо пропустить и сдвинуть
# версию.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1; trap 'rm -rf "$SB"' EXIT
Z2K_AU_SOURCE_ONLY=1; export Z2K_AU_SOURCE_ONLY
# shellcheck disable=SC1091
. "$ROOT/lib/utils.sh" 2>/dev/null
# shellcheck disable=SC1091
. "$ROOT/lib/auto_update.sh" 2>/dev/null
Z2K_AU_TMP_DIR="$SB/tmp"; mkdir -p "$Z2K_AU_TMP_DIR"
au_log() { :; }

cat > "$SB/m.json" <<'EOF'
{"current": "p-3",
 "history": [
{"v": "p-1", "type": "patch", "steps": ["restart-service"], "changed_files": ["files/lua/a.lua"]},
{"v": "p-2", "type": "patch", "steps": ["regen-config", "validate-config", "restart-service"], "changed_files": ["lib/config_official.sh"]},
{"v": "p-3", "type": "patch", "steps": ["refresh-binaries", "restart-service"], "changed_files": ["z2k-warpd/builds/x"]},
{"v": "p-4", "type": "patch", "changed_files": ["files/lists/a.txt"]}
]}
EOF

assert_eq "шаги записи читаются" "regen-config validate-config restart-service" \
    "$(au_entry_steps "$SB/m.json" p-2 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "запись без steps — пусто, не ошибка" "" "$(au_entry_steps "$SB/m.json" p-4 | tr '\n' ' ')"
assert_eq "неизвестный тег — пусто" "" "$(au_entry_steps "$SB/m.json" p-99 | tr '\n' ' ')"

assert_eq "объединение трёх релизов: порядок канонический, рестарт один" \
    "regen-config validate-config refresh-binaries restart-service" \
    "$(au_steps_union "$SB/m.json" p-1 p-2 p-3 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "порядок объединения не зависит от порядка тегов" \
    "$(au_steps_union "$SB/m.json" p-1 p-2 p-3 | tr '\n' ' ')" \
    "$(au_steps_union "$SB/m.json" p-3 p-1 p-2 | tr '\n' ' ')"

# Каталог исполнителя и каталог сборки — две стороны одного контракта.
# shellcheck disable=SC1091
. "$ROOT/lib/release_map.sh"
assert_eq "исполнитель и сборка знают один и тот же порядок" \
    "$(z2k_all_steps | tr '\n' ' ')" "$(au_step_order | tr '\n' ' ')"

# refresh-binaries крутит цикл ЗА ПАЙПОМ, то есть в подоболочке: присвоение
# оттуда не переживает конец цикла. Провал загрузки бинарника обязан выйти
# наружу ошибкой, а не успехом — иначе версия сдвинется, а движок останется
# старым, и снаружи это выглядит как «обновилось».
mkdir -p "$SB/tmp"
cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<'EOF'
{"files_sha256": {
  "z2k-warpd/builds/z2k-warpd-linux-testarch": "0000000000000000000000000000000000000000000000000000000000000000"
}, "current": "p-1"}
EOF
au_bin_goarch() { echo testarch; }
au_service_for_binary() { echo ""; }
au_download_repo_file() { return 1; }
assert_eq "refresh-binaries: обрыв загрузки виден снаружи" "1" "$(au_step_refresh_binaries; echo $?)"
au_download_repo_file() { printf 'подделка\n' > "$2"; }
assert_eq "refresh-binaries: чужая sha виден снаружи" "1" "$(au_step_refresh_binaries; echo $?)"

# Исполнение: подменяем действия наблюдаемыми заглушками.
: > "$SB/done.log"
au_step_regen_strategies(){ echo regen-strategies >> "$SB/done.log"; }
au_step_regen_config()    { echo regen-config >> "$SB/done.log"; }
au_step_validate_config() { echo validate-config >> "$SB/done.log"; [ -f "$SB/bad" ] && return 1; return 0; }
au_step_refresh_binaries(){ echo refresh-binaries >> "$SB/done.log"; }
au_step_rebuild_panel()   { echo rebuild-panel >> "$SB/done.log"; }
au_step_reset_state()     { echo reset-state >> "$SB/done.log"; }
au_step_restart_service() { echo restart-service >> "$SB/done.log"; }

assert_eq "успешный прогон" "0" "$(au_run_steps regen-config validate-config restart-service; echo $?)"
assert_eq "порядок исполнения" "regen-config validate-config restart-service" "$(tr '\n' ' ' < "$SB/done.log" | sed 's/ $//')"

: > "$SB/done.log"; touch "$SB/bad"
assert_eq "валидация провалилась — rc 1" "1" "$(au_run_steps regen-config validate-config restart-service; echo $?)"
assert_eq "ВЕТО: перезапуска не было" "0" "$(grep -c restart-service "$SB/done.log")"
rm -f "$SB/bad"

: > "$SB/done.log"
assert_eq "неизвестный шаг → rc 2 (нужна полная установка)" "2" "$(au_run_steps regen-config шаг-из-будущего restart-service; echo $?)"
assert_eq "неизвестный шаг: ничего после него не выполнялось" "regen-config" "$(tr '\n' ' ' < "$SB/done.log" | sed 's/ $//')"

: > "$SB/done.log"
assert_eq "пустой набор шагов — успех, ничего не делаем" "0" "$(au_run_steps; echo $?)"
assert_eq "пустой набор: журнал пуст" "0" "$(wc -l < "$SB/done.log" | tr -d ' ')"

# Каждый шаг из каталога исполним: обёртка не должна молча промахиваться мимо
# имени функции.
_unimpl=""
for s in $(au_step_order); do
    au_run_step "$s" >/dev/null 2>&1
    [ "$?" = 2 ] && _unimpl="$_unimpl $s"
done
assert_eq "у каждого шага каталога есть исполнитель" "" "$_unimpl"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
