#!/bin/sh
# tests/test_panel_tcp16.sh — карточка «Обрыв на 16 КБ» на дашборде и её CGI.
#
# ЧТО ОХРАНЯЕТСЯ:
#   1. GET /tcp16 отдаёт картину из ФАЙЛОВ пробы (флаг, давность, сети, имена),
#      а «в конфиге» — из конфига: расхождение флага и конфига — самая частая
#      болезнь механизма, и панель обязана его показывать.
#   2. POST /tcp16/probe запускает ровно штатную пробу (z2k-tcp16-probe.sh без
#      аргументов) как задачу; без файла пробы — отказ, вторая проба поверх
#      идущей — отказ.
#   3. Строка состояния считается настоящей функцией из панели: вердикт с
#      давностью, «не попал в конфиг» красным только когда блок найден.
#
# POSIX sh + node (без node — SKIP фронтовой части; в CI node есть).
PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ACT="$ROOT/webpanel/cgi/actions.sh"
API="$ROOT/webpanel/cgi/api.sh"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- 1. CGI: картина из файлов пробы ----------------------------------------
# Берём сами функции из actions.sh, а не копию: копия расходится молча.
ZAPRET2_DIR="$TMP/z2k"; CONFIG_FILE="$ZAPRET2_DIR/config"
mkdir -p "$ZAPRET2_DIR/state" "$ZAPRET2_DIR/lists"
json_string() { printf '"%s"' "$(printf '%s' "$1" | sed 's/["\\]/\\&/g')"; }
# Замок пробы — в песочнице: по нему панель и отвечает «идёт».
Z2K_TCP16_LOCK="$TMP/probe.lock"
eval "$(sed -n '/^_tcp16_count()/,/^}/p; /^_tcp16_bypassed()/,/^}/p; /^_tcp16_running()/,/^}/p; /^tcp16_status_json()/,/^}/p; /^tcp16_probe_async()/,/^}/p' "$ACT")"
probe_lock_on()  { mkdir -p "$Z2K_TCP16_LOCK"; echo $$ > "$Z2K_TCP16_LOCK/pid"; }
probe_lock_off() { rm -rf "$Z2K_TCP16_LOCK"; }
probe_lock_off

printf '# a\n24940\n13335\n' > "$ZAPRET2_DIR/state/tcp16_asn.txt"
printf '24940\t300.ya.ru\n' > "$ZAPRET2_DIR/state/tcp16_sni.txt"
printf 'a.example\nb.example\nc.example\n' > "$ZAPRET2_DIR/lists/sni_wl_candidates.txt"
printf '1\n' > "$ZAPRET2_DIR/state/tcp16.flag"
printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$ZAPRET2_DIR/state/tcp16.flag.ts"
printf 'NFQWS2_OPT="--lua-desync=z2k_sni_fake:payload=tls_client_hello"\n' > "$CONFIG_FILE"
J=$(tcp16_status_json)
case "$J" in *'"measured":"1"'*) ok "блок найден — measured=1" ;; *) no "measured=1" '"measured":"1"' "$J" ;; esac
case "$J" in *'"nets_blocked":2'*) ok "сети с блоком считаются без комментариев" ;; *) no "nets_blocked" 2 "$J" ;; esac
case "$J" in *'"nets_bypassed":1'*) ok "сетей с обходом — 1 из 2" ;; *) no "nets_bypassed" 1 "$J" ;; esac
case "$J" in *'"candidates":3'*) ok "кандидатов — 3" ;; *) no "candidates" 3 "$J" ;; esac
case "$J" in *'"in_config":true'*) ok "механизм в конфиге виден" ;; *) no "in_config" true "$J" ;; esac
_age=$(printf '%s' "$J" | sed -n 's/.*"age":\([0-9]*\).*/\1/p')
if [ -n "$_age" ] && [ "$_age" -ge 7200 ] && [ "$_age" -lt 7260 ]; then ok "давность замера в секундах"; else no "age" "~7200" "$_age"; fi

printf '%s\n' '--lua-desync=z2k_sni_pick:blob=z2k_ch' > "$CONFIG_FILE"
J=$(tcp16_status_json)
case "$J" in *'"in_config":false'*) ok "старый селектор не объявлен работающим обходом" ;; *) no "старый селектор" false "$J" ;; esac

printf '0\n' > "$ZAPRET2_DIR/state/tcp16.flag"
: > "$CONFIG_FILE"
J=$(tcp16_status_json)
case "$J" in *'"measured":"0"'*'"in_config":false'*) ok "блока нет и механизма в конфиге нет" ;; *) no "measured=0/in_config=false" "" "$J" ;; esac

