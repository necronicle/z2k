#!/bin/sh
# tests/test_auto_update_toggle.sh
#
# Users asked to be able to switch off unattended updates. The trap in a feature
# like this is what "off" is allowed to mean:
#
#   * It must stop the NIGHTLY apply — that is the whole request.
#   * It must NOT stop a deliberate one. If flipping the switch also disabled the
#     "Обновить" button, the user would have opted out of ever updating again,
#     including out of security fixes, without being told.
#   * It must NOT stop `check`, or the dashboard goes quiet about new versions
#     for exactly the people who chose to update by hand.
#
# The gate is therefore asserted by RUNNING the shipped script against a fake
# install root, not by grepping it: what matters is whether au_run_apply is
# reached, and only an execution can answer that.
#
# One more thing is pinned here. The config key is Z2K_AUTO_UPDATE_ENABLED and
# must never be shortened to Z2K_AUTO_UPDATE: that name is already an ENV marker
# meaning "this reinstall was launched by the updater", read by lib/install.sh
# and z2k.sh to decide how to merge the user's config. A config key colliding
# with it could silently change reinstall behaviour.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="$HERE/files/z2k-auto-update.sh"
ACTIONS="$HERE/webpanel/cgi/actions.sh"
API="$HERE/webpanel/cgi/api.sh"
APPJS="$HERE/webpanel/www/app.js"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/autoupd.XXXXXX") || exit 1
API_JOBS=""
cleanup() {
    for _j in $API_JOBS; do
        rm -f "/tmp/z2k-job-$_j.log" "/tmp/z2k-job-$_j.pid" "/tmp/z2k-job-$_j.exit"
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

for f in "$SRC" "$ACTIONS" "$API" "$APPJS"; do
    [ -f "$f" ] || { printf '[FAIL] missing %s\n' "$f"; exit 1; }
done

# ---------------------------------------------------------------------------
# A fake install root, so the real script can run without an /opt/zapret2.
# ---------------------------------------------------------------------------
ROOT="$TMP/opt"
mkdir -p "$ROOT/lib"
printf 'z2k-enhanced\n' > "$ROOT/.z2k-branch"
: > "$ROOT/lib/utils.sh"
cat > "$ROOT/lib/auto_update.sh" <<'STUB'
au_run_apply() { echo "APPLY_RAN"; }
au_run_check() { echo "CHECK_RAN"; }
STUB

UNDER_TEST="$TMP/z2k-auto-update.sh"
sed "s|^ZAPRET2_DIR=\"/opt/zapret2\"|ZAPRET2_DIR=\"$ROOT\"|" "$SRC" > "$UNDER_TEST"
grep -q "ZAPRET2_DIR=\"$ROOT\"" "$UNDER_TEST" \
    && ok "фикстура: корень установки подменён" \
    || { no "фикстура: корень установки подменён" "$ROOT" "не подставился"; exit 1; }

# Z2K_AU_NO_JITTER is unrelated to the toggle — it only suppresses the 0..90min
# nightly spread, which would otherwise make this suite sleep. Set everywhere.
run() {
    # run <config-line-or-empty> <action> [extra-env]
    if [ -n "$1" ]; then printf '%s\n' "$1" > "$ROOT/config"; else : > "$ROOT/config"; fi
    env Z2K_AU_NO_JITTER=1 ${3:-IGNORE=1} sh "$UNDER_TEST" "$2" 2>&1
}

# --- the gate ---------------------------------------------------------------
out=$(run "" apply)
case "$out" in *APPLY_RAN*) ok "по умолчанию (флага нет) плановое обновление идёт" ;;
               *) no "по умолчанию плановое обновление идёт" "APPLY_RAN" "$out" ;; esac

out=$(run 'Z2K_AUTO_UPDATE_ENABLED=1' apply)
case "$out" in *APPLY_RAN*) ok "флаг=1 — плановое обновление идёт" ;;
               *) no "флаг=1 — плановое обновление идёт" "APPLY_RAN" "$out" ;; esac

out=$(run 'Z2K_AUTO_UPDATE_ENABLED=0' apply)
case "$out" in *APPLY_RAN*) no "флаг=0 — плановое обновление НЕ идёт" "без APPLY_RAN" "$out" ;;
               *) ok "флаг=0 — плановое обновление НЕ идёт" ;; esac
