#!/bin/sh
# tests/test_release_tooling.sh
#
# The two scripts that cut a release — release.sh and scripts/gen_file_hashes.sh —
# are the only code in the tree whose bugs land on every router simultaneously.
# The digest map they produce is checked fail-closed: a map that does not describe
# the committed tree does not degrade the update, it aborts it for everyone at once.
#
# Three properties, all learned from cutting r-70 by hand:
#
#   1. The generator is a FIXED POINT after one run. It rewrites the panel's
#      cache-buster in index.html and hashes the tree; doing those in the wrong
#      order publishes the pre-rewrite digest of index.html, which no router can
#      ever match. That ordering was wrong, and the script's own comment claimed
#      otherwise, so only a mechanical check keeps it honest.
#
#   2. release.sh PRESERVES files_sha256. Its serialiser knew four keys and
#      dropped the map; anything failing between it and the generator left a
#      manifest with no digests at all — the unverified-download hole the map
#      exists to close.
#
#   3. release.sh REFUSES a dirty tree. The map is computed from files on disk
#      while routers fetch the committed revision, so one unrelated edit in the
#      working tree publishes an unobtainable digest.
#
# Runs against a throwaway clone, never the real tree. POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE" || exit 1

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

done_report() {
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ]
}

for t in git python3; do
    command -v "$t" >/dev/null 2>&1 || {
        skip "релизный тулинг" "нет $t"
        done_report; exit $?
    }
done
git rev-parse --git-dir >/dev/null 2>&1 || {
    skip "релизный тулинг" "нет git-репозитория"
    done_report; exit $?
}

# ---------------------------------------------------------------- property 1 --
TMP=$(mktemp -d) || { skip "релизный тулинг" "нет mktemp"; done_report; exit $?; }
trap 'rm -rf "$TMP"' EXIT INT TERM

# ВСЁ ниже работает только в одноразовом клоне, никогда в рабочем дереве.
# Первая версия этого теста гоняла генератор прямо в репозитории и вписала в
# закоммиченный UPDATES.json дайджесты незавершённой правки — ровно та авария,
# от которой мы этим же коммитом ставим гейт в release.sh. Тест, который ломает
# манифест, опаснее бага, который он ищет.
#
# ------------------------------------------------------------ all properties --
if ! git clone -q --no-hardlinks --local . "$TMP/clone" 2>/dev/null; then
    skip "release.sh: карта и гейт на грязное дерево" "клонирование недоступно"
    done_report; exit $?
fi

# Клон несёт ЗАКОММИЧЕННОЕ состояние, а проверять надо тулинг из текущего дерева —
# иначе тест зелёный на старом release.sh и молчит про правку, которую как раз и
# принесли. Накладываем поверх все изменённые отслеживаемые файлы и коммитим,
# чтобы клон стартовал с чистым деревом.
for f in $(git -C "$HERE" diff --name-only HEAD 2>/dev/null); do
    [ -f "$HERE/$f" ] || continue
    mkdir -p "$TMP/clone/$(dirname "$f")"
    cp -f "$HERE/$f" "$TMP/clone/$f"
done

cd "$TMP/clone" || { skip "release.sh" "клон недоступен"; done_report; exit $?; }
git checkout -q -B z2k-enhanced 2>/dev/null
git config user.email t@t; git config user.name t
git add -A >/dev/null 2>&1
git diff --cached --quiet || git commit -q -m "overlay working tree" >/dev/null 2>&1

# --- property 1, с зубами: порядок проверяется только при СМЕНЕ версии ---------
# На сошедшемся дереве правка кеш-бастера — no-op, и неверный порядок внутри
# генератора не проявляется вообще. Ловится он лишь тогда, когда "current"
# меняется: тогда index.html переписывается, и при обратном порядке в карту
# уезжает дайджест ДО правки. Бампаем версию руками и требуем совпадения за
# ОДИН прогон.
sed -i.bak 's/"current": "[^"]*"/"current": "zz-999"/' UPDATES.json && rm -f UPDATES.json.bak
sh scripts/gen_file_hashes.sh >/dev/null 2>&1
if command -v sha256sum >/dev/null 2>&1; then
    _real=$(sha256sum webpanel/www/index.html | awk '{print $1}')
else
    _real=$(shasum -a 256 webpanel/www/index.html | awk '{print $1}')
fi
_mapped=$(sed -n 's/.*"webpanel\/www\/index\.html"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' UPDATES.json | head -1)
if [ "$_real" = "$_mapped" ]; then
    ok "смена версии: дайджест index.html верен за один прогон"
else
    no "смена версии: дайджест index.html верен за один прогон" "$_real" "${_mapped:-нет записи}"
