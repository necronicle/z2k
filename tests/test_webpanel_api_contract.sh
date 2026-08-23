#!/bin/sh
# tests/test_webpanel_api_contract.sh - контракт HTTP-ответа webpanel/cgi/api.sh:
# ответ обязан начинаться заголовками и быть разбираемым JSON'ом при ЛЮБОМ
# содержимом файлов на диске (конфиг, state.tsv, /tmp job-файлы). Дёргаем
# полным CGI-вызовом с env как у lighttpd; валидность JSON проверяет python3.
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf "[SKIP] %s (%s)\n" "$1" "$2"; }

assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected '%s', got '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    case "$3" in
        *"$2"*) TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1" ;;
        *)      TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: '%s' not in output: %s\n" "$1" "$2" "$3" ;;
    esac
}
assert_not_contains() {
    case "$3" in
        *"$2"*) TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: unexpected '%s' in output\n" "$1" "$2" ;;
        *)      TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# python3 разбирает тела ответов — без него сюита не проверяет ничего, но и
# краснеть не должна: на роутере python3 нет, а run_all.sh гоняется и там.
# Так же поступают test_release_tooling.sh и test_update_content_verification.sh.
command -v python3 >/dev/null 2>&1 || {
    skip "контракт HTTP-ответа api.sh" "нет python3"
    printf "\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
    exit 0
}

# Оболочка, под которой запускается api.sh. Роутерный /bin/sh — busybox ash:
# ${#var} там считает БАЙТЫ, а case-шаблоны сопоставляются побайтно. macOS'ный
# /bin/sh — bash 3.2, и в UTF-8 локали он считает символы и НЕ ловит кириллицу
# диапазоном [!A-Za-z0-9_-]. Гоняя тут /bin/sh, мы бы мерили оболочку
# разработчика: проверки многобайтных имён зеленели бы при любом коде api.sh.
# dash ведёт себя как ash — берём его, если он есть.
if command -v dash >/dev/null 2>&1; then SH_UT="dash"; else SH_UT="sh"; fi
printf "api.sh под оболочкой: %s\n" "$SH_UT"

# --- sandbox ---
SB="$(mktemp -d)"
JOB_IDS=""
cleanup() {
    for _j in $JOB_IDS; do
        rm -f "/tmp/z2k-job-$_j.log" "/tmp/z2k-job-$_j.pid" "/tmp/z2k-job-$_j.exit"
    done
    rm -rf "$SB"
}
trap cleanup EXIT

ZAPRET2_DIR="$SB/opt/zapret2";                  export ZAPRET2_DIR
CONFIG_FILE="$ZAPRET2_DIR/config";              export CONFIG_FILE
LISTS_DIR="$ZAPRET2_DIR/lists";                 export LISTS_DIR
WHITELIST_FILE="$LISTS_DIR/whitelist.txt";      export WHITELIST_FILE
CUSTOM_STRAT_DIR="$LISTS_DIR/custom-strategies"; export CUSTOM_STRAT_DIR
WARP_LISTS_DIR="$LISTS_DIR/warp";               export WARP_LISTS_DIR
STATE_FILE="$ZAPRET2_DIR/state.tsv";            export STATE_FILE
STATE_FILE_FALLBACK="$SB/state-fallback.tsv";   export STATE_FILE_FALLBACK
INIT_SCRIPT="$SB/S99-stub";                     export INIT_SCRIPT
AU_MANIFEST_CACHE="$SB/manifest.json";          export AU_MANIFEST_CACHE
mkdir -p "$LISTS_DIR" "$CUSTOM_STRAT_DIR" "$ZAPRET2_DIR/lib"
printf 'ENABLED=1\nGAME_WARP_ENABLED=0\n' > "$CONFIG_FILE"

# Заглушка генератора: regenerate_config ищет lib/config_official.sh сначала в
# $ZAPRET2_DIR/lib, потом в /tmp/z2k/lib — свой кладём первым, чтобы тест не
# зависел от того, что лежит в /tmp на машине сборки. utils.sh — по той же
# причине (иначе подхватится чужой).
printf '#!/bin/sh\ncreate_official_config() { return 0; }\n' > "$ZAPRET2_DIR/lib/config_official.sh"
printf '#!/bin/sh\nsafe_config_read() { return 0; }\n'       > "$ZAPRET2_DIR/lib/utils.sh"

