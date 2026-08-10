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
CILOCAL="$ROOT/scripts/ci_local.sh"

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

# tip-check ОСОЗНАННО убран (было: "публикуем только если CAND == верхушка
# staging"). Он противоречил формальной модели "кандидат = подписанный тег":
# уже подписанный, полностью валидный тег A застревал НАВСЕГДА, стоило после
# него появиться любому обычному коммиту B без своего релиза — свой ран у A
# не было и вызвать некому. Защиту от публикации УЖЕ УСТАРЕВШЕГО кандидата
# даёт seq (см. проверку выше): если что-то новее уже опубликовано,
# seq(candidate) <= seq(published) и гейт откажет по существу, а не по
# случайному совпадению с текущим состоянием ветки.
if grep -q 'CAND" != "\$TIP' "$PUB"; then
    no "tip-check убран (застревал валидный тег из-за постороннего коммита)" "нет сравнения с tip" "остался"
else
    ok "tip-check убран — seq и history остаются единственной защитой от устаревшего кандидата"
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

# --- 6б. timeout-minutes у verify реально покрывает сумму внутренних дедлайнов -
#
# Поллинг по ветке и по тегу идут ПОСЛЕДОВАТЕЛЬНО в одной job. Каждый шаг сам
# по себе укладывается в свой дедлайн, но GitHub убивает job по СУММЕ, а не по
# отдельному шагу — job, добравшаяся до тег-проверки только к 24-й минуте при
# лимите 25, будет убита посреди содержательной работы, и это будет выглядеть
# как "job cancelled" безо всякой диагностики. Сверяем таймаут job с суммой
# ВСЕХ дедлайнов, которые эта job проходит одну за другой, а не гоняем реальный
# workflow_run (нельзя, см. шапку файла).
# Не привязываемся к конкретному имени переменной (cdn_deadline,
# _cdn_tag_deadline, ...) — только к форме выражения справа. Привязка к
# точному имени уже один раз чуть не подвела: новый дедлайн для jsdelivr по
# тегу назвали "_cdn_tag_deadline=", а не "cdn_deadline=", и старый regex
# его бы молча пропустил.
_deadlines=$(grep -oE '\(started \+ [0-9]+\)|\$\(\( \$\(date \+%s\) \+ [0-9]+ \)\)' "$CDN" \
             | grep -oE '[0-9]+' )
_sig_retries=$(awk '/for i in 1 2 3 4 5 6 7 8 9 10;/{print}' "$CDN" | grep -oE '1 2 3 4 5 6 7 8 9 10' | wc -w)
_sig_sleep=$(grep -A3 'sleep 20' "$CDN" | grep -oE 'sleep [0-9]+' | head -1 | grep -oE '[0-9]+')
# Каждая попытка внутри "for i in 1..10" — это не только sleep между ними: два
# curl --max-time на СЕТЕВОЙ запрос (m.json + m.sig), и при реальном
# зависании (не быстром отказе) КАЖДЫЙ добирает до своего таймаута целиком.
# Считать только sleep — недосчитать ровно эти сетевые max-time; раньше здесь
# так и было, разница набегала до 400с (10 попыток × 2 curl × 20с).
_sig_curl_per_try=$(awk '/for i in 1 2 3 4 5 6 7 8 9 10;/,/^          done$/' "$CDN" \
                     | grep -oE -- '--max-time [0-9]+' | grep -oE '[0-9]+' \
                     | awk '{s+=$1} END{print s+0}')
_sum=0
for d in $_deadlines; do _sum=$((_sum + d)); done
if [ -n "$_sig_retries" ] && [ -n "$_sig_sleep" ]; then
    _sum=$((_sum + _sig_retries * (_sig_sleep + _sig_curl_per_try)))
