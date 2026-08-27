#!/bin/sh
# tests/test_diag_warp_reasons.sh — диагностика про WARP отвечает, а не намекает.
#
# ЗАЧЕМ. Три жалобы подряд приходили с одинаковой строкой «WARP включён, но
# туннель не несёт трафик (поднимается)», и она не значила ничего: «поднимается»
# — это пустой last_error, то есть «движок не назвал причину». Под ней
# скрывались три разных состояния:
#   * движок терпеливо идёт по лестнице адресов — ждать;
#   * сессия ВСТАЁТ, но не возит (no_transit) — лестница пойдёт дальше сама;
#   * движок перезапускают снаружи каждые пятнадцать секунд, и лестница не
#     успевает пройти ни разу (поле 2026-08-27).
# Плюс четвёртое, которое диагностика молчала вовсе: туннель поднят, а списков
# адресов не выбрано — WARP работает и не делает НИЧЕГО.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIAG="$ROOT/files/z2k-diag.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

# warp_status_reason читает /tmp/z2k-warp/status.json по абсолютному пути,
# поэтому подменяем не путь, а sed: функция вытаскивает код одной строкой.
reason_for() {
    printf '{"ready":false,"last_error":"%s"}\n' "$1" > "$SB/status.json"
    sed -n '/^warp_status_reason() {/,/^}/p' "$DIAG" \
        | sed "s#/tmp/z2k-warp/status.json#$SB/status.json#" > "$SB/fn.sh"
    sh -c ". '$SB/fn.sh'; warp_status_reason"
}

assert_eq "код no_transit переведён" \
    "сессия встаёт, но сквозная проба не проходит — туннель не возит" "$(reason_for no_transit)"
assert_eq "пустой код — «поднимается»" "поднимается" "$(reason_for '')"
assert_eq "незнакомый код печатается как есть" "чтототакое" "$(reason_for чтототакое)"
for code in register_blocked device_revoked no_endpoint tun_failed; do
    r=$(reason_for "$code")
    if [ -n "$r" ] && [ "$r" != "$code" ]; then ok "код $code переведён"; else no "код $code переведён" "текст" "$r"; fi
done

# Панель и диагностика обязаны знать ОДИН И ТОТ ЖЕ набор кодов: движок пишет
# код, объясняют его двое, и разъехавшись они дают «no_transit» вместо текста.
PANEL="$ROOT/webpanel/www/js/pages/warp.js"
for code in register_blocked device_revoked no_endpoint tun_failed no_transit; do
    if grep -q "$code" "$PANEL"; then ok "панель знает код $code"; else no "панель знает код $code" "есть" "нет"; fi
done
# И у движка не должно быть кода, которого не знает никто.
for code in $(grep -oE 'Err[A-Za-z]+ *= *"[a-z_]+"' "$ROOT/z2k-warpd/internal/status/status.go" | sed 's/.*"\(.*\)"/\1/'); do
    if grep -q "$code" "$DIAG" && grep -q "$code" "$PANEL"; then
        ok "код движка $code объяснён обоими"
    else
        no "код движка $code объяснён обоими" "да" "нет"
    fi
done

# Карусель перезапусков и пустой список — отдельные строки сводки.
if grep -q 'перезапускается по кругу' "$DIAG"; then
    ok "карусель перезапусков названа отдельно от «поднимается»"
else
    no "сводка отличает карусель" "есть" "нет"
fi
if grep -q 'ни один список адресов не выбран' "$DIAG"; then
    ok "поднятый WARP с пустым ipset не молчит"
else
    no "сводка ловит пустой z2k_warp" "есть" "нет"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
