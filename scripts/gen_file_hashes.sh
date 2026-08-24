#!/bin/sh
# scripts/gen_file_hashes.sh — regenerate the "files_sha256" map in UPDATES.json.
#
# Every file z2k installs is fetched over a chain of mirrors we do not control:
# jsdelivr and gh-proxy terminate TLS themselves, and any hop may answer 304 from
# a cache. Without a digest to check against, a mirror that is merely STALE is
# indistinguishable from a fresh one — the router keeps an old file while the
# version tag moves forward, silently, with no error in any log. That is not a
# hypothetical: issue #26 pinned a user to a revision from two days earlier
# across five consecutive releases.
#
# So UPDATES.json — which the updater must already fetch fresh in order to
# decide anything at all — carries the expected digest of every deliverable
# file. One trust root, not two.
#
# Run from the repo root. Regenerates in place; CI fails if the result differs
# from what is committed, so the map cannot drift away from the tree.
#
# The deliverable set is not hardcoded: it is whatever z2k_install_paths() maps
# to an install target, so a newly shipped file is covered the moment it becomes
# deliverable.
#
# EDITING IS SURGICAL, AND MUST STAY THAT WAY. au_history_entries_after() parses
# history with awk, one ENTRY PER LINE (`/^[[:space:]]*\{[[:space:]]*"v"/ {...
# print $0 }`). Re-serialising this file with a JSON pretty-printer would split
# every entry across many lines and break the updater on every router that has
# already shipped. So we only ever delete and re-insert our own block and leave
# every other byte exactly where it was.

set -e

