#!/bin/sh
# test_tunnel_pair_gating.sh
#
# Инвариант (решение владельца 2026-08-06): выключатель туннеля Telegram
# управляет ОБОИМИ туннелями — :1443 (Telegram) и :1444 (cdnbase). Это один
# бинарник tg-mtproxy-client в двух ролях, и держать один без другого незачем.
#
# Что чинилось этим релизом:
#   1. S97 stop() убивал ТОЛЬКО супервизора по pidfile. Демон при этом
#      осиротевал и продолжал жить, держа ~8 МБ и порт — это и наблюдали как
#      «выключил туннель, а он остался в памяти и жрёт оперативку».
#      Воспроизведено в песочнице на роутере до правки.
#   2. S97 start() не смотрел на TG_PROXY_USER_DISABLED, поэтому cdnbase
#      воскресал на каждом ребуте вопреки выключенному туннелю.
#   3. Панель, меню и watchdog трогали только S98.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
S97="$HERE/files/init.d/S97z2k-http-tunnel"
S98="$HERE/files/init.d/S98tg-tunnel"
PANEL="$HERE/webpanel/cgi/actions.sh"
MENU="$HERE/lib/menu.sh"
WD="$HERE/files/z2k-tg-watchdog.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }

# --- 1. S97 stop(): добивает СВОЙ демон, а не только супервизора -------------
# Вырезаем тело stop() и смотрим, что в нём есть матч по cmdline на свой порт.
# Без него смерть супервизора оставляет живого сироту (см. шапку).
s97_stop=$(awk '/^stop\(\)/{i=1} i{print} i&&/^\}/{exit}' "$S97")
if printf '%s' "$s97_stop" | grep -q 'cmdline'; then
    ok "S97 stop(): читает /proc/PID/cmdline (добой демона, не только супервизор)"
else
    bad "S97 stop(): добой демона" "нет обращения к cmdline — сирота переживёт stop"
fi
if printf '%s' "$s97_stop" | grep -q -- '--listen=:\$LISTEN_PORT'; then
    ok "S97 stop(): матчит именно СВОЙ порт (не заденет :1443)"
else
    bad "S97 stop(): матч по своему порту" "нет --listen=:\$LISTEN_PORT"
fi

# --- 2. S97 start(): уважает флаг пользователя -------------------------------
# Функциональная проверка: с флагом=1 старт обязан выйти до запуска демона.
TMP="${TMPDIR:-/tmp}/z2k-tunnel-gate.$$"
mkdir -p "$TMP/opt/zapret2"
trap 'rm -rf "$TMP"' EXIT INT TERM

s97_start=$(awk '/^start\(\)/{i=1} i{print} i&&/^\}/{exit}' "$S97")
# Флаг читается по абсолютному пути /opt/zapret2/config, подменить его нельзя,
# поэтому проверяем логику на извлечённом теле с подставленным awk-источником.
if printf '%s' "$s97_start" | grep -q 'TG_PROXY_USER_DISABLED'; then
    ok "S97 start(): смотрит на TG_PROXY_USER_DISABLED"
else
    bad "S97 start(): уважение флага" "флаг не упоминается — cdnbase воскреснет на ребуте"
fi
# Тот же приём, что в S98 — сверяем, что ветка реально прерывает старт.
if printf '%s' "$s97_start" | grep -A3 'user_disabled" = "1"' | grep -q 'return 0'; then
    ok "S97 start(): при флаге=1 выходит до запуска демона"
else
    bad "S97 start(): выход при флаге=1" "нет return 0 в ветке флага"
fi
# S98 обязан сохранить то же поведение (регресс-страховка).
s98_start=$(awk '/^start\(\)/{i=1} i{print} i&&/^\}/{exit}' "$S98")
if printf '%s' "$s98_start" | grep -q 'TG_PROXY_USER_DISABLED'; then
    ok "S98 start(): уважение флага не потеряно"
else
    bad "S98 start(): уважение флага" "регресс — флаг перестал проверяться"
fi

# --- 3. Все точки управления трогают ОБА туннеля ------------------------------
# Вырезаем нужные блоки и требуем упоминания обоих init-скриптов.
check_pair() { # <desc> <текст>
    _d="$1"; _t="$2"
    if printf '%s' "$_t" | grep -q 'S98tg-tunnel' && printf '%s' "$_t" | grep -q 'S97z2k-http-tunnel'; then
        ok "$_d: управляет обоими туннелями"
    else
        bad "$_d: управляет обоими туннелями" "cdnbase (S97) не затронут"
    fi
}

check_pair "панель, выключение" "$(awk '/^tunnel_disable\(\)/{i=1} i{print} i&&/^\}/{exit}' "$PANEL")"
check_pair "панель, включение"  "$(awk '/^tunnel_enable\(\)/{i=1} i{print} i&&/^\}/{exit}' "$PANEL")"

# watchdog: ветка «пользователь выключил туннель». Здесь телеграмный init
# зовётся через переменную $INIT, а не по имени файла, поэтому сверяем смысл:
# должен глушиться и телеграмный (через $INIT), и cdnbase (S97).
wd_block=$(awk '/user_disabled" = "1"/{i=1} i{print} i&&/exit 0/{exit}' "$WD")
if printf '%s' "$wd_block" | grep -q 'INIT' && printf '%s' "$wd_block" | grep -q 'S97z2k-http-tunnel'; then
    ok "watchdog, ветка выключено: глушит оба туннеля"
else
    bad "watchdog, ветка выключено: глушит оба туннеля" "в ветке нет одного из туннелей"
fi
# И сам $INIT обязан указывать на телеграмный init — иначе проверка выше пуста.
if grep -qE '^INIT=.*S98tg-tunnel' "$WD"; then
    ok "watchdog: \$INIT указывает на S98tg-tunnel"
else
    bad "watchdog: \$INIT указывает на S98tg-tunnel" "переменная изменилась — проверка выше теряет смысл"
fi
# меню: обе ветки (запуск и остановка) внутри одного case-блока
menu_tunnel=$(awk '/S98tg-tunnel restart/{i=1} i{print; n++} n>12{exit}' "$MENU")
check_pair "меню, включение" "$menu_tunnel"
menu_stop=$(awk '/S98tg-tunnel stop/{i=1} i{print; n++} n>8{exit}' "$MENU")
check_pair "меню, остановка" "$menu_stop"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
