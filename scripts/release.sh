#!/bin/sh
# scripts/release.sh — собрать релиз: запись в UPDATES.json, карта сумм, коммиты.
#
# ЗАЧЕМ. До 2026-08-05 такого скрипта не существовало: релиз собирался руками
# каждый раз. Список файлов писался глазами по памяти о том, что менялось, и
# промахи в нём — не гипотеза, а трижды случившийся факт (index.html пропускали
# в r-71.1, r-72, r-72.1). Цена промаха не косметическая: незаявленный файл
# патчем НЕ доставляется, версия при этом продвигается вперёд, и у человека
# остаётся старый код под новым номером — то есть ровно то состояние, которое
# невозможно опознать снаружи.
#
# Поэтому список файлов здесь НЕ пишется руками. Он вычисляется из git: что
# изменилось с предыдущего релиза, то и заявлено. Человек не может забыть то,
# чего не набирает.
#
# Использование (двухфазный релиз, см. CD-гейт ниже):
#   1. push кода в z2k-enhanced (current не двигается — флот обновы не видит)
#   2. дождаться зелёного CI (release.sh сам ждёт и сверяет)
#   3. sh scripts/release.sh <версия> <тип> <описание>
#      sh scripts/release.sh r-72.3 patch "Описание для человека, 1-3 предложения."
#   4. push объявления — это и есть релиз для флота
#
# Тип: patch — файлы раскладываются по местам; reinstall — прогоняется установка
# целиком. Reinstall нужен, когда меняются вещи, которые install.sh ГЕНЕРИРУЕТ
# (конфиги, init-скрипты) или когда меняется бинарник: цель для него зависит от
# архитектуры роутера, и патч разложил бы arm64 на mipsel.
#
# POSIX sh.

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MANIFEST=UPDATES.json

die() { printf 'release: %s\n' "$1" >&2; exit 1; }

VER="${1:-}"
TYPE="${2:-}"
DESC="${3:-}"

[ -n "$VER" ]  || die "не указана версия (пример: r-72.3 или p-73.1)"
[ -n "$TYPE" ] || die "не указан тип: patch или reinstall"
[ -n "$DESC" ] || die "не указано описание"

case "$TYPE" in
    patch|reinstall) ;;
    *) die "тип должен быть patch или reinstall, а не '$TYPE'" ;;
esac

# Формат версии тот же, что уже в истории: буква, дефис, числа через точку.
case "$VER" in
    [rp]-[0-9]*) ;;
    *) die "версия должна выглядеть как r-72.3 или p-73.1, а не '$VER'" ;;
esac

# Префикс версии ОБЯЗАН совпадать с типом: r = reinstall, p = patch.
#
# Правило человеческое — код обновления смотрит только на поле type
# (lib/auto_update.sh: [ "$etype" = "reinstall" ]), поэтому расхождение ничего
# не ломает, но врёт всем, кто читает историю глазами: номер релиза перестаёт
# отвечать на вопрос «это быстрый патч или переустановка на три минуты».
# В истории такое расхождение случалось семь раз из 139 — то есть само по себе
# внимание его не ловит.
_pref=$(printf '%s' "$VER" | cut -c1)
case "${_pref}/${TYPE}" in
    r/reinstall|p/patch) ;;
    r/patch)     die "версия начинается на r-, а тип patch. Либо назовите p-${VER#r-}, либо ставьте reinstall" ;;
    p/reinstall) die "версия начинается на p-, а тип reinstall. Либо назовите r-${VER#p-}, либо ставьте patch" ;;
esac

command -v python3 >/dev/null 2>&1 || die "нужен python3"
git rev-parse --git-dir >/dev/null 2>&1 || die "не git-репозиторий"

