#!/bin/sh
# tests/test_panel_pages.sh — КАЖДАЯ страница вебпанели должна отрисовываться
# без исключений.
#
# Зачем отдельный тест. 2026-08-04 при удалении раздела Geosite из app.js вместе
# с ним уехала константа STRATEGY_POOL_NAMES, и вкладка «Свои стратегии»
# перестала грузиться совсем. Ни один существующий тест этого не заметил, и я
# сам отчитался «всё работает», потому что проверял не то: эндпоинт
# /strategy/pools отвечал 200, маршрут и функция были на месте, синтаксис
# сходился. Ломалось ИСПОЛНЕНИЕ — обращение к константе внутри .map().
#
# Поэтому здесь страницы именно ИСПОЛНЯЮТСЯ в заглушке DOM, а не проверяются
# грепом. И фикстуры ответов API намеренно правдоподобные: с пустым {ok:true}
# список пулов приходит пустым, .map() не запускается, и та самая строка не
# выполняется — первая версия этой заглушки ровно так поломку и пропустила.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

if ! command -v node >/dev/null 2>&1; then
    printf '[SKIP] node не найден — прогон страниц пропущен\n'
    printf '\nPASSED: 0\nFAILED: 0\nSKIPPED: 1\n'
    exit 0
fi

ROUTES="dashboard toggles strategies state warp whitelist extra-domains diag credits"

# shellcheck disable=SC2086
out=$(node "$ROOT/tests/panel_harness.js" "$ROOT/webpanel/www/app.js" $ROUTES 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
for r in $ROUTES; do
    if printf '%s\n' "$out" | grep -q "ok  *#/$r$"; then ok "страница #/$r отрисовалась"
    else no "страница #/$r НЕ отрисовалась"; fi
done

# Мета-проверка: тест обязан ЛОВИТЬ поломку, иначе он декорация. Собираем копию
# без STRATEGY_POOL_NAMES — ровно тот дефект, что уехал в r-71.1, — и требуем,
# чтобы прогон на ней провалился.
tmp=$(mktemp "${TMPDIR:-/tmp}/z2k_panel.XXXXXX") || exit 1
awk '/^  const STRATEGY_POOL_NAMES = \{/{skip=1} skip && /^  \};$/{skip=0; next} !skip' \
    "$ROOT/webpanel/www/app.js" > "$tmp"
if node "$ROOT/tests/panel_harness.js" "$tmp" strategies 2>&1 | grep -q "ПАДАЕТ"; then
    ok "тест ловит реальную поломку (удалённая константа)"
else
    no "тест НЕ ловит удалённую константу — проверка бесполезна"
fi
rm -f "$tmp"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
