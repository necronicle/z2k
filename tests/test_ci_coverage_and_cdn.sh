#!/bin/sh
# tests/test_ci_coverage_and_cdn.sh — находки ревью GitHub Actions 2026-08-15.
#
# ЗАЧЕМ. Обе охраняемые здесь вещи ломаются молча и выглядят исправными:
#
#   1. Маска файлов у гейта. shellcheck и `dash -n` брали из webpanel только
#      подкаталог cgi, поэтому webpanel/install.sh (678 строк, переписывает
#      панель на живом роутере) и webpanel/uninstall.sh не проверялись НИКОГДА.
#      Джобы при этом зелёные: файл просто не попадает в выборку, и отсутствие
#      проверки неотличимо от пройденной проверки.
#
#   2. Список файлов для сброса кэша CDN. purge считал разницу по
#      github.event.before/after, а на единственном боевом пути (publish.yml
#      зовёт его через workflow_call) этих полей не существует. Условие
#      фоллбэка было истинно на КАЖДОМ релизе, и выселялись «первые 200 файлов
#      дерева» — то есть tests/*, но не webpanel/* и не z2k.sh. Проверено на
#      реальном прогоне r-75.17: список обрывается на tests/test_panel_auth.sh.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CI="$ROOT/.github/workflows/ci.yml"
LOCAL="$ROOT/scripts/ci_local.sh"
PUB="$ROOT/.github/workflows/publish.yml"
PURGE="$ROOT/.github/workflows/jsdelivr-purge.yml"

for f in "$CI" "$LOCAL" "$PUB" "$PURGE"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

# --- 1. Каждый отгружаемый shell-файл попадает под линтер -----------------------
#
# Проверяем не текст маски, а РЕЗУЛЬТАТ: собираем список файлов, которые
# реально едут на роутер, и требуем, чтобы каждый из них ловился маской.
# Так проверка переживёт любое переписывание самой маски.
# МАСКУ ЧИТАЕМ ИЗ ci.yml, А НЕ ПОВТОРЯЕМ ЗДЕСЬ.
#
# Первая версия этой проверки держала копию маски в самом тесте — и потому
# зеленела на старом, дырявом ci.yml: она сверяла файлы со своей собственной
# правильной копией, а не с тем, что реально гоняет гейт. Тест, проверяющий
# сам себя, охраняет ноль.
# Берём шаблоны ТОЛЬКО из строки самой маски, а не отовсюду.
#
# Наивный grep по всему ci.yml вытаскивал 130 путей вместо восьми: в файле есть
# ещё и перечисление конкретных имён (проверка полноты манифеста), и оно тоже
# состоит из строк вида './что-то.sh'. Смешавшись, они давали ложные «дыры».
_maskline=$(grep -n "find . -name '\*\.sh'" "$CI" | head -1 | cut -d: -f1)
[ -n "$_maskline" ] || { printf '[FAIL] в ci.yml не найдена строка маски shellcheck\n'; exit 1; }
_patterns=$(sed -n "${_maskline}p" "$CI" | grep -o "path '\./[A-Za-z0-9_/*.-]*'" | sed "s/path '//; s/'$//" | sort -u)
[ -n "$_patterns" ] || { printf '[FAIL] не удалось вынуть маску из ci.yml\n'; exit 1; }

# МАСКУ ИСПОЛНЯЕМ ТЕМ ЖЕ find, А НЕ ЭМУЛИРУЕМ.
#
# Первая попытка сверяла шаблоны через `case` — и выдала семь несуществующих
# «дыр» в files/ndm/. Причина: у `find -path` звёздочка проходит через слэш, а
# у `case` в POSIX-оболочке поведение другое. Эмуляция чужой семантики врёт в
# обе стороны, поэтому строим ровно ту же команду и запускаем её.
# set -f ОБЯЗАТЕЛЕН. В `for p in $_patterns` подстановка проходит не только
# разбиение на слова, но и раскрытие путей: шаблон './lib/*.sh' превратился бы
# в список реальных файлов ещё ДО того, как стать аргументом find, и маска
# «сузилась» бы до того, что существует сейчас. Именно так и вышло с первого
# раза — тест отрапортовал семь несуществующих дыр в files/ndm/.
set -f
_expr=""
for p in $_patterns; do
    [ -z "$_expr" ] && _expr="-path '$p'" || _expr="$_expr -o -path '$p'"
done
set +f
_covered=$( cd "$ROOT" && eval "find . -name '*.sh' \\( $_expr \\)" | sort )

_shipped=$( cd "$ROOT" && find ./lib ./files ./webpanel -name '*.sh' -not -path '*/node_modules/*' | sort )
_uncovered=""
for f in $_shipped; do
    printf '%s\n' "$_covered" | grep -qxF "$f" || _uncovered="$_uncovered $f"
done
if [ -z "$_uncovered" ]; then
    ok "все отгружаемые shell-файлы попадают под маску линтера"
