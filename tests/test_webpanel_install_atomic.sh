#!/bin/sh
# tests/test_webpanel_install_atomic.sh — атомарность webpanel/install.sh и
# жизненный цикл init.d/S96z2k-webpanel:
#   (а) неполные/пустые исходники НЕ разрушают установленную панель;
#   (б) переустановка без аргументов сохраняет кастомные port/bind;
#   (в) is_alive не доверяет чужому PID из pidfile (и stop его не убивает);
#   (г) stop убивает фоновый waiter, повторный start не плодит второго;
#   (д) uninstall.sh возвращает отключённый штатный S80lighttpd;
#   (е) inline-удаление из меню работает при частичной установке и тоже
#       возвращает штатный init.
#
# Песочница без root и без обращений к настоящему /opt: абсолютные пути
# (/opt, /var/run, /tmp/z2k*) переписаны sed'ом в КОПИЯХ скриптов, lighttpd
# и ip подменены шимами. На Linux проверка идентичности PID идёт по
# настоящему /proc, на macOS — по подставному каталогу через Z2K_PROC.
# POSIX sh compatible (busybox ash / dash).

TESTS_PASSED=0
TESTS_FAILED=0
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf '[PASS] %s\n' "$1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '[FAIL] %s: %s\n' "$1" "$2"; }
assert_eq()       { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }
assert_rc0()      { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "rc=$2"; fi; }
assert_rc_fail()  { if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "unexpectedly rc=0"; fi; }
assert_file()     { if [ -e "$2" ]; then pass "$1"; else fail "$1" "missing: $2"; fi; }
assert_no_file()  { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "still present: $2"; fi; }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "'$2' not in output" ;; esac; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)" || exit 1
# Убить все процессы песочницы (их cmdline содержит путь $SB) и убрать её.
trap 'pkill -f "$SB" 2>/dev/null; rm -rf "$SB"' EXIT

# ---------------------------------------------------------------------------
# Шимы для install.sh (он не переопределяет PATH): ip отдаёт фиктивные
# интерфейсы, opkg никогда не должен быть нужен (fake lighttpd уже «стоит»).
# ---------------------------------------------------------------------------
mkdir -p "$SB/bin"
cat > "$SB/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
    *"addr show"*) cat <<'IPOUT'
1: lo: <LOOPBACK,UP> mtu 65536
    inet 127.0.0.1/8 scope host lo
2: br0: <BROADCAST,UP> mtu 1500
    inet 192.168.77.1/24 brd 192.168.77.255 scope global br0
3: eth1: <BROADCAST,UP> mtu 1500
    inet 10.5.5.5/24 brd 10.5.5.255 scope global eth1
IPOUT
        ;;
    *"route get"*) echo "1.1.1.1 via 192.168.77.254 dev br0 src 192.168.77.1" ;;
esac
EOF
cat > "$SB/bin/opkg" <<'EOF'
#!/bin/sh
echo "opkg-shim: $*"
exit 0
EOF
chmod 755 "$SB/bin/ip" "$SB/bin/opkg"
PATH="$SB/bin:$PATH"
export PATH

# Переписать абсолютные пути скрипта внутрь песочницы. Порядок правил не
# случаен: на Linux $R сам начинается с /tmp, поэтому /tmp-правило первое и
# узкое (/tmp/z2k покрывает и /tmp/z2k-log, и /tmp/z2k-webpanel-*), а /opt/ —
# последним, чтобы не перезаписывать уже подставленный $R.
rw() {
    sed -e "s|/tmp/z2k|$R/tmp/z2k|g" \
        -e "s|/var/run/|$R/var/run/|g" \
        -e "s|/opt/|$R/opt/|g" \
        "$1" > "$2"
    chmod 755 "$2"
}

