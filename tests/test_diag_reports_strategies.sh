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
# стратегии до движка.
#
# ЧТО ИЗМЕНИЛОСЬ И ПОЧЕМУ ХАРНЕСС ПЕРЕПИСАН.
#
#   * Счёт переехал с ТОКЕНОВ на ПЛЕЧИ ротации. Прежний `grep -c '--lua-desync='`
#     мерил аргументы: пул, обрезанный до одного circular-заголовка (ротация
#     мертва, перебирать нечего), печатался как «1 (из них circular: 1)» —
#     ложный зелёный ровно на той форме поломки, ради которой всё писалось.
#     Помощник теперь печатает ТРИ числа и опирается на nfqws_cmdline.
#   * Ветка «в движке ноль circular» была недостижима: discord_udp приезжает с
#     зашитым circular всегда. Её место занял счёт ПО ПУЛАМ.
#   * Прежний харнесс сорсил вырезанный кусок print_verdict на ВЕРХНЕМ уровне,
#     а там объявлен `local`. Под bash это молча проходит, под dash (то есть
#     под /bin/sh в CI) — «local: not in a function», rc=2, оба ассерта
#     красные. Куски, содержащие local, оборачиваем в функцию.
#
# POSIX sh.

# Диалект вложенных оболочек задаётся набором, а не хардкодом: на macOS
# /bin/sh — это bash, в CI — dash, и один и тот же тест под ними ведёт себя
# по-разному. См. шапку tests/lib/common.sh.
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="${Z2K_DIAG_UNDER_TEST:-$ROOT/files/z2k-diag.sh}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-diagstrat.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

[ -f "$SRC" ] || { printf '[FAIL] нет %s\n' "$SRC"; exit 1; }

# --- 0. Помощники извлечены ---------------------------------------------------
#
# nfqws_strategy_counts и nfqws_reasm_state читают командную строку не сами, а
# через nfqws_cmdline — значит вынимать надо обе, иначе в песочнице отвалится
# не проверка, а харнесс.
awk '/^nfqws_cmdline\(\) \{/,/^\}/'         "$SRC" >  "$TMP/fns.sh"
awk '/^nfqws_strategy_counts\(\) \{/,/^\}/' "$SRC" >> "$TMP/fns.sh"
awk '/^nfqws_reasm_state\(\) \{/,/^\}/'     "$SRC" >> "$TMP/fns.sh"
awk '/^strategy_file_arms\(\) \{/,/^\}/'    "$SRC" >> "$TMP/fns.sh"

_missing=""
for _f in nfqws_cmdline nfqws_strategy_counts nfqws_reasm_state strategy_file_arms; do
    grep -q "^${_f}() {" "$TMP/fns.sh" || _missing="$_missing $_f"
done
if [ -z "$_missing" ]; then
    ok "все четыре помощника извлечены"
else
    no "помощники извлечены" "четыре определения" "не найдены:$_missing"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"; exit 1
fi

# --- 1. Счёт ПЛЕЧ, а не токенов ----------------------------------------------
counts() {  # counts <аргументы командной строки через |>
    printf '%s' "$1" | tr '|' '\n' | tr '\n' '\0' > "$TMP/cmd.bin"
    env -i PATH=/usr/bin:/bin SB="$TMP" "$Z2K_TEST_SH" -c '
        . "$SB/fns.sh"
        Z2K_DIAG_CMDLINE_SRC="$SB/cmd.bin" nfqws_strategy_counts
    ' 2>/dev/null
}

# Два профиля через --new: в первом два слота, во втором один (номер слота
# повторяется — это одно плечо, а не два). Итого 3 плеча в 2 пулах, мёртвых 0.
r=$(counts '--lua-desync=circular:key=a|--lua-desync=fake:strategy=1|--lua-desync=fake:strategy=2|--new|--lua-desync=circular:key=b|--lua-desync=fake:strategy=1|--lua-desync=multisplit:strategy=1')
if [ "$r" = "3 2 0" ]; then ok "норма: 3 плеча в 2 пулах, мёртвых нет"; else no "норма" "3 2 0" "$r"; fi

# ПОЛЕВОЙ СЛУЧАЙ 2026-08-23 (r-78, свежая установка с форматированием). Плечи
# профиля могут приезжать НЕ своими токенами, а импортом шаблона: у rkn_tcp в
# боевом конфиге стоит `--lua-desync=circular:...key=rkn_tcp... --import=...`,
# и ни одного strategy= в самом профиле нет. Проверка объявила такой пул мёртвым
# и написала человеку «переустановите z2k» — на исправном роутере, где все 117
# плеч были на месте. Импортирующий профиль мёртвым НЕ считается.
r=$(counts '--template=arsenal|--lua-desync=fake:strategy=1|--lua-desync=fake:strategy=2|--new|--lua-desync=circular:key=rkn_tcp|--import=arsenal')
if [ "$r" = "2 1 0" ]; then
    ok "пул с плечами из импортированного шаблона не считается мёртвым"
