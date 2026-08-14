#!/bin/sh
# tests/test_panel_transient_errors.sh — переустановка не должна выглядеть как ошибка.
#
# ИСТОРИЯ, РАДИ КОТОРОЙ ЭТОТ ТЕСТ СУЩЕСТВУЕТ. Одна и та же беда чинилась дважды
# и оба раза не до конца:
#
#   077a490 (07-08)  ввёл классификацию ошибок, и отказом стал считаться ЛЮБОЙ
#                    числовой HTTP-статус. При переустановке дерево /opt/zapret2
#                    переезжает, lighttpd жив и честно отвечает 404 — и панель
#                    объявляла «панель ответила ошибкой: 404 Not Found — чем
#                    кончилась задача, неизвестно» через четыре секунды после
#                    начала обновления, хотя обновление шло и доходило до конца.
#
#   90823e8 (08-08)  вывел 404/502/503/504 из отказов — но только в опросе задачи
#                    и в awaitPanelBack. Сырой текст ошибки печатает больше сорока
#                    мест в app.js, и все они продолжали показывать людям «404».
#
#   ...и это оказалось верно только наполовину. Источник чинить было правильно,
#   но обещание «текста нет» выполняется ровно настолько, насколько с ним
#   считается каждое место ПОКАЗА. Ревью 08-14 пересчитало: 11 мест печатали
#   пустой текст прямо в разметку (красная плашка «Ошибка» и пустота под ней),
#   а 26 склеивали «Ошибка: » + e.message ДО вызова toast — и его защита от
#   пустого текста не срабатывала, потому что строка «Ошибка: » непустая.
#
# Поэтому теперь проверяются ОБА конца. Источник: httpError рождает пустой
# текст для временных статусов. Потребители: показ идёт через общую пару
# errMsg/errHtml/toastErr, а не через e.message россыпью — иначе следующее
# добавленное место снова разойдётся с обещанием.
#
# POSIX sh + node (без node — честный SKIP, в CI node есть).

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
APPJS="$HERE/../webpanel/www/app.js"

[ -f "$APPJS" ] || { printf '[FAIL] нет %s\n' "$APPJS"; exit 1; }

if ! command -v node >/dev/null 2>&1; then
    SKIP=$((SKIP+1))
    printf '[SKIP] классификатор ошибок панели (нет node; в CI проверяется)\n'
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
fi

# --- 1. Статический контракт: один список, а не два ---------------------------
#
# Раньше набор временных статусов был вписан прямо в switch внутри isRefusal.
# Стоило добавить статус в одном месте и забыть в другом — и опрос ждал бы, пока
# страница кричит про ошибку. Требуем единый источник.
if grep -q 'TRANSIENT_HTTP' "$APPJS"; then
    ok "временные статусы вынесены в общий список TRANSIENT_HTTP"
else
    no "временные статусы вынесены в общий список TRANSIENT_HTTP" "есть TRANSIENT_HTTP" "нет"
fi

if grep -qE 'case 404: case 502' "$APPJS"; then
    no "нет второго, независимого списка статусов" "список один" "остался switch в isRefusal"
else
    ok "нет второго, независимого списка статусов"
fi

# --- 2. Поведение: вытаскиваем реальные функции из app.js и гоняем -------------
OUT=$(node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");

// Берём НАСТОЯЩИЕ определения из app.js, а не копии: копия разошлась бы с
// оригиналом ровно так же, как разошлись две ветки классификации.
const grab = (re, what) => {
  const m = src.match(re);
  if (!m) { console.log("MISSING:" + what); process.exit(0); }
  return m[0];
};
const constDecl = grab(/const TRANSIENT_HTTP = \{[^}]*\};/, "TRANSIENT_HTTP");
const httpErrFn = grab(/function httpError\(status, statusText, message\) \{[\s\S]*?\n  \}/, "httpError");
const isHttpFn  = grab(/function isHttpError\(e\) \{[^\n]*\}/, "isHttpError");
const isRefFn   = grab(/function isRefusal\(e\) \{[\s\S]*?\n  \}/, "isRefusal");

const sandbox = new Function(constDecl + "\n" + httpErrFn + "\n" + isHttpFn + "\n" + isRefFn +
  "\nreturn { httpError, isRefusal };")();
const { httpError, isRefusal } = sandbox;

