#!/bin/sh
# tests/test_scheduler_exec_reload_keeps_pid.sh — горячая перезагрузка кода
# планировщика не должна убивать планировщик.
#
# ЧТО БЫЛО. Увидев новый mtime своего файла, планировщик делает `exec sh
# "$_self"`. exec сохраняет pid, а pidfile остаётся с этим же pid — и новый
# экземпляр на первой же проверке «уже запущен?» находит в pidfile САМОГО СЕБЯ,
# kill -0 отвечает «жив», и он выходит с кодом 3. Надзиратель трактует 3 как
# «работает у чужого родителя», ждёт 30 секунд, видит мёртвый pid и только
# тогда перезапускает. Замер на роутере владельца 02.09.2026 08:31:25 →
# 08:31:55: тридцать секунд без планировщика на каждое обновление его файла —
# то есть на каждое обновление z2k.
#
# Тест исполняет настоящий планировщик ровно в этой ситуации: pidfile уже
# содержит pid оболочки, которая затем exec'ает планировщик (как после
# перезагрузки кода). Планировщик обязан стартовать, а не выйти с кодом 3.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHED="$ROOT/files/z2k-scheduler.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2kexecpid.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
SB="$TMP/opt/zapret2"
mkdir -p "$SB/state" "$TMP/bin" "$TMP/log" "$TMP/run"
echo 1 > "$SB/state/tcp16.flag"

REAL_DATE=$(command -v date)
REAL_SLEEP=$(command -v sleep)
# Часы стоят на минуте без задач; sleep гасит цикл после первого тика.
cat > "$TMP/bin/date" <<EOF
#!/bin/sh
case "\$1" in
    +%H:%M) echo 12:34 ;;
    *) exec "$REAL_DATE" "\$@" ;;
esac
EOF
printf '#!/bin/sh\nkill -TERM $PPID 2>/dev/null\nexit 0\n' > "$TMP/bin/sleep"
chmod 755 "$TMP/bin/date" "$TMP/bin/sleep"

LOGF="$TMP/log/z2k-scheduler.log"
sed -e "s|^export PATH=|export PATH=$TMP/bin:|" \
    -e "s|^ZAPRET2_DIR=\"/opt/zapret2\"|ZAPRET2_DIR=\"$SB\"|" \
    -e "s|^LOG=\"/opt/var/log/z2k-scheduler.log\"|LOG=\"$LOGF\"|" \
    -e "s|^TMP_STATE=\"/tmp/.z2k-scheduler-state\"|TMP_STATE=\"$TMP/run/tmpstate\"|" \
    -e "s|/opt/etc/init.d/S99zapret2|$SB/S99-absent|g" \
    -e "s|/tmp/z2k-sni-refresh.ts|$TMP/run/sni.ts|g" \
    -e "s|/tmp/z2k-scheduler.mtime|$TMP/run/sched.mtime|g" \
    "$SCHED" > "$TMP/sched.sh"
: > "$LOGF"
PIDF="$TMP/run/pid"

# Ровно то, что происходит при перезагрузке кода: pid в pidfile — наш, и мы
# exec'аем планировщик, не меняя pid.
# Именно sh -c, а не ( ... ): в подоболочке $$ — это pid РОДИТЕЛЯ, и в pidfile
# попал бы живой чужой процесс, то есть совсем другой сценарий. Пути — через
# окружение: позиционные аргументы `sh -c` на роутере приходят пустыми
# (tests/test_router_shell_portability.sh, п. 7).
Z2K_SCHED_PIDFILE="$PIDF" Z2K_LOG_DIR="$TMP/log" SCHED_COPY="$TMP/sched.sh" \
  sh -c 'echo $$ > "$Z2K_SCHED_PIDFILE"; exec sh "$SCHED_COPY"' >"$TMP/stdout" 2>"$TMP/stderr" &
SPID=$!
i=0
while kill -0 "$SPID" 2>/dev/null && [ "$i" -lt 100 ]; do "$REAL_SLEEP" 0.1; i=$((i+1)); done
kill -0 "$SPID" 2>/dev/null && kill -TERM "$SPID" 2>/dev/null
wait "$SPID" 2>/dev/null; rc=$?

if grep -q 'scheduler started' "$LOGF" 2>/dev/null; then
    ok "после exec-перезагрузки планировщик стартует, увидев в pidfile свой pid"
else
    bad "после exec-перезагрузки планировщик стартует" \
        "rc=$rc stderr=[$(head -c 200 "$TMP/stderr" 2>/dev/null)] — вышел, приняв себя за чужого"
fi
if [ "$rc" = "3" ]; then
    bad "код возврата не 3" "надзиратель ждал бы 30 с «чужого» планировщика, которого нет"
else
    ok "код возврата не 3 (rc=$rc)"
fi

# Контроль: ЧУЖОЙ живой pid по-прежнему даёт 3 — защита от двойного запуска
# не сломана.
"$REAL_SLEEP" 300 & OTHER=$!
echo "$OTHER" > "$PIDF"
Z2K_SCHED_PIDFILE="$PIDF" Z2K_LOG_DIR="$TMP/log" sh "$TMP/sched.sh" >/dev/null 2>&1; rc2=$?
kill "$OTHER" 2>/dev/null
if [ "$rc2" = "3" ]; then
    ok "чужой живой pid в pidfile по-прежнему даёт код 3"
else
    bad "чужой живой pid в pidfile даёт код 3" "rc=$rc2 — защита от двойного запуска потеряна"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
