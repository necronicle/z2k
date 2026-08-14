#!/bin/sh
# tests/test_panel_auth.sh — вход в панель по паролю от роутера.
#
# ЗАЧЕМ ЭТО ЕСТЬ. Всё, что защищало панель раньше, закрывает её от чужого САЙТА
# и от обращения ИЗВНЕ: слушает только адрес в локальной сети, Host сверяется с
# приватными диапазонами, проверяется origin. Снаружи она недоступна —
# проверено стуком с другого конца интернета. Не закрыто было ровно одно: тот,
# кто УЖЕ в локальной сети. Для него панель открыта полностью, а её CGI
# работает от root.
#
# Своего пароля мы не заводим: панель спрашивает сам роутер по его же схеме
# x-ndw2-interactive. Хранить нечего, по сети идёт одноразовый ответ на
# случайный вызов, смена пароля на роутере действует сразу.
#
# ЧТО ОХРАНЯЕТСЯ ЗДЕСЬ — по одному пункту на каждый способ всё испортить:
#
#   1. Выключено по умолчанию. Панель годами ставили без пароля, и обновление
#      не должно однажды утром потребовать его от всех.
#   2. Нельзя запереться наглухо. Если веб-интерфейс роутера не отвечает,
#      войти нельзя (иначе достаточно уронить роутеру порт 80 и войти) — но
#      пароль ВСЕГДА снимается из терминального меню, и текст отказа это
#      называет.
#   3. «Роутер не ответил» ≠ «пароль неверный». Разные коды, разные сообщения.
#   4. Никакого 127.0.0.1. Первая версия ходила на петлю, а ndm её не слушает:
#      с 127.0.0.1 приходит 403 без вызова. Проверено на роутере.
#   5. Токен не через `od`. На роутере он есть, но комбинацию флагов не
#      понимает и молча отдаёт пустоту — сессия не создавалась при ВЕРНОМ
#      пароле.
#
# POSIX sh (+ node для панельной части; без node — SKIP).

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
AUTH="$ROOT/webpanel/cgi/auth.sh"
API="$ROOT/webpanel/cgi/api.sh"
WP="$ROOT/lib/webpanel.sh"
APPJS="$ROOT/webpanel/www/app.js"

for f in "$AUTH" "$API" "$WP" "$APPJS"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# Гоняем НАСТОЯЩИЕ функции из auth.sh, подменив только пути.
run() {
    Z2K_PANEL_CONFIG="$TMP/config" \
    Z2K_PANEL_SESS_DIR="$TMP/sess" \
    Z2K_PANEL_SESS_TTL="${TTL:-43200}" \
    HTTP_COOKIE="${COOKIE:-}" \
    PATH_INFO="${PINFO:-/status}" \
    sh -c '. "$1" 2>/dev/null; shift; eval "$@"' _ "$AUTH" "$@" 2>&1
}

# --- 1. Выключено по умолчанию -------------------------------------------------
: > "$TMP/config"
[ "$(run 'panel_auth_enabled && echo on || echo off')" = "off" ] \
    && ok "без флага в конфиге пароль выключен" \
    || no "умолчание" "off" "$(run 'panel_auth_enabled && echo on || echo off')"

printf 'Z2K_PANEL_AUTH=0\n' > "$TMP/config"
[ "$(run 'panel_auth_enabled && echo on || echo off')" = "off" ] \
    && ok "явный 0 выключает" || no "флаг 0" "off" "включено"

printf 'Z2K_PANEL_AUTH=1\n' > "$TMP/config"
[ "$(run 'panel_auth_enabled && echo on || echo off')" = "on" ] \
    && ok "флаг 1 включает" || no "флаг 1" "on" "выключено"

# Конфиг исполняется как скрипт, значение бывает в кавычках — читать обязаны оба.
printf 'Z2K_PANEL_AUTH="1"\n' > "$TMP/config"
[ "$(run 'panel_auth_enabled && echo on || echo off')" = "on" ] \
    && ok "значение в кавычках тоже читается" || no "кавычки" "on" "не прочитано"

# --- 2. Жизненный цикл сессии --------------------------------------------------
printf 'Z2K_PANEL_AUTH=1\n' > "$TMP/config"
SID=$(run 'panel_session_create admin')
case "$SID" in
    [0-9a-fA-F][0-9a-fA-F]*) ok "сессия создаётся, токен шестнадцатеричный" ;;
    *) no "создание сессии" "hex-токен" "[$SID]" ;;