fi
# Не просто "больше" — эта сумма уже один раз оказалась заниженной на 400с
# (сетевые --max-time внутри retry-цикла подписи не считались), и "timeout
# больше суммы на 4 минуты" оказалось технически "проходит", но по факту
# без реального запаса. Требуем минимум 20% сверху — не строгая граница,
# а сигнал "числа наступают друг другу на пятки, посмотри ещё раз", если
# кто-то добавит новую последовательную проверку и подвинет сумму вплотную
# к таймауту.
_timeout_min=$(awk '/^  verify:/{f=1} f && /timeout-minutes:/{print $2; exit}' "$CDN")
_min_required=$(( _sum * 12 / 10 ))
if [ -n "$_timeout_min" ] && [ -n "$_sum" ] && [ "$_sum" -gt "0" ] && [ $((_timeout_min * 60)) -ge "$_min_required" ]; then
    ok "timeout-minutes у verify ($_timeout_min мин) покрывает сумму внутренних дедлайнов с запасом ≥20% (${_sum}с = $((_sum / 60))мин)"
else
    no "timeout-minutes покрывает сумму дедлайнов с запасом ≥20%" \
       "timeout*60 >= сумма*1.2 ($_min_required с)" "timeout=${_timeout_min:-?}мин (=$((_timeout_min * 60))с), сумма=${_sum:-?}с"
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

if grep -q 'select(.path==".github/workflows/ci.yml" and .conclusion=="success")' "$PUB"; then
    ok "проверяется именно CI и именно success, а не любой прогон"
else
    no "проверяется CI+success" "select по path==.github/workflows/ci.yml и conclusion==success" "не найдено"
fi

# path, а не name: display name ("CI") — вольный текст из name: в самом
# workflow-файле, переименование сломало бы матч по имени незаметно. path —
# файл в дереве, стабильный идентификатор.
if grep -q '\.name=="CI"' "$PUB"; then
    no "матч по CI не завязан на изменяемое display name" "только path" "остался матч по .name"
else
    ok "матч по CI завязан на path (стабильный идентификатор), не на переименовываемое display name"
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

# --- 11. Тот же преflight дублируется на staging, до publish.yml -------------
#
# workflow_run в publish.yml берёт САМ ФАЙЛ publish.yml с ветки по умолчанию,
# не со staging (см. комментарий в самом publish.yml). Проверки тега и history
# появились позже схемы публикации — первый релиз, которому они реально нужны,
# попадёт под СТАРЫЙ publish.yml, где их ещё нет. До тех пор, пока кто-то не
# проведёт хотя бы один релиз через обновлённый publish.yml, единственная
# защита — копия этих же проверок на staging.
if grep -q "refs/tags/\$NEW_CUR" "$CI" && grep -q 'git rev-list -n 1 "refs/tags/\$NEW_CUR"' "$CI"; then
    ok "CI на staging проверяет существование и цель тега (не только publish.yml)"
else
    no "CI на staging проверяет тег" 'refs/tags/$NEW_CUR + rev-list' "не найдено"
fi

if grep -qE "grep -q ['\"]BEGIN SSH SIGNATURE" "$CI"; then
    no "CI на staging проверяет КОНКРЕТНОГО подписанта, не просто маркер" \
       "нет живого grep -q BEGIN SSH SIGNATURE" "остался — пропускает тег с чужим ключом"
else
    ok "CI на staging не довольствуется голым SSH-маркером подписи (только упоминание в комментарии-обосновании)"
fi

if grep -q "gpg.ssh.allowedSignersFile" "$CI" && grep -q "verify-tag" "$CI" \
    && grep -q "z2k-update-pub.pem" "$CI"; then
    ok "CI на staging сверяет тег с ОПУБЛИКОВАННЫМ ключом (allowed-signers), не просто фактом подписи"
else
    no "CI на staging сверяет тег с конкретным ключом" \
       "allowedSignersFile + verify-tag + z2k-update-pub.pem" "не найдено"
fi

if grep -q 'nh\[:len(oh)\] != oh' "$CI" && grep -q 'len(nh) != len(oh) + 1' "$CI"; then
    ok "CI на staging дублирует семантический gate history (префикс + ровно одна запись)"
else
    no "CI на staging дублирует gate history" "та же логика, что в publish.yml" "не найдено"