# Незакоммиченное дерево — это уже не тот срез, который поедет людям: сумма
# посчитается по рабочей копии, а ссылка укажет на коммит без этих правок.
if [ -n "$(git status --porcelain -- ':!UPDATES.json' 2>/dev/null)" ]; then
    printf 'release: в дереве есть незакоммиченные правки:\n' >&2
    git status --short -- ':!UPDATES.json' | sed 's/^/  /' >&2
    die "закоммитьте их — релиз собирается из коммитов, а не из рабочей копии"
fi

CUR=$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
[ -n "$CUR" ] || die "не читается current из $MANIFEST"
[ "$CUR" != "$VER" ] || die "версия $VER уже текущая"

# --- CD-гейт: объявлять можно только то, что прошло CI ------------------------
#
# push в z2k-enhanced делает байты видимыми роутерам мгновенно (канал доставки —
# сама ветка), но ОБНОВЛЕНИЕ у флота триггерит только сдвиг "current". На этом
# и стоит деплой-гейт: релиз идёт двумя пушами.
#
#   1. push кода. current стоит на месте — флот обновы не видит. Карта
#      files_sha256 должна быть перегенерирована в этом же пуше (CI-гейт
#      дайджестов это проверяет). Хук попросит слово со СТАРОЙ версией —
#      манифест ещё на ней.
#   2. Зелёные CI и CDN-verify на этом коммите.
#   3. Снова release.sh — этот блок сверяет (а) что HEAD запушен и (б) что оба
#      workflow на нём зелёные, и только тогда собирает объявление. Его push
#      (слово с НОВОЙ версией) — и есть релиз для флота.
#
# До 2026-08-07 обновление предлагалось роутерам сразу после пуша, пока CI ещё
# бежал: окно, в котором флот получает код, не прошедший даже собственных
# проверок. Это окно закрывается здесь.
#
# Z2K_RELEASE_SKIP_CI_GATE=1 — аварийный обход на случай лежащего GitHub
# Actions (прецедент 2026-08-06: p-73 ушёл в окно сбоя, раны не создались
# вовсе). Обход осознанный и громкий, как и всё в этом процессе.
if [ "${Z2K_RELEASE_SKIP_CI_GATE:-0}" = "1" ]; then
    printf 'ВНИМАНИЕ: CD-гейт пропущен вручную (Z2K_RELEASE_SKIP_CI_GATE=1) — объявляем без вердикта CI\n'
else
    command -v gh >/dev/null 2>&1 || die "нужен gh для сверки CI (аварийный обход: Z2K_RELEASE_SKIP_CI_GATE=1)"
    HEAD_SHA=$(git rev-parse HEAD)
    git fetch -q origin z2k-enhanced 2>/dev/null || true
    REMOTE_SHA=$(git rev-parse origin/z2k-enhanced 2>/dev/null || printf '')
    if [ "$HEAD_SHA" != "$REMOTE_SHA" ]; then
        die "код ещё не запушен (HEAD != origin/z2k-enhanced).
         Порядок: 1) push кода — флот его не увидит, current не сдвинут
                  2) зелёный CI на нём
                  3) снова release.sh"
    fi
    printf 'CD-гейт: жду вердикта CI для %s ' "$(git rev-parse --short HEAD)"
    _deadline=$(( $(date +%s) + 1500 ))
    while :; do
        _runs=$(gh run list --commit "$HEAD_SHA" --json name,status,conclusion,event 2>/dev/null) \
            || die "gh run list не отвечает — сеть/авторизация? (аварийный обход: Z2K_RELEASE_SKIP_CI_GATE=1)"
        _verdict=$(printf '%s' "$_runs" | python3 -c '
import json, sys
runs = [r for r in json.load(sys.stdin)
        if r["event"] in ("push", "workflow_dispatch")
        and r["name"] in ("CI", "Release CDN (purge + verify)")]
names = {r["name"] for r in runs}
if len(names) < 2:
    print("waiting")           # раны ещё не создались (или сбой Actions)
elif any(r["status"] != "completed" for r in runs):
    print("running")
elif all(r["conclusion"] == "success" for r in runs):
    print("green")
else:
    print("red")')
        case "$_verdict" in
            green) printf 'зелёный\n'; break ;;
            red)   printf '\n'
                   die "CI на запушенном коде КРАСНЫЙ — чинить код, а не объявлять релиз (gh run list --commit $HEAD_SHA)" ;;
            *)     if [ "$(date +%s)" -ge "$_deadline" ]; then
                       printf '\n'
                       die "CI не дал вердикта за 25 минут. Если Actions лежит (как 2026-08-06) — Z2K_RELEASE_SKIP_CI_GATE=1, иначе gh run watch и снова release.sh"
                   fi
                   printf '.'; sleep 30 ;;
        esac
    done
