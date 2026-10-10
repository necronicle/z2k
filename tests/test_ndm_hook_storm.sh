#!/bin/sh
# tests/test_ndm_hook_storm.sh — GitHub issue #18 + отложенный повтор (10.10.2026).
# The NDM netfilter hook 000-zapret2.sh must COALESCE an NDM event storm into a
# bounded number of start_fw runs (mkdir mutex), not spawn 80+ in parallel —
# AND must not lose the trailing event: a regen that lands while start_fw is
# running wipes the rules again, so the lock holder re-runs once afterwards.
# Runs the real hook with env-overridden paths + a fake pidof + a counting
# mock INIT_SCRIPT + a fake iptables that reports the NFQUEUE rule count.
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$HERE/files/000-zapret2.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ndmstorm.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

# counting mock INIT_SCRIPT (one line per start_fw); re-arms PENDING when asked
# (simulates a storm that keeps regenerating while we rebuild).
CNT="$TMP/count"; : > "$CNT"
INIT="$TMP/S99zapret2"
cat > "$INIT" <<EOF2
#!/bin/sh
[ "\$1" = start_fw ] || exit 0
echo x >> "$CNT"
[ -n "\${REARM_PENDING:-}" ] && : > "\$PENDING"
exit 0
EOF2
chmod +x "$INIT"

printf 'ENABLED=1\n' > "$TMP/config"

# fake pidof so is_nfqws2_running() succeeds; fake iptables reports $FAKE_NFQ
# NFQUEUE rules (default 0 = "wiped", so a trailing event triggers a rerun).
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\necho 12345\nexit 0\n' > "$BIN/pidof"
cat > "$BIN/iptables" <<'EOF2'
#!/bin/sh
i=0; while [ "$i" -lt "${FAKE_NFQ:-0}" ]; do echo "-A PREROUTING -p tcp -j NFQUEUE --queue-num 200"; i=$((i+1)); done
exit 0
EOF2
chmod +x "$BIN/pidof" "$BIN/iptables"

LOCK="$TMP/lock"; LAST="$TMP/last"; PEND="$TMP/pending"; LOG="$TMP/hook.log"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

run_hook() {  # $1 HOOK_SETTLE  $2 FAKE_NFQ  $3 REARM_PENDING  $4 MAX_RERUNS
    # Параметры — ТОЛЬКО позиционные. Присваивание перед вызовом функции
    # (`HS=1 run_hook`) в POSIX sh не локально: оно остаётся до конца скрипта и
    # утекает в следующие секции (именно так в первой версии этого набора
    # settle=1 из шторма сломал пять проверок ниже).
    table=mangle type=iptables PATH="$BIN:$PATH" Z2K_TEST_NOW_SHIFT="${Z2K_TEST_NOW_SHIFT:-}" \
        INIT_SCRIPT="$INIT" ZAPRET_CONFIG="$TMP/config" FAKE_NFQ="${2:-0}" \
        REARM_PENDING="${3:-}" PENDING="$PEND" HOOK_LOG="$LOG" \
        LOCK_DIR="$LOCK" LAST_RUN="$LAST" HOOK_SETTLE="${1:-0}" MAX_RERUNS="${4:-3}" \
        sh "$HOOK"
}
# Хук уходит в фон и отпускает замок последним действием: ждём именно замок,
# а не фиксированные секунды (на медленном раннере они и рвали проверки).
settle() {
    _i=0
    while [ -d "$LOCK" ] && [ "$_i" -lt 30 ]; do sleep 1; _i=$((_i+1)); done
}
count() { wc -l < "$CNT" | tr -d ' '; }
reset() { rm -rf "$LOCK"; rm -f "$LAST" "$PEND" "$LOG"; : > "$CNT"; }

# --- 1) storm: 20 rapid events -> 1 run + exactly 1 trailing rerun ----------
# settle=2: the first hook holds the lock for two seconds, the other 19 land inside
# and collapse into one PENDING mark; the holder sees wiped rules (FAKE_NFQ=0)
# and re-runs ONCE.
reset
i=0; while [ "$i" -lt 20 ]; do run_hook 2; i=$((i+1)); done
settle
n=$(count); [ "$n" = "2" ] && ok "20-event storm -> 1 run + 1 trailing rerun" || no "storm coalesce" "2" "$n"
[ ! -d "$LOCK" ] && ok "lock released after run" || no "lock released" "absent" "present"
[ ! -f "$PEND" ] && ok "pending mark consumed" || no "pending consumed" "absent" "present"
grep -q ' pending ' "$LOG" && grep -q ' run dur=' "$LOG" && grep -q ' rerun 1/3 dur=' "$LOG" \
    && ok "journal has pending / run / rerun lines" || no "journal lines" "pending+run+rerun" "$(tr '\n' '|' < "$LOG")"

