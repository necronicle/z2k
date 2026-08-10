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
#   1. работаете и коммитите в z2k-staging (люди этой ветки не видят)
#   2. sh scripts/release.sh <версия> <тип> <описание>
#      sh scripts/release.sh r-72.3 patch "Описание для человека, 1-3 предложения."
#   3. push в z2k-staging — всё, дальше ждать нечего
#
# Публикацию делает робот: .github/workflows/publish.yml дожидается зелёного CI
# на этом коммите и переводит на него z2k-enhanced. Красный CI — значит ветка
# не сдвинулась и люди ничего не увидели. Ждать вердикта руками больше не надо.
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

# Две роли, и их нельзя путать. RELEASE_BRANCH — то, что видят люди: роутеры
# тянут с её верхушки всё, включая z2k.sh для переустановки. STAGING_BRANCH —
# где работают. Человек пишет только во вторую.
RELEASE_BRANCH="${RELEASE_BRANCH:-z2k-enhanced}"
STAGING_BRANCH="${STAGING_BRANCH:-z2k-staging}"

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

# --- Публикация — не наше дело --------------------------------------------
#
# КАК ЭТО РАБОТАЕТ ТЕПЕРЬ. Ветка `z2k-enhanced` — это и есть канал доставки:
# роутеры тянут с её верхушки и манифест, и файлы патча, и `z2k.sh` для
# переустановки, а однострочник из README ставит оттуда же. Поэтому всё, что
# туда попало, люди получают немедленно — независимо от того, сдвинут `current`
# или нет.
#
# Отсюда правило, которое здесь и закрепляется: ЧЕЛОВЕК В РЕЛИЗНУЮ ВЕТКУ НЕ
# ПИШЕТ. Работа идёт в `z2k-staging`, релиз собирается там же, а верхушку
# `z2k-enhanced` двигает робот (.github/workflows/publish.yml) — и только после
# зелёного CI на ровно этом коммите. Ключа подписи у робота нет и не будет: он
# переносит ссылку на уже подписанный коммит, а не собирает релиз.
#
# ЧТО ЭТО ЗАМЕНИЛО. До 2026-08-09 гейт жил здесь: скрипт сам ждал `gh run` до
# 25 минут, а на случай лежащего Actions существовал обход
# Z2K_RELEASE_SKIP_CI_GATE=1. Гейт, который можно переждать или обойти
# переменной, при одном разработчике рано или поздно обходится. Теперь ждать
# нечего и обходить нечего: непрошедший коммит просто не доезжает до людей,
# потому что двигать ветку умеет только робот.
#
# Индустрия делает ровно так: публикация — это правка маленького указателя, а
# не появление кода. MikroTik двигает строку в NEWESTa7.stable, OpenWrt — поле
# stable_version в .versions.json, Home Assistant — stable.json. Сборка лежит
# доступной задолго до этого и никого не трогает. У нас роль указателя играет
# сама ссылка ветки.
_branch=$(git rev-parse --abbrev-ref HEAD)
case "$_branch" in
    "$RELEASE_BRANCH")
        die "релиз собирается на $STAGING_BRANCH, а не в релизной ветке.
         В $RELEASE_BRANCH пишет только робот — иначе код попадёт людям до тестов.
         git checkout $STAGING_BRANCH" ;;
    "$STAGING_BRANCH") ;;
    *)  printf 'release: вы на ветке %s, а не на %s — продолжаю, но публиковать будет некому\n' \
            "$_branch" "$STAGING_BRANCH" >&2 ;;
esac

PREV_REF=$(grep '^[[:space:]]*{"v":' "$MANIFEST" | tail -1 \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().strip().rstrip(","))["ref"])')
case "$PREV_REF" in
    ''|PENDING|HEAD) die "у предыдущей записи ref='$PREV_REF' — сначала проставьте его на реальный коммит" ;;
esac
git cat-file -e "${PREV_REF}^{commit}" 2>/dev/null || die "предыдущий ref '$PREV_REF' не найден в истории git"

printf 'предыдущий релиз: %s (%s)\n' "$CUR" "$PREV_REF"

