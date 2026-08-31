#!/bin/sh
# tests/test_au_cleanup_step.sh — шаг обновления cleanup-ip-hosts обязан
# НАХОДИТЬ свою функцию.
#
# Повод: жалоба 31.08.2026. Шаг писал в журнал «функция недоступна, пропускаю»
# и не делал ничего — у всех, всегда. Функция жила в lib/install.sh, а апдейтер
# подключает только utils.sh, config_official.sh и strategies.sh. Проверка на
# наличие была, а подключения не было, и молчаливый пропуск выглядел штатно.
#
# Здесь сторожим ровно связку: там ли функция, где апдейтер её ищет.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

# 1. Функция лежит в том файле, который апдейтер подключает.
if grep -q '^cleanup_legacy_ip_hosts()' "$DIR/lib/utils.sh"; then
    ok "cleanup_legacy_ip_hosts живёт в utils.sh"
else
    bad "cleanup_legacy_ip_hosts не в utils.sh — апдейтер её не найдёт"
fi

# 2. Апдейтер подключает utils.sh на своём пути загрузки генераторов.
if grep -q 'utils.sh' "$DIR/lib/auto_update.sh"; then
    ok "апдейтер подключает utils.sh"
else
    bad "апдейтер не подключает utils.sh"
fi

# 3. Сам шаг сперва подключает библиотеки, а потом проверяет наличие.
if sed -n '/^au_step_cleanup_ip_hosts()/,/^}/p' "$DIR/lib/auto_update.sh" \
   | grep -q 'au_gen_libs_source'; then
    ok "шаг подключает библиотеки перед проверкой"
else
    bad "шаг проверяет наличие, не подключив библиотеки — вернётся молчаливый пропуск"
fi

# 4. Живая проверка: подключаем ровно так, как это делает апдейтер, и смотрим,
#    что функция определилась.
OUT=$(cd "$DIR" && sh -c '
    ZAPRET2_DIR="'"$DIR"'"
    . ./lib/utils.sh >/dev/null 2>&1
    command -v cleanup_legacy_ip_hosts >/dev/null 2>&1 && echo found
' 2>/dev/null)
if [ "$OUT" = "found" ]; then
    ok "после подключения utils.sh функция определена"
else
    bad "utils.sh подключён, а функции нет"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
