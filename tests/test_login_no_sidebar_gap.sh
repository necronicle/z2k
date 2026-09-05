#!/bin/sh
# tests/test_login_no_sidebar_gap.sh — на экране входа не остаётся места под
# боковое меню, которого там нет.
#
# Повод: жалобы 05.09.2026. body держит постоянный `padding-left` под
# фиксированный sidebar. На экране входа меню скрывается, а отступ оставался —
# и вся страница вместе с шапкой съезжала вправо на всю его ширину. Замер в
# headless-браузере: при окне 1280 центр карточки стоял на 760 вместо 640,
# то есть ровно на половину ширины меню.
#
# ПОРЯДОК ПРАВИЛ ЗДЕСЬ ЗАГРУЖЕН. У `body[data-page="login"]` и
# `body[data-sidebar="collapsed"]` одинаковая специфичность, поэтому побеждает
# то, что ниже в файле. Если правило входа уедет выше, свёрнутое меню вернёт
# свой отступ и дефект воскреснет только для тех, у кого меню свёрнуто, —
# то есть выборочно и незаметно.
# POSIX sh (busybox ash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CSS="$ROOT/webpanel/www/style.css"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

[ -f "$CSS" ] || { echo "нет $CSS"; exit 1; }

# Блок правила входа: от селектора до закрывающей скобки.
_login_block=$(awk '/^body\[data-page="login"\] \{/{f=1} f{print} f && /^\}/{exit}' "$CSS")

if printf '%s' "$_login_block" | grep -qE 'padding-left:[[:space:]]*0'; then
    ok "экран входа обнуляет место под боковое меню"
else
    bad "экран входа не обнуляет padding-left — страница съедет вправо на ширину меню"
fi

_login_line=$(grep -n '^body\[data-page="login"\] {' "$CSS" | head -1 | cut -d: -f1)
_coll_line=$(grep -n '^body\[data-sidebar="collapsed"\] { padding-left' "$CSS" | head -1 | cut -d: -f1)
if [ -n "$_login_line" ] && [ -n "$_coll_line" ] && [ "$_login_line" -gt "$_coll_line" ]; then
    ok "правило входа стоит ниже правила свёрнутого меню (специфичность равная, решает порядок)"
else
    bad "правило входа стоит выше свёрнутого меню — у кого меню свёрнуто, отступ вернётся"
fi

# Меню на входе скрывается — иначе обнулять отступ было бы нельзя.
if grep -q 'body\[data-page="login"\] #nav' "$CSS"; then
    ok "боковое меню на экране входа скрыто"
else
    bad "меню на входе не скрыто, а место под него убрано — оно ляжет поверх формы"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
