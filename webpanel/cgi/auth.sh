#!/bin/sh
# z2k webpanel — cross-origin request guard.
# Sourced from api.sh.
#
# The panel has NO HTTP authentication — LAN + KeenDNS by design, same trust
# level as the Keenetic web UI itself. That is a decision about WHO may use the
# panel. This file answers a different question: did this request come from the
# panel's own page, or from some other site the user happens to have open in
# another tab? Authentication and origin isolation are separate problems, and
# only the second one is solved here.
#
# We accept any ONE of three proofs of same-origin:
#
#   X-Z2K-Panel    — set by app.js on every fetch. A cross-origin <form> — the
#                    workhorse of CSRF, because it fires without reading the
#                    response — cannot set a header at all. A cross-origin
#                    fetch that sets one turns into a CORS preflight we never
#                    answer, so the real request is never sent.
#   Sec-Fetch-Site — set by the browser, not the page. Unlike Referer, the
#                    requesting document can neither forge nor suppress it.
#   Origin         — likewise browser-set, and not subject to Referrer-Policy.
#
# Three proofs and not one because a reverse proxy in front of us (KeenDNS
# cloud access) may drop headers it does not recognise; at least one survives.
#
# Referer is deliberately NOT consulted any more. The requesting page controls
# it through Referrer-Policy, and every browser strips it outright when an
# HTTPS page posts to an HTTP origin — so both "matches us" and "empty" are
# states an attacker can arrange at will.
#
# Host is checked separately and always: after a successful DNS rebind the
# attacker's page IS same-origin, so every check above passes by construction.
# Only pinning Host to something the attacker cannot name stops that.

json_error() {
    local code="$1"
    local msg="$2"
    printf 'Status: %s\r\n' "$code"
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '{"ok":false,"error":"%s"}\n' "$msg"
    exit 0
}

# Directory holding the bind/port/hosts files, one level up from cgi/.
_auth_panel_dir() {
    local d=""
    d=$(dirname "${SELF_DIR:-/opt/zapret2/webpanel/cgi}" 2>/dev/null)
    [ -n "$d" ] && [ -d "$d" ] || d="/opt/zapret2/webpanel"
    printf '%s' "$d"
}

# HTTP_HOST -> bare hostname. IPv6 arrives bracketed ("[::1]:8088").
_auth_host_only() {
    local h="$1"
    case "$h" in
        \[*)  h="${h#\[}"; h="${h%%\]*}" ;;
        *:*)  h="${h%%:*}" ;;
    esac
    printf '%s' "$h"
}

# True only for a literal dotted-quad. A glob like 10.* would also accept the
# hostname "10.evil.tld", which is exactly the rebinding case we must reject.
_auth_is_ipv4() {
    local s="$1" o1 o2 o3 o4 rest
    case "$s" in
        ''|*[!0-9.]*|*..*|.*|*.) return 1 ;;
    esac
    o1="${s%%.*}"; rest="${s#*.}"
    [ "$rest" != "$s" ] || return 1
    o2="${rest%%.*}"; rest="${rest#*.}"
    [ -n "$rest" ] || return 1
    o3="${rest%%.*}"; o4="${rest#*.}"
    case "$o4" in ''|*.*) return 1 ;; esac
    [ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ]
}

_auth_is_ipv6() {
    case "$1" in
        *:*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!0-9A-Fa-f:.]*) return 1 ;;
    esac
    return 0
}