fi

PREV_REF=$(grep '^[[:space:]]*{"v":' "$MANIFEST" | tail -1 \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().strip().rstrip(","))["ref"])')
case "$PREV_REF" in
    ''|PENDING|HEAD) die "у предыдущей записи ref='$PREV_REF' — сначала проставьте его на реальный коммит" ;;
esac
git cat-file -e "${PREV_REF}^{commit}" 2>/dev/null || die "предыдущий ref '$PREV_REF' не найден в истории git"

printf 'предыдущий релиз: %s (%s)\n' "$CUR" "$PREV_REF"

# --- Список файлов: из git, а не из головы -----------------------------------
#
# Заявляем то, что реально изменилось с предыдущего релиза И имеет цель на
# роутере. Файл без цели (vps-relay/, docs, планы) заявлять нечем и незачем:
# патч его никуда не положит.
Z2K_AU_SOURCE_ONLY=1 . ./lib/auto_update.sh 2>/dev/null

CHANGED=$(mktemp) || exit 1
trap 'rm -f "$CHANGED"' EXIT

git diff --name-only "$PREV_REF"..HEAD > "$CHANGED"

DELIVERABLE=""
SKIPPED=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue            # удалённые не заявляем
    [ "$f" = "$MANIFEST" ] && continue # добавим отдельно, он всегда меняется
    if [ -n "$(au_install_paths "$f" 2>/dev/null)" ]; then
        DELIVERABLE="$DELIVERABLE $f"
    else
        SKIPPED="$SKIPPED $f"
    fi
done < "$CHANGED"

[ -n "$DELIVERABLE" ] || die "с $PREV_REF не изменилось ни одного доставляемого файла — релизить нечего"

printf 'заявляем (%s):\n' "$(printf '%s' "$DELIVERABLE" | wc -w | tr -d ' ')"
for f in $DELIVERABLE; do printf '  %s\n' "$f"; done
if [ -n "$SKIPPED" ]; then
    printf 'не доставляются патчем, поэтому не заявлены (%s):\n' "$(printf '%s' "$SKIPPED" | wc -w | tr -d ' ')"
    for f in $SKIPPED; do printf '  %s\n' "$f"; done
fi

# Бинарник туннеля доставляется ТОЛЬКО реинсталлом: цель зависит от архитектуры
# роутера, и патч разложил бы чужую. Если он менялся, а тип patch — это молчаливо
# несостоявшаяся доставка, ровно та, из-за которой люди сидели на старом клиенте.
if git diff --name-only "$PREV_REF"..HEAD | grep -q '^mtproxy-client/builds/'; then
    [ "$TYPE" = "reinstall" ] || die "изменился бинарник туннеля — тип обязан быть reinstall, а не patch"
fi