const res = [];
// Временные: человеческий текст, отказом не считаются.
for (const s of [404, 502, 503, 504]) {
  const e = httpError(s, "Whatever");
  res.push([s, e.message, isRefusal(e), e.transient === true]);
}
// Настоящие отказы: текст сохраняется, считаются отказом.
for (const s of [403, 500, 401]) {
  const e = httpError(s, "Forbidden");
  res.push([s, e.message, isRefusal(e), e.transient === true]);
}
// Явное сообщение от бекенда не должно подменяться.
const withBody = httpError(403, "Forbidden", "запрос отклонён: панель не отвечает на этот адрес");
res.push(["body", withBody.message, isRefusal(withBody), withBody.transient === true]);
console.log(JSON.stringify(res));
' "$APPJS" 2>&1)

case "$OUT" in
    MISSING:*)
        no "функции классификатора найдены в app.js" "все четыре" "${OUT#MISSING:} не найдена"
        printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
        exit 1 ;;
esac

check() {
    _label="$1"; _expr="$2"
    if printf '%s' "$OUT" | node -e '
      let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
        const r = JSON.parse(s);
        const f = new Function("r", "return (" + process.argv[1] + ");");
        process.exit(f(r) ? 0 : 1);
      });' "$_expr" 2>/dev/null; then
        ok "$_label"
    else
        no "$_label" "истина" "ложь ($OUT)"
    fi
}

# Текста у временного статуса нет ВОВСЕ. Раньше здесь требовался «человеческий»
# текст — и это была половинчатая правка: сообщение всё равно всплывало, просто
# другими словами, и пугало ровно так же. Наш код 404 не возвращает; тот, что
# видели люди, — ответ lighttpd на переехавшее дерево. Показывать его нечем и
# незачем.
check 'у временного статуса нет текста вообще' \
      'r.slice(0,4).every(x => x[1] === "")'
check 'ни один временный статус не показывает код протокола' \
      'r.slice(0,4).every(x => !/^\d\d\d /.test(x[1]))'
check '404/502/503/504 отказом НЕ считаются' \
      'r.slice(0,4).every(x => x[2] === false)'
check 'временные помечены флагом transient' \
      'r.slice(0,4).every(x => x[3] === true)'
check '403 и 500 остаются отказом' \
      'r.slice(4,7).every(x => x[2] === true)'
check 'у настоящих отказов текст на месте' \
      'r.slice(4,7).every(x => x[1].length > 0)'
check 'объяснение от бекенда доходит до человека дословно' \
      'r[7][1] === "запрос отклонён: панель не отвечает на этот адрес"'

# --- 3. Пустой текст гасится, а не показывается пустой плашкой ----------------
#
# Троттлинг тостов «панель перезапускается» здесь больше не проверяется: такого
# текста не существует. Вместо него — гарантия, что пустое сообщение молчит.
if awk '/^  function toast\(/,/^  }/' "$APPJS" | grep -q 'String(msg).trim()'; then
    ok "пустой текст не превращается в тост"
else
    no "пустой текст не превращается в тост" "ранний return в toast()" "не найдено"
fi

# --- 4. Панель не выносит ВЕРДИКТОВ о задаче ----------------------------------
#
# Правило здесь уточнено после r-75.4, и уточнение важно понять, иначе оно
# откатится обратно. Изначально запрещался весь класс «сообщений про
# недоступную панель». Запрет был прав ровно наполовину: панель действительно
# не должна объявлять задачу проваленной и печатать коды протокола — задача
# идёт на роутере и от браузера не зависит.
#
# Но «не выносить вердикт» подменили на «молчать вообще», а это разные вещи.
# Лог во время переезда замирает на последней строке, и «идёт долгий шаг»
# становится неотличимо от «повисло»: человек смотрел на застывший
# «Шаг 4/12» и решил, что установка встала. Молчание оказалось ещё одним
# способом дезинформировать.
#
# Поэтому запрещены именно ВЕРДИКТЫ (ниже), а признак жизни показывать не
# только можно, но и обязательно — счётчиком ожидания В САМОМ ЛОГЕ, ровно как
# было до p-73.2. Отдельная плашка под логом эту роль не сыграла: смотрят в лог,
# и жалоба после r-75.6 была именно «ни логов, ни того, что панель вернётся».
# Поведение закреплено в tests/test_panel_job_poller.sh.
_ghosts=0
# «панель снова на связи» из списка УБРАНА 2026-08-11: она попала сюда заодно
# с вердиктами, а вердиктом не является — это отметка, что опрос восстановился.
for _s in 'панель ответила ошибкой' 'Связь с панелью пропала' \
          'чем кончилась задача, неизвестно'; do
    if grep -n "$_s" "$APPJS" | grep -vE '^\s*[0-9]+:\s*//' | grep -q .; then
        printf '[FAIL] текст вернулся в код: %s\n' "$_s"; _ghosts=$((_ghosts+1))
    fi
