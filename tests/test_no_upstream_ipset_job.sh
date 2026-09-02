#!/bin/sh
# tests/test_no_upstream_ipset_job.sh — планировщик не должен запускать
# апстримную пересборку ipset'ов.
#
# ЧТО БЫЛО. Задача «06:00 ipset/get_config.sh» переехала в планировщик из
# cron'а вместе с остальными и годами считалась безобидной «IP-set resolution».
# На деле в z2k (MODE_FILTER=hostlist) сеты zapret/ipban не используются нигде,
# а get_config.sh -> get_ipban.sh -> create_ipset.sh делает `ipset flush
# nozapret` и пересобирает сет из одного вывода mdig по файлу
# zapret-hosts-user-exclude.txt. Каждую ночь из nozapret исчезали:
#   * локальные диапазоны (10/8, 172.16/12, 192.168/16 ...) — засев z2k, ради
#     которого чинили камеры EasyLive; на роутере владельца 02.09.2026 сет
#     стоял ПУСТЫМ с 06:00 до 08:09, пока хук NDM не перезапустил файрвол;
#   * адреса с комментарием в конце строки — mdig не понимает такую строку и
#     молча выбрасывает её вместе с адресом (отчёт с точки babka: из 14
#     адресов в сете остались 4);
#   * записи, добавленные панелью «сразу» — они живут в сете до ближайшего flush.
# А доменные строки, которые z2k намеренно игнорирует, mdig РАЗРЕШАЛ — и в
# исключения уезжал общий адрес CDN со всеми чужими именами за ним.
#
# Единственный законный читатель файла — засев z2k при старте файрвола и
# панель. Тест исполняет настоящий планировщик в песочнице: подставные `date`
# (всегда 06:00) и `sleep` (останавливает цикл после первого тика), а вместо
# ipset/get_config.sh лежит маркер. Маркер не должен сработать, в журнале не
# должно быть «fire get-config».
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHED="$ROOT/files/z2k-scheduler.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }

[ -f "$SCHED" ] || { printf '[FAIL] нет %s\n' "$SCHED"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2knojob.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

SB="$TMP/opt/zapret2"
mkdir -p "$SB/ipset" "$TMP/bin" "$TMP/log" "$TMP/run"
MARK="$TMP/get_config.called"

# Маркер на месте апстримного скрипта. Если планировщик его дёрнет — файл
# появится.
printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$MARK" > "$SB/ipset/get_config.sh"
chmod 755 "$SB/ipset/get_config.sh"

# Подставные утилиты: часы стоят на 06:00; sleep гасит цикл после первого тика.
REAL_DATE=$(command -v date)
REAL_SLEEP=$(command -v sleep)
cat > "$TMP/bin/date" <<EOF
#!/bin/sh
case "\$1" in
    +%H:%M) echo 06:00 ;;
    *) exec "$REAL_DATE" "\$@" ;;
esac
EOF
cat > "$TMP/bin/sleep" <<EOF
#!/bin/sh
kill -TERM \$PPID 2>/dev/null
exit 0
EOF
chmod 755 "$TMP/bin/date" "$TMP/bin/sleep"

# Копия планировщика с путями, переведёнными в песочницу. Сам код задач не
# трогаем — исполняется ровно та ветка case, что и на роутере.
LOGF="$TMP/log/z2k-scheduler.log"
sed -e "s|^export PATH=|export PATH=$TMP/bin:|" \
    -e "s|^ZAPRET2_DIR=\"/opt/zapret2\"|ZAPRET2_DIR=\"$SB\"|" \
    -e "s|^LOG=\"/opt/var/log/z2k-scheduler.log\"|LOG=\"$LOGF\"|" \
    -e "s|^TMP_STATE=\"/tmp/.z2k-scheduler-state\"|TMP_STATE=\"$TMP/run/tmpstate\"|" \
    -e "s|/opt/etc/init.d/S99zapret2|$SB/S99-absent|g" \
    -e "s|/tmp/z2k-sni-refresh.ts|$TMP/run/sni.ts|g" \
    -e "s|/tmp/z2k-scheduler.mtime|$TMP/run/sched.mtime|g" \
    "$SCHED" > "$TMP/sched.sh"
# Флаг «линия измерена», чтобы ветка повторной пробы не искала бинарник.
mkdir -p "$SB/state"; echo 1 > "$SB/state/tcp16.flag"
: > "$LOGF"

# Сторож: если цикл не остановился сам — гасим через 10 секунд.
( Z2K_SCHED_PIDFILE="$TMP/run/pid" Z2K_LOG_DIR="$TMP/log" sh "$TMP/sched.sh" >/dev/null 2>&1 ) &
SPID=$!
i=0
while kill -0 "$SPID" 2>/dev/null && [ "$i" -lt 100 ]; do "$REAL_SLEEP" 0.1; i=$((i+1)); done
kill -0 "$SPID" 2>/dev/null && { kill -TERM "$SPID" 2>/dev/null; bad "тик планировщика завершился сам" "цикл не остановился за 10 с"; }
"$REAL_SLEEP" 0.5   # фоновые run_task успевают дописать

# --- 1. Тик вообще случился (иначе остальное — пустая зелень) -----------------
if [ -s "$LOGF" ] || [ -f "$TMP/run/tmpstate" ]; then
    ok "планировщик отработал тик в песочнице"
else
    bad "планировщик отработал тик в песочнице" "ни журнала, ни состояния — стенд не запустился"
fi

# --- 2. Апстримный get_config.sh не вызывается ------------------------------
if [ -f "$MARK" ]; then
    bad "в 06:00 апстримный ipset/get_config.sh не запускается" \
        "маркер сработал — сет nozapret снова будет сбрасываться каждую ночь"
else
    ok "в 06:00 апстримный ipset/get_config.sh не запускается"
fi
if grep -q 'get-config' "$LOGF" 2>/dev/null; then
    bad "в журнале нет задачи get-config" "$(grep 'get-config' "$LOGF" | head -1)"
else
    ok "в журнале нет задачи get-config"
fi

# --- 3. Ни один файл z2k не зовёт апстримные ipset-скрипты -------------------
# Планировщик — не единственное место, откуда такая задача могла бы вернуться
# (cron-строки инсталлятора, панель, обновление списков).
hits=$(grep -rn 'ipset/get_config\.sh\|ipset/get_exclude\.sh\|ipset/get_ipban\.sh' \
        "$ROOT/files" "$ROOT/lib" "$ROOT/webpanel" "$ROOT/z2k.sh" 2>/dev/null \
      | grep -v ':[0-9]*:[[:space:]]*#' | grep -v 'cron_regex\|crontab')
if [ -z "$hits" ]; then
    ok "никто в z2k не запускает апстримную пересборку ipset'ов"
else
    bad "никто в z2k не запускает апстримную пересборку ipset'ов" "$(printf '%s' "$hits" | head -2 | tr '\n' ';')"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
