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
# Поэтому проверяем не одну ветку, а сам источник: текст ошибки рождается в
# httpError, и для временных статусов он обязан быть человеческим. Тогда все
# места, которые его показывают, чинятся разом и не могут разойтись снова.
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

check 'у 404 текст человеческий, а не «404 Not Found»' \
      'r[0][1].indexOf("перезапускается") !== -1'
check 'ни один временный статус не показывает код протокола' \
      'r.slice(0,4).every(x => !/^\d\d\d /.test(x[1]))'
check '404/502/503/504 отказом НЕ считаются' \
      'r.slice(0,4).every(x => x[2] === false)'
check 'временные помечены флагом transient' \
      'r.slice(0,4).every(x => x[3] === true)'
check '403 и 500 остаются отказом' \
      'r.slice(4,7).every(x => x[2] === true)'
check 'у настоящих отказов текст НЕ подменяется на «перезапускается»' \
      'r.slice(4,7).every(x => x[1].indexOf("перезапускается") === -1)'
check 'объяснение от бекенда доходит до человека дословно' \
      'r[7][1] === "запрос отклонён: панель не отвечает на этот адрес"'

# --- 3. Тосты про перезапуск не заливают экран --------------------------------
if grep -q '_lastRestartToastAt' "$APPJS"; then
    ok "повторные тосты про перезапуск придерживаются"
else
    no "повторные тосты про перезапуск придерживаются" "есть троттлинг" "нет"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