fi

# --- 12. Версия не переиспользуется, новая запись полна по схеме -------------
#
# Семантический gate раньше проверял только форму (префикс/count/current==v),
# но не содержание: номер версии мог повториться (роутер, уже видевший этот
# номер, не обновится — installed_tag==current трактуется как "уже стоит"), а
# запись могла не хватать поля вроде changed_files и патч разъехался бы молча.
# Проверяем И publish.yml (настоящий гейт, решает он), И ci.yml (preflight на
# staging) — слабее настоящего гейта preflight быть не должен.
for _f_name in "publish.yml:$PUB" "ci.yml (preflight):$CI"; do
    _label="${_f_name%%:*}"
    _f="${_f_name#*:}"
    if grep -q "entry\['v'\] in versions_seen" "$_f" || grep -q 'entry\["v"\] in versions_seen' "$_f"; then
        ok "$_label: версия проверяется на переиспользование по всей history"
    else
        no "$_label: версия проверяется на переиспользование" "entry[\"v\"] in versions_seen" "не найдено"
    fi

    if grep -q 'required = {"v": str, "type": str, "ts": str, "ref": str, "desc": str, "changed_files": list}' "$_f"; then
        ok "$_label: схема новой записи history проверяется по всем обязательным полям и типам"
    else
        no "$_label: схема новой записи проверяется полностью" "required = {v,type,ts,ref,desc,changed_files}" "не найдено"
    fi
done

# --- 13. Push не делает второй tip-check — тег уже полностью провалидирован --
#
# Был "повторный fetch + сверка верхушки" прямо перед push — убран тем же
# коммитом, что и tip-check в gate: тот же anti-паттерн (валидный тег
# застревает из-за постороннего коммита на staging), только на более узком
# окне. Единственная оставшаяся защита здесь — сам git push без --force:
# он либо пройдёт (fast-forward), либо честно упадёт (job красная), а не
# тихо "пропущено, устарело".
if grep -q '_tip_now' "$PUB"; then
    no "второй tip-check перед push убран" "нет повторной сверки с tip staging" "остался (_tip_now)"
else
    ok "второй tip-check перед push убран — push либо проходит, либо честно падает по fast-forward"
fi

if grep -q 'if ! git push origin "\$SHA:refs/heads/z2k-enhanced"; then' "$PUB" \
    && awk '/name: Push fast-forward/,/^  cdn:/' "$PUB" | grep -q 'moved=no' \
    && awk '/name: Push fast-forward/,/^  cdn:/' "$PUB" | grep -q 'exit 1'; then
    ok "неудачный push (не fast-forward) — это красная job с moved=no, а не тихий пропуск"
else
    no "неудачный push красит job, а не пропускает молча" 'if ! git push ...; then moved=no; exit 1; fi' "не найдено"
fi

# --- 14. CDN verify не режет список файлов молча ------------------------------
#
# Раньше при превышении лимита (120, а манифест уже нёс 107) job резала
# список, печатала ::warning:: и шла дальше ЗЕЛЁНОЙ — "проверено" и "проверены
# первые N" неотличимы по цвету. ::warning:: — не то же самое, что job status:
# он не красит job красным и легко пролистывается в логе.
if grep -qE 'if \[ "\$total" -gt 300 \]' "$CDN"; then
    ok "CDN verify поднял лимит с 120 (почти исчерпан) на 300 (реальный запас)"
else
    no "CDN verify поднял лимит" '$total" -gt 300' "не найдено — лимит остался прежним или исчез вовсе"
fi

if awk '/if \[ "\$total" -gt 300 \]/,/^          fi$/' "$CDN" | grep -q 'exit 1'; then
    ok "CDN verify фейлится КРАСНЫМ при превышении лимита, а не режет список молча"
else
    no "CDN verify фейлится при превышении лимита" "exit 1 внутри if total -gt 300" "не найдено"
fi

if grep -qE '::warning::verify capped' "$CDN"; then
    no "нет старого молчаливого усечения с warning" "нет" "старая ветка ::warning::verify capped осталась"
