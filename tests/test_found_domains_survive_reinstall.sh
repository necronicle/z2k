#!/bin/sh
# tests/test_found_domains_survive_reinstall.sh — домены, найденные автоматикой,
# переживают переустановку.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Обновление у нас — это переустановка: дерево /opt/zapret2
# уносится в .old.$$ и удаляется, а обратно кладётся то, что установщик явно
# положил в бэкап. В этом списке были whitelist, extra-domains, адресные
# исключения, списки WARP и пользовательские стратегии — всё, что ввёл ЧЕЛОВЕК.
# А то, что нашла АВТОМАТИКА, в списке отсутствовало:
#
#   lists/autohostlist-domains.txt  — след автохостлиста движка,
#   lists/discovered-domains.txt    — публикации демона z2k-detect.
#
# Первый не бэкапился вовсе, второй установщик к тому же пересоздавал ПУСТЫМ.
# То есть недели наблюдений стирались на каждой обнове, и незаметно: панель
# показывала те же две категории, просто пустые — «пока ничего не нашлось».
# Восстановить их нечем, они не выводятся ни из shipped-файлов, ни из апстрима.
#
# ЧТО ОХРАНЯЕТСЯ:
#
#   1. Оба файла реально доезжают: бэкап и восстановление ИСПОЛНЯЮТСЯ на
#      временном дереве, а не проверяются грепом по комментариям.
#   2. Пустышка, которую установщик создаёт для discovered-domains.txt, не
#      затирает восстановленное — порядок в коде правильный.
#   3. Бэкап fail-closed: если копия не удалась, установка прерывается ДО
#      удаления рабочего дерева (как у whitelist), а не продолжается молча.
#   4. Спасение из недостроенной прошлой установки (.old) знает про оба файла.
#
# POSIX sh. Настоящая установка не запускается.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
INST="$ROOT/lib/install.sh"
[ -f "$INST" ] || { printf '[FAIL] нет %s\n' "$INST"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

MARK='for _acc in autohostlist-domains discovered-domains; do'

# Вынимаем НАСТОЯЩИЕ куски установщика: первый цикл — бэкап, второй — возврат.
extract() {
    awk -v want="$1" -v mark="$MARK" '
        index($0, mark) { n++; if (n == want) grab = 1 }
        grab { print }
        grab && /^[[:space:]]*done[[:space:]]*$/ { exit }
    ' "$INST"
}

extract 1 > "$TMP/backup.sh"
extract 2 > "$TMP/restore.sh"

if [ -s "$TMP/backup.sh" ] && [ -s "$TMP/restore.sh" ]; then
    ok "обе половины найдены в install.sh"
else
    no "обе половины найдены" "бэкап и возврат" \
       "бэкап=$([ -s "$TMP/backup.sh" ] && echo да || echo нет) возврат=$([ -s "$TMP/restore.sh" ] && echo да || echo нет)"
    printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
    exit 1
fi

# Заглушки окружения установщика.
cat > "$TMP/stubs.sh" <<'STUBS'
print_info()    { printf 'INFO: %s\n' "$*"; }
print_warning() { printf 'WARN: %s\n' "$*"; }
print_success() { printf 'OK: %s\n' "$*"; }
die()           { printf 'DIE: %s\n' "$*"; exit 7; }
STUBS

# --- 1. Полный цикл: бэкап → снос дерева → возврат ---------------------------
TREE="$TMP/opt/zapret2"
BK="$TMP/backup"
mkdir -p "$TREE/lists"
printf 'meduza.io\nrutracker.org\n' > "$TREE/lists/autohostlist-domains.txt"
printf 'example.blocked\n' > "$TREE/lists/discovered-domains.txt"
mkdir -p "$BK"

(
    . "$TMP/stubs.sh"
    ZAPRET2_DIR="$TREE"; backup_tmp="$BK"
    . "$TMP/backup.sh"
) > "$TMP/backup.log" 2>&1
_rc=$?

if [ "$_rc" = "0" ] && [ -f "$BK/autohostlist-domains.txt" ] && [ -f "$BK/discovered-domains.txt" ]; then
    ok "оба файла уходят в бэкап"
else
    no "оба файла в бэкапе" "две копии, rc=0" "rc=$_rc $(ls "$BK" 2>/dev/null | tr '\n' ' ')"
fi

# Переустановка: дерева больше нет. Установщик пересоздаёт пустой
# discovered-domains.txt (lib/install.sh, «z2k-detect daemon-managed hostlist»),
# и именно эта пустышка раньше и оставалась у человека.
rm -rf "$TREE"
mkdir -p "$TREE/lists"
: > "$TREE/lists/discovered-domains.txt"

(
    . "$TMP/stubs.sh"
    ZAPRET2_DIR="$TREE"; backup_tmp="$BK"
    . "$TMP/restore.sh"
) > "$TMP/restore.log" 2>&1
_rc=$?

_got_auto=$(cat "$TREE/lists/autohostlist-domains.txt" 2>/dev/null)
_got_disc=$(cat "$TREE/lists/discovered-domains.txt" 2>/dev/null)

if [ "$_got_auto" = "$(printf 'meduza.io\nrutracker.org')" ]; then
    ok "autohostlist-domains.txt вернулся целиком"
else
    no "autohostlist-domains.txt вернулся" "meduza.io+rutracker.org" "[$_got_auto] rc=$_rc"
fi

if [ "$_got_disc" = "example.blocked" ]; then
    ok "discovered-domains.txt вернулся, пустышка его не затёрла"
else
    no "discovered-domains.txt вернулся" "example.blocked" "[$_got_disc] rc=$_rc"
fi

# --- 2. Порядок в коде: возврат ПОСЛЕ создания пустышки ----------------------
_ln_empty=$(grep -n ': > "${ZAPRET2_DIR}/lists/discovered-domains.txt"' "$INST" | head -1 | cut -d: -f1)
_ln_restore=$(grep -n "$MARK" "$INST" | sed -n '2p' | cut -d: -f1)
if [ -n "$_ln_empty" ] && [ -n "$_ln_restore" ] && [ "$_ln_restore" -gt "$_ln_empty" ]; then
    ok "возврат идёт после создания пустышки ($_ln_empty → $_ln_restore)"
else
    no "порядок пустышка→возврат" "возврат позже" "пустышка=$_ln_empty возврат=$_ln_restore"
fi

# --- 3. Бэкап fail-closed ----------------------------------------------------
#
# Копия не удалась (каталог бэкапа недоступен на запись) — установка обязана
# прерваться, потому что дальше по коду рабочее дерево уносится в .old и
# удаляется. Молчаливое продолжение здесь стоит человеку всех находок.
TREE2="$TMP/opt2/zapret2"; BK2="$TMP/backup2"
mkdir -p "$TREE2/lists" "$BK2"
printf 'meduza.io\n' > "$TREE2/lists/autohostlist-domains.txt"
chmod 500 "$BK2"

if [ "$(id -u)" = "0" ]; then
    printf '[SKIP] fail-closed: под root права на каталог не запрещают запись\n'
else
    (
        . "$TMP/stubs.sh"
        ZAPRET2_DIR="$TREE2"; backup_tmp="$BK2"
        . "$TMP/backup.sh"
    ) > "$TMP/failclosed.log" 2>&1
    _rc=$?
    if [ "$_rc" = "7" ] && grep -q '^DIE:' "$TMP/failclosed.log"; then
        ok "неудачный бэкап прерывает установку (die)"
    else
        no "бэкап fail-closed" "die, rc=7" "rc=$_rc $(head -1 "$TMP/failclosed.log" 2>/dev/null)"
    fi
fi
chmod 700 "$BK2" 2>/dev/null

# --- 4. Спасение из недостроенной установки знает про оба файла --------------
_rescue=$(awk '/Прошлая установка не завершилась/{c=1} c{print} c&&/^            done$/{exit}' "$INST")
_miss=""
for f in lists/autohostlist-domains.txt lists/discovered-domains.txt; do
    printf '%s' "$_rescue" | grep -q "$f" || _miss="$_miss $f"
done
if [ -z "$_miss" ]; then
    ok "спасение из .old переносит оба файла"
else
    no "спасение из .old" "оба файла в списке" "нет:$_miss"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
