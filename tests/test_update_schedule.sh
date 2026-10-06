#!/bin/sh
# tests/test_update_schedule.sh — час ночного автообновления (issue #60).
#
# До 16.09.2026 час был зашит в планировщик (`case "$hhmm" in 02:00)`), и
# человеку, которому 02:00 не подходит (роутер выключен на ночь, в это время
# идёт бэкап, канал занят), выбрать было нечего. Теперь час лежит в конфиге,
# и у этого есть ровно три места, где всё ломается молча:
#
#   * РАЗБОР. Сравнение строковое: «5» вместо «05» не совпадёт ни с одним
#     тиком, и автообновление просто перестанет приходить — без ошибки, без
#     записи в лог, навсегда. Поэтому всё, что не HH из 00..23, обязано
#     возвращать ночное умолчание, а не то, что написано.
#   * ЧТЕНИЕ. Планировщик тикает каждые 30 секунд вечно. Читать конфиг на
#     каждом тике — 2880 запусков awk в сутки ради значения, которое меняется
#     раз в жизни; читать один раз при старте — заставить человека
#     перезагружать роутер ради выбранного часа. Проверяем оба края.
#   * ЗАПИСЬ. Панель пишет час в конфиг сама; мусор из неё уйти не должен,
#     а отказ обязан быть отказом, а не «сохранено» с прежним значением.
#
# Утверждения поведенческие: боевой код вырезается из файлов и ИСПОЛНЯЕТСЯ —
# грепом ни одно из трёх не проверить.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
SCHED="$HERE/files/z2k-scheduler.sh"
API="$HERE/webpanel/cgi/api.sh"
GEN="$HERE/lib/config_official.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

for f in "$SCHED" "$API" "$GEN"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/ausched.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/opt"

# ---------------------------------------------------------------------------
# 1. Разбор ключа: au_hour() из планировщика, против настоящего файла конфига.
# ---------------------------------------------------------------------------
awk '/^au_hour\(\) \{/,/^\}/' "$SCHED" > "$T/au_hour.sh"
if [ ! -s "$T/au_hour.sh" ]; then
    no "в планировщике есть au_hour()" "функция" "не найдена"
else
    hour_of() { # hour_of <строка конфига или пусто>
        if [ "$1" = "__nofile__" ]; then
            rm -f "$T/opt/config"
        else
            printf '%s\n' "$1" > "$T/opt/config"
        fi
        ZAPRET2_DIR="$T/opt" sh -c ". $T/au_hour.sh; au_hour"
    }
    eq "ключа нет — ночное умолчание"      "02" "$(hour_of 'ENABLED=1')"
    eq "конфига нет вовсе — умолчание"     "02" "$(hour_of __nofile__)"
    eq "выбранный час читается"            "05" "$(hour_of 'Z2K_AU_HOUR=05')"
    eq "час в кавычках читается"           "07" "$(hour_of 'Z2K_AU_HOUR="07"')"
    eq "полночь — валидный час"            "00" "$(hour_of 'Z2K_AU_HOUR=00')"
    eq "23 — валидный час"                 "23" "$(hour_of 'Z2K_AU_HOUR=23')"
    # Ровно те значения, которые выглядят разумно и НЕ СОВПАДАЮТ НИКОГДА.
    eq "час без ведущего нуля отвергнут"   "02" "$(hour_of 'Z2K_AU_HOUR=5')"
    eq "24 отвергнут"                      "02" "$(hour_of 'Z2K_AU_HOUR=24')"
    eq "мусор отвергнут"                   "02" "$(hour_of 'Z2K_AU_HOUR=ночью')"
    eq "время с минутами отвергнуто"       "02" "$(hour_of 'Z2K_AU_HOUR=05:30')"
fi

# ---------------------------------------------------------------------------
# 2. Условие запуска: тот же блок, что крутится в цикле планировщика.
# ---------------------------------------------------------------------------
awk '/hhmm#\*:/,/^    fi$/' "$SCHED" > "$T/block.sh"
if [ ! -s "$T/block.sh" ]; then
    no "в планировщике есть блок запуска автообновления" "блок" "не найден"
