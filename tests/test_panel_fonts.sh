#!/bin/sh
# tests/test_panel_fonts.sh — шрифты панели едут с ней, а не из интернета.
#
# ЗАЧЕМ. Панель тянула Fira с fonts.googleapis.com блокирующим <link>: браузер
# не рисует ничего, пока кросс-доменная таблица стилей не разрешится. На
# устройстве, которое стоит ради обхода блокировок, и открывают которое ровно
# тогда, когда с сетью плохо, это белый экран на десятки секунд. Ссылку убрали
# — но вместе с ней ушла и гарнитура, панель поехала системным шрифтом и
# потеряла вид. Теперь файлы отгружаются вместе с панелью.
#
# ГЛАВНЫЙ РИСК — РАСХОЖДЕНИЕ СПИСКОВ, и оно молчаливое. Имена файлов заданы в
# ТРЁХ местах: @font-face в style.css, список загрузки в z2k.sh, копирование в
# webpanel/install.sh. Разойдётся любое — браузер тихо откатится на системный
# шрифт, ошибки не будет нигде, и причину будет не видно. Поэтому сверяем.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CSS="$ROOT/webpanel/www/style.css"
BOOT="$ROOT/z2k.sh"
INST="$ROOT/webpanel/install.sh"
CONF="$ROOT/webpanel/lighttpd.conf"
DIR="$ROOT/webpanel/www/fonts"
IDX="$ROOT/webpanel/www/index.html"

# --- 1. Ни одного обращения наружу --------------------------------------------
#
# Это причина, по которой всё затевалось. Проверяем именно ЖИВУЮ ссылку, а не
# упоминание: рядом лежит комментарий, который называет эти хосты по имени, и
# голый grep зеленел бы на нём при вернувшемся <link>.
if grep -qE '<(link|script)[^>]*(href|src)="https?://' "$IDX"; then
    no "панель не ходит наружу за ресурсами" "нет внешних link/script" \
       "$(grep -oE '<(link|script)[^>]*(href|src)="https?://[^"]*"' "$IDX" | head -1)"
else
    ok "в index.html нет ни одного внешнего ресурса"
fi

# --- 2. Файлы на месте ---------------------------------------------------------
_have=$(ls "$DIR"/*.woff2 2>/dev/null | wc -l | tr -d ' ')
if [ "$_have" -gt 0 ]; then
    ok "шрифты лежат в дереве панели ($_have файлов)"
else
    no "шрифты лежат в webpanel/www/fonts" "хотя бы один .woff2" "каталог пуст"
    printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
    exit 1
fi

# --- 3. Списки сходятся: style.css ↔ файлы ↔ z2k.sh ↔ install.sh ---------------
_css=$(grep -oE 'fonts/[A-Za-z0-9-]+\.woff2' "$CSS" | sed 's|fonts/||' | sort -u)
# Глобом, а не `ls | grep`: имена шрифтов мы задаём сами, но правило общее и
# ломается ровно на неожиданном имени файла.
_fs=$(for _p in "$DIR"/*.woff2; do [ -e "$_p" ] && basename "$_p"; done | sort -u)
_boot=$(grep -oE 'www/fonts/[A-Za-z0-9-]+\.woff2' "$BOOT" | sed 's|www/fonts/||' | sort -u)

if [ "$_css" = "$_fs" ]; then
    ok "каждый файл из @font-face существует, и лишних файлов нет"
else
    no "@font-face и каталог совпадают" "одинаковые списки" \
       "разница: $(printf '%s\n%s\n' "$_css" "$_fs" | sort | uniq -u | tr '\n' ' ')"
fi

if [ "$_boot" = "$_fs" ]; then
    ok "z2k.sh скачивает ровно те файлы, что лежат в дереве"
else
    no "список загрузки в z2k.sh совпадает с каталогом" "одинаковые списки" \
       "разница: $(printf '%s\n%s\n' "$_boot" "$_fs" | sort | uniq -u | tr '\n' ' ')"
fi

# install.sh копирует каталогом — это и правильно: поимённый список разошёлся бы
# с @font-face при первой правке. Требуем именно копирование каталога.
if grep -q 'www/fonts' "$INST" && grep -qE 'fonts/\*\.woff2' "$INST"; then
    ok "install.sh копирует шрифты каталогом, а не поимённо"
else
    no "install.sh раскладывает шрифты" "cp каталогом fonts/*.woff2" "не найдено"
fi

# --- 4. lighttpd отдаёт их правильным типом ------------------------------------
#
# Без mime-типа сервер вернёт application/octet-stream, и браузеры такой ответ
# для @font-face молча игнорируют: панель останется на системном шрифте, а
# причина не будет видна ниоткуда.
if grep -qE '"\.woff2"[[:space:]]*=>[[:space:]]*"font/woff2"' "$CONF"; then
    ok "lighttpd отдаёт .woff2 как font/woff2"
else
    no "mime-тип для .woff2 в lighttpd.conf" '".woff2" => "font/woff2"' "не найдено"
fi

# --- 5. Локальная копия имеет приоритет над чтением с флешки -------------------
#
# local() первым: если Fira установлена в системе, файл с флешки не читается
# вовсе. На роутере с медленным носителем это заметно.
_bad=0
for _f in $_css; do
    grep -B4 "fonts/$_f" "$CSS" | grep -q 'local(' || _bad=$((_bad+1))
done
if [ "$_bad" = "0" ]; then
    ok "у каждого объявления есть local() перед url()"
else
    no "local() стоит перед url()" "у всех объявлений" "без local(): $_bad"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
