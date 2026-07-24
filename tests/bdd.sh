#!/bin/sh
# tests/bdd.sh — executable acceptance specs (Gherkin) for the WARP behaviours users feel.
#
# The unit suite locks FUNCTIONS; this locks OUTCOMES, in the words a bug report arrives in:
# "включено, а интернета нет", "туннель не поднялся, но написано что работает". Each step
# below drives the REAL functions from files/z2k-warp.sh — the stubs replace the router
# (iptables, ip, the engine), never the logic under test.
#
# Usage: sh tests/bdd.sh [features/warp.feature]
#
# An unmapped step is a FAILURE, not a skip: a scenario that silently does nothing is worse
# than no scenario at all.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEATURE="${1:-$ROOT/tests/features/warp.feature}"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

PASSED=0
FAILED=0
CUR_SCENARIO=""

fail_step() {
    FAILED=$((FAILED + 1))
    printf '    [FAIL] %s\n           %s\n' "$1" "$2"
}
pass_step() { PASSED=$((PASSED + 1)); printf '    [ok] %s\n' "$1"; }

# ---- the world under test ---------------------------------------------------
Z2K_WARP_SOURCE_ONLY=1
export Z2K_WARP_SOURCE_ONLY
# shellcheck disable=SC1091
. "$ROOT/files/z2k-warp.sh"

WARP_DIR="$SB/warp";                 mkdir -p "$WARP_DIR"
WARP_LIVE_STAMP="$SB/live"
WARP_FAIL_STREAK="$SB/streak"
WARP_KICK_STAMP="$SB/kick"
WARP_LIVE_MAXAGE=180
WARP_FAIL_THRESHOLD=3
WARP_PROBE_RETRY_WAIT=0
WARP_KICK_COOLDOWN=300
USQUE_INIT="$SB/init"
# self-heal gates on the ENGINE before anything else; without one it (correctly) tries to
# provision instead of routing, and every scenario below would silentlycheck nothing.
USQUE_BIN="$SB/engine"; printf '#!/bin/sh\nexit 0\n' > "$USQUE_BIN"; chmod 755 "$USQUE_BIN"
USQUE_SESSION="$SB/session.conf"; echo key > "$USQUE_SESSION"
PBR_UP="$SB/pbr_up"; PBR_DOWN="$SB/pbr_down"; RESTARTS="$SB/restarts"

cat > "$USQUE_INIT" <<EOF
#!/bin/sh
echo x >> "$RESTARTS"
exit 0
EOF
chmod 755 "$USQUE_INIT"

# Router-side stubs. Everything below replaces HARDWARE, not decisions.
warp_pbr_up()   { echo x >> "$PBR_UP"; }
warp_pbr_down() { echo x >> "$PBR_DOWN"; }
warp_ipset_load() { return 0; }
warp_purge_legacy_nat() { return 0; }
warp_write_iface_ip() { return 1; }
warp_enroll_or_fallback() { return 1; }
warp_link_up() { return 0; }
warp_flag() { echo 1; }
ipset() { return 0; }
ip() {   # an interface that exists, is addressed and UP — the "looks healthy" case
    if [ "$1" = "-o" ]; then echo "44: $WARP_IFACE    inet 172.16.240.2/32 scope global $WARP_IFACE"; return 0; fi
    if [ "$1" = link ]; then echo "44: $WARP_IFACE: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280"; return 0; fi
    return 0
}
warp_usque_running() { [ -f "$SB/engine_running" ]; }
date_now() { date +%s; }

reset_world() {
    : > "$PBR_UP"; : > "$PBR_DOWN"; : > "$RESTARTS"
    rm -f "$WARP_LIVE_STAMP" "$WARP_FAIL_STREAK" "$WARP_KICK_STAMP"
    touch "$SB/engine_running"
    LAST_STATE=""
}
count() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# A scenario whose steps all failed to parse would otherwise pass silently. Refuse that.
STEPS_IN_SCENARIO=0
check_scenario_had_steps() {
    [ -n "$CUR_SCENARIO" ] || return 0
    [ "$STEPS_IN_SCENARIO" -gt 0 ] && return 0
    FAILED=$((FAILED + 1))
    printf '    [FAIL] scenario executed ZERO steps — the runner is not reading the feature file\n'
}