case "$out" in *"отключено в настройках"*) ok "причина пропуска написана в лог" ;;
               *) no "причина пропуска написана в лог" "текст про отключение" "$out" ;; esac

# Exit code must be 0: a deliberate opt-out is not a failure, and a non-zero rc
# would make the scheduler treat it as a broken task.
run 'Z2K_AUTO_UPDATE_ENABLED=0' apply >/dev/null 2>&1
[ "$?" = 0 ] && ok "пропуск завершается кодом 0, а не ошибкой" \
             || no "пропуск завершается кодом 0" "0" "$?"

# --- what "off" must NOT break ----------------------------------------------
out=$(run 'Z2K_AUTO_UPDATE_ENABLED=0' apply 'Z2K_AU_MANUAL=1')
case "$out" in *APPLY_RAN*) ok "при выключенном автообновлении РУЧНОЕ всё равно работает" ;;
               *) no "ручное обновление работает при выключенном авто" "APPLY_RAN" "$out" ;; esac

out=$(run 'Z2K_AUTO_UPDATE_ENABLED=0' check)
case "$out" in *CHECK_RAN*) ok "проверка наличия обновлений не блокируется" ;;
               *) no "проверка наличия обновлений не блокируется" "CHECK_RAN" "$out" ;; esac

# --- the value is parsed like every other flag in the config ----------------
out=$(run 'Z2K_AUTO_UPDATE_ENABLED="0"' apply)
case "$out" in *APPLY_RAN*) no "значение в кавычках распознаётся" "без APPLY_RAN" "$out" ;;
               *) ok "значение в кавычках распознаётся" ;; esac
out=$(run 'Z2K_AUTO_UPDATE_ENABLED= 0' apply)
case "$out" in *APPLY_RAN*) no "значение с пробелом распознаётся" "без APPLY_RAN" "$out" ;;
               *) ok "значение с пробелом распознаётся" ;; esac
# Anything that is not exactly 0 must leave updates ON — fail safe, not silent off.
out=$(run 'Z2K_AUTO_UPDATE_ENABLED=' apply)
case "$out" in *APPLY_RAN*) ok "пустое значение = включено (не выключаем молча)" ;;
               *) no "пустое значение = включено" "APPLY_RAN" "$out" ;; esac

# --- the name must not collide with the env marker --------------------------
grep -qE '^\s*AU_ENABLED=.*Z2K_AUTO_UPDATE_ENABLED=' "$SRC" \
    && ok "ключ конфига называется Z2K_AUTO_UPDATE_ENABLED" \
    || no "ключ конфига называется Z2K_AUTO_UPDATE_ENABLED" "полное имя" "иное"
grep -qE '/\^Z2K_AUTO_UPDATE=' "$SRC" \
    && no "ключ не совпадает с env-маркером Z2K_AUTO_UPDATE" "не совпадает" "совпал" \
    || ok "ключ не совпадает с env-маркером Z2K_AUTO_UPDATE"
# and the env marker itself is still what install.sh keys off
grep -q '"\$Z2K_AUTO_UPDATE" = "1"' "$HERE/lib/install.sh" \
    && ok "install.sh по-прежнему читает env-маркер Z2K_AUTO_UPDATE" \
    || no "install.sh читает env-маркер Z2K_AUTO_UPDATE" "проверка есть" "отсутствует"

# --- the toggle itself ------------------------------------------------------
CONFIG_FILE="$TMP/cfg"; export CONFIG_FILE
ZAPRET2_DIR="$ROOT"; export ZAPRET2_DIR
# shellcheck disable=SC1090
. "$ACTIONS" 2>/dev/null

printf 'SOMETHING=1\n' > "$CONFIG_FILE"
toggle_auto_update 0 >/dev/null 2>&1
[ "$(grep -c '^Z2K_AUTO_UPDATE_ENABLED=0$' "$CONFIG_FILE")" = 1 ] \
    && ok "toggle_auto_update дописывает флаг, когда его не было" \
    || no "toggle_auto_update дописывает флаг" "одна строка =0" "$(grep -c 'Z2K_AUTO_UPDATE_ENABLED' "$CONFIG_FILE")"

