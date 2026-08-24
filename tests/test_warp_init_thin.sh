#!/bin/sh
# tests/test_warp_init_thin.sh — S51z2k-warp после переезда на z2k-warpd.
#
# Init больше не супервизор: движок сам себе супервизор, здесь только pidfile
# и окружение. Контракт, который держат эти тесты:
#   - нет бинаря → start молча выходит 0 и ничего не создаёт (WARP не
#     установлен — это штатно, не ошибка);
#   - start один раз; повторный start не плодит второй процесс;
#   - stop убивает процесс и убирает pidfile;
#   - на MIPS в окружении движка есть GODEBUG=asyncpreemptoff=1.
# POSIX sh.
TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$SCRIPT_DIR/files/init.d/S51z2k-warp"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"; pkill -f "fake-warpd-$$" 2>/dev/null' EXIT

# --- нет бинаря ---
rc=0; BIN="$SB/absent" PIDFILE="$SB/pid" sh "$INIT" start >/dev/null 2>&1 || rc=$?
assert_eq "start without binary exits 0" "0" "$rc"
assert_eq "start without binary creates no pidfile" "no" "$([ -f "$SB/pid" ] && echo yes || echo no)"

# --- фейковый движок: пишет окружение и спит ---
cat > "$SB/fake-warpd-$$" <<EOF
#!/bin/sh
echo "GODEBUG=\$GODEBUG" > "$SB/env"
echo "ARGS=\$*" >> "$SB/env"
trap 'kill \$c 2>/dev/null; exit 0' TERM INT
sleep 30 & c=\$!
wait \$c
EOF
chmod +x "$SB/fake-warpd-$$"

BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" start >/dev/null 2>&1
sleep 1
assert_eq "start writes pidfile" "yes" "$([ -s "$SB/pid" ] && echo yes || echo no)"
pid=$(cat "$SB/pid")
assert_eq "started process is alive" "alive" "$(kill -0 "$pid" 2>/dev/null && echo alive || echo dead)"
assert_eq "engine started with 'run'" "ARGS=run" "$(grep ARGS "$SB/env")"

BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" start >/dev/null 2>&1
sleep 1
assert_eq "second start keeps the same pid" "$pid" "$(cat "$SB/pid")"
assert_eq "second start spawns no second process" "1" "$(pgrep -f "fake-warpd-$$" | wc -l | tr -d ' ')"

rc=0; BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" status >/dev/null 2>&1 || rc=$?
assert_eq "status exits 0 while running" "0" "$rc"

BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" stop >/dev/null 2>&1
sleep 1
assert_eq "stop removes pidfile" "no" "$([ -f "$SB/pid" ] && echo yes || echo no)"
assert_eq "stop kills the process" "dead" "$(kill -0 "$pid" 2>/dev/null && echo alive || echo dead)"
rc=0; BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" status >/dev/null 2>&1 || rc=$?
assert_eq "status exits 1 when stopped" "1" "$rc"

# --- мгновенно умирающий движок: мёртвый pid в pidfile = вечная карусель ---
# Поле r-79.4: неудачный старт (замок/TUN заняты) записывал свой pid, selfheal
# видел мёртвый процесс и поднимал новый — каждые 25 с, при живом демоне.
printf '#!/bin/sh\nexit 1\n' > "$SB/dead-warpd-$$"; chmod +x "$SB/dead-warpd-$$"
rm -f "$SB/pid"
BIN="$SB/dead-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" start >/dev/null 2>&1
assert_eq "мгновенная смерть: pidfile не создан" "no" "$([ -f "$SB/pid" ] && echo yes || echo no)"
rc=0; BIN="$SB/dead-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" status >/dev/null 2>&1 || rc=$?
assert_eq "мгновенная смерть: status говорит «остановлен»" "1" "$rc"

# --- живой демон без pidfile: status обязан его увидеть (второй источник правды) ---
rm -f "$SB/pid"
"$SB/fake-warpd-$$" run >/dev/null 2>&1 &
sleep 1
rc=0; BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" status >/dev/null 2>&1 || rc=$?
assert_eq "живой демон без pidfile опознан по имени" "0" "$rc"
BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" stop >/dev/null 2>&1
sleep 1
assert_eq "stop добивает демона без pidfile" "0" "$(pgrep -f "fake-warpd-$$ run" | wc -l | tr -d ' ')"

# --- MIPS: GODEBUG ---
mkdir -p "$SB/bin"; printf '#!/bin/sh\necho mipsel\n' > "$SB/bin/uname"; chmod +x "$SB/bin/uname"
rm -f "$SB/env"
Z2K_STUB_PATH="$SB/bin" BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" start >/dev/null 2>&1
sleep 1
assert_eq "MIPS gets asyncpreemptoff" "GODEBUG=asyncpreemptoff=1" "$(grep GODEBUG "$SB/env")"
BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" stop >/dev/null 2>&1

# --- не MIPS: GODEBUG пуст ---
printf '#!/bin/sh\necho aarch64\n' > "$SB/bin/uname"
rm -f "$SB/env"
Z2K_STUB_PATH="$SB/bin" BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" start >/dev/null 2>&1
sleep 1
assert_eq "aarch64 gets no GODEBUG" "GODEBUG=" "$(grep GODEBUG "$SB/env")"
BIN="$SB/fake-warpd-$$" PIDFILE="$SB/pid" sh "$INIT" stop >/dev/null 2>&1

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
