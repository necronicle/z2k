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
        case "$h" in
            ::1|fe80:*|fd*|fc*) return 0 ;;
        esac
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