# Init-заглушка: печатает в stdout ровно так же, как настоящий S99 при restart.
printf '#!/bin/sh\necho "Stopping nfqws2..."\necho "Starting nfqws2..."\nexit 0\n' > "$INIT_SCRIPT"
chmod +x "$INIT_SCRIPT"

# Копия cgi/ с подменённым is_running: «сервис запущен» иначе определяется
# через pgrep по всей машине, а фоновый процесс с nfqws2 в командной строке
# сломал бы соседние сюиты. api.sh копируется БЕЗ правок — проверяем именно его.
STUBDIR="$SB/cgi"
mkdir -p "$STUBDIR"
cp "$SCRIPT_DIR/webpanel/cgi/api.sh" "$SCRIPT_DIR/webpanel/cgi/auth.sh" \
   "$SCRIPT_DIR/webpanel/cgi/actions.sh" "$STUBDIR/"
cat >> "$STUBDIR/actions.sh" <<'STUB'
is_running() { [ -f "${Z2K_TEST_RUNNING:-/nonexistent}" ]; }
STUB
Z2K_TEST_RUNNING="$SB/running"; export Z2K_TEST_RUNNING

# --- CGI helpers ---
# HTTP_X_Z2K_PANEL — то же, что app.js шлёт на каждом fetch; без него
# origin-страж в cgi/auth.sh отвечает 403 и до роутинга дело не доходит.
cgi_at() { # cgi_at <api.sh> <METHOD> <PATH_INFO> <QUERY> [bodyfile] [content-length]
    _a="$1"; _m="$2"; _p="$3"; _q="$4"; _b="${5:-}"; _cl="${6:-}"
    if [ -n "$_b" ]; then
        [ -n "$_cl" ] || _cl=$(wc -c < "$_b" | tr -d ' ')
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="$_cl" \
            "$SH_UT" "$_a" < "$_b" 2>/dev/null
    else
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="${_cl:-0}" \
            "$SH_UT" "$_a" < /dev/null 2>/dev/null
    fi
}
cgi()      { cgi_at "$SCRIPT_DIR/webpanel/cgi/api.sh" "$@"; }
cgi_stub() { cgi_at "$STUBDIR/api.sh" "$@"; }

cgi_body()    { awk 'blank{print} /^\r?$/{blank=1}'; }
cgi_status()  { tr -d '\r' | awk 'NR==1{print; exit}'; }
cgi_ctype()   { tr -d '\r' | awk '/^$/{exit} tolower($1)=="content-type:"{print $2}'; }

json_ok_p() { printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 && echo 1 || echo 0; }
jget() {    # jget <json> <python-expr над d>
    printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = eval(sys.argv[1], {"d": d})
if v is None: print("null")
elif v is True: print("true")
elif v is False: print("false")
else: print(v)
' "$2" 2>/dev/null
}

printf "\n--- /strategy/pool/reset: заголовки не затираются выводом restart ---\n"
# strategy_pool_reset зовёт restart_service_if_running, а та ПЕЧАТАЕТ в stdout
# (её контракт менять нельзя — на нём держится job-лог svc_action_async).
# Захватить обязан api.sh, иначе первые байты ответа — «Stopping nfqws2...»,
# lighttpd разбирает их как заголовок и отдаёт 500/мусор, а фронт валит кнопку
# «вернуть авто» в ошибку при успешно выполненном сбросе.
: > "$Z2K_TEST_RUNNING"
printf 'x\n' > "$CUSTOM_STRAT_DIR/rkn_tcp.txt"
BODYF="$SB/body.txt"
printf 'pool=rkn_tcp' > "$BODYF"
RAW=$(cgi_stub POST /strategy/pool/reset "" "$BODYF")
OUT=$(printf '%s\n' "$RAW" | cgi_body)
assert_eq       "running: первая строка — статус"  "Status: 200 OK" "$(printf '%s\n' "$RAW" | cgi_status)"
assert_eq       "running: Content-Type JSON"       "application/json;" "$(printf '%s\n' "$RAW" | cgi_ctype)"
assert_eq       "running: тело — валидный JSON"    "1" "$(json_ok_p "$OUT")"
assert_contains "running: сброс отчитался ok"      '"ok":true' "$OUT"
assert_not_contains "вывод restart не попал в тело" "Starting nfqws2" "$OUT"
assert_eq       "custom-стратегия удалена"         "0" "$([ -f "$CUSTOM_STRAT_DIR/rkn_tcp.txt" ] && echo 1 || echo 0)"