else
    # Заглушки вместо соседей по циклу. au_hour ОТМЕЧАЕТ каждый свой вызов:
    # «конфиг не читается вне ровного часа» иначе не утверждение, а надежда.
    {
        printf 'ZAPRET2_DIR="%s/opt"\n' "$T"
        printf 'au_hour() { echo call >> "%s/reads"; printf %%s "$AU_HOUR"; }\n' "$T"
        printf 'last_fired_for_key() { cat "%s/fired" 2>/dev/null; }\n' "$T"
        printf 'mark_fired() { printf %%s "$2" > "%s/fired"; }\n' "$T"
        printf 'run_task() { printf "%%s\\n" "$*" >> "%s/ran"; }\n' "$T"
        cat "$T/block.sh"
    } > "$T/fire.sh"

    fire() { # fire <час из конфига> <hhmm> <дата>
        rm -f "$T/ran" "$T/reads"
        AU_HOUR="$1" hhmm="$2" today="$3" sh "$T/fire.sh"
        [ -f "$T/ran" ] && cat "$T/ran" || true
    }
    reads() { [ -f "$T/reads" ] && wc -l < "$T/reads" | tr -d ' ' || echo 0; }

    rm -f "$T/fired"
    out=$(fire 05 "05:00" 2026-09-16)
    case "$out" in
        *z2k-auto-update.sh*apply*) ok "в выбранный час обновление запускается" ;;
        *) no "запуск в выбранный час" "z2k-auto-update.sh apply" "${out:-<ничего>}" ;;
    esac
    eq "день отмечен — второй раз за сутки не сработает" "" "$(fire 05 "05:00" 2026-09-16)"
    eq "назавтра сработает снова" \
        "auto-update $T/opt/z2k-auto-update.sh apply" "$(fire 05 "05:00" 2026-09-17)"

    # Главное, ради чего всё: в 02:00 у выбравшего 05:00 не происходит НИЧЕГО.
    rm -f "$T/fired"
    eq "в прежние 02:00 обновление не запускается" "" "$(fire 05 "02:00" 2026-09-18)"

    rm -f "$T/fired"
    out=$(fire 02 "02:00" 2026-09-19)
    case "$out" in
        *z2k-auto-update.sh*apply*) ok "умолчание 02:00 работает как раньше" ;;
        *) no "умолчание 02:00" "z2k-auto-update.sh apply" "${out:-<ничего>}" ;;
    esac

    rm -f "$T/fired"
    eq "вне ровного часа не запускается" "" "$(fire 05 "05:30" 2026-09-20)"
    eq "вне ровного часа конфиг не читается" "0" "$(reads)"
    # А на ровном — ровно один раз за тик, не на каждое условие.
    rm -f "$T/fired"
    fire 05 "05:00" 2026-09-21 >/dev/null
    eq "на ровном часе конфиг читается один раз" "1" "$(reads)"
fi

# Зашитого часа в планировщике не осталось: оставленная ветка `02:00)` значила
# бы два запуска в сутки у всех, кто выбрал другое время.
eq "зашитой ветки 02:00 в планировщике нет" "0" \
    "$(grep -c '^ *02:00)' "$SCHED")"
# Генератор конфига обязан и сохранять старое значение, и писать ключ в новый
# файл: без второго ключ исчезает при первой же регенерации, без первого
# сбрасывается в 02 (тот же класс, что issue #38 про автообновление).
eq "генератор сохраняет выбранный час" "1" \
    "$(grep -c 'safe_config_read "Z2K_AU_HOUR"' "$GEN")"
eq "генератор пишет ключ в конфиг" "1" \
    "$(grep -c '^Z2K_AU_HOUR=' "$GEN")"

