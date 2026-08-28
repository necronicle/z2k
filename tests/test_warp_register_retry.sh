#!/bin/sh
# tests/test_warp_register_retry.sh — selfheal чинит НЕЗАРЕГИСТРИРОВАННОЕ устройство.
#
# ЧТО БЫЛО. warp_selfheal проверял три вещи: флаг, бинарь и живость демона.
# Наличия ключа устройства (device.json) он не проверял вовсе. А движок без
# ключа падает на старте всегда:
#
#   fatal: device.json: open /opt/etc/z2k-warp/device.json: no such file
#
# Значит warp_daemon_running вечно ложь, и selfheal поднимал заведомого
# покойника каждые 25 секунд. Поле 2026-08-28: карусель шла больше суток, в
# журнале сорок таких «fatal» подряд, а починить это могла только кнопка
# «Установить» руками — регистрация жила ТОЛЬКО в warp_install.
#
# Как получается такое состояние: warp_install сначала кладёт движок, потом
# регистрирует. Движок встал, регистрация не прошла (API Cloudflare заблокирован,
# релей не выручил) — и человек остаётся с бинарём, включённым флагом и без ключа.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W="$ROOT/files/z2k-warp.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

mkdir -p "$SB/stub" "$SB/zd" "$SB/log"
for c in ipset ip iptables ip6tables; do
    printf '#!/bin/sh\nexit 0\n' > "$SB/stub/$c"; chmod +x "$SB/stub/$c"
done
printf 'GAME_WARP_ENABLED=1\n' > "$SB/zd/config"

# Движок-заглушка: пишет, с чем его звали. REG_RC задаёт исход регистрации,
# REG_WRITES=1 — успешная регистрация создаёт ключ, как настоящая.
cat > "$SB/warpd" <<'STUB'
#!/bin/sh
echo "$@" >> "$CALLS"
case "$1" in
    register)
        [ "${REG_WRITES:-0}" = "1" ] && printf '{"id":"x"}\n' > "$3"
        echo "register rc=${REG_RC:-1}"
        exit "${REG_RC:-1}" ;;
    version) exit 0 ;;
esac
exit 0
STUB
chmod +x "$SB/warpd"

# init-заглушка: status всегда «не запущен» (движка ведь нет), start отмечается.
cat > "$SB/init" <<'STUB'
#!/bin/sh
echo "init:$1" >> "$CALLS"
[ "$1" = "status" ] && exit 1
exit 0
STUB
chmod +x "$SB/init"

run_selfheal() {
    CALLS="$SB/calls" \
    REG_RC="$1" REG_WRITES="$2" \
    Z2K_STUB_PATH="$SB/stub" \
    ZAPRET2_DIR="$SB/zd" CONFIG_FILE="$SB/zd/config" \
    WARP_BIN="$SB/warpd" WARP_INIT="$SB/init" \
    WARP_DEVICE="$SB/device.json" WARP_STATUS="$SB/status.json" \
    WARP_LOG="$SB/log/warpd.log" WARP_REG_STAMP="$SB/reg.stamp" \
    WARP_REG_RETRY="${3:-600}" \
    WARP_LISTS_DIR="$SB/zd/lists/warp" \
    sh "$W" selfheal >/dev/null 2>&1
}

# --- 1. Нет ключа — selfheal РЕГИСТРИРУЕТ, а не поднимает труп ----------------
: > "$SB/calls"; rm -f "$SB/device.json" "$SB/reg.stamp"
run_selfheal 1 0
# Два вызова — это напрямую и следом через релей, обе ступени warp_register.
assert_eq "нет ключа: регистрация вызвана (напрямую + релей)" "2" "$(grep -c '^register ' "$SB/calls")"
assert_eq "нет ключа: демон не запускается впустую" "0" "$(grep -c '^init:start' "$SB/calls")"
case "$(cat "$SB/calls")" in
    *"--proxy"*) ok "провал напрямую: пробуется релей" ;;
    *) no "провал напрямую: пробуется релей" "--proxy" "$(cat "$SB/calls")" ;;
esac

# --- 2. Причина видна человеку: пишем в журнал движка, а не в /dev/null -------
case "$(cat "$SB/log/warpd.log" 2>/dev/null)" in
    *"нет ключа устройства"*) ok "причина попала в журнал движка" ;;
    *) no "причина попала в журнал движка" "нет ключа устройства" "$(cat "$SB/log/warpd.log" 2>/dev/null)" ;;
esac

# --- 3. Заблокированный API не долбим каждые 25 с ----------------------------
: > "$SB/calls"
run_selfheal 1 0
assert_eq "повтор в пределах окна: регистрации нет" "0" "$(grep -c '^register ' "$SB/calls")"

# --- 4. Окно вышло — пробуем снова, и удача поднимает демон -------------------
: > "$SB/calls"
run_selfheal 0 1 0
assert_eq "окно вышло: регистрация повторена" "1" "$(grep -c '^register ' "$SB/calls")"
assert_eq "успешная регистрация: демон поднят" "1" "$(grep -c '^init:start' "$SB/calls")"
assert_eq "ключ устройства создан" "1" "$([ -s "$SB/device.json" ] && echo 1 || echo 0)"

# --- 5. Ключ есть — обычный путь, регистрация не трогается --------------------
: > "$SB/calls"; rm -f "$SB/reg.stamp"
run_selfheal 1 0
assert_eq "ключ есть: регистрации нет" "0" "$(grep -c '^register ' "$SB/calls")"
assert_eq "ключ есть: демон поднимается как раньше" "1" "$(grep -c '^init:start' "$SB/calls")"

# --- 6. WARP выключен — selfheal молчит --------------------------------------
: > "$SB/calls"; rm -f "$SB/device.json" "$SB/reg.stamp"
printf 'GAME_WARP_ENABLED=0\n' > "$SB/zd/config"
run_selfheal 1 0
assert_eq "выключен: ни регистрации, ни старта" "0" "$(grep -c . "$SB/calls")"
printf 'GAME_WARP_ENABLED=1\n' > "$SB/zd/config"

# --- 7. Контракт: регистрация — общая функция, а не копия в двух местах -------
assert_eq "warp_register существует" "1" "$(grep -c '^warp_register() {' "$W")"
assert_eq "вызов register не размножен" "2" "$(grep -c '"\$WARP_BIN" register' "$W")"
case "$(sed -n '/^warp_selfheal() {/,/^}/p' "$W")" in
    *'WARP_DEVICE'*) ok "selfheal смотрит на ключ устройства" ;;
    *) no "selfheal смотрит на ключ устройства" "WARP_DEVICE" "нет" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