else
    no "покрытие маской" "все файлы lib/ files/ webpanel/" \
       "вне маски:$_uncovered — линтер их не видит, а джоба всё равно зелёная"
fi

# Конкретно те два, из-за которых находка и появилась.
for f in ./webpanel/install.sh ./webpanel/uninstall.sh; do
    if printf '%s\n' "$_covered" | grep -qxF "$f"; then
        ok "$f под линтером"
    else
        no "$f под линтером" "ловится маской ci.yml" "нет"
    fi
done

# --- 2. Маски в CI и в локальном прогоне совпадают ------------------------------
#
# Оба файла прямо требуют менять маски только синхронно. Расхождение означает,
# что локальный зелёный перестал предсказывать удалённый.
# Та же оговорка: только строка маски, иначе в сравнение попадёт список имён.
_lo_maskline=$(grep -n "find . -name '\*\.sh'" "$LOCAL" | head -1 | cut -d: -f1)
_ci_paths="$_patterns"
_lo_paths=$(sed -n "${_lo_maskline}p" "$LOCAL" | grep -o "path '\./[A-Za-z0-9_/*.-]*'" | sed "s/path '//; s/'$//" | sort -u)
if [ "$_ci_paths" = "$_lo_paths" ] && [ -n "$_ci_paths" ]; then
    ok "маски ci.yml и scripts/ci_local.sh совпадают"
else
    no "синхронность масок" "одинаковые списки путей" \
       "разошлись — локальный зелёный больше не предсказывает CI"
fi

# И тот же вопрос про вторую выборку (dash -n), она отдельная.
_ci_dirs=$(grep -o 'find \./files \./lib \./[A-Za-z/]* -type f' "$CI" | sort -u)
_lo_dirs=$(grep -o 'find \./files \./lib \./[A-Za-z/]* -type f' "$LOCAL" | sort -u)
if [ "$_ci_dirs" = "$_lo_dirs" ] && [ -n "$_ci_dirs" ]; then
    ok "выборка для dash -n совпадает в обоих местах"
else
    no "синхронность выборки dash -n" "одинаковая" "разошлась: [$_ci_dirs] против [$_lo_dirs]"
fi

# --- 3. Сброс кэша CDN получает обе точки, а не одну ----------------------------
#
# Корень дефекта: purge вызывается через workflow_call, где github.event.before
# не существует. Значит точку «до» обязан передать вызывающий.
if grep -q '^      before:$' "$PURGE"; then
    ok "jsdelivr-purge принимает вход before"
else
    no "вход before у purge" "объявлен в workflow_call.inputs" \
       "нет — разницу считать не из чего, каждый релиз уйдёт в фоллбэк"
fi

if grep -q 'BEFORE: ${{ inputs.before || github.event.before }}' "$PURGE"; then
    ok "вход имеет приоритет над полем события"
else
    no "приоритет входа" "inputs.before перед github.event.before" \
       "нет — на workflow_call поле пусто и фоллбэк снова станет обычным путём"
fi

if grep -q 'before: ${{ needs.publish.outputs.before }}' "$PUB"; then
    ok "publish передаёт before в purge"
else
    no "проводка before" "cdn получает needs.publish.outputs.before" "нет — вход объявлен, но не заполняется"
fi

if grep -q 'before: ${{ steps.push.outputs.before }}' "$PUB"; then
    ok "job publish отдаёт before наружу"
else
    no "output before у publish" "объявлен в outputs" "нет — needs.publish.outputs.before будет пуст"
fi

# Прежняя вершина обязана читаться ДО перевода ветки, иначе прочитаем новую.
_l_read=$(grep -n 'refs/heads/z2k-enhanced" *\\$' "$PUB" | head -1 | cut -d: -f1)
_l_get=$(grep -n 'BEFORE=$(gh api' "$PUB" | head -1 | cut -d: -f1)
_l_patch=$(grep -n 'gh api -X PATCH' "$PUB" | head -1 | cut -d: -f1)
if [ -n "$_l_get" ] && [ -n "$_l_patch" ] && [ "$_l_get" -lt "$_l_patch" ]; then
    ok "прежняя вершина читается до перевода ветки, а не после"
else
    no "порядок чтения before" "чтение раньше PATCH" \
       "чтение=$_l_get PATCH=$_l_patch — прочитаем уже новую вершину, разница будет пустой"
fi

# --- 4. Фоллбэк перестал быть тихим ---------------------------------------------
#
# Пока он молча писал обычную строку, три релиза подряд выселяли не те файлы и
# никто этого не заметил. Теперь это предупреждение.
if grep -q '::warning::BEFORE=' "$PURGE"; then
    ok "срабатывание фоллбэка видно в ленте сборок"
else
    no "заметность фоллбэка" "::warning::" "обычная строка — снова пройдёт незамеченным"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