rm -f "$ZAPRET2_DIR/state/tcp16.flag" "$ZAPRET2_DIR/state/tcp16.flag.ts"
J=$(tcp16_status_json)
case "$J" in *'"measured":""'*'"age":null'*) ok "не мерили — measured пуст, давности нет" ;; *) no "не мерили" "" "$J" ;; esac
printf 'мусор\n' > "$ZAPRET2_DIR/state/tcp16.flag"
J=$(tcp16_status_json)
case "$J" in *'"measured":""'*) ok "битый флаг читается как «не мерили»" ;; *) no "битый флаг" "" "$J" ;; esac

# --- 2. CGI: запуск пробы ----------------------------------------------------
svc_action_async() { printf 'job-%s' "$(printf '%s' "$*" | tr -c 'a-z0-9' '_' | cut -c1-40)"; }
tcp16_probe_async >/dev/null 2>&1; assert_eq "без файла пробы — код 3" "3" "$?"
: > "$ZAPRET2_DIR/z2k-tcp16-probe.sh"
_job=$(tcp16_probe_async); assert_eq "проба запускается штатной командой" "job-_____________" "$(printf '%s' "$_job" | cut -c1-17)"
case "$(svc_action_async "Проба линии на обрыв 16 КБ" "sh \"${ZAPRET2_DIR}/z2k-tcp16-probe.sh\"")" in
    "$_job") ok "команда пробы — sh <ZAPRET2_DIR>/z2k-tcp16-probe.sh без аргументов" ;;
    *) no "команда пробы" "sh probe без аргументов" "$_job" ;;
esac
probe_lock_on          # проба уже идёт
tcp16_probe_async >/dev/null 2>&1; assert_eq "вторая проба поверх идущей — код 4" "4" "$?"
J=$(tcp16_status_json)
case "$J" in *'"running":true'*) ok "идущая проба видна по замку" ;; *) no "running по замку" true "$J" ;; esac
probe_lock_off
# Замок остался от убитой пробы (владельца нет) — не «идёт».
mkdir -p "$Z2K_TCP16_LOCK"; echo 4194300 > "$Z2K_TCP16_LOCK/pid"
J=$(tcp16_status_json)
case "$J" in *'"running":false'*) ok "брошенный замок мёртвого владельца — проба не идёт" ;; *) no "брошенный замок" false "$J" ;; esac
tcp16_probe_async >/dev/null 2>&1; assert_eq "брошенный замок не мешает запустить пробу" "0" "$?"
probe_lock_off

# --- 1б. оборванный прогон и честный счёт имён -------------------------------
printf '# a\n24940\n13335\n' > "$ZAPRET2_DIR/state/tcp16_asn.txt"
# В карте имя сети БЕЗ блока (рантайм его не применит) и повтор одной сети —
# именно так «имён подобрано» выходило больше, чем «сетей с обрывом».
printf '24940\t300.ya.ru\n55555\tchужая.example\n24940\tповтор.example\n' > "$ZAPRET2_DIR/state/tcp16_sni.txt"
printf '1\n' > "$ZAPRET2_DIR/state/tcp16.flag"
_now=$(date +%s)
printf '%s\n' "$((_now - 7200))" > "$ZAPRET2_DIR/state/tcp16.flag.ts"
printf '%s\n' "$((_now - 7300))" > "$ZAPRET2_DIR/state/tcp16.flag.started"
J=$(tcp16_status_json)
case "$J" in *'"nets_bypassed":1'*) ok "сетей с обходом: только сети с блоком и без повторов" ;; *) no "nets_bypassed" 1 "$J" ;; esac
_nb=$(printf '%s' "$J" | sed -n 's/.*"nets_blocked":\([0-9]*\).*/\1/p')
_nw=$(printf '%s' "$J" | sed -n 's/.*"nets_bypassed":\([0-9]*\).*/\1/p')
if [ "${_nw:-99}" -le "${_nb:-0}" ]; then ok "сетей с обходом не больше, чем сетей с обрывом"; else no "обход ≤ обрыв" "$_nb" "$_nw"; fi
case "$J" in *'"stale":false'*) ok "завершённый прогон — не оборван" ;; *) no "stale" false "$J" ;; esac
# Начало новее завершения и никто не работает — прогон оборван.
printf '%s\n' "$((_now - 60))" > "$ZAPRET2_DIR/state/tcp16.flag.started"
J=$(tcp16_status_json)
case "$J" in *'"stale":true'*) ok "оборванный прогон виден отдельным признаком" ;; *) no "stale" true "$J" ;; esac
probe_lock_on
J=$(tcp16_status_json)
case "$J" in *'"running":true,"stale":false'*) ok "пока проба идёт, оборванным прогон не считается" ;; *) no "stale при running" false "$J" ;; esac
probe_lock_off
rm -f "$ZAPRET2_DIR/state/tcp16.flag.started"