# Вторая ветка той же дыры: при остановленном сервисе функция печатает
# «Сервис не запущен — пропускаю restart» — тоже в stdout, тоже до заголовков.
rm -f "$Z2K_TEST_RUNNING"
printf 'x\n' > "$CUSTOM_STRAT_DIR/yt_tcp.txt"
printf 'pool=yt_tcp' > "$BODYF"
RAW=$(cgi_stub POST /strategy/pool/reset "" "$BODYF")
OUT=$(printf '%s\n' "$RAW" | cgi_body)
assert_eq       "stopped: первая строка — статус"  "Status: 200 OK" "$(printf '%s\n' "$RAW" | cgi_status)"
assert_eq       "stopped: тело — валидный JSON"    "1" "$(json_ok_p "$OUT")"
assert_eq       "stopped: pool в ответе"           "yt_tcp" "$(jget "$OUT" 'd["pool"]')"

printf 'pool=nosuchpool' > "$BODYF"
RAW=$(cgi POST /strategy/pool/reset "" "$BODYF")
OUT=$(printf '%s\n' "$RAW" | cgi_body)
assert_contains "неизвестный пул -> 400"           "Status: 400" "$(printf '%s\n' "$RAW" | cgi_status)"
assert_eq       "отказ тоже валидный JSON"         "1" "$(json_ok_p "$OUT")"

printf "\n--- /status: значение флага с кавычкой не рвёт JSON ---\n"
# read_flag снимает только ОКРУЖАЮЩИЕ кавычки, так что правленный руками
# конфиг отдаёт значение с кавычкой внутри. Раньше оно шло в "%s" как есть:
# JSON.parse во фронте падал, и весь дашборд показывал «Ошибка».
printf 'ENABLED=1\nGAME_WARP_ENABLED=0"x\nZ2K_PPE_DEOFFLOAD=a\\b\nZ2K_STATS=да\n' > "$CONFIG_FILE"
OUT=$(cgi GET /status "" | cgi_body)
assert_eq "тело /status — валидный JSON"      "1"    "$(json_ok_p "$OUT")"
assert_eq "кавычка доехала экранированной"    '0"x'  "$(jget "$OUT" 'd["toggles"]["game_warp"]')"
assert_eq "обратный слэш доехал экранированным" 'a\b' "$(jget "$OUT" 'd["toggles"]["ppe"]')"
assert_eq "кириллица не превратилась в escape" 'да'  "$(jget "$OUT" 'd["toggles"]["stats"]')"
printf 'ENABLED=1\nGAME_WARP_ENABLED=1\n' > "$CONFIG_FILE"
OUT=$(cgi GET /status "" | cgi_body)
assert_eq "нормальный флаг читается как раньше" "1" "$(jget "$OUT" 'd["toggles"]["game_warp"]')"

printf "\n--- /policy/status, /warp/status, /debug: те же сырые %%s ---\n"
printf 'ENABLED=1\nPOLICY_NAME=Через ВПН\nPOLICY_EXCLUDE=0"x\n' > "$CONFIG_FILE"
OUT=$(cgi GET /policy/status "" | cgi_body)
assert_eq "policy/status — валидный JSON"  "1"          "$(json_ok_p "$OUT")"
assert_eq "имя политики с пробелом+UTF-8"  "Через ВПН"  "$(jget "$OUT" 'd["name"]')"
assert_eq "exclude с кавычкой экранирован" '0"x'        "$(jget "$OUT" 'd["exclude"]')"