# --- 2) event right after a finished run is NOT dropped (old debounce bug) --
# LAST is fresh from test 1. A regen that lands after start_fw finished wiped
# the rules again; the hook must rebuild, not assume the previous run covers it.
: > "$CNT"; run_hook; settle
n=$(count); [ "$n" = "1" ] && ok "event after a fresh run still restores rules" || no "post-run event restores" "1" "$n"

# --- 3) trailing event whose regen landed BEFORE our start_fw -> no rerun ---
# FAKE_NFQ=12: rules are present after the run, so the pending mark is
# consumed without a second start_fw (also what breaks any NDM feedback loop).
reset
run_hook 2 12; run_hook 0 12; settle
n=$(count); [ "$n" = "1" ] && ok "rules present after run -> rerun skipped" || no "rerun skip" "1" "$n"
grep -q 'rerun-skip' "$LOG" && ok "journal records rerun-skip" || no "journal rerun-skip" "present" "absent"

# --- 4) rerun bound: a storm that never stops gets MAX_RERUNS, then yields ---
reset
: > "$PEND"                               # storm already in flight
run_hook 0 0 1 2; settle
n=$(count); [ "$n" = "3" ] && ok "endless storm bounded to 1 run + MAX_RERUNS" || no "rerun bound" "3" "$n"
[ ! -d "$LOCK" ] && ok "lock released after bounded reruns" || no "lock released (bound)" "absent" "present"

# --- 5) stale lock (>60s) reclaimed -- only where `date -r FILE` = mtime -----
# (busybox/GNU: file mtime; BSD/macOS: arg is epoch seconds -> skip there)
if date -r "$TMP" +%s 2>/dev/null | grep -qE '^[0-9]{10}$'; then
    reset; mkdir "$LOCK"
    # Замок старим СДВИГОМ «СЕЙЧАС», а не mtime: busybox touch не знает -t
    # (usage — `touch [-ch] FILE...`), метка не ставилась, и на роутере замок
    # оставался свежим. Хук считает возраст как now - `date -r ЗАМОК`, так что
    # сдвиг эквивалентен и портируем. См. z2k_write_date_stub.
    z2k_write_date_stub "$BIN/date"
    # Присваивание ПЕРЕД ВЫЗОВОМ ФУНКЦИИ в POSIX sh не локально: оно остаётся в
    # окружении до конца скрипта, и сдвиг «сейчас» утекал в следующие секции —
    # свежий замок выглядел просроченным. Ставим и снимаем явно.
    Z2K_TEST_NOW_SHIFT=86400; run_hook; unset Z2K_TEST_NOW_SHIFT; settle
    n=$(count); [ "$n" = "1" ] && ok "stale lock reclaimed -> start_fw runs" || no "stale lock reclaim" "1" "$n"
    [ ! -d "$LOCK" ] && ok "reclaimed lock released" || no "reclaimed lock released" "absent" "present"
    rm -f "$BIN/date"
else
    ok "stale-lock test skipped (BSD date -r, not router busybox)"
fi

# --- 6) fresh lock held (<60s): no concurrent run, but the event is marked ---
reset; mkdir "$LOCK"                      # simulate in-flight rebuild
run_hook; sleep 1                         # замок наш, settle ждать нечего
n=$(count); [ "$n" = "0" ] && ok "held lock blocks concurrent start_fw" || no "held lock blocks" "0" "$n"
[ -f "$PEND" ] && ok "held lock leaves a pending mark for the holder" || no "pending mark" "present" "absent"
rm -rf "$LOCK"

# --- 7) HOOK_LOG="" disables the journal ------------------------------------
reset
HOOK_LOG='' table=mangle type=iptables PATH="$BIN:$PATH" INIT_SCRIPT="$INIT" ZAPRET_CONFIG="$TMP/config" \
    PENDING="$PEND" LOCK_DIR="$LOCK" LAST_RUN="$LAST" HOOK_SETTLE=0 sh "$HOOK"; settle
[ ! -f "$LOG" ] && [ "$(count)" = "1" ] && ok "empty HOOK_LOG: run happens, nothing written" || no "journal off" "run+no file" "$(count)/$([ -f "$LOG" ] && echo file || echo nofile)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
