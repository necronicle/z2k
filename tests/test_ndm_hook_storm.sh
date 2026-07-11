#!/bin/sh
# tests/test_ndm_hook_storm.sh — GitHub issue #18.
# The NDM netfilter hook 000-zapret2.sh must COALESCE an NDM event storm into a
# single restart_fw (mkdir mutex + debounce), not spawn 80+ in parallel.
# Runs the real hook with env-overridden paths + a fake pidof + a counting
# mock INIT_SCRIPT. POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$HERE/files/000-zapret2.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ndmstorm.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

# counting mock INIT_SCRIPT (one line per restart_fw)
CNT="$TMP/count"; : > "$CNT"
INIT="$TMP/S99zapret2"
cat > "$INIT" <<EOF
#!/bin/sh
[ "\$1" = start_fw ] && echo x >> "$CNT"
exit 0
EOF
chmod +x "$INIT"

printf 'ENABLED=1\n' > "$TMP/config"

# fake pidof so is_nfqws2_running() succeeds
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\necho 12345\nexit 0\n' > "$BIN/pidof"
chmod +x "$BIN/pidof"

LOCK="$TMP/lock"; LAST="$TMP/last"
run_hook() {  # MI / HS overridable per call
    table=mangle PATH="$BIN:$PATH" \
        INIT_SCRIPT="$INIT" ZAPRET_CONFIG="$TMP/config" \
        LOCK_DIR="$LOCK" LAST_RUN="$LAST" MIN_INTERVAL="${MI:-15}" HOOK_SETTLE="${HS:-0}" \
        sh "$HOOK"
}
count() { wc -l < "$CNT" | tr -d ' '; }

# --- 1) storm: 20 rapid events -> exactly 1 restart_fw ----------------------
rm -rf "$LOCK"; rm -f "$LAST"; : > "$CNT"
i=0; while [ "$i" -lt 20 ]; do run_hook; i=$((i+1)); done
sleep 1                                  # let the backgrounded restart_fw finish
n=$(count); [ "$n" = "1" ] && ok "20-event storm coalesced to 1 restart_fw" || no "storm coalesce" "1" "$n"
[ ! -d "$LOCK" ] && ok "lock released after run" || no "lock released" "absent" "present"

# --- 2) debounce: event within MIN_INTERVAL is skipped ----------------------
: > "$CNT"; run_hook; sleep 1            # LAST is fresh from test 1
n=$(count); [ "$n" = "0" ] && ok "event within debounce window skipped" || no "debounce skip" "0" "$n"

# --- 3) past the debounce window -> runs again ------------------------------
echo 1 > "$LAST"                          # ancient timestamp -> no debounce
: > "$CNT"; run_hook; sleep 1
n=$(count); [ "$n" = "1" ] && ok "past debounce window restart_fw runs again" || no "post-window run" "1" "$n"

# --- 4) stale lock (>60s) reclaimed -- only where `date -r FILE` = mtime -----
# (busybox/GNU: file mtime; BSD/macOS: arg is epoch seconds -> skip there)
if date -r "$TMP" +%s 2>/dev/null | grep -qE '^[0-9]{10}$'; then
    rm -rf "$LOCK"; mkdir "$LOCK"
    touch -t 202601010000.00 "$LOCK" 2>/dev/null   # backdate ~months
    echo 1 > "$LAST"                                # no debounce
    : > "$CNT"; run_hook; sleep 1
    n=$(count); [ "$n" = "1" ] && ok "stale lock reclaimed -> restart_fw runs" || no "stale lock reclaim" "1" "$n"
    [ ! -d "$LOCK" ] && ok "reclaimed lock released" || no "reclaimed lock released" "absent" "present"
else
    ok "stale-lock test skipped (BSD date -r, not router busybox)"
fi

# --- 5) fresh lock held (<60s) blocks a concurrent event --------------------
rm -f "$LAST"; rm -rf "$LOCK"; mkdir "$LOCK"   # simulate in-flight rebuild
: > "$CNT"; run_hook; sleep 1
n=$(count); [ "$n" = "0" ] && ok "held lock blocks concurrent restart_fw" || no "held lock blocks" "0" "$n"
rm -rf "$LOCK"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