# Which Host values may address this panel. Anything an attacker can point at
# our IP from public DNS must NOT be here.
_auth_host_allowed() {
    local h="$1" dir bind

    [ -n "$h" ] || return 1
    # Nothing legitimate carries these; keep them out of later matching.
    case "$h" in
        */*|*'\'*|*'?'*|*'*'*|*'['*) return 1 ;;
    esac

    dir=$(_auth_panel_dir)
    bind=$(cat "$dir/bind" 2>/dev/null)
    # Адрес бинда разрешаем как Host ТОЛЬКО если он приватный.
    #
    # Раньше условие было просто "$h" = "$bind", и это замыкало круг: детект
    # LAN при неудаче брал src маршрута по умолчанию, то есть адрес WAN,
    # записывал его в этот самый файл — и публичный адрес сам себя вносил в
    # allowlist, отключая заодно и защиту от DNS-rebinding для себя.
    # Детект починен (webpanel/install.sh), но самоподтверждение — второй
    # независимый замок: файл bind можно задать и руками через --bind.
    #
    # 0.0.0.0 сюда не попадает намеренно: это не адрес, по которому обращаются,
    # а «слушать везде»; Host при этом придёт настоящий и пройдёт проверки ниже.
    if [ -n "$bind" ] && [ "$h" = "$bind" ]; then
        case "$bind" in
            127.*|10.*|192.168.*|169.254.*) return 0 ;;
            172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
            ::1|fe80:*|fd*|fc*) return 0 ;;
        esac
        # Публичный или неопознанный адрес в bind — молча не доверяем, пусть
        # запрос проходит остальные проверки на общих основаниях.
    fi

    # Operator escape hatch — one hostname per line. For the user who reaches
    # the panel through a name of their own (reverse proxy, custom local DNS).
    if [ -f "$dir/hosts" ] && grep -qxiF -- "$h" "$dir/hosts" 2>/dev/null; then
        return 0
    fi

    # Address literals. A rebind needs a NAME whose DNS the attacker controls;
    # a bare address always means the operator's own network.
    if _auth_is_ipv4 "$h"; then
        case "$h" in
            127.*|10.*|192.168.*|169.254.*) return 0 ;;
            172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        esac
        return 1
    fi
    if _auth_is_ipv6 "$h"; then
        # Петля, link-local и приватные диапазоны — как у IPv4.
        case "$h" in
            ::1|fe80:*|fd*|fc*) return 0 ;;
        esac
        # ГЛОБАЛЬНЫЙ IPv6 — только если это адрес САМОГО РОУТЕРА.
        #
        # У IPv6 нет NAT: домашней сети раздаётся настоящий префикс, и адрес
        # панели у человека часто глобальный. Отбивать его наглухо значит
        # сказать «панель не отвечает на этот адрес» тому, кто открыл её по
        # единственному имеющемуся адресу — ровно та жалоба, из-за которой всё
        # это и делается.
        #
        # Дыры здесь нет, и вот почему. Проверка существует против подмены DNS,
        # а та работает через ИМЯ: браузер шлёт Host с доменом злоумышленника,
        # и такой Host по-прежнему отбивается ниже. Литеральный адрес в Host
        # означает, что человек сам его набрал. Принимаем при этом не любой
        # литерал, а только тот, что действительно поднят на интерфейсе этого
        # роутера, — чужой адрес в Host ничего не даёт.
        _auth_own_ipv6 "$h" && return 0
        return 1
    fi

    # KeenDNS / netcraze — issued by Keenetic, so not registrable by anyone
    # else. Matched against the hostname alone: the old code globbed the whole
    # Referer URL, where * also spans "/" and https://evil.tld/.keenetic.pro/
    # sailed straight through.
    # keenetic.net — штатное локальное имя роутера (my.keenetic.net), по нему
    # открывают и родной веб-интерфейс. Без него у всех, у кого панель в
    # закладках под этим именем, каждый запрос отвечал 403.
    case "$h" in
        keenetic.net|*.keenetic.net) return 0 ;;
        *.keenetic.pro|*.keenetic.com|*.keenetic.io|*.keenetic.cloud|*.keenetic.link) return 0 ;;
        *.netcraze.pro|*.netcraze.com|*.netcraze.io|*.netcraze.cloud|*.netcraze.link) return 0 ;;
    esac

    # Names that cannot exist in public DNS, so cannot be rebound: local
    # suffixes and single-label names ("router", "keenetic").
    case "$h" in
        *.lan|*.local|*.home|*.internal|*.home.arpa) return 0 ;;
        *.*) return 1 ;;
        *) return 0 ;;
    esac
}

# ============================================================================
#  ПАРОЛЬ НА ПАНЕЛЬ — ТОТ ЖЕ, ЧТО У САМОГО РОУТЕРА
# ============================================================================
#
# ЗАЧЕМ. Всё, что стоит выше, защищает от чужого САЙТА и от обращения ИЗВНЕ:
# панель слушает только адрес в локальной сети, Host сверяется с приватными
# диапазонами (иначе DNS-rebinding), origin проверяется. Снаружи она
# недоступна — проверено стуком с другого конца интернета. Чего эта защита не
# закрывает вовсе — того, кто УЖЕ в локальной сети: гостевой Wi-Fi без
# изоляции, чужое устройство, сосед с паролем. Для него панель открыта
# полностью, а её CGI работает от root.
#
# СВОЙ ПАРОЛЬ НЕ ЗАВОДИМ. Спрашиваем сам роутер: у его веб-интерфейса есть
# эндпоинт /auth со схемой x-ndw2-interactive — он отдаёт realm и одноразовый
# challenge, а мы возвращаем SHA256(challenge + MD5(логин:realm:пароль)).
# Проверено на живом Keenetic: верный пароль → 200, неверный → 401,
# несуществующий логин → 401.
#
# Почему так, а не свой файл с паролем:
#   * хранить нечего — ни пароля, ни хеша;
#   * по сети идёт одноразовый ответ на случайный вызов, а не пароль, поэтому
#     подслушивание в локальной сети бесполезно даже по открытому HTTP;
#   * сменили пароль на роутере — он сразу действует и здесь;
#   * забыли — восстанавливается штатными средствами Keenetic.
#
# ВЫХОД ЕСТЬ ВСЕГДА. Если веб-интерфейс роутера не отвечает, войти нельзя:
# пускать всех в этом случае значит превратить пароль в театр — любой в
# локальной сети уронил бы роутеру порт 80 и вошёл. Но и запереть наглухо
# нельзя, поэтому пароль ВСЕГДА снимается из терминального меню
# ([P] → переключатель), а терминал не зависит ни от панели, ни от веб-морды
# роутера. Это и написано человеку в тексте отказа.
Z2K_PANEL_SESS_DIR="${Z2K_PANEL_SESS_DIR:-/tmp/z2k-panel-sessions}"
# Два часа, а не двенадцать. Это ПРЕДЪЯВИТЕЛЬСКИЙ токен, который ходит по
# открытому HTTP: чем дольше он живёт, тем шире окно для того, кто снял его
# из эфира. Панелью пользуются заходами по несколько минут, а не сутками.
Z2K_PANEL_SESS_TTL="${Z2K_PANEL_SESS_TTL:-7200}"
Z2K_PANEL_CONFIG="${Z2K_PANEL_CONFIG:-/opt/zapret2/config}"
# Адрес веб-интерфейса роутера ПОДБИРАЕТСЯ, а не задаётся константой.
#
# Первой версией здесь стояло 127.0.0.1 — и это не работает: ndm не слушает
# петлю. Проверено на роутере: с 127.0.0.1 приходит 403 без вызова, а с
# 192.168.1.1 — 401 с realm и challenge. Слушает он адреса интерфейсов
# (netstat показал WAN и локальные), поэтому спрашиваем по тому адресу,
# на котором стоит сама панель: он принадлежит роутеру по построению.
#
# Кандидаты перебираются до первого, который реально отдаёт вызов: жёсткий
# выбор одного адреса развалится на первой же нестандартной топологии, а
# «отдал X-NDM-Challenge» — признак однозначный.
Z2K_NDM_HOST="${Z2K_NDM_HOST:-}"

_panel_ndm_candidates() {
    [ -n "$Z2K_NDM_HOST" ] && { printf '%s\n' "$Z2K_NDM_HOST"; return 0; }
    # 1. Адрес, на котором слушает сама панель.
    sed -n 's/^[[:space:]]*server\.bind[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        /opt/zapret2/webpanel/lighttpd.conf 2>/dev/null | grep -v '^0\.0\.0\.0$' | head -1
    # 2. Приватные адреса роутера — на случай bind 0.0.0.0 или переезда панели.
    ip -4 addr show 2>/dev/null \
        | sed -n 's|^[[:space:]]*inet \([0-9.]*\)/.*|\1|p' \
        | grep -E '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -4
}

# Выключено по умолчанию: панель ставили годами без пароля, и обновление не
# должно однажды утром потребовать его от всех.
panel_auth_enabled() {
    # НЕЧИТАЕМЫЙ КОНФИГ — НЕ «ПАРОЛЬ ВЫКЛЮЧЕН».
    #
    # Здесь стояло `[ -r ... ] || return 1`, то есть при любой беде с файлом
    # ворота открывались настежь и молча. А конфиг лежит на той же флешке,
    # которая у нас регулярно уходит в read-only — то есть отказ читаемости
    # это не гипотеза.
    #
    # Различаем два случая:
    #   файла НЕТ вовсе      — панель не настроена, пароля никогда не было,
    #                          закрываться не от чего;
    #   файл ЕСТЬ, но не читается — состояние неизвестно, и единственное
    #                          безопасное допущение «пароль был включён».
    #                          Дверь при этом не заперта: снять пароль можно
    #                          из терминального меню, оно конфиг перезапишет.
    if [ ! -e "$Z2K_PANEL_CONFIG" ]; then
        return 1
    fi
    if [ ! -r "$Z2K_PANEL_CONFIG" ]; then
        return 0
    fi
    _pa=$(sed -n 's/^Z2K_PANEL_AUTH=["'"'"']*\([01]\).*/\1/p' "$Z2K_PANEL_CONFIG" 2>/dev/null | tail -1)
    [ "${_pa:-0}" = "1" ]
}

