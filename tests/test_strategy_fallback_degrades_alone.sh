#!/bin/sh
# tests/test_strategy_fallback_degrades_alone.sh — один битый манифест не должен
# ронять обход целиком, а аварийный набор обязан уметь ротировать.
#
# ЗАЧЕМ. В create_default_strategy_files стояло
#     if [ -n "$p_yt" ] && [ -n "$p_gv" ] && [ -n "$p_rkn" ] && [ -n "$p_quic" ]
# то есть непрочитавшийся ОДИН пул отправлял в аварийный дефолт ВСЕ ЧЕТЫРЕ.
# А сам аварийный дефолт был одиночным `fake:blob=fake_default_tls:repeats=4`
# без circular — то есть один приём и ни одного запасного.
#
# Обе половины били по одному и тому же: порча одного файла на флешке (а нули
# в Strategy.txt на этом железе уже случались) стоила ротации на всех
# категориях сразу. И происходило это МОЛЧА: чтения идут с 2>/dev/null, код
# возврата не проверяется.
#
# Здесь пинится ровно это: деградирует только пострадавший пул, и аварийный
# набор несёт circular и не меньше трёх слотов.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="${Z2K_STRATEGIES_UNDER_TEST:-$ROOT/lib/strategies.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-fallback.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

sed -n '/^default_pool_numbers() {/,/^}/p;/^save_strategy_to_category() {/,/^}/p;/^z2k_emergency_tcp_pool() {/,/^}/p;/^z2k_emergency_quic_pool() {/,/^}/p;/^create_default_strategy_files() {/,/^}/p' \
    "$SRC" > "$TMP/fns.sh"
for _fn in default_pool_numbers save_strategy_to_category z2k_emergency_tcp_pool \
           z2k_emergency_quic_pool create_default_strategy_files; do
    grep -q "^${_fn}() {" "$TMP/fns.sh" || {
        printf '[FAIL] %s не извлеклась из %s\n' "$_fn" "$SRC"
        printf '\n%s: PASS=0 FAIL=1\n' "$(basename "$0")"; exit 1; }
done

print_info() { :; }
print_success() { :; }
print_warning() { printf 'WARN %s\n' "$1" >> "$TMP/warn.log"; }
print_error() { printf 'ERR %s\n' "$1" >> "$TMP/warn.log"; }
build_tls_profile_params()  { printf 'TLSPROFILE(%s)' "$1"; }
build_quic_profile_params() { printf 'QUICPROFILE(%s)' "$1"; }
set_current_quic_strategy() { :; }
get_quic_strategy_num_by_name() { echo 2; }
get_quic_strategy() { [ "$Z2K_TEST_BREAK" = "quic" ] && return 0; echo "quic-params"; }
get_strategy() {
    case "$Z2K_TEST_BREAK" in
        yt)  [ "$1" = "$Z2K_POOL_YT" ]  && return 0 ;;
        gv)  [ "$1" = "$Z2K_POOL_GV" ]  && return 0 ;;
        rkn) [ "$1" = "$Z2K_POOL_RKN" ] && return 0 ;;
    esac
    echo "params-for-$1"
}
# shellcheck disable=SC1091
. "$TMP/fns.sh"

run() {  # run <какой пул ломаем>
    Z2K_TEST_BREAK="$1"
    ZAPRET2_DIR="$TMP/opt/$1"
    export Z2K_TEST_BREAK ZAPRET2_DIR
    rm -rf "$ZAPRET2_DIR"; mkdir -p "$ZAPRET2_DIR"
    : > "$TMP/warn.log"
    create_default_strategy_files >/dev/null 2>&1
}

f_yt="extra_strats/TCP/YT/Strategy.txt"
f_gv="extra_strats/TCP/YT_GV/Strategy.txt"
f_rkn="extra_strats/TCP/RKN/Strategy.txt"
f_q="extra_strats/UDP/YT/Strategy.txt"

# --- 1. всё читается — аварийных наборов нет вовсе ----------------------------
run none
_bad=0
for f in "$f_yt" "$f_gv" "$f_rkn" "$f_q"; do
    grep -q "PROFILE(" "$ZAPRET2_DIR/$f" 2>/dev/null || _bad=$((_bad+1))