else
    ok "старая ветка молчаливого усечения (warning + head -120) убрана"
fi

# --- 15. Manual-gate CI-check по стабильному идентификатору workflow ----------
#
# .name — вольный текст из name: в самом workflow-файле; переименование
# ci.yml (или его name:) молча ломает матч. .path — файл в дереве, тот же
# всегда, пока файл не переехал (а переезд — это явная, видимая правка, а не
# косметика).
if grep -q '\.name=="CI"' "$PUB"; then
    no "manual-gate матчит CI по стабильному path, не по name" "нет .name==\"CI\"" "остался"
else
    ok "manual-gate матчит CI по стабильному path (.github/workflows/ci.yml), не по переименовываемому name"
fi

# --- 16. mtproxy-сверка пинует ТОЧНУЮ прод-версию Go, не первый попавшийся ---
#
# Живьём воспроизведено: `command -v go` на машине с несколькими тулчейнами
# нашёл go1.26.1, хотя прод собирается go1.25.12 — сверка байт-в-байт с таким
# несовпадением либо ложно падает на валидном релизе, либо (хуже) случайно
# совпадает и ничего не доказывает.
if grep -q 'GO_VERSION:' "$CI" && grep -qE 'sed -n .s/\^\[\[:space:\]\]\*GO_VERSION' "$REL"; then
    ok "версия Go для сверки mtproxy читается из GO_VERSION в ci.yml, а не второй раз хардкодится"
else
    no "версия Go читается из единого источника (ci.yml GO_VERSION)" "sed по GO_VERSION в release.sh" "не найдено"
fi

if grep -q '\$HOME/go/bin/go\$_go_ver' "$REL"; then
    ok "release.sh требует ИМЕННО этот бинарник (\$HOME/go/bin/goX.Y.Z), не bare go из PATH"
else
    no "release.sh требует конкретный бинарник, не PATH" '$HOME/go/bin/go$_go_ver' "не найдено"
fi

if grep -q '"\$_go_actual" = "go\$_go_ver"' "$REL"; then
    ok "release.sh перепроверяет, что найденный бинарник ДЕЙСТВИТЕЛЬНО сообщает нужную версию (не просто верит имени файла)"
else
    no "release.sh перепроверяет версию через go version" '"$_go_actual" = "go$_go_ver"' "не найдено"
fi

# --- 17. CDN не гоняется, если публикация фактически не сдвинула ветку -------
#
# publish, встретив устаревшего кандидата, раньше делал `exit 0` (успех) без
# сигнала об этом наружу — cdn job смотрел только на `gate.outputs.publish`,
# который не в курсе, что публикация сама себя пропустила, и честно пытался
# проверить релиз, которого на ветке физически нет.
if grep -q 'moved: \${{ steps.push.outputs.moved }}' "$PUB"; then
    ok "publish job отдаёт наружу, реально ли сдвинул ветку (moved), а не только свой exit code"
else
    no "publish job отдаёт moved output" 'moved: ${{ steps.push.outputs.moved }}' "не найдено"
fi

if grep -q "needs.gate.outputs.publish == 'yes' && needs.publish.outputs.moved == 'yes'" "$PUB"; then
    ok "cdn job запускается только когда публикация РЕАЛЬНО произошла (gate=yes И moved=yes)"
else
    no "cdn job учитывает moved, не только gate.publish" "publish=='yes' && moved=='yes'" "не найдено"
fi