else
    no "импорт шаблона = живой пул" "2 1 0" "$r"
fi

# ГЛАВНОЕ. Пул, приехавший ОДНИМ circular-заголовком: circular есть, перебирать
# нечего. Старый счёт токенов рапортовал это как живой пул.
r=$(counts '--lua-desync=circular:key=a|--lua-desync=fake:strategy=1|--lua-desync=fake:strategy=2|--new|--lua-desync=circular:key=b')
if [ "$r" = "2 2 1" ]; then
    ok "обрезанный до заголовка пул виден как мёртвый (2 2 1)"
else
    no "мёртвый пул виден" "2 2 1" "$r — ротация потеряна, а счёт этого не показывает"
fi

r=$(counts '--filter-tcp=443|--hostlist=/x')
if [ "$r" = "0 0 0" ]; then ok "стратегий нет вовсе: 0 0 0"; else no "стратегий нет" "0 0 0" "$r"; fi

# Статический набор без слотов — это ОДНО плечо и никакой ротации, а не ноль:
# токены без strategy= действуют на весь профиль сразу.
r=$(counts '--lua-desync=fake:x|--lua-desync=multisplit:y')
if [ "$r" = "1 0 0" ]; then ok "статический набор без слотов = 1 плечо, 0 пулов"; else no "статический набор" "1 0 0" "$r"; fi

# Не прочитать — молчим, а не выдумываем ноль. Ноль здесь означал бы
# «стратегий нет», то есть диагностика соврала бы в самую опасную сторону.
if env -i PATH=/usr/bin:/bin SB="$TMP" "$Z2K_TEST_SH" -c '
        . "$SB/fns.sh"
        Z2K_DIAG_CMDLINE_SRC="$SB/нет-такого-файла" nfqws_strategy_counts
    ' >/dev/null 2>&1; then
    no "нечитаемый источник -> отказ, а не ноль" "код возврата 1" "вернула успех"
else
    ok "нечитаемый источник даёт отказ, а не выдуманный ноль"
fi

# --- 2. Гейт reasm виден по ЖИВОЙ командной строке ---------------------------
#
# Флаг ставит init, но только если движок его знает. Патч-канал бинарники не
# обновляет — значит роутер спокойно живёт с новым init и старым движком, и
# тогда большой ClientHello по-прежнему виснет, хотя релиз обещает обратное.
reasm() {
    printf '%s' "$1" | tr '|' '\n' | tr '\n' '\0' > "$TMP/cmd.bin"
    env -i PATH=/usr/bin:/bin SB="$TMP" "$Z2K_TEST_SH" -c '
        . "$SB/fns.sh"
        Z2K_DIAG_CMDLINE_SRC="$SB/cmd.bin" nfqws_reasm_state
    ' 2>/dev/null
}
r=$(reasm '--user=nobody|--reasm-disable=tls_client_hello|--new')
[ "$r" = "on" ] && ok "reasm: флаг с типом → on" || no "reasm: флаг с типом" "on" "$r"
r=$(reasm '--user=nobody|--reasm-disable=quic_initial,tls_client_hello')
[ "$r" = "on" ] && ok "reasm: тип в списке через запятую → on" || no "reasm: список типов" "on" "$r"
r=$(reasm '--user=nobody|--reasm-disable')
[ "$r" = "on" ] && ok "reasm: голый --reasm-disable выключает всё, включая TLS CH → on" \
                || no "reasm: голый флаг" "on" "$r"
# Ложное срабатывание по подстроке: tls_client_hello живёт ещё и в --payload=.
r=$(reasm '--user=nobody|--payload=tls_client_hello|--lua-desync=fake:x')
[ "$r" = "off" ] && ok "reasm: tls_client_hello только в --payload= → off (не путаем с флагом)" \
                 || no "reasm: подстрока в --payload=" "off" "$r"

