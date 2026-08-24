#!/bin/sh
# tests/test_release_manifest_complete.sh
#
# The updater delivers exactly what a release's `changed_files` lists. A file
# that changed but was left off that list is simply never sent — quietly, with
# a green CI and a successful update.
#
# p-67.9.2 shipped that way: scripts/gen_file_hashes.sh rewrites the panel's
# cache-buster in webpanel/www/index.html on every release, the file duly
# changed, and it was not in changed_files. The very mechanism added to stop the
# panel going stale could not itself reach a router. And it is not a one-off
# mistake to be more careful about next time — the list is hand-written, so it
# will drift again.
#
# So the invariant is checked mechanically: everything that actually changed
# between the previous release commit and this one, and that has somewhere to be
# installed, must be declared. Files with no install target (tests, CI config)
# are ignored — the updater skips them anyway.
#
# Skips when git history or the refs are unavailable (shallow clone, tarball).
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE" || exit 1

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

[ -f UPDATES.json ] || { printf '[FAIL] UPDATES.json missing\n'; exit 1; }

if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    skip "полнота changed_files" "нет git-репозитория"
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
fi

# Last two history entries and their refs.
cur_v=$(awk '/^[[:space:]]*\{[[:space:]]*"v"/{last=$0} END{print last}' UPDATES.json | sed -n 's/.*"v"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
cur_ref=$(awk '/^[[:space:]]*\{[[:space:]]*"v"/{last=$0} END{print last}' UPDATES.json | sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
prev_ref=$(awk '/^[[:space:]]*\{[[:space:]]*"v"/{prev=last; last=$0} END{print prev}' UPDATES.json | sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

[ -n "$cur_v" ] && ok "последний релиз прочитан ($cur_v)" \
                || no "последний релиз прочитан" "тег" "пусто"

# "HEAD" — не пропуск, а ОШИБКА. Такое значение release.sh выдать не может
# (там git rev-parse --short HEAD), значит запись правили руками и забыли
# указать коммит. Последствия отложенные и оттого коварные: git diff HEAD HEAD
# даёт пустой набор, гейт полноты молча выключается, а у СЛЕДУЮЩЕГО релиза
# окно сравнения расползается на посторонние коммиты и тест краснеет с ложным
# сообщением. Класс отказа, который этот гейт ловит, уже уезжал в прод
# (p-67.9.2: index.html не доехал). Поймано ревью r-72.
if [ "$cur_ref" = "HEAD" ]; then
    no "ref последнего релиза указывает на коммит" "sha коммита" "HEAD (правлено руками?)"
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit 1
fi
if [ -z "$cur_ref" ] || [ -z "$prev_ref" ] || [ "$cur_ref" = "PENDING" ]; then
    skip "полнота changed_files" "нет ref у одного из релизов"
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit "$([ "$FAIL" = 0 ] && echo 0 || echo 1)"
fi
if ! git cat-file -e "${cur_ref}^{commit}" 2>/dev/null || ! git cat-file -e "${prev_ref}^{commit}" 2>/dev/null; then
    skip "полнота changed_files" "коммиты $prev_ref/$cur_ref недоступны (shallow clone?)"
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit "$([ "$FAIL" = 0 ] && echo 0 || echo 1)"
fi

declared=$(awk '/^[[:space:]]*\{[[:space:]]*"v"/{last=$0} END{print last}' UPDATES.json \
           | sed -n 's/.*"changed_files"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
           | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep -v '^$')
[ -n "$declared" ] && ok "changed_files прочитан" \
                   || no "changed_files прочитан" "список" "пусто"

# Everything that changed between the two release commits AND has an install
# target. UPDATES.json is always in the list by construction; skip the noise.
missing=""
checked=0
for f in $(git diff --name-only "$prev_ref" "$cur_ref" 2>/dev/null); do
    [ "$f" = "UPDATES.json" ] && continue
    # Удалённые файлы не заявляются — заявить к доставке нечего, и release.sh
    # их отсеивает тем же условием («удалённые не заявляем»). Без этой строки
    # гейт требовал объявить файл, которого в релизном коммите уже нет, и любое
    # удаление доставляемого файла роняло выпуск. Поймано на r-77.4, где из
    # проекта убирали lists/cloudflare-ranges.txt.
    #
    # Оговорка, которую надо держать в голове: у уже установленных роутеров
    # такой файл остаётся лежать. Для списков и прочей пассивной начинки это
    # безвредно, но если когда-нибудь удалять придётся код, который что-то
    # делает, — это отдельная задача, и решать её надо явной зачисткой в
    # lib/install.sh, а не молчанием манифеста.
    git cat-file -e "$cur_ref:$f" 2>/dev/null || continue
    target=$(sh -c ". ./lib/release_map.sh 2>/dev/null; z2k_install_paths '$f'")
    [ -n "$target" ] || continue          # no install target — updater skips it anyway
    checked=$((checked + 1))
    printf '%s\n' "$declared" | grep -qxF "$f" || missing="$missing $f"
done

if [ "$checked" = 0 ]; then
    skip "полнота changed_files" "в этом релизе не менялось ни одного доставляемого файла"
elif [ -z "$missing" ]; then
    ok "все изменённые доставляемые файлы объявлены ($checked шт, $prev_ref..$cur_ref)"
else
    no "все изменённые доставляемые файлы объявлены" "ничего не пропущено" "пропущено:$missing"
fi

# The panel's index.html carries the cache-buster and is therefore rewritten by
# scripts/gen_file_hashes.sh on EVERY release — the single most likely thing to
# be forgotten, and the one that went missing first.
if git diff --name-only "$prev_ref" "$cur_ref" 2>/dev/null | grep -qx 'webpanel/www/index.html'; then
    printf '%s\n' "$declared" | grep -qxF 'webpanel/www/index.html' \
        && ok "index.html с новой меткой версии доставляется" \
        || no "index.html с новой меткой версии доставляется" "в changed_files" "отсутствует"
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