# ---------------------------------------------------------------------------
# 3. Запись из панели: настоящий api.sh под CGI.
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    skip "запись часа через api.sh" "нет python3"
else
    SB="$T/sb"
    ZAPRET2_DIR="$SB/opt/zapret2";     export ZAPRET2_DIR
    CONFIG_FILE="$ZAPRET2_DIR/config"; export CONFIG_FILE
    LISTS_DIR="$ZAPRET2_DIR/lists";    export LISTS_DIR
    INIT_SCRIPT="$SB/S99-stub";        export INIT_SCRIPT
    mkdir -p "$LISTS_DIR" "$ZAPRET2_DIR/lib"
    printf 'ENABLED=1\nZ2K_AUTO_UPDATE_ENABLED=1\n' > "$CONFIG_FILE"
    printf '#!/bin/sh\nexit 0\n' > "$INIT_SCRIPT"; chmod +x "$INIT_SCRIPT"
    printf '#!/bin/sh\ncreate_official_config() { return 0; }\n' > "$ZAPRET2_DIR/lib/config_official.sh"
    printf '#!/bin/sh\nsafe_config_read() { return 0; }\n'       > "$ZAPRET2_DIR/lib/utils.sh"

    cgi() { # cgi <METHOD> <PATH_INFO> [тело]
        _m="$1"; _p="$2"; _b="${3:-}"
        if [ -n "$_b" ]; then
            printf '%s' "$_b" > "$T/body"
            env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="" \
                HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" \
                CONTENT_LENGTH="$(wc -c < "$T/body" | tr -d ' ')" \
                sh "$API" < "$T/body" 2>/dev/null
        else
            env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="" \
                HTTP_HOST="192.168.1.1" HTTP_X_Z2K_PANEL="1" CONTENT_LENGTH="0" \
                sh "$API" < /dev/null 2>/dev/null
        fi
    }
    body_of()   { awk 'blank{print} /^\r?$/{blank=1}'; }
    status_of() { tr -d '\r' | awk 'NR==1{print; exit}'; }
    jget() { printf '%s' "$1" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("<не JSON>"); raise SystemExit
v = eval(sys.argv[1], {"d": d})
print("null" if v is None else v)' "$2" 2>/dev/null; }
    cfg_hour() { grep '^Z2K_AU_HOUR=' "$CONFIG_FILE" 2>/dev/null | sed 's/^Z2K_AU_HOUR=//' || true; }

    r=$(cgi POST /update/schedule 'hour=05')
    eq "час сохранён: ответ ok"       "True" "$(jget "$(printf '%s' "$r" | body_of)" 'd["ok"]')"
    eq "час сохранён: в конфиге 05"   "05"   "$(cfg_hour)"

    # Отказы. Каждый — значение, которое человек или кривой клиент реально
    # пришлёт, и каждое обязано оставить конфиг нетронутым.
    for bad_val in 25 5 '' 'null' '05:30' '2 3'; do
        r=$(cgi POST /update/schedule "hour=$bad_val")
        st=$(printf '%s' "$r" | status_of)
        case "$st" in
            *400*) ok "отказ на hour='$bad_val'" ;;
            *)     no "отказ на hour='$bad_val'" "400" "${st:-<нет статуса>}" ;;
        esac
    done
    eq "после отказов в конфиге прежний час" "05" "$(cfg_hour)"

    r=$(cgi GET /status)
    eq "панель видит сохранённый час" "05" \
        "$(jget "$(printf '%s' "$r" | body_of)" 'd["toggles"]["au_hour"]')"

    # Конфиг правят и руками. Значение, которое планировщик всё равно заменит
    # на 02, панель обязана показывать как 02 — иначе она обещает 99:00.
    printf 'ENABLED=1\nZ2K_AU_HOUR=99\n' > "$CONFIG_FILE"
    r=$(cgi GET /status)
    eq "мусор в конфиге показан как умолчание" "02" \
        "$(jget "$(printf '%s' "$r" | body_of)" 'd["toggles"]["au_hour"]')"
