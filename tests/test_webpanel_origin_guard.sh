#!/bin/sh
# Origin guard (cgi/auth.sh): каждый сценарий из ревью 2026-08-06 плюс живые
# пути доступа, которые ломать нельзя.
#
# auth.sh дёргается напрямую, без HTTP: важно ровно то, какие переменные
# окружения CGI до него доезжают.

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
TESTS_DIR=$(dirname "$SELF")
Z2K_DIR=$(dirname "$TESTS_DIR")
AUTH="$Z2K_DIR/webpanel/cgi/auth.sh"

[ -f "$AUTH" ] || { echo "FAIL: не найден $AUTH"; exit 1; }

TMP="${TMPDIR:-/tmp}/z2k-origin-guard.$$"
mkdir -p "$TMP/webpanel/cgi" || exit 1
printf '192.168.1.1' > "$TMP/webpanel/bind"
printf '8088' > "$TMP/webpanel/port"
trap 'rm -rf "$TMP"' EXIT INT TERM

pass=0; fail=0

# Прогон auth_require в отдельном shell. Печатает ALLOW либо DENY.
# Аргументы — присваивания вида ИМЯ=значение, пустое значение = заголовка нет.
run_guard() {
    env -i "PATH=$PATH" "AUTH_FILE=$AUTH" "SELF_DIR=$TMP/webpanel/cgi" "$@" /bin/sh -c '
        set -u
        . "$AUTH_FILE"
        auth_require
        echo ALLOW
    ' 2>/dev/null | {
        out=$(cat)
        case "$out" in
            *ALLOW*) echo ALLOW ;;
            *403*)   echo DENY ;;
            *)       echo "ERR:$out" ;;
        esac
    }
}

check() {
    want="$1"; name="$2"; shift 2
    got=$(run_guard "$@")
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name — ожидали $want, получили $got"
    fi
}

echo "--- обходы, найденные в ревью (должны отбиваться) ---"

# H2: HTTPS-страница постит на HTTP-панель. Браузер сам вырезает Referer при
# понижении схемы, старый код пропускал это как «мы за trusted proxy».
check DENY "CSRF: пустой Referer + приватный Host" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 HTTP_SEC_FETCH_SITE=cross-site

# Тот же запрос от браузера, который Sec-Fetch не шлёт вовсе.
check DENY "CSRF: пустой Referer, без Sec-Fetch" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088

# H1: * в глобе покрывал и слэш, поэтому путь в URL подделывал домен.
check DENY "CSRF: Referer https://evil.tld/.keenetic.pro/" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 \
    HTTP_REFERER=https://evil.tld/.keenetic.pro/ HTTP_SEC_FETCH_SITE=cross-site
check DENY "CSRF: Referer https://evil.tld/.netcraze.pro" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 \
    HTTP_REFERER=https://evil.tld/.netcraze.pro

# H3: старая проверка сверяла Referer с Host — оба от атакующего.
check DENY "DNS-rebinding: Host и Referer = evil.tld" \
    REQUEST_METHOD=POST HTTP_HOST=evil.tld:8088 \
    HTTP_REFERER=http://evil.tld:8088/ HTTP_SEC_FETCH_SITE=same-origin
check DENY "DNS-rebinding: Origin совпадает с Host" \
    REQUEST_METHOD=POST HTTP_HOST=evil.tld:8088 HTTP_ORIGIN=http://evil.tld:8088

# L5: 10.* как глоб ловил и хостнейм.
check DENY "Host 10.evil.tld — не адрес, а имя" \
    REQUEST_METHOD=POST HTTP_HOST=10.evil.tld HTTP_SEC_FETCH_SITE=same-origin
check DENY "Host 172.20.evil.tld" \
    REQUEST_METHOD=POST HTTP_HOST=172.20.evil.tld HTTP_SEC_FETCH_SITE=same-origin

# L6: Host подставлялся В шаблон case, метасимвол становился wildcard'ом.
check DENY "Host '*' не превращается в wildcard" \
    REQUEST_METHOD=POST HTTP_HOST='*' HTTP_ORIGIN=http://anything

# M1: GET с побочными эффектами (/diag от root) через <img src> с чужой страницы.
check DENY "GET с чужого сайта" \
    REQUEST_METHOD=GET HTTP_HOST=192.168.1.1:8088 HTTP_SEC_FETCH_SITE=cross-site
