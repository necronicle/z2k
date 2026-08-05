#!/bin/sh
# tests/test_cachebuster_declared.sh
#
# Кеш-бастер панели правит САМ генератор карты сумм: он вписывает в
# webpanel/www/index.html текущую версию (`app.js?v=<тег>`). А список файлов
# релиза (changed_files) человек пишет РАНЬШЕ, чем запускает генератор — то есть
# на момент составления списка index.html ещё не изменён, и объявить его нельзя
# физически.
#
# На эти грабли наступали трижды подряд (r-71.1, r-72, r-72.1), каждый раз ловили
# руками. Гейт полноты (tests/test_release_manifest_complete.sh) тут не спасает:
# у свежей записи ref ещё PENDING, и он пропускает проверку.
#
# Цена промаха не косметическая: панель у людей осталась бы со старым кешем при
# новой версии — браузер кеширует по URL, и пока суффикс не сменился, новый app.js
# не подхватывается.
#
# Поэтому объявляет тот, кто изменил: генератор сам дописывает index.html в
# changed_files последней записи. Этот тест следит, чтобы поведение не убрали.
#
# POSIX sh.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GEN="$ROOT/scripts/gen_file_hashes.sh"
MANIFEST="$ROOT/UPDATES.json"
IDX="$ROOT/webpanel/www/index.html"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n      %s\n' "$1" "$2"; }

for f in "$GEN" "$MANIFEST" "$IDX"; do
    [ -f "$f" ] || { no "файлы на месте" "нет $f"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1; }
done

# 1) Механизм присутствует в генераторе.
if grep -q 'changed_files.*index\.html\|index\.html.*changed_files' "$GEN"; then
    ok "генератор умеет объявлять index.html сам"
else
    no "генератор умеет объявлять index.html сам" \
       "в scripts/gen_file_hashes.sh нет дописывания в changed_files — грабли вернутся"
fi

# 2) Кеш-бастер в index.html совпадает с current. Если разошлись — генератор
#    не запускали после смены версии, и людям уедет старый кеш.
cur=$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
idx=$(sed -n 's/.*app\.js?v=\([A-Za-z0-9._-]*\)".*/\1/p' "$IDX" | head -1)
if [ -n "$cur" ] && [ "$cur" = "$idx" ]; then
    ok "кеш-бастер панели совпадает с current ($cur)"
else
    no "кеш-бастер панели совпадает с current" "current=$cur, в index.html=$idx — запустить scripts/gen_file_hashes.sh"
fi

# 3) index.html объявлен в changed_files последней записи. Пропускаем, если он
#    в этом релизе и правда не менялся — тогда объявлять нечего.
last=$(grep '^{"v":' "$MANIFEST" | tail -1)
if printf '%s' "$last" | grep -q '"webpanel/www/index.html"'; then
    ok "index.html объявлен в changed_files последнего релиза"
else
    # менялся ли он относительно предыдущего коммита
    if git -C "$ROOT" diff --quiet HEAD -- webpanel/www/index.html 2>/dev/null; then
        ok "index.html в этом релизе не менялся — объявлять нечего"
    else
        no "index.html объявлен в changed_files последнего релиза" \
           "файл изменён, но не объявлен — панель уедет со старым кешем"
    fi
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
