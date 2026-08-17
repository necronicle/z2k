#!/bin/sh
# tests/test_diag_tg_redirect.sh — сводка диагностики замечает пропавшие правила
# редиректа телеграма.
#
# ЗАЧЕМ. Полевой случай, issue #34 (2026-08-17), «Telegram постоянно в
# состоянии Подключение…». В присланной диагностике честно напечатано:
#
#   TG REDIR PREROUT  : 0  (expected 1 — ipset match-set, r-50+)
#   TG REDIR OUTPUT   : 0  (expected 1 — ipset match-set, r-50+)
#
# а сводкой выше — «явных проблем не найдено». Сводка про эти правила не
# спрашивала вовсе: она проверяла только, запущен ли процесс туннеля. Процесс
# был запущен, поэтому и молчание. Человек читает первую строку и успокаивается,
# а трафик к дата-центрам телеграма всё это время идёт мимо туннеля прямо в WAN,
# где его и режут.
#
# ЧТО ОХРАНЯЕТСЯ:
#   1. Сводка спрашивает про правила редиректа, а не только про процесс.
#   2. Числа для деталей и для сводки берутся из ОДНОГО места — иначе они
#      разойдутся, и вернётся ровно то же расхождение «в деталях ноль, в
#      сводке порядок».
#   3. Помощник считает оба правила и на пустом выводе iptables отдаёт нули,
#      а не пустую строку (пустая строка в сравнении `=` сломала бы проверку).
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DIAG="$ROOT/files/z2k-diag.sh"
[ -f "$DIAG" ] || { printf '[FAIL] нет %s\n' "$DIAG"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- 1. Сводка спрашивает про правила ----------------------------------------
_sum=$(awk '/printf .=== что не так/{exit} /_add "/{print}' "$DIAG")
if printf '%s' "$_sum" | grep -q 'правила редиректа телеграма'; then
    ok "сводка «что не так» проверяет правила редиректа"
else
    no "сводка проверяет редирект" "строка про правила редиректа" "нет — вернулось молчание из #34"
fi

# --- 2. Один источник чисел для деталей и сводки ------------------------------
_uses=$(grep -c 'tg_redirect_counts' "$DIAG")
if [ "$_uses" -ge 4 ]; then
    ok "детали и сводка считают правила одним помощником ($_uses обращения)"
else
    no "один источник чисел" ">=4 обращений к tg_redirect_counts" "$_uses"
fi
# И никто не считает их мимо помощника: второй grep по 'redir ports 1443'
# означал бы, что подсчёт снова продублирован.
_raw=$(grep -c "grep -c 'redir ports 1443'" "$DIAG")
if [ "$_raw" -le 2 ]; then
    ok "подсчёт не продублирован мимо помощника"
else
    no "подсчёт не продублирован" "<=2 вхождений" "$_raw"
fi

# --- 3. Помощник исполняется и отдаёт нули на пустом iptables -----------------
awk '/^tg_redirect_counts\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$DIAG" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { printf '[FAIL] помощник tg_redirect_counts не найден\n'; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/iptables" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$TMP/bin/iptables"
_out=$( PATH="$TMP/bin:$PATH"; . "$TMP/fn.sh"; tg_redirect_counts )
if [ "$_out" = "0 0" ]; then
    ok "без правил помощник отдаёт «0 0», а не пустоту"
else
    no "нули на пустом выводе" "0 0" "$_out"
fi

cat > "$TMP/bin/iptables" <<'STUB'
#!/bin/sh
echo "REDIRECT   tcp  --  0.0.0.0/0   0.0.0.0/0   match-set z2k_tg_dc dst tcp dpt:443 redir ports 1443"
STUB
chmod +x "$TMP/bin/iptables"
_out=$( PATH="$TMP/bin:$PATH"; . "$TMP/fn.sh"; tg_redirect_counts )
if [ "$_out" = "1 1" ]; then
    ok "с правилами помощник считает их обоих"
else
    no "счёт правил" "1 1" "$_out"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
