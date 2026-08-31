#!/bin/sh
# z2k webpanel — CGI dispatcher.
#
# Routes /api/* requests to handlers in actions.sh. All reads are GET,
# all mutations are POST. Returns JSON with Content-Type header.
#
# The HTTP server invokes this with standard CGI env vars:
#   REQUEST_METHOD, PATH_INFO, QUERY_STRING, CONTENT_LENGTH, CONTENT_TYPE
#   REMOTE_USER (set after basic-auth), HTTP_HOST, HTTP_REFERER
#
# Body for POSTs is on stdin.

# lighttpd mod_cgi passes a nearly-empty environment to scripts — no PATH.
# On Entware all standard tools live in /opt/{bin,sbin,usr/bin,usr/sbin} and
# system tools in /bin:/sbin. Set an explicit PATH so cut/grep/sed/awk/cat/dd
# etc. all resolve, otherwise they silently fail with "command not found" and
# our handlers return empty JSON.
export PATH="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin"

set -u

# $0 is usually the symlink at /opt/zapret2/www/cgi-bin/api that lighttpd
# invokes, not the real file. Resolve to the directory holding auth.sh +
# actions.sh.
if real_self=$(readlink -f "$0" 2>/dev/null); then
    SELF_DIR=$(dirname "$real_self")
else
    SELF_DIR=$(dirname "$0" 2>/dev/null)
fi
[ -d "$SELF_DIR" ] && [ -f "$SELF_DIR/auth.sh" ] || SELF_DIR="/opt/zapret2/webpanel/cgi"

# shellcheck source=auth.sh
. "$SELF_DIR/auth.sh"
# shellcheck source=actions.sh
. "$SELF_DIR/actions.sh"

# --- utility: json output ---

json_header() {
    printf 'Status: 200 OK\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
}

# Minimal JSON string escape: backslash, quote, control chars.
#
# Управляющие символы ищутся через `c in ord`, а не просто по ord[c] < 32:
# промах по таблице — это не управляющий символ, а символ, которого в ней нет.
# На multibyte-aware awk кириллица приходит одним символом, ord[c] возвращает
# пустую строку, а она численно равна нулю — и байт уезжал в \u0000.
json_escape() {
    # LC_ALL=C по той же причине, что и в form_value: таблица ord[] строится
    # через sprintf("%c", 0..255) и обязана быть байтовой.
    # shellcheck disable=SC2016
    LC_ALL=C awk 'BEGIN {
        for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    }
    {
        s = $0
        out = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\\") out = out "\\\\"
            else if (c == "\"") out = out "\\\""
            else if (c == "\n") out = out "\\n"
            else if (c == "\r") out = out "\\r"
            else if (c == "\t") out = out "\\t"
            else if ((c in ord) && ord[c] < 32) out = out sprintf("\\u%04x", ord[c])
            else out = out c
        }
        if (NR > 1) printf "\\n"
        printf "%s", out
    }'
}

json_string() {
    # Emit a JSON string literal including surrounding quotes.
    #
    # Быстрый путь без форка. json_escape — это запуск awk, а json_string зовут
    # в цикле по каждой строке списка: на 173 доменах whitelist это 173 процесса
    # и почти секунда на роутере. При этом экранировать в подавляющем
    # большинстве значений нечего — это хостнеймы.
    #
    # Условие проверяет РОВНО тот набор, который умеет менять json_escape:
    # обратный слэш, кавычка и любой управляющий символ (сюда же попадают \n,
    # \r и \t). Всё остальное awk вернул бы байт в байт, включая кириллицу и
    # прочие байты >127 — они не управляющие, и класс [[:cntrl:]] их не ловит
    # (проверено на busybox ash роутера). Если условие сработало — идём прежним
    # путём, поведение не меняется ни на символ.
    case "$1" in
        *\\*|*\"*|*[[:cntrl:]]*)
            printf '"'
            printf '%s' "$1" | json_escape
            printf '"'
            ;;
        *) printf '"%s"' "$1" ;;
    esac
}

# shellcheck disable=SC2120  # optional arg: most callers pass none, some pass a JSON tail
json_ok() {
    json_header
    printf '{"ok":true'
    if [ $# -gt 0 ]; then
        printf ',%s' "$1"
    fi
    printf '}\n'
    exit 0
}

json_fail() {
    # usage: json_fail <http-status-line> <msg>
    local status="$1" msg="$2"
    printf 'Status: %s\r\n' "$status"
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '{"ok":false,"error":'
    json_string "$msg"
    printf '}\n'
    exit 0
}

require_method() {
    if [ "${REQUEST_METHOD:-GET}" != "$1" ]; then
        json_fail "405 Method Not Allowed" "method not allowed"
    fi
}

# ПОТОЛОК РАЗМЕРА ТЕЛА. `dd bs=1` — это один системный вызов на байт, то есть
# секунды процессорного времени на роутере за килобайт. Пока каждый POST
# требовал признака страницы, худшее, что мог сделать чужой, — потратить своё
# же время. С появлением входа по паролю два маршрута (/auth/challenge и
# /auth/login) стали доступны БЕЗ сессии: сосед по сети мог послать туда тело
# в мегабайты и занять роутер на минуты одним запросом.
#
# 8 КБ хватает с запасом: самое большое тело здесь — строка своей стратегии.
# Загрузка списков идёт другим путём (read_body_raw, там head -c блоками).
# Общий потолок в lighttpd тоже стоит (server.max-request-size), но он в
# мегабайтах и защищает память, а не процессор.
Z2K_MAX_BODY="${Z2K_MAX_BODY:-8192}"

# ВНИМАНИЕ: отсюда НЕЛЬЗЯ отвечать ошибкой. read_body почти всегда вызывают
# как `body=$(read_body)`, а json_fail внутри подстановки завершает только
# подоболочку: заголовки уехали бы в переменную, а запрос продолжил бы
# выполняться. Поэтому размер проверяется ОДИН раз в основном потоке, до
# разбора маршрута (см. проверку сразу после panel_auth_gate).
read_body() {
    local len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 0 ] 2>/dev/null || { echo ""; return 0; }
    [ "$len" -gt "$Z2K_MAX_BODY" ] && { echo ""; return 0; }
    dd bs=1 count="$len" 2>/dev/null
}

# Like read_body but for BIG raw bodies (list uploads, hundreds of KB):
# `dd bs=1` is one syscall per byte — seconds on a MIPS router — while
# `head -c` reads in blocks. Both busybox and coreutils head support -c.
read_body_raw() {
    local len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 0 ] 2>/dev/null || { echo ""; return 0; }
    head -c "$len" 2>/dev/null
}