esac
[ "${#SID}" -ge 16 ] && ok "токен не короче 16 символов" \
                     || no "длина токена" ">=16" "${#SID}"

COOKIE="z2kpsid=$SID" run 'panel_session_valid && echo yes || echo no' | grep -qx yes \
    && ok "свежая сессия принимается" || no "свежая сессия" "yes" "no"

# Чужой/выдуманный токен — мимо.
COOKIE="z2kpsid=deadbeefdeadbeefdeadbeef" run 'panel_session_valid && echo yes || echo no' | grep -qx no \
    && ok "выдуманный токен отвергается" || no "чужой токен" "no" "yes"
# Мусор в куке не должен ни приниматься, ни ломать разбор.
for junk in 'z2kpsid=../../etc/passwd' 'z2kpsid=a;rm -rf /' 'z2kpsid=' 'nothing=1'; do
    COOKIE="$junk" run 'panel_session_valid && echo yes || echo no' | grep -qx no \
        && ok "мусор в куке отвергнут: $junk" || no "мусор: $junk" "no" "принято"
done

# Просрочка. Возраст свежей сессии — ноль, а истекает она при возрасте СТРОГО
# больше TTL, поэтому просто выставить TTL=0 мало: старим саму метку времени.
SID_OLD=$(run 'panel_session_create admin')
printf '%s\nadmin\n' "$(( $(date +%s) - 99999 ))" > "$TMP/sess/$SID_OLD"
COOKIE="z2kpsid=$SID_OLD" run 'panel_session_valid && echo yes || echo no' | grep -qx no \
    && ok "просроченная сессия отвергается" || no "просрочка" "no" "принято"
# И файл просроченной сессии за собой убирается, а не копится в /tmp.
[ -f "$TMP/sess/$SID_OLD" ] && no "просроченная сессия удаляется" "файла нет" "остался" \
                           || ok "просроченная сессия удаляется с диска"

# Выход и общий сброс — то, чем меню выкидывает всех при выключении пароля.
SID2=$(run 'panel_session_create admin')
COOKIE="z2kpsid=$SID2" run 'panel_session_drop; panel_session_valid && echo yes || echo no' | grep -qx no \
    && ok "выход убивает сессию" || no "выход" "no" "сессия жива"
SID3=$(run 'panel_session_create admin')
run 'panel_sessions_drop_all' >/dev/null
COOKIE="z2kpsid=$SID3" run 'panel_session_valid && echo yes || echo no' | grep -qx no \
    && ok "общий сброс выкидывает всех" || no "сброс всех" "no" "сессия жива"

# --- 3. Ворота: что открыто без входа ------------------------------------------
#
# Вход и состояние обязаны быть доступны, иначе страница не сможет даже узнать,
# что от неё хотят пароль. Всё остальное — закрыто.
printf 'Z2K_PANEL_AUTH=1\n' > "$TMP/config"
for p in /auth/challenge /auth/login /auth/state; do
    out=$(PINFO="$p" run 'panel_auth_gate; echo PASSED')
    case "$out" in
        *PASSED*) ok "без входа доступно: $p" ;;
        *) no "доступ к $p" "пропущен" "закрыт" ;;
    esac
done
for p in /status /service/restart /uninstall; do
    out=$(PINFO="$p" run 'panel_auth_gate; echo PASSED')
    case "$out" in
        *PASSED*) no "закрыт без входа: $p" "401" "пропущен" ;;
        *401*) ok "без входа закрыт: $p" ;;
        *) no "закрыт без входа: $p" "401" "$out" ;;
    esac
done
# Признак needauth машиночитаемый: по тексту ошибки форму входа не показывают.
PINFO=/status run 'panel_auth_gate' | grep -q '"needauth":true' \
    && ok "в отказе есть машиночитаемый признак needauth" \
    || no "признак needauth" '"needauth":true' "нет"
# При выключенном пароле ворота не мешают вовсе.
printf 'Z2K_PANEL_AUTH=0\n' > "$TMP/config"
PINFO=/status run 'panel_auth_gate; echo PASSED' | grep -q PASSED \
    && ok "с выключенным паролем ворота пропускают всё" \
    || no "выключенный пароль" "пропуск" "закрыто"

