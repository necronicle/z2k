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
# The deliverable set is not hardcoded: it is whatever au_install_paths() maps
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
elif command -v shasum >/dev/null 2>&1; then
    _sha() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "нужен sha256sum или shasum" >&2; exit 1
fi

# Deliverable = au_install_paths() gives it a destination on the router.
Z2K_AU_SOURCE_ONLY=1 . ./lib/auto_update.sh 2>/dev/null

BLOCK=$(mktemp) || exit 1
OUT=$(mktemp) || exit 1
trap 'rm -f "$BLOCK" "$OUT"' EXIT

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
    sed "s/?v=[A-Za-z0-9._-]*\"/?v=${_cur}\"/g" webpanel/www/index.html > "$OUT" \
        && cat "$OUT" > webpanel/www/index.html
    printf 'кеш-бастер панели: ?v=%s\n' "$_cur"
fi

n=0
for f in $(git ls-files | LC_ALL=C sort); do
    [ -f "$f" ] || continue
    [ "$f" = "$MANIFEST" ] && continue          # cannot contain its own digest
    [ -n "$(au_install_paths "$f" 2>/dev/null)" ] || continue
    printf '  "%s": "%s",\n' "$f" "$(_sha "$f")" >> "$BLOCK"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "не найдено ни одного доставляемого файла — генерация прервана" >&2; exit 1; }

# Strip the trailing comma of the last pair (JSON has no trailing commas).
sed -i.bak '$ s/,$//' "$BLOCK" && rm -f "${BLOCK}.bak"

# Rebuild: everything as-is, minus any previous block of ours, plus a fresh one
# straight after "current". awk state machine, so no dependence on where the old
# block happened to sit.
awk -v blockfile="$BLOCK" '
    /^[[:space:]]*"files_sha256"[[:space:]]*:[[:space:]]*\{/ { skipping = 1; next }
    skipping && /^[[:space:]]*\},?[[:space:]]*$/            { skipping = 0; next }
    skipping                                                { next }
    { print }
    /^[[:space:]]*"current"[[:space:]]*:/ && !emitted {
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

cat "$OUT" > "$MANIFEST"
printf 'files_sha256: %d файлов\n' "$n"

# Подпись — побочный продукт манифеста, а НЕ шаг релиза.
#
# Роутер тянет UPDATES.json с головы ветки, а не с релизного тега. Значит любой
# коммит, трогающий доставляемый файл, пересобирает files_sha256 и меняет байты
# манифеста — и подпись, поставленная в момент релиза, к нему уже не подходит.
# Держали бы подпись в release.sh — первый же обычный пуш остановил бы обновления
# у всего парка, который успел получить ключ, причём молча: вебморда проверяет
# обновления своим curl без подписи и продолжала бы показывать «доступно».
# Поэтому подписываем здесь: где меняется манифест, там же меняется и подпись.
#
# Приватного ключа нет ни в репозитории, ни на CI — там этот блок просто
# пропускается, а сверку committed-пары делает отдельный шаг workflow.
SIGN_KEY="${Z2K_SIGNING_KEY:-$HOME/.z2k-signing/z2k-update-priv.pem}"
PUBKEY="$ROOT/files/etc/z2k-update-pub.pem"
OSSL=openssl
for _o in /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
    [ -x "$_o" ] && { OSSL="$_o"; break; }
done

if [ -s "$SIGN_KEY" ]; then
    if ! "$OSSL" pkeyutl -sign -inkey "$SIGN_KEY" -rawin \
            -in "$MANIFEST" -out "${MANIFEST}.sig" 2>/dev/null; then
        echo "не удалось подписать манифест ($OSSL)" >&2
        exit 1
    fi
    # Расходящаяся подпись хуже отсутствующей: её отвергнет разом весь парк.
    if ! "$OSSL" pkeyutl -verify -pubin -inkey "$PUBKEY" \
            -rawin -in "$MANIFEST" -sigfile "${MANIFEST}.sig" >/dev/null 2>&1; then
        echo "подпись не сходится с files/etc/z2k-update-pub.pem — приватный ключ не тот" >&2
        rm -f "${MANIFEST}.sig"
        exit 1
    fi
    printf 'подпись манифеста: UPDATES.json.sig обновлена\n'
else
    printf 'подпись пропущена: приватного ключа нет (%s)\n' "$SIGN_KEY"
fi
