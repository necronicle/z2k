#!/bin/sh
# tests/test_panel_uninstall.sh — удаление z2k из панели: подтверждение, запуск,
# и честный финал.
#
# ПОЧЕМУ ЭТОТ ТЕСТ ВООБЩЕ НУЖЕН. Это единственный необратимый вызов во всём
# API панели, и у него три места, где ошибка не прощается:
#
#   1. Подтверждение. Панель работает БЕЗ авторизации — она доверяет всей
#      локальной сети так же, как веб-интерфейс роутера. Origin-guard защищает
#      от чужого сайта, но не от запроса, посланного из этой же сети. Значит
#      слово подтверждения обязан проверять сервер, а не только страница:
#      голый POST /uninstall не должен сносить роутер.
#
#   2. Неинтерактивность. uninstall_zapret2 спрашивает подтверждение через
#      confirm(), а тот читает /dev/tty. У фоновой задачи под CGI терминала
#      нет, чтение падает, и удаление МОЛЧА отменяется — с виду «кнопка не
#      работает». Нужен явный путь без вопроса, и он должен включаться только
#      переменной, которую ставит вызывающий.
#
#   3. Панель удаляет сама себя. lighttpd гасится вместе с деревом, поэтому
#      лог задачи обязан лежать в /tmp (иначе он исчезнет ровно тогда, когда
#      он единственный источник правды), а фронт не должен обещать возвращение
#      панели.
#
# Настоящее удаление здесь, разумеется, не запускается: Z2K_SH подменяется
# заглушкой, и проверяется, что и с чем было вызвано.
#
# POSIX sh (+ node для фронтовой части; без node — SKIP, в CI node есть).

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
API="$ROOT/webpanel/cgi/api.sh"
ACTIONS="$ROOT/webpanel/cgi/actions.sh"
INSTALL="$ROOT/lib/install.sh"
# Источник — ВЕСЬ JavaScript панели, а не один файл: с 2026-08-14 фронтенд
# разбит на модули, и греп по точке входа не нашёл бы ничего (см.
# tests/lib/panel_js.sh).
APPJS=$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")

for f in "$API" "$ACTIONS" "$INSTALL" "$APPJS"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- 1. Слово подтверждения проверяется НА СЕРВЕРЕ ----------------------------
#
# Проверяем не наличие строки, а то, что отказ стоит ДО запуска задачи: если
# uninstall_async вызывается раньше проверки, роутер уже мёртв, а 400 в ответе
# ничего не спасает.
_guard=$(awk '/"POST \/uninstall"\)/,/;;/' "$API")
case "$_guard" in
    *'form_value "$body" "confirm"'*) ok "сервер читает слово подтверждения из тела запроса" ;;
    *) no "сервер читает слово подтверждения" "form_value confirm" "не найдено" ;;
esac

_reject_line=$(printf '%s\n' "$_guard" | grep -n 'json_fail' | head -1 | cut -d: -f1)
_launch_line=$(printf '%s\n' "$_guard" | grep -n 'uninstall_async' | head -1 | cut -d: -f1)
if [ -n "$_reject_line" ] && [ -n "$_launch_line" ] && [ "$_reject_line" -lt "$_launch_line" ]; then
    ok "отказ стоит РАНЬШЕ запуска удаления, а не после"
else
    no "отказ раньше запуска" "json_fail до uninstall_async" \
       "reject=$_reject_line launch=$_launch_line"
fi

# --- 2. Заглушка вместо настоящего z2k.sh: что и как запускается ---------------
cat > "$TMP/fake-z2k.sh" <<'STUB'
#!/bin/sh
echo "argv: $*"
echo "confirmed: ${Z2K_UNINSTALL_CONFIRMED:-unset}"
echo "stdin-tty: $([ -t 0 ] && echo yes || echo no)"
exit 0
STUB
chmod +x "$TMP/fake-z2k.sh"