# Кука сессии из заголовка. Имя короткое и своё, чтобы не пересечься с чужими.
_panel_cookie() {
    printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' | LC_ALL=C sed -n \
        's/^[[:space:]]*z2kpsid=\([A-Za-z0-9]\{16,64\}\)[[:space:]]*$/\1/p' | head -1
}

# Живая сессия — это ФАЙЛ, а не подпись: подписывать нечем (секрета у нас нет),
# зато файл можно удалить, то есть выкинуть всех разом при выключении пароля.
panel_session_valid() {
    _sid=$(_panel_cookie)
    [ -n "$_sid" ] || return 1
    _f="$Z2K_PANEL_SESS_DIR/$_sid"
    [ -f "$_f" ] || return 1
    _ts=$(sed -n '1p' "$_f" 2>/dev/null)
    # Мусор вместо метки времени — это не «сессия свежая», это испорченный
    # файл. Считать его валидным значит принять чужую подделку.
    case "$_ts" in ''|*[!0-9]*) rm -f "$_f" 2>/dev/null; return 1 ;; esac
    _age=$(( $(date +%s) - _ts ))
    if [ "$_age" -lt 0 ] || [ "$_age" -gt "$Z2K_PANEL_SESS_TTL" ]; then
        rm -f "$_f" 2>/dev/null
        return 1
    fi
    # Привязка к клиенту. Кука ходит по открытому HTTP, и перехваченный
    # заголовок иначе давал бы полный вход к CGI, работающему от root.
    # Совпадение адреса не спасает от соседа, подменившего себе адрес, — но
    # отсекает пассивное подслушивание, а это ровно тот случай, ради которого
    # пароль и вводили. Записи без адреса (старый формат) не принимаем.
    _ip=$(sed -n '3p' "$_f" 2>/dev/null)
    [ -n "$_ip" ] || { rm -f "$_f" 2>/dev/null; return 1; }
    [ "$_ip" = "${REMOTE_ADDR:-?}" ] || return 1
    return 0
}

