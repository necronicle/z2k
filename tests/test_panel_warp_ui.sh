#!/bin/sh
# tests/test_panel_warp_ui.sh — раздел WARP после переезда на z2k-warpd.
#
# Три состояния раздела рендерятся из одного /warp/status: не установлен (одна
# кнопка «Установить»), установлен (тумблер + статус + «Удалить»), и блок
# «Устройства». Коды ошибок движка переводятся в текст здесь, и все четыре
# должны быть покрыты — иначе панель покажет код. Плюс: раздел отрисовывается
# в харнесе с обоими моками статуса.
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
J="$ROOT/webpanel/www/js/pages/warp.js"
count() { grep -c -- "$1" "$J" 2>/dev/null; return 0; }

assert_eq "install button"                   "1" "$(count 'id="warp-install-btn"')"
assert_eq "remove button"                    "1" "$(count 'id="warp-remove-btn"')"
assert_eq "remove asks confirmation"         "yes" "$(grep -A2 'async function warpRemove' "$J" | grep -q 'confirm(' && echo yes || echo no)"
assert_eq "install posts /warp/install"      "1" "$(count '"/warp/install"')"
assert_eq "remove posts /warp/remove"        "1" "$(count '"/warp/remove"')"
assert_eq "devices: GET"                     "1" "$(count '"/warp/devices"')"
assert_eq "devices: save"                    "1" "$(count '"/warp/devices/save"')"
assert_eq "devices textarea"                 "1" "$(count 'id="warp-devices"')"
for code in register_blocked device_revoked no_endpoint tun_failed; do
    assert_eq "error text for $code"         "1" "$(count "$code:")"
done
assert_eq "no usque wording"                 "0" "$(grep -ci 'usque' "$J")"
assert_eq "no opkgtun wording"               "0" "$(grep -ci 'opkgtun' "$J")"
assert_eq "status uses ready, not tunnel_up" "0" "$(count 'tunnel_up')"

if command -v node >/dev/null 2>&1; then
    JS=$(sh "$ROOT/tests/lib/panel_js.sh")
    for mock in installed uninstalled; do
        out=$(Z2K_WARP_MOCK="$mock" node "$ROOT/tests/panel_harness.js" "$JS" warp 2>&1)
        if printf '%s\n' "$out" | grep -q 'ok  *#/warp$'; then ok "раздел #/warp отрисовался ($mock)"
        else no "раздел #/warp НЕ отрисовался ($mock)" "ok" "$(printf '%s' "$out" | tail -1)"; fi
    done
else
    printf '[SKIP] node не найден — рендер пропущен\n'
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