# Decode x-www-form-urlencoded body or query string into a specific key.
# Returns the decoded value on stdout. Minimal decoder — only handles %XX.
form_value() {
    local haystack="$1" key="$2"
    local pair raw=""
    local OLD_IFS="$IFS"
    # Разбиение на пары — это word splitting по &, а вместе с ним работает и
    # pathname expansion: без set -f значение с *, ? или [ раскрылось бы по
    # содержимому рабочего каталога CGI. Снимаем сразу за циклом — дальше по
    # файлу подстановки должны вести себя как обычно.
    IFS='&'
    set -f
    for pair in $haystack; do
        case "$pair" in
            "$key="*) raw="${pair#$key=}"; break ;;
        esac
    done
    set +f
    IFS="$OLD_IFS"
    [ -n "$raw" ] || { echo ""; return 0; }
    # Convert + to space then decode %XX. NB: portable hex decode via
    # an index() lookup — busybox/mawk on the router has NO strtonum()
    # (a gawk extension). The old strtonum() decoder silently failed on
    # any %XX-bearing value, which surfaced once rotation host keys grew
    # an address-family suffix ("host|6" → URLSearchParams encodes "|"
    # as %7C) and the × delete started returning "key and host required".
    #
    # Разбор идёт слева направо с накоплением в out, а не заменой внутри $0:
    # замена на месте перезапускала match() с начала строки, то есть
    # декодировала уже раскодированное (%2541 -> %41 -> A).
    # LC_ALL=C обязателен: декодер собирает БАЙТЫ через sprintf("%c"), а на
    # multibyte-aware awk (gawk на CI-раннере) %c для значения выше 127 даёт
    # символ текущей локали, а не байт — кириллица из формы приезжала битой.
    # На роутере awk байто-ориентированный, поэтому там расхождения не видно.
    printf '%s' "$raw" | LC_ALL=C awk '
        function hx(c) { return index("0123456789abcdef", tolower(c)) - 1 }
        {
            gsub(/\+/, " ")
            out = ""
            rest = $0
            while (match(rest, /%[0-9a-fA-F][0-9a-fA-F]/)) {
                ch = sprintf("%c", hx(substr(rest, RSTART+1, 1)) * 16 + hx(substr(rest, RSTART+2, 1)))
                out = out substr(rest, 1, RSTART-1) ch
                rest = substr(rest, RSTART+3)
            }
            print out rest
        }'
}

# --- route dispatch ---

auth_require
panel_auth_gate

# Потолок размера тела — в основном потоке, а не внутри read_body: оттуда
# ответить нельзя (см. комментарий у read_body). Два маршрута входа доступны
# БЕЗ сессии, и без этой проверки сосед по локальной сети занимал бы роутер
# мегабайтным телом через `dd bs=1` — сисколл на байт.
#
# Крупные загрузки (списки, своя стратегия) идут через read_body_raw и свои
# собственные потолки в мегабайтах — их это ограничение не касается.
case "$PATH_INFO" in
    /warp/list/save|/warp/devices/save|/whitelist/import|/strategy/pool/save|/strategy/pool/validate) ;;
    *)
        if [ "${CONTENT_LENGTH:-0}" -gt "$Z2K_MAX_BODY" ] 2>/dev/null; then
            json_fail "413 Payload Too Large" "запрос слишком большой"
        fi
        ;;
esac

path="${PATH_INFO:-/}"
method="${REQUEST_METHOD:-GET}"

# lighttpd sets PATH_INFO to the portion after the CGI script path —
# e.g. for request /cgi-bin/api/toggle/rst-filter the PATH_INFO is
# /toggle/rst-filter. No rewriting needed.