printf 'ENABLED=1\nGAME_WARP_ENABLED=0"x\n' > "$CONFIG_FILE"
OUT=$(cgi GET /warp/status "" | cgi_body)
assert_eq "warp/status — валидный JSON"    "1"  "$(json_ok_p "$OUT")"
assert_eq "warp enabled экранирован"       '0"x' "$(jget "$OUT" 'd["enabled"]')"

OUT=$(cgi GET /debug "" | cgi_body)
assert_eq "debug — валидный JSON"          "1"  "$(json_ok_p "$OUT")"
printf 'ENABLED=1\n' > "$CONFIG_FILE"

printf "\n--- /warp/status: поля движка z2k-warpd; /warp/install|remove: job; /warp/devices ---\n"
# Статус панель читает из status.json движка через z2k-warp.sh status — без проб.
WARP_SCRIPT="$SB/warp-stub.sh"; export WARP_SCRIPT
cat > "$WARP_SCRIPT" <<'WSTUB'
#!/bin/sh
case "$1" in
    status) echo 'installed=1 enabled=1 ready=1 transport=wg endpoint=8.6.112.0:2408 iface=z2ktun0 addr=172.16.0.2 entries=12 devices=2 error=' ;;
    ipset)  : ;;
    migrate) mkdir -p "$WARP_LISTS_DIR"; touch "$WARP_LISTS_DIR/.legacy-aggregate-purged" ;;
esac
WSTUB
chmod +x "$WARP_SCRIPT"
printf 'ENABLED=1\nGAME_WARP_ENABLED=1\n' > "$CONFIG_FILE"
OUT=$(cgi GET /warp/status "" | cgi_body)
assert_eq "warp/status — валидный JSON"          "1"               "$(json_ok_p "$OUT")"
assert_eq "warp/status — installed из скрипта"   "true"            "$(jget "$OUT" 'd["installed"]')"
assert_eq "warp/status — ready"                  "true"            "$(jget "$OUT" 'd["ready"]')"
assert_eq "warp/status — transport"              "wg"              "$(jget "$OUT" 'd["transport"]')"
assert_eq "warp/status — endpoint"               "8.6.112.0:2408"  "$(jget "$OUT" 'd["endpoint"]')"
assert_eq "warp/status — iface"                  "z2ktun0"         "$(jget "$OUT" 'd["iface"]')"
assert_eq "warp/status — devices"                "2"               "$(jget "$OUT" 'd["devices"]')"
assert_eq "warp/status — error пустой"           ""                "$(jget "$OUT" 'd["error"]')"

OUT=$(cgi POST /warp/install "" | cgi_body)
assert_eq "warp/install — валидный JSON с job" "1" "$(jget "$OUT" '1 if d.get("job") else 0')"
OUT=$(cgi POST /warp/remove "" | cgi_body)
assert_eq "warp/remove — валидный JSON с job"  "1" "$(jget "$OUT" '1 if d.get("job") else 0')"

printf '192.168.1.5\nzz\nAA:BB:CC:DD:EE:FF\n11-22-33-44-55-66\n999.1.1.1\n' > "$SB/devices.body"
OUT=$(cgi POST /warp/devices/save "" "$SB/devices.body" | cgi_body)
assert_eq "warp/devices/save — валидный JSON"  "1" "$(json_ok_p "$OUT")"
assert_eq "warp/devices/save — entries=3"      "3" "$(jget "$OUT" 'd["entries"]')"
assert_eq "warp/devices/save — dropped=2"      "2" "$(jget "$OUT" 'd["dropped"]')"
assert_eq "devices.txt — три строки"           "3" "$(wc -l < "$WARP_LISTS_DIR/devices.txt" | tr -d ' ')"
assert_eq "devices.txt — MAC нормализован"     "aa:bb:cc:dd:ee:ff" "$(sed -n 2p "$WARP_LISTS_DIR/devices.txt")"
OUT=$(cgi GET /warp/devices "")
assert_eq "warp/devices — text/plain"          "1" "$(printf '%s' "$OUT" | grep -c 'Content-Type: text/plain')"
assert_eq "warp/devices — отдаёт сохранённое"  "1" "$(printf '%s' "$OUT" | grep -c '^11:22:33:44:55:66$')"