# --- Предыдущий релиз обязан быть опубликован ---------------------------------
#
# Иначе получается liveness-дыра. Публикацию запускает workflow_run по CI на
# staging, а CI разных коммитов идут ПАРАЛЛЕЛЬНО (каждый в своей concurrency-
# группе по SHA — см. .github/workflows/ci.yml). Если завести релиз C, пока A
# ещё не опубликован, CI(C) может закончиться первым, и gate увидит в манифесте
# СРАЗУ ДВЕ новые записи history вместо одной. Он на это честно ответит красным
# — semantic-гейт требует ровно одну — но сам собой уже не повторится, когда A
# наконец опубликуется. Подмены тут нет и быть не может, всё fail-closed; цена
# — застрявший релиз и ручной разбор.
#
# Дешевле не пустить второй релиз в полёт, чем разбирать заклинивший.
git fetch -q origin "$RELEASE_BRANCH" 2>/dev/null \
    || die "не удалось получить origin/$RELEASE_BRANCH — не с чем сверить, опубликован ли предыдущий релиз"
PUBLISHED=$(git show "origin/${RELEASE_BRANCH}:UPDATES.json" 2>/dev/null \
    | sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$PUBLISHED" ] || die "не читается current из origin/$RELEASE_BRANCH:UPDATES.json"
if [ "$PUBLISHED" != "$CUR" ]; then
    die "предыдущий релиз $CUR ещё НЕ опубликован (в $RELEASE_BRANCH сейчас $PUBLISHED).
         Второй релиз в этом состоянии заклинит публикацию: gate увидит две новые
         записи history разом, честно ответит красным и сам не повторится.
         Дождитесь, пока publish.yml переведёт $RELEASE_BRANCH на $CUR."
fi

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

# ЕДИНАЯ политика path -> patch/reinstall/ignore живёт в одном месте:
# au_reinstall_required() (lib/auto_update.sh, рядом с au_install_paths, тем
# же case-статементом). Раньше каждый такой путь получал свой отдельный гейт
# по мере обнаружения — сперва только mtproxy-client, потом отдельно
# z2k-detect/z2k-verify (общий regex по builds/), потом отдельно
# lib/config_official.sh и lib/strategies.sh. Ровно так в дыру провалился
# webpanel/lighttpd.conf: рядом с ним лежал комментарий "if it actually
# changes, ship as reinstall", который никто и ничто не читало — очередной
# частный случай, до которого просто не дошла очередь. Список путей теперь
# один, живёт в au_reinstall_required(), и покрывает всё сразу: любой бинарник
# (au_install_paths для */builds/* цели не знает — патч не разложит чужую
# арку, файл молча выпадет из changed_files, а версия уедет вперёд), генераторы
# конфига/стратегий и шаблон lighttpd.conf.
_reinstall_changed=$(git diff --name-only "$PREV_REF"..HEAD | while IFS= read -r f; do
    if [ -n "$(au_reinstall_required "$f")" ]; then
        printf '%s\n' "$f"
    fi
done; true)
if [ -n "$_reinstall_changed" ] && [ "$TYPE" != "reinstall" ]; then
    die "изменились файлы, которые патч доставить не может ($(printf '%s' "$_reinstall_changed" | tr '\n' ' ')) —
     тип обязан быть reinstall: их эффект применяется либо на архитектуру роутера,
     либо один раз при установке, а патч тут кладёт файл, который никто заново не перечитает"
fi

# --- mtproxy-client: сверка с РЕАЛЬНЫМ секретом ------------------------------
#
# .github/workflows/ci.yml проверяет байт-в-байт все бинарники из build-matrix.tsv
# КРОМЕ mtproxy-client: в него на сборке вшивается Z2K_TUNNEL_SECRET через -X, и
# без настоящего секрета CI не может пересобрать то же самое (там же есть
# отдельная проверка, что сборка хотя бы детерминирована — с тестовым секретом).
# Настоящий секрет есть только здесь, на машине владельца. Значит именно тут —
# единственное место во всей цепочке, где можно закрыть тот же класс аварии,
# что уже случался с rt-proxy: полностью пересобранный, задеплоенный и
# провалидированный на роутере бинарник тихо не попадает в builds/, потому что
# кто-то забыл его туда скопировать после `make all`.
#
# ТРИГГЕР — НЕ только builds/. Правка mtproxy-client/main.go (или go.mod,
# go.sum, Makefile), после которой забыли прогнать `make all`, оставляет
# builds/ БЕЗ единого изменения в git diff — и гейт, завязанный только на
# "/builds/ поменялся", такую правку не увидел бы вообще: source разошёлся с
# уже отгруженным бинарником, а release.sh молча решил бы, что сверять нечего.
# Сверяем при ЛЮБОМ изменении внутри mtproxy-client/ (исходники, builds/,
# go.mod/go.sum, Makefile) и при правке build-matrix.tsv (могла поменяться
# цель сборки для модуля). Пересборка с тем же исходником и тем же секретом
# либо совпадёт с builds/ (ничего по сути не изменилось — например, правка
# только комментария), либо разойдётся — и это ровно тот «забыли пересобрать»
# случай, который и нужно ловить.
# || true: grep как ПОСЛЕДНЯЯ команда пайпа внутри $(...) — её код возврата
# становится кодом возврата присваивания. "Нет совпадений" (обычный случай,
# когда mtproxy-client никто не трогал) — это exit 1 у grep, и под set -e
# такое присваивание молча валит весь скрипт без единого сообщения die. Тот
# же класс бага, что уже ловился на _reinstall_changed чуть выше — там
# ловушка была в while-цикле, здесь — в голом grep на конце пайпа.
_mtproxy_changed=$(git diff --name-only "$PREV_REF"..HEAD \
    | grep -E '^mtproxy-client/|^build-matrix\.tsv$' || true)
if [ -n "$_mtproxy_changed" ]; then
    [ -n "${Z2K_TUNNEL_SECRET:-}" ] || die "mtproxy-client ($(printf '%s' "$_mtproxy_changed" | tr '\n' ' ')) изменился, но Z2K_TUNNEL_SECRET не задан —
     нечем пересобрать и свериться с тем, что реально лежит в builds/.
     Запустите: Z2K_TUNNEL_SECRET=<hex> sh scripts/release.sh ... (тот же секрет, что в make all)"
    # НЕ произвольный `go` из PATH. Смысл всей сверки — доказать, что builds/
    # получается из ЭТОГО исходника, а прод (ci.yml, Makefile) собирается
    # СТРОГО go1.25.12 (golang/go#77730 на MIPS для более новых 1.26.x — см.
    # комментарий в ci.yml). Другой тулчейн на машине владельца даёт другие
    # байты НЕ ПОТОМУ ЧТО ЧТО-ТО СЛОМАНО, а просто потому что это другой
    # компилятор — и тогда сверка либо ложно падает (запрещает валидный
    # релиз), либо, что хуже, случайно совпадает и создаёт уверенность на
    # пустом месте. Версия — из ci.yml, единственного источника правды,
    # чтобы не завести ЕЩЁ одну копию "1.25.12", которая когда-нибудь
    # разойдётся с двумя уже существующими (Makefile, ci.yml).
    _go_ver=$(sed -n 's/^[[:space:]]*GO_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' .github/workflows/ci.yml | head -1)
    [ -n "$_go_ver" ] || die "не нашёл GO_VERSION в .github/workflows/ci.yml — нечем определить, каким тулчейном сверяться с mtproxy-client"
    _go_bin="$HOME/go/bin/go$_go_ver"
    [ -x "$_go_bin" ] || die "mtproxy-client изменился, нужен ИМЕННО go$_go_ver (прод-тулчейн) для сверки — $_go_bin не найден или не исполняем.
     Поставьте: https://go.dev/dl/go${_go_ver}.$(uname -s | tr 'A-Z' 'a-z')-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').tar.gz в \$HOME/go/bin/go$_go_ver"
    _go_actual=$("$_go_bin" version 2>/dev/null | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    [ "$_go_actual" = "go$_go_ver" ] || die "release: $_go_bin сообщает версию '$_go_actual', а нужен ровно go$_go_ver — файл переименован или подменён"
    _mt_rc=0
    _mt_tmp=$(mktemp -d) || die "mktemp для сверки mtproxy-client"
    while IFS="$(printf '\t')" read -r mod pkg bdir prefix goarch sfx extra; do
        case "$mod" in ''|\#*) continue ;; esac
        [ "$mod" = "mtproxy-client" ] || continue
        [ "$extra" = "-" ] && extra=""
        want="$bdir/$prefix-linux-$sfx"
        [ -f "$want" ] || { printf 'release: нет отгружаемого %s\n' "$want" >&2; _mt_rc=1; continue; }
        # shellcheck disable=SC2086 # $extra — набор присваиваний окружения
        if ! ( cd mtproxy-client && env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" $extra \
                 "$_go_bin" build -trimpath -buildvcs=false \
                 -ldflags="-s -w -X main.defaultTunnelSecret=$Z2K_TUNNEL_SECRET" \
                 -o "$_mt_tmp/rebuilt" "$pkg" ); then
            printf 'release: mtproxy-client/%s не собирается\n' "$goarch" >&2; _mt_rc=1; continue
        fi
        _a=$(shasum -a 256 "$_mt_tmp/rebuilt" 2>/dev/null | cut -d' ' -f1)
        [ -n "$_a" ] || _a=$(sha256sum "$_mt_tmp/rebuilt" | cut -d' ' -f1)
        _b=$(shasum -a 256 "$want" 2>/dev/null | cut -d' ' -f1)
        [ -n "$_b" ] || _b=$(sha256sum "$want" | cut -d' ' -f1)
        if [ "$_a" = "$_b" ]; then
            printf '  ok      %s (реальный секрет, байт-в-байт)\n' "$want"
        else
            printf 'release: %s НЕ собирается из этого исходника этим секретом (пересборка %s, в репо %s)\n' \
                "$want" "$_a" "$_b" >&2
            _mt_rc=1
        fi
    done < build-matrix.tsv
    rm -rf "$_mt_tmp"
    [ "$_mt_rc" = "0" ] || die "mtproxy-client в builds/ не совпадает с пересборкой из этого исходника (реальный секрет) —
     пересоберите: cd mtproxy-client && make all Z2K_TUNNEL_SECRET=... — и закоммитьте builds/"
    printf 'mtproxy-client: все изменённые архитектуры совпадают с пересборкой (реальный секрет)\n'
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
# ref — ЭТО ИМЯ ТЕГА, а не хеш коммита.
#
# Роутер читает его и тянет файлы по неизменяемой ссылке, а не с верхушки
# ветки: ветка движется, и обновление, начатое до её движения, доскачивало бы
# файлы уже от следующего релиза — суммы не сошлись бы, обновление отвалилось.
#
# Имя тега известно ЗАРАНЕЕ (это номер версии), поэтому самоссылки не возникает.
# Хеш релизного коммита сюда положить нельзя по построению: он неизвестен до
# коммита — ровно та ловушка «PENDING», которая ломала подпись на r-75.
#
# И это же чинит старую неточность: прежний ref указывал на несущий коммит, чьё
# дерево БЕЗ кеш-бастера панели, то есть «не на то, что доставили».
REF="$VER"
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
    # Раньше здесь был warn-and-continue: без ключа релиз собирался БЕЗ подписи,
    # и человек узнавал о последствиях (роутер с подписанными манифестами в
    # истории отвергнет неподписанный — StatusChat "z2k-verify" гарантия
    # ломается молча) уже постфактум, по факту жалоб. Ключ либо есть на машине
    # владельца, либо релиз собирать нечем — это не деградация, а требование:
    # publish.yml всё равно откажет неподписанному тегу на шаге gate (см.
    # "у кандидата нет UPDATES.json.sig"), так что смысла продолжать без ключа
    # нет — только время до того же самого отказа, но уже после коммита и тега.
    die "ключ подписи не найден ($Z2K_SIGNING_KEY) — релиз без подписи publish.yml всё равно отвергнет.
     Положите ключ или укажите Z2K_SIGNING_KEY=путь"
fi

# --- Один коммит --------------------------------------------------------------
#
# Всё окончательно: history-запись с настоящим ref, карта сумм, подпись. Второго
# коммита нет по построению — ref уже указывает на код, а не на этот коммит.
git add "$MANIFEST" "${MANIFEST}.sig" webpanel/www/index.html 2>/dev/null || git add "$MANIFEST"
git commit -q -m "release: $VER ($TYPE) — $DESC"

# --- Подписанный тег на релизный коммит ----------------------------------------
#
# Тег — неизменяемое имя релиза И адрес, по которому роутер скачивает файлы:
# `ref` в манифесте равен имени тега. Ветка движется, тег — нет.
#
# Подписывается ТЕМ ЖЕ ключом, что и манифест (scripts/tag_signing_key.sh
# переупаковывает его в формат, понятный git). Второго ключа не заводим.
git rev-parse -q --verify "refs/tags/$VER" >/dev/null 2>&1 \
    && die "тег $VER уже существует — номер версии переиспользовать нельзя"

_tagkey=$(sh scripts/tag_signing_key.sh 2>/dev/null) || _tagkey=""
if [ -n "$_tagkey" ]; then
    git -c gpg.format=ssh -c user.signingkey="$_tagkey" \
        tag -s "$VER" -m "z2k $VER ($TYPE)" \
        || { rm -f "$_tagkey" "${_tagkey}.pub"; die "не удалось подписать тег $VER"; }
    # Сверяем СВОЙ результат тем же ключом и по КОДУ ВОЗВРАТА: git печатает
    # «Good signature» и для чужого ключа, сообщая о несовпадении отдельной
    # строкой. Тег, который отвергнет публикация, лучше поймать здесь.
    printf 'z2k-release %s\n' "$(cut -d' ' -f1-2 < "${_tagkey}.pub")" > "${_tagkey}.allowed"
    if ! git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="${_tagkey}.allowed" \
           verify-tag "$VER" >/dev/null 2>&1; then
        rm -f "$_tagkey" "${_tagkey}.pub" "${_tagkey}.allowed"
        git tag -d "$VER" >/dev/null 2>&1
        die "подпись тега $VER не проверяется собственным ключом — релиз остановлен"
    fi
    rm -f "$_tagkey" "${_tagkey}.pub" "${_tagkey}.allowed"
    printf 'тег %s подписан и проверен\n' "$VER"
else
    # Манифест выше уже потребовал ключ и умер бы, не найдя его — значит, если
    # мы здесь и tag_signing_key.sh всё равно ничего не отдал, дело не в
    # отсутствии ключа, а во внутреннем сбое переупаковки (несовпадение с
    # опубликованным pub.pem, битый ssh-keygen и т.п. — см. вывод самого
    # tag_signing_key.sh выше). Продолжать неподписанным тегом хуже, чем
    # остановиться: publish.yml всё равно его отвергнет на шаге gate, но узнает
    # об этом уже CI постфактум, а коммит и запись в UPDATES.json к тому моменту
    # уже сделаны.
    git tag -d "$VER" >/dev/null 2>&1
    die "не удалось подписать тег $VER (ключ для манифеста нашёлся, для тега — нет).
     Коммит $(git rev-parse --short HEAD) уже создан — почините ключ, затем повторите тег вручную или откатите коммит."
fi

printf '\nсобрано: %s (%s), релизный коммит %s, тег %s\n' \
    "$VER" "$TYPE" "$(git rev-parse --short HEAD)" "$VER"
printf 'проверяю...\n'
if sh tests/run_all.sh >/dev/null 2>&1; then
    printf 'тесты зелёные\n'
else
    die "тесты упали — прогоните sh tests/run_all.sh и посмотрите"
fi
printf 'push делается ОТДЕЛЬНО и только с одобрения:\n'
# --atomic: одна транзакция на обе ссылки. Раньше это были два push подряд —
# между ними реальное окно, где на origin уже есть ветка с новым коммитом
# (и то, что её видит staging CI), а тега ещё нет (или наоборот, если первый
# push оборвался по сети). publish.yml тогда либо не найдёт тег для current
# из манифеста ("нет тега $NEW_CUR"), либо (если прервался push тега после
# успешного push ветки) человек решит, что раз ветка ушла — то и всё ушло, и
# полезет разбираться руками. Один push с --atomic либо доставляет и ветку, и
# тег вместе, либо не доставляет ничего — оба сообщения об ошибке от git
# в этом случае одинаково безопасны: ничего на origin не изменилось.
printf '  git push --atomic origin %s %s\n' "$STAGING_BRANCH" "$VER"
printf 'дальше сам: зелёный CI → робот сверит тег и переведёт %s → флот увидит %s\n' \
    "$RELEASE_BRANCH" "$VER"