case "$method $path" in

    # ---------- STATUS ----------
    "GET /status"|"GET /")
        installed=$(is_installed && echo true || echo false)
        running=$(is_running   && echo true || echo false)
        svc_state=$(service_status_string)
        disable_cd=$(read_flag "DISABLE_CUSTOM" "$CONFIG_FILE" "1")
        # UI wants positive "customd_enabled"
        if [ "$disable_cd" = "0" ]; then customd="1"; else customd="0"; fi
        dynamic_ttl=$(read_flag "Z2K_DYNAMIC_TTL" "$CONFIG_FILE" "1")
        stats=$(read_flag "Z2K_STATS" "$CONFIG_FILE" "1")
        # Признак «человек ещё не видел, что уходит». Панель по нему покажет
        # карточку с полями и адресом, и снимет гейт первой отправки —
        # до этого аплоадер молчит (files/z2k-stats-upload.sh).
        stats_ack=$(read_flag "Z2K_STATS_ACK" "$CONFIG_FILE" "1")
        ppe=$(read_flag "Z2K_PPE_DEOFFLOAD" "$CONFIG_FILE" "1")
        auto_update=$(read_flag "Z2K_AUTO_UPDATE_ENABLED" "$CONFIG_FILE" "1")
        autohostlist=$(read_flag "Z2K_AUTOHOSTLIST" "$CONFIG_FILE" "0")
        tpid=$(tunnel_pid 2>/dev/null)
        tunnel_running=false
        [ -n "$tpid" ] && tunnel_running=true

        game_warp=$(read_flag "GAME_WARP_ENABLED" "$CONFIG_FILE" "0")
        json_header
        # Каждое значение флага — через json_string, а не прямым %s. read_flag
        # снимает только ОКРУЖАЮЩИЕ кавычки, поэтому правленный руками конфиг
        # (Z2K_STATS=0") отдаёт значение, которое рвёт строку JSON. Ломается при
        # этом не один тумблер: фронт не разбирает ответ целиком и весь дашборд
        # уходит в «Ошибка». Быстрый путь json_string на "0"/"1" не форкает.
        printf '{"ok":true,"installed":%s,"running":%s,"service":' \
            "${installed:-false}" "${running:-false}"
        json_string "${svc_state:-unknown}"
        printf ',"toggles":{"game_warp":';   json_string "${game_warp:-0}"
        printf ',"customd":';                json_string "${customd:-0}"
        printf ',"dynamic_ttl":';            json_string "${dynamic_ttl:-1}"
        printf ',"stats":';                  json_string "${stats:-1}"
        printf ',"stats_ack":';              json_string "${stats_ack:-1}"
        printf ',"ppe":';                    json_string "${ppe:-1}"
        printf ',"auto_update":';            json_string "${auto_update:-1}"
        printf ',"autohostlist":';           json_string "${autohostlist:-0}"
        printf '},"tunnel":{"running":%s}}\n' "${tunnel_running:-false}"
        exit 0
        ;;

    # ---------- SERVICE CONTROL (async — returns job_id) ----------
    # Юзер получает {ok:true, job:<id>} мгновенно; UI открывает модалку
    # с live log поллингом /job?id=<id>. Без этого browser висел до
    # завершения restart (5-15s) и не понимал что происходит.
    "POST /service/start")
        require_method POST
        job_id=$(svc_action_async "Запуск сервиса nfqws2" "set_flag ENABLED 1 \"${CONFIG_FILE}\"; svc_start")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;
    "POST /service/stop")
        require_method POST
        job_id=$(svc_action_async "Остановка сервиса nfqws2" "set_flag ENABLED 0 \"${CONFIG_FILE}\"; svc_stop")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;
    "POST /service/restart")
        require_method POST
        job_id=$(svc_action_async "Перезапуск сервиса nfqws2" "set_flag ENABLED 1 \"${CONFIG_FILE}\"; svc_restart")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    # Человек увидел карточку с составом телеметрии. Снимаем гейт первой
    # отправки — синхронно, без задачи: правка одного ключа в конфиге, ждать
    # тут нечего, а показывать модалку прогресса ради этого было бы издевательством.
    "POST /stats/ack")
        set_flag Z2K_STATS_ACK 1 "$CONFIG_FILE" \
            || json_fail "500 Internal Server Error" "не удалось записать признак"
        json_header
        printf '{"ok":true}\n'
        exit 0
        ;;

    # ---------- TOGGLES (async — returns job_id) ----------
    "POST /toggle/game-warp"|\
    "POST /toggle/customd"|\
    "POST /toggle/dynamic-ttl"|\
    "POST /toggle/stats"|\
    "POST /toggle/ppe"|\
    "POST /toggle/auto-update"|\
    "POST /toggle/autohostlist")
        body=$(read_body)
        val=$(form_value "$body" "value")
        [ -z "$val" ] && val=$(form_value "${QUERY_STRING:-}" "value")
        case "$val" in
            0|1) ;;
            *) json_fail "400 Bad Request" "value must be 0 or 1" ;;
        esac
        case "$path" in
            /toggle/game-warp)       _toggle_fn=toggle_game_warp;       _label="WARP-туннель" ;;
            /toggle/customd)         _toggle_fn=toggle_customd;         _label="custom.d" ;;
            /toggle/dynamic-ttl)     _toggle_fn=toggle_dynamic_ttl;     _label="Динамический TTL" ;;
            /toggle/stats)           _toggle_fn=toggle_stats;           _label="Сбор статистики" ;;
            /toggle/ppe)             _toggle_fn=toggle_ppe;             _label="PPE de-offload" ;;
            /toggle/auto-update)     _toggle_fn=toggle_auto_update;     _label="Автообновление" ;;
            /toggle/autohostlist)    _toggle_fn=toggle_autohostlist;    _label="Автохостлист" ;;
        esac
        _verb=$([ "$val" = "1" ] && echo "Включаю" || echo "Отключаю")
        job_id=$(svc_action_async "${_verb} ${_label}" "${_toggle_fn} ${val}")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    # ---------- POLICY ACCESS (Keenetic ip policy filter) ----------
    "GET /policy/status")
        result=$(policy_status)
        name=$(printf '%s' "$result" | sed -n 's/.*name=\([^|]*\).*/\1/p')
        exclude=$(printf '%s' "$result" | sed -n 's/.*exclude=\([^|]*\).*/\1/p')
        exists=$(printf '%s' "$result" | sed -n 's/.*exists=\([0-9]*\).*/\1/p')
        json_header
        printf '{"ok":true,"name":'; json_string "$name"
        printf ',"exclude":';        json_string "${exclude:-0}"
        printf ',"exists":%s}\n' "${exists:-0}"
        exit 0
        ;;

    "POST /policy/save")
        body=$(read_body)
        name=$(form_value "$body" "name")
        exclude=$(form_value "$body" "exclude")
        [ -z "$exclude" ] && exclude="0"
        case "$exclude" in
            0|1) ;;
            *) json_fail "400 Bad Request" "exclude must be 0 or 1" ;;
        esac
        # SECURITY: имя уходит в eval внутри svc_action_async, но НЕ как часть
        # eval-строки — там остаётся литеральный токен $Z2K_POLICY_NAME, а
        # раскрывает его сам eval, то есть уже как ЗНАЧЕНИЕ переменной: результат
        # подстановки заново кодом не разбирается. Именно поэтому чарсет здесь
        # может быть тем же денилистом, что и в policy_save: имена политик
        # Keenetic человек пишет по-русски и с пробелами («Через ВПН»), а прежний
        # [A-Za-z0-9_-] отбивал их ЗДЕСЬ, до обработчика — фикс в policy_save при
        # этом выглядел рабочим. Запрещено ровно то, что ломает `. config`.
        #
        # Апостроф — там же: set_flag пишет значение в одинарных кавычках и
        # экранирует апостроф как '\'', а safe_config_read обратно это не
        # разворачивает, так что имя портится НАВСЕГДА при первой же
        # перегенерации конфига. Вертикальная черта — потому что policy_status
        # отдаёт name=%s|exclude=%s|exists=%s, и на чтении назад имя режется по
        # разделителю: панель показала бы «a» вместо «a|b», а пользователь
        # сохранил бы предзаполненное поле и потерял политику.
        case "$name" in
            *[\"\$\`\\]*|*';'*|*"'"*|*'|'*|*'
'*) json_fail "400 Bad Request" "invalid policy name" ;;
        esac
        # Длина — в СИМВОЛАХ, а не в байтах: ${#name} на ash/dash считает байты,
        # и кириллическое имя из 17 символов уже «длиннее 32», хотя форма в
        # панели ограничивает поле ровно 32 символами (maxlength="32").
        #
        # Считаем без awk и без wc -m, потому что оба зависят от локали и от
        # реализации: CGI стартует вообще без LC_*, в C-локали wc -m считает
        # байты, а построение таблицы продолжений через sprintf("%c", 128..191)
        # в awk даёт разное на разных сборках — на CI-раннере именно это и
        # отвергло имя в 17 символов. Байт продолжения UTF-8 имеет вид 10xxxxxx,
        # то есть символов = байты минус продолжения; tr в C-локали байтовый
        # везде, где мы работаем.
        name_bytes=$(printf '%s' "$name" | wc -c | tr -d ' ')
        name_cont=$(printf '%s' "$name" | LC_ALL=C tr -dc '\200-\277' | wc -c | tr -d ' ')
        name_len=$((name_bytes - name_cont))
        case "$name_len" in
            ''|*[!0-9]*) name_len=${#name} ;;
        esac
        if [ "$name_len" -gt 32 ]; then
            json_fail "400 Bad Request" "policy name too long"
        fi
        # Async job для visibility (есть restart сервиса под капотом).
        Z2K_POLICY_NAME="$name"
        export Z2K_POLICY_NAME
        job_id=$(svc_action_async "Применение политики доступа" "policy_save \"\$Z2K_POLICY_NAME\" ${exclude}")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    # ---------- WHITELIST ----------
    "GET /exclude")
        # entries — только адреса и подсети, то есть то, что здесь реально
        # действует. legacy_domains — домены, осевшие в файле, пока панель их
        # сюда принимала: они не работали никогда, но выкидывать их молча
        # нельзя, человек вписывал их осознанно.
        json_header
        printf '{"ok":true,"entries":['
        first=1
        exclude_list_addresses | while IFS= read -r e; do
            [ -z "$e" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$e"
        done
        printf '],"legacy_domains":['
        first=1
        exclude_list_legacy_domains | while IFS= read -r e; do
            [ -z "$e" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$e"
        done
        printf ']}\n'
        exit 0
        ;;

    "POST /exclude/add"|"POST /exclude/delete")
        body=$(read_body)
        entry=$(form_value "$body" "entry")
        [ -z "$entry" ] && json_fail "400 Bad Request" "entry required"
        # Причина отказа идёт человеку как есть: «это домен — добавьте его во
        # вкладке Домены» объясняет, что делать, а «invalid or add failed» —
        # нет. Захват в $(...) обязателен ещё и потому, что stdout обработчика
        # иначе ушёл бы в блок HTTP-заголовков.
        if [ "$path" = "/exclude/add" ]; then
            ex_err=$(exclude_add "$entry" 2>&1 >/dev/null) \
                || json_fail "400 Bad Request" "${ex_err:-не удалось добавить}"
        else
            ex_err=$(exclude_delete "$entry" 2>&1 >/dev/null) \
                || json_fail "400 Bad Request" "${ex_err:-не удалось удалить}"
        fi
        json_ok
        ;;

    "GET /whitelist")
        json_header
        printf '{"ok":true,"domains":['
        first=1
        whitelist_list | while IFS= read -r d; do
            [ -z "$d" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$d"
        done
        printf ']}\n'
        exit 0
        ;;

    "POST /whitelist/add"|"POST /whitelist/delete")
        body=$(read_body)
        domain=$(form_value "$body" "domain")
        [ -z "$domain" ] && json_fail "400 Bad Request" "domain required"
        # Причину отказа отдаём как есть: «это адрес — добавьте его во вкладке
        # Адреса» говорит человеку, что делать, а «invalid or add failed» — нет.
        if [ "$path" = "/whitelist/add" ]; then
            wl_err=$(whitelist_add "$domain" 2>&1 >/dev/null) \
                || json_fail "400 Bad Request" "${wl_err:-не удалось добавить}"
        else
            wl_err=$(whitelist_delete "$domain" 2>&1 >/dev/null) \
                || json_fail "400 Bad Request" "${wl_err:-не удалось удалить}"
        fi
        json_ok
        ;;

    "POST /whitelist/import")
        # Body — raw multi-line TXT (one domain per line). Frontend sends
        # Content-Type: text/plain. whitelist_import парсит/валидирует/
        # дедуплицирует/append'ит и выводит counts.
        #
        # Потолок и read_body_raw — как у /warp/list/save: это ровно тот
        # эндпоинт, куда пользователь грузит файл целиком, а read_body (dd bs=1)
        # тратит сисколл на байт и держит слот CGI секундами, попутно занося всё
        # тело в переменную шелла. 2 МБ — тот же предел, что и у списков WARP.
        if [ "${CONTENT_LENGTH:-0}" -gt 2097152 ] 2>/dev/null; then
            json_fail "413 Payload Too Large" "list too large (max 2 MB)"
        fi
        result=$(read_body_raw | whitelist_import) || json_fail "500 Internal Server Error" "import failed"
        added=$(printf '%s' "$result" | sed -n 's/.*added=\([0-9]*\).*/\1/p')
        dup=$(printf '%s' "$result" | sed -n 's/.*skipped_dup=\([0-9]*\).*/\1/p')
        inv=$(printf '%s' "$result" | sed -n 's/.*skipped_invalid=\([0-9]*\).*/\1/p')
        json_header
        printf '{"ok":true,"added":%d,"skipped_duplicate":%d,"skipped_invalid":%d}\n' "${added:-0}" "${dup:-0}" "${inv:-0}"
        exit 0
        ;;

    # ---------- EXTRA DOMAINS (live hostlist для autocircular) ----------
    "GET /extra-domains")
        json_header
        printf '{"ok":true,"domains":['
        first=1
        extra_domains_list | while IFS= read -r d; do
            [ -z "$d" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$d"
        done
        printf ']}\n'
        exit 0
        ;;

    "GET /autohostlist-domains")
        json_header
        printf '{"ok":true,"domains":['
        first=1
        autohostlist_domains_list | while IFS= read -r d; do
            [ -z "$d" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$d"
        done
        printf ']}\n'
        exit 0
        ;;

    "POST /autohostlist-domains/delete")
        body=$(read_body)
        domain=$(form_value "$body" "domain")
        [ -z "$domain" ] && json_fail "400 Bad Request" "domain required"
        autohostlist_domains_delete "$domain" || json_fail "400 Bad Request" "invalid or delete failed"
        json_ok
        ;;

    "POST /extra-domains/add"|"POST /extra-domains/delete")
        body=$(read_body)
        domain=$(form_value "$body" "domain")
        [ -z "$domain" ] && json_fail "400 Bad Request" "domain required"
        if [ "$path" = "/extra-domains/add" ]; then
            # Причину отказа показываем как есть: бэкенд объясняет, в каком
            # именно списке домен уже лежит, а generic «invalid or add failed»
            # это объяснение съедал — человек видел отказ без причины.
            _add_err=$(extra_domains_add "$domain" 2>&1 >/dev/null) || \
                json_fail "400 Bad Request" "${_add_err:-invalid or add failed}"
        else
            extra_domains_delete "$domain" || json_fail "400 Bad Request" "invalid or delete failed"
        fi
        json_ok
        ;;

    # ---------- WARP (webpanel «WARP» section) ----------
    "GET /warp/status")
        result=$(warp_status_info)
        _wf() { printf '%s' "$result" | sed -n "s/.*$1=\([^ ]*\).*/\1/p" | head -1; }
        w_enabled=$(printf '%s' "$result" | sed -n 's/.*enabled=\(.*\)$/\1/p')
        w_inst_j=false;  [ "$(_wf installed)" = "1" ] && w_inst_j=true
        w_ready_j=false; [ "$(_wf ready)" = "1" ] && w_ready_j=true
        json_header
        printf '{"ok":true,"enabled":'; json_string "${w_enabled:-0}"
        printf ',"installed":%s,"ready":%s,"transport":' "$w_inst_j" "$w_ready_j"; json_string "$(_wf transport)"
        printf ',"endpoint":'; json_string "$(_wf endpoint)"
        printf ',"iface":';    json_string "$(_wf iface)"
        printf ',"addr":';     json_string "$(_wf addr)"
        printf ',"entries":%s,"devices":%s,"error":' "$(_wf entries | grep -E '^[0-9]+$' || echo 0)" "$(_wf devices | grep -E '^[0-9]+$' || echo 0)"
        json_string "$(_wf error)"
        printf '}\n'
        exit 0
        ;;

    # Установка/удаление движка — долгие (скачивание ~7 МБ, регистрация у
    # Cloudflare через десинк или релей), поэтому job, как у тумблеров.
    "POST /warp/install")
        job_id=$(svc_action_async "Установка WARP" "warp_install_action")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;
    "GET /dns/check")
        json_header
        _last=$(dns_check_last)
        if [ -n "$_last" ]; then
            printf '{"ok":true,"result":%s,"own":' "$_last"; json_string "$(dns_check_own_read)"; printf '}\n'
        else
            printf '{"ok":true,"result":null,"own":'; json_string "$(dns_check_own_read)"; printf '}\n'
        fi
        exit 0
        ;;

    "POST /dns/check")
        job_id=$(svc_action_async "Проверка DNS" "dns_check_run")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    "POST /dns/own")
        body=$(read_body)
        _res=$(printf '%s' "$body" | dns_check_own_save) || json_fail "500 Internal Server Error" "save failed"
        json_header
        printf '{"ok":true,"saved":'; json_string "$_res"; printf '}\n'
        exit 0
        ;;

    "POST /warp/reregister")
        job_id=$(svc_action_async "Перерегистрация устройства WARP" "warp_reregister")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    "POST /warp/remove")
        job_id=$(svc_action_async "Удаление WARP" "warp_remove_action")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    # Устройства в сети роутера с отметкой, кто уже в WARP.
    "GET /warp/neighbors")
        json_header
        printf '{"ok":true,"devices":['
        _first=1
        # \037, не таб: таб — IFS-пробельный, и пустые поля офлайн-устройств
        # (нет адреса, нет сегмента) схлопывались бы вместе с разделителями.
        warp_neighbors | while IFS="$(printf '\037')" read -r n_mac n_ip n_label n_net n_active n_on; do
            [ "$_first" = 1 ] || printf ','
            _first=0
            printf '{"mac":'; json_string "$n_mac"
            printf ',"ip":';  json_string "$n_ip"
            printf ',"label":'; json_string "$n_label"
            printf ',"net":'; json_string "$n_net"
            printf ',"active":%s,"on":%s}' "$([ "$n_active" = 1 ] && echo true || echo false)" "$([ "$n_on" = 1 ] && echo true || echo false)"
        done
        printf ']}\n'
        exit 0
        ;;
    "POST /warp/devices/toggle")
        body=$(read_body)
        n_mac=$(form_value "$body" "mac")
        n_val=$(form_value "$body" "value")
        case "$n_val" in 0|1) ;; *) json_fail "400 Bad Request" "value must be 0 or 1" ;; esac
        warp_device_toggle "$n_mac" "$n_val" || json_fail "400 Bad Request" "bad mac or save failed"
        json_ok
        ;;

    # Устройства «всё в WARP»: text/plain, как /warp/list.
    "GET /warp/devices")
        printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
        warp_devices_read
        exit 0
        ;;
    "POST /warp/devices/save")
        if [ "${CONTENT_LENGTH:-0}" -gt 2097152 ] 2>/dev/null; then
            json_fail "413 Payload Too Large" "list too large (max 2 MB)"
        fi
        result=$(read_body_raw | warp_devices_save) || json_fail "400 Bad Request" "save failed"
        w_n=$(printf '%s' "$result" | sed -n 's/.*entries=\([0-9]*\).*/\1/p')
        w_d=$(printf '%s' "$result" | sed -n 's/.*dropped=\([0-9]*\).*/\1/p')
        json_header
        printf '{"ok":true,"entries":%d,"dropped":%d}\n' "${w_n:-0}" "${w_d:-0}"
        exit 0
        ;;

    # Upstream per-game lists: name, entry count, and whether they are switched
    # on. Read-only by design — editing them is meaningless, the next refresh
    # overwrites the file.
    # Подбор стратегии под домен замером. Отдаётся JSON самого замера как есть —
    # разбирает его страница. Здесь ничего не интерпретируем намеренно: набор
    # полей у замера свой и меняется вместе с инструментом, а лишний слой
    # перевода только разъезжался бы с ним.
    "GET /strategy/pick")
        json_header
        _pick=$(strategy_pick_last)
        if [ -n "$_pick" ]; then
            printf '{"ok":true,"result":%s}\n' "$_pick"
        else
            printf '{"ok":true,"result":null}\n'
        fi
        exit 0
        ;;

    # Запуск замера. Минута работы, поэтому задачей — синхронный CGI на это
    # время занял бы воркер lighttpd (ср. /diag/probe: та проба идёт секунды и
    # потому синхронная).
    "POST /strategy/pick")
        body=$(read_body)
        domain=$(form_value "$body" "domain")
        [ -n "$domain" ] || json_fail "400 Bad Request" "укажите домен"
        case "$domain" in
            *[!a-zA-Z0-9.-]*) json_fail "400 Bad Request" "в имени домена есть недопустимые символы" ;;
        esac
        [ "${#domain}" -le 253 ] || json_fail "400 Bad Request" "слишком длинное имя домена"
        job_id=$(svc_action_async "Подбор стратегии для $domain" "strategy_pick_run $domain")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    # Per-pool strategies: which pools have a user line, and what it is.
    "GET /strategy/pools")
        json_header
        printf '{"ok":true,"pools":['
        first=1
        for _sp in $STRATEGY_POOLS; do
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            _sp_custom=0
            [ -s "$CUSTOM_STRAT_DIR/$_sp.txt" ] && _sp_custom=1
            printf '{"pool":'; json_string "$_sp"
            printf ',"custom":%s}' "$_sp_custom"
        done
        printf ']}\n'
        exit 0
        ;;

    # Raw text of one pool's line (text/plain, like /warp/list — no JSON
    # round-trip of a long option string).
    "GET /strategy/pool")
        s_name=$(form_value "${QUERY_STRING:-}" "pool")
        s_body=$(strategy_pool_read "$s_name") || {
            [ "$?" = 2 ] && { printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'; exit 0; }
            json_fail "400 Bad Request" "invalid pool"; }
        printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n%s' "$s_body"
        exit 0
        ;;

    # Dry-run only: tells the user whether the line parses WITHOUT applying it.
    # Deliberately separate from save, so a mistake is found before it can take
    # the daemon down rather than after.
    "POST /strategy/pool/validate")
        s_name=$(form_value "${QUERY_STRING:-}" "pool")
        # СВОЙ ПОТОЛОК — тот, что обещан комментарием у общего гейта.
        #
        # Оба маршрута /strategy/pool/* исключены из общего ограничения в 8 КБ с
        # пояснением «крупные загрузки идут через read_body_raw и свои
        # собственные потолки». У /whitelist/import и /warp/list/save такой
        # потолок действительно есть (2 МБ), а здесь его не было вовсе: тело
        # уходило в head -c "$CONTENT_LENGTH" без верхней границы, то есть один
        # запрос мог занять слот CGI и память роутера на сколько угодно.
        # Стратегия — это несколько килобайт текста; 256 КБ с большим запасом.
        if [ "${CONTENT_LENGTH:-0}" -gt 262144 ] 2>/dev/null; then
            json_fail "413 Payload Too Large" "стратегия слишком большая (максимум 256 КБ)"
        fi
        # Тело читаем В ПЕРЕМЕННУЮ: оно нужно дважды — достроить каркасом и
        # проверить. Через конвейер stdin кончается на первом же чтении.
        s_body=$(read_body_raw)
        s_full=$(printf '%s\n' "$s_body" | strategy_complete_line "$s_name")
        s_err=$(printf '%s\n' "$s_full" | strategy_validate "$s_name" 2>&1) && {
            json_header
            # Отдаём собранную строку: человек вставил один приём, а применится
            # полный набор — он обязан это увидеть, а не догадываться.
            printf '{"ok":true,"valid":true,"line":'; json_string "$s_full"
            printf '}\n'; exit 0; }
        json_header
        printf '{"ok":true,"valid":false,"error":'; json_string "$s_err"
        printf '}\n'
        exit 0
        ;;

    "POST /strategy/pool/save")
        s_name=$(form_value "${QUERY_STRING:-}" "pool")
        # Тот же потолок, что и у /strategy/pool/validate выше — см. пояснение там.
        if [ "${CONTENT_LENGTH:-0}" -gt 262144 ] 2>/dev/null; then
            json_fail "413 Payload Too Large" "стратегия слишком большая (максимум 256 КБ)"
        fi
        s_err=$(read_body_raw | strategy_pool_save "$s_name" 2>&1) || \
            json_fail "400 Bad Request" "$s_err"
        json_header
        printf '{"ok":true,"pool":'; json_string "$s_name"
        printf '}\n'
        exit 0
        ;;

    "POST /strategy/pool/reset")
        s_name=$(form_value "$(read_body)" "pool")
        [ -z "$s_name" ] && s_name=$(form_value "${QUERY_STRING:-}" "pool")
        # Захват ОБЯЗАТЕЛЕН: strategy_pool_reset зовёт restart_service_if_running,
        # а та печатает в stdout — либо весь вывод init-скрипта, либо «сервис не
        # запущен». Контракт функции менять нельзя, на её stdout рассчитывает
        # svc_action_async (job-лог). Здесь же stdout — это тело HTTP-ответа, и
        # эти строки уезжали ПЕРЕД заголовками: lighttpd разбирает первые байты
        # как заголовок, двоеточия в них нет — 500 либо мусор до JSON.
        s_err=$(strategy_pool_reset "$s_name" 2>&1) || \
            json_fail "400 Bad Request" "${s_err:-reset failed}"
        json_header
        printf '{"ok":true,"pool":'; json_string "$s_name"
        printf '}\n'
        exit 0
        ;;

    "GET /warp/games")
        json_header
        printf '{"ok":true,"games":['
        first=1
        warp_games | while IFS="$(printf '\t')" read -r gname gentries gon; do
            [ -z "$gname" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            printf '{"name":'; json_string "$gname"
            printf ',"entries":%s,"enabled":%s}' "${gentries:-0}" "${gon:-0}"
        done
        printf ']}\n'
        exit 0
        ;;

    "POST /warp/games/toggle")
        body=$(read_body)
        g_name=$(form_value "$body" "name")
        [ -z "$g_name" ] && g_name=$(form_value "${QUERY_STRING:-}" "name")
        g_val=$(form_value "$body" "value")
        [ -z "$g_val" ] && g_val=$(form_value "${QUERY_STRING:-}" "value")
        case "$g_val" in
            0|1) ;;
            *) json_fail "400 Bad Request" "value must be 0 or 1" ;;
        esac
        warp_game_toggle "$g_name" "$g_val" || json_fail "400 Bad Request" "toggle failed"
        # Same live-apply path the list editor uses: the set is rebuilt on the
        # spot, so a switch takes effect without a restart.
        warp_ipset_reload_if_enabled
        json_header
        printf '{"ok":true,"name":'; json_string "$g_name"
        printf ',"enabled":%s}\n' "$g_val"
        exit 0
        ;;

    "GET /warp/lists")
        json_header
        printf '{"ok":true,"lists":['
        first=1
        warp_lists | while IFS="$(printf '\t')" read -r wname wentries wsize wmtime; do
            [ -z "$wname" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            printf '{"name":'; json_string "$wname"
            printf ',"entries":%s,"size":%s,"mtime":%s}' \
                "${wentries:-0}" "${wsize:-0}" "${wmtime:-0}"
        done
        printf ']}\n'
        exit 0
        ;;

    # Raw list content (text/plain, NOT JSON) — feeds both the editor
    # textarea and the «скачать .txt» export, so no JSON-escape roundtrip
    # of a 300 KB body on a MIPS CPU.
    "GET /warp/list")
        w_name=$(form_value "${QUERY_STRING:-}" "name")
        [ -z "$w_name" ] && json_fail "400 Bad Request" "name required"
        w_file=$(warp_list_read_path "$w_name")
        case $? in
            0) ;;
            2) json_fail "404 Not Found" "no such list" ;;
            *) json_fail "400 Bad Request" "invalid list name" ;;
        esac
        printf 'Status: 200 OK\r\n'
        printf 'Content-Type: text/plain; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n\r\n'
        cat "$w_file"
        exit 0
        ;;

    # Body — raw list text (textarea save / .txt import), как /whitelist/import.
    # name & mode идут в QUERY_STRING чтобы не кодировать сотни КБ в urlencoded.
    "POST /warp/list/save")
        w_name=$(form_value "${QUERY_STRING:-}" "name")
        w_mode=$(form_value "${QUERY_STRING:-}" "mode")
        [ -z "$w_mode" ] && w_mode="replace"
        [ -z "$w_name" ] && json_fail "400 Bad Request" "name required"
        # Mirror warp_name_ok: the handler validates too, but fail fast with a
        # clear 400 before touching the body.
        case "$w_name" in
            .*|-*|*[!A-Za-z0-9._-]*) json_fail "400 Bad Request" "invalid list name" ;;
        esac
        case "$w_mode" in
            replace|append|create) ;;
            *) json_fail "400 Bad Request" "mode must be replace, append or create" ;;
        esac
        # lighttpd's own limit is higher; keep a sane cap so a runaway upload
        # can't fill /opt. 2 MB ≈ 6× the shipped 18k-entry game list.
        if [ "${CONTENT_LENGTH:-0}" -gt 2097152 ] 2>/dev/null; then
            json_fail "413 Payload Too Large" "list too large (max 2 MB)"
        fi
        result=$(read_body_raw | warp_list_save "$w_name" "$w_mode") || \
            json_fail "400 Bad Request" "save failed"
        w_saved=$(printf '%s' "$result" | sed -n 's/.*saved=\([0-9]*\).*/\1/p')
        w_inv=$(printf '%s' "$result" | sed -n 's/.*skipped_invalid=\([0-9]*\).*/\1/p')
        json_header
        printf '{"ok":true,"saved":%d,"skipped_invalid":%d}\n' "${w_saved:-0}" "${w_inv:-0}"
        exit 0
        ;;

    "POST /warp/list/delete")
        body=$(read_body)
        w_name=$(form_value "$body" "name")
        [ -z "$w_name" ] && json_fail "400 Bad Request" "name required"
        warp_list_delete "$w_name" || json_fail "400 Bad Request" "invalid or delete failed"
        json_ok
        ;;

    # ---------- TUNNEL (async — returns job_id) ----------
    "POST /tunnel/enable")
        job_id=$(svc_action_async "Запуск Telegram туннеля" "tunnel_enable")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;
    "POST /tunnel/disable")
        job_id=$(svc_action_async "Остановка Telegram туннеля" "tunnel_disable")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    "GET /job")
        id=$(form_value "${QUERY_STRING:-}" "id")
        [ -z "$id" ] && json_fail "400 Bad Request" "id required"
        # Sanitize id: must be digits only
        case "$id" in
            *[!0-9]*) json_fail "400 Bad Request" "bad id" ;;
        esac
        st=$(job_status "$id")
        log_content=$(job_log "$id")
        exit_code=$(job_exit_code "$id")
        # unknown — состояние ТЕРМИНАЛЬНОЕ, а не «ещё идёт»: файлов задачи нет
        # (job_reap подчистил либо роутер перезагрузился), и появиться они уже
        # не могут. С done:false поллер панели считает такой ответ успешным,
        # сбрасывает счётчик ошибок и крутится вечно, не отпуская глобальный
        # UI-lock.
        done_flag=false
        case "$st" in
            done|unknown) done_flag=true ;;
        esac
        # exit печатается ЧИСЛОМ, без кавычек: файл лежит в /tmp и переживает
        # обрывы записи, а нечисло сделало бы невалидным весь ответ.
        case "$exit_code" in
            ''|*[!0-9]*) exit_code="null" ;;
        esac
        json_header
        printf '{"ok":true,"status":'; json_string "$st"
        printf ',"done":%s,"exit":%s,"log":' "$done_flag" "$exit_code"
        json_string "$log_content"
        printf '}\n'
        exit 0
        ;;

    # ---------- DIAG (Phase 3) ----------
    "GET /diag")
        diag_content=$(diag_run); diag_rc=$?
        json_header
        # ok отражает КОД ВОЗВРАТА, а не факт того, что что-то напечаталось.
        # Раньше здесь стояло безусловное true, и оборванный отчёт приходил в
        # панель неотличимым от целого.
        if [ "$diag_rc" = "0" ]; then
            printf '{"ok":true,"diag":'
        else
            printf '{"ok":false,"rc":%s,"diag":' "$diag_rc"
        fi
        json_string "$diag_content"
        printf '}\n'
        exit 0
        ;;

    # Отдаём отчёт файлом, а не в сообщении. Полная сводка с логами в лимит
    # телеграма (~4000 символов) не влезает, и резать её ради этого — терять
    # ровно то, ради чего её и читают. Файл прикладывают вложением.
    #
    # Content-Type text/plain, а не application/octet-stream: так вложение
    # можно открыть просмотром прямо в клиенте, не скачивая.
    "GET /diag/download")
        diag_content=$(diag_run report); diag_rc=$?
        # Обрыв виден В САМОМ ФАЙЛЕ, а не только в статусе. Отдавать 500 нельзя:
        # браузер тогда не сохранит вложение, и человек останется вообще без
        # данных, хотя частичный отчёт для разбора всё-таки полезен. Поэтому
        # файл отдаём, но обрыв в нём написан прямым текстом — иначе обрезок
        # выглядит как полная картина.
        if [ "$diag_rc" != "0" ] || ! diag_is_complete "$diag_content"; then
            diag_content="${diag_content}