# Каталог только для root и только наш.
#
# /tmp общедоступен на запись, а tmpfs после перезагрузки пуст — значит между
# стартом системы и первым входом любой процесс успевает создать каталог
# сессий и подложить туда свой файл, который мы потом примем за настоящий.
# Поэтому: создаём с правами сразу (mkdir -m, а не mkdir + chmod — между ними
# окно), и если каталог уже есть, проверяем, что он наш и не доступен чужим.
_panel_mkdir_private() {
    _d="$1"
    if [ -e "$_d" ]; then
        [ -d "$_d" ] || return 1
        [ -L "$_d" ] && return 1
        # ls печатает ИМЯ владельца, а id -u — число: сравнивать их между собой
        # бессмысленно, проверка проваливалась бы всегда, когда мы не root.
        # На роутере CGI и так работает от root, но эта же функция гоняется в
        # тестах под обычным пользователем, и «всегда false» там означало бы
        # проверку, которая ничего не проверяет.
        _own=$(ls -ld "$_d" 2>/dev/null | awk '{print $3}')
        _me=$(id -un 2>/dev/null || id -u 2>/dev/null)
        [ "$_own" = "root" ] || [ "$_own" = "$_me" ] || return 1
        _mode=$(ls -ld "$_d" 2>/dev/null | awk '{print $1}')
        case "$_mode" in
            drwx------*) ;;
            *) chmod 700 "$_d" 2>/dev/null || return 1 ;;
        esac
        return 0
    fi
    # Без -p: с ним -m применяется ТОЛЬКО к последнему уровню, а промежуточные
    # каталоги создаются с правами по умолчанию — то есть доступными чужим.
    # Родителя создаём отдельно и заранее.
    _parent=$(dirname "$_d")
    [ -d "$_parent" ] || mkdir -p "$_parent" 2>/dev/null || return 1
    mkdir -m 700 "$_d" 2>/dev/null
}

