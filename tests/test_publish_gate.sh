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

# --- 5. Перемотка вперёд, без принудительного обновления ----------------------
#
# Единственная защита от публикации разошедшейся истории — отказ самой
# платформы. Механизм с 2026-08-11 не `git push`, а REST API: чекаут в job
# публикации существовал только ради пуша и оставлял токен в .git/config
# (zizmor artipacked), а документированного способа пушить без сохранённых
# учётных данных actions/checkout не даёт. Гарантия при этом ровно та же —
# документация REST API: «Leaving this out or setting it to false will make
# sure you're not overwriting work» (https://docs.github.com/en/rest/git/refs).
#
# Проверяем СВОЙСТВО, а не команду: ссылка переводится на $SHA и параметр
# force не передаётся ни в каком виде.
if grep -q 'git/refs/heads/z2k-enhanced' "$PUB" && grep -q 'sha=\${SHA}' "$PUB"; then
    ok "ветка двигается переводом ссылки на проверенный коммит"
else
    no "ветка двигается переводом ссылки на \$SHA" "PATCH git/refs/heads/z2k-enhanced + sha=\$SHA" "не найдено"
fi
if grep -qE '(-f|-F) *"?force' "$PUB"; then
    no "принудительное обновление ссылки не используется" "нет force" "force передаётся"
else
    ok "force не передаётся — платформа сама отказывает, если это не перемотка вперёд"
fi
# Чекаута в job публикации быть не должно: он и тащил за собой токен на диск.
# Именно ШАГ `- uses: actions/checkout`, а не упоминание в комментарии:
# обоснование рядом само называет действие по имени, и голый grep зеленел бы
# на комментарии при вернувшемся чекауте (эта ловушка сегодня срабатывала уже
# дважды).
if awk '/^  publish:/,/^  cdn:/' "$PUB" | grep -qE '^[[:space:]]*-[[:space:]]+uses:[[:space:]]*actions/checkout'; then
    no "job публикации обходится без рабочего дерева" "нет actions/checkout" "чекаут вернулся — вместе с токеном в .git/config"
else
    ok "job публикации не выкачивает дерево — токен на диск не попадает"
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
# Джоба теперь одна: проверка отдачи убрана 2026-08-12 вместе со своими
# проверками (см. пояснение ниже). Требуем ровно один явный ref, а не «два» —
# ожидание «двух» краснело бы на верной конфигурации.
_ck=$(grep -c 'ref: \${{ inputs.ref || github.sha }}' "$CDN")
if [ "$_ck" = "1" ]; then
    ok "джоба сброса кэша берёт переданный коммит, а не состояние ветки до публикации"
else
    no "checkout берёт переданный коммит" "1" "$_ck"
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

_pubstep=$(awk '/name: Перевести ссылку релизной ветки/,/^  cdn:/' "$PUB")
if printf '%s' "$_pubstep" | grep -q 'if ! gh api -X PATCH' \
    && printf '%s' "$_pubstep" | grep -q 'moved=no' \
    && printf '%s' "$_pubstep" | grep -q 'exit 1'; then
    ok "неудачный перевод ссылки — это красная job с moved=no, а не тихий пропуск"
else
    no "неудачный перевод ссылки красит job" 'if ! gh api -X PATCH ...; then moved=no; exit 1; fi' "не найдено"
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

