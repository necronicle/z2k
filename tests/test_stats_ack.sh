#!/bin/sh
# tests/test_stats_ack.sh — телеметрия не уходит раньше, чем человек узнал.
#
# ЧТО ЗДЕСЬ ОХРАНЯЕТСЯ. Сбор статистики включён по умолчанию — это решение
# владельца, и оно не обсуждается: по opt-in выборка не набирается. Но
# «включено по умолчанию» и «ушло раньше, чем человек успел узнать» — разные
# вещи, и второе исправимо без отказа от первого.
#
# Механика: свежая установка получает Z2K_STATS_ACK=0, и аплоадер молчит, пока
# признак не снимут — меню [C] или карточка в вебпанели снимают его, показав
# состав посылки и адрес. Потолок ожидания трое суток: дальше отправляем, иначе
# потеряем ровно тех, кто панель не открывает.
#
# Уже работающая установка ключа не имеет — ей ставится 1, заново спрашивать
# того, кто давно живёт с телеметрией, незачем.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
UP="$ROOT/files/z2k-stats-upload.sh"
GEN="$ROOT/lib/config_official.sh"
MENU="$ROOT/lib/menu.sh"
API="$ROOT/webpanel/cgi/api.sh"
# Источник — ВЕСЬ JavaScript панели, а не один файл: с 2026-08-14 фронтенд
# разбит на модули, и греп по точке входа не нашёл бы ничего (см.
# tests/lib/panel_js.sh).
APPJS=$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")

for f in "$UP" "$GEN" "$MENU" "$API" "$APPJS"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-statsack.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- 1. Аплоадер уважает признак ---------------------------------------------
#
# Гоняем настоящий скрипт с подставным curl и смотрим, ушёл ли запрос.
mkdir -p "$TMP/bin" "$TMP/z2k/extra_strats/cache/autocircular"
cat > "$TMP/bin/curl" <<'STUBC'
#!/bin/sh
printf 'ОТПРАВЛЕНО\n' >> "$Z2K_TEST_SENT"
exit 0
STUBC
chmod +x "$TMP/bin/curl"

STATE="$TMP/z2k/extra_strats/cache/autocircular/state.tsv"
printf '# z2k state\nyt_tcp\ta.com\t3\t%s\n' "$(date +%s)" > "$STATE"

run_upload() {
    _ack="$1"; _age_days="$2"
    rm -f "$TMP/sent"
    : > "$TMP/sent"
    {
        printf 'Z2K_STATS=1\n'
        [ "$_ack" != "-" ] && printf 'Z2K_STATS_ACK=%s\n' "$_ack"
    } > "$TMP/z2k/config"
    # Возраст установки задаём временем файла-метки.
    touch -t "$(date -v-"${_age_days}"d '+%Y%m%d%H%M' 2>/dev/null || date -d "-${_age_days} days" '+%Y%m%d%H%M')" \
        "$TMP/z2k/config" 2>/dev/null
    env PATH="$TMP/bin:/usr/bin:/bin" Z2K_TEST_SENT="$TMP/sent" \
        ZAPRET2_DIR="$TMP/z2k" CONFIG="$TMP/z2k/config" \
        STATE_TSV="$STATE" \
        sh "$UP" >/dev/null 2>&1
    if [ -s "$TMP/sent" ]; then printf 'ушло'; else printf 'молчит'; fi
}

# Скрипт берёт пути из своих констант, поэтому подменяем их sed-копией:
# менять ради теста продовый скрипт нельзя.
#
# PATH подменяем ОБЯЗАТЕЛЬНО. Аплоадер сам делает `export PATH=/opt/sbin:...`
# (так надо на Entware, системный PATH там без /opt/bin), и без этой строки
# подставной curl из PATH теста просто не находится — запускается НАСТОЯЩИЙ и
# уходит на боевой адрес. Ровно так и случилось при первом прогоне этого теста:
# три тестовых замера уехали на прод.
sed -e "s|^ZAPRET2_DIR=.*|ZAPRET2_DIR=\"$TMP/z2k\"|" \
    -e "s|^STATE_TSV=.*|STATE_TSV=\"$STATE\"|" \
    -e "s|^export PATH=.*|export PATH=\"$TMP/bin:/usr/bin:/bin\"|" \
    -e "s|^PATH=.*|PATH=\"$TMP/bin:/usr/bin:/bin\"|" \
    "$UP" > "$TMP/upload.sh"