# --- Несущий коммит: ref = уже существующий HEAD ------------------------------
#
# ref в записи релиза — это дифф-база для СЛЕДУЮЩЕГО релиза (роутер это поле не
# читает вовсе, проверено). Значит он должен указывать на коммит, чьё дерево =
# «что этот релиз доставил», и такой коммит УЖЕ есть: код закоммичен до запуска
# release.sh (см. RELEASING.md). Его хеш известен прямо сейчас.
#
# Отсюда — один коммит и одна подпись. Прежняя схема писала ref="PENDING",
# коммитила, потом ВТОРЫМ коммитом проставляла хеш этого же коммита в манифест —
# самоссылка, которую нельзя знать до коммита. Она и тянула за собой второй
# коммит, и ломала подпись (второй коммит правил уже подписанный файл). На
# выпуске r-75 это поймали пост-проверкой до пуша. Самоссылки больше нет:
# ref указывает на код, а не на сам себя.
REF=$(git rev-parse --short HEAD) || die "не читается HEAD"
git diff --quiet && git diff --cached --quiet \
    || die "дерево не чистое — сначала закоммитьте код, потом release.sh (см. RELEASING.md)"

# --- Запись в историю ---------------------------------------------------------
#
# Правка строго текстовая, по одной записи в строке: история парсится на
# роутерах awk'ом (au_history_entries_after), и пересериализация всего файла
# сломала бы обновление на каждом уже отгруженном роутере.
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
python3 - "$VER" "$TYPE" "$TS" "$DESC" "$DELIVERABLE" "$MANIFEST" "$REF" <<'PY'
import json, sys
ver, typ, ts, desc, deliverable, path, ref = sys.argv[1:8]
files = deliverable.split() + [path]

entry = {"v": ver, "type": typ, "ts": ts, "ref": ref,
         "desc": desc, "changed_files": files}

lines = open(path, encoding='utf-8').read().split('\n')

# Монотонный счётчик релизов. Он НЕ дублирует номер версии: номера дотнутые
# (p-74.2 после r-74.1), сравнивать их числом нельзя, а роутеру нужно ровно одно
# — «этот манифест новее того, что я уже видел». Без такого признака подписанный,
# но СТАРЫЙ манифест остаётся валидным вечно: подпись не устаревает сама по себе,
# и понижение версии подсовыванием вчерашнего файла подписью не ловится.
cur_seq = 0
for ln in lines:
    st = ln.strip()
    if st.startswith('"seq"'):
        try:
            cur_seq = int(st.split(':', 1)[1].strip().rstrip(','))
        except ValueError:
            cur_seq = 0
        break
new_seq = cur_seq + 1

out = []
seen_seq = False
for ln in lines:
    st = ln.strip()
    if st.startswith('"current"'):
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append('%s"current": "%s",' % (indent, ver))
    elif st.startswith('"seq"'):
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append('%s"seq": %d,' % (indent, new_seq))
        seen_seq = True
    else:
        out.append(ln)

# Манифест до появления счётчика — дописываем строку следом за branch.
#
# Именно за branch, а НЕ за current: gen_file_hashes вставляет блок files_sha256
# сразу после "current", и строка, поставленная туда же, оказывается вытеснена
# под карту сумм. Порядок ключей у нас несущий — роутеры разбирают манифест
# построчно, — и тест на него не зря стоит.
if not seen_seq:
    for i, ln in enumerate(out):
        if ln.strip().startswith('"branch"'):
            indent = ln[:len(ln) - len(ln.lstrip())]
            out.insert(i + 1, '%s"seq": %d,' % (indent, new_seq))
            break

last = max(i for i, ln in enumerate(out) if ln.strip().startswith('{"v":'))
indent = out[last][:len(out[last]) - len(out[last].lstrip())]
if not out[last].rstrip().endswith(','):
    out[last] = out[last].rstrip() + ','
out.insert(last + 1, indent + json.dumps(entry, ensure_ascii=False))
open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY

# Карта сумм + кеш-бастер панели. Он правит index.html и САМ дописывает его в
# changed_files — заявить его заранее человек не может физически, файл на тот
# момент ещё не изменён.
sh scripts/gen_file_hashes.sh

python3 -c "import json; json.load(open('$MANIFEST'))" || die "после правки $MANIFEST перестал быть валидным JSON"