# mk_env <имя>: свежий песочный корень $R с переписанными копиями скриптов,
# фейковым lighttpd в $R/opt/sbin и полным source-деревом в $R/src.
mk_env() {
    R="$SB/$1"
    mkdir -p "$R/opt/etc/init.d" "$R/opt/sbin" "$R/opt/lib/lighttpd" \
             "$R/opt/zapret2" "$R/var/run" "$R/tmp" "$R/src/init.d"
    cp -R "$ROOT/webpanel/cgi" "$R/src/cgi"
    cp -R "$ROOT/webpanel/www" "$R/src/www"
    cp "$ROOT/webpanel/lighttpd.conf" "$R/src/lighttpd.conf"
    rw "$ROOT/webpanel/install.sh"             "$R/src/install.sh"
    rw "$ROOT/webpanel/uninstall.sh"           "$R/src/uninstall.sh"
    rw "$ROOT/webpanel/init.d/S96z2k-webpanel" "$R/src/init.d/S96z2k-webpanel"
    # Фейковый lighttpd: -tt валидирует (или падает с сообщением из
    # FAKE_TT_FAIL_MSG), обычный запуск пишет свой pid в FAKE_PIDFILE и живёт
    # в foreground. Имя файла = lighttpd, поэтому на Linux comm настоящий.
    cat > "$R/opt/sbin/lighttpd" <<'FAKE'
#!/bin/sh
tt=0
while [ $# -gt 0 ]; do
    case "$1" in -tt) tt=1 ;; esac
    shift
done
if [ -n "${FAKE_TT_FAIL_MSG:-}" ]; then
    echo "$FAKE_TT_FAIL_MSG" >&2
    exit 1
fi
[ "$tt" = 1 ] && exit 0
[ -n "${FAKE_PIDFILE:-}" ] && echo $$ > "$FAKE_PIDFILE"
while :; do sleep 1; done
FAKE
    chmod 755 "$R/opt/sbin/lighttpd"
    touch "$R/opt/lib/lighttpd/mod_cgi.so"
    FAKE_PIDFILE="$R/var/run/z2k-webpanel.pid"
    export FAKE_PIDFILE
    unset FAKE_TT_FAIL_MSG
}

# ===========================================================================
printf -- "--- (а) неполные исходники не разрушают установленную панель ---\n"
# ===========================================================================
mk_env a
mkdir -p "$R/opt/zapret2/webpanel/cgi" "$R/opt/zapret2/www"
echo "OLD-API"   > "$R/opt/zapret2/webpanel/cgi/api.sh"
echo "OLD-INDEX" > "$R/opt/zapret2/www/index.html"
printf '9090'    > "$R/opt/zapret2/webpanel/port"
printf '#!/bin/sh\nexit 0\n' > "$R/opt/etc/init.d/S96z2k-webpanel"
chmod 755 "$R/opt/etc/init.d/S96z2k-webpanel"
rm "$R/src/www/app.js"          # источник неполон...
: > "$R/src/cgi/auth.sh"        # ...и пустой файл — тоже неполный
out=$(sh "$R/src/install.sh" 2>&1); rc=$?
assert_rc_fail "install с неполными исходниками падает" "$rc"
assert_contains "называет отсутствующий файл" "www/app.js" "$out"
assert_contains "называет пустой файл" "cgi/auth.sh" "$out"
assert_eq "старый cgi не тронут" "OLD-API"   "$(cat "$R/opt/zapret2/webpanel/cgi/api.sh" 2>/dev/null)"
assert_eq "старый www не тронут" "OLD-INDEX" "$(cat "$R/opt/zapret2/www/index.html" 2>/dev/null)"
assert_eq "port-файл не тронут"  "9090"      "$(cat "$R/opt/zapret2/webpanel/port" 2>/dev/null)"
assert_file "init не удалён" "$R/opt/etc/init.d/S96z2k-webpanel"

# ===========================================================================
printf -- "\n--- (б) переустановка сохраняет кастомные port/bind ---\n"
# ===========================================================================
mk_env b
out=$(sh "$R/src/install.sh" --port 9090 --bind 10.5.5.5 2>&1); rc=$?
assert_rc0 "первичная установка --port 9090 --bind 10.5.5.5" "$rc"
[ "$rc" -ne 0 ] && printf '%s\n' "$out"
assert_eq "port записан"  "9090"     "$(cat "$R/opt/zapret2/webpanel/port" 2>/dev/null)"
assert_eq "bind записан"  "10.5.5.5" "$(cat "$R/opt/zapret2/webpanel/bind" 2>/dev/null)"
assert_file "маркер явного bind создан" "$R/opt/zapret2/webpanel/bind.explicit"
# Переустановка из меню = вызов установщика БЕЗ аргументов.
out=$(sh "$R/src/install.sh" 2>&1); rc=$?
assert_rc0 "переустановка без аргументов" "$rc"
[ "$rc" -ne 0 ] && printf '%s\n' "$out"
assert_contains "сообщает о повторном использовании порта" "reusing saved port 9090" "$out"
assert_eq "port сохранён" "9090"     "$(cat "$R/opt/zapret2/webpanel/port" 2>/dev/null)"
assert_eq "bind сохранён" "10.5.5.5" "$(cat "$R/opt/zapret2/webpanel/bind" 2>/dev/null)"
grep -q 'server.port[[:space:]]*=[[:space:]]*9090' "$R/opt/zapret2/webpanel/lighttpd.conf" 2>/dev/null
assert_rc0 "конфиг сгенерирован с сохранённым портом" "$?"
grep -q 'server.bind[[:space:]]*=[[:space:]]*"10.5.5.5"' "$R/opt/zapret2/webpanel/lighttpd.conf" 2>/dev/null
assert_rc0 "конфиг сгенерирован с сохранённым bind" "$?"
"$R/opt/etc/init.d/S96z2k-webpanel" stop >/dev/null 2>&1