# set_flag rewrites an existing line with `sed -i`, which BSD sed (macOS) rejects
# without a backup suffix while GNU sed and the router's busybox accept it. The
# assertion is real and runs in CI on Linux; locally on a Mac it would only be
# measuring the developer's sed, so it is skipped explicitly rather than
# weakened for everyone.
if printf 'a\n' > "$TMP/sedprobe" && sed -i 's/a/b/' "$TMP/sedprobe" 2>/dev/null; then
    toggle_auto_update 1 >/dev/null 2>&1
    if [ "$(grep -c '^Z2K_AUTO_UPDATE_ENABLED=1$' "$CONFIG_FILE")" = 1 ] \
       && [ "$(grep -c 'Z2K_AUTO_UPDATE_ENABLED' "$CONFIG_FILE")" = 1 ]; then
        ok "повторное переключение правит строку, а не плодит дубликаты"
    else
        no "повторное переключение не плодит дубликаты" "ровно одна строка =1" \
           "$(grep 'Z2K_AUTO_UPDATE_ENABLED' "$CONFIG_FILE" | tr '\n' ' ')"
    fi
else
    printf '[SKIP] повторное переключение правит строку (у этого sed нет -i без суффикса — BSD/macOS; в CI проверяется)\n'
fi

[ "$(read_flag Z2K_AUTO_UPDATE_ENABLED "$TMP/does-not-exist" 1)" = 1 ] \
    && ok "без конфига флаг читается как включённый" \
    || no "без конфига флаг читается как включённый" "1" "иное"

# --- the flag has to survive a reinstall ------------------------------------
# Nothing enumerates flags by name — au_save_feature_flags carries everything
# matching ^Z2K_*, which is why this one needed no extra plumbing. Asserted, so
# a future narrowing of that pattern cannot silently re-enable updates for
# everyone who opted out.
printf 'Z2K_AUTO_UPDATE_ENABLED=0\nOTHER=1\n' > "$ROOT/config"
sh -c "Z2K_AU_SOURCE_ONLY=1 . '$HERE/lib/auto_update.sh' 2>/dev/null
       ZAPRET2_DIR='$ROOT' au_save_feature_flags '$TMP/flags.out' >/dev/null 2>&1"
grep -q '^Z2K_AUTO_UPDATE_ENABLED=0$' "$TMP/flags.out" 2>/dev/null \
    && ok "флаг переносится через reinstall (au_save_feature_flags)" \
    || no "флаг переносится через reinstall" "строка в бэкапе" "отсутствует"

# --- the manual path must mark itself --------------------------------------
# Comment lines are stripped before matching. The docstring inside this very
# function names both variables, so an unfiltered grep would pass on the prose
# after the code had been deleted — a test that asserts its own comments.
apply_fn=$(awk '/^update_apply_async\(\)/{f=1} f{print} f&&/^}/{exit}' "$ACTIONS" \
           | sed 's/^[[:space:]]*#.*$//')
case "$apply_fn" in *'Z2K_AU_MANUAL=1'*) ok "кнопка «Обновить» помечает запуск как ручной" ;;
                    *) no "кнопка «Обновить» помечает запуск как ручной" "Z2K_AU_MANUAL=1" "нет" ;; esac
# Same line fixes a separate, pre-existing defect: the subshell closes stdin, so
# the updater could not tell a button press from cron and slept the nightly
# 0..90min jitter with an empty job log.
case "$apply_fn" in *'Z2K_AU_NO_JITTER=1'*) ok "ручной запуск не уходит в ночной jitter (до 90 мин)" ;;
                    *) no "ручной запуск не уходит в ночной jitter" "Z2K_AU_NO_JITTER=1" "нет" ;; esac