# actions.sh тянет за собой окружение панели; берём из него только нужную
# функцию, ровно как это делает сам CGI, но с подменённым путём к скрипту.
_out=$(
    ZAPRET2_DIR="$TMP" Z2K_SH="$TMP/fake-z2k.sh" sh -c '
        . "$1" 2>/dev/null || true
        command -v uninstall_async >/dev/null 2>&1 || { echo "__NOFUNC__"; exit 0; }
        id=$(uninstall_async) || { echo "__LAUNCHFAIL__"; exit 0; }
        # Задача фоновая: дожидаемся файла .exit, но не дольше 10 секунд.
        i=0
        while [ ! -f "/tmp/z2k-job-$id.exit" ] && [ "$i" -lt 100 ]; do
            i=$((i+1)); sleep 0.1 2>/dev/null || sleep 1
        done
        echo "__ID__$id"
        cat "/tmp/z2k-job-$id.log" 2>/dev/null
        rm -f "/tmp/z2k-job-$id".* 2>/dev/null
    ' _ "$ACTIONS" 2>&1
)

case "$_out" in
    *__NOFUNC__*)
        no "uninstall_async существует в actions.sh" "функция" "не определена" ;;
    *__LAUNCHFAIL__*)
        no "uninstall_async запускает задачу" "job id" "вернула ошибку" ;;
    *)
        ok "uninstall_async запускает фоновую задачу и пишет её лог"

        case "$_out" in
            *"argv: uninstall"*) ok "скрипт вызван именно с командой uninstall" ;;
            *) no "команда вызова" "uninstall" "$(printf '%s' "$_out" | grep '^argv:')" ;;
        esac

        # Без этого удаление из панели молча отменяется на вопросе в /dev/tty.
        case "$_out" in
            *"confirmed: 1"*) ok "задача несёт Z2K_UNINSTALL_CONFIRMED=1" ;;
            *) no "Z2K_UNINSTALL_CONFIRMED передан" "1" \
                  "$(printf '%s' "$_out" | grep '^confirmed:')" ;;
        esac

        # Открытый stdin от CGI держал бы HTTP-ответ незакрытым, и браузер не
        # получил бы job id до самого конца удаления.
        case "$_out" in
            *"stdin-tty: no"*) ok "задача отвязана от stdin CGI" ;;
            *) no "stdin отвязан" "no" "$(printf '%s' "$_out" | grep '^stdin-tty:')" ;;
        esac

        # Лог в /tmp, а не в дереве: дерево удаляется вместе с логом.
        case "$_out" in
            *__ID__*) ok "лог задачи лежит в /tmp и переживает удаление дерева" ;;
        esac
        ;;
esac

# --- 3. Неинтерактивный путь в самом удалении ---------------------------------
_u=$(awk '/^uninstall_zapret2\(\)/,/^}/' "$INSTALL")
case "$_u" in
    *'Z2K_UNINSTALL_CONFIRMED'*) ok "uninstall_zapret2 знает про подтверждение извне" ;;
    *) no "uninstall_zapret2 умеет работать без tty" "ветка Z2K_UNINSTALL_CONFIRMED" "нет" ;;
esac
# Защита не должна сниматься пустым значением или чем угодно непустым.
case "$_u" in
    *'"${Z2K_UNINSTALL_CONFIRMED:-}" = "1"'*)
        ok "снимается строго значением 1, а не любым непустым" ;;
    *)
        no "строгое сравнение с 1" '= "1"' "сравнение слабее" ;;
esac
# Интерактивный путь обязан остаться: в терминале вопрос задаётся по-прежнему.
case "$_u" in
    *'confirm "Вы уверены?'*) ok "в терминале вопрос по-прежнему задаётся" ;;
    *) no "терминальный confirm сохранён" "confirm(...)" "исчез" ;;
esac

# --- 4. Фронт: подтверждение набором и никаких обещаний вернуться --------------
if ! command -v node >/dev/null 2>&1; then
    SKIP=$((SKIP+1))
    printf '[SKIP] фронтовая часть (нет node; в CI проверяется)\n'