# ===========================================================================
printf -- "\n--- (в) is_alive не доверяет чужому PID из pidfile ---\n"
# ===========================================================================
mk_env c
INIT="$R/src/init.d/S96z2k-webpanel"
CONF_PATH="$R/opt/zapret2/webpanel/lighttpd.conf"
sleep 30 &
FOREIGN=$!
mkdir -p "$R/proc/$FOREIGN"
printf 'sleep\n'  > "$R/proc/$FOREIGN/comm"
printf 'sleep 30' > "$R/proc/$FOREIGN/cmdline"
echo "$FOREIGN" > "$R/var/run/z2k-webpanel.pid"
out=$(Z2K_PROC="$R/proc" sh "$INIT" status); rc=$?
assert_rc_fail "status: живой чужой PID ≠ running" "$rc"
assert_contains "status печатает stopped" "stopped" "$out"
# stop не должен слать TERM чужому процессу, но обязан убрать stale pidfile.
Z2K_PROC="$R/proc" sh "$INIT" stop >/dev/null 2>&1
kill -0 "$FOREIGN" 2>/dev/null
assert_rc0 "stop не убил чужой процесс" "$?"
assert_no_file "stale pidfile убран" "$R/var/run/z2k-webpanel.pid"
# Позитивный контроль: запись procfs, похожая на наш lighttpd → running.
printf 'lighttpd\n' > "$R/proc/$FOREIGN/comm"
printf 'lighttpd -D -f %s' "$CONF_PATH" > "$R/proc/$FOREIGN/cmdline"
echo "$FOREIGN" > "$R/var/run/z2k-webpanel.pid"
out=$(Z2K_PROC="$R/proc" sh "$INIT" status); rc=$?
assert_rc0 "status: наш lighttpd = running" "$rc"
kill "$FOREIGN" 2>/dev/null
wait "$FOREIGN" 2>/dev/null   # реап: иначе шелл печатает "Terminated" в вывод теста
rm -f "$R/var/run/z2k-webpanel.pid"

# ===========================================================================
printf -- "\n--- (г) stop убивает фоновый waiter ---\n"
# ===========================================================================
mk_env d
INIT="$R/src/init.d/S96z2k-webpanel"
mkdir -p "$R/opt/zapret2/webpanel" "$R/opt/zapret2/www"
echo x > "$R/opt/zapret2/www/index.html"
cp "$ROOT/webpanel/lighttpd.conf" "$R/opt/zapret2/webpanel/lighttpd.conf"
# Шаг ожидания задираем: при боевых пяти секундах waiter успевал пройти
# цикл и прибрать свой pidfile раньше, чем до него добиралась проверка —
# на CI-раннере это воспроизводилось стабильно, на macOS нет. Здесь важно
# наблюдать waiter'а живым, а не мерить его терпение. 30, а не больше:
# убитый waiter оставляет за собой осиротевший sleep, и жить ему ровно
# столько же — на общем раннере это чужое время.
Z2K_WAIT_INTERVAL=30
export Z2K_WAIT_INTERVAL
FAKE_TT_FAIL_MSG="error while loading shared libraries: libnettle.so.8: cannot open shared object file: No such file or directory"
export FAKE_TT_FAIL_MSG
out=$(sh "$INIT" start 2>&1); rc=$?
assert_rc0 "start уходит в фоновое ожидание (rc=0)" "$rc"
assert_contains "start сообщает об ожидании" "background" "$out"
if [ ! -f "$R/var/run/z2k-webpanel-wait.pid" ]; then
    # Голое «missing» здесь бесполезно: расхождение платформенное (на CI-Linux
    # падало, на macOS зелено), а Linux под рукой нет ни у кого. Печатаем ровно
    # то, чего не хватило, чтобы следующий прогон дал факты, а не догадки.
    printf '       диагностика:\n'
    printf '         вывод start: %s\n' "$(printf '%s' "$out" | tr '\n' '|')"
    printf '         строка WAIT_PIDFILE в переписанном init: %s\n' \
        "$(grep -n '^WAIT_PIDFILE=' "$INIT" 2>/dev/null || echo '<нет>')"
    printf '         содержимое %s: %s\n' "$R/var/run" "$(ls -a "$R/var/run" 2>&1 | tr '\n' ' ')"
    printf '         каталог логов: %s\n' "$(ls -ld "$R/tmp/z2k-log" 2>&1)"
    # Лог waiter'а отвечает на главный вопрос: он ещё крутится (тогда pidfile
    # должен быть на месте) или уже вышел, сам за собой прибрав. Второе значит,
    # что цикл прошёл все 60 итераций мгновенно — то есть sleep или проверка
    # внутри отработали не так, как на macOS.
    printf '         лог waiter: %s\n' \
        "$(tail -5 "$R/tmp/z2k-log/z2k-webpanel-wait.log" 2>&1 | tr '\n' '|')"
    printf '         живые sh с нашим init: %s\n' \
        "$(pgrep -f "S96z2k-webpanel" 2>/dev/null | tr '\n' ' ')"
    _t0=$(date +%s); sleep 2; _t1=$(date +%s)
    printf '         sleep: %s, две секунды заняли %s с\n' \
        "$(command -v sleep 2>&1)" "$((_t1 - _t0))"