# --- 4. Роутер не ответил ≠ пароль неверный ------------------------------------
#
# 203.0.113.1 — документационный диапазон, гарантированно не отвечает.
printf 'Z2K_PANEL_AUTH=1\n' > "$TMP/config"
rc=$(Z2K_PANEL_CONFIG="$TMP/config" Z2K_NDM_HOST=203.0.113.1 \
     sh -c '. "$1" 2>/dev/null; panel_verify_router_password admin x >/dev/null 2>&1; echo $?' _ "$AUTH")
[ "$rc" = "2" ] && ok "недоступный роутер даёт отдельный код (2), а не «неверный пароль»" \
               || no "код при недоступном роутере" "2" "$rc"

# И API обязан превратить этот код в отдельное сообщение, называющее выход.
# Диапазон до ветки-уровня, а не до первого ";;": внутри есть вложенный
# case "$?" со своими ";;", и короткий диапазон резал разбор на третьей строке.
_login=$(awk '/"POST \/auth\/login"\)/{p=1} p{print} p&&/^        ;;$/{exit}' "$API")
case "$_login" in
    *"2)"*) ok "API различает код 2 отдельной веткой" ;;
    *) no "ветка кода 2 в API" "есть" "нет" ;;
esac
case "$_login" in
    *"меню роутера"*) ok "в тексте отказа назван аварийный выход" ;;
    *) no "аварийный выход в тексте" "упоминание меню роутера" "нет" ;;
esac
case "$_login" in
    *"401 Unauthorized"*) ok "неверный пароль — отдельный ответ 401" ;;
    *) no "401 при неверном пароле" "есть" "нет" ;;
esac

# --- 5. Регрессии, на которые я уже наступил -----------------------------------
#
# Петля: ndm её не слушает, с 127.0.0.1 приходит 403 без вызова.
if grep -q 'Z2K_NDM_HOST:-127\.0\.0\.1' "$AUTH"; then
    no "адрес роутера не захардкожен на петлю" "подбор кандидатов" "вернулся 127.0.0.1"
else
    ok "адрес веб-интерфейса роутера подбирается, а не задан петлёй"
fi
grep -q '_panel_ndm_candidates' "$AUTH" \
    && ok "кандидаты перебираются до первого, кто отдаст вызов" \
    || no "перебор кандидатов" "_panel_ndm_candidates" "нет"
# od: есть на роутере, но нужную комбинацию флагов не понимает.
# Комментарии выкидываем: внутри функции od назван по имени в объяснении,
# почему его там больше нет, и голый grep зеленел бы на прозе.
if awk '/^panel_session_create\(\)/,/^}/' "$AUTH" | grep -vE '^\s*#' | grep -qE '(^|[^a-z])od '; then
    no "токен не зависит от od" "openssl/md5sum" "вернулся od — он отдаёт пустоту"
else
    ok "токен генерируется без od"
fi

# --- 6. Тег http: пароль от сетевой папки не открывает управление обходом -------
grep -q 'panel_user_has_http_tag' "$AUTH" \
    && ok "проверяется право учётки на веб-интерфейс" \
    || no "проверка тега http" "panel_user_has_http_tag" "нет"
awk '/^panel_verify_router_password\(\)/,/^}/' "$AUTH" | grep -q 'panel_user_has_http_tag' \
    && ok "тег проверяется в самом входе, а не где-то рядом" \
    || no "тег проверяется при входе" "вызов внутри verify" "нет"

# --- 7. Аварийный выход в терминале --------------------------------------------
_toggle=$(awk '/^webpanel_toggle_auth\(\)/,/^}/' "$WP")
[ -n "$_toggle" ] && ok "в меню есть переключатель входа" \
                  || no "переключатель в меню" "webpanel_toggle_auth" "нет"
grep -q '6) webpanel_toggle_auth' "$WP" \
    && ok "переключатель подключён к пункту меню" \
    || no "пункт меню" "6) webpanel_toggle_auth" "нет"