UP="$TMP/upload.sh"

# Страховка: если подмена PATH вдруг не сработает, запрос уйдёт на боевой
# адрес. Проверяем это ДО прогонов и падаем громко, а не молча шлём в прод.
if grep -qE '^\s*(export )?PATH=/opt' "$TMP/upload.sh"; then
    printf '[FAIL] подмена PATH не сработала — тест ушёл бы на боевой адрес\n'
    exit 1
fi

r=$(run_upload 0 0)
[ "$r" = "молчит" ] && ok "свежая установка с ACK=0 не отправляет" \
                    || no "свежая установка с ACK=0 не отправляет" "молчит" "$r"

r=$(run_upload 1 0)
[ "$r" = "ушло" ] && ok "после снятия признака отправка идёт" \
                  || no "после снятия признака отправка идёт" "ушло" "$r"

r=$(run_upload - 0)
[ "$r" = "ушло" ] && ok "установка без ключа (старая) не задерживается" \
                  || no "установка без ключа (старая) не задерживается" "ушло" "$r"

r=$(run_upload 0 5)
[ "$r" = "ушло" ] && ok "через трое суток ожидание кончается" \
                  || no "через трое суток ожидание кончается" "ушло" "$r"

# --- 2. Генератор конфига проставляет ключ ------------------------------------
if grep -q 'saved_Z2K_STATS_ACK="0"' "$GEN"; then
    ok "свежая установка получает ACK=0"
else
    no "свежая установка получает ACK=0" 'saved_Z2K_STATS_ACK="0"' "не найдено"
fi
if grep -q 'safe_config_read "Z2K_STATS_ACK" "$config_file" "1"' "$GEN"; then
    ok "существующая установка без ключа получает 1"
else
    no "существующая установка без ключа получает 1" 'default "1"' "не найдено"
fi
if grep -q '^Z2K_STATS_ACK=' "$GEN"; then
    ok "ключ попадает в конфиг"
else
    no "ключ попадает в конфиг" "строка Z2K_STATS_ACK=" "не найдено"
fi

# --- 3. Оба места снимают признак ---------------------------------------------
if grep -q 'set_flag Z2K_STATS_ACK 1' "$MENU"; then
    ok "меню снимает признак при показе экрана"
else
    no "меню снимает признак" "set_flag Z2K_STATS_ACK 1" "не найдено"
fi
if grep -q 'POST /stats/ack' "$API"; then
    ok "у панели есть ручка снятия признака"
else
    no "у панели есть ручка снятия признака" "POST /stats/ack" "не найдено"
fi
if grep -q 'stats_ack' "$API" && grep -q 'stats_ack' "$APPJS"; then
    ok "признак доезжает до фронта"
else
    no "признак доезжает до фронта" "stats_ack в api.sh и app.js" "не найдено"
fi

# --- 4. Адрес в карточке и в аплоадере совпадает ------------------------------
#
# Карточка обязана называть настоящий адрес. Продублирован он намеренно, но
# расхождение означало бы, что человеку показывают не то, куда уходит.
ep_js=$(sed -n 's/.*const STATS_ENDPOINT = "\([^"]*\)".*/\1/p' "$APPJS" | head -1)
ep_sh=$(sed -n 's/^ENDPOINT="\([^"]*\)".*/\1/p' "$ROOT/files/z2k-stats-upload.sh" | head -1)
if [ -n "$ep_js" ] && [ "$ep_js" = "$ep_sh" ]; then
    ok "адрес в карточке совпадает с адресом отправки"
else
    no "адрес в карточке совпадает с адресом отправки" "$ep_sh" "$ep_js"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
