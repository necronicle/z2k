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
# Источник правды о туннеле — status.json движка z2k-warpd. Стабы ниже заменяют
# РОУТЕР (iptables, ip, ipset, init движка), а не решения обвязки.
Z2K_WARP_SOURCE_ONLY=1
export Z2K_WARP_SOURCE_ONLY
WARP_BIN="$SB/engine"; printf '#!/bin/sh\nexit 0\n' > "$WARP_BIN"; chmod 755 "$WARP_BIN"
WARP_INIT="$SB/init"
WARP_DEVICE="$SB/device.json"; printf '{"iface":"z2ktun0","id":"dev"}\n' > "$WARP_DEVICE"
WARP_STATUS="$SB/status.json"
WARP_LISTS_DIR="$SB/lists"; mkdir -p "$WARP_LISTS_DIR/games"
CONFIG_FILE="$SB/config"; printf 'GAME_WARP_ENABLED=1\n' > "$CONFIG_FILE"
WARP_READY_WAIT=1
export WARP_BIN WARP_INIT WARP_DEVICE WARP_STATUS WARP_LISTS_DIR CONFIG_FILE WARP_READY_WAIT
# shellcheck disable=SC1091
. "$ROOT/files/z2k-warp.sh"

PBR_UP="$SB/pbr_up"; PBR_DOWN="$SB/pbr_down"; RESTARTS="$SB/restarts"; STOPS="$SB/stops"

cat > "$WARP_INIT" <<EOF
#!/bin/sh
case "\$1" in
    start)  echo x >> "$RESTARTS"; touch "$SB/engine_running" ;;
    stop)   echo x >> "$STOPS"; rm -f "$SB/engine_running" ;;
    status) [ -f "$SB/engine_running" ] ;;
esac
EOF
chmod 755 "$WARP_INIT"

# Router-side stubs. Everything below replaces HARDWARE, not decisions.
warp_pbr_up()   { echo x >> "$PBR_UP"; }
warp_pbr_down() { echo x >> "$PBR_DOWN"; }
warp_ipset_all() { return 0; }
warp_ipset_src_load() { return 0; }
ipset() { case "$*" in list*) echo "Members:"; return 0 ;; esac; return 0; }
ip() { return 0; }
iptables() { return 0; }

status_json() { # $1 = true|false, $2 = last_error
    printf '{"ready":%s,"transport":"wg","endpoint":"8.6.112.0:2408","iface":"z2ktun0","addr":"172.16.0.2","last_error":"%s"}\n' "$1" "${2:-}" > "$WARP_STATUS"
}

reset_world() {
    : > "$PBR_UP"; : > "$PBR_DOWN"; : > "$RESTARTS"; : > "$STOPS"
    rm -f "$WARP_STATUS"
    touch "$SB/engine_running"
    printf '#!/bin/sh\nexit 0\n' > "$WARP_BIN"; chmod 755 "$WARP_BIN"
    printf 'GAME_WARP_ENABLED=1\n' > "$CONFIG_FILE"
    LAST_STATE=""; LAST_RC=""; LAST_OUT=""
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
        "движок сообщает, что туннель не проводит трафик")
            status_json false; return 0 ;;
        "движок сообщает, что туннель проводит трафик")
            status_json true; return 0 ;;
        "причина отказа: "*)
            status_json false "${step##*: }"; return 0 ;;
        "движок не запущен")
            rm -f "$SB/engine_running"; return 0 ;;
        "движок не установлен")
            rm -f "$WARP_BIN"; rm -f "$SB/engine_running"; return 0 ;;
        "движок не оставил вердикта")
            rm -f "$WARP_STATUS"; return 0 ;;
        "режим выключается")
            warp_disable >/dev/null 2>&1; return 0 ;;
        "режим включается")
            LAST_OUT=$(warp_enable 2>&1); LAST_RC=$?; return 0 ;;
        "выполняется самолечение")
            warp_selfheal >/dev/null 2>&1; return 0 ;;
        "панель спрашивает состояние")
            LAST_STATE=$(warp_status | sed -n 's/.*ready=\([01]\).*/\1/p'); return 0 ;;

        "маршрутизация снята")
            [ "$(count "$PBR_DOWN")" -ge 1 ] || { REASON="routing was never torn down"; return 1; }; return 0 ;;
        "маршрутизация применена")
            [ "$(count "$PBR_UP")" -ge 1 ] || { REASON="routing was never applied"; return 1; }; return 0 ;;
        "маршрутизация не трогалась")
            [ "$(count "$PBR_UP")" -eq 0 ] && [ "$(count "$PBR_DOWN")" -eq 0 ] || { REASON="routing was touched"; return 1; }; return 0 ;;
        "трафик идёт напрямую")
            [ "$(count "$PBR_UP")" -eq 0 ] || { REASON="routing was applied into a dead tunnel"; return 1; }; return 0 ;;
        "движок не перезапускался")
            [ "$(count "$RESTARTS")" -eq 0 ] || { REASON="engine was (re)started"; return 1; }; return 0 ;;
        "движок запущен")
            [ "$(count "$RESTARTS")" -ge 1 ] || { REASON="a stopped engine was not started"; return 1; }; return 0 ;;
        "движок остановлен")
            [ "$(count "$STOPS")" -ge 1 ] || { REASON="engine was not stopped"; return 1; }; return 0 ;;
        "включение ответило кодом "*)
            [ "$LAST_RC" = "${step##*кодом }" ] || { REASON="enable rc=$LAST_RC"; return 1; }; return 0 ;;
        "причина названа: "*)
            printf '%s' "$LAST_OUT" | grep -q "${step##*: }" || { REASON="reason missing in: $LAST_OUT"; return 1; }; return 0 ;;
        "состояние не живое")
            [ "$LAST_STATE" = "0" ] || { REASON="missing verdict reported as '$LAST_STATE'"; return 1; }; return 0 ;;
        "состояние живое")
            [ "$LAST_STATE" = "1" ] || { REASON="fresh live verdict reported as '$LAST_STATE'"; return 1; }; return 0 ;;
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