done
if [ "$_bad" -eq 0 ]; then
    ok "при читаемых манифестах все четыре пула боевые"
else
    no "при читаемых манифестах все четыре пула боевые" "0 аварийных" "$_bad"
fi

# --- 2. ГЛАВНОЕ: ломаем ОДИН пул — соседи обязаны остаться боевыми ------------
for broken in yt gv rkn quic; do
    run "$broken"
    case "$broken" in
        yt)   victim="$f_yt";  others="$f_gv $f_rkn $f_q" ;;
        gv)   victim="$f_gv";  others="$f_yt $f_rkn $f_q" ;;
        rkn)  victim="$f_rkn"; others="$f_yt $f_gv  $f_q" ;;
        quic) victim="$f_q";   others="$f_yt $f_gv  $f_rkn" ;;
    esac
    _spread=0
    for o in $others; do
        grep -q "PROFILE(" "$ZAPRET2_DIR/$o" 2>/dev/null || _spread=$((_spread+1))
    done
    if [ "$_spread" -eq 0 ]; then
        ok "сломан только $broken — соседние пулы остались боевыми"
    else
        no "сломан только $broken — соседи остались боевыми" "0 задетых" "$_spread"
    fi
    # и сам пострадавший обязан быть аварийным, а не пустым
    if grep -q "lua-desync" "$ZAPRET2_DIR/$victim" 2>/dev/null; then
        ok "  пострадавший пул $broken наполнен аварийным набором"
    else
        no "  пострадавший пул $broken наполнен" "есть стратегии" "пусто"
    fi
done

# --- 3. аварийный набор умеет ротировать -------------------------------------
# Без circular это один приём и ни одного запасного — ровно то, что было.
for key in yt_tcp gv_tcp rkn_tcp; do
    pool=$(z2k_emergency_tcp_pool "$key")
    slots=$(printf '%s' "$pool" | tr ' ' '\n' | grep -c "strategy=")
    uniq_slots=$(printf '%s' "$pool" | tr ' ' '\n' | grep -oE "strategy=[0-9]+" | sort -u | wc -l | tr -d ' ')
    if printf '%s' "$pool" | grep -q "lua-desync=circular:" &&
       printf '%s' "$pool" | grep -q "key=${key}" &&
       [ "${uniq_slots:-0}" -ge 3 ]; then
        ok "аварийный TCP-набор $key: circular есть, слотов $uniq_slots (арм $slots)"
    else
        no "аварийный TCP-набор $key" "circular + >=3 слотов" \
           "circular=$(printf '%s' "$pool" | grep -c 'circular:') слотов=$uniq_slots"
    fi
done

qpool=$(z2k_emergency_quic_pool)
quniq=$(printf '%s' "$qpool" | tr ' ' '\n' | grep -oE "strategy=[0-9]+" | sort -u | wc -l | tr -d ' ')
if printf '%s' "$qpool" | grep -q "lua-desync=circular:" && [ "${quniq:-0}" -ge 3 ]; then
    ok "аварийный QUIC-набор: circular есть, слотов $quniq"
else
    no "аварийный QUIC-набор" "circular + >=3 слотов" "слотов=$quniq"
fi

# --- 4. аварийный набор не зависит от скачанных блобов ------------------------
# В аварии files/fake/ может отсутствовать тоже; ссылка на внешний блоб дала бы
# пул, который не стартует.
_ext=$(z2k_emergency_tcp_pool yt_tcp; z2k_emergency_quic_pool)
_bad_blob=$(printf '%s' "$_ext" | tr ' ' '\n' | grep -oE "blob=[a-z0-9_]+" \
            | grep -v "blob=fake_default_tls" | grep -v "blob=fake_default_quic" | sort -u)
if [ -z "$_bad_blob" ]; then
    ok "аварийные наборы опираются только на встроенные блобы движка"
else
    no "аварийные наборы опираются только на встроенные блобы" "нет внешних" \
       "$(printf '%s' "$_bad_blob" | tr '\n' ' ')"
fi

# --- 5. деградация не проходит молча ------------------------------------------
run gv
if grep -q "WARN" "$TMP/warn.log" 2>/dev/null; then
    ok "деградация пула сообщается предупреждением"
else
    no "деградация пула сообщается" "есть WARN" "тишина"
fi

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