# Соседи из Keenetic: стаб ndmc отдаёт формат `show ip hotspot`.
cat > "$SB/ndmc-stub" <<'NSTUB'
#!/bin/sh
printf '                  mac: 6c:15:db:10:cc:7a\n                   ip: 10.1.30.147\n             hostname: LGwebOSTV\n                 name: Телевизор "LG"\n            interface: \n                     name: Guest\n           registered: yes\n               active: yes\n'
printf '                  mac: AA:BB:CC:DD:EE:FF\n                   ip: 192.168.1.77\n             hostname: PS5-xyz\n                 name: aa:bb:cc:dd:ee:ff - Home network - 2026-01-24\n            interface: \n                     name: Home\n           registered: no\n               active: no\n'
NSTUB
chmod +x "$SB/ndmc-stub"; WARP_NDMC="$SB/ndmc-stub"; export WARP_NDMC
OUT=$(cgi GET /warp/neighbors "" | cgi_body)
assert_eq "warp/neighbors — валидный JSON"      "1" "$(json_ok_p "$OUT")"
assert_eq "warp/neighbors — два устройства"     "2" "$(jget "$OUT" 'len(d["devices"])')"
assert_eq "warp/neighbors — имя из Keenetic без кавычек" "Телевизор LG" "$(jget "$OUT" '[x for x in d["devices"] if x["mac"]=="6c:15:db:10:cc:7a"][0]["label"]')"
assert_eq "warp/neighbors — hostname вместо авто-имени Keenetic" "PS5-xyz" "$(jget "$OUT" '[x for x in d["devices"] if x["mac"]=="aa:bb:cc:dd:ee:ff"][0]["label"]')"
assert_eq "warp/neighbors — on по devices.txt"  "true" "$(jget "$OUT" '[x for x in d["devices"] if x["mac"]=="aa:bb:cc:dd:ee:ff"][0]["on"]')"
assert_eq "warp/neighbors — сеть"               "Guest" "$(jget "$OUT" 'd["devices"][0]["net"]')"
assert_eq "warp/neighbors — активные первыми"   "6c:15:db:10:cc:7a" "$(jget "$OUT" 'd["devices"][0]["mac"]')"
printf 'mac=6c:15:db:10:cc:7a&value=1\n' > "$SB/tg.body"
OUT=$(cgi POST /warp/devices/toggle "" "$SB/tg.body" | cgi_body)
assert_eq "warp/devices/toggle on — ok"        "true" "$(jget "$OUT" 'd["ok"]')"
assert_eq "devices.txt — MAC добавлен"         "1" "$(grep -c '^6c:15:db:10:cc:7a$' "$WARP_LISTS_DIR/devices.txt")"
printf 'mac=AA-BB-CC-DD-EE-FF&value=0\n' > "$SB/tg.body"
OUT=$(cgi POST /warp/devices/toggle "" "$SB/tg.body" | cgi_body)
assert_eq "warp/devices/toggle off — ok"       "true" "$(jget "$OUT" 'd["ok"]')"
assert_eq "devices.txt — MAC убран"            "0" "$(grep -c 'aa:bb:cc:dd:ee:ff' "$WARP_LISTS_DIR/devices.txt")"
assert_eq "devices.txt — ручная строка цела"   "1" "$(grep -c '^192.168.1.5$' "$WARP_LISTS_DIR/devices.txt")"
printf 'mac=zz&value=1\n' > "$SB/tg.body"
OUT=$(cgi POST /warp/devices/toggle "" "$SB/tg.body" | cgi_body)
assert_eq "warp/devices/toggle bad mac — ok:false" "false" "$(jget "$OUT" 'd["ok"]')"
unset WARP_NDMC
printf 'ENABLED=1\n' > "$CONFIG_FILE"

