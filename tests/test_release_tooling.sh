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
# Отслеживаемые правки И НОВЫЕ ФАЙЛЫ. Только `diff --name-only HEAD` не видит
# untracked, и модуль, добавленный этой же правкой (lib/release_map.sh), в клон
# не попадал: release.sh падал на sourcing, а тест списывал это на свои гейты и
# показывал четыре осмысленных на вид отказа вместо одной настоящей причины.
for f in $(git -C "$HERE" diff --name-only HEAD 2>/dev/null; git -C "$HERE" ls-files --others --exclude-standard 2>/dev/null); do
    [ -f "$HERE/$f" ] || continue
    mkdir -p "$TMP/clone/$(dirname "$f")"
    cp -f "$HERE/$f" "$TMP/clone/$f"
done

cd "$TMP/clone" || { skip "release.sh" "клон недоступен"; done_report; exit $?; }
git checkout -q -B z2k-enhanced 2>/dev/null
git config user.email t@t; git config user.name t
git add -A >/dev/null 2>&1
git diff --cached --quiet || git commit -q -m "overlay working tree" >/dev/null 2>&1

# release.sh сверяется с origin: опубликован ли предыдущий релиз (иначе второй
# релиз в полёте заклинивает публикацию). В песочнице origin по умолчанию —
# РОДИТЕЛЬСКИЙ репозиторий, где локальная z2k-enhanced живёт своей жизнью и
# обычно отстаёт; тогда этот гейт срабатывал бы в каждом тесте и глушил ровно
# те свойства, которые тест и проверяет. Замыкаем origin на сам клон: "уже
# опубликовано ровно то, что лежит в дереве" — штатное состояние перед релизом.
git remote set-url origin "$TMP/clone" 2>/dev/null || git remote add origin "$TMP/clone" 2>/dev/null

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

# --- property 4: install-time генератор уезжает ПАТЧЕМ и объявляет шаги -------
#
# lib/config_official.sh материализуется в $ZAPRET2_DIR/config один раз, при
# установке. Раньше отсюда следовало «менять его можно только релизом типа
# reinstall»: патч клал новый файл, но генерацию никто не переигрывал. Цена —
# четыре с половиной минуты у каждого роутера флота за однострочную правку.
#
# Теперь следствие выражается адресно: релиз объявляет regen-config,
# validate-config и restart-service, а исполнитель их выполняет. Проверяем ровно
# это — что правка генератора проходит патчем И что шаги объявлены. Патч без
# объявленных шагов был бы прежней аварией под новым именем: файл приехал,
# конфиг остался старым, версия сдвинулась.
git checkout -q -B z2k-staging
# Свойство про ГЕНЕРАТОР, поэтому в дереве не должно остаться постороннего
# незарелизенного. Клон несёт рабочую копию целиком, и любая правка
# mtproxy-client в ней упирает release.sh в отдельный гейт: туда на сборке
# вшивается Z2K_TUNNEL_SECRET, без него пересобрать и сверить builds/ нечем.
# Гейт правильный, но к этому свойству отношения не имеет — и делал тест
# красным всякий раз, когда рядом лежала невыпущенная правка туннеля.
# Приводим mtproxy-client к опубликованному состоянию, чтобы дельта была одна.
if git rev-parse --verify -q origin/z2k-enhanced >/dev/null 2>&1; then
    # rm -rf до checkout: восстановление из ссылки возвращает только то, что
    # в ней есть, и НЕ убирает файлы, появившиеся позже. Один новый файл в
    # каталоге — и дельта снова не одна.
    rm -rf mtproxy-client
    git checkout -q origin/z2k-enhanced -- mtproxy-client 2>/dev/null || true
    git add -A mtproxy-client 2>/dev/null || true
    git diff --cached --quiet -- mtproxy-client 2>/dev/null \
        || git commit -q -m "тест: mtproxy-client к опубликованному состоянию"
fi
echo "# generator touch" >> lib/config_official.sh
git add lib/config_official.sh
git commit -q -m "тест: правка генератора конфига"
_p4_before=$(git rev-parse HEAD)
out=$(sh scripts/release.sh p-9999.2 patch "тест: генератор объявляет шаги" 2>&1); rc=$?
case "$out" in
    *"regen-config"*) ok "правка генератора объявляет regen-config" ;;
    *) no "правка генератора объявляет regen-config" "упоминание regen-config" \
          "$(printf '%s' "$out" | grep -i 'последств' | head -1)" ;;
esac
case "$out" in
    *"restart-service"*) ok "и перезапуск сервиса" ;;
    *) no "и перезапуск сервиса" "упоминание restart-service" "$(printf '%s' "$out" | grep -i 'последств' | head -1)" ;;
esac
if [ "$rc" -eq 0 ]; then
    ok "патчем это теперь проходит — переустановка больше не цена одной строки"