# --- 21. cancel-in-progress не может отменить CI релизного кандидата --------
#
# Живой сценарий: пуш обычного коммита B в staging, пока ещё бежит CI
# релизного коммита A, отменял CI(A) по cancel-in-progress — "наслоившийся"
# ран гасился новым, не разбирая, что A нёс невыпущенный подписанный тег.
# Результат — тупик с обеих сторон: workflow_run для A никогда не выстрелит
# (conclusion=cancelled, не success), а CI(B), даже отработав, не может
# опубликовать ничего под именем релиза A — тег указывает на A, gate это
# отдельно сверяет и откажет "тег указывает не на этот коммит". Раньше
# исключение из cancel-in-progress было только для z2k-enhanced — верно ДО
# перехода на публикацию через workflow_run с staging, устарело после.
if grep -qE "cancel-in-progress:.*z2k-enhanced.*&&.*z2k-staging|cancel-in-progress:.*z2k-staging.*&&.*z2k-enhanced" "$CI"; then
    ok "CI не отменяется cancel-in-progress ни на z2k-enhanced, ни на z2k-staging — оба гейтят публикацию"
else
    no "cancel-in-progress отключён и на staging, не только на enhanced" \
       "ref != z2k-enhanced && ref != z2k-staging" "не найдено"
fi

# --- 20b. подавление zizmor — только вместе с обоснованием -------------------
#
# Подавить находку анализатора легко, и именно поэтому опасно: молчаливый
# `ignore` неотличим от «разобрались». Требуем, чтобы рядом с подавлением
# оставался разбор — и чтобы подавлялось ровно одно известное правило, а не
# всё подряд.
_zz=$(grep -n 'zizmor: ignore' "$PUB" || true)
if [ -n "$_zz" ]; then
    if printf '%s' "$_zz" | grep -q 'ignore\[dangerous-triggers\]' \
       && grep -q 'публикация требует тег, подписанный ключом' "$PUB"; then
        ok "подавление zizmor точечное (dangerous-triggers) и снабжено разбором"
    else
        no "подавление zizmor названо по правилу и обосновано" \
           "ignore[dangerous-triggers] + разбор рядом" "$(printf '%s' "$_zz" | head -1)"
    fi
    # Никаких «заглушить всё»: подавление без имени правила недопустимо.
    if printf '%s' "$_zz" | grep -qE 'zizmor: ignore[^[]'; then
        no "подавление всегда с именем правила" "ignore[<правило>]" "есть безымянное подавление"
    else
        ok "безымянных подавлений zizmor нет"
    fi
fi

# --- 14. ПРОВЕРКИ УДАЛЁННОЙ CDN-ВЕРИФИКАЦИИ УБРАНЫ (2026-08-12) --------------
#
# Здесь стояли пять групп проверок над job `verify` из jsdelivr-purge.yml:
# полнота списка файлов, дедлайн внутри раунда, независимость проходов raw и
# jsdelivr, красный статус при рассогласовании корня доверия, ожидание с
# повтором. Самой job больше нет — решение Марка от 2026-08-12.
#
# Причина в jsdelivr-purge.yml описана целиком; коротко: краснела она не от
# того класса отказа, ради которого писалась. Гейтом доставки служит
# raw.githubusercontent, а красный давало отставание jsdelivr — фоллбэка,
# который сам догоняет за часы. Письмо о провале приходило каждый релиз при
# исправной доставке.
#
# Проверки удалены, а не закомментированы: тест, который сторожит то, чего
# нет, краснеет на каждой правке файла и учит не смотреть на красное.

# --- 21b. у запертого выпуска есть документированный выход ------------------
#
# Гейт «один релиз в полёте» держит выпуск до публикации предыдущего. Значит
# кандидат, который опубликован не будет никогда (CI красный по существу),
# без процедуры отзыва запирает выпуск НАВСЕГДА. Требуем, чтобы выход был
# описан и чтобы отказ гейта на него показывал — искать его нужно ровно в тот
# момент, когда упёрся, а не когда-нибудь потом.
RELDOC="$ROOT/RELEASING.md"
if [ -f "$RELDOC" ] && grep -q 'Отмена окончательно красного кандидата' "$RELDOC" \
   && grep -q 'refs/tags/' "$RELDOC"; then
    ok "путь отзыва мёртвого кандидата описан (и включает снятие подписанного тега)"
