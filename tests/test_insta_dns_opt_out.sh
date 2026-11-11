#!/bin/sh
# tests/test_insta_dns_opt_out.sh — issue #39: убранные через [I] статические IP
# Instagram не возвращаются обновлением.
#
# Сторож «ноль записей = юзер сам убрал» жил только в z2k-insta-ip-refresh.sh;
# install.sh его не видел и на каждом обновлении прошивал записи заново. Теперь
# решение юзера — флаг Z2K_INSTA_DNS в конфиге (0 = убрал, 1 = вернул), который
# переживает реинсталл как остальные Z2K_* и который уважают все три места:
# установка, ежедневный рефреш и само меню. POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

# --- 1. флаг переживает реинсталл: config_official читает и пишет его ---
C="$ROOT/lib/config_official.sh"
assert_eq "config: saved_Z2K_INSTA_DNS читается из старого конфига" "1" \
    "$(grep -c 'saved_Z2K_INSTA_DNS=$(safe_config_read "Z2K_INSTA_DNS" "$config_file" "1")' "$C")"
assert_eq "config: Z2K_INSTA_DNS пишется в новый конфиг" "1" "$(grep -c '^Z2K_INSTA_DNS=${saved_Z2K_INSTA_DNS}' "$C")"

# --- 2. install.sh: при Z2K_INSTA_DNS=0 записи не прошиваются ---
I="$ROOT/lib/install.sh"
assert_eq "install: прошивка гейтится флагом" "yes" \
    "$(grep -B6 'z2k_instagram_dns_add_fallback$' "$I" | grep -q 'Z2K_INSTA_DNS' && echo yes || echo no)"

# The independent VPS WhatsApp block must still run with Instagram disabled.
block=$(awk '/    # upgrades any stale/ {relay=1}
    relay && /    # Telegram transparent proxy/ {relay=0}
    relay {print}' "$I")
mkdir -p "$SB/relay-bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SB/relay.log"\n' > "$SB/relay-bin/ndmc"
chmod +x "$SB/relay-bin/ndmc"
export SB
PATH="$SB/relay-bin:$PATH" sh -c "safe_config_read() { echo 0; }; print_success() { :; }; print_info() { :; }; relay_test() { $block
}; relay_test"
assert_eq "install: Instagram opt-out сохраняет мобильный WA" "9" \
    "$(grep -c -- '-c ip host .* 85.192.60.175$' "$SB/relay.log" || true)"

# --- 3. refresh: при Z2K_INSTA_DNS=0 выходит до ndmc ---
R="$ROOT/files/z2k-insta-ip-refresh.sh"
mkdir -p "$SB/bin" "$SB/z2k"
printf '#!/bin/sh\necho "$*" >> "%s/ndmc.log"\nexit 0\n' "$SB" > "$SB/bin/ndmc"; chmod +x "$SB/bin/ndmc"
printf 'Z2K_INSTA_DNS=0\n' > "$SB/z2k/config"
PATH="$SB/bin:$PATH" ZAPRET2_DIR="$SB/z2k" CONFIG_FILE="$SB/z2k/config" LOG_FILE="$SB/refresh.log" sh "$R" >/dev/null 2>&1
assert_eq "refresh: при флаге 0 ndmc не трогается" "0" "$([ -f "$SB/ndmc.log" ] && wc -l < "$SB/ndmc.log" | tr -d ' ' || echo 0)"
assert_eq "refresh: причина в журнале" "1" "$(grep -ci 'Z2K_INSTA_DNS' "$SB/refresh.log" 2>/dev/null || echo 0)"

# --- 4. меню: «убрать» пишет 0, «вернуть» пишет 1 ---
M="$ROOT/lib/menu.sh"
assert_eq "menu: убрать → Z2K_INSTA_DNS=0" "1" "$(grep -c 'set_flag "Z2K_INSTA_DNS" "0"' "$M")"
assert_eq "menu: вернуть → Z2K_INSTA_DNS=1" "1" "$(grep -c 'set_flag "Z2K_INSTA_DNS" "1"' "$M")"

# --- 5. пропавшие записи возвращаются, если флаг не 0 (поле 15.09.2026) ---
# Раньше рефреш видел «записей нет» и выходил, считая, что их убрал пользователь,
# — хотя отказ давно пишется флагом. Instagram не открывался, пока кто-нибудь не
# ставил затравочную запись руками.
SB5="$SB/case5"; mkdir -p "$SB5/bin" "$SB5/z2k"
cat > "$SB5/bin/ndmc" <<EOF5
#!/bin/sh
case "\$*" in
    *"show running-config"*) : ;;
    *) echo "\$*" >> "$SB5/ndmc.log" ;;
esac
exit 0
EOF5
cat > "$SB5/bin/openssl" <<'EOF5'
#!/bin/sh
cat >/dev/null; echo "(stdin)= 00ff"
EOF5
cat > "$SB5/bin/curl" <<'EOF5'
#!/bin/sh
case "$*" in
    *"/resolve"*) printf '%s' '{"results":{"instagram.com":["157.240.9.174"]}}' ;;
    *) printf '200' ;;
esac
exit 0
EOF5
chmod +x "$SB5/bin/ndmc" "$SB5/bin/openssl" "$SB5/bin/curl"
printf 'Z2K_INSTA_DNS=1\nZ2K_RESOLVE_SECRET=test\n' > "$SB5/z2k/config"
Z2K_STUB_PATH="$SB5/bin" ZAPRET2_DIR="$SB5/z2k" CONFIG_FILE="$SB5/z2k/config" LOG_FILE="$SB5/refresh.log" sh "$R" >/dev/null 2>&1
assert_eq "refresh: без записей и с флагом 1 адрес прописан заново" "1" \
    "$(cat "$SB5/ndmc.log" 2>/dev/null | grep -c 'ip host instagram.com 157.240.9.174$')"
assert_eq "refresh: старый сторож «нет записей — выход» не срабатывает" "0" \
    "$(cat "$SB5/refresh.log" 2>/dev/null | grep -c 'cleared by user')"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
