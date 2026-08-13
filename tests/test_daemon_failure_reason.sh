#!/bin/sh
# tests/test_daemon_failure_reason.sh — при отказе старта видно ПОЧЕМУ.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. 2026-08-13, полевой случай: у человека перестал работать
# обход, при перезапуске в консоли — «ERROR: Daemon 1 failed to start» и больше
# ни слова. Конфиг оказался исправен (прогнали его текст через тот же nfqws2 на
# заведомо рабочем роутере: 5 профилей, «command line parameters verified»),
# то есть причина была в окружении — но узнать это было неоткуда. Кончилось
# слепым перезапуском роутера.
#
# Причина немоты: демон запускался как `$2 $3 >/dev/null 2>&1 &`. nfqws2 честно
# писал, что ему не понравилось, а мы это стирали.
#
# ЧТО ОХРАНЯЕТСЯ:
#
#   1. stderr демона не выбрасывается в /dev/null.
#   2. При отказе он ПЕЧАТАЕТСЯ, а не просто копится в файле.
#   3. Если демон не сказал ничего — спрашиваем движок через --dry-run.
#      --dry-run обязан быть без побочных эффектов: очередь он не занимает.
#   4. При успешном старте файл не остаётся в /tmp (tmpfs = оперативка).
#   5. Валидатор, на который ссылается сообщение об отказе, умеет
#      воспроизвести отказ — то есть тоже зовёт --dry-run.
#   6. Диагностика показывает причину сама: человек присылает её, а не
#      получает в ответ ещё одну команду.
#   7. Диагностика считает ОБЕ половины правил NFQUEUE. Входящие живут в
#      INPUT+FORWARD, и раньше их не было видно вовсе.
#
# POSIX sh. Логика run_daemon исполняется на подставном «демоне» — настоящий
# nfqws2 здесь не нужен и не запускается.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
INIT="$ROOT/files/S99zapret2.new"
VALID="$ROOT/files/z2k-config-validator.sh"
DIAG="$ROOT/files/z2k-diag.sh"

for f in "$INIT" "$VALID" "$DIAG"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# Комментарии не считаются доказательством: три раза тесты зеленели на прозе,
# описывающей уже снятый дефект.
code_of() { grep -v '^[[:space:]]*#' "$1"; }

# --- 1. stderr больше не выбрасывается ----------------------------------------
if code_of "$INIT" | grep -q '\$2 \$3 >/dev/null 2>&1 &'; then
    no "stderr демона сохраняется" "2>файл" "2>&1 в /dev/null — причина стирается"
else
    ok "stderr демона не выбрасывается в /dev/null"
fi
if code_of "$INIT" | grep -q '\$2 \$3 >/dev/null 2>"\$ERRFILE" &'; then
    ok "stderr уходит в файл на время старта"
else
    no "stderr уходит в файл" 'canary 2>"$ERRFILE"' "нет"
fi

# --- 2. Логика run_daemon ИСПОЛНЯЕТСЯ -----------------------------------------
#
# Вынимаем настоящие функции из init и гоняем на подставном демоне: один падает
# с сообщением, другой падает молча, третий живёт.
_fns=$(awk '/^z2k_daemon_err_file\(\)/,/^}/' "$INIT"; awk '/^z2k_daemon_explain\(\)/,/^}/' "$INIT")
case "$_fns" in
    *z2k_daemon_err_file*z2k_daemon_explain*) ok "функции разбора причины найдены в init" ;;
    *) no "функции причины" "err_file+explain" "не найдены"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1 ;;
esac

# Демон, который ругается и умирает.
cat > "$TMP/loud" <<'STUB'
#!/bin/sh
case " $* " in *" --dry-run "*) echo "dry: bad blob 'nope'" >&2; exit 1 ;; esac
echo "unknown blob 'nope'" >&2
exit 1
STUB
# Демон, который умирает молча (stderr пуст — причина только из --dry-run).
cat > "$TMP/mute" <<'STUB'
#!/bin/sh
case " $* " in *" --dry-run "*) echo "dry: strategy numbers must be contiguous" >&2; exit 1 ;; esac
exit 1
STUB
# Демон, у которого параметры верны, а старт всё равно не удался.
cat > "$TMP/ok_args" <<'STUB'
#!/bin/sh
case " $* " in *" --dry-run "*) echo "command line parameters verified"; exit 0 ;; esac
exit 1
STUB
chmod +x "$TMP/loud" "$TMP/mute" "$TMP/ok_args"

# Текст функций — в файл и source. Через heredoc нельзя: он раскроет $ внутри
# самих функций, и проверяться будет не то, что лежит в init.
printf '%s\n' "$_fns" > "$TMP/fns.sh"