# Случайное шестнадцатеричное значение — ИЛИ ОТКАЗ.
#
# Запасным путём тут стоял `head -c 64 /dev/urandom | md5sum`, и это было хуже
# отсутствия запасного пути: если /dev/urandom недоступен или head отсутствует,
# md5sum считает хеш ПУСТОГО ввода и уверенно возвращает d41d8cd98f00b204…
# — одну и ту же константу на всех роутерах мира. Предсказуемый токен сессии
# страшнее, чем «не удалось войти», поэтому здесь только отказ.
_panel_random_hex() {
    _v=$(openssl rand -hex 24 2>/dev/null)
    case "$_v" in
        [0-9a-f]*) [ "${#_v}" -ge 32 ] && { printf '%s' "$_v"; return 0; } ;;
    esac
    # Запасной путь — тоже НАСТОЯЩАЯ случайность, а не хеш чего попало:
    # читаем urandom и проверяем, что байты действительно прочитались.
    _raw=$(head -c 32 /dev/urandom 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1)
    [ "$_raw" = "d41d8cd98f00b204e9800998ecf8427e" ] && return 1   # md5 пустого ввода
    case "$_raw" in
        [0-9a-f]*) [ "${#_raw}" = "32" ] && { printf '%s' "$_raw"; return 0; } ;;
    esac
    return 1
}

# БИЛЕТ НА ВХОД. Связывает выданный вызов с кукой роутера и адресом, по
# которому вызов получен. Иначе второй шаг пришлось бы принимать от браузера
# на веру, а он в этой модели угрозы недоверенная сторона.
#
# Живёт секунды: вызов у роутера всё равно одноразовый, а долгий билет — это
# лишний файл, который кто-то попробует подобрать.
Z2K_PANEL_CHAL_TTL="${Z2K_PANEL_CHAL_TTL:-120}"

