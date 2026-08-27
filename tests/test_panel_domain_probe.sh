#!/bin/sh
# tests/test_panel_domain_probe.sh — проверка домена в панели (аналог [Y] в меню).
#
# ЗАЧЕМ ОНА ВООБЩЕ ПОЯВИЛАСЬ. В терминале пункт [Y] проверяет один домен и
# говорит, на какой стадии всё обрывается и блокирует ли его DPI. В панели
# такого не было — и это уже вредило: когда спрашивали «а мы вообще умеем
# проверять доступность», ответ был «нет, /probe/run отдаёт 410», и вместо
# измерений в интерфейс лезли догадки.
#
# ЧТО ОХРАНЯЕТСЯ:
#
#   1. Домен проверяется НА СЕРВЕРЕ, а не только на странице. Панель работает
#      без пароля и доверяет всей локальной сети, а значение уходит в командную
#      строку — набор символов должен совпадать с тем, что у пункта [Y].
#   2. Проба остаётся СТАТЕЛЕСС: запускается ровно `z2k-detect probe`, без
#      --apply и прочего, что могло бы писать в списки или состояние демона.
#   3. У запуска есть свой сторож: `timeout` на Entware отсутствует, а зависший
#      CGI держит воркер lighttpd.
#   4. Разбор отчёта не врёт: стадии, адреса, причина и вердикт достаются из
#      настоящего текста настоящей функцией из app.js.
#
# POSIX sh + node (без node — SKIP фронтовой части; в CI node есть).

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
API="$ROOT/webpanel/cgi/api.sh"
ACT="$ROOT/webpanel/cgi/actions.sh"
# Источник — ВЕСЬ JavaScript панели, а не один файл: с 2026-08-14 фронтенд
# разбит на модули, и греп по точке входа не нашёл бы ничего (см.
# tests/lib/panel_js.sh).
APPJS=$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")
CSS="$ROOT/webpanel/www/style.css"
MENU="$ROOT/lib/menu.sh"

for f in "$API" "$ACT" "$APPJS" "$CSS" "$MENU"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- 1. Маршрут есть и не путается со снятым /probe/run -----------------------
_route=$(awk '/"POST \/diag\/probe"\)/,/;;/' "$API")
[ -n "$_route" ] && ok "маршрут POST /diag/probe объявлен" \
                 || no "маршрут" "POST /diag/probe" "нет"
# Старый автоматический зонд ротатора убран в r-15 и воскрешать его нельзя.
if grep -q '"POST /probe/run"' "$API" && \
   awk '/"POST \/probe\/run"\)/,/;;/' "$API" | grep -q '410 Gone'; then
    ok "снятый автозонд /probe/run по-прежнему отвечает 410, а не воскрес"
else
    no "старый /probe/run" "410 Gone" "изменился"
fi

# --- 2. Проверка домена ИСПОЛНЯЕТСЯ, а не описывается -------------------------
#
# Берём настоящую функцию из actions.sh с подставным z2k-detect и гоняем на
# входах, которые реально приходят из формы.
cat > "$TMP/fake-detect" <<'STUB'
#!/bin/sh
echo "argv: $*"
echo "Domain:  $2"
echo "Probe:   DNS=ok TCP=ok TLS=fail HTTP=skip  (234ms)"
echo "IPs:     57.144.248.34"
echo "Code:    tls_reset"
echo "Reason:  tls_reset: read tcp 1.2.3.4:5->6.7.8.9:443: read: connection reset by peer"
echo "Verdict: HOT — DPI блокирует, но домен уже в списке: RKN list (shipped)."
echo "  → ничего делать не надо, autocircular подбирает страту автоматически."
STUB
chmod +x "$TMP/fake-detect"

probe() {   # domain -> печатает "rc=<код>" и вывод
    Z2K_DETECT_BIN="$TMP/fake-detect" Z2K_ACT="$ACT" Z2K_DOM="$1" sh -c '
        . "$Z2K_ACT" 2>/dev/null || true
        out=$(detect_probe_domain "$Z2K_DOM" 2>&1); rc=$?
        echo "rc=$rc"; printf "%s\n" "$out"
    ' 2>&1
}

_r=$(probe "instagram.com")
case "$_r" in
    *"rc=0"*) ok "нормальный домен проверяется" ;;
    *) no "нормальный домен" "rc=0" "$(printf '%s' "$_r" | head -1)" ;;
esac
case "$_r" in
    *"argv: probe instagram.com"*) ok 'запускается именно probe, без лишних аргументов' ;;
    *) no "команда запуска" "probe <домен>" "$(printf '%s' "$_r" | grep '^argv:')" ;;
esac
# --apply писал бы в списки и гонялся бы с демоном за один и тот же TSV.
case "$_r" in
    *--apply*) no "проба остаётся стателесс" "без --apply" "передан --apply" ;;
    *) ok "проба остаётся стателесс — ничего не пишет" ;;
esac

# Инъекция: значение уходит в командную строку, панель без пароля.
for bad in 'bad;rm -rf /' 'a b' '$(id)' '../../etc/passwd' ''; do
    _r=$(probe "$bad")
    case "$_r" in
        *"rc=2"*) ok "отвергнут вход: ${bad:-<пусто>}" ;;
        *) no "отвергнут вход ${bad:-<пусто>}" "rc=2" "$(printf '%s' "$_r" | head -1)" ;;
    esac
done

