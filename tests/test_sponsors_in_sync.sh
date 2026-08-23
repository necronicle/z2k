#!/bin/sh
# tests/test_sponsors_in_sync.sh — список спонсоров одинаков во всех трёх местах.
#
# ЗАЧЕМ. Спонсоры перечислены ТРИЖДЫ и в трёх разных форматах: README.md
# (маркдаун-список), lib/menu.sh (ASCII-коробка фиксированной ширины, имена через запятую) и
# webpanel/www/js/pages/credits.js (карточки «Благодарности»). Добавляют человека
# руками в каждое место. Забыть одно из трёх — вопрос времени, а заметить это
# некому: ошибки не будет нигде, просто человек, давший денег, не увидит себя
# там, куда пойдёт смотреть.
#
# ГЛАВНЫЙ ТЕСТИРОВЩИК — НЕ СПОНСОР. В панели у него отдельная карточка с другим
# бейджем (tester-card / «Главный тестировщик»), и в списках спонсоров его нет
# намеренно. Тест это учитывает: сверяются только карточки sponsor-card.
#
# ШИРИНА КОРОБКИ В МЕНЮ. Строки меню выровнены по правому краю столбиком `|`.
# Кириллица в UTF-8 занимает два байта на символ, поэтому длину надо считать
# в СИМВОЛАХ, а не в байтах — иначе проверка ругалась бы на «Алексей Стрельцов»
# и была бы отключена как ложная.
#
# POSIX sh + python3 (в CI есть; без него — честный SKIP).

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n%s\n' "$1" "$2"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

for f in README.md lib/menu.sh webpanel/www/js/pages/credits.js; do
    [ -f "$ROOT/$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

if ! command -v python3 >/dev/null 2>&1; then
    printf '[SKIP] сверка списков спонсоров (нет python3; в CI проверяется)\n'
    printf '\nPASSED: 0\nFAILED: 0\nSKIPPED: 1\n'
    exit 0
fi

OUT=$(python3 - "$ROOT" <<'PY'
import re, sys, html
root = sys.argv[1]
rd_txt = open(f"{root}/README.md", encoding="utf-8").read()
mn_txt = open(f"{root}/lib/menu.sh", encoding="utf-8").read()
# Карточки живут в модуле «Благодарности» — фронтенд разбит на модули
# 2026-08-14, и чтение app.js возвращало бы точку входа без единого имени.
js_txt = open(f"{root}/webpanel/www/js/pages/credits.js", encoding="utf-8").read()

# README: список под заголовком благодарности, до первой пустой строки после него.
m = re.search(r'^## .*спонсор.*$', rd_txt, re.M | re.I)
readme = []
if m:
    for line in rd_txt[m.end():].splitlines():
        if line.startswith("- **"):
            readme.append(line[4:].split("**")[0])
        elif readme and line.strip() == "":
            break

# Меню: компактные строки коробки после заголовка благодарности — имена
# через запятую, перенос по ширине; до закрывающей линии коробки. Имя может
# содержать « - » (Dkarloff - SEO отец), разделитель — только запятая.
menu = []
mm = re.search(r'^\|  Огромная благодарность спонсорам проекта:.*$', mn_txt, re.M)
if mm:
    for line in mn_txt[mm.end():].splitlines()[1:]:   # [0] — хвост строки заголовка
        if not line.startswith("|"):
            break
        body = line.strip("|").strip()
        menu += [x.strip() for x in body.split(",") if x.strip()]

# Панель: только карточки спонсоров. Тестировщик — отдельная карточка и в
# списки спонсоров не входит.
# Разбор по паре «класс карточки → следующее имя», а не по блоку целиком:
# внутри карточки есть вложенные div, и жадная скобка ловила только первую.
panel = []
for cls, name in re.findall(
        r'class="card credits-card (\w+)-card">.*?<div class="credits-name">(.+?)</div>',
        js_txt, re.S):
    if cls == "sponsor":
        panel.append(html.unescape(name).strip())

print("COUNTS", len(readme), len(menu), len(panel))
for label, a, b in (("README-меню", readme, menu),
                    ("README-панель", readme, panel)):
    only_a = [x for x in a if x not in b]
    only_b = [x for x in b if x not in a]
    if only_a or only_b:
        print(f"DIFF {label} | только слева: {only_a} | только справа: {only_b}")

# Порядок тоже сверяем: расхождение обычно значит, что кого-то вставили не туда.
if readme and menu and readme != menu:
    print("ORDER README-меню отличается")
if readme and panel and readme != panel:
    print("ORDER README-панель отличается")

# Ширина строк коробки — в символах.
widths = {}
for line in mn_txt.splitlines():
    if re.match(r'^[|+].*[|+]$', line) and ("- " in line or set(line) <= set("+=-|")):
        widths.setdefault(len(line), []).append(line)
if len(widths) > 1:
    worst = sorted(widths.items(), key=lambda kv: -len(kv[1]))
    print("WIDTH", {w: len(v) for w, v in worst},
          "| выбиваются:", [v[0] for w, v in worst[1:]][:3])
PY
) || { printf '[FAIL] разбор не состоялся:\n%s\n' "$OUT"; exit 1; }

_counts=$(printf '%s\n' "$OUT" | grep '^COUNTS' | cut -d' ' -f2-)
_r=$(echo "$_counts" | cut -d' ' -f1); _m=$(echo "$_counts" | cut -d' ' -f2); _p=$(echo "$_counts" | cut -d' ' -f3)

if [ "${_r:-0}" -gt 0 ] && [ "${_m:-0}" -gt 0 ] && [ "${_p:-0}" -gt 0 ]; then
    ok "списки найдены во всех трёх местах (README $_r, меню $_m, панель $_p)"
else
    no "списки найдены везде" "  README=$_r меню=$_m панель=$_p — разбор сломался"
fi

_diff=$(printf '%s\n' "$OUT" | grep '^DIFF' || true)
if [ -z "$_diff" ]; then
    ok "состав спонсоров совпадает во всех трёх местах"
else
    no "состав совпадает" "$_diff"
fi

_order=$(printf '%s\n' "$OUT" | grep '^ORDER' || true)
if [ -z "$_order" ]; then
    ok "порядок спонсоров одинаков"
else
    no "порядок одинаков" "$_order"
fi

_width=$(printf '%s\n' "$OUT" | grep '^WIDTH' || true)
if [ -z "$_width" ]; then
    ok "коробка меню ровная — все строки одной ширины в символах"
else
    no "коробка меню ровная" "$_width"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