fi

# ---------------------------------------------------------------------------
# 4. Меню в терминале: что оно обещает после ручной проверки.
# ---------------------------------------------------------------------------
#
# Пункт «Проверить обновления» спрашивает «применить сейчас?», и на отказ
# печатал безусловное «авто-обновление пройдёт ночью (~02:00 + jitter)». Для
# человека с ВЫКЛЮЧЕННЫМ автообновлением это обещание, которого гейт в
# z2k-auto-update.sh не выполнит: он уходил ждать ночь, а ночью ничего не
# происходило. Час с 16.09.2026 тоже свой у каждого.
MENU="$HERE/lib/menu.sh"
awk '/^            local _au_cfg=/,/^            fi$/' "$MENU" > "$T/menu_branch.sh"
if [ ! -s "$T/menu_branch.sh" ]; then
    no "в меню есть ветка про ночное обновление" "блок" "не найден"
else
    menu_says() { # menu_says <строки конфига>
        printf '%b' "$1" > "$T/opt/config"
        {
            printf 'ZAPRET2_DIR="%s/opt"\n' "$T"
            printf 'print_info() { printf "%%s\\n" "$*"; }\n'
            printf 'safe_config_read() {\n  _v=$(grep "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2-)\n  [ -n "$_v" ] || _v="$3"\n  printf %%s "$_v"\n}\n'
            # Ветку оборачиваем в функцию, а не разглаживаем: внутри неё есть
            # `local`, и вне функции он либо ошибка, либо (после подмены на `:`)
            # молча НЕ присваивает — тест тогда мерил бы собственную заглушку.
            printf 'menu_branch() {\n'
            cat "$T/menu_branch.sh"
            printf '}\nmenu_branch\n'
        } > "$T/menu_run.sh"
        sh "$T/menu_run.sh" 2>&1
    }
    out=$(menu_says 'Z2K_AUTO_UPDATE_ENABLED=0\n')
    case "$out" in
        *"НЕ придёт"*) ok "при выключенном автообновлении ночь не обещают" ;;
        *) no "при выключенном автообновлении ночь не обещают" "«ночью обновление НЕ придёт»" "$out" ;;
    esac
    case "$out" in
        *"панели"*) ok "сказано, чем обновиться вместо ночи" ;;
        *) no "сказано, чем обновиться вместо ночи" "упоминание панели/меню" "$out" ;;
    esac
    out=$(menu_says 'Z2K_AUTO_UPDATE_ENABLED=1\nZ2K_AU_HOUR=05\n')
    case "$out" in
        *"05:00"*) ok "обещанный час совпадает с выбранным" ;;
        *) no "обещанный час совпадает с выбранным" "05:00" "$out" ;;
    esac
    case "$out" in
        *"02:00"*) no "зашитых 02:00 в обещании нет" "без 02:00" "$out" ;;
        *) ok "зашитых 02:00 в обещании нет" ;;
    esac
fi

# Разброс ночного запуска — час, а не полтора: значение живёт в трёх местах
# (утилита, вызов из апдейтера, подпись в панели), и разъехавшись, они
# превращают подпись под селектором в неправду.
eq "разброс в утилите — 3600 с" "3" \
    "$(grep -c '3600' "$HERE/lib/utils.sh")"
eq "апдейтер просит тот же разброс" "1" \
    "$(grep -c 'z2k_host_jitter 3600' "$HERE/files/z2k-auto-update.sh")"
eq "панель подписывает тот же разброс" "1" \
    "$(grep -c 'AU_JITTER_MIN = 60;' "$HERE/webpanel/www/js/pages/toggles.js")"

# Баннер на дашборде берёт час из ответов /update/*, а не отдельным запросом:
# без этих двух вызовов подпись «автообновление в HH:00» молча уедет на
# умолчание у всех, кто выбрал другое время.
eq "оба ответа /update отдают расписание" "2" \
    "$(grep -c '^ *au_schedule_json$' "$API")"

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