else
    # 4a. Кнопка удаления не отправляет запрос без подтверждения.
    _handler=$(awk '/uninstall-btn"\)\.forEach/,/^    \}\)\);/' "$APPJS")
    case "$_handler" in
        *confirmTypedModal*) ok "кнопка открывает диалог с набором слова" ;;
        *) no "диалог подтверждения" "confirmTypedModal" "не вызывается" ;;
    esac
    case "$_handler" in
        *'if (!ok) return;'*) ok "отказ в диалоге прекращает всё" ;;
        *) no "отказ прекращает действие" "ранний return" "не найден" ;;
    esac
    # Порядок: диалог ДО запроса. Иначе подтверждение — украшение.
    _ask=$(printf '%s\n' "$_handler" | grep -n 'confirmTypedModal' | head -1 | cut -d: -f1)
    _post=$(printf '%s\n' "$_handler" | grep -n 'apiPost("/uninstall"' | head -1 | cut -d: -f1)
    if [ -n "$_ask" ] && [ -n "$_post" ] && [ "$_ask" -lt "$_post" ]; then
        ok "запрос уходит только после подтверждения"
    else
        no "подтверждение раньше запроса" "confirmTypedModal до apiPost" "ask=$_ask post=$_post"
    fi

    # 4b. Кнопка в диалоге неактивна, пока слово не набрано — исполняем код.
    _res=$(node -e '
      const fs = require("fs");
      const src = fs.readFileSync(process.argv[1], "utf8");
      const m = src.match(/function confirmTypedModal\([\s\S]*?\n  \}\n/);
      if (!m) { console.log("MISSING"); process.exit(0); }
      // Минимальный DOM: нужен ровно тот путь, что включает кнопку.
      const nodes = {};
      const mk = () => ({
        value: "", disabled: false, className: "", innerHTML: "",
        _h: {},
        addEventListener(ev, fn) { this._h[ev] = fn; },
        removeEventListener() {}, remove() {}, focus() {}, contains() { return true; },
        setAttribute() {}, appendChild() {},
        querySelector(sel) { return nodes[sel] || (nodes[sel] = mk()); },
      });
      const backdrop = mk();
      global.document = {
        activeElement: null,
        createElement: () => backdrop,
        body: { appendChild() {} },
        addEventListener() {}, removeEventListener() {},
      };
      global.escapeHtml = (s) => String(s);
      const fn = new Function("return " + m[0].trim().replace(/^function /, "function "))();
      fn("t", ["a"], "УДАЛИТЬ", "ok");
      const input = backdrop.querySelector("#typed-input");
      const okBtn = backdrop.querySelector("#typed-ok");
      const type = (v) => { input.value = v; input._h.input(); };
      const out = [];
      out.push(["initial", okBtn.disabled]);
      type("удал");            out.push(["partial", okBtn.disabled]);
      type("удалить");         out.push(["lowercase", okBtn.disabled]);
      type("  УДАЛИТЬ  ");     out.push(["spaces", okBtn.disabled]);
      type("УДАЛИТЬ ВСЁ");     out.push(["extra", okBtn.disabled]);
      console.log(JSON.stringify(out));
    ' "$APPJS" 2>&1)

    case "$_res" in
        MISSING*)
            no "confirmTypedModal найдена в app.js" "функция" "не найдена" ;;
        \[*)
            _get() { printf '%s' "$_res" | node -e '
              let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
                const r=JSON.parse(s), k=process.argv[1];
                const row=r.find(x=>x[0]===k);
                console.log(row ? String(row[1]) : "missing");
              });' "$1"; }
            [ "$(_get initial)" = "true" ] \
                && ok "при открытии кнопка удаления неактивна" \
                || no "кнопка неактивна при открытии" "true" "$(_get initial)"
            [ "$(_get partial)" = "true" ] \
                && ok "неполное слово кнопку не включает" \
                || no "неполное слово не включает" "true" "$(_get partial)"
            [ "$(_get extra)" = "true" ] \
                && ok "лишний текст после слова кнопку не включает" \
                || no "лишний текст не включает" "true" "$(_get extra)"
            # Регистр и пробелы прощаем осознанно: требование — прочитать и
            # набрать, а не воевать с Caps Lock и раскладкой.
            [ "$(_get lowercase)" = "false" ] \
                && ok "слово принимается независимо от регистра" \
                || no "регистр не важен" "false" "$(_get lowercase)"
            [ "$(_get spaces)" = "false" ] \
                && ok "краевые пробелы не мешают" \
                || no "пробелы по краям" "false" "$(_get spaces)" ;;
        *)
            no "диалог исполняется в node" "результат" "$_res" ;;
    esac

    # 4c. Опрос задачи не обещает возвращения панели.
    if grep -q 'expectGone' "$APPJS"; then
        ok "у опроса есть режим «панель не вернётся»"
    else
        no "режим expectGone" "есть" "нет — опрос будет ждать мёртвый сервер"
    fi
    _wait=$(grep -n 'панель выключается вместе с z2k' "$APPJS" | head -1)
    if [ -n "$_wait" ]; then
        ok "во время удаления в логе пишется, что панель выключается, а не «ждём»"
    else
        no "текст ожидания при удалении" "«панель выключается вместе с z2k»" "нет"
    fi
    # 4d. И — главное — молчание сервера НЕ выдаётся за успешное удаление.
    #
    # Соблазн здесь прямой: панель пропала, значит удалили. Но панель гасится
    # ВТОРЫМ действием, задолго до чистки правил, сноса дерева и конфига, так
    # что всё, что упадёт после, случится уже за спиной у страницы. Сначала
    # тут стояло exit: 0 и «z2k удалён» — догадка, поданная как факт: человек
    # читал «удалён», закрывал вкладку, а дерево оставалось на месте, и
    # проверить было нечем (журнал задачи лежит в /tmp, доступен по SSH).
    # Комментарии выкидываем: внутри блока прежний «exit: 0» процитирован в
    # объяснении, почему его там больше нет, и голый grep зеленел бы на прозе.
    _gone=$(awk '/opts.expectGone && state.consecutiveErrors/,/^        \}/' "$APPJS" \
            | grep -vE '^[[:space:]]*//')
    case "$_gone" in
        *"exit: 0"*)
            no "успех не заявляется по молчанию сервера" "exit не 0" "стоит exit: 0" ;;
        *'status: "unknown"'*)
            ok "исход помечен неизвестным, а не успешным" ;;
        *)
            no "исход помечен неизвестным" 'status: "unknown"' "не найдено" ;;
    esac
    # Человеку сказано и что это норма, и куда смотреть, если нет.
    case "$_gone" in
        *"так и должно быть"*) ok "выключение панели объяснено как ожидаемое" ;;
        *) no "объяснение выключения панели" "«так и должно быть»" "нет" ;;
    esac
    case "$_gone" in
        *"откройте меню в терминале"*) ok "указано, где проверить результат" ;;
        *) no "куда смотреть за результатом" "отсылка к меню в терминале" "нет" ;;
    esac