fi
case "$(grep -o '?v=[A-Za-z0-9._-]*' webpanel/www/index.html | head -1)" in
    '?v=zz-999') ok "смена версии: кеш-бастер панели переписан под новый тег" ;;
    *) no "смена версии: кеш-бастер панели переписан под новый тег" "?v=zz-999" \
          "$(grep -o '?v=[A-Za-z0-9._-]*' webpanel/www/index.html | head -1)" ;;
esac

# Второй прогон уже ничего не меняет — генератор является фиксированной точкой.
cp UPDATES.json "$TMP/pass1.json"
cp webpanel/www/index.html "$TMP/pass1.html"
sh scripts/gen_file_hashes.sh >/dev/null 2>&1
if cmp -s "$TMP/pass1.json" UPDATES.json && cmp -s "$TMP/pass1.html" webpanel/www/index.html; then
    ok "генератор — фиксированная точка: второй прогон ничего не меняет"
else
    no "генератор — фиксированная точка: второй прогон ничего не меняет" "без изменений" "второй прогон переписал"
fi

git checkout -q -- . 2>/dev/null

# --- property 3: грязное дерево отбивается ------------------------------------
echo "# dirty" >> lib/install.sh
# scripts/release.sh — канонический. Раньше здесь гонялся ./release.sh, то есть
# тест сторожил ЛЕГАСИ-скрипт, который выпускал релиз в обход CI-гейта, и тем
# самым закреплял его как рабочий путь. Легаси теперь шим (печатает правильную
# команду и падает), поведение проверяем у того, кто релиз реально собирает.
out=$(sh scripts/release.sh p-9999.1 patch "тест: грязное дерево" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
    ok "release.sh отказывается работать на грязном дереве"
else
    no "release.sh отказывается работать на грязном дереве" "ненулевой код" "0"
fi
case "$out" in
    *"незакоммиченные правки"*|*"не чистое"*|*"dirty"*) ok "отказ объясняет причину" ;;
    *) no "отказ объясняет причину" "упоминание грязного дерева" "$(printf '%s' "$out" | head -1)" ;;
esac
# Манифест не должен быть тронут отклонённым запуском.
if git diff --quiet -- UPDATES.json; then
    ok "отклонённый релиз не трогает манифест"
else
    no "отклонённый релиз не трогает манифест" "без изменений" "манифест переписан"
fi
git checkout -q -- lib/install.sh

# --- property 4: install-time генератор требует reinstall, а не patch ---------
#
# lib/config_official.sh материализуется в $ZAPRET2_DIR/config РОВНО ОДИН РАЗ,
# при установке (step_create_config_and_init). Патч кладёт новый файл на диск,
# но не перезапускает генерацию — уже установленный роутер живёт со старым
# config. Изменение здесь ДОЛЖНО коммититься (в отличие от property 3 — тут
# проверяем не грязное дерево, а содержательный гейт по конкретному пути).
#
# И, в отличие от property 3, дерево здесь чистое — die на грязном дереве
# больше не отвлекает более раннюю проверку ветки ("релиз собирается на
# staging, а не в релизной ветке"), поэтому нужна настоящая staging-ветка.
git checkout -q -B z2k-staging
echo "# generator touch" >> lib/config_official.sh
git add lib/config_official.sh
git commit -q -m "тест: правка генератора конфига"
out=$(sh scripts/release.sh p-9999.2 patch "тест: генератор требует reinstall" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
    ok "release.sh отвергает patch при изменении install-time генератора"
else
    no "release.sh отвергает patch при изменении генератора" "ненулевой код" "0"
fi
case "$out" in
    *"config_official.sh"*|*"генератор"*) ok "отказ называет генератор причиной" ;;
    *) no "отказ называет генератор причиной" "упоминание config_official.sh/генератора" "$(printf '%s' "$out" | head -1)" ;;
esac
if git diff --quiet -- UPDATES.json; then
    ok "отклонённый релиз (генератор) не трогает манифест"
else
    no "отклонённый релиз (генератор) не трогает манифест" "без изменений" "манифест переписан"
fi
# TYPE=reinstall для того же диффа гейт снимает — проверяем СТАТИЧЕСКИ (что он
# написан как `[ "$TYPE" != "reinstall" ]`, тот же вид, что и у гейта на
# builds/), а не живым прогоном: живой прогон ушёл бы дальше, к шагу подписи,
# который на этой машине может найти настоящий ключ владельца — тестам сюда
# лезть незачем.
if grep -B2 "config_official.*strategies" scripts/release.sh | grep -q 'TYPE.*!=.*reinstall' \
    || awk '/_gen_changed=/,/^fi$/' scripts/release.sh | grep -q '"\$TYPE" != "reinstall"'; then
    ok "гейт на генераторы условен на TYPE=reinstall (снимается, не абсолютный запрет)"
