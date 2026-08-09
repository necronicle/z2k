#!/bin/sh
# tests/test_strategy_injection.sh — строка стратегии не должна становиться командой.
#
# ПОЧЕМУ ЭТОТ ТЕСТ СУЩЕСТВУЕТ. Тело пула стратегий, которое приходит из
# вебпанели, попадает в конфиг как  NFQWS2_OPT="<тело>"  (lib/config_official.sh),
# а конфиг сорсится root-овым init-скриптом S99zapret2. Одной кавычки внутри
# тела достаточно, чтобы закрыть присваивание и выполнить что угодно от root:
#
#     --dpi-desync=fake " ; touch /tmp/PWNED ; : "
#
# Это было воспроизведено 2026-08-08, а не выведено из чтения кода. Отдельная
# строка из кавычки не нужна: z2k_custom_strategy склеивает тело в ОДНУ строку,
# и кавычка срабатывает из середины.
#
# Вектор: любой не-браузерный клиент в LAN. Origin-guard панели защищает от
# браузерного CSRF и по построению не мешает curl'у поставить нужный заголовок.
#
# Тест держит ДВЕ вещи:
#   1) фильтр отбивает опасные символы;
#   2) сам механизм подстановки всё ещё таков, что кавычка ломает конфиг —
#      то есть фильтр остаётся нужным, а не охраняет уже исчезнувшую проблему.
# POSIX sh.

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ACTIONS="$ROOT/webpanel/cgi/actions.sh"

[ -f "$ACTIONS" ] || { printf '[FAIL] нет %s\n' "$ACTIONS"; exit 1; }

# --- 1. Фильтр на месте и делает то, что заявлено ----------------------------

# Вытаскиваем функцию из actions.sh, не сорся весь файл (он тянет окружение CGI).
FN=$(awk '/^_strategy_body_is_safe\(\) \{/,/^\}/' "$ACTIONS")
if [ -z "$FN" ]; then
    no "_strategy_body_is_safe определена в actions.sh" "функция есть" "не найдена"
    printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
    exit 1
fi
ok "_strategy_body_is_safe определена в actions.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-inj-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

eval "$FN"

check_rejected() {
    _label="$1"; _payload="$2"
    printf '%s\n' "$_payload" > "$TMP/body.txt"
    if _strategy_body_is_safe "$TMP/body.txt"; then
        no "$_label" "отбито" "пропущено"
    else
        ok "$_label"
    fi
}

check_rejected 'кавычка отбита'            '--dpi-desync=fake " ; touch /tmp/PWNED ; : "'
check_rejected 'обратная кавычка отбита'   '--dpi-desync=fake `id`'
check_rejected 'подстановка $( ) отбита'   '--dpi-desync=fake $(id)'
check_rejected 'голый $ отбит'             '--dpi-desync=fake $HOME'
check_rejected 'кавычка в середине опции'  '--filter-l7=a"b'

# Управляющий байт (перевод строки внутри значения имитируем табом+CR).
printf -- '--dpi-desync=fake\r\n' > "$TMP/body.txt"
if _strategy_body_is_safe "$TMP/body.txt"; then
    no "управляющий байт отбит" "отбито" "пропущено"
else
    ok "управляющий байт отбит"
fi

# --- 2. Законные строки НЕ отбиваются ----------------------------------------

check_allowed() {
    _label="$1"; _payload="$2"
    printf '%s\n' "$_payload" > "$TMP/body.txt"
    if _strategy_body_is_safe "$TMP/body.txt"; then
        ok "$_label"
    else
        no "$_label" "пропущено" "отбито (фильтр слишком широк)"
    fi
}

check_allowed 'обычная стратегия проходит' \
    '--dpi-desync=fake,split2 --dpi-desync-ttl=3 --dpi-desync-fooling=badseq'
check_allowed 'lua-desync с двоеточиями проходит' \
    '--lua-desync=circular:fails=3:time=60:key=yt_tcp:nld=2'
check_allowed 'диапазоны и запятые проходят' \
    '--filter-udp=50000-50100,1400,3478-3481 --out-range=-d4 --payload=stun'
check_allowed 'комментарий проходит' '# моя стратегия'

# --- 3. Механизм всё ещё уязвим без фильтра ----------------------------------
#
# Если однажды генератор начнёт экранировать значение сам, этот блок покраснеет
# и скажет: фильтр больше не единственная защита, проверьте, нужен ли он.
VAL=$(printf -- '--dpi-desync=fake " ; touch %s/PWNED ; : "\n' "$TMP" \
      | awk '{ sub(/\r$/,""); sub(/^[[:space:]]*#.*$/,"") } NF { printf "%s ", $0 }' \
      | sed 's/[[:space:]]*$//')
cat > "$TMP/config" <<CFG
NFQWS2_OPT="
$VAL
"
CFG
( . "$TMP/config" ) >/dev/null 2>&1 || true
if [ -f "$TMP/PWNED" ]; then
    ok "подстановка по-прежнему исполняема без фильтра — фильтр нужен"
else
    no "подстановка по-прежнему исполняема без фильтра — фильтр нужен" \
       "инъекция срабатывает (значит фильтр — единственная защита)" \
       "не сработала: генератор начал экранировать сам, пересмотрите фильтр"
fi

# --- 4. Фильтр вызывается ДО генерации конфига и dry-run ---------------------
#
# Порядок важен: если проверку опустить ниже, тело успеет попасть в конфиг
# теневого прогона, а полагаться на строгость чужого парсера как на границу
# безопасности нельзя.
_line_safe=$(grep -n '_strategy_body_is_safe "\$cand"' "$ACTIONS" | head -1 | cut -d: -f1)
_line_regen=$(grep -n 'regenerate_config_to "\$tmpcfg"' "$ACTIONS" | head -1 | cut -d: -f1)
if [ -n "$_line_safe" ] && [ -n "$_line_regen" ] && [ "$_line_safe" -lt "$_line_regen" ]; then
    ok "фильтр стоит до генерации конфига (строка $_line_safe < $_line_regen)"
else
    no "фильтр стоит до генерации конфига" "проверка раньше генерации" \
       "safe=$_line_safe regen=$_line_regen"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