printf "\n--- /state: битое 4-е поле не роняет весь ответ ---\n"
# ts печатается ЧИСЛОМ без кавычек. Обрыв записи в state.tsv оставлял там
# мусор, и невалидным становился ВЕСЬ ответ — таблица пустела целиком.
printf '# hdr\n' > "$STATE_FILE"
printf 'rkn_tcp\tgood.example\t3\t1754000000\tauto\n'      >> "$STATE_FILE"
printf 'rkn_tcp\ttorn.example\t2\t17540abc\tauto\n'        >> "$STATE_FILE"
printf 'rkn_tcp\tinj.example\t1\t1,"x":1\tfrozen\n'        >> "$STATE_FILE"
printf 'rkn_tcp\tempty.example\t1\t\tauto\n'               >> "$STATE_FILE"
# Одних цифр мало: JSON запрещает ведущий ноль, и 0123456789 из битой записи
# делает неразбираемым ВЕСЬ ответ ровно так же, как буквы в поле.
printf 'rkn_tcp\tzero.example\t1\t0123456789\tauto\n'      >> "$STATE_FILE"
OUT=$(cgi GET /state "" | cgi_body)
assert_eq "state — валидный JSON"              "1" "$(json_ok_p "$OUT")"
assert_eq "все 5 строк на месте"               "5" "$(jget "$OUT" 'len(d["entries"])')"
assert_eq "целая строка сохранила ts"          "1754000000" "$(jget "$OUT" '[e for e in d["entries"] if e["host"]=="good.example"][0]["ts"]')"
assert_eq "битый ts обнулён"                   "0" "$(jget "$OUT" '[e for e in d["entries"] if e["host"]=="torn.example"][0]["ts"]')"
assert_eq "инъекция структуры не прошла"       "0" "$(jget "$OUT" '[e for e in d["entries"] if e["host"]=="inj.example"][0]["ts"]')"
assert_eq "ведущий ноль в ts срезан"           "123456789" "$(jget "$OUT" '[e for e in d["entries"] if e["host"]=="zero.example"][0]["ts"]')"
assert_eq "лишних ключей не появилось"         "0" "$(jget "$OUT" 'sum(1 for e in d["entries"] if "x" in e)')"
rm -f "$STATE_FILE"

printf "\n--- /job: незнакомый id терминален (done:true) ---\n"
# С done:false поллер панели крутится вечно и не отпускает глобальный UI-lock.
OUT=$(cgi GET /job "id=190000000000" | cgi_body)
assert_eq "job — валидный JSON"     "1"       "$(json_ok_p "$OUT")"
assert_eq "status=unknown"          "unknown" "$(jget "$OUT" 'd["status"]')"
assert_eq "done=true"               "true"    "$(jget "$OUT" 'd["done"]')"
assert_eq "exit=null"               "null"    "$(jget "$OUT" 'd["exit"]')"
assert_eq "log пустой"              ""        "$(jget "$OUT" 'd["log"]')"

printf "\n--- /whitelist/import: потолок размера ---\n"
# Список засеян намеренно: whitelist_import сверяет новое со старым одной
# awk-программой на NR==FNR, а при ПУСТОМ первом файле это условие истинно и
# для второго — импорт в пустой whitelist не добавляет ничего. Баг в
# actions.sh, к пути чтения тела отношения не имеет.
printf 'seed.example\n' > "$WHITELIST_FILE"
printf 'good-one.example\nGOOD-TWO.example\n' > "$BODYF"
OUT=$(cgi POST /whitelist/import "" "$BODYF" | cgi_body)
assert_eq "импорт добавил 2 домена" "2" "$(jget "$OUT" 'd["added"]')"
# Гейт на CONTENT_LENGTH срабатывает ДО чтения тела — 3 МБ файла для этого
# создавать не нужно, проверяется ровно тот заголовок, который его включает.
RAW=$(cgi POST /whitelist/import "" "$BODYF" "3000000")
OUT=$(printf '%s\n' "$RAW" | cgi_body)
assert_contains "тело >2 МБ -> 413"        "Status: 413" "$(printf '%s\n' "$RAW" | cgi_status)"
assert_eq       "отказ — валидный JSON"    "1" "$(json_ok_p "$OUT")"
assert_eq       "список не тронут"         "3" "$(grep -c . "$WHITELIST_FILE")"

