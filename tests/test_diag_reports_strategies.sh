#!/bin/sh
# tests/test_diag_reports_strategies.sh — диагностика обязана говорить про
# стратегии, КОГДА ДВИЖОК РАБОТАЕТ.
#
# ЗАЧЕМ. Разбор конфигурации в z2k-diag.sh сидел в print_nfqws_start_failure, а
# та вызывается только из ветки «nfqws2 PIDs: (not running)». То есть в самом
# частом обращении в поддержку — «z2k запущен, а сайты блокируются» — сводка
# про стратегии не говорила НИЧЕГО.
#
# Полевой случай 2026-08-22 (диагностика z2k-diag-20260822-1010.txt): человек
# жалуется, что стратегии не применяются; в файле 219 строк, движок работает,
# правила на месте, счётчики растут — и ни одного слова о том, доехали ли
# стратегии до движка. Разговор начался с просьбы выполнить команду руками,
# ради которой диагностику и просят присылать.
#
# Здесь пинится три вещи:
#   1. помощник различает три состояния (норма / стратегий нет / ротации нет);
#   2. сводка «что не так» об этом ГОВОРИТ, а не прячет в середину файла;
#   3. проверка не уехала обратно в ветку «движок не запущен».
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="${Z2K_DIAG_UNDER_TEST:-$ROOT/files/z2k-diag.sh}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-diagstrat.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

[ -f "$SRC" ] || { printf '[FAIL] нет %s\n' "$SRC"; exit 1; }

# --- 1. Помощник различает состояния -----------------------------------------
awk '/^nfqws_strategy_counts\(\) \{/,/^\}/' "$SRC" > "$TMP/nsc.sh"
if grep -q '^nfqws_strategy_counts() {' "$TMP/nsc.sh"; then
    ok "nfqws_strategy_counts извлечена"
else
    no "nfqws_strategy_counts извлечена" "определение есть" "не найдено"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"; exit 1
fi

counts() {  # counts <строки командной строки через |>
    printf '%s' "$1" | tr '|' '\n' | tr '\n' '\0' > "$TMP/cmd.bin"
    env -i PATH=/usr/bin:/bin SB="$TMP" /bin/sh -c '
        . "$SB/nsc.sh"
        Z2K_DIAG_CMDLINE_SRC="$SB/cmd.bin" nfqws_strategy_counts
    ' 2>/dev/null
}

r=$(counts '--lua-desync=circular:key=a|--lua-desync=fake:x|--lua-desync=multisplit:y')
if [ "$r" = "3 1" ]; then ok "норма: 3 стратегии, 1 circular"; else no "норма" "3 1" "$r"; fi

r=$(counts '--filter-tcp=443|--hostlist=/x')
if [ "$r" = "0 0" ]; then ok "стратегий нет вовсе: 0 0"; else no "стратегий нет" "0 0" "$r"; fi

r=$(counts '--lua-desync=fake:x|--lua-desync=multisplit:y')
if [ "$r" = "2 0" ]; then ok "есть стратегии, но нет ротации: 2 0"; else no "нет ротации" "2 0" "$r"; fi

# Не прочитать — молчим, а не выдумываем ноль. Ноль здесь означал бы
# «стратегий нет», то есть диагностика соврала бы в самую опасную сторону.
if env -i PATH=/usr/bin:/bin SB="$TMP" /bin/sh -c '
        . "$SB/nsc.sh"
        Z2K_DIAG_CMDLINE_SRC="$SB/нет-такого-файла" nfqws_strategy_counts
    ' >/dev/null 2>&1; then
    no "нечитаемый источник -> отказ, а не ноль" "код возврата 1" "вернула успех"
else
    ok "нечитаемый источник даёт отказ, а не выдуманный ноль"
fi

# --- 2. Сводка «что не так» об этом говорит ----------------------------------
#
# Вырезаем блок проверки из print_verdict и исполняем с подставными pgrep и
# помощником: интересует не то, как считается, а то, что сводка реагирует.
awk '/# Стратегии доехали до движка\?/,/^    fi$/' "$SRC" > "$TMP/verdict.sh"
if [ -s "$TMP/verdict.sh" ] && grep -q '_add' "$TMP/verdict.sh"; then
    ok "блок проверки стратегий в сводке извлечён"
