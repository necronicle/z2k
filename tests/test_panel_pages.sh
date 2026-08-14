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

ROUTES="dashboard toggles strategies state warp whitelist exclude extra-domains diag credits"

# shellcheck disable=SC2086
out=$(node "$ROOT/tests/panel_harness.js" "$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")" $ROUTES 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
for r in $ROUTES; do
    if printf '%s\n' "$out" | grep -q "ok  *#/$r$"; then ok "страница #/$r отрисовалась"
    else no "страница #/$r НЕ отрисовалась"; fi
done

# Мета-проверки: тест обязан ЛОВИТЬ поломку, иначе он декорация. Случаев ДВА, и
# это принципиально — они ловятся разными механизмами.
#
#   STRATEGY_POOL_NAMES используется ВНЕ try/catch: исключение вылетает наружу,
#   его видит обработчик unhandledRejection.
#   STATE_SORT_LABELS используется ВНУТРИ try/catch: код ловит исключение сам и
#   пишет текст ошибки в DOM, наружу не выходит НИЧЕГО. До r-72.1 харнесс такое
#   не видел вовсе и отвечал «ok» — то есть защищал один маршрут из девяти.
#
# Если оставить только первый случай, проверка самоподтверждающаяся: она
# доказывает лишь то, что уже умеет.
meta_case() {
    local label="$1" pattern="$2" route="$3" tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/z2k_panel.XXXXXX") || return 1
    # Вырезаем от строки объявления до первой строки, ЗАКАНЧИВАЮЩЕЙСЯ на };
    # включительно. Обе формы объявления живут в файле рядом: многострочная
    # (STRATEGY_POOL_NAMES) и однострочная (STATE_SORT_LABELS). Прежний вариант
    # ждал закрывающую скобку ОТДЕЛЬНОЙ строкой и на однострочной вырезал файл
    # до конца — мета-случай тогда не собирался, а выглядело это как «тест не
    # ловит поломку».
    awk -v pat="$pattern" '
        $0 ~ pat { skip=1 }
        skip { if (/\};[[:space:]]*$/) skip=0; next }
        { print }' "$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")" > "$tmp"
    if ! grep -q "$pattern" "$tmp"; then
        if node "$ROOT/tests/panel_harness.js" "$tmp" "$route" 2>&1 | grep -q "ПАДАЕТ"; then
            ok "тест ловит поломку: $label"
        else
            no "тест НЕ ловит поломку: $label — проверка бесполезна"
        fi
    else
        no "мета-случай не собрался: $label (константа не вырезалась)"
    fi
    rm -f "$tmp"
}
meta_case "константа вне try/catch (регрессия r-71.1)" "const STRATEGY_POOL_NAMES = " strategies
meta_case "константа ВНУТРИ try/catch (ошибка отрисована, не брошена)" "const STATE_SORT_LABELS = " state

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
