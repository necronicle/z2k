#!/bin/sh
# tests/test_publish_gate.sh — релиз доходит до людей только после зелёного CI.
#
# ЧТО ЗДЕСЬ ОХРАНЯЕТСЯ.
#
# `z2k-enhanced` — не «ветка с кодом», а канал доставки. Роутеры тянут с её
# верхушки манифест, файлы патча и `z2k.sh` для переустановки; однострочник из
# README ставит оттуда же. Всё, что туда попало, у людей немедленно — прошло оно
# проверки или нет. До 2026-08-09 туда пушил человек, а CI прогонялся уже после.
#
# Теперь публикация — работа робота: `publish.yml` переводит релизную ветку на
# коммит staging, и только когда CI на ЭТОМ коммите зелёный. Свойство держится
# на нескольких мелочах, каждую из которых легко снести правкой, не заметив.
# Здесь они закреплены.
#
# Тест статический: разбирает workflow и release.sh. Прогнать настоящий
# workflow_run в CI нельзя, а свойство должно охраняться всё равно.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PUB="$ROOT/.github/workflows/publish.yml"
CDN="$ROOT/.github/workflows/jsdelivr-purge.yml"
CI="$ROOT/.github/workflows/ci.yml"
REL="$ROOT/scripts/release.sh"

for f in "$PUB" "$CDN" "$CI" "$REL"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

# --- 1. Публикует только робот и только по зелёному CI -------------------------
#
# Триггер обязан быть workflow_run по CI на staging. Заменить его на `push`
# означало бы вернуть ровно тот дефект, ради которого всё это делалось.
if grep -q 'workflow_run:' "$PUB" && grep -q 'workflows: \["CI"\]' "$PUB"; then
    ok "публикация запускается по завершению CI, а не по пушу"
else
    no "публикация запускается по завершению CI" "workflow_run по CI" "не найдено"
fi

if grep -q 'branches: \[z2k-staging\]' "$PUB"; then
    ok "источник публикации — z2k-staging"
else
    no "источник публикации — z2k-staging" "branches: [z2k-staging]" "не найдено"
fi

# Красный CI не должен доходить до решения вовсе.
if grep -q "workflow_run.conclusion == 'success'" "$PUB"; then
    ok "красный CI до решения о публикации не доходит"
else
    no "красный CI до решения не доходит" "проверка conclusion == success" "не найдено"
fi

# --- 2. Права на запись — ровно одной джобе ------------------------------------
#
# Токен с записью в релизную ветку равен захвату канала доставки. Он допустим
# только там, где ветку и двигают.
_top=$(awk '/^permissions:/{getline; print; exit}' "$PUB" | tr -d ' ')
if [ "$_top" = "contents:read" ]; then
    ok "по умолчанию у workflow только чтение"
else
    no "по умолчанию только чтение" "contents: read" "$_top"
fi

_writes=$(grep -c 'contents: write' "$PUB")
if [ "$_writes" = "1" ]; then
    ok "запись выдана ровно одной джобе"
else
    no "запись выдана ровно одной джобе" "1" "$_writes"
fi

# И она не должна оказаться у джобы, которая что-то проверяет: гейт с правом
# записи — это уже не гейт.
#
# `/re/,/re/` в awk сверяет ОБА паттерна с одной и той же строкой: строка
# "  gate:" сама подходит и под конец диапазона (2 пробела + буква), так что
# наивный `/^  gate:/,/^  [a-z]/` печатает ровно одну строку и молчит про всё
# тело job'ы — проверка была бы зелёной, даже принеси кто-то `contents: write`
# прямо туда. Явный флаг вместо диапазона: включаем на "  gate:", выключаем на
# СЛЕДУЮЩЕЙ job-строке (не на ней самой).
_gate_block() {
    awk '/^  gate:/{p=1} p && /^  [a-z]/ && $0 !~ /^  gate:/{p=0} p' "$PUB"
}
if _gate_block | grep -q 'contents: write'; then
    no "у проверяющей джобы нет права записи" "нет" "gate умеет писать"
else
    ok "у проверяющей джобы нет права записи"
fi

# --- 3. Ключа подписи у робота нет, но подпись он проверяет --------------------
#
# Модель угроз — «захватили репозиторий». Ключ в secrets захватывается вместе с
# ним, поэтому робот имеет право только ПРОВЕРЯТЬ.
if grep -qiE 'secrets\.[A-Z_]*(SIGN|KEY|PRIV)' "$PUB"; then
    no "у робота нет ключа подписи" "никаких secrets с ключом" "найдена ссылка на секрет-ключ"
else
    ok "у робота нет ключа подписи"
fi

if grep -q 'pkeyutl -verify' "$PUB"; then
    ok "робот проверяет подпись манифеста перед публикацией"
else
    no "робот проверяет подпись" "openssl pkeyutl -verify" "не найдено"
fi