else
    no "блок проверки в сводке" "непустой блок с _add" "пусто"
fi

verdict() {  # verdict <что вернёт помощник>
    env -i PATH=/usr/bin:/bin SB="$TMP" CNT="$1" /bin/sh -c '
        issues=""
        _add() { issues="${issues}[!] $1
"; }
        pgrep() { return 0; }
        nfqws_strategy_counts() { [ -n "$CNT" ] || return 1; printf "%s" "$CNT"; }
        . "$SB/verdict.sh"
        printf "%s" "$issues"
    ' 2>/dev/null
}

case "$(verdict '0 0')" in
    *"НИ ОДНОЙ стратегии"*) ok "движок без стратегий — сводка кричит об этом" ;;
    *) no "движок без стратегий попадает в сводку" "строка про НИ ОДНОЙ стратегии" \
          "$(verdict '0 0')" ;;
esac

case "$(verdict '224 0')" in
    *circular*) ok "движок без circular — сводка сообщает про выключенный автоподбор" ;;
    *) no "движок без circular попадает в сводку" "строка про circular" "$(verdict '224 0')" ;;
esac

if [ -z "$(verdict '224 6')" ]; then
    ok "здоровый движок сводку не засоряет"
else
    no "здоровый движок молчит" "пусто" "$(verdict '224 6')"
fi

# Не прочитали — не выдумываем проблему.
if [ -z "$(verdict '')" ]; then
    ok "нечитаемое состояние не превращается в ложную тревогу"
else
    no "нечитаемое состояние молчит" "пусто" "$(verdict '')"
fi

# --- 3. Проверка не уехала обратно в ветку «движок не запущен» ---------------
#
# Ровно та регрессия, ради которой всё писалось: пока разбор жил только в
# print_nfqws_start_failure, работающий движок оставался неохваченным.
_line_helper=$(grep -n '^nfqws_strategy_counts() {' "$SRC" | head -1 | cut -d: -f1)
_line_fail=$(grep -n '^print_nfqws_start_failure() {' "$SRC" | head -1 | cut -d: -f1)
_line_serv=$(grep -n '^print_service() {' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_line_helper" ] && [ -n "$_line_serv" ] && [ "$_line_helper" -lt "$_line_serv" ]; then
    ok "помощник объявлен до потребителей (${_line_helper} < ${_line_serv})"
else
    no "помощник объявлен до потребителей" "строки по возрастанию" \
       "helper=${_line_helper:-нет} service=${_line_serv:-нет}"
fi

# В print_service вызов должен стоять в ВЕТКЕ РАБОТАЮЩЕГО движка, то есть выше
# else, за которым идёт print_nfqws_start_failure.
_serv_block=$(awk '/^print_service\(\) \{/,/^\}/' "$SRC")
_before_else=$(printf '%s\n' "$_serv_block" | awk '/^    else$/{exit} {print}')
if printf '%s\n' "$_before_else" | grep -q 'nfqws_strategy_counts'; then
    ok "в разделе service стратегии печатаются для РАБОТАЮЩЕГО движка"
else
    no "стратегии печатаются для работающего движка" "вызов до else" \
       "вызова нет — проверка снова только для лежащего демона"
fi

# И --dry-run по-прежнему не запускается при живом демоне: он грузит списки,
# а на больших списках РКН это заметная разовая память.
# Комментарии отсекаем: в этом же блоке про --dry-run написано словами, что он
# тут НЕ запускается, и наивный grep поймал бы собственное объяснение.
if printf '%s\n' "$_before_else" | grep -vE '^[[:space:]]*#' | grep -q -- '--dry-run'; then
    no "живой демон не платит за --dry-run" "без --dry-run" "появился --dry-run"
else
    ok "живой демон по-прежнему не платит за --dry-run"
fi

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
