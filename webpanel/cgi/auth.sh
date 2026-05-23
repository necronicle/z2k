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
        if [ -z "$referer" ] || [ -z "$host" ]; then
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
        case "$referer" in
            https://*.keenetic.pro/*|https://*.keenetic.pro|\
            https://*.keenetic.com/*|https://*.keenetic.com|\
            https://*.keenetic.io/*|https://*.keenetic.io|\
            https://*.keenetic.cloud/*|https://*.keenetic.cloud|\
            https://*.keenetic.link/*|https://*.keenetic.link)
                return ;;
        esac
        json_error "403 Forbidden" "cross-origin request blocked"
    fi
}