# Выключение обязано выкидывать открытые сессии: иначе тот, кто уже вошёл,
# останется внутри после того, как пароль сняли.
_off=$(printf '%s\n' "$_toggle" | awk '/Выключить вход/,/fi$/')
case "$_off" in
    *z2k-panel-sessions*) ok "выключение сбрасывает открытые сессии" ;;
    *) no "сброс сессий при выключении" "rm сессий" "нет" ;;
esac

# --- 8. Панель показывает форму, а не красную плашку ---------------------------
if ! command -v node >/dev/null 2>&1; then
    SKIP=$((SKIP+1))
    printf '[SKIP] панельная часть (нет node; в CI проверяется)\n'
else
    _hooks=$(grep -c 'needauth) { showLoginScreen' "$APPJS" 2>/dev/null || echo 0)
    # Три помощника ходят в API: apiGet, apiPost, apiPostText. Пропустить один —
    # значит на части страниц получить красную плашку вместо формы входа.
    if [ "${_hooks:-0}" -ge 3 ]; then
        ok "форму входа показывают все помощники API ($_hooks из 3)"
    else
        no "перехват needauth во всех помощниках" "3" "${_hooks:-0}"
    fi
    grep -q 'function showLoginScreen' "$APPJS" \
        && ok "экран входа есть" || no "экран входа" "showLoginScreen" "нет"
    # На экране входа человеку сказано, где выход, если он не может войти.
    awk '/function showLoginScreen/,/^  }/' "$APPJS" | grep -q 'меню роутера' \
        && ok "на экране входа назван способ снять пароль" \
        || no "подсказка на экране входа" "упоминание меню роутера" "нет"
fi

# --- 9. БЛОКИРУЮЩЕЕ: флаг переживает перегенерацию конфига ----------------------
#
# Найдено вычиткой и воспроизведено запуском генератора. set_flag дописывает
# Z2K_PANEL_AUTH в конец /opt/zapret2/config, а create_official_config пишет
# конфиг С НУЛЯ по фиксированному списку ключей и подменяет файл. Ключа в
# списке не было — и пароль снимался сам: достаточно щёлкнуть любой тумблер в
# панели (каждый зовёт regenerate_config) или дождаться ночного обновления.
# Выключатель безопасности, который выключается сам, хуже его отсутствия.
CO="$ROOT/lib/config_official.sh"
_missing=""
grep -q 'local saved_Z2K_PANEL_AUTH=' "$CO" || _missing="$_missing умолчание"
grep -q 'saved_Z2K_PANEL_AUTH=$(safe_config_read "Z2K_PANEL_AUTH"' "$CO" || _missing="$_missing чтение"
grep -q '^Z2K_PANEL_AUTH=\${saved_Z2K_PANEL_AUTH}' "$CO" || _missing="$_missing запись"
if [ -z "$_missing" ]; then
    ok "флаг входа объявлен в генераторе конфига (умолчание, чтение, запись)"
else
    no "флаг в генераторе" "все три места" "нет:$_missing"
fi
# И то же самое ДЕЛОМ: гоняем настоящий генератор и смотрим, выжил ли ключ.
if command -v awk >/dev/null 2>&1; then
    GT="$TMP/gen"; mkdir -p "$GT"
    printf 'Z2K_PANEL_AUTH=1\nENABLED=1\n' > "$GT/config"
    ( cd "$ROOT" && ZAPRET2_DIR="$GT" sh -c '. lib/utils.sh 2>/dev/null; . lib/config_official.sh 2>/dev/null; create_official_config "$1" >/dev/null 2>&1' _ "$GT/config" ) || true
    if grep -q '^Z2K_PANEL_AUTH=1' "$GT/config" 2>/dev/null; then
        ok "включённый пароль переживает перегенерацию конфига (проверено запуском генератора)"
    else
        no "пароль переживает перегенерацию" "Z2K_PANEL_AUTH=1 на месте" \
           "$(grep -c '^Z2K_PANEL_AUTH' "$GT/config" 2>/dev/null || echo 0) — ключ стёрт"
    fi
fi

# --- 10. Пароль не покидает браузер ---------------------------------------------
#
# Первая версия принимала пароль в теле запроса и считала ответ на сервере —
# то есть пароль администратора роутера ехал по локальной сети открытым
# текстом. Схема x-ndw2-interactive существует ровно для того, чтобы этого не
# происходило; сервер обязан принимать только готовый ответ.
_login2=$(awk '/"POST \/auth\/login"\)/{p=1} p{print} p&&/^        ;;$/{exit}' "$API")
case "$_login2" in
    *'form_value "$body" "password"'*)
        no "пароль не приходит на сервер" "только готовый ответ" "сервер всё ещё читает поле password" ;;
    *) ok "сервер не принимает пароль — только посчитанный ответ" ;;