printf "\n--- /policy/save: денилист вместо чарсета, имя мимо eval ---\n"
# Гейт обязан совпадать с policy_save в actions.sh: имена политик Keenetic
# человек пишет по-русски и с пробелами. Безопасность держится не на чарсете,
# а на том, что в eval-строку уходит литеральный $Z2K_POLICY_NAME — это
# проверяется E2E ниже («eval не выполнил имя как код», «без glob и фона»),
# а не грепом по тексту api.sh.

policy_post() { # policy_post <urlencoded-name>
    printf 'name=%s&exclude=0' "$1" > "$BODYF"
    cgi POST /policy/save "" "$BODYF" | cgi_body
}
urlenc() { # urlenc <строка> -> %XX для КАЖДОГО байта (form_value декодирует %XX)
    printf '%s' "$1" | od -An -tx1 -v | awk '{ for (i = 1; i <= NF; i++) printf "%%%s", $i }'
}
job_wait() { # job_wait <id> — ждём появления .exit, не дольше 10 с
    _w=0
    while [ "$_w" -lt 10 ]; do
        [ -f "/tmp/z2k-job-$1.exit" ] && return 0
        _w=$((_w + 1)); sleep 1
    done
    return 1
}
# a%27b — апостроф: set_flag пишет значение в одинарных кавычках и экранирует
# его как '\'', а safe_config_read обратно не разворачивает — имя портится
# навсегда при первой перегенерации конфига.
# a%7Cb — вертикальная черта: policy_status отдаёт name=%s|exclude=%s|exists=%s,
# и на чтении назад имя режется по разделителю.
for _bad in 'a%22b' 'a%60b' 'a%3Bb' 'a%24%28id%29b' 'a%5Cb' 'a%0Ab' 'a%27b' 'a%7Cb'; do
    OUT=$(policy_post "$_bad")
    assert_eq "отклонено имя '$_bad'" "false" "$(jget "$OUT" 'd["ok"]')"
done
OUT=$(policy_post "aaaa%20aaaa%20aaaa%20aaaa%20aaaa%20aaaa%20aaaa%20aaaa%20a")
assert_eq "отклонено имя длиннее 32" "false" "$(jget "$OUT" 'd["ok"]')"

# «Через ВПН» — ровно то имя, ради которого policy_save перевели на денилист.
OUT=$(policy_post "%D0%A7%D0%B5%D1%80%D0%B5%D0%B7%20%D0%92%D0%9F%D0%9D")
assert_eq "имя с пробелом и кириллицей принято" "true" "$(jget "$OUT" 'd["ok"]')"
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"
job_wait "$JOB"
assert_eq "задача завершилась"                "1" "$([ -f "/tmp/z2k-job-$JOB.exit" ] && echo 1 || echo 0)"
assert_eq "имя доехало до конфига целиком"    "1" "$(grep -c 'POLICY_NAME=.*Через ВПН' "$CONFIG_FILE")"
assert_eq "eval не выполнил имя как код"      "0" "$(grep -c 'POLICY_NAME=$' "$CONFIG_FILE")"

# Глоб и управляющие операторы шелла денилист пропускает — и обязан пропускать:
# внутри eval значение раскрывается из переменной, а не парсится как код.
printf 'ENABLED=1\n' > "$CONFIG_FILE"
OUT=$(policy_post "a%20%26%20b%20%2A")
assert_eq "имя с & и * принято"  "true" "$(jget "$OUT" 'd["ok"]')"
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"
job_wait "$JOB"
assert_eq "имя записано дословно, без glob и фона" "1" \
    "$(grep -c 'POLICY_NAME=.*a & b \*' "$CONFIG_FILE")"

# Потолок длины — в СИМВОЛАХ, а не в байтах. Форма в панели ограничена
# maxlength="32", а ${#name} на ash/dash считает байты: «Домашняя политика» —
# это 17 символов и 33 байта, то есть сервер отбивал 400 ровно тот класс имён,
# ради которого гейт и переписывали на денилист.
#
# Проверяется вердикт МАРШРУТА (400 или задача), а не содержимое конфига:
# записью занимается policy_save в actions.sh, и её собственный потолок длины
# живёт отдельно — сюда его состояние подмешивать нельзя, иначе сюита меряет
# соседний файл.
printf 'ENABLED=1\n' > "$CONFIG_FILE"
RAW=$(printf 'name=%s&exclude=0' "$(urlenc 'Домашняя политика')" > "$BODYF"; cgi POST /policy/save "" "$BODYF")
OUT=$(printf '%s\n' "$RAW" | cgi_body)
assert_eq "кириллическое имя в 17 символов (33 байта) принято" "true" "$(jget "$OUT" 'd["ok"]')"
assert_eq "оно же: не 400 от маршрута" "Status: 200 OK" "$(printf '%s\n' "$RAW" | cgi_status)"
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"
job_wait "$JOB"