# --- фоновая задача обязана пережить смерть панели --------------------------
#
# busybox ash шлёт SIGHUP фоновым детям, когда обёртка завершается, а
# CGI-обёртка завершается немедленно — она возвращает браузеру job_id. Плюс
# установка перезапускает саму панель, под которой эта задача и живёт. Без
# игнорирования HUP обновление через панель обрывалось на середине: дерево
# /opt/zapret2 уже переименовано, установка убита, код завершения не записан.
# Снаружи — «панель ответила 404, чем кончилась задача неизвестно», трое
# пользователей на r-74. Замерено на роутере: без строки задача умирает и
# .exit не появляется, с ней доживает и пишет 0.
#
# Комментарии выше вырезаны из apply_fn, так что тест не может пройти на
# собственной прозе.
case "$apply_fn" in *"trap '' HUP"*) ok "фоновое обновление игнорирует HUP (переживает перезапуск панели)" ;;
                    *) no "фоновое обновление игнорирует HUP" "trap '' HUP в подоболочке" \
                          "нет — обновление через панель оборвётся на переезде дерева" ;; esac

# --- HTTP surface ----------------------------------------------------------
# Проверяется ОТВЕТ api.sh, а не его исходник. Прежние утверждения грепали
# написание printf ('"auto_update":"%s"' и «сбалансированность» плейсхолдеров с
# аргументами): разбиение одной строки формата на цепочку json_string не меняет
# в ответе ни байта, но грепу видится пропажей поля. Такой тест охраняет форму
# кода, а не контракт с фронтом — и краснеет на правках, которые контракт как
# раз чинят.
API_SB="$TMP/apiroot"
API_CFG="$API_SB/config"
mkdir -p "$API_SB/lists" "$API_SB/lib"
printf '#!/bin/sh\ncreate_official_config() { return 0; }\n' > "$API_SB/lib/config_official.sh"
printf '#!/bin/sh\nsafe_config_read() { return 0; }\n'       > "$API_SB/lib/utils.sh"
printf '#!/bin/sh\nexit 0\n' > "$API_SB/S99-stub"
chmod +x "$API_SB/S99-stub"

# HTTP_X_Z2K_PANEL — то же, что app.js шлёт на каждом fetch; без него
# origin-страж в cgi/auth.sh отвечает 403 и до роутинга дело не доходит.
api_cgi() { # api_cgi <METHOD> <PATH_INFO> <QUERY> [файл-тела] -> тело ответа
    _m="$1"; _p="$2"; _q="$3"; _b="${4:-/dev/null}"
    _cl=0; [ "$_b" = /dev/null ] || _cl=$(wc -c < "$_b" | tr -d ' ')
    env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
        HTTP_HOST=192.168.1.1 HTTP_X_Z2K_PANEL=1 CONTENT_LENGTH="$_cl" \
        ZAPRET2_DIR="$API_SB" CONFIG_FILE="$API_CFG" LISTS_DIR="$API_SB/lists" \
        STATE_FILE="$API_SB/state.tsv" INIT_SCRIPT="$API_SB/S99-stub" \
        sh "$API" < "$_b" 2>/dev/null | awk 'b{print} /^\r?$/{b=1}'
}
tgl() { printf '%s' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'; }

printf 'ENABLED=1\n' > "$API_CFG"
body=$(api_cgi GET /status "")
got=$(tgl "$body" auto_update)
[ -n "$got" ] && ok "GET /status отдаёт поле auto_update" \
              || no "GET /status отдаёт поле auto_update" "поле в JSON" "отсутствует"
[ "$got" = 1 ] && ok "без флага в конфиге поле равно 1 (дефолт)" \
               || no "без флага в конфиге поле равно 1" "1" "$got"

# Маршрут POST /toggle/auto-update — сквозняком: тумблер обязан дописать флаг в
# конфиг и после этого измениться в /status. Раньше существование маршрута и
# его связка с toggle_auto_update проверялись двумя грепами по api.sh.
printf 'value=0' > "$TMP/toggle-body"
body=$(api_cgi POST /toggle/auto-update "" "$TMP/toggle-body")
job=$(printf '%s' "$body" | sed -n 's/.*"job":"\([0-9]*\)".*/\1/p')
API_JOBS="$API_JOBS $job"
[ -n "$job" ] && ok "POST /toggle/auto-update завёл задачу" \
              || no "POST /toggle/auto-update завёл задачу" "job id" "$body"
_w=0
while [ "$_w" -lt 10 ]; do
    [ -f "/tmp/z2k-job-$job.exit" ] && break
    _w=$((_w + 1)); sleep 1
done
[ "$(grep -c '^Z2K_AUTO_UPDATE_ENABLED=0$' "$API_CFG")" = 1 ] \
    && ok "маршрут действительно выключил автообновление в конфиге" \
    || no "маршрут выключил автообновление в конфиге" "строка =0" \
          "$(grep 'Z2K_AUTO_UPDATE_ENABLED' "$API_CFG" | tr '\n' ' ')"
got=$(tgl "$(api_cgi GET /status "")" auto_update)
[ "$got" = 0 ] && ok "выключенное состояние видно в GET /status" \
               || no "выключенное состояние видно в GET /status" "0" "$got"

# Соседние поля не должны разъезжаться: раньше это стерегла проверка на
# «сбалансированность» плейсхолдеров, теперь — четыре различимых значения,
# каждое на своём месте.
printf 'ENABLED=1\nRST_FILTER=1\nZ2K_STATS=0\nZ2K_AUTO_UPDATE_ENABLED=0\nZ2K_AUTOHOSTLIST=1\n' > "$API_CFG"
body=$(api_cgi GET /status "")
got="$(tgl "$body" rst_filter)|$(tgl "$body" stats)|$(tgl "$body" auto_update)|$(tgl "$body" autohostlist)"
[ "$got" = "1|0|0|1" ] && ok "тумблеры в JSON не съехали друг относительно друга" \
                       || no "тумблеры в JSON не съехали" "1|0|0|1" "$got"

# Значение-ловушка: read_flag снимает только ОКРУЖАЮЩИЕ кавычки, так что
# правленный руками конфиг отдаёт значение с кавычкой внутри. Если оно уедет в
# "%s" как есть — невалидным станет ВЕСЬ ответ, и дашборд покажет «Ошибка»
# целиком, а не один тумблер.
printf 'ENABLED=1\nZ2K_AUTO_UPDATE_ENABLED=0"x\n' > "$API_CFG"
body=$(api_cgi GET /status "")
if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 \
        && ok "значение с кавычкой не рвёт JSON ответа" \
        || no "значение с кавычкой не рвёт JSON ответа" "валидный JSON" "$body"
    got=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["toggles"]["auto_update"])' 2>/dev/null)
    [ "$got" = '0"x' ] && ok "значение доехало экранированным, без потерь" \
                       || no "значение доехало экранированным" '0"x' "$got"