esac
case "$_login2" in
    *'form_value "$body" "response"'*) ok "принимается ответ, посчитанный страницей" ;;
    *) no "приём ответа" "поле response" "нет" ;;
esac
grep -q '"POST /auth/challenge"' "$API" \
    && ok "вызов выдаётся отдельным шагом" || no "шаг с вызовом" "POST /auth/challenge" "нет"
# Ответ обязан быть проверен по форме: 64 шестнадцатеричных символа.
awk '/^panel_verify_ndm_response\(\)/,/^}/' "$AUTH" | grep -q '"64"' \
    && ok "длина ответа проверяется" || no "проверка длины ответа" "64 символа" "нет"
# Билет одноразовый: файл удаляется при использовании.
awk '/^panel_challenge_use\(\)/,/^}/' "$AUTH" | grep -q 'rm -f "$_f"' \
    && ok "билет входа одноразовый" || no "одноразовость билета" "rm при использовании" "нет"

# --- 11. Токен не может стать константой ----------------------------------------
#
# Запасной путь считал md5 от ПУСТОГО ввода при недоступном /dev/urandom и
# уверенно возвращал d41d8cd98f00b204e9800998ecf8427e — одну и ту же строку на
# всех роутерах мира. Предсказуемый токен хуже отказа во входе.
awk '/^_panel_random_hex\(\)/,/^}/' "$AUTH" | grep -q 'd41d8cd98f00b204e9800998ecf8427e' \
    && ok "хеш пустого ввода распознаётся и отвергается" \
    || no "защита от md5 пустого ввода" "явная проверка константы" "нет"
_r1=$(run '_panel_random_hex'); _r2=$(run '_panel_random_hex')
[ -n "$_r1" ] && [ "$_r1" != "$_r2" ] \
    && ok "два вызова дают разные значения" \
    || no "случайность токена" "разные значения" "[$_r1] и [$_r2]"

# --- 12. Каталог сессий не перехватить -------------------------------------------
#
# /tmp общедоступен на запись, а tmpfs после перезагрузки пуст: между стартом
# и первым входом чужой процесс успевает создать каталог и подложить файл.
awk '/^_panel_mkdir_private\(\)/,/^}/' "$AUTH" | grep -q 'mkdir -m 700' \
    && ok "каталог сессий создаётся сразу с правами, без окна между mkdir и chmod" \
    || no "создание каталога" "mkdir -m 700" "нет"
awk '/^_panel_mkdir_private\(\)/,/^}/' "$AUTH" | grep -q '\-L "\$_d"' \
    && ok "подсунутая символьная ссылка вместо каталога отвергается" \
    || no "проверка на симлинк" "-L" "нет"

# --- 13. Сессия привязана к клиенту ----------------------------------------------
#
# Кука ходит по открытому HTTP. Без привязки перехваченный заголовок давал бы
# полный вход к CGI, работающему от root, на всё время жизни сессии.
awk '/^panel_session_valid\(\)/,/^}/' "$AUTH" | grep -q 'REMOTE_ADDR' \
    && ok "сессия проверяет адрес клиента" || no "привязка сессии" "REMOTE_ADDR" "нет"
SID_A=$(REMOTE_ADDR=192.168.1.50 Z2K_PANEL_CONFIG="$TMP/config" Z2K_PANEL_SESS_DIR="$TMP/sess" \
        sh -c '. "$1"; panel_session_create admin' _ "$AUTH")
_v=$(REMOTE_ADDR=192.168.1.99 COOKIE="z2kpsid=$SID_A" run 'panel_session_valid && echo yes || echo no')
case "$_v" in
    *no*) ok "чужой адрес с той же кукой не принимается" ;;
    *) no "кука с чужого адреса" "no" "$_v" ;;