# Ключ для проверки берётся из УЖЕ опубликованного состояния. Возьми он ключ из
# кандидата — кандидат заверял бы сам себя, и подпись перестала бы что-либо
# значить.
if grep -q 'origin/\$RELEASE:files/etc/z2k-update-pub.pem' "$PUB"; then
    ok "проверка идёт ключом из опубликованной ветки, а не из кандидата"
else
    no "проверка ключом из опубликованной ветки" 'origin/$RELEASE:files/etc/z2k-update-pub.pem' "не найдено"
fi

# --- 4. Что именно считается релизом ------------------------------------------
#
# Пуш кода в staging — не релиз. Публиковать его нельзя: люди получили бы
# состояние, которое никто не объявлял.
if grep -q 'NEW_CUR" = "\$OLD_CUR' "$PUB"; then
    ok "пуш без сдвига current не публикуется"
else
    no "пуш без сдвига current не публикуется" "сравнение current" "не найдено"
fi

# seq — антидаунгрейд на роутере. Объявление с непродвинутым seq будет отвергнуто
# у людей: «выпустили, и не доехало».
if grep -q 'NEW_SEQ" -le "\$OLD_SEQ' "$PUB"; then
    ok "объявление с непродвинутым seq отклоняется"
else
    no "объявление с непродвинутым seq отклоняется" "проверка seq" "не найдено"
fi

# Публикуем только верхушку staging: промежуточный коммит имеет свой вердикт, и
# у людей оказалось бы состояние, которого нет ни у кого в работе.
if grep -q 'CAND" != "\$TIP' "$PUB"; then
    ok "публикуется только верхушка staging"
else
    no "публикуется только верхушка staging" "сравнение с tip" "не найдено"
fi

# --- 5. Перемотка вперёд, без --force -----------------------------------------
#
# Единственная защита от публикации разошедшейся истории — отказ самого git.
if grep -q 'git push origin "\$SHA:refs/heads/z2k-enhanced"' "$PUB"; then
    ok "ветка двигается перемоткой вперёд"
else
    no "ветка двигается перемоткой вперёд" "push sha:refs/heads/z2k-enhanced" "не найдено"
fi

if grep -qE 'git push .*(--force|-f )' "$PUB"; then
    no "публикация не пользуется --force" "нет --force" "найден --force"
else
    ok "публикация не пользуется --force"
fi

if grep -q 'merge-base --is-ancestor' "$PUB"; then
    ok "расхождение веток ловится до пуша"
else
    no "расхождение веток ловится до пуша" "merge-base --is-ancestor" "не найдено"
fi

# --- 6. Сброс кэша не теряется ------------------------------------------------
#
# Пуш, сделанный GITHUB_TOKEN, чужие workflow НЕ запускает. Значит после
# публикации jsdelivr-purge.yml сам не заведётся, и без явного вызова мы молча
# остались бы с 12-часовым кэшем зеркала.
if grep -q 'uses: ./.github/workflows/jsdelivr-purge.yml' "$PUB"; then
    ok "сброс кэша вызывается из публикации явно"
else
    no "сброс кэша вызывается явно" "uses: ./.github/workflows/jsdelivr-purge.yml" "не найдено"
fi

if grep -q 'workflow_call:' "$CDN"; then
    ok "workflow сброса кэша вызываемый"
else
    no "workflow сброса кэша вызываемый" "workflow_call" "не найдено"
fi

# И проверять он обязан ИМЕННО опубликованный коммит. По умолчанию контекст
# workflow_run указывает на ветку в состоянии ДО публикации — без явного ref мы
# сверяли бы предыдущий релиз, отчитываясь за новый.
_ck=$(grep -c 'ref: \${{ inputs.ref || github.sha }}' "$CDN")
if [ "$_ck" = "2" ]; then
    ok "обе checkout-джобы сброса кэша берут переданный коммит"
else
    no "обе checkout-джобы берут переданный коммит" "2" "$_ck"
fi

# --- 6а. CDN проверяется и по тегу, не только по ветке -------------------------
#
# Патч-доставка (lib/auto_update.sh, Z2K_AU_TARGET_REF) фетчит файлы по имени
# ТЕГА — это отдельный ключ кэша на raw.githubusercontent.com и jsdelivr,
# независимый от ключа по имени ветки. Проверка только ветки давала зелёный
# verify, даже если кэш по тегу (то, чем реально патчатся роутеры) всё ещё
# отдаёт старьё.
if grep -q 'raw.githubusercontent.com/\${REPO}/\${TAG}/' "$CDN" \
    && grep -q 'cdn.jsdelivr.net/gh/\${REPO}@\${TAG}/' "$CDN"; then
    ok "CDN проверяется по URL с именем тега, не только ветки"
else
    no "CDN проверяется по тегу" 'raw.../${TAG}/... и jsdelivr.../@${TAG}/...' "не найдено"
fi

if grep -q '"current"' "$CDN" && grep -q 'refs/tags/\$TAG' "$CDN"; then
    ok "тег для проверки берётся из current манифеста, локальный тег подтверждается"