# --- 3. Плечи в ФАЙЛЕ пула ----------------------------------------------------
#
# Раньше здесь считались строки, а пул пишется одной строкой — поэтому у любого
# файла всегда стояло «1 строк»: и у живого, и у обрезанного до заголовка.
arms_of() {
    printf '%s' "$1" > "$TMP/pool.txt"
    env -i PATH=/usr/bin:/bin SB="$TMP" "$Z2K_TEST_SH" -c '
        . "$SB/fns.sh"; strategy_file_arms "$SB/pool.txt"
    ' 2>/dev/null
}
r=$(arms_of '--lua-desync=circular:key=yt_tcp:nld=2 --lua-desync=fake:strategy=1 --lua-desync=fake:strategy=2')
[ "$r" = "2" ] && ok "файл пула: 2 плеча" || no "файл пула: 2 плеча" "2" "$r"
r=$(arms_of '--lua-desync=circular:key=yt_tcp:nld=2')
[ "$r" = "0" ] && ok "файл пула из одного circular-заголовка: 0 плеч" \
               || no "обрезанный файл пула" "0" "$r — раньше печаталось «1 строк»"
r=$(arms_of '--lua-desync=fake:blob=fake_default_tls:repeats=6')
[ "$r" = "1" ] && ok "статический набор в файле: 1 плечо" || no "статический набор в файле" "1" "$r"

# --- 4. Сводка «что не так» об этом говорит ----------------------------------
#
# Вырезаем блок проверки из print_health и исполняем с подставными помощниками:
# интересует не то, как считается, а то, что сводка реагирует.
#
# Блок объявляет `local`, поэтому исполняем его ВНУТРИ функции: на верхнем
# уровне dash отвечает «local: not in a function» и валит всю оболочку.
awk '/# Стратегии доехали до движка\?/,/^    fi$/' "$SRC" > "$TMP/verdict.sh"
if [ -s "$TMP/verdict.sh" ] && grep -q '_add' "$TMP/verdict.sh"; then
    ok "блок проверки стратегий в сводке извлечён"
else
    no "блок проверки в сводке" "непустой блок с _add" "пусто"
fi

verdict() {  # verdict <что вернёт счётчик> [что вернёт гейт reasm]
    env -i PATH=/usr/bin:/bin SB="$TMP" CNT="$1" RSM="${2:-on}" "$Z2K_TEST_SH" -c '
        issues=""
        _add() { issues="${issues}[!] $1
"; }
        _nfq_pid=4242
        nfqws_strategy_counts() { [ -n "$CNT" ] || return 1; printf "%s" "$CNT"; }
        nfqws_reasm_state() { [ -n "$RSM" ] || return 1; printf "%s" "$RSM"; }
        _b() { . "$SB/verdict.sh"; }
        _b
        printf "%s" "$issues"
    ' 2>/dev/null
}

case "$(verdict '0 0 0')" in
    *"НИ ОДНОГО плеча"*) ok "движок без плеч — сводка кричит об этом" ;;
    *) no "движок без плеч попадает в сводку" "строка про НИ ОДНОГО плеча" "$(verdict '0 0 0')" ;;
esac

case "$(verdict '224 3 1')" in
    *"мёртвой ротацией"*) ok "пул с circular без плеч — сводка называет мёртвую ротацию" ;;
    *) no "мёртвая ротация в сводке" "строка про мёртвую ротацию" "$(verdict '224 3 1')" ;;
esac

case "$(verdict '224 0 0')" in
    *circular*) ok "движок без circular — сводка сообщает про выключенный автоподбор" ;;
    *) no "движок без circular попадает в сводку" "строка про circular" "$(verdict '224 0 0')" ;;
esac

if [ -z "$(verdict '224 3 0')" ]; then
    ok "здоровый движок сводку не засоряет"
else
    no "здоровый движок молчит" "пусто" "$(verdict '224 3 0')"
fi

# Не прочитали — не выдумываем проблему.
if [ -z "$(verdict '')" ]; then
    ok "нечитаемое состояние не превращается в ложную тревогу"
else
    no "нечитаемое состояние молчит" "пусто" "$(verdict '')"
fi

# Отказ гейта reasm обязан попасть в ту же сводку: init про него сказал только
# в консоль и в syslog, а человек присылает диагностику.
case "$(verdict '224 3 0' off)" in
    *ClientHello*) ok "гейт reasm отказал — сводка называет причину «curl работает, браузер нет»" ;;
    *) no "отказ гейта reasm в сводке" "строка про ClientHello" "$(verdict '224 3 0' off)" ;;
esac

# --- 5. То же самое видно и в разделе service --------------------------------
#
# Сводка — это заголовок, а раздел service — то, что читает тот, кто разбирает
# отчёт целиком. Обе половины должны говорить одно и то же.
awk '/^print_service\(\) \{/,/^\}/' "$SRC" > "$TMP/service.sh"
_serv_before_else=$(awk '/^    else$/{exit} {print}' "$TMP/service.sh")
for _needle in 'плеч ротации' 'пулы без плеч' 'reasm TLS CH'; do
    if printf '%s\n' "$_serv_before_else" | grep -q "$_needle"; then
        ok "service печатает «${_needle}» для РАБОТАЮЩЕГО движка"
    else
        no "service печатает «${_needle}»" "строка до else" "нет — состояние видно только в сводке"
    fi