else
    # Отказ по ДРУГОЙ причине (ключ подписи, неопубликованный предыдущий) —
    # законен и к этому свойству отношения не имеет; отказ ИМЕННО про тип релиза
    # означал бы, что гейт вернулся.
    case "$out" in
        *"тип обязан быть reinstall"*)
            no "патчем это теперь проходит" "релиз собран" "гейт вернулся — снова reinstall за одну строку" ;;
        *) ok "отказ не про тип релиза (гейт не вернулся)" ;;
    esac
fi
# Возвращаем когерентность: «опубликовано ровно то, что в дереве». Правка
# генератора теперь проходит патчем и ДВИГАЕТ current — а следующие свойства
# упрутся в гейт «предыдущий релиз не опубликован» и будут отказывать по этой
# причине вместо своей. origin здесь ещё сам клон (pubrepo появится ниже).
# ПОЛНОСТЬЮ откатываем песочницу к состоянию до этого релиза.
#
# Раньше правка генератора здесь ОТВЕРГАЛАСЬ, и следа не оставалось. Теперь она
# законно проходит — то есть двигает current, ставит тег и меняет PREV_REF, от
# которого считают дифф все свойства ниже. Без отката они начинают отказывать по
# чужой причине («предыдущий релиз не опубликован») вместо своей, и тест
# перестаёт проверять то, ради чего написан.
git tag -d p-9999.2 >/dev/null 2>&1 || true
git reset -q --hard "$_p4_before" 2>/dev/null || true
git push -q -f origin "HEAD:refs/heads/z2k-enhanced" 2>/dev/null || true

# --- property 5: mtproxy-client без Z2K_TUNNEL_SECRET не пересобрать и не свериться
#
# builds/mtproxy-client/* нельзя пересобрать байт-в-байт без настоящего
# Z2K_TUNNEL_SECRET (см. -X main.defaultTunnelSecret в Makefile). Меняем файл
# под mtproxy-client/builds/, ставим TYPE=reinstall (снимает builds/-гейт из
# property "любой бинарник — reinstall") и явно НЕ задаём Z2K_TUNNEL_SECRET —
# ожидаем отказ ИМЕННО про секрет, а не про тип релиза.
printf 'junk-for-test\n' >> mtproxy-client/builds/tg-mtproxy-client-linux-amd64
git add mtproxy-client/builds/tg-mtproxy-client-linux-amd64
git commit -q -m "тест: правка mtproxy-бинарника"
out=$(env -u Z2K_TUNNEL_SECRET sh scripts/release.sh r-9999.3 reinstall "тест: mtproxy без секрета" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
    ok "release.sh отказывается собирать релиз с изменённым mtproxy-client без секрета"
else
    no "release.sh отказывается без секрета" "ненулевой код" "0"
fi
case "$out" in
    *"Z2K_TUNNEL_SECRET"*) ok "отказ называет Z2K_TUNNEL_SECRET причиной, а не что-то другое" ;;
    *) no "отказ называет Z2K_TUNNEL_SECRET причиной" "упоминание Z2K_TUNNEL_SECRET" "$(printf '%s' "$out" | head -1)" ;;
esac
if git diff --quiet -- UPDATES.json; then
    ok "отклонённый релиз (mtproxy без секрета) не трогает манифест"
else
    no "отклонённый релиз (mtproxy без секрета) не трогает манифест" "без изменений" "манифест переписан"
fi

# --- property 5b: mtproxy-client SOURCE-ONLY (без единого байта в builds/) ---
#
# Реальная дыра, найденная живьём: правка main.go/go.mod/go.sum/Makefile без
# последующего `make all` НЕ оставляет диффа в builds/ вообще — старый гейт,
# завязанный только на builds/, такую рассинхронизацию не видел бы совсем.
# main.go сам по себе не доставляем (z2k_install_paths о нём не знает —
# исходник, не артефакт), поэтому бандлим с реальным доставляемым файлом,
# иначе release.sh упадёт раньше с "релизить нечего", и до нужного гейта
# дело не дойдёт вовсе.
#
# TYPE=reinstall, не patch: клон продолжается с property 4/5 БЕЗ отката —
# их правки (lib/config_official.sh, mtproxy-client/builds/...) остаются в
# том же диффе PREV_REF..HEAD и сами уже требуют reinstall. На patch тут
# первым сработал бы ИХ гейт, а не тот, что проверяет property 5b — реальная
# логика release.sh это не бесит, дело в накопленном состоянии теста.
echo "// test: source-only change, builds/ untouched" >> mtproxy-client/main.go
echo "-- test: unrelated patchable change" >> files/lua/z2k-fooling-ext.lua
git add mtproxy-client/main.go files/lua/z2k-fooling-ext.lua
git commit -q -m "тест: mtproxy source-only (builds/ не тронут) + не связанная патчуемая правка"
out=$(env -u Z2K_TUNNEL_SECRET sh scripts/release.sh r-9999.4 reinstall "тест: mtproxy source-only без секрета" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
    ok "release.sh отвергает SOURCE-ONLY правку mtproxy-client (builds/ не тронут) без секрета"
else
    no "release.sh отвергает source-only mtproxy без секрета" "ненулевой код" "0"
fi
case "$out" in
    *"Z2K_TUNNEL_SECRET"*) ok "source-only: отказ называет Z2K_TUNNEL_SECRET причиной" ;;
    *) no "source-only: отказ называет Z2K_TUNNEL_SECRET причиной" "упоминание Z2K_TUNNEL_SECRET" "$(printf '%s' "$out" | head -1)" ;;
