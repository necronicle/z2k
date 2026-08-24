#!/bin/sh
# tests/test_au_compat.sh — совместимость в обе стороны и выбор пути.
#
# Манифест без install_map (откат манифеста, ручная правка) НЕ должен приводить
# к тихому сдвигу версии: исполнитель обязан честно потребовать полную
# установку. Тихий сдвиг версии без доставки — авария, которую снаружи не
# опознать: тег новый, поведение старое, в логе успех.
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

printf '{"current":"p-2","history":[\n{"v": "p-2", "type": "patch", "changed_files": ["files/lua/a.lua"]}\n]}\n' > "$SB/old.json"
printf '{"current":"p-2","install_map":{"files/lua/a.lua":["/x"]},"history":[\n{"v": "p-2", "type": "patch", "steps": ["restart-service"], "changed_files": ["files/lua/a.lua"]}\n]}\n' > "$SB/new.json"

assert_eq "манифест без карты опознан"  "1" "$(au_manifest_has_install_map "$SB/old.json"; echo $?)"
assert_eq "манифест с картой опознан"   "0" "$(au_manifest_has_install_map "$SB/new.json"; echo $?)"

# Старый манифест: патч обязан отказаться (rc 2), а не разложить наугад.
cp "$SB/old.json" "$Z2K_AU_TMP_DIR/UPDATES.json"
assert_eq "без карты патч отказывается, а не гадает" "2" \
    "$(au_apply_patch p-2 "files/lua/a.lua" >/dev/null 2>&1; echo $?)"

# Аварийный флаг релиза уводит на полную установку.
printf '{"current":"p-9","install_map":{},"history":[\n{"v": "p-9", "type": "reinstall", "full_install": true, "steps": [], "changed_files": []}\n]}\n' > "$SB/full.json"
_e=$(grep '^{"v"' "$SB/full.json")
assert_eq "full_install читается как булев флаг" "true" "$(au_entry_bool "$_e" full_install)"
_e2=$(grep '^{"v"' "$SB/new.json")
assert_eq "обычный релиз флага не несёт" "" "$(au_entry_bool "$_e2" full_install)"

# Старый апдейтер против нового манифеста: type и changed_files на месте, иначе
# он посчитает запись патчем без файлов и сдвинет версию, ничего не доставив.
assert_eq "новый манифест несёт type для старого апдейтера" "patch" "$(au_entry_field "$_e2" type)"
assert_eq "новый манифест несёт changed_files" "files/lua/a.lua" "$(au_entry_changed_files "$_e2" | tr '\n' ' ' | sed 's/ $//')"

# Развилка целиком: au_apply_converge доводит до отметки версии.
mkdir -p "$SB/zd"
printf 'новое\n' > "$SB/src.lua"
_sha=$(z2k_sha256_file "$SB/src.lua")
cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<EOF
{"current": "p-5",
 "install_map": {"files/lua/a.lua": ["$SB/zd/a.lua"]},
 "files_sha256": {"files/lua/a.lua": "$_sha"},
 "history": [
{"v": "p-5", "type": "patch", "steps": ["restart-service"], "changed_files": ["files/lua/a.lua"]}
]}
EOF
au_download_repo_file() { cp "$SB/src.lua" "$2"; }
: > "$SB/acts.log"
au_step_restart_service() { echo restart >> "$SB/acts.log"; }
au_snapshot_for_patch() { echo snapshot >> "$SB/acts.log"; return 0; }
au_rollback_patch() { echo rollback >> "$SB/acts.log"; return 0; }
au_health_check() { [ -f "$SB/sick" ] && return 1; return 0; }
Z2K_AU_INSTALLED_TAG_FILE="$SB/tag"; printf 'p-4\n' > "$Z2K_AU_INSTALLED_TAG_FILE"

assert_eq "успешный прогон" "0" "$(au_apply_converge p-5 restart-service; echo $?)"
assert_eq "файл доставлен" "новое" "$(cat "$SB/zd/a.lua" 2>/dev/null)"
assert_eq "порядок: снимок → шаги, отката нет" "snapshot restart" "$(tr '\n' ' ' < "$SB/acts.log" | sed 's/ $//')"
assert_eq "версия переставлена" "p-5" "$(cat "$SB/tag" | tr -d '[:space:]')"

# Повторный прогон: дерево уже совпало — только отметка, без шагов.
: > "$SB/acts.log"; printf 'p-4\n' > "$SB/tag"
assert_eq "идемпотентность: успех" "0" "$(au_apply_converge p-5; echo $?)"
assert_eq "идемпотентность: ничего не делалось" "" "$(tr '\n' ' ' < "$SB/acts.log" | sed 's/ $//')"
assert_eq "идемпотентность: версия всё равно отмечена" "p-5" "$(cat "$SB/tag" | tr -d '[:space:]')"

# Провал health-check: откат, версия НЕ двигается.
: > "$SB/acts.log"; printf 'p-4\n' > "$SB/tag"; touch "$SB/sick"; printf 'старое\n' > "$SB/zd/a.lua"
assert_eq "health-check провален — rc 1" "1" "$(au_apply_converge p-5 restart-service; echo $?)"
assert_eq "был откат" "yes" "$(grep -q rollback "$SB/acts.log" && echo yes || echo no)"
assert_eq "версия НЕ сдвинулась" "p-4" "$(cat "$SB/tag" | tr -d '[:space:]')"
rm -f "$SB/sick"

# Неизвестный шаг: rc 2 — наверх, за полной установкой; версия не двигается.
: > "$SB/acts.log"; printf 'p-4\n' > "$SB/tag"; printf 'старое\n' > "$SB/zd/a.lua"
assert_eq "неизвестный шаг — rc 2" "2" "$(au_apply_converge p-5 шаг-из-будущего; echo $?)"
assert_eq "неизвестный шаг: версия НЕ сдвинулась" "p-4" "$(cat "$SB/tag" | tr -d '[:space:]')"

# Старый флаг релиза «reset_state»: он появился до каталога шагов и раньше
# работал только через полную переустановку. Новый путь обязан его уважать —
# иначе релиз со сдвигом нумерации пулов приедет, а накопленная статистика
# останется указывать не на те стратегии.
_e3='{"v": "p-7", "type": "patch", "reset_state": true, "steps": ["restart-service"], "changed_files": []}'
assert_eq "reset_state читается" "true" "$(au_entry_bool "$_e3" reset_state)"
if grep -q 'au_entry_bool "$_e" reset_state' "$ROOT/lib/auto_update.sh"; then
    ok "новый путь смотрит на reset_state"
else
    no "новый путь смотрит на reset_state" "проверка флага" "не найдена — сброс состояния потеряется"
fi

# Контракт манифеста репозитория: у каждого шага в истории есть исполнитель.
unknown=""
for s in $(grep -o '"steps"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$ROOT/UPDATES.json" 2>/dev/null \
           | sed 's/.*\[//; s/\]//' | tr ',' '\n' | tr -d ' "' | grep -v '^$' | sort -u); do
    au_step_order | grep -qx "$s" || unknown="$unknown $s"
done
assert_eq "в манифесте нет шагов без исполнителя" "" "$unknown"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
