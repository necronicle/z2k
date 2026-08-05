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
# Использование:
#   sh scripts/release.sh <версия> <тип> <описание>
#   sh scripts/release.sh r-72.3 patch "Описание для человека, 1-3 предложения."
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

# --- Запись в историю ---------------------------------------------------------
#
# Правка строго текстовая, по одной записи в строке: история парсится на
# роутерах awk'ом (au_history_entries_after), и пересериализация всего файла
# сломала бы обновление на каждом уже отгруженном роутере.
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
python3 - "$VER" "$TYPE" "$TS" "$DESC" "$DELIVERABLE" "$MANIFEST" <<'PY'
import json, sys
ver, typ, ts, desc, deliverable, path = sys.argv[1:7]
files = deliverable.split() + [path]

entry = {"v": ver, "type": typ, "ts": ts, "ref": "PENDING",
         "desc": desc, "changed_files": files}

lines = open(path, encoding='utf-8').read().split('\n')
out = []
for ln in lines:
    if ln.strip().startswith('"current"'):
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append('%s"current": "%s",' % (indent, ver))
    else:
        out.append(ln)

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

# --- Коммиты ------------------------------------------------------------------
#
# Ссылка на несущий коммит проставляется ВТОРЫМ коммитом, и иначе не выйдет:
# хеш известен только после того, как коммит создан, а поправить его через amend
# нельзя — amend меняет хеш, и ссылка снова указывает в никуда.
git add "$MANIFEST" webpanel/www/index.html 2>/dev/null || true
git commit -q -m "release: $VER ($TYPE)

$DESC"

REL=$(git rev-parse --short HEAD)
python3 - "$REL" "$VER" "$MANIFEST" <<'PY'
import json, sys
ref, ver, path = sys.argv[1:4]
lines = open(path, encoding='utf-8').read().split('\n')
for i, ln in enumerate(lines):
    s = ln.strip().rstrip(',')
    if s.startswith('{"v":') and ('"%s"' % ver) in s:
        d = json.loads(s); d['ref'] = ref
        indent = ln[:len(ln) - len(ln.lstrip())]
        tail = ',' if ln.rstrip().endswith(',') else ''
        lines[i] = indent + json.dumps(d, ensure_ascii=False) + tail
        break
else:
    raise SystemExit('не нашёл запись %s' % ver)
open(path, 'w', encoding='utf-8').write('\n'.join(lines))
PY
sh scripts/gen_file_hashes.sh >/dev/null
git add "$MANIFEST"
git commit -q -m "chore(manifest): указать ref $VER на несущий коммит"

printf '\nсобрано: %s (%s), несущий коммит %s\n' "$VER" "$TYPE" "$REL"
printf 'проверяю...\n'
if sh tests/run_all.sh >/dev/null 2>&1; then
    printf 'тесты зелёные\n'
else
    die "тесты упали — прогоните sh tests/run_all.sh и посмотрите"
fi
printf 'push делается ОТДЕЛЬНО и только с одобрения.\n'