# ---- step definitions -------------------------------------------------------
# Returns 0 if the step is known AND satisfied, 1 if known and violated, 2 if unmapped.
run_step() {
    step="$1"
    case "$step" in
        "туннель не проводит трафик")
            warp_tunnel_live_retry() { return 1; }; return 0 ;;
        "туннель проводит трафик")
            warp_tunnel_live_retry() { return 0; }; return 0 ;;
        "проверка живости провалилась подряд раз: "*)
            n=${step##*: }
            # the scenario's Nth failure is the one the When performs
            echo $((n - 1)) > "$WARP_FAIL_STREAK"; return 0 ;;
        "движок не запущен")
            rm -f "$SB/engine_running"; return 0 ;;
        "вердикт о живости старше допустимого")
            echo "$(( $(date_now) - 100000 )) 1" > "$WARP_LIVE_STAMP"; return 0 ;;
        "вердикт о живости свежий и положительный")
            echo "$(date_now) 1" > "$WARP_LIVE_STAMP"; return 0 ;;
        "режим выключается")
            warp_disable >/dev/null 2>&1; return 0 ;;
        "выполняется самолечение")
            warp_selfheal >/dev/null 2>&1; return 0 ;;
        "панель спрашивает состояние")
            LAST_STATE=$(warp_live_cached); return 0 ;;

        "маршрутизация снята")
            [ "$(count "$PBR_DOWN")" -ge 1 ] || { REASON="routing was never torn down"; return 1; }; return 0 ;;
        "маршрутизация сохранена")
            [ "$(count "$PBR_DOWN")" -eq 0 ] || { REASON="routing was torn down on a single miss"; return 1; }; return 0 ;;
        "маршрутизация применена")
            [ "$(count "$PBR_UP")" -ge 1 ] || { REASON="routing was never applied"; return 1; }; return 0 ;;
        "трафик идёт напрямую")
            [ "$(count "$PBR_UP")" -eq 0 ] || { REASON="routing was applied into a dead tunnel"; return 1; }; return 0 ;;
        "предпринята попытка восстановления")
            [ "$(count "$RESTARTS")" -ge 1 ] || { REASON="no recovery was attempted"; return 1; }; return 0 ;;
        "движок не перезапускался")
            [ "$(count "$RESTARTS")" -eq 0 ] || { REASON="a healthy tunnel was restarted"; return 1; }; return 0 ;;
        "движок запущен")
            [ "$(count "$RESTARTS")" -ge 1 ] || { REASON="a stopped engine was not started"; return 1; }; return 0 ;;
        "состояние неизвестно")
            [ -z "$LAST_STATE" ] || { REASON="stale verdict reported as '$LAST_STATE'"; return 1; }; return 0 ;;
        "состояние живое")
            [ "$LAST_STATE" = "1" ] || { REASON="fresh live verdict reported as '$LAST_STATE'"; return 1; }; return 0 ;;
        "вердикт о живости удалён")
            [ ! -f "$WARP_LIVE_STAMP" ] || { REASON="the liveness verdict outlived the mode"; return 1; }; return 0 ;;
        *) return 2 ;;
    esac
}

# ---- the runner -------------------------------------------------------------
printf 'Gherkin: %s\n' "$FEATURE"
[ -f "$FEATURE" ] || { echo "feature file not found"; exit 1; }

while IFS= read -r raw; do
    line=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$line" in
        ''|'#'*) continue ;;
        'Функция:'*|'Feature:'*) printf '\n%s\n' "$line"; continue ;;
        'Как '*|'Я хочу'*|'Чтобы '*) continue ;;
        'Сценарий:'*|'Scenario:'*)
            check_scenario_had_steps
            CUR_SCENARIO=${line#*: }
            STEPS_IN_SCENARIO=0
            reset_world
            printf '\n  Сценарий: %s\n' "$CUR_SCENARIO"
            continue ;;
    esac
    # Strip the step keyword with `case`, NOT sed alternation: BSD sed has no \| in BREs, so
    # the sed version silently matched nothing, every line was treated as prose, and the whole
    # suite reported "0 steps" while looking green. Portability bugs in a TEST HARNESS are the
    # worst kind — they turn verification into decoration.
    case "$line" in
        'Дано '*)  text=${line#Дано } ;;
        'Когда '*) text=${line#Когда } ;;
        'Тогда '*) text=${line#Тогда } ;;
        'И '*)     text=${line#И } ;;
        'Given '*) text=${line#Given } ;;
        'When '*)  text=${line#When } ;;
        'Then '*)  text=${line#Then } ;;
        'And '*)   text=${line#And } ;;
        *) continue ;;   # prose, not a step
    esac
    STEPS_IN_SCENARIO=$((STEPS_IN_SCENARIO + 1))
    REASON=""
    run_step "$text"; rc=$?
    case "$rc" in
        0) pass_step "$line" ;;
        1) fail_step "$line" "$REASON" ;;
        2) fail_step "$line" "UNMAPPED STEP — the scenario is not actually being checked" ;;
    esac
done < "$FEATURE"

check_scenario_had_steps
printf '\n=== BDD: %d steps passed, %d failed ===\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