=== ОТЧЁТ ОБОРВАН (код возврата ${diag_rc}) ===
Файл неполный: сбор прервался. Данные выше верны, но ниже них могло быть
что-то ещё. Пришлите файл как есть и скажите, что он оборван."
        fi
        printf 'Status: 200 OK\r\n'
        printf 'Content-Type: text/plain; charset=utf-8\r\n'
        printf 'Content-Disposition: attachment; filename="z2k-diag-%s.txt"\r\n' \
            "$(date '+%Y%m%d-%H%M' 2>/dev/null || echo report)"
        printf 'Cache-Control: no-store\r\n\r\n'
        printf '%s\n' "$diag_content"
        exit 0
        ;;

    # ---------- ROTATOR STATE (Phase 3) ----------
    "GET /state")
        # Одна awk-программа на весь ответ вместо цикла с json_string.
        #
        # Было: shell читает state.tsv построчно и на КАЖДОЕ поле зовёт
        # json_string -> json_escape, а тот запускает отдельный awk. На 131
        # строке это 524 запуска процесса, и вкладка открывалась 2.98 с при
        # 0.11 с у соседних эндпоинтов. Замерено на роутере владельца.
        #
        # Экранирование повторяет json_escape ОДИН В ОДИН, включая \u00XX для
        # управляющих символов: ослаблять его нельзя, даже если в state.tsv
        # лежат одни хостнеймы — файл переживает ручные правки и сбои записи.
        json_header
        printf '{"ok":true,"entries":['
        state_read | awk -F'\t' '
            BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
            function esc(s,   i, c, out) {
                out = ""
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if      (c == "\\") out = out "\\\\"
                    else if (c == "\"")  out = out "\\\""
                    else if (c == "\n")  out = out "\\n"
                    else if (c == "\r")  out = out "\\r"
                    else if (c == "\t")  out = out "\\t"
                    else if ((c in ord) && ord[c] < 32) out = out sprintf("\\u%04x", ord[c])
                    else                  out = out c
                }
                return out
            }
            $1 != "" {
                if (n++) printf ","
                # ts — единственное поле, которое уходит ЧИСЛОМ, мимо esc().
                # Оборванная запись оставляет там что угодно, и это делает
                # невалидным ВЕСЬ ответ, а не одну строку: таблица стейта
                # пустеет целиком. Значение вида ,"x":1 дописало бы структуру.
                #
                # +0 обязательно: одной проверки на цифры мало, JSON запрещает
                # ведущий ноль, и «0123456789» из битой записи снова уронил бы
                # разбор всего ответа. Так же это делает state_read в actions.sh.
                ts = ($4 ~ /^[0-9]+$/) ? $4 + 0 : 0
                # Шестое поле — подобранное имя из белого списка (обход блокировки
                # по объёму). Пустое у подавляющего большинства строк: имя есть
                # только там, где подбор реально сработал. Старые файлы без этой
                # колонки дают пустую строку, и фронт просто ничего не рисует.
                printf "{\"key\":\"%s\",\"host\":\"%s\",\"strategy\":\"%s\",\"ts\":%s,\"mode\":\"%s\",\"sni\":\"%s\"}", \
                    esc($1), esc($2), esc($3 == "" ? "0" : $3), ts, esc($5 == "" ? "auto" : $5), esc($6)
            }'
        printf ']}\n'
        exit 0
        ;;

    # Pool sizes (distinct strategies per category key) from the live nfqws2
    # cmdline — drives the per-row strategy dropdown and the Discord-voice panel.
    "GET /pools")
        json_header
        printf '{"ok":true,"pools":{'
        first=1
        pools_read | while IFS="$(printf '\t')" read -r pkey pcount; do
            [ -z "$pkey" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$pkey"; printf ':%s' "${pcount:-0}"
        done
        printf '}}\n'
        exit 0
        ;;

    "POST /state/delete")
        body=$(read_body)
        s_key=$(form_value "$body" "key")
        s_host=$(form_value "$body" "host")
        [ -z "$s_key" ] || [ -z "$s_host" ] && json_fail "400 Bad Request" "key and host required"
        state_delete "$s_key" "$s_host" || json_fail "400 Bad Request" "delete failed"
        json_ok
        ;;

    # Wipe ALL rotator rows. Every host's live rotation resets to strategy 1
    # within ~2s (reconcile); freezes cleared; no service restart.
    "POST /state/clear")
        state_clear_all || json_fail "500 Internal Server Error" "clear failed"
        json_ok
        ;;

    # Pin / manually select a rotator row's strategy. mode=auto adopts it live and
    # keeps rotating; mode=frozen adopts it AND stops the rotator from changing it.
    "POST /state/set")
        body=$(read_body)
        s_key=$(form_value "$body" "key")
        s_host=$(form_value "$body" "host")
        s_strategy=$(form_value "$body" "strategy")
        s_mode=$(form_value "$body" "mode")
        [ -z "$s_mode" ] && s_mode="auto"
        { [ -z "$s_key" ] || [ -z "$s_host" ] || [ -z "$s_strategy" ]; } && \
            json_fail "400 Bad Request" "key, host, strategy required"
        state_set "$s_key" "$s_host" "$s_strategy" "$s_mode" || \
            json_fail "400 Bad Request" "set failed"
        json_ok
        ;;

    # ---------- ACTIVE PROBE — removed in r-15 (Phase 1 cleanup) ----------
    # /probe/run replaced by the server_active_reject taxonomy and Phase 3
    # reactive z2k-detect daemon. Endpoint kept as 410 Gone so any cached
    # browser UI doesn't 404 silently.
    "POST /probe/run")
        json_fail "410 Gone" "active probe removed in r-15"
        ;;

    # ---------- ВХОД ПО ПАРОЛЮ ОТ РОУТЕРА ----------
    "GET /auth/state")
        json_header
        printf '{"ok":true,"required":%s,"signed_in":%s}\n' \
            "$(panel_auth_enabled && echo true || echo false)" \
            "$(panel_session_valid && echo true || echo false)"
        exit 0
        ;;

    # ВЫЗОВ ДЛЯ БРАУЗЕРА. Пароль считает страница, сюда он не приходит.
    #
    # Первая версия принимала пароль в теле запроса и считала ответ здесь — и
    # это перечёркивало весь смысл схемы: пароль администратора роутера ехал
    # по локальной сети открытым текстом, потому что панель работает по HTTP.
    # Схема x-ndw2-interactive существует ровно для того, чтобы пароль в сеть
    # не попадал; теперь так и есть.
    #
    # Куку сессии роутера, привязанную к вызову, держим у себя: она нужна на
    # втором шаге, а браузеру знать про неё незачем.
    "POST /auth/challenge")
        panel_auth_enabled || json_ok
        chal_jar="/tmp/z2k-ndm-jar.$$"
        chal=$(panel_ndm_challenge "$chal_jar") || {
            rm -f "$chal_jar" 2>/dev/null
            json_fail "503 Service Unavailable" \
              "веб-интерфейс роутера не отвечает — пароль сейчас не проверить. Пароль можно снять в меню роутера: пункт [P], переключатель входа"
        }
        chal_realm=${chal%%	*}
        chal_rest=${chal#*	}
        chal_value=${chal_rest%%	*}
        chal_host=${chal_rest#*	}
        # Билет связывает вызов, куку роутера и адрес: без него второй шаг
        # пришлось бы принимать на веру от браузера.
        chal_id=$(panel_challenge_store "$chal_value" "$chal_host" "$chal_jar") \
            || json_fail "500 Internal Server Error" "не удалось начать вход"
        json_header
        printf '{"ok":true,"realm":'; json_string "$chal_realm"
        printf ',"challenge":'; json_string "$chal_value"
        printf ',"ticket":'; json_string "$chal_id"
        printf '}\n'
        exit 0
        ;;

    "POST /auth/login")
        panel_auth_enabled || json_ok
        body=$(read_body)
        login=$(form_value "$body" "login")
        ticket=$(form_value "$body" "ticket")
        response=$(form_value "$body" "response")
        panel_challenge_use "$ticket" || json_fail "400 Bad Request" "вход просрочен — попробуйте ещё раз"
        panel_verify_ndm_response "$login" "$response" "$PANEL_CHAL_HOST" "$PANEL_CHAL_JAR"
        vrc=$?
        panel_challenge_clear
        case "$vrc" in
            0) ;;
            2)
                # Роутер не ответил — это НЕ «пароль неверный». Пускать всех
                # нельзя (иначе достаточно уронить роутеру порт 80), поэтому
                # отказываем и сразу говорим, где выход, чтобы человек не
                # оказался запертым.
                json_fail "503 Service Unavailable" \
                  "веб-интерфейс роутера не отвечает — пароль сейчас не проверить. Пароль можно снять в меню роутера: пункт [P], переключатель входа" ;;
            *)
                json_fail "401 Unauthorized" "неверный логин или пароль" ;;
        esac
        sid=$(panel_session_create "$login") || json_fail "500 Internal Server Error" "не удалось открыть сессию"
        printf 'Status: 200 OK\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        # HttpOnly — чтобы скрипт на странице не мог её прочитать; SameSite=Strict
        # — чтобы кука не уезжала с чужого сайта. Secure не ставим: панель по HTTP,
        # с ним кука просто не сохранилась бы.
        printf 'Set-Cookie: z2kpsid=%s; Path=/; Max-Age=%s; HttpOnly; SameSite=Strict\r\n' \
            "$sid" "$Z2K_PANEL_SESS_TTL"
        printf '\r\n{"ok":true}\n'
        exit 0
        ;;

    "POST /auth/logout")
        panel_session_drop
        printf 'Status: 200 OK\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf 'Set-Cookie: z2kpsid=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict\r\n'
        printf '\r\n{"ok":true}\n'
        exit 0
        ;;

    # ---------- ПРОВЕРКА ДОМЕНА (аналог пункта [Y] в меню) ----------
    #
    # Не путать с /probe/run выше: тот был АВТОМАТИЧЕСКОЙ пробой ротатора и
    # убран в r-15. Здесь человек сам вводит домен и сам жмёт кнопку, а проба
    # стателесс — ничего не пишет ни в состояние, ни в списки.
    "POST /diag/probe")
        body=$(read_body)
        domain=$(form_value "$body" "domain")
        [ -n "$domain" ] || json_fail "400 Bad Request" "укажите домен"
        probe_out=$(detect_probe_domain "$domain" 2>&1)
        case "$?" in
            0) ;;
            2) json_fail "400 Bad Request" "в имени домена есть недопустимые символы" ;;
            3) json_fail "503 Service Unavailable" "модуль проверки не установлен — переустановите z2k" ;;
            4) json_fail "504 Gateway Timeout" "проверка не уложилась в 20 секунд" ;;
            *) json_fail "500 Internal Server Error" "проверка не выполнилась" ;;
        esac
        json_header
        printf '{"ok":true,"report":'
        json_string "$probe_out"
        printf '}\n'
        exit 0
        ;;

    # ---------- DEBUG FLAG (Phase 3) ----------
    "GET /debug")
        json_header
        printf '{"ok":true,"enabled":'
        json_string "$(debug_flag_state)"
        printf '}\n'
        exit 0
        ;;

    "POST /debug")
        body=$(read_body)
        val=$(form_value "$body" "value")
        [ -z "$val" ] && val=$(form_value "${QUERY_STRING:-}" "value")
        case "$val" in
            0|1) ;;
            *) json_fail "400 Bad Request" "value must be 0 or 1" ;;
        esac
        debug_flag_set "$val" || json_fail "500 Internal Server Error" "debug set failed"
        json_ok
        ;;

    # ---------- AUTO-UPDATE ----------
    "GET /update/status")
        # GET → may refresh the cache opportunistically (TTL guarded).
        update_refresh_manifest 0 2>/dev/null || true
        installed=$(update_installed_tag)
        available=$(update_manifest_current)
        behind=$(update_behind_count "$installed")
        last_check=$(update_last_check_ts)
        fetch_failed=$(update_last_fetch_failed)
        check_age=$(update_last_check_age)
        pending=$(update_pending_entries "$installed")
        json_header
        printf '{"ok":true,"installed":'
        json_string "$installed"
        printf ',"available":'
        json_string "$available"
        printf ',"behind":%s,"last_check":%s,"fetch_failed":%s,"check_age":%s,"pending":%s}\n' \
            "${behind:-0}" "${last_check:-0}" "${fetch_failed:-false}" "${check_age:--1}" "${pending:-[]}"
        exit 0
        ;;

    "POST /update/check")
        update_refresh_manifest 1 2>/dev/null
        installed=$(update_installed_tag)
        available=$(update_manifest_current)
        behind=$(update_behind_count "$installed")
        last_check=$(update_last_check_ts)
        fetch_failed=$(update_last_fetch_failed)
        check_age=$(update_last_check_age)
        pending=$(update_pending_entries "$installed")
        json_header
        printf '{"ok":true,"installed":'
        json_string "$installed"
        printf ',"available":'
        json_string "$available"
        printf ',"behind":%s,"last_check":%s,"fetch_failed":%s,"check_age":%s,"pending":%s}\n' \
            "${behind:-0}" "${last_check:-0}" "${fetch_failed:-false}" "${check_age:--1}" "${pending:-[]}"
        exit 0
        ;;

    "POST /update/apply")
        job_id=$(update_apply_async) || json_fail "500 Internal Server Error" "apply launch failed"
        json_header
        printf '{"ok":true,"job":'
        json_string "$job_id"
        printf '}\n'
        exit 0
        ;;

    # ---------- УДАЛЕНИЕ ZAPRET2 ----------
    #
    # Слово подтверждения проверяет СЕРВЕР, а не только страница. Origin-guard
    # для POST уже стоит, но он защищает от чужого сайта, а не от случайного
    # запроса из локальной сети: панель работает без авторизации и доверяет
    # всему сегменту. Это единственный необратимый вызов в API, поэтому у него
    # есть собственный ключ, который нельзя проставить, не зная его.
    "POST /uninstall")
        body=$(read_body)
        confirm_word=$(form_value "$body" "confirm")
        if [ "$confirm_word" != "УДАЛИТЬ" ]; then
            json_fail "400 Bad Request" "запрос отклонён: не подтверждено удаление"
        fi
        job_id=$(uninstall_async) || json_fail "500 Internal Server Error" "uninstall launch failed"
        json_header
        printf '{"ok":true,"job":'
        json_string "$job_id"
        printf '}\n'
        exit 0
        ;;

    # ---------- DEFAULT ----------
    *)
        json_fail "404 Not Found" "no such endpoint: $method $path"
        ;;
esac