else
    no "гейт на генераторы условен на TYPE=reinstall" '"$TYPE" != "reinstall"' "не найдено"
fi

# Незакоммиченные НЕотслеживаемые файлы не должны блокировать релиз: в карту они
# не попадают (git ls-files их не видит), значит и опасности не создают.
echo x > untracked_probe.tmp
# Ожидания CI здесь больше нет: гейт переехал в publish.yml, а скрипт только
# собирает релиз (см. RELEASING.md). Проверяется ровно одно — что
# НЕотслеживаемые файлы не считаются грязным деревом.
out=$(sh scripts/release.sh p-9999.1 patch "тест: только untracked" 2>&1); rc=$?
# Ветка про ключ подписи осталась от отката 6fbe694: подпись манифеста была
# построена и снята обратно, а условие тут пережило её. Держим как есть —
# подпись возвращается (см. PLAN/issue #28), и тогда ветка снова понадобится.
# Проверяем ИМЕННО то, ради чего блок написан: неотслеживаемый файл не должен
# засчитываться как грязное дерево. Доводить до успешного релиза здесь нечем —
# в клоне не изменился ни один доставляемый файл, и канонический скрипт на этом
# законно останавливается. Поэтому утверждение о ПРИЧИНЕ отказа, а не о коде:
# любая причина годится, кроме незакоммиченных правок.
case "$out" in
    *"незакоммиченные правки"*|*"не чистое"*|*"dirty"*)
        no "untracked-файлы не блокируют релиз" "отказ не про грязное дерево" "$(printf '%s' "$out" | head -1)" ;;
    *)
        ok "untracked-файлы не блокируют релиз" ;;
esac
rm -f untracked_probe.tmp

# --- property 2: карта пережила перезапись манифеста --------------------------
if python3 -c "
import json,sys
m=json.load(open('UPDATES.json'))
sys.exit(0 if m.get('files_sha256') else 1)
" 2>/dev/null; then
    ok "release.sh сохраняет files_sha256 в манифесте"
else
    no "release.sh сохраняет files_sha256 в манифесте" "карта на месте" "карта потеряна"
fi

# Порядок ключей важен: генератор вставляет блок сразу после "current", и
# построчный awk-парсер апдейтера рассчитывает на записи истории по одной в строке.
if python3 -c "
import json,sys
m=json.load(open('UPDATES.json'))
sys.exit(0 if list(m.keys())==['schema','branch','seq','current','files_sha256','history'] else 1)
" 2>/dev/null; then
    ok "порядок ключей манифеста сохранён"
else
    no "порядок ключей манифеста сохранён" "schema,branch,seq,current,files_sha256,history" "другой"
fi

if [ "$(grep -c '^{"v":' UPDATES.json)" -gt 1 ]; then
    ok "история осталась по одной записи на строку"
else
    no "история осталась по одной записи на строку" ">1 строки с записями" "$(grep -c '^{"v":' UPDATES.json)"
fi

# index.html попал в changed_files свежей записи автоматически.
if python3 -c "
import json,sys
m=json.load(open('UPDATES.json'))
sys.exit(0 if 'webpanel/www/index.html' in m['history'][-1]['changed_files'] else 1)
" 2>/dev/null; then
    ok "index.html объявлен в changed_files нового релиза"
else
    no "index.html объявлен в changed_files нового релиза" "объявлен" "отсутствует"
fi

# Генератор карты ИДЕМПОТЕНТЕН: второй прогон подряд не меняет ни байта.
#
# Раньше здесь проверялось «после release.sh карта уже синхронна». Проверка
# была неверной по построению: релиз в этом тесте намеренно не доходит до
# конца (мы проверяем отказы), значит сравнивалась карта, которую никто не
# пересобирал. А с 2026-08-09 карта и вовсе пересобирается ТОЛЬКО в релизе —
# между релизами манифест описывает выпущенный срез, а не рабочую копию.
#
# Идемпотентность же — настоящее свойство генератора: без неё каждый прогон CI
# давал бы новый манифест, и «карта не сходится» стало бы вечным.
sh scripts/gen_file_hashes.sh >/dev/null 2>&1
cp UPDATES.json "$TMP/gen1.json"
sh scripts/gen_file_hashes.sh >/dev/null 2>&1
if cmp -s "$TMP/gen1.json" UPDATES.json; then
    ok "генератор карты идемпотентен (второй прогон ничего не меняет)"
else
    no "генератор карты идемпотентен" "без расхождений" "второй прогон переписал манифест"
fi

cd "$HERE" || true
done_report