# --- 18. CDN-verify проверяет дедлайн ВНУТРИ раунда, не только между ними ----
#
# Раунд — последовательный проход по pending с curl --max-time 30 на файл на
# каждое зеркало. При большом числе файлов и реально зависшей (не быстро
# отказавшей) сети один раунд сам по себе может уйти далеко за общий бюджет
# job, а проверка "между раундами" до этого момента просто не доедет.
#
# ДВА поллинг-цикла (ветка и тег), у каждого свой pending/deadline — гейт на
# первую находку закрыл только ветку; тег остался с тем же классом дыры
# (дедлайн 10 минут, до 107+ файлов последовательно — потенциально ~107
# минут вместо 10). Считаем оба вхождения, а не "хотя бы одно": единственное
# совпадение означало бы, что кто-то один цикл починил, а второй — нет.
_round_i_count=$(grep -c '_round_i=\$((_round_i + 1))' "$CDN")
if [ "$_round_i_count" = "2" ] && grep -q '"\$(date +%s)" -ge "\$deadline"' "$CDN"; then
    ok "CDN-verify проверяет дедлайн перед КАЖДЫМ файлом внутри раунда — в ОБОИХ циклах (ветка и тег)"
else
    no "CDN-verify проверяет дедлайн внутри раунда в обоих циклах" "2 вхождения _round_i" "$_round_i_count"
fi

# --- 19. raw и jsdelivr — независимые проходы, не один цикл на двоих --------
#
# Раньше на каждый файл в raw-раунде синхронно ждали ЕЩЁ и jsdelivr — тот же
# curl --max-time 30, только к необязательному фоллбэку, и ЭТО время всё
# равно вычиталось из дедлайна raw — единственного гейта, который решает
# исход публикации. Полностью исправный, быстрый raw мог получить ложный
# красный результат по вине зависшего фоллбэка. Проверяем ПОВЕДЕНЧЕСКИ, не
# по тексту: внутри цикла, который читает pending.txt (raw-гейт), не должно
# быть обращений к cdn.jsdelivr.net вообще — jsdelivr должен жить в
# отдельном, более позднем блоке.
if awk '/cp \/tmp\/verify\/files.txt \/tmp\/verify\/pending.txt/,/^          done$/' "$CDN" \
    | grep -q 'cdn.jsdelivr.net'; then
    no "raw-раунд (branch) не обращается к jsdelivr внутри себя" "нет cdn.jsdelivr.net в raw-цикле" "найдено"
else
    ok "raw-раунд (branch) полностью независим от jsdelivr — не может получить от него ложный красный"
fi

if awk '/cp \/tmp\/verify\/files.txt \/tmp\/verify\/tag_pending.txt/,/^          done$/' "$CDN" \
    | grep -q 'cdn.jsdelivr.net'; then
    no "raw-раунд (tag) не обращается к jsdelivr внутри себя" "нет cdn.jsdelivr.net в tag raw-цикле" "найдено"
else
    ok "raw-раунд (tag) полностью независим от jsdelivr — не может получить от него ложный красный"
fi

if grep -q 'raw_ok.txt' "$CDN" && grep -q 'tag_raw_ok.txt' "$CDN"; then
    ok "оба raw-гейта копят СВОЙ список успехов (raw_ok/tag_raw_ok) отдельно от jsdelivr-проверки"
else
    no "raw-гейты копят список успехов отдельно от jsdelivr" "raw_ok.txt и tag_raw_ok.txt" "не найдено"
fi

# --- 20. ci_local.sh не строже реального CI на severity actionlint'а --------
#
# Найдено на практике, не в теории: actionlint без SHELLCHECK_OPTS гоняет
# встроенный ShellCheck на info-уровне, ci.yml ("Workflow lint") явно
# понижает до warning — а ci_local.sh этого не делал, и локальный прогон
# падал на info-находке (SC2094), которую реальный CI пропустил бы молча.
# "Локально строже судьи" — тот же класс расхождения, что уже чинили для
# go-модулей (build-matrix.tsv), только для линтера, а не для сборки.
if [ -f "$CILOCAL" ]; then
    if grep -q 'SHELLCHECK_OPTS' "$CI" && ! grep -q 'SHELLCHECK_OPTS' "$CILOCAL"; then
        no "ci_local.sh задаёт тот же SHELLCHECK_OPTS для actionlint, что и ci.yml" \
           "SHELLCHECK_OPTS в обоих файлах" "есть в ci.yml, нет в ci_local.sh"
    else
        ok "ci_local.sh не строже реального CI на severity встроенного в actionlint ShellCheck"
    fi
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