panel_challenge_store() {   # challenge host jarfile -> печатает билет
    # Сперва родитель с правильными правами, потом вложенный: иначе он был бы
    # создан родителем как побочный эффект и с чужими правами.
    _panel_mkdir_private "$Z2K_PANEL_SESS_DIR" || return 1
    _dir="$Z2K_PANEL_SESS_DIR/chal"
    _panel_mkdir_private "$_dir" || return 1
    _cid=$(_panel_random_hex) || return 1
    printf '%s\n%s\n%s\n' "$(date +%s)" "$2" "$3" > "$_dir/$_cid" || return 1
    chmod 600 "$_dir/$_cid" 2>/dev/null || true
    # Старые билеты подчищаем здесь же: отдельного уборщика на роутере нет.
    for _old in "$_dir"/*; do
        [ -f "$_old" ] || continue
        _t=$(sed -n '1p' "$_old" 2>/dev/null)
        case "$_t" in ''|*[!0-9]*) rm -f "$_old" 2>/dev/null; continue ;; esac
        [ $(( $(date +%s) - _t )) -gt "$Z2K_PANEL_CHAL_TTL" ] && rm -f "$_old" 2>/dev/null
    done
    printf '%s' "$_cid"
}

# Разбирает билет и выставляет PANEL_CHAL_HOST / PANEL_CHAL_JAR. Билет
# одноразовый: файл удаляется сразу, повторить тот же вход нельзя.
panel_challenge_use() {
    PANEL_CHAL_HOST=""; PANEL_CHAL_JAR=""
    _cid="$1"
    case "$_cid" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
    [ "${#_cid}" -ge 16 ] || return 1
    _f="$Z2K_PANEL_SESS_DIR/chal/$_cid"
    [ -f "$_f" ] || return 1
    _t=$(sed -n '1p' "$_f" 2>/dev/null)
    PANEL_CHAL_HOST=$(sed -n '2p' "$_f" 2>/dev/null)
    PANEL_CHAL_JAR=$(sed -n '3p' "$_f" 2>/dev/null)
    rm -f "$_f" 2>/dev/null
    case "$_t" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( $(date +%s) - _t )) -le "$Z2K_PANEL_CHAL_TTL" ] || return 1
    [ -n "$PANEL_CHAL_HOST" ] && [ -n "$PANEL_CHAL_JAR" ]
}

panel_challenge_clear() {
    [ -n "${PANEL_CHAL_JAR:-}" ] && rm -f "$PANEL_CHAL_JAR" 2>/dev/null
    return 0
}

panel_session_create() {
    _panel_mkdir_private "$Z2K_PANEL_SESS_DIR" || return 1
    _sid=$(_panel_random_hex) || return 1
    # Вторая строка — логин, третья — адрес клиента: сессия привязывается к
    # тому, кто её открыл. Кука ходит по открытому HTTP, и без привязки
    # перехваченный заголовок давал бы полный вход на все 12 часов.
    printf '%s\n%s\n%s\n' "$(date +%s)" "${1:-?}" "${REMOTE_ADDR:-?}" \
        > "$Z2K_PANEL_SESS_DIR/$_sid" || return 1
    chmod 600 "$Z2K_PANEL_SESS_DIR/$_sid" 2>/dev/null || true
    printf '%s' "$_sid"
}

panel_session_drop() {
    _sid=$(_panel_cookie)
    [ -n "$_sid" ] && rm -f "$Z2K_PANEL_SESS_DIR/$_sid" 2>/dev/null
    return 0
}

# Все сессии разом — при выключении пароля и при смене политики доступа.
panel_sessions_drop_all() {
    rm -rf "$Z2K_PANEL_SESS_DIR" 2>/dev/null
    return 0
}

# Учётка должна иметь право на веб-интерфейс. Пароль от сетевой папки не
# должен открывать управление обходом — у Keenetic это отдельные теги.
panel_user_has_http_tag() {
    _u="$1"
    case "$_u" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac
    LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
        | awk -v want="$_u" '
            $1 == "user" { cur = ($2 == want) ; next }
            cur && $1 == "tag" && $2 == "http" { found = 1 }
            cur && $1 == "user" { cur = 0 }
            END { exit(found ? 0 : 1) }'
}

# Взять у роутера realm и одноразовый вызов. Печатает "realm<TAB>challenge<TAB>host".
# Нужна отдельно от проверки, потому что считает ответ теперь БРАУЗЕР, а не мы.
panel_ndm_challenge() {
    _jar="$1"
    for _c in $(_panel_ndm_candidates); do
        _hdr=$(curl -s -c "$_jar" -D - -o /dev/null -m 4 "http://${_c}/auth" 2>/dev/null)
        _r=$(printf '%s' "$_hdr" | awk 'BEGIN{IGNORECASE=1}/^X-NDM-Realm:/{sub(/^[^:]*: */,"");gsub(/\r/,"");print}')
        _ch=$(printf '%s' "$_hdr" | awk 'BEGIN{IGNORECASE=1}/^X-NDM-Challenge:/{sub(/^[^:]*: */,"");gsub(/\r/,"");print}')
        if [ -n "$_r" ] && [ -n "$_ch" ]; then
            printf '%s\t%s\t%s' "$_r" "$_ch" "$_c"
            return 0
        fi
    done
    return 1
}