# Маршруты есть в api.sh и ведут к этим функциям.
grep -q '"GET /tcp16")' "$API" && ok "маршрут GET /tcp16" || no "маршрут GET /tcp16" "есть" "нет"
grep -q '"POST /tcp16/probe")' "$API" && ok "маршрут POST /tcp16/probe" || no "маршрут POST /tcp16/probe" "есть" "нет"
grep -q 'json_fail "409 Conflict" "проба уже идёт"' "$API" && ok "повторный запуск отвечает 409" || no "409" "есть" "нет"

# --- 3. Панель: строка состояния карточки ---------------------------------------
if ! command -v node >/dev/null 2>&1; then
    skip "плитки карточки" "node не найден"
else
    APPJS=$(sh "$HERE/lib/panel_js.sh")
    FN=$(awk '/^  function tcp16Line\(/,/^  }$/' "$APPJS")
    if [ -z "$FN" ]; then
        no "tcp16Line найдена в панели" "функция" "нет"
    else
        printf '%s\n' "$FN" > "$TMP/fn.js"
        cat > "$TMP/drive.js" <<'JS'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const tcp16Line = new Function(src + "\nreturn tcp16Line;")();
const j = (t) => { const l = tcp16Line(t); return l.kind + "|" + l.text; };
console.log("blocked\t" + j({ measured: "1", age: 5400, nets_blocked: 12, nets_bypassed: 9, in_config: true, running: false }));
console.log("stale\t" + j({ measured: "1", age: 5400, nets_blocked: 12, nets_bypassed: 0, in_config: false, running: false, stale: true }));
console.log("blockedNoCfg\t" + j({ measured: "1", age: 60, nets_blocked: 1, nets_bypassed: 0, in_config: false, running: false }));
console.log("clean\t" + j({ measured: "0", age: 172800, nets_blocked: 0, nets_bypassed: 0, in_config: false, running: false }));
console.log("never\t" + j({ measured: "", age: null, nets_blocked: 0, nets_bypassed: 0, in_config: false, running: false }));
console.log("running\t" + j({ measured: "0", age: 10, nets_blocked: 0, nets_bypassed: 0, in_config: false, running: true }));
JS
        R=$(node "$TMP/drive.js" "$TMP/fn.js" 2>&1)
        case "$R" in *'blocked	warn|Блок есть, проверено 1 ч назад: обход есть у 9 сетей из 12, включён'*) ok "блок найден: вердикт, давность, сколько сетей с обходом — одной строкой" ;; *) no "блок найден" "warn|…обход есть у 9 сетей из 12, включён" "$R" ;; esac
        case "$R" in *'stale	warn|Прошлая проба оборвалась'*) ok "оборванный прогон: карточка говорит о повторе, а не «имён 0»" ;; *) no "оборванный прогон" "warn|Прошлая проба оборвалась…" "$R" ;; esac
        case "$R" in *'blockedNoCfg	bad|'*'но в конфиг не попал'*) ok "блок есть, а в конфиге нет — расхождение красным" ;; *) no "расхождение" "bad|…не попал" "$R" ;; esac
        case "$R" in *'clean	good|Блока нет, проверено 2 дн назад'*) ok "блока нет: давность в днях, зелёным" ;; *) no "блока нет" "good|Блока нет…" "$R" ;; esac
        case "$R" in *'never	|Линия ещё не проверялась'*) ok "не мерили — так и написано" ;; *) no "не измерялась" "" "$R" ;; esac
        case "$R" in *'running	|проба идёт…'*) ok "идущая проба — «проба идёт…»" ;; *) no "проба идёт" "" "$R" ;; esac
    fi
    # Кнопка и карточка на дашборде, кнопка бьёт в свой маршрут.
    grep -q 'id="tcp16-probe-btn"' "$APPJS" && ok "кнопка «Пробить 16 КБ» на дашборде" || no "кнопка" "есть" "нет"
    grep -q 'apiPost("/tcp16/probe")' "$APPJS" && ok "кнопка зовёт POST /tcp16/probe" || no "маршрут кнопки" "/tcp16/probe" "нет"
    grep -q 'apiGet("/tcp16")' "$APPJS" && ok "карточка читает GET /tcp16" || no "чтение карточки" "/tcp16" "нет"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