esac
if git diff --quiet -- UPDATES.json; then
    ok "отклонённый релиз (mtproxy source-only) не трогает манифест"
else
    no "отклонённый релиз (mtproxy source-only) не трогает манифест" "без изменений" "манифест переписан"
fi

# --- property 6: второй релиз в полёте не заводится ---------------------------
#
# Liveness-дыра, а не дыра в безопасности. Публикацию запускает workflow_run по
# CI на staging, и CI разных коммитов идут ПАРАЛЛЕЛЬНО (группа по SHA, см.
# ci.yml). Если завести релиз C, пока A ещё не опубликован, CI(C) может
# закончиться первым — и gate увидит в манифесте СРАЗУ ДВЕ новые записи history
# вместо одной. Он честно ответит красным (semantic-гейт требует ровно одну),
# но сам собой уже не повторится, когда A наконец опубликуется: подмены нет,
# всё fail-closed, цена — застрявший релиз и ручной разбор.
#
# Моделируем ровно это: origin (то, что «опубликовано») отстаёт от манифеста в
# дереве. Гейт обязан не пустить.
_pub_head=$(git rev-parse HEAD)
sed -i.bak 's/"current": "[^"]*"/"current": "zz-unpublished"/' UPDATES.json && rm -f UPDATES.json.bak
git add UPDATES.json >/dev/null 2>&1
git commit -q -m "тест: в дереве релиз, которого ещё нет в origin" >/dev/null 2>&1
echo "-- test: patchable change" >> files/lua/z2k-fooling-ext.lua
git add files/lua/z2k-fooling-ext.lua >/dev/null 2>&1
git commit -q -m "тест: доставляемая правка поверх неопубликованного релиза" >/dev/null 2>&1
# origin остаётся на _pub_head: там current ещё прежний, то есть предыдущий
# релиз не опубликован.
git update-ref refs/remotes/origin/z2k-enhanced "$_pub_head"
git remote set-url origin "$TMP/pubrepo" 2>/dev/null
git init -q --bare "$TMP/pubrepo" 2>/dev/null
git push -q "$TMP/pubrepo" "$_pub_head:refs/heads/z2k-enhanced" 2>/dev/null
out=$(sh scripts/release.sh p-9999.7 patch "тест: предыдущий релиз не опубликован" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
    ok "release.sh не заводит новый релиз, пока предыдущий не опубликован"
else
    no "release.sh не заводит новый релиз, пока предыдущий не опубликован" \
       "ненулевой код" "0 — второй релиз в полёте заклинит публикацию"
fi
case "$out" in
    *"НЕ опубликован"*) ok "отказ прямо называет причиной неопубликованный предыдущий релиз" ;;
    *) no "отказ называет причиной неопубликованный предыдущий релиз" \
          "упоминание «НЕ опубликован»" "$(printf '%s' "$out" | tail -1)" ;;
esac
if git diff --quiet -- UPDATES.json; then
    ok "отклонённый релиз (предыдущий не опубликован) не трогает манифест"
else
    no "отклонённый релиз (предыдущий не опубликован) не трогает манифест" "без изменений" "манифест переписан"
fi
# Возвращаем когерентность: «опубликовано ровно то, что в дереве».
git push -q -f "$TMP/pubrepo" "HEAD:refs/heads/z2k-enhanced" 2>/dev/null

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

# Порядок ключей важен: генератор вставляет блоки сразу после "current", и
# построчный awk-парсер апдейтера рассчитывает на записи истории по одной в строке.
#
# install_map необязателен: этот манифест — ЗАКОММИЧЕННЫЙ, а карта появляется в
# нём только с первым релизом нового генератора. Проверяем не наличие, а место:
# если карта есть, она обязана стоять между "current" и files_sha256.
if python3 -c "
import json,sys
m=json.load(open('UPDATES.json'))
head=['schema','branch','seq','current']
tail=['files_sha256','history']
want=head + (['install_map'] if 'install_map' in m else []) + tail
sys.exit(0 if list(m.keys())==want else 1)
" 2>/dev/null; then
    ok "порядок ключей манифеста сохранён"
else
    no "порядок ключей манифеста сохранён" "schema,branch,seq,current[,install_map],files_sha256,history" \
       "$(python3 -c "import json;print(','.join(json.load(open('UPDATES.json')).keys()))" 2>/dev/null)"
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