done
if [ "$_ghosts" = "0" ]; then
    ok "вердиктов о судьбе задачи в коде нет (кроме комментариев)"
else
    FAIL=$((FAIL + _ghosts))
fi

# Счётчик ожидания в логе существует и молчит про протокол: коды человеку
# по-прежнему не показываются.
_wait=$(grep -n "панель пока не отвечает" "$APPJS" | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*//' || true)
if [ -n "$_wait" ]; then
    case "$_wait" in
        *404*|*50[0-9]*|*HTTP*) no "счётчик ожидания без кодов протокола" "без кодов" "$_wait" ;;
        *) ok "в логе идёт счётчик ожидания, и он без кодов протокола" ;;
    esac
else
    no "в логе есть счётчик ожидания" "строка «панель пока не отвечает»" \
       "нет — замерший лог снова неотличим от зависшей установки"
fi

# --- Потребители: пустой текст не должен доходить до человека ------------------
#
# Комментарии отсеиваем: тест уже трижды в этом проекте зеленел на прозе,
# описывающей снятый дефект.
_code() { grep -vE '^[[:space:]]*(//|\*|/\*)' "$APPJS"; }

_raw_html=$(_code | grep -cE 'escapeHtml\(e\.message\)' || true)
if [ "${_raw_html:-0}" = "0" ]; then
    ok "в разметку не печатается сырой e.message (иначе — «Ошибка» и пустота)"
else
    no "сырой e.message в разметке" "0 мест" "$_raw_html — при временном статусе там пустота"
fi

_raw_toast=$(_code | grep -cE 'toast\([^)]*\+ e\.message' || true)
if [ "${_raw_toast:-0}" = "0" ]; then
    ok "тосты не склеивают текст до toast (иначе защита от пустоты не сработает)"
else
    no "склейка до toast" "0 мест" "$_raw_toast — человек увидит «Ошибка:» без продолжения"
fi

# Сама пара должна существовать и вести себя как обещано — ИСПОЛНЯЕМ её.
if command -v node >/dev/null 2>&1; then
    _beh=$(node -e '
      const fs = require("fs");
      const src = fs.readFileSync(process.argv[1], "utf8");
      const grab = (re, what) => { const m = src.match(re); if (!m) { console.log("MISSING:" + what); process.exit(0); } return m[0]; };
      const code = grab(/const TRANSIENT_WHY = [\s\S]*?;/, "TRANSIENT_WHY") + "\n" +
                   grab(/function errMsg\([\s\S]*?\n  \}/, "errMsg") + "\n" +
                   grab(/function escapeHtml\([\s\S]*?\n  \}/, "escapeHtml") + "\n" +
                   grab(/function errHtml\([\s\S]*?\n  \}/, "errHtml");
      const api = new Function(code + "; return { errMsg, errHtml, TRANSIENT_WHY };")();
      const empty = api.errMsg({ message: "" });
      const real  = api.errMsg({ message: "403 Forbidden" });
      console.log(JSON.stringify({
        emptyBecameHuman: empty === api.TRANSIENT_WHY,
        realKept: real === "403 Forbidden",
        htmlNotBlank: api.errHtml({ message: "" }).trim().length > 0,
      }));
    ' "$APPJS" 2>&1)
    case "$_beh" in
        MISSING:*) no "пара errMsg/errHtml существует" "обе" "${_beh#MISSING:} отсутствует" ;;
        *'"emptyBecameHuman":true'*'"realKept":true'*'"htmlNotBlank":true'*)
            ok "пустой текст превращается в человеческий, настоящий отказ сохраняется" ;;
        *) no "поведение пары" "пустой→человеческий, настоящий→как есть" "$_beh" ;;
    esac
else
    SKIP=$((SKIP+1)); printf '[SKIP] поведение errMsg/errHtml (нет node)\n'
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