# Pin collation. Without this the map is ordered by the AMBIENT locale, and
# macOS (UTF-8, punctuation-insensitive) disagrees with a Linux CI runner about
# where "files/lists/extra-domains.txt" sits relative to "extra_strats/". Same
# digests, different line order — which reads as drift and fails the CI gate on
# a tree that is perfectly in sync. Deterministic output is the whole point of a
# file whose job is to be compared byte-for-byte.
LC_ALL=C
export LC_ALL

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MANIFEST=UPDATES.json
[ -f "$MANIFEST" ] || { echo "UPDATES.json не найден в $ROOT" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
    _sha() { sha256sum "$1" | awk '{print $1}'; }
    _sha_stdin() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    _sha() { shasum -a 256 "$1" | awk '{print $1}'; }
    _sha_stdin() { shasum -a 256 | awk '{print $1}'; }
else
    echo "нужен sha256sum или shasum" >&2; exit 1
fi

# Deliverable = z2k_install_paths() gives it a destination on the router.
. ./lib/release_map.sh

BLOCK=$(mktemp) || exit 1
MAPBLOCK=$(mktemp) || exit 1
OUT=$(mktemp) || exit 1
trap 'rm -f "$BLOCK" "$MAPBLOCK" "$OUT"' EXIT

# Pin the panel's cache-buster to the release BEFORE hashing, or the digest we
# publish for index.html is the one from before the rewrite — the map then needs
# a SECOND run to converge, and a release cut after a single run ships a digest
# no router can ever match (fail-closed for everyone).
#
# index.html loads its assets as `app.js?v=<tag>`. The browser caches by URL, so
# that suffix is the only thing that makes a browser pick up a new panel. It was
# a hand-written literal and sat at `p39` for twenty-eight releases: the panel
# changed, the URL did not, and anyone whose browser caches got the old script
# after every update. It is derived from "current" now, so it cannot drift again.
_cur=$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
if [ -n "$_cur" ] && [ -f webpanel/www/index.html ]; then
    _idx_before=$(_sha webpanel/www/index.html)
    sed "s/?v=[A-Za-z0-9._-]*\"/?v=${_cur}\"/g" webpanel/www/index.html > "$OUT" \
        && cat "$OUT" > webpanel/www/index.html
    printf 'кеш-бастер панели: ?v=%s\n' "$_cur"

    # Если кеш-бастер реально сдвинулся — объявить index.html в changed_files
    # последней записи истории САМИ.
    #
    # Это чинит грабли, на которые наступали трижды. Порядок работы такой: список
    # файлов релиза пишется руками, ПОТОМ запускается этот скрипт — и он же
    # правит index.html. То есть на момент составления списка файл ещё не изменён,
    # и объявить его человек физически не может, а гейт полноты
    # (tests/test_release_manifest_complete.sh) при ref=PENDING пропускает
    # проверку и молчит. Ловилось каждый раз вручную и когда-нибудь не поймалось
    # бы: панель у людей осталась бы со старым кешем при новой версии.
    #
    # Объявляет тот, кто изменил. Правка строго текстовая: история парсится на
    # роутерах awk'ом по одной записи в строке, пересериализация сломала бы её.
    # Сравниваем с ЗАКОММИЧЕННЫМ файлом, а не с состоянием до этого прогона.
    # Разница принципиальная: генератор запускают по нескольку раз за релиз, и
    # начиная со второго раза кеш-бастер уже правильный — «до» и «после»
    # совпадают, блок не срабатывает, а файл при этом изменён относительно
    # коммита и объявить его всё равно надо. Ровно на этом объявление и терялось.
    _idx_after=$(_sha webpanel/www/index.html)
    _idx_head=""
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
        _idx_head=$(git show HEAD:webpanel/www/index.html 2>/dev/null | _sha_stdin)
    fi
    [ -n "$_idx_head" ] && _idx_before="$_idx_head"
    if [ "$_idx_before" != "$_idx_after" ]; then
        if awk '/^\{"v":/ {last=$0} END {exit (last ~ /"webpanel\/www\/index\.html"/) ? 0 : 1}' "$MANIFEST"; then
            :   # уже объявлен — ничего не делаем
        else
            _last_line=$(grep -n '^{"v":' "$MANIFEST" | tail -1 | cut -d: -f1)
            if [ -n "$_last_line" ]; then
                # Пробуем оба написания: запись могли сериализовать и компактно,
                # без пробела после двоеточия.
                sed -i.bak "${_last_line}s|\"changed_files\": \[|\"changed_files\": [\"webpanel/www/index.html\", |" "$MANIFEST"
                sed -i.bak2 "${_last_line}s|\"changed_files\":\[|\"changed_files\":[\"webpanel/www/index.html\",|" "$MANIFEST"
                rm -f "${MANIFEST}.bak" "${MANIFEST}.bak2"
            fi
            # ПРОВЕРЯЕМ, а не рапортуем. Раньше здесь печаталось «добавлен» сразу
            # после sed, не глядя на результат: sed искал только написание с
            # пробелом, на компактной записи молча не срабатывал, и человек читал
            # сообщение об успехе при неизменённом файле. Тихий отказ в этом месте
            # стоит ровно того, ради чего весь блок и написан, — панель уедет
            # людям со старым кешем.
            if awk '/^\{"v":/ {last=$0} END {exit (last ~ /"webpanel\/www\/index\.html"/) ? 0 : 1}' "$MANIFEST"; then
                printf 'в changed_files добавлен webpanel/www/index.html (его изменил кеш-бастер)\n'
            else
                printf 'ОШИБКА: index.html изменён кеш-бастером, но объявить его в changed_files не удалось.\n' >&2
                printf '        Впишите "webpanel/www/index.html" в changed_files последней записи вручную.\n' >&2
                exit 1
            fi
        fi
    fi
fi

# Файлы, которые НЕ доставляются патчем, но всё равно должны иметь контрольную
# сумму. Пример и причина — бинарники: install.sh качает их напрямую с зеркал
# ("${GITHUB_RAW}/mtproxy-client/builds/..."), а проверял до сих пор эвристиками
# «ELF, больше 500 КБ, --help не падает». Это ловит обрыв закачки и чужую арку,
# но НЕ ловит протухший ответ зеркала — ровно тот отказ, ради которого карта сумм
# и заводилась (issue #26).
#
# Целью установки их делать нельзя: цель зависит от архитектуры роутера, и патч
# начал бы раскладывать arm64-бинарник на mipsel. Поэтому они попадают в карту,
# но z2k_install_paths для них по-прежнему пуст — доставка остаётся за reinstall,
# а z2k_fetch получает по ним sha и сверяет (см. _z2k_manifest_sha в z2k.sh).
_verify_only() {
    case "$1" in
        mtproxy-client/builds/*|z2k-warpd/builds/*) return 0 ;;
        *) return 1 ;;
    esac
}

n=0
m=0
for f in $(git ls-files | LC_ALL=C sort); do
    [ -f "$f" ] || continue
    [ "$f" = "$MANIFEST" ] && continue          # cannot contain its own digest
    if ! _verify_only "$f"; then
        [ -n "$(z2k_install_paths "$f" 2>/dev/null)" ] || continue
    fi
    printf '  "%s": "%s",\n' "$f" "$(_sha "$f")" >> "$BLOCK"
    n=$((n + 1))
    # install_map — куда класть. Едет ДАННЫМИ, потому что обновление выполняет
    # старый апдейтер, который шаблонов новых путей не знает: пока он выводил
    # адрес сам, файл нового класса терялся, а версия уезжала вперёд.
    _targets=$(z2k_install_paths "$f" 2>/dev/null)
    [ -n "$_targets" ] || continue
    _json=$(printf '%s\n' "$_targets" | awk 'NF {printf "%s\"%s\"", (c++ ? ", " : ""), $0}')
    printf '  "%s": [%s],\n' "$f" "$_json" >> "$MAPBLOCK"
    m=$((m + 1))
done
[ "$n" -gt 0 ] || { echo "не найдено ни одного доставляемого файла — генерация прервана" >&2; exit 1; }

# Strip the trailing comma of the last pair (JSON has no trailing commas).
sed -i.bak '$ s/,$//' "$BLOCK" && rm -f "${BLOCK}.bak"
sed -i.bak '$ s/,$//' "$MAPBLOCK" && rm -f "${MAPBLOCK}.bak"

# Rebuild: everything as-is, minus any previous block of ours, plus a fresh one
# straight after "current". awk state machine, so no dependence on where the old
# block happened to sit.
awk -v blockfile="$BLOCK" -v mapfile="$MAPBLOCK" '
    /^[[:space:]]*"(files_sha256|install_map)"[[:space:]]*:[[:space:]]*\{/ { skipping = 1; next }
    skipping && /^[[:space:]]*\},?[[:space:]]*$/            { skipping = 0; next }
    skipping                                                { next }
    { print }
    /^[[:space:]]*"current"[[:space:]]*:/ && !emitted {
        print "  \"install_map\": {"
        while ((getline line < mapfile) > 0) print line
        close(mapfile)
        print "  },"
        print "  \"files_sha256\": {"
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        print "  },"
        emitted = 1
    }
' "$MANIFEST" > "$OUT"

# Never ship a manifest we just broke.
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT" \
        || { echo "результат не парсится как JSON — исходник не тронут" >&2; exit 1; }
fi
grep -q '"files_sha256"' "$OUT" || { echo "блок не вставился — исходник не тронут" >&2; exit 1; }
grep -q '"install_map"' "$OUT" || { echo "install_map не вставился — исходник не тронут" >&2; exit 1; }

cat "$OUT" > "$MANIFEST"
printf 'files_sha256: %d файлов, install_map: %d целей\n' "$n" "$m"