else
    no "RELEASING.md описывает отзыв кандидата вместе со снятием тега" \
       "раздел про отмену + git push origin :refs/tags/" "не найдено"
fi
if grep -q 'RELEASING.md' "$REL"; then
    ok "отказ гейта отсылает к процедуре отзыва, а не оставляет наедине с тупиком"
else
    no "release.sh в отказе ссылается на процедуру отзыва" "упоминание RELEASING.md" "нет"
fi

# --- 21c. гейт читает принесённое, а не remote-tracking ссылку --------------
#
# `git fetch origin <branch>` обновляет refs/remotes/origin/<branch> не во
# всякой конфигурации. Гейт, сверяющийся с устаревшей ссылкой, и пропускает
# второй релиз в полёте, и блокирует законный — оба исхода молча.
if grep -q 'git show FETCH_HEAD:UPDATES.json' "$REL" \
   && ! grep -q 'git show "origin/\${RELEASE_BRANCH}:UPDATES.json"' "$REL"; then
    ok "release.sh сверяется с только что принесённым FETCH_HEAD, не с remote-tracking ссылкой"
else
    no "release.sh читает FETCH_HEAD" "git show FETCH_HEAD:UPDATES.json" "читает origin/<branch>"
fi

# --- 22. группа CI на релизных ветках уникальна по SHA, не по ref -----------
#
# cancel-in-progress: false защищает только УЖЕ ИДУЩИЙ ран. У GitHub в каждой
# concurrency-группе по умолчанию держится ровно один pending (ожидающий)
# ран — следующий триггер молча отменяет и заменяет его, cancel-in-progress
# на это вообще не влияет (см. коммент над блоком concurrency в ci.yml и
# https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
# Живой сценарий: коммит X идёт, релизный A встаёт за ним в очередь, потом
# пушится обычный B — его pending отменяет ожидающий A. Эмпирически
# воспроизведено и проверено 2026-08-10 на отдельной ветке-пробнике: с
# группой по ref pending-ран стабильно отменялся; с группой по SHA — нет
# (коллизии группы физически не с кем разделить, если каждый коммит один).
if grep -qE "group:.*z2k-enhanced.*z2k-staging.*&&.*github\.sha|group:.*\(.*z2k-enhanced.*\|\|.*z2k-staging.*\).*&&.*github\.sha" "$CI"; then
    ok "группа CI на z2k-enhanced/z2k-staging уникальна по SHA — не делится в очереди ни с кем"
else
    no "concurrency.group на релизных ветках включает github.sha, а не только ref" \
       "group содержит (z2k-enhanced || z2k-staging) && github.sha" "не найдено"
fi

# --- 23. очередь publish не теряет ожидающие релизы -------------------------
#
# Тот же класс бага, что и в 22, но в publish.yml: группа там СТАТИЧЕСКАЯ
# ("publish", намеренно — публикация должна сериализоваться), поэтому лечить
# уникальностью группы нельзя, и это ровно случай, для которого GitHub
# документирует queue: max — расширить очередь pending-ранов с 1 до 100
# вместо замены новым. cancel-in-progress: true с queue: max несовместимы
# (ошибка валидации воркфлоу), но здесь cancel-in-progress статически false,
# конфликта нет. Без queue: max ожидающий publish кандидата A, пока идёт
# более ранний ран той же группы, отменяется публикацией следующего
# успешного CI на staging (даже если тот publish=no) — тег A остаётся
# неопубликованным. Эмпирически воспроизведено 2026-08-10.
if grep -qE '^[[:space:]]*queue:[[:space:]]*max[[:space:]]*$' "$PUB"; then
    ok "publish.yml: очередь publish расширена (queue: max) — ожидающий релиз не теряется"
else
    no "publish.yml имеет queue: max в блоке concurrency" "queue: max" "не найдено"
fi