esac
_v=$(REMOTE_ADDR=192.168.1.50 COOKIE="z2kpsid=$SID_A" Z2K_PANEL_CONFIG="$TMP/config" \
     Z2K_PANEL_SESS_DIR="$TMP/sess" HTTP_COOKIE="z2kpsid=$SID_A" \
     sh -c '. "$1"; panel_session_valid && echo yes || echo no' _ "$AUTH")
case "$_v" in
    *yes*) ok "со своего адреса кука работает" ;;
    *) no "кука со своего адреса" "yes" "$_v" ;;
esac
# Испорченная метка времени — не «свежая сессия».
BAD=$(run 'panel_session_create admin'); printf 'мусор\nadmin\n1.2.3.4\n' > "$TMP/sess/$BAD"
COOKIE="z2kpsid=$BAD" REMOTE_ADDR=1.2.3.4 run 'panel_session_valid && echo yes || echo no' | grep -qx no \
    && ok "мусор вместо метки времени отвергается" || no "битая метка" "no" "принято"

# --- 14. Нечитаемый конфиг не открывает двери ------------------------------------
_fn=$(awk '/^panel_auth_enabled\(\)/,/^}/' "$AUTH")
case "$_fn" in
    *'! -r "$Z2K_PANEL_CONFIG" ]; then'*'return 0'*)
        ok "нечитаемый конфиг трактуется как «пароль включён», а не наоборот" ;;
    *) no "нечитаемый конфиг" "fail-closed" "открывает доступ" ;;
esac
case "$_fn" in
    *'! -e "$Z2K_PANEL_CONFIG"'*) ok "отсутствующий конфиг отличается от нечитаемого" ;;
    *) no "различение нет/не читается" "проверка -e" "нет" ;;
esac

# --- 15. Потолок размера тела ------------------------------------------------------
#
# Два маршрута входа доступны без сессии, а read_body — это `dd bs=1`, сисколл
# на байт. Проверка обязана быть в ОСНОВНОМ потоке: json_fail внутри
# `body=$(read_body)` завершает только подоболочку, и запрос продолжился бы.
grep -q 'Z2K_MAX_BODY' "$API" && ok "потолок размера тела объявлен" \
                              || no "потолок тела" "Z2K_MAX_BODY" "нет"
awk '/^read_body\(\)/,/^}/' "$API" | grep -q 'json_fail' \
    && no "ответ не отправляется из подстановки" "без json_fail в read_body" "json_fail внутри read_body" \
    || ok "read_body не пытается отвечать из подстановки"
_gate_line=$(grep -n 'panel_auth_gate$' "$API" | head -1 | cut -d: -f1)
_cap_line=$(grep -n 'Payload Too Large' "$API" | head -1 | cut -d: -f1)
_case_line=$(grep -n '^case "\$method \$path" in' "$API" | head -1 | cut -d: -f1)
if [ -n "$_cap_line" ] && [ "$_cap_line" -gt "${_gate_line:-0}" ] && [ "$_cap_line" -lt "${_case_line:-999999}" ]; then
    ok "проверка размера стоит до разбора маршрута"
else
    no "место проверки размера" "между воротами и разбором" "ворота=$_gate_line потолок=$_cap_line case=$_case_line"
fi
# Крупные загрузки не должны попасть под общий потолок.
grep -q '/warp/list/save|/whitelist/import|/strategy/pool/save|/strategy/pool/validate' "$API" \
    && ok "маршруты крупных загрузок выведены из-под общего потолка" \
    || no "исключения для крупных загрузок" "перечислены" "нет"

