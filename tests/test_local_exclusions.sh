#!/bin/sh
# test_local_exclusions.sh
#
# Локальные адреса не должны попадать под десинк НИКОГДА: между роутером и
# 192.168.x / 10.x нет DPI, обходить там нечего — а сломать можно. Полевой
# отчёт 2026-08-06: приложение камер (EasyLive/Tiandy) не показывало видео при
# включённом обходе и работало при выключенном.
#
# Одной привязки правил к WAN недостаточно: в _fw_nfqws_post4 есть ветка без
# `-o $iface` (WAN не определился) — тогда правило висит на всех интерфейсах.
# Поэтому локалка засевается в сет nozapret, который проверяется в КАЖДОМ
# NFQUEUE-правиле через $IPSET_EXCLUDE и потому работает независимо от
# хостлистов и профилей (в т.ч. для Discord/STUN, у которого хостлиста нет).
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$HERE/files/S99zapret2.new"
ACTIONS="$HERE/webpanel/cgi/actions.sh"
API="$HERE/webpanel/cgi/api.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }

# --- 1. Полный набор локальных диапазонов засевается ------------------------
for net in '10\.0\.0\.0/8' '172\.16\.0\.0/12' '192\.168\.0\.0/16' \
           '127\.0\.0\.0/8' '169\.254\.0\.0/16'; do
    plain=$(printf '%s' "$net" | sed 's/\\//g')
    if grep -q -- "$net" "$INIT"; then
        ok "локалка засевается: $plain"
    else
        bad "локалка засевается: $plain" "диапазон отсутствует в S99zapret2.new"
    fi
done
for net in '::1/128' 'fc00::/7' 'fe80::/10'; do
    if grep -qF -- "$net" "$INIT"; then
        ok "локалка IPv6 засевается: $net"
    else
        bad "локалка IPv6 засевается: $net" "диапазон отсутствует"
    fi
done

# CGNAT намеренно НЕ засевается (это не локалка, а адреса провайдерского NAT).
# Проверяем САМИ переменные засева, а не весь файл: в комментарии рядом стоит
# объяснение, почему CGNAT исключён, и наивный греп по файлу ловил бы его.
seed_vars=$(grep -E '^Z2K_LOCAL_EXCLUDE[46]=' "$INIT")
if printf '%s' "$seed_vars" | grep -qF -- "100.64.0.0/10"; then
    bad "CGNAT не засевается по умолчанию" "100.64.0.0/10 попал в засев — решение было не включать"
else
    ok "CGNAT (100.64.0.0/10) намеренно не засевается"
fi

# --- 2. Засев вызывается из start_fw и идёт в правильные сеты ---------------
if grep -q 'z2k_seed_local_exclusions' "$INIT" && \
   awk '/^start_fw\(\)/{i=1} i{print} i&&/^\}/{exit}' "$INIT" | grep -q 'z2k_seed_local_exclusions'; then
    ok "засев вызывается из start_fw"
else
    bad "засев вызывается из start_fw" "функция не вызывается при старте файрвола"
fi
seed=$(awk '/^z2k_seed_local_exclusions\(\)/{i=1} i{print} i&&/^\}/{exit}' "$INIT")
if printf '%s' "$seed" | grep -q 'nozapret6' && printf '%s' "$seed" | grep -q 'family inet6'; then
    ok "IPv6-сет создаётся с family inet6"
else
    bad "IPv6-сет создаётся с family inet6" "nozapret6 создаётся неверно — add отвергнет адреса"
fi
if printf '%s' "$seed" | grep -q -- '-exist'; then
    ok "засев идемпотентен (-exist)"
else
    bad "засев идемпотентен (-exist)" "повторный старт будет сыпать ошибками"
fi

# --- 3. Пользовательский файл исключений создаётся --------------------------
if grep -q 'z2k_ensure_user_exclude_file' "$INIT"; then
    ok "пользовательский файл исключений создаётся при старте"
else
    bad "пользовательский файл исключений создаётся" "функция отсутствует"
fi
if grep -q 'zapret-hosts-user-exclude.txt' "$INIT"; then
    ok "используется апстримное имя файла (его читает ipset/def.sh)"
else
    bad "апстримное имя файла" "апстрим не подхватит список с другим именем"
fi

# --- 4. Бэкенд панели: добавление/удаление/валидация ------------------------
TMP="${TMPDIR:-/tmp}/z2k-excl-test.$$"
mkdir -p "$TMP/ipset"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ipset на машине с тестами может отсутствовать — хендлеры обязаны это переживать.
( ZAPRET2_DIR="$TMP" LISTS_DIR="$TMP/lists" EXCLUDE_FILE="$TMP/ipset/zapret-hosts-user-exclude.txt"
  export ZAPRET2_DIR LISTS_DIR EXCLUDE_FILE
  . "$ACTIONS" 2>/dev/null || true
  exclude_add "tiandycloud.com"  || exit 11
  exclude_add "203.0.113.0/24"   || exit 12
  exclude_add "2001:db8::1"      || exit 13
  exclude_add "tiandycloud.com"  || exit 14      # идемпотентность
  exclude_add "плохой домен"     2>/dev/null && exit 21
  exclude_add "-flag"            2>/dev/null && exit 22
  exclude_add 'a;rm -rf /'       2>/dev/null && exit 23
  exit 0 )
rc=$?
case "$rc" in
    0)  ok "бэкенд: добавление домена/подсети/IPv6 и отказ на мусоре" ;;
    1[1-4]) bad "бэкенд: добавление" "легитимная запись отвергнута (код $rc)" ;;
    2[1-3]) bad "бэкенд: валидация" "принят опасный ввод (код $rc)" ;;
    *)  bad "бэкенд" "неожиданный код $rc" ;;
esac

f="$TMP/ipset/zapret-hosts-user-exclude.txt"
[ -f "$f" ] && n=$(grep -c . "$f") || n=0
if [ "$n" = "3" ]; then
    ok "бэкенд: в файле ровно 3 записи (дубль не добавился)"
else
    bad "бэкенд: дедупликация" "в файле $n записей вместо 3"
fi

( ZAPRET2_DIR="$TMP" LISTS_DIR="$TMP/lists" EXCLUDE_FILE="$f"
  export ZAPRET2_DIR LISTS_DIR EXCLUDE_FILE
  . "$ACTIONS" 2>/dev/null || true
  exclude_delete "203.0.113.0/24" ) >/dev/null 2>&1
if grep -q "203.0.113" "$f" 2>/dev/null; then
    bad "бэкенд: удаление" "запись осталась в файле"
else
    ok "бэкенд: удаление работает"
fi

# --- 5. API-эндпоинты присутствуют ------------------------------------------
for ep in "GET /exclude" "POST /exclude/add" "POST /exclude/delete"; do
    if grep -qF -- "$ep" "$API"; then
        ok "API: $ep"
    else
        bad "API: $ep" "эндпоинт не зарегистрирован"
    fi
done

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