explain() {  # $1 - подставной демон, $2 - содержимое err-файла
    printf '%s' "$2" > "$TMP/e.err"
    QNUM=200 sh -c '. "$1"; z2k_daemon_explain "$2" "$3" "--qnum=200"' \
        _ "$TMP/fns.sh" "$TMP/e.err" "$1" 2>&1
}

_r=$(explain "$TMP/loud" "unknown blob 'nope'")
case "$_r" in
    *"unknown blob 'nope'"*) ok "сказанное демоном доходит до человека дословно" ;;
    *) no "вывод демона" "unknown blob" "$_r" ;;
esac

_r=$(explain "$TMP/mute" "")
case "$_r" in
    *"strategy numbers must be contiguous"*) ok "молчаливый отказ добирается через --dry-run" ;;
    *) no "молчаливый отказ" "причина из --dry-run" "$_r" ;;
esac

_r=$(explain "$TMP/ok_args" "")
case "$_r" in
    *"разобраны без ошибок"*)
        case "$_r" in
            *nfnetlink_queue*) ok "верные параметры → говорим, что дело не в конфиге, и куда смотреть" ;;
            *) no "подсказка про очередь" "nfnetlink_queue" "$_r" ;;
        esac ;;
    *) no "верные параметры" "«дело не в них»" "$_r" ;;
esac

# --dry-run обязан быть безвредным: если он вдруг начнёт занимать очередь,
# диагностика на живом роутере отберёт её у работающего демона.
if code_of "$INIT" | grep -q 'dry-run.*--qnum=200\|--qnum=200.*dry-run'; then
    no "--dry-run не трогает боевую очередь" "без --qnum=200" "запуск с боевым номером"
else
    ok "--dry-run не заявляет боевую очередь"
fi

# --- 3. Успешный старт не оставляет файла в tmpfs ------------------------------
_succ=$(awk '/if z2k_pid_running "\$PID"; then/,/^    fi$/' "$INIT")
case "$_succ" in
    *'rm -f "$ERRFILE"'*) ok "при успехе err-файл удаляется — tmpfs не копится" ;;
    *) no "уборка при успехе" 'rm -f $ERRFILE' "нет" ;;
esac
case "$_succ" in
    *z2k_daemon_explain*) ok "при отказе причина печатается" ;;
    *) no "печать причины" "вызов z2k_daemon_explain" "нет" ;;
esac

# --- 4. Валидатор умеет воспроизвести отказ ------------------------------------
if code_of "$VALID" | grep -q 'dry-run'; then
    ok "валидатор спрашивает сам движок"
else
    no "валидатор зовёт --dry-run" "есть" "нет — команда из сообщения об ошибке бесполезна"
fi
if code_of "$VALID" | grep -q 'check_nfqws2_dry_run$'; then
    ok "проверка движком включена в прогон, а не просто объявлена"
else
    no "вызов check_nfqws2_dry_run" "в main" "функция объявлена, но не вызывается"
fi

# --- 5. Диагностика показывает причину сама ------------------------------------
if code_of "$DIAG" | grep -q 'print_nfqws_start_failure'; then
    ok "диагностика печатает причину отказа"
else
    no "причина в диагностике" "print_nfqws_start_failure" "нет"
fi
# Дорого и незачем: если демон жив, конфигурация заведомо разобралась.
_dsec=$(awk '/^print_nfqws_start_failure\(\)/,/^}/' "$DIAG")
[ -n "$_dsec" ] && ok "секция причины существует отдельной функцией" \
                || no "секция причины" "функция" "нет"
if code_of "$DIAG" | grep -A 3 "printf 'nfqws2 PIDs       : (not running)" | grep -q 'print_nfqws_start_failure'; then
    ok "причина считается только когда демон лежит"
else
    no "--dry-run только при отказе" "вызов в ветке not running" "вызывается всегда/никогда"
fi

# --- 6. Обе половины правил NFQUEUE --------------------------------------------
if code_of "$DIAG" | grep -q 'NFQUEUE prerouting'; then
    no "входящие правила видны" "INPUT+FORWARD" "считается неиспользуемый PREROUTING"
else
    ok "бесполезный счёт PREROUTING убран"
fi
if code_of "$DIAG" | grep -q 'mangle -L INPUT' && code_of "$DIAG" | grep -q 'mangle -L FORWARD'; then
    ok "входящая половина правил считается (INPUT+FORWARD)"
else
    no "входящие правила" "INPUT и FORWARD" "не считаются"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