else
    printf '[SKIP] значение с кавычкой не рвёт JSON ответа (нет python3; в CI проверяется)\n'
fi

# --- UI --------------------------------------------------------------------
grep -q 'key: "auto_update"' "$APPJS" \
    && ok "тумблер есть в списке режимов" \
    || no "тумблер есть в списке режимов" "TOGGLE_DEFS" "отсутствует"
grep -q 'auto_update: "auto-update"' "$APPJS" \
    && ok "имя маршрута для UI задано" \
    || no "имя маршрута для UI задано" "TOGGLE_API_NAME" "отсутствует"
grep -q 's.toggles.auto_update' "$APPJS" \
    && ok "состояние выведено на дашборд" \
    || no "состояние выведено на дашборд" "строка статуса" "отсутствует"
# Off is a state worth noticing, not an error: amber, and the class must exist.
grep -q '\.status-cell\.warn' "$HERE/webpanel/www/style.css" \
    && ok "класс .status-cell.warn существует (выключенное состояние видно)" \
    || no "класс .status-cell.warn существует" "css-класс" "отсутствует"
# A toggle that is not in TOGGLES_RESTART_SERVICE must not restart the service —
# switching off updates has nothing to do with the bypass.
# Свойство, а не литерал: важно ровно то, что auto_update НЕ в списке
# перезапускающих сервис — переключение автообновления к обходу отношения не
# имеет. Пиннинг всей строки ломался от появления любого нового тумблера.
_restart_map=$(sed -n 's/.*TOGGLES_RESTART_SERVICE = {\(.*\)};.*/\1/p' "$APPJS")
case "$_restart_map" in
    *auto_update*) no "переключение не перезапускает сервис" "auto_update вне списка" "в списке" ;;
    "")            no "список рестартующих тумблеров найден" "TOGGLES_RESTART_SERVICE" "нет" ;;
    *)             ok "переключение не перезапускает сервис" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