# --- 16. Форма входа не исчезает навсегда ------------------------------------------
#
# С булевой переменной форма ставилась один раз, а роутер страницы при каждой
# смене адреса затирает содержимое: после первого перехода человек оставался с
# пустыми скелетонами и без единого поля для пароля.
if command -v node >/dev/null 2>&1; then
    _sls=$(awk '/^  function showLoginScreen/,/^  }/' "$APPJS")
    case "$_sls" in
        *'_loginShown'*) no "признак показа формы не переменная" "проверка DOM" "остался _loginShown" ;;
        *'getElementById("login-go")'*) ok "показ формы определяется по DOM, а не переменной" ;;
        *) no "проверка показа формы" "getElementById" "нет" ;;
    esac
    grep -q 'function md5hex' "$APPJS" \
        && ok "MD5 считается в браузере" || no "MD5 в браузере" "md5hex" "нет"
    # SHA-256 НЕ ДОЛЖЕН ЗАВИСЕТЬ ОТ crypto.subtle.
    #
    # Полевой отказ r-75.14: по KeenDNS вход работал, по локалке — нет.
    # crypto.subtle доступен ТОЛЬКО в защищённом контексте, а панель по
    # умолчанию открывают по http://192.168.1.1:8088 — там его нет вовсе
    # (проверено в браузере на роутере: isSecureContext=false,
    # crypto.subtle=undefined). То есть вход ломался ровно на основном пути.
    grep -q 'function sha256hexJS' "$APPJS" \
        && ok "есть своя реализация SHA-256, не зависящая от защищённого контекста" \
        || no "своя SHA-256" "sha256hexJS" "нет — по локалке вход не сработает"
    awk '/^  async function sha256hex\(str\)/,/^  \}/' "$APPJS" | grep -q 'sha256hexJS' \
        && ok "при отсутствии crypto.subtle используется своя реализация" \
        || no "запасной путь" "вызов sha256hexJS" "нет"
    awk '/^  async function sha256hex\(str\)/,/^  \}/' "$APPJS" | grep -q 'isSecureContext' \
        && ok "защищённость контекста проверяется явно" \
        || no "проверка контекста" "isSecureContext" "нет"

    # И сама реализация обязана считать ВЕРНО — иначе запасной путь просто
    # меняет отказ на неверный пароль.
    _sha=$(node -e '
      const fs=require("fs"), crypto=require("crypto");
      const src=fs.readFileSync(process.argv[1],"utf8");
      const m=src.match(/function sha256hexJS\(str\)[\s\S]*?\n  \}/);
      if(!m){console.log("MISSING");process.exit(0);}
      const f=new Function("TextEncoder","DataView","Uint8Array","Uint32Array",
                m[0]+"; return sha256hexJS;")(require("util").TextEncoder,DataView,Uint8Array,Uint32Array);
      const cases=["","abc","admin:Keenetic Ultra:test","ы".repeat(100),"x".repeat(1000)];
      const bad=cases.filter(c => f(c)!==crypto.createHash("sha256").update(c,"utf8").digest("hex"));
      console.log(bad.length ? "BAD:"+bad.length : "OK");
    ' "$APPJS" 2>&1)
    case "$_sha" in
        OK) ok "своя SHA-256 совпадает с эталоном на всех проверенных входах" ;;
        MISSING) no "sha256hexJS найдена" "функция" "нет" ;;
        *) no "своя SHA-256 считает верно" "совпадение с эталоном" "$_sha" ;;
    esac
    # Пароль не должен уходить в тело запроса.
    awk '/const submit = async/,/^    };/' "$APPJS" | grep -q 'password: pass.value' \
        && no "пароль не уходит в сеть" "в теле только response" "пароль в теле запроса" \
        || ok "в теле запроса пароля нет — только посчитанный ответ"
fi

# --- Форма входа обязана появляться на ВСЕХ четырёх помощниках --------------
#
# Полевой класс, найденный ревью 08-14: ветка needauth была добавлена одним
# диффом сразу в apiGet, apiPost и apiPostText, а apiGetText в тот дифф не
# попал. Между тем через него идут четыре живых вызова — правка списка WARP
# (дважды), выгрузка диагностики и редактор своей стратегии. Сервер на
# протухшей сессии отдаёт 401 {needauth:true} на ЛЮБОЙ маршрут кроме /auth/*,
# поэтому человек, вернувшийся к вкладке через два часа, получал тост с
# невнятной причиной и НИ ОДНОГО способа войти: формы не было вовсе.
#
# Проверяем все четыре, а не только починенный: расходятся они именно так —
# правку вносят в те, что под рукой.
_missing=""
for _fn in apiGet apiPost apiGetText apiPostText; do
    _body=$(awk "/async function ${_fn}\\(/,/^  }$/" "$APPJS")
    case "$_body" in
        *needauth*showLoginScreen*) ;;
        *) _missing="$_missing $_fn" ;;
    esac
done
if [ -z "$_missing" ]; then
    ok "форма входа показывается из всех четырёх помощников fetch"
else
    no "needauth во всех помощниках" "все четыре" "нет в:$_missing — там человек останется без формы входа"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