done

# --- 6. D7: PID ищется ОДИН раз на секцию и передаётся аргументом -------------
#
# Было ~6 обходов /proc через pgrep на отчёт, и, что важнее, соседние строки
# могли описывать РАЗНЫЕ процессы, если движок рестартанул посреди дампа.
awk '/^print_health\(\) \{/,/^\}/' "$SRC" > "$TMP/health.sh"
_d7=$(env -i PATH=/usr/bin:/bin SB="$TMP" ZD="$TMP/zd" "$Z2K_TEST_SH" -c '
    mkdir -p "$ZD/extra_strats/TCP/RKN"
    : > "$ZD/extra_strats/TCP/RKN/List.txt"
    ZAPRET2_DIR="$ZD"
    . "$SB/fns.sh"
    # Считаем ТОЛЬКО поиски движка: телеграм и WARP ищутся своими pgrep, но их
    # ветки в песочнице не открываются, и мешать счёту они не должны.
    pgrep() {
        case "$*" in *nfq2/nfqws2*) printf "%s\n" "pgrep $*" >> "$SB/pgrep.log"; printf "4242\n" ;; esac
        return 0
    }
    # Через что реально читается командная строка — и с каким аргументом.
    nfqws_cmdline() { printf "%s\n" "arg=[${1:-}]" >> "$SB/cmdline.log"; printf -- "--lua-desync=circular:key=a\n--lua-desync=fake:strategy=1\n"; }
    bitmap_port_ok() { printf yes; }
    clock_skew_vs_relay() { printf 0; }
    tg_redirect_counts() { printf "1 1"; }
    mount() { printf " /opt \n"; }
    df() { printf "x\nx x x 999999\n"; }
    : > "$SB/pgrep.log"; : > "$SB/cmdline.log"
    print_health() { :; }
    . "$SB/health.sh"
    print_health >/dev/null 2>&1
    printf "pgrep=%s cmdline=%s пусто=%s" \
        "$(wc -l < "$SB/pgrep.log" | tr -d " ")" \
        "$(wc -l < "$SB/cmdline.log" | tr -d " ")" \
        "$(grep -c "arg=\[\]" "$SB/cmdline.log")"
' 2>/dev/null)
case "$_d7" in
    "pgrep=1 "*) ok "print_health ищет PID движка ровно один раз (было ~4)" ;;
    *) no "print_health ищет PID один раз" "pgrep=1" "$_d7" ;;
esac
case "$_d7" in
    *"пусто=0") ok "помощники получают PID аргументом, а не ищут его сами" ;;
    *) no "PID передаётся аргументом" "пусто=0" "$_d7 — помощник снова ищет процесс сам" ;;
esac

# --- 7. Проверка не уехала обратно в ветку «движок не запущен» ---------------
#
# Ровно та регрессия, ради которой всё писалось: пока разбор жил только в
# print_nfqws_start_failure, работающий движок оставался неохваченным.
_line_helper=$(grep -n '^nfqws_strategy_counts() {' "$SRC" | head -1 | cut -d: -f1)
_line_serv=$(grep -n '^print_service() {' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_line_helper" ] && [ -n "$_line_serv" ] && [ "$_line_helper" -lt "$_line_serv" ]; then
    ok "помощник объявлен до потребителей (${_line_helper} < ${_line_serv})"
else
    no "помощник объявлен до потребителей" "строки по возрастанию" \
       "helper=${_line_helper:-нет} service=${_line_serv:-нет}"
fi

if printf '%s\n' "$_serv_before_else" | grep -q 'nfqws_strategy_counts'; then
    ok "в разделе service стратегии печатаются для РАБОТАЮЩЕГО движка"
else
    no "стратегии печатаются для работающего движка" "вызов до else" \
       "вызова нет — проверка снова только для лежащего демона"
fi

# И --dry-run по-прежнему не запускается при живом демоне: он грузит списки,
# а на больших списках РКН это заметная разовая память.
# Комментарии отсекаем: в этом же блоке про --dry-run написано словами, что он
# тут НЕ запускается, и наивный grep поймал бы собственное объяснение.
if printf '%s\n' "$_serv_before_else" | grep -vE '^[[:space:]]*#' | grep -q -- '--dry-run'; then
    no "живой демон не платит за --dry-run" "без --dry-run" "появился --dry-run"
else
    ok "живой демон по-прежнему не платит за --dry-run"
fi

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
