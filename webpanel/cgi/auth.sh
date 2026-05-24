#!/bin/sh
# z2k webpanel — CSRF helper library.
# Sourced from api.sh.
#
# The panel has NO HTTP authentication — it's LAN-only by design, same
# trust level as the Keenetic web UI at 192.168.1.1. We still enforce a
# same-origin Referer check for POST requests so a malicious web page
# on the same LAN cannot trick a browser into issuing destructive
# requests against the panel.

json_error() {
    local code="$1"
    local msg="$2"
    printf 'Status: %s\r\n' "$code"
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '{"ok":false,"error":"%s"}\n' "$msg"
    exit 0
}

auth_require() {
    if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
        local referer="${HTTP_REFERER:-}"
        local host="${HTTP_HOST:-}"
        if [ -z "$host" ]; then
            json_error "403 Forbidden" "cross-origin request blocked"
        fi
        # Host stripped of port for private-IP matching below.
        local host_noport="${host%%:*}"

        # KeenDNS / netcraze cloud reverse-proxy случай: облако
        # переписывает Host на LAN backend (например 192.168.2.1) И
        # вырезает Referer entirely (privacy). Field-confirmed 2026-05-24
        # на yarega.netcraze.pro юзере — Referer пуст, Host=192.168.2.1.
        # Принимаем пустой Referer ТОЛЬКО если Host — приватный IP:
        # это означает что мы за trusted reverse-proxy (наша :8088 не
        # рутируется из внешнего интернета). Атака CSRF из браузера
        # на LAN-странице оставила бы Referer ненулевым.
        if [ -z "$referer" ]; then
            case "$host_noport" in
                10.*|192.168.*|127.*) return ;;
                172.1[6-9].*|172.2[0-9].*|172.3[01].*) return ;;
            esac
            json_error "403 Forbidden" "cross-origin request blocked"
        fi

        # Direct LAN access — Referer scheme+host equals HTTP_HOST.
        case "$referer" in
            "http://$host"|"http://$host/"*|"https://$host"|"https://$host/"*)
                return ;;
        esac
        # KeenDNS cloud reverse-proxy access — Keenetic's authenticated
        # tunnel rewrites Host to the LAN backend, so HTTP_REFERER won't
        # match HTTP_HOST. Only Keenetic's own proxy can reach us with
        # these Referer hostnames, so CSRF guarantee still holds.
        # netcraze.* — новый официальный суффикс после ребрендинга
        # Keenetic в России (та же KeenDNS-инфраструктура, новый домен).
        case "$referer" in
            https://*.keenetic.pro/*|https://*.keenetic.pro|\
            https://*.keenetic.com/*|https://*.keenetic.com|\
            https://*.keenetic.io/*|https://*.keenetic.io|\
            https://*.keenetic.cloud/*|https://*.keenetic.cloud|\
            https://*.keenetic.link/*|https://*.keenetic.link|\
            https://*.netcraze.pro/*|https://*.netcraze.pro|\
            https://*.netcraze.com/*|https://*.netcraze.com|\
            https://*.netcraze.io/*|https://*.netcraze.io|\
            https://*.netcraze.cloud/*|https://*.netcraze.cloud|\
            https://*.netcraze.link/*|https://*.netcraze.link)
                return ;;
        esac
        json_error "403 Forbidden" "cross-origin request blocked"
    fi
}