# Набор символов обязан совпадать с пунктом [Y] — иначе панель и меню начнут
# принимать разное, и «в меню работает, в панели нет» станет отдельной загадкой.
_menu_charset=$(awk '/^menu_diagnose_domain\(\)/,/^}/' "$MENU" | grep -c 'a-zA-Z0-9.-')
_cgi_charset=$(awk '/^detect_probe_domain\(\)/,/^}/' "$ACT" | grep -c 'a-zA-Z0-9.-')
if [ "$_menu_charset" -gt 0 ] && [ "$_cgi_charset" -gt 0 ]; then
    ok "панель принимает тот же набор символов, что и пункт [Y]"
else
    no "набор символов совпадает с меню" "оба проверяют a-zA-Z0-9.-" \
       "меню=$_menu_charset панель=$_cgi_charset"
fi

# Отсутствующий модуль — отдельный код, чтобы человеку сказать «переустановите».
_r=$(Z2K_DETECT_BIN="$TMP/nope" Z2K_ACT="$ACT" sh -c '. "$Z2K_ACT" 2>/dev/null||true; detect_probe_domain ok.test >/dev/null 2>&1; echo "rc=$?"')
case "$_r" in
    *"rc=3"*) ok "отсутствие z2k-detect отличается от прочих отказов" ;;
    *) no "модуль не установлен" "rc=3" "$_r" ;;
esac

# --- 3. Сторож времени --------------------------------------------------------
#
# На Entware нет `timeout`, а зависший CGI держит соединение и воркер lighttpd.
_fn=$(awk '/^detect_probe_domain\(\)/,/^}/' "$ACT")
case "$_fn" in
    *"kill -9"*) ok "у запуска есть сторож, добивающий зависшую пробу" ;;
    *) no "сторож времени" "kill -9 по таймауту" "нет" ;;
esac

# --- 4. Разбор отчёта: исполняем настоящие функции из app.js ------------------
if ! command -v node >/dev/null 2>&1; then
    SKIP=$((SKIP+1))
    printf '[SKIP] разбор отчёта (нет node; в CI проверяется)\n'
else
    OUT=$(node -e '
      const fs=require("fs");
      const src=fs.readFileSync(process.argv[1],"utf8");
      const grab=(re,what)=>{const m=src.match(re); if(!m){console.log("MISSING:"+what);process.exit(0);} return m[0];};
      const code = grab(/function parseProbeReport\([\s\S]*?\n  \}/,"parseProbeReport")+"\n"+
                   grab(/function verdictText\([\s\S]*?\n  \}/,"verdictText");
      const api = new Function(code+"; return {parseProbeReport, verdictText};")();
      const rep = [
        "Domain:  instagram.com",
        "Probe:   DNS=ok TCP=ok TLS=fail HTTP=skip  (234ms)",
        "IPs:     57.144.248.34",
        "Code:    tls_reset",
        "Reason:  tls_reset: connection reset by peer",
        "Verdict: HOT — DPI блокирует, но домен уже в списке: RKN list (shipped).",
        "  → ничего делать не надо, autocircular подбирает страту автоматически."
      ].join("\n");
      const r = api.parseProbeReport(rep);
      console.log(JSON.stringify({
        stages: r.stages.map(s=>s.name+"="+s.state).join(" "),
        lat: r.latency, ips: r.ips, code: r.code,
        verdict: r.verdict, shown: api.verdictText(r.verdict),
        advice: r.advice
      }));
    ' "$APPJS" 2>&1)

    case "$OUT" in
        MISSING:*) no "функции разбора найдены" "все" "${OUT#MISSING:} отсутствует" ;;
        \{*)
            get() { printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(String(JSON.parse(s)[process.argv[1]])))' "$1"; }
            [ "$(get stages)" = "DNS=ok TCP=ok TLS=fail HTTP=skip" ] \
                && ok "все четыре стадии разобраны в правильном порядке" \
                || no "стадии" "DNS=ok TCP=ok TLS=fail HTTP=skip" "$(get stages)"
            [ "$(get lat)" = "234" ] && ok "время пробы вынуто отдельно" \
                || no "время пробы" "234" "$(get lat)"
            [ "$(get ips)" = "57.144.248.34" ] && ok "адреса вынуты" \
                || no "адреса" "57.144.248.34" "$(get ips)"
            # Внутренний ярлык не показывается человеку, но в полном отчёте
            # остаётся — его пересылают в чат.
            case "$(get shown)" in
                HOT*|IGNORE*) no "ярлык классификатора скрыт от человека" "без HOT/IGNORE" "$(get shown)" ;;
                "") no "текст вердикта не пустой" "текст" "пусто" ;;
                *) ok "внутренний ярлык HOT/IGNORE в показываемой строке убран" ;;
            esac
            case "$(get advice)" in
                *"autocircular"*) ok "совет из отчёта доходит до человека дословно" ;;
                *) no "совет из отчёта" "строка после →" "$(get advice)" ;;
            esac ;;
        *) no "разбор исполняется" "JSON" "$OUT" ;;
    esac
fi

# --- 5. Стили стадий существуют -----------------------------------------------
#
# Без них четыре состояния сливаются в серый ряд, и смысл «видно, где
# оборвалось» теряется.
_missing=""
for c in probe-stage probe-verdict probe-stages probe-row; do
    grep -q "^\.$c" "$CSS" || _missing="$_missing $c"
done
[ -z "$_missing" ] && ok "стили результата на месте" \
                   || no "стили результата" "все классы" "нет:$_missing"

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