# То же самое в jsdelivr-purge.yml. Группа там ОДНА на все три триггера
# фактически, а не по недосмотру: ветка по умолчанию репозитория —
# z2k-enhanced, поэтому push в неё, workflow_dispatch и вызов из publish.yml
# дают один и тот же `cdn-refs/heads/z2k-enhanced`. Уникализировать по SHA,
# как в ci.yml, нельзя — последовательность в одной группе здесь и есть цель.
# Файл сам декларирует намерение "старый ран НЕ гасим", но одного
# cancel-in-progress: false для него не хватает: он держит только идущий ран,
# а pending всё равно вытесняется третьим триггером. Теряется при этом именно
# СБРОС КЭША уже выложенного релиза: ран не красный, его просто нет, а зеркало
# продолжает отдавать старьё до двенадцати часов.
if grep -qE '^[[:space:]]*queue:[[:space:]]*max[[:space:]]*$' "$CDN"; then
    ok "jsdelivr-purge.yml: очередь сброса кэша расширена (queue: max) — сброс релиза не вытесняется"
else
    no "jsdelivr-purge.yml имеет queue: max в блоке concurrency" "queue: max" "не найдено"
fi

# --- 24. actionlint-исключение под queue не расширено дальше нужного -------
#
# actionlint@v1.7.12 (версия, зафиксированная и в ci.yml, и в ci_local.sh) не
# знает про ключ queue (rhysd/actionlint#657, ещё не выпущено) и без
# .github/actionlint.yaml ЛОЖНО красит publish.yml. Исключение обязано быть
# точечным: только для publish.yml и только для сообщения про queue — иначе
# оно тихо проглотит и настоящие будущие ошибки actionlint в этом файле.
ACTIONLINT_CFG="$ROOT/.github/actionlint.yaml"
# Инвариант, а не список файлов: исключение не должно быть шире самой дыры в
# actionlint. Значит (а) каждый путь под `paths:` — это файл, который РЕАЛЬНО
# использует queue (иначе исключение нечем оправдать и оно тихо проглотит
# будущие настоящие ошибки в этом файле), и (б) каждый ignore-шаблон говорит
# именно про queue. Список файлов сознательно не хардкожу: он будет расти по
# мере надобности, а инвариант — нет.
#
# Разбираем только реальные ключи (без ведущего "#"): комментарий-обоснование
# в самом конфиге упоминает "ci.yml" по имени, и это не исключение.
_al_path_keys=$(awk '
    /^paths:/ { inpaths=1; next }
    inpaths && /^  [^ #]/ { sub(/:[[:space:]]*$/, ""); sub(/^  /, ""); print; next }
    inpaths && /^[^ ]/ { inpaths=0 }
' "$ACTIONLINT_CFG" 2>/dev/null)
_al_ignores=$(awk '
    /^paths:/ { inpaths=1 }
    inpaths && /^      - / { print }
' "$ACTIONLINT_CFG" 2>/dev/null)
_al_bad=""
[ -n "$_al_path_keys" ] || _al_bad="нет ни одного path-ключа"
# (а) каждый файл под исключением действительно использует queue
for _p in $_al_path_keys; do
    if ! grep -qE '^[[:space:]]*queue:' "$ROOT/$_p" 2>/dev/null; then
        _al_bad="исключение на $_p, который queue не использует"
    fi
done
# (б) каждый ignore-шаблон — именно про queue
printf '%s\n' "$_al_ignores" | while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    case "$_line" in *queue*) ;; *) exit 7 ;; esac
done || _al_bad="есть ignore-шаблон не про queue"
if [ -f "$ACTIONLINT_CFG" ] && [ -z "$_al_bad" ]; then
    ok "actionlint.yaml: исключения под неизвестный actionlint'у queue не шире самой дыры (только queue, только файлы с queue)"
else
    no "actionlint.yaml: каждый path-ключ реально использует queue и каждый ignore — про queue" \
       "исключение ровно под дыру actionlint" "${_al_bad:-конфига нет}"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
