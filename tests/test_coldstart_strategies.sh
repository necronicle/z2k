#!/bin/sh
# tests/test_coldstart_strategies.sh — установка сразу кладёт боевые пулы.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Порядок на свежей установке был такой:
#
#   install.sh: create_default_strategy_files  → ЗАГЛУШКИ
#   install.sh: create_official_config         → NFQWS2_OPT из ЗАГЛУШЕК
#             ...
#   install.sh: apply_autocircular_strategies  → боевые пулы, конфиг заново
#
# Заглушкой для TCP был ОДИН фейк без circular вообще, для UDP — четыре
# килобайта захардкоженного QUIC-пула прямо в strategies.sh (третья копия того
# же пула: две другие в config_official.sh и quic_strats.ini, и они уже
# разъехались по udp_in). То есть конфиг собирался дважды, первый раз — без
# ротации; обрыв установки между шагами оставлял человека с одним фейком.
#
# ЧТО ОХРАНЯЕТСЯ:
#
#   1. Материализация идёт из манифестов, и в каждом пуле есть circular —
#      то есть это пул, а не заглушка.
#   2. Записанное СОВПАДАЕТ с тем, что позже пишет apply: одна формула на
#      обоих путях, поздний шаг идемпотентен.
#   3. Номера пулов живут в одном месте (default_pool_numbers) и совпадают
#      с тем, что реально применяет apply.
#   4. Захардкоженной копии QUIC-пула в strategies.sh больше нет.
#   5. Без манифестов установка не падает — есть минимальный дефолт.
#
# POSIX sh. Настоящие функции продукта на временном дереве.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$ROOT/lib/strategies.sh" >/dev/null 2>&1

print_info()    { :; }
print_success() { :; }
print_warning() { :; }
print_error()   { :; }

# Манифесты → conf, ровно как это делает z2k.sh перед установкой.
CONFIG_DIR="$TMP/etc"; mkdir -p "$CONFIG_DIR"
STRATEGIES_CONF="$CONFIG_DIR/strategies.conf"
QUIC_STRATEGIES_CONF="$CONFIG_DIR/quic_strategies.conf"
QUIC_STRATEGY_FILE="$CONFIG_DIR/quic_strategy.conf"
generate_strategies_conf "$ROOT/strats_new2.txt" "$STRATEGIES_CONF" >/dev/null 2>&1
generate_quic_strategies_conf "$ROOT/quic_strats.ini" "$QUIC_STRATEGIES_CONF" >/dev/null 2>&1
[ -s "$STRATEGIES_CONF" ] && [ -s "$QUIC_STRATEGIES_CONF" ] \
    || { printf '[FAIL] харнесс: манифесты не разобрались\n'; exit 1; }

ZAPRET2_DIR="$TMP/opt/zapret2"
mkdir -p "$ZAPRET2_DIR"
create_default_strategy_files >/dev/null 2>&1

ES="$ZAPRET2_DIR/extra_strats"

# --- 1. В каждом пуле есть ротация ------------------------------------------
for f in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
    if grep -q -- '--lua-desync=circular:' "$ES/$f/Strategy.txt" 2>/dev/null; then
        ok "$f: пул с ротацией, а не заглушка"
    else
        no "$f: пул с ротацией" "есть circular" "$(head -c 60 "$ES/$f/Strategy.txt" 2>/dev/null)"
    fi
done

# --- 2. Совпадает с формулой apply ------------------------------------------
default_pool_numbers; YT=$Z2K_POOL_YT; GV=$Z2K_POOL_GV; RKN=$Z2K_POOL_RKN
_quic=$(get_quic_strategy_num_by_name "yt_quic_autocircular"); [ -n "$_quic" ] || _quic=2

cmp_pool() {   # $1 — путь пула, $2 — ожидаемое содержимое
    if [ "$(cat "$1" 2>/dev/null)" = "$2" ]; then
        ok "$(basename "$(dirname "$1")"): совпадает с тем, что напишет apply"
    else
        no "$(basename "$(dirname "$1")"): совпадает с apply" "как у apply" "разошлось"
    fi
}
cmp_pool "$ES/TCP/YT/Strategy.txt"    "$(build_tls_profile_params "$(get_strategy "$YT")")"
cmp_pool "$ES/TCP/YT_GV/Strategy.txt" "$(build_tls_profile_params "$(get_strategy "$GV")")"
cmp_pool "$ES/TCP/RKN/Strategy.txt"   "$(build_tls_profile_params "$(get_strategy "$RKN")")"
cmp_pool "$ES/UDP/YT/Strategy.txt"    "$(build_quic_profile_params "$(get_quic_strategy "$_quic")")"

# --- 3. Номера пулов — из одного места --------------------------------------
_apply_nums=$(grep -c '^\s*default_pool_numbers; ' "$ROOT/lib/strategies.sh")
if [ "$_apply_nums" -ge 2 ]; then
    ok "номера пулов читаются из default_pool_numbers в обоих путях ($_apply_nums)"
else
    no "номера пулов в одном месте" ">=2 обращения" "$_apply_nums"
fi
if grep -qE '^\s*local yt_tcp=[0-9]' "$ROOT/lib/strategies.sh"; then
    no "захардкоженных номеров нет" "нет literal yt_tcp=N" "остались"
else
    ok "захардкоженных номеров пулов не осталось"
fi
# И выбор QUIC-пула зафиксирован — иначе поздний apply перепишет файл зря.
if grep -q "QUIC_STRATEGY=$_quic" "$QUIC_STRATEGY_FILE" 2>/dev/null; then
    ok "выбранный QUIC-пул зафиксирован (#$_quic)"
else
    no "QUIC-пул зафиксирован" "QUIC_STRATEGY=$_quic" "$(cat "$QUIC_STRATEGY_FILE" 2>/dev/null)"
fi

# --- 4. Захардкоженной копии QUIC-пула больше нет ---------------------------
_hard=$(grep -c 'lua-desync=z2k_quic_morph_v2' "$ROOT/lib/strategies.sh")
if [ "$_hard" = "0" ]; then
    ok "четырёхкилобайтная копия QUIC-пула убрана из strategies.sh"
else
    no "копия QUIC-пула убрана" "0 вхождений" "$_hard — третья копия пула вернулась"
fi

# --- 5. Без манифестов установка не встаёт ----------------------------------
Z2="$TMP/opt2/zapret2"; mkdir -p "$Z2"
(
    ZAPRET2_DIR="$Z2"
    STRATEGIES_CONF="$TMP/nope.conf"
    QUIC_STRATEGIES_CONF="$TMP/nope2.conf"
    create_default_strategy_files >/dev/null 2>&1
)
_rc=$?
if [ "$_rc" = "0" ] && [ -s "$Z2/extra_strats/TCP/RKN/Strategy.txt" ]; then
    ok "без манифестов ставится минимальный дефолт, установка не падает"
else
    no "фоллбэк без манифестов" "rc=0 и файл на месте" "rc=$_rc"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