else
    no "тег берётся из current и подтверждается локально" 'current -> refs/tags/$TAG' "не найдено"
fi

if grep -q 'fetch-tags: true' "$CDN"; then
    ok "checkout явно тянет теги (не понадеялись на побочный эффект fetch-depth:0)"
else
    no "checkout явно тянет теги" "fetch-tags: true" "не найдено"
fi

# --- 7. В release.sh не осталось обходимого гейта ------------------------------
#
# Старый гейт жил в скрипте и умел пропускаться переменной. Гейт, который можно
# обойти переменной, при одном разработчике рано или поздно обходится.
if grep -q 'Z2K_RELEASE_SKIP_CI_GATE' "$REL" && ! grep -q '^# .*Z2K_RELEASE_SKIP_CI_GATE' "$REL"; then
    no "в release.sh нет обхода гейта" "нет живого Z2K_RELEASE_SKIP_CI_GATE" "обход на месте"
else
    ok "в release.sh нет живого обхода гейта"
fi

if grep -qE '^[^#]*gh run list' "$REL"; then
    no "release.sh не ждёт CI сам" "нет ожидания gh run" "ожидание на месте"
else
    ok "release.sh не ждёт CI сам — ждать больше нечего"
fi

# Собирать релиз в релизной ветке нельзя: коммит там уже был бы публикацией.
if grep -q 'RELEASE_BRANCH' "$REL" && grep -q 'STAGING_BRANCH' "$REL"; then
    ok "release.sh различает рабочую и релизную ветки"
else
    no "release.sh различает ветки" "RELEASE_BRANCH и STAGING_BRANCH" "не найдено"
fi

# --- 8. CI по-прежнему без права записи ---------------------------------------
#
# Публикация — единственное место с записью во всём репозитории.
if awk '/^permissions:/{getline; print; exit}' "$CI" | grep -q 'contents: read'; then
    ok "у CI только чтение"
else
    no "у CI только чтение" "contents: read" "иначе"
fi

# --- 9. Ручной запуск (workflow_dispatch) не публикует непроверенный коммит ---
#
# Условие job'ы наверху пропускает workflow_dispatch БЕЗ проверки
# github.event.workflow_run.conclusion — этому полю у ручного запуска попросту
# неоткуда взяться. Значит без отдельной проверки кто угодно с правом ручного
# запуска мог опубликовать SHA, для которого CI провалился или не бежал вовсе.
if grep -q 'EVENT_NAME" = "workflow_dispatch"' "$PUB" \
    && grep -q 'actions/runs?head_sha=' "$PUB"; then
    ok "ручной запуск сверяется с реальным CI по head_sha, а не доверяет факту ручного вызова"
else
    no "ручной запуск проверяет CI по SHA" "gh api actions/runs?head_sha= внутри ветки workflow_dispatch" "не найдено"
fi

if grep -q 'select(.name=="CI" and .conclusion=="success")' "$PUB"; then
    ok "проверяется именно CI и именно success, а не любой прогон"
else
    no "проверяется CI+success" "select по name==CI и conclusion==success" "не найдено"
fi

# gh api ходит в Actions REST — джобе нужно чтение actions, отдельно от
# contents. Без него шаг выше молча получил бы 403 и после `|| _ci_ok=0`
# ушёл бы в отказ по НЕПРАВИЛЬНОЙ причине (выглядело бы как «нет зелёного CI»,
# хотя на деле «нет прав спросить»), и это не поймать снаружи по логам одной строкой.
if _gate_block | grep -q 'actions: read'; then
    ok "у gate есть право читать Actions API (нужно для проверки CI по SHA)"
else
    no "у gate есть actions: read" "actions: read внутри job gate" "не найдено"
fi

# --- 10. Целостность history манифеста проверяется независимо от release.sh ---
#
# release.sh и так гарантирует это по построению (дописывает одну строку текстом,
# не трогая остальные), но gate — это защита от чужого процесса: ручной правки,
# кривого мерджа, скомпрометированного release.sh на чьей-то машине. seq и
# подпись сами по себе порчу history не ловят: seq может честно вырасти на
# переписанной истории, а подпись накроет что угодно, что ей дали подписать.
if grep -q 'nh\[:len(oh)\] != oh' "$PUB"; then
    ok "gate требует, чтобы старая history осталась неизменным префиксом"
else
    no "gate требует неизменный префикс history" "nh[:len(oh)] != oh" "не найдено"
fi

if grep -q 'len(nh) != len(oh) + 1' "$PUB"; then
    ok "gate требует ровно одну новую запись history у кандидата"
else
    no "gate требует ровно одну новую запись" "len(nh) != len(oh) + 1" "не найдено"
fi

if grep -q 'new\["current"\] != nh\[-1\]\["v"\]' "$PUB"; then
    ok "gate требует current == history[-1].v"
else
    no "gate требует current == history[-1].v" 'new["current"] != nh[-1]["v"]' "не найдено"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