fi

# --- 5. Удаление обязано работать без интернета ---------------------------------
#
# Просят снести z2k чаще всего именно тогда, когда сеть не работает. Пока
# команда uninstall стояла в одной ветке бутстрапа с install/update, z2k.sh
# перед удалением скачивал с GitHub всё дерево заново и умирал на первом же
# неудачном фетче — до самого удаления дело не доходило, и снаружи это
# выглядело как «кнопка не работает».
_boot=$(awk '/^    local _need_fetch=1$/,/^    esac$/' "$ROOT/z2k.sh")
case "$_boot" in
    *"install|i|update|u|uninstall|remove)"*)
        no "uninstall не тянет файлы из сети" "своя ветка бутстрапа" \
           "uninstall всё ещё в одной ветке с install/update" ;;
    *"uninstall|remove)"*)
        ok "у uninstall своя ветка бутстрапа, отдельно от install/update" ;;
    *)
        no "ветка uninstall в бутстрапе" "есть" "не найдена" ;;
esac
case "$_boot" in
    *"_need_fetch=0"*) ok "для uninstall загрузка из сети выключается" ;;
    *) no "загрузка выключается" "_need_fetch=0 в ветке uninstall" "нет" ;;
esac
# Но только если модули действительно на диске: на разрушенном дереве
# единственный шанс что-то доделать — всё-таки скачать.
case "$_boot" in
    *'/opt/zapret2/lib/${_um}.sh'*) ok "офлайн-путь включается только при наличии модулей на диске" ;;
    *) no "проверка модулей на диске" "проверка /opt/zapret2/lib" "нет" ;;
esac

# --- 6. Уборка tpws не роняет удаление под set -e -------------------------------
#
# Последней командой z2k_remove_tpws стоял условный список: при отсутствующем
# конфиге он возвращает 1, и всё удаление обрывалось ровно посередине — сервис
# убит, правила сняты, панель снесена, а дерево и конфиг остались.
_tpws=$(awk '/^z2k_remove_tpws\(\)/,/^}/' "$INSTALL")
_last=$(printf '%s\n' "$_tpws" | grep -vE '^\s*(#|$)' | tail -2 | head -1)
case "$_last" in
    *"return 0"*) ok "z2k_remove_tpws всегда возвращает успех" ;;
    *) no "z2k_remove_tpws не роняет set -e" "return 0 последней командой" "последняя: $_last" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