# --- Подпись ------------------------------------------------------------------
#
# ПОСЛЕДНИМ шагом, когда манифест окончателен: ref проставлен, карта сумм
# пересобрана. Ровно эти байты уедут на роутеры и ровно их покрывает подпись.
#
# ГДЕ КЛЮЧ. Только на машине владельца, вне репозитория. Вариант «ключ в GitHub
# Actions secrets» отвергнут осознанно: модель угроз здесь — «захватили
# репозиторий», а такой ключ захватывается вместе с ним. CI имеет право лишь
# ПРОВЕРЯТЬ.
#
# macOS отдаёт LibreSSL, который Ed25519 не умеет вовсе, поэтому ищем настоящий
# OpenSSL, а не первый попавшийся в PATH.
Z2K_SIGNING_KEY="${Z2K_SIGNING_KEY:-$HOME/.z2k-signing/z2k-update.key}"

_find_openssl() {
    for _c in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
              /usr/local/bin/openssl "$(command -v openssl 2>/dev/null)"; do
        [ -x "$_c" ] || continue
        "$_c" genpkey -algorithm ed25519 -out /dev/null >/dev/null 2>&1 || continue
        printf '%s' "$_c"
        return 0
    done
    return 1
}

if [ -f "$Z2K_SIGNING_KEY" ]; then
    OSSL=$(_find_openssl) || die "не нашёл OpenSSL с поддержкой Ed25519 (у macOS системный — LibreSSL; поставьте: brew install openssl)"
    "$OSSL" pkeyutl -sign -rawin -inkey "$Z2K_SIGNING_KEY" \
        -in "$MANIFEST" -out "${MANIFEST}.sig" \
        || die "подписать $MANIFEST не удалось"

    # Проверяем СВОЙ результат опубликованным публичным ключом. Подпись, не
    # сходящаяся с тем ключом, что лежит у людей, хуже отсутствия подписи:
    # каждый роутер, уже видевший валидную, отвергнет релиз целиком.
    "$OSSL" pkeyutl -verify -rawin -pubin -inkey files/etc/z2k-update-pub.pem \
        -in "$MANIFEST" -sigfile "${MANIFEST}.sig" >/dev/null 2>&1 \
        || die "подпись не проверяется публичным ключом из files/etc/z2k-update-pub.pem — релиз остановлен"

    printf 'манифест подписан (seq=%s), подпись сверена с опубликованным ключом\n' \
        "$(sed -n 's/.*"seq"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$MANIFEST" | head -1)"
else
    # Без ключа релиз собрать МОЖНО — иначе выпустить не смог бы никто, кроме
    # владельца. Но молчать нельзя: неподписанный релиз отвергнет каждый роутер,
    # который уже принимал подписанные.
    printf 'ВНИМАНИЕ: ключ подписи не найден (%s) — манифест уйдёт БЕЗ подписи.\n' "$Z2K_SIGNING_KEY" >&2
    printf 'Роутеры, уже принимавшие подписанные манифесты, этот релиз ОТВЕРГНУТ.\n' >&2
    rm -f "${MANIFEST}.sig"
fi

# --- Один коммит --------------------------------------------------------------
#
# Всё окончательно: history-запись с настоящим ref, карта сумм, подпись. Второго
# коммита нет по построению — ref уже указывает на код, а не на этот коммит.
git add "$MANIFEST" "${MANIFEST}.sig" webpanel/www/index.html 2>/dev/null || git add "$MANIFEST"
git commit -q -m "release: $VER ($TYPE) — $DESC"

printf '\nсобрано: %s (%s), несущий коммит %s, релизный коммит %s\n' \
    "$VER" "$TYPE" "$REF" "$(git rev-parse --short HEAD)"
printf 'проверяю...\n'
if sh tests/run_all.sh >/dev/null 2>&1; then
    printf 'тесты зелёные\n'
else
    die "тесты упали — прогоните sh tests/run_all.sh и посмотрите"
fi
printf 'push делается ОТДЕЛЬНО и только с одобрения.\n'