check DENY "GET вообще без признаков origin" \
    REQUEST_METHOD=GET HTTP_HOST=192.168.1.1:8088

check DENY "запрос без Host" REQUEST_METHOD=POST

echo "--- живые пути доступа (ломать нельзя) ---"

# Штатный путь: fetch со страницы панели.
check ALLOW "LAN: маркер панели" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 HTTP_X_Z2K_PANEL=1 \
    HTTP_SEC_FETCH_SITE=same-origin
# Прокси срезал кастомный заголовок — держит Sec-Fetch.
check ALLOW "маркер срезан прокси, Sec-Fetch на месте" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 HTTP_SEC_FETCH_SITE=same-origin
# Прокси срезал Sec-Fetch — держит маркер.
check ALLOW "Sec-Fetch нет, маркер на месте" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 HTTP_X_Z2K_PANEL=1
# Полевой кейс 2026-05-24: KeenDNS вырезает Referer, Host переписан на LAN.
check ALLOW "KeenDNS: Referer вырезан, Host = LAN backend" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.2.1 HTTP_X_Z2K_PANEL=1
# Удалённый доступ по имени KeenDNS.
check ALLOW "KeenDNS: necronicle.keenetic.pro" \
    REQUEST_METHOD=POST HTTP_HOST=necronicle.keenetic.pro HTTP_X_Z2K_PANEL=1 \
    HTTP_SEC_FETCH_SITE=same-origin
check ALLOW "netcraze: yarega.netcraze.pro" \
    REQUEST_METHOD=POST HTTP_HOST=yarega.netcraze.pro HTTP_X_Z2K_PANEL=1
# Только Origin (браузер без Sec-Fetch, прокси съел маркер).
check ALLOW "совпадающий Origin" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 HTTP_ORIGIN=http://192.168.1.1:8088
# KeenDNS ходит по https, и это единственный признак, доехавший до нас.
check ALLOW "совпадающий Origin по https через KeenDNS" \
    REQUEST_METHOD=POST HTTP_HOST=necronicle.keenetic.pro \
    HTTP_ORIGIN=https://necronicle.keenetic.pro
# Чужой публичный домен без записи в webpanel/hosts панель не обслуживает.
check DENY "чужой публичный домен" \
    REQUEST_METHOD=POST HTTP_HOST=panel.example.ru HTTP_X_Z2K_PANEL=1 \
    HTTP_SEC_FETCH_SITE=same-origin
# Юзер открыл адрес руками/из закладки — только чтение.
check ALLOW "GET по набранному адресу (Sec-Fetch none)" \
    REQUEST_METHOD=GET HTTP_HOST=192.168.1.1:8088 HTTP_SEC_FETCH_SITE=none
check DENY "POST по набранному адресу не проходит" \
    REQUEST_METHOD=POST HTTP_HOST=192.168.1.1:8088 HTTP_SEC_FETCH_SITE=none
# Другие подсети и локальные имена — у людей встречаются любые.
check ALLOW "другая подсеть 10.0.0.1" \
    REQUEST_METHOD=POST HTTP_HOST=10.0.0.1:8088 HTTP_X_Z2K_PANEL=1
check ALLOW "localhost по адресу" \
    REQUEST_METHOD=POST HTTP_HOST=127.0.0.1:8088 HTTP_X_Z2K_PANEL=1
check ALLOW "IPv6 [::1]" \
    REQUEST_METHOD=POST 'HTTP_HOST=[::1]:8088' HTTP_X_Z2K_PANEL=1
check ALLOW "односоставное имя router" \
    REQUEST_METHOD=POST HTTP_HOST=router:8088 HTTP_X_Z2K_PANEL=1
check ALLOW "локальный суффикс keenetic.lan" \
    REQUEST_METHOD=POST HTTP_HOST=keenetic.lan:8088 HTTP_X_Z2K_PANEL=1

echo "--- ручной allowlist для своего имени ---"
printf 'panel.mydomain.ru\n' > "$TMP/webpanel/hosts"
check ALLOW "имя из webpanel/hosts" \
    REQUEST_METHOD=POST HTTP_HOST=panel.mydomain.ru HTTP_X_Z2K_PANEL=1
check DENY "имя не из webpanel/hosts" \
    REQUEST_METHOD=POST HTTP_HOST=other.mydomain.ru HTTP_X_Z2K_PANEL=1
rm -f "$TMP/webpanel/hosts"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = "0" ] || exit 1
echo "OK"