# Отправить роутеру ГОТОВЫЙ ответ, посчитанный страницей.
# 0 — пароль верный; 1 — неверный; 2 — роутер не ответил.
panel_verify_ndm_response() {
    _login="$1"; _resp="$2"; _host="$3"; _jar="$4"
    case "$_login" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac
    case "$_resp"  in ''|*[!0-9a-fA-F]*) return 1 ;; esac
    [ "${#_resp}" = "64" ] || return 1        # SHA-256 в шестнадцатеричном виде

    _code=$(curl -s -b "$_jar" -o /dev/null -w '%{http_code}' -m 6 -X POST \
            -H 'Content-Type: application/json' \
            --data "{\"login\":\"${_login}\",\"password\":\"${_resp}\"}" \
            "http://${_host}/auth" 2>/dev/null)
    case "$_code" in
        200) ;;
        401|403) return 1 ;;
        *) return 2 ;;
    esac
    panel_user_has_http_tag "$_login" || return 1
    return 0
}

# Возвращает 0 — пароль верный; 1 — неверный; 2 — роутер не ответил.
panel_verify_router_password() {
    _login="$1"; _pass="$2"
    case "$_login" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac
    [ -n "$_pass" ] || return 1

    _jar="/tmp/z2k-auth.$$"
    _host=""; _realm=""; _chal=""
    for _c in $(_panel_ndm_candidates); do
        _hdr=$(curl -s -c "$_jar" -D - -o /dev/null -m 4 "http://${_c}/auth" 2>/dev/null)
        _realm=$(printf '%s' "$_hdr" | awk 'BEGIN{IGNORECASE=1}/^X-NDM-Realm:/{sub(/^[^:]*: */,"");gsub(/\r/,"");print}')
        _chal=$(printf '%s'  "$_hdr" | awk 'BEGIN{IGNORECASE=1}/^X-NDM-Challenge:/{sub(/^[^:]*: */,"");gsub(/\r/,"");print}')
        if [ -n "$_realm" ] && [ -n "$_chal" ]; then _host="$_c"; break; fi
    done
    if [ -z "$_host" ]; then
        rm -f "$_jar" 2>/dev/null
        return 2
    fi

    _md5=$(printf '%s:%s:%s' "$_login" "$_realm" "$_pass" | md5sum | cut -d' ' -f1)
    _sha=$(printf '%s%s' "$_chal" "$_md5" | sha256sum | cut -d' ' -f1)
    _code=$(curl -s -b "$_jar" -o /dev/null -w '%{http_code}' -m 6 -X POST \
            -H 'Content-Type: application/json' \
            --data "{\"login\":\"${_login}\",\"password\":\"${_sha}\"}" \
            "http://${_host}/auth" 2>/dev/null)
    rm -f "$_jar" 2>/dev/null

    case "$_code" in
        200) ;;
        401|403) return 1 ;;
        *) return 2 ;;    # 000/5xx — роутер не ответил, это НЕ «пароль неверный»
    esac
    # Роутер пароль принял. Тег http — вторая, наша проверка: /auth его,
    # скорее всего, и сам требует, но полагаться на догадку о чужой политике
    # нельзя, а лишний отказ здесь безопаснее лишнего доступа.
    panel_user_has_http_tag "$_login" || return 1
    return 0
}

