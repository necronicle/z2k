#!/bin/sh
# tests/test_warp_no_strategy_tuning.sh — WARP не крутит ротацию обхода ради себя.
#
# ЧТО БЫЛО. Туннель не вставал → warp_enable запускал фоном подборщик плеча:
# закреплял rkn_tcp/cloudflareclient.com|4 на очередном номере в режиме
# «manual», перезапускал движок и смотрел, встанет ли MASQUE. До пятидесяти
# заходов.
#
# ПОЧЕМУ УДАЛЕНО. Цена оказалась выше пользы:
#   * «manual» ротатор не трогает НИКОГДА — брошенный на полпути подбор
#     оставлял хост навсегда на случайном плече (замер на роутере владельца
#     2026-08-27: одиннадцатое, при выключенном WARP);
#   * перебор рвал движку лестницу транспортов: она не успевала пройти ни разу;
#   * туннель, меняющий стратегию обхода ради себя, — это не его дело.
#
# Этот набор — сторож решения: подбор не должен вернуться ни одной строкой, а
# оставленное им закрепление обязано сниматься.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W="$ROOT/files/z2k-warp.sh"
INIT="$ROOT/files/init.d/S51z2k-warp"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM
TAB=$(printf '\t')

# --- 1. Подборщика нет ни в одной форме --------------------------------------
for pat in warp_masque_tune warp_state_pin WARP_TUNE_MAX WARP_TUNE_WAIT WARP_TUNE_RUN WARP_TUNE_CURSOR; do
    assert_eq "в z2k-warp.sh нет $pat" "0" "$(grep -c "$pat" "$W")"
done
assert_eq "init не знает про форс транспорта" "0" "$(grep -c 'Z2K_WARP_FORCE\|FORCE_ARG' "$INIT")"
assert_eq "enable не запускает ничего фоном" "0" \
    "$(grep -vE '^[[:space:]]*#' "$W" | grep -c 'trap .. HUP')"

# --- 2. Закрепление, оставленное подборщиком, снимается -----------------------
mk_state() {
    printf '# z2k autocircular state\n' > "$1"
    printf 'rkn_tcp%scloudflareclient.com|4%s11%s1787838597%smanual\n' "$TAB" "$TAB" "$TAB" "$TAB" >> "$1"
    printf 'rkn_tcp%sinstagram.com|4%s2%s1787824184%sauto\n'          "$TAB" "$TAB" "$TAB" "$TAB" >> "$1"
    printf 'rkn_tcp%smy.own.host|4%s7%s1787824184%smanual\n'          "$TAB" "$TAB" "$TAB" "$TAB" >> "$1"
}
mk_state "$SB/state.tsv"; mk_state "$SB/fallback.tsv"

cat > "$SB/env.sh" <<INNER
ZAPRET2_DIR="$SB/zd"
WARP_STATE="$SB/state.tsv"
WARP_STATE_FALLBACK="$SB/fallback.tsv"
$(sed -n '/^WARP_TUNE_KEY=/,/^WARP_TUNE_HOST=/p;/^warp_unpin_legacy() {/,/^}/p' "$W")
_wlog() { echo "[z2k-warp] \$*" >&2; }
INNER
sh -c ". '$SB/env.sh'; warp_unpin_legacy" 2>/dev/null

for f in state.tsv fallback.tsv; do
    assert_eq "$f: закрепление подборщика снято" "0" \
        "$(grep -c 'cloudflareclient' "$SB/$f")"
    assert_eq "$f: чужая ручная запись не тронута" "1" \
        "$(grep -c 'my.own.host' "$SB/$f")"
    assert_eq "$f: авто-запись не тронута" "1" \
        "$(grep -c 'instagram.com' "$SB/$f")"
done

# --- 3. Повторный вызов ничего не портит и не шумит ---------------------------
_before=$(cat "$SB/state.tsv")
_out=$(sh -c ". '$SB/env.sh'; warp_unpin_legacy" 2>&1)
assert_eq "повторная уборка не меняет файл" "$_before" "$(cat "$SB/state.tsv")"
assert_eq "и молчит"                        ""         "$_out"

# --- 4. Уборка подключена к обеим кнопкам -------------------------------------
assert_eq "enable зовёт уборку" "1" \
    "$(sed -n '/^warp_enable() {/,/^}/p' "$W" | grep -c 'warp_unpin_legacy')"
assert_eq "disable тоже"        "1" \
    "$(sed -n '/^warp_disable() {/,/^}/p' "$W" | grep -c 'warp_unpin_legacy')"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
