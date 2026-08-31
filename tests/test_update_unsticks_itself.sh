#!/bin/sh
# tests/test_update_unsticks_itself.sh — обновление, которое не проходит, обязано
# менять поведение, а не повторять одно и то же вечно.
#
# ЧТО СЛУЧИЛОСЬ (диагностика 31.08.2026). Человек стоял на версии от 25 августа.
# ШЕСТЬ НОЧЕЙ ПОДРЯД журнал показывал одно и то же: «[1/47] качаю <файл>»,
# «сходимость: не скачался», «доставка не удалась — откат». Каждую ночь заново,
# тем же путём, с тем же итогом. Пока человек не написал сам, никто бы и не
# узнал.
#
# Причина отказа может быть какой угодно — канал, зеркало, DNS. Но бесконечное
# повторение одного действия с одним итогом — дефект НАШ независимо от причины.
# После третьей неудачи путь обязан смениться на полную переустановку: она тянет
# один архив вместо полусотни файлов и у этого человека работала.
#
# Тест исполняемый: гоняет настоящую au_apply_converge с падающей доставкой.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/state"

ZAPRET2_DIR="$SB"
# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$ROOT/lib/auto_update.sh" >/dev/null 2>&1

# Заглушки — ПОСЛЕ подключения, иначе их затрёт сам модуль.
LOG="$SB/au.log"
au_log() { printf '%s\n' "$1" >> "$LOG"; }
au_manifest_files_for() { printf 'files/a.txt\n'; }
au_snapshot_for_patch() { return 0; }
au_rollback_patch() { return 0; }
au_mark_dirty_tree() { return 0; }
au_prune_orphans() { return 0; }
au_run_steps() { return 0; }
au_write_installed_tag() { return 0; }
au_health_check() { return 0; }   # проверка живости сервиса нам здесь не нужна
au_converge_plan() { printf 'files/a.txt\n' > "$2"; return 0; }
# Доставка не удаётся — ровно как у человека.
au_converge_apply() { return 1; }

command -v au_apply_converge >/dev/null 2>&1 \
    || { bad "нет au_apply_converge"; printf '\nFAILED: 1\n'; exit 1; }

# Гоняем НАСТОЯЩУЮ au_apply_converge. Ей нужен каталог с манифестом и планом —
# больше ничего: доставку, снимок и откат мы подменили выше как зависимости.
#
# Копию логики в тест НЕ переносим сознательно: аудит того же дня показал, что
# такие «синхронные копии» расходятся с боевым кодом и охраняют сами себя.
Z2K_AU_TMP_DIR="$SB/tmp"; mkdir -p "$Z2K_AU_TMP_DIR"
printf '{}' > "$Z2K_AU_TMP_DIR/UPDATES.json"
au_converge_plan() { printf 'files/a.txt\n'; }

try() { au_apply_converge "r-99.9" restart-service; }

# --- 1. Первые две неудачи ведут себя как раньше ------------------------------
try >/dev/null 2>&1; r1=$?
try >/dev/null 2>&1; r2=$?
[ "$r1" = 1 ] && [ "$r2" = 1 ] && ok "первые две неудачи не меняют путь" \
    || bad "ожидал 1 и 1, получил $r1 и $r2"

# --- 2. Третья уводит на полную переустановку ---------------------------------
try >/dev/null 2>&1; r3=$?
[ "$r3" = 2 ] && ok "третья неудача уводит на полную переустановку" \
    || bad "третья неудача вернула $r3, а не 2"

# --- 3. Счётчик обнуляется, чтобы не уходить в переустановку каждую ночь -------
[ "$(cat "$SB/state/au-delivery-fails" 2>/dev/null)" = "0" ] \
    && ok "счётчик обнулён после эскалации" \
    || bad "счётчик не обнулён: $(cat "$SB/state/au-delivery-fails" 2>/dev/null)"

# --- 4. Успешная доставка сбрасывает счёт -------------------------------------
printf '2\n' > "$SB/state/au-delivery-fails"
au_converge_apply() { return 0; }
try >/dev/null 2>&1; r4=$?
[ "$r4" = 0 ] && ok "успешная доставка возвращает 0" || bad "успех вернул $r4"
[ "$(cat "$SB/state/au-delivery-fails" 2>/dev/null)" = "0" ] \
    && ok "успех обнуляет счётчик неудач" \
    || bad "после успеха счётчик остался: $(cat "$SB/state/au-delivery-fails" 2>/dev/null)"

# --- 5. В боевом коде счётчик и эскалация действительно есть ------------------
A="$ROOT/lib/auto_update.sh"
grep -q 'au-delivery-fails' "$A" && ok "счётчик заведён в боевом коде" \
    || bad "в боевом коде нет счётчика неудач доставки"
grep -q 'ухожу на полную переустановку' "$A" && ok "эскалация есть в боевом коде" \
    || bad "в боевом коде нет эскалации"

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