# Адрес принадлежит этому роутеру? Сравнение построчное и точное: подстрокой
# «2a00::1» совпало бы с «2a00::10», то есть с чужим адресом в той же сети.
_auth_own_ipv6() {
    _want=$(printf '%s' "$1" | tr 'A-F' 'a-f')
    ip -6 addr show 2>/dev/null \
        | sed -n 's|^[[:space:]]*inet6 \([0-9a-fA-F:]*\)/.*|\1|p' \
        | tr 'A-F' 'a-f' \
        | grep -qxF "$_want"
}

auth_require() {
    local host_raw="${HTTP_HOST:-}"
    local method="${REQUEST_METHOD:-GET}"
    local sfs="${HTTP_SEC_FETCH_SITE:-}"
    local origin="${HTTP_ORIGIN:-}"
    local host=""

    host=$(_auth_host_only "$host_raw")
    if [ -z "$host_raw" ] || ! _auth_host_allowed "$host"; then
        json_error "403 Forbidden" "запрос отклонён: панель не отвечает на этот адрес"
    fi

    # Positive evidence of another origin outranks every proof below.
    case "$sfs" in
        cross-site|same-site)
            json_error "403 Forbidden" "запрос отклонён: обращение с другого сайта"
            ;;
    esac

    [ -n "${HTTP_X_Z2K_PANEL:-}" ] && return 0
    [ "$sfs" = "same-origin" ] && return 0
    # "none" is a user-typed URL or a bookmark — an attacker's page cannot
    # produce it. Reads only; a mutation still needs one of the proofs above.
    [ "$sfs" = "none" ] && [ "$method" = "GET" ] && return 0

    if [ -n "$origin" ]; then
        # String compare, never a case pattern: Host is attacker-supplied and
        # "Host: *" would otherwise expand into a glob matching everything.
        if [ "$origin" = "http://$host_raw" ] || [ "$origin" = "https://$host_raw" ]; then
            return 0
        fi
        json_error "403 Forbidden" "запрос отклонён: обращение с другого сайта"
    fi

    json_error "403 Forbidden" "запрос отклонён: браузер не передал признак запроса со страницы панели"
}

# Ворота пароля. Ставятся ПОСЛЕ auth_require: проверки происхождения запроса
# дешевле и должны отбивать чужие сайты раньше, чем мы вообще заговорим о
# сессии. Вызывается из api.sh перед разбором маршрута.
panel_auth_gate() {
    panel_auth_enabled || return 0

    _p="${PATH_INFO:-/}"
    # Сам вход и состояние — единственное, что доступно без сессии. Иначе
    # страница не смогла бы даже узнать, что от неё хотят пароль.
    case "$_p" in
        /auth/challenge|/auth/login|/auth/state) return 0 ;;
    esac

    panel_session_valid && return 0

    # Признак needauth машиночитаемый: по нему страница показывает форму входа,
    # а не красную плашку с текстом ошибки.
    printf 'Status: 401 Unauthorized\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '{"ok":false,"needauth":true,"error":"нужен вход: логин и пароль от веб-интерфейса роутера"}\n'
    exit 0
}