_i=0; NAME32=""
while [ "$_i" -lt 32 ]; do NAME32="${NAME32}я"; _i=$((_i + 1)); done
OUT=$(policy_post "$(urlenc "$NAME32")")
assert_eq "кириллическое имя ровно в 32 символа принято" "true" "$(jget "$OUT" 'd["ok"]')"
JOB=$(jget "$OUT" 'd["job"]'); JOB_IDS="$JOB_IDS $JOB"
job_wait "$JOB"

OUT=$(policy_post "$(urlenc "${NAME32}я")")
assert_eq "кириллическое имя в 33 символа отклонено" "false" "$(jget "$OUT" 'd["ok"]')"

printf "\n--- form_value / json_escape (вырезаны из api.sh) ---\n"
# api.sh — не библиотека: source запускает диспетчер и завершает процесс.
# Поэтому две чистые функции вырезаем из НЕГО ЖЕ (не копия, не переписывание)
# и зовём напрямую.
LIBF="$SB/apilib.sh"
awk '/^form_value/,/^\}$/'  "$SCRIPT_DIR/webpanel/cgi/api.sh" >  "$LIBF"
awk '/^json_escape/,/^\}$/' "$SCRIPT_DIR/webpanel/cgi/api.sh" >> "$LIBF"
assert_eq "обе функции вырезались" "1" "$(grep -c '^json_escape() {' "$LIBF")"

# Цель для глоба именуется как ЦЕЛАЯ пара: раскрывается весь токен "v=...",
# поэтому файл, не начинающийся с "v=", ничего бы не поймал.
: > "$SB/v=ab"
fv() { # fv <query> <key>
    ( cd "$SB" && "$SH_UT" -c '. "$0"; form_value "$1" "$2"' "$LIBF" "$1" "$2" < /dev/null )
}
# Декодирование РОВНО один раз: замена внутри $0 перезапускала match() с начала
# строки, то есть декодировала уже раскодированное (%2541 -> %41 -> A).
assert_eq "%XX декодируется один раз"    '%41'      "$(fv 'v=%2541' v)"
assert_eq "плюс -> пробел"               'a b'      "$(fv 'v=a+b' v)"
assert_eq "суффикс адресного семейства"  'host|6'   "$(fv 'v=host%7C6' v)"
assert_eq "нет раскрытия по каталогу"    '*'          "$(fv 'v=*' v)"
assert_eq "квадратные скобки не глоб"    '[a-z][a-z]' "$(fv 'v=[a-z][a-z]' v)"
assert_eq "ключа нет — пусто"            ''         "$(fv 'other=1' v)"
assert_eq "вторая пара находится"        '7'        "$(fv 'a=1&v=7&b=2' v)"

# Промах по ord[] сравнивался с 32 как ноль и печатал \u0000: на multibyte-aware
# awk так терялась кириллица в diag-выводе и job-логах.
ESC=$(printf 'привет\tмир\n' | "$SH_UT" -c '. "$0"; json_escape' "$LIBF")
assert_contains     "кириллица прошла как есть" "привет" "$ESC"
assert_not_contains "нет \u0000 в выводе"       '\u0000' "$ESC"
assert_contains     "таб экранирован"           '\t'     "$ESC"
ESC=$(printf 'a\001b"c\\d\n' | "$SH_UT" -c '. "$0"; json_escape' "$LIBF")
assert_contains     "управляющий байт всё ещё escape" '\u0001' "$ESC"
assert_contains     "кавычка экранирована"            '\"'      "$ESC"
assert_contains     "слэш экранирован"                '\\'      "$ESC"

printf "\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
