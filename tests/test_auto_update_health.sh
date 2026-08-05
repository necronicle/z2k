#!/bin/sh
# tests/test_auto_update_health.sh
#
# The post-update health check used to open with `sleep 60`, described as
# "waiting for the service to settle". It was neither needed for that nor
# measured: au_apply_patch runs `/opt/etc/init.d/S99zapret2 restart`
# SYNCHRONOUSLY, and run_daemon() blocks on z2k_wait_queue_bound until nfqws2 has
# bound its NFQUEUE. By the time the check runs, the condition its first test
# asks about is already guaranteed — so the minute was spent waiting for
# something that had already happened, on every single update.
#
# What the window is actually worth is the opposite case: a daemon that starts,
# binds, and then dies seconds later (the MIPS async-preempt crash loop). Five
# seconds covers that.
#
# Asserted here: the value, and the three verdicts — died, broken script,
# unreachable GitHub — because the last one must NOT roll anything back. Rolling
# back on a failed GitHub probe churned good updates nightly for users whose
# provider blocks it, and that regression is easy to reintroduce.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
AU="$HERE/lib/auto_update.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/auhealth.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export TMP

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$AU" ] || { printf '[FAIL] missing %s\n' "$AU"; exit 1; }

# --- the value ---------------------------------------------------------------
def=$(grep -E '^Z2K_AU_HEALTH_TIMEOUT=' "$AU" | sed 's/.*:-\([0-9]*\)}.*/\1/')
[ "$def" = "5" ] && ok "окно стабильности = 5с" \
                 || no "окно стабильности = 5с" "5" "$def"
[ "${def:-0}" -le 10 ] && ok "окно не превышает 10с (не ждём того, что уже проверено стартом)" \
                       || no "окно не превышает 10с" "<=10" "$def"

# The old wording is what made the number look load-bearing. If it comes back,
# so will the assumption behind it.
grep -q 'waiting .*for service to settle' "$AU" \
    && no "формулировка «ждём старта» убрана" "нет" "вернулась" \
    || ok "формулировка «ждём старта» убрана"

# The claim above is only true while the restart really is synchronous and
# self-verifying. Pin both halves: if either changes, the 5s stops being safe.
grep -q 'z2k_wait_queue_bound' "$HERE/files/S99zapret2.new" \
    && ok "старт nfqws2 дожидается привязки очереди (основание для короткого окна)" \
    || no "старт дожидается привязки очереди" "z2k_wait_queue_bound" "отсутствует"
apply_body=$(awk '/^au_apply_patch\(\)/{f=1} f{print} f&&/^}/{exit}' "$AU" | sed 's/^[[:space:]]*#.*$//')
# Проверяем СВОЙСТВО, а не точную строку. Раньше здесь была зашита
# `restart >/dev/null 2>&1`, и тест упал, когда приёмник вывода сменили с
# /dev/null на временный файл — а менялось это ради дела: при отказе перезапуска
# в журнале не оставалось ни слова о причине, и человек читал «непонятно что не
# так». Важно тут одно — что вызов синхронный, то есть без фонового &.
case "$apply_body" in
    *'restart > "$_rst_out" 2>&1'*|*'restart >/dev/null 2>&1'*) ok "рестарт сервиса синхронный, без фонового &" ;;
    *) no "рестарт сервиса синхронный" "синхронный вызов" "не найден" ;;
esac
case "$apply_body" in
    *'restart >/dev/null 2>&1 &'*) no "рестарт не уходит в фон" "без &" "с &" ;;
    *) ok "рестарт не уходит в фон" ;;
esac

# --- behaviour ---------------------------------------------------------------
# Stubs on PATH: pgrep decides "alive", curl decides "github reachable".
mkdir -p "$TMP/bin" "$TMP/zd/lib" "$TMP/zd/webpanel/cgi" "$TMP/init"
cat > "$TMP/bin/pgrep" <<'S'
#!/bin/sh
[ -f "$TMP/alive" ] && exit 0
exit 1
S
cat > "$TMP/bin/curl" <<'S'
#!/bin/sh
[ -f "$TMP/gh_ok" ] && exit 0
exit 7
S
chmod +x "$TMP/bin/pgrep" "$TMP/bin/curl"
printf 'echo ok\n' > "$TMP/zd/lib/good.sh"
: > "$TMP/init/S99zapret2"

run_health() {
    PATH="$TMP/bin:$PATH" sh -c "
        Z2K_AU_SOURCE_ONLY=1 Z2K_AU_HEALTH_TIMEOUT=0 . '$AU' 2>/dev/null
        Z2K_AU_LOG_FILE='$TMP/log' ZAPRET2_DIR='$TMP/zd'
        export Z2K_AU_LOG_FILE ZAPRET2_DIR
        au_health_check >/dev/null 2>&1
        echo \$?
    "
}

: > "$TMP/alive"; : > "$TMP/gh_ok"
[ "$(run_health)" = 0 ] && ok "живой демон + валидные скрипты + доступный github = OK" \
                        || no "здоровое состояние = OK" "0" "$(run_health)"

rm -f "$TMP/gh_ok"
[ "$(run_health)" = 0 ] \
    && ok "недоступный github НЕ откатывает обновление (совещательный сигнал)" \
    || no "недоступный github не откатывает" "0" "$(run_health)"
: > "$TMP/gh_ok"

rm -f "$TMP/alive"
[ "$(run_health)" = 1 ] && ok "демон умер после старта = провал (откат оправдан)" \
                        || no "демон умер = провал" "1" "$(run_health)"
: > "$TMP/alive"

printf 'if then fi\n' > "$TMP/zd/lib/broken.sh"
[ "$(run_health)" = 1 ] \
    && ok "синтаксическая ошибка в установленном скрипте = провал" \
    || no "синтаксическая ошибка = провал" "1" "$(run_health)"
rm -f "$TMP/zd/lib/broken.sh"

# A broken CGI bricks the panel while nfqws2 keeps running — it must fail too.
printf 'case x in\n' > "$TMP/zd/webpanel/cgi/broken.sh"
[ "$(run_health)" = 1 ] \
    && ok "сломанный CGI вебпанели тоже ловится" \
    || no "сломанный CGI ловится" "1" "$(run_health)"
rm -f "$TMP/zd/webpanel/cgi/broken.sh"

[ "$(run_health)" = 0 ] && ok "после уборки поломок снова OK" \
                        || no "после уборки поломок снова OK" "0" "$(run_health)"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