fi
assert_file "waiter pidfile создан" "$R/var/run/z2k-webpanel-wait.pid"
WPID=$(cat "$R/var/run/z2k-webpanel-wait.pid" 2>/dev/null)
kill -0 "$WPID" 2>/dev/null
assert_rc0 "waiter жив" "$?"
# Повторный start в окне ожидания не должен плодить второго waiter'а.
out=$(sh "$INIT" start 2>&1)
assert_contains "повторный start: already pending" "pending" "$out"
assert_eq "waiter pidfile не переписан" "$WPID" "$(cat "$R/var/run/z2k-webpanel-wait.pid" 2>/dev/null)"
# stop обязан убить waiter — иначе панель «сама» поднимется вопреки stop.
sh "$INIT" stop >/dev/null 2>&1
i=0
while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 8 ]; do
    sleep 1
    i=$((i + 1))
done
kill -0 "$WPID" 2>/dev/null
assert_rc_fail "waiter убит stop'ом" "$?"
assert_no_file "waiter pidfile убран" "$R/var/run/z2k-webpanel-wait.pid"
unset FAKE_TT_FAIL_MSG Z2K_WAIT_INTERVAL

# ===========================================================================
printf -- "\n--- (д) uninstall.sh возвращает отключённый штатный lighttpd init ---\n"
# ===========================================================================
mk_env e
mkdir -p "$R/opt/zapret2/webpanel" "$R/opt/zapret2/www"
echo "stock-init" > "$R/opt/etc/init.d/.S80lighttpd.disabled-by-z2k"
out=$(sh "$R/src/uninstall.sh" 2>&1); rc=$?
assert_rc0 "uninstall отработал" "$rc"
[ "$rc" -ne 0 ] && printf '%s\n' "$out"
assert_file "штатный S80lighttpd восстановлен" "$R/opt/etc/init.d/S80lighttpd"
assert_no_file "disabled-файл убран" "$R/opt/etc/init.d/.S80lighttpd.disabled-by-z2k"
assert_no_file "каталог панели удалён" "$R/opt/zapret2/webpanel"
assert_no_file "каталог www удалён" "$R/opt/zapret2/www"

# ===========================================================================
printf -- "\n--- (е) inline-удаление из меню при частичной установке ---\n"
# ===========================================================================
mk_env f
rw "$ROOT/lib/webpanel.sh" "$R/webpanel_lib.sh"
# Частичное состояние: осиротевший init БЕЗ каталога панели.
printf '#!/bin/sh\nexit 0\n' > "$R/opt/etc/init.d/S96z2k-webpanel"
chmod 755 "$R/opt/etc/init.d/S96z2k-webpanel"
echo "stock-init" > "$R/opt/etc/init.d/.S80lighttpd.disabled-by-z2k"
cat > "$R/drive_uninstall.sh" <<EOF
#!/bin/sh
print_info()    { echo "INFO: \$*"; }
print_error()   { echo "ERR: \$*"; }
print_success() { echo "OK: \$*"; }
pause() { :; }
read_input() { eval "\$1=y"; }
. "$R/webpanel_lib.sh"
webpanel_do_uninstall
EOF
out=$(sh "$R/drive_uninstall.sh" 2>&1); rc=$?
assert_rc0 "inline-удаление отработало" "$rc"
assert_contains "частичная установка удалена (не «не установлена»)" "OK:" "$out"
assert_no_file "осиротевший init удалён" "$R/opt/etc/init.d/S96z2k-webpanel"
assert_file "штатный S80lighttpd восстановлен (inline)" "$R/opt/etc/init.d/S80lighttpd"

printf -- "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf -- "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
