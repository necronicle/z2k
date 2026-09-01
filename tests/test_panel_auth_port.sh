#!/bin/sh
# tests/test_panel_auth_port.sh — панель обязана спрашивать порт морды у роутера.
#
# ЧТО БЫЛО. Адрес веб-интерфейса подбирался, а порт был зашит восьмидесятым.
# Keenetic позволяет перенести веб-конфигуратор (`ip http port N`), и тогда
# вызов не приходит ниоткуда: панель пишет «веб-интерфейс роутера не отвечает»,
# человек читает это как «неверный пароль» и идёт раздавать своей учётке права,
# которые ни при чём. Поле 01.09.2026 — ровно такая жалоба.
#
# Проверяется ИСПОЛНЕНИЕМ настоящих функций из webpanel/cgi/auth.sh.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/opt/zapret2/webpanel"
printf 'server.bind = "192.168.1.1"\n' > "$SB/opt/zapret2/webpanel/lighttpd.conf"

# Заглушки: ndmc отдаёт конфигурацию из файла, ip — один приватный адрес.
cat > "$SB/bin/ndmc" <<'STUB'
#!/bin/sh
cat "$NDM_CONF" 2>/dev/null
STUB
cat > "$SB/bin/ip" <<'STUB'
#!/bin/sh
printf '    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0\n'
STUB
chmod +x "$SB/bin/ndmc" "$SB/bin/ip"

# Функции берём настоящие, подменив только зашитый путь к конфигу панели.
awk '/^_panel_ndm_port\(\)/,/^}/' "$ROOT/webpanel/cgi/auth.sh"  > "$SB/fns.sh"
awk '/^_panel_ndm_candidates\(\)/,/^}/' "$ROOT/webpanel/cgi/auth.sh" >> "$SB/fns.sh"
sed -i.bak "s#/opt/zapret2/webpanel/lighttpd.conf#$SB/opt/zapret2/webpanel/lighttpd.conf#g" "$SB/fns.sh"

run() {  # run <содержимое running-config>
    printf '%s\n' "$1" > "$SB/ndm.conf"
    env PATH="$SB/bin:$PATH" NDM_CONF="$SB/ndm.conf" Z2K_NDM_HOST="" \
        "${Z2K_TEST_SH:-sh}" -c ". '$SB/fns.sh'; _panel_ndm_candidates" 2>/dev/null
}
port() {
    printf '%s\n' "$1" > "$SB/ndm.conf"
    env PATH="$SB/bin:$PATH" NDM_CONF="$SB/ndm.conf" \
        "${Z2K_TEST_SH:-sh}" -c ". '$SB/fns.sh'; _panel_ndm_port" 2>/dev/null
}

# --- 1. Порт перенесён — берём объявленный ------------------------------------
[ "$(port 'ip http port 8080')" = "8080" ] \
    && ok "перенесённый порт морды прочитан из конфигурации роутера" \
    || bad "порт морды не прочитан: [$(port 'ip http port 8080')]"

# --- 2. Строки нет — умолчание 80 ---------------------------------------------
[ "$(port 'ip http security-level private')" = "80" ] \
    && ok "без строки в конфигурации остаётся 80" \
    || bad "умолчание не 80: [$(port 'ip http security-level private')]"

# --- 3. Мусор и выход за диапазон не превращаются в адрес ----------------------
[ "$(port 'ip http port abc')" = "80" ] \
    && ok "мусор вместо порта не проходит" || bad "мусор просочился"
[ "$(port 'ip http port 99999')" = "80" ] \
    && ok "порт вне диапазона отбрасывается" || bad "99999 просочился"

# --- 4. Кандидаты несут порт, и 80 остаётся запасным ---------------------------
out=$(run 'ip http port 8080')
case "$out" in
    *192.168.1.1:8080*) ok "кандидат идёт с объявленным портом" ;;
    *) bad "в кандидатах нет объявленного порта: [$out]" ;;
esac
case "$out" in
    *192.168.1.1:80*) ok "80 остаётся запасным заходом" ;;
    *) bad "запасного захода на 80 нет: [$out]" ;;
esac
# Порядок важен: объявленный порт обязан идти первым, иначе на роутере с
# перенесённой мордой каждый вход платил бы таймаут по несуществующему 80.
[ "$(printf '%s\n' "$out" | head -1)" = "192.168.1.1:8080" ] \
    && ok "объявленный порт пробуется первым" \
    || bad "первым идёт не объявленный порт: [$(printf '%s\n' "$out" | head -1)]"

# --- 5. Умолчание не дублируется ----------------------------------------------
out80=$(run 'ip http security-level private')
n=$(printf '%s\n' "$out80" | grep -c '192.168.1.1:80')
[ "$n" = "1" ] && ok "при умолчании кандидат не задваивается" \
               || bad "кандидат 192.168.1.1:80 повторён $n раз"

# --- 6. Ручное указание по-прежнему главнее всего ------------------------------
manual=$(printf 'ip http port 8080\n' > "$SB/ndm.conf"; env PATH="$SB/bin:$PATH" \
    NDM_CONF="$SB/ndm.conf" Z2K_NDM_HOST="10.0.0.1:81" \
    "${Z2K_TEST_SH:-sh}" -c ". '$SB/fns.sh'; _panel_ndm_candidates" 2>/dev/null)
[ "$manual" = "10.0.0.1:81" ] \
    && ok "Z2K_NDM_HOST перебивает подбор" \
    || bad "ручное указание потеряно: [$manual]"

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
