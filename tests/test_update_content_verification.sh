#!/bin/sh
# tests/test_update_content_verification.sh
#
# An update used to be able to report success, move the version tag forward, and
# change nothing — or move a file BACKWARDS to an older revision. Nothing logged
# an error, because from the updater's point of view every step succeeded.
#
# Two independent ways it happened, both observed in the field (issue #26):
#
#   * A mirror answered with stale bytes. jsdelivr and gh-proxy terminate TLS
#     themselves and cache per edge; "the transport succeeded" says nothing
#     about WHICH revision arrived.
#   * A staged file from an earlier run survived in /tmp/z2k_au/dl together with
#     its .etag sidecar. The next run offered that etag, took a 304, counted it
#     a successful download, and installed the old file.
#
# The fix is that a download only counts if the bytes hash to what UPDATES.json
# says HEAD holds. So the properties under test are behavioural: a stale mirror
# must be SKIPPED like one that never answered, an all-stale fetch must FAIL
# rather than install, and a rejected body must not survive to be revalidated.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ucv.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export TMP

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }
sha_str() { printf '%s' "$1" > "$TMP/.s"; sha_of "$TMP/.s"; }

# ---------------------------------------------------------------------------
# A fake curl. _z2k_curl_etag invokes curl with -o <body> and -w '%{http_code}';
# we honour exactly that contract and serve a different body per invocation, so
# a test can say "hop 1 is stale, hop 2 is fresh" and observe which one wins.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/sh
n=$(cat "$TMP/hop.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$TMP/hop.n"
out=""; hdr=""; prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    [ "$prev" = "-D" ] && hdr="$a"
    prev="$a"
done
body="$TMP/serve.$n"; [ -f "$body" ] || body="$TMP/serve.default"
if [ -f "$body" ] && [ -n "$out" ]; then cat "$body" > "$out"; fi
# A real mirror answers with an ETag, and _z2k_curl_etag persists it as a
# sidecar. Emitting one is what makes "the sidecar of a REJECTED body must be
# destroyed" testable at all — without it the assertion passes vacuously,
# and a mutant that stops deleting the etag survives.
if [ -n "$hdr" ]; then
    printf 'HTTP/2 200\r\netag: "hop-%s"\r\n\r\n' "$n" > "$hdr"
fi
printf '200'
exit 0
STUB
chmod +x "$TMP/bin/curl"

FRESH='fresh content — the revision HEAD actually holds'
STALE='stale content — what a lagging CDN edge still has'
FRESH_SHA=$(sha_str "$FRESH")
STALE_SHA=$(sha_str "$STALE")
[ "$FRESH_SHA" != "$STALE_SHA" ] && ok "фикстуры различимы по sha256" \
                                 || no "фикстуры различимы по sha256" "разные" "одинаковые"

run_fetch() {
    # run_fetch <expected-sha> ; hop bodies come from $TMP/serve.N
    rm -f "$TMP/hop.n" "$TMP/dest" "$TMP/dest.etag"
    PATH="$TMP/bin:$PATH" \
    GITHUB_RAW="https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced" \
    Z2K_FETCH_SHA256="$1" \
    sh -c '
        . '"$HERE"'/lib/utils.sh 2>/dev/null
        z2k_fetch "/files/probe.sh" "'"$TMP"'/dest" >/dev/null 2>&1
        echo "rc=$?"
    '
}

# --- 1. a stale first hop must not be accepted; a later fresh hop must win ---
printf '%s' "$STALE" > "$TMP/serve.1"
printf '%s' "$STALE" > "$TMP/serve.2"
printf '%s' "$FRESH" > "$TMP/serve.default"
rc=$(run_fetch "$FRESH_SHA")
got=$(cat "$TMP/dest" 2>/dev/null)
case "$rc" in *rc=0*) ok "фетч удался, дойдя до свежего зеркала" ;;
              *)     no "фетч удался, дойдя до свежего зеркала" "rc=0" "$rc" ;; esac
[ "$got" = "$FRESH" ] && ok "установлено содержимое СВЕЖЕГО зеркала, а не первого ответившего" \
                      || no "установлено содержимое свежего зеркала" "$FRESH" "$got"

# --- 2. every hop stale => the fetch must FAIL, not install the old file ------
printf '%s' "$STALE" > "$TMP/serve.default"
rm -f "$TMP"/serve.1 "$TMP"/serve.2
rc=$(run_fetch "$FRESH_SHA")
got=$(cat "$TMP/dest" 2>/dev/null)
case "$rc" in *rc=0*) no "все зеркала устарели → фетч обязан провалиться" "rc!=0" "$rc" ;;
              *)     ok "все зеркала устарели → фетч провалился, а не поставил старьё" ;; esac
[ -z "$got" ] && ok "отклонённое тело не осталось на диске" \
              || no "отклонённое тело не осталось на диске" "пусто" "$got"
[ ! -f "$TMP/dest.etag" ] && ok "etag отклонённого тела удалён (иначе следующий хоп получит 304 и примет его снова)" \
                          || no "etag отклонённого тела удалён" "нет файла" "остался"

# --- 3. no expectation set => behaviour is exactly as before ------------------
rm -f "$TMP/hop.n" "$TMP/dest" "$TMP/dest.etag"
printf '%s' "$STALE" > "$TMP/serve.default"
rc=$(PATH="$TMP/bin:$PATH" GITHUB_RAW="https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced" \
     sh -c '. '"$HERE"'/lib/utils.sh 2>/dev/null; z2k_fetch "/files/probe.sh" "'"$TMP"'/dest" >/dev/null 2>&1; echo "rc=$?"')
case "$rc" in *rc=0*) ok "без ожидаемого хеша фетч не изменил поведение" ;;
              *)     no "без ожидаемого хеша фетч не изменил поведение" "rc=0" "$rc" ;; esac

# --- 4. the manifest lookup --------------------------------------------------
MAN="$HERE/UPDATES.json"
lookup() { sh -c "Z2K_AU_SOURCE_ONLY=1 . '$HERE/lib/auto_update.sh' 2>/dev/null; au_manifest_file_sha '$1' '$2'"; }

want=$(lookup "$MAN" "files/z2k-warp.sh")
real=$(sha_of "$HERE/files/z2k-warp.sh")
[ -n "$want" ] && [ "$want" = "$real" ] \
    && ok "манифест публикует верный sha256 для files/z2k-warp.sh" \
    || no "манифест публикует верный sha256" "$real" "$want"

[ -z "$(lookup "$MAN" "files/no-such-file.sh")" ] \
    && ok "неизвестный путь → пусто (проверка просто не применяется)" \
    || no "неизвестный путь → пусто" "пусто" "непусто"

# A path that is a regex-ish substring of a real one must not match it: the
# lookup anchors and escapes, so "iles/z2k-warp.sh" is simply unknown.
[ -z "$(lookup "$MAN" "iles/z2k-warp.sh")" ] \
    && ok "поиск заякорен — подстрока чужого пути не матчится" \
    || no "поиск заякорен" "пусто" "нашёл"

# Backward compatibility: manifests published before this map existed.
printf '{\n "schema": 1,\n "current": "r-1",\n "history": [\n]\n}\n' > "$TMP/old.json"
[ -z "$(lookup "$TMP/old.json" "files/z2k-warp.sh")" ] \
    && ok "манифест без files_sha256 → пусто, старые релизы не ломаются" \
    || no "манифест без files_sha256 → пусто" "пусто" "непусто"

# --- 5. the manifest must stay machine-readable for the OLD parser -----------
# au_history_entries_after matches history one ENTRY PER LINE. A pretty-printer
# run over UPDATES.json would split every entry and break the updater on every
# router already in the field, so this is asserted, not assumed.
entries=$(awk '/^[[:space:]]*\{[[:space:]]*"v"[[:space:]]*:[[:space:]]*"/{n++} END{print n+0}' "$MAN")
[ "$entries" -ge 100 ] && ok "история осталась построчной ($entries записей)" \
                       || no "история осталась построчной" ">=100" "$entries"
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MAN" 2>/dev/null \
        && ok "UPDATES.json остаётся валидным JSON" \
        || no "UPDATES.json остаётся валидным JSON" "валиден" "сломан"
fi

# --- 6. the map must match the tree -----------------------------------------
# Otherwise verification rejects good files and every update fails closed —
# a far louder failure than the one being fixed, so CI must catch drift.
# Проверяются ВСЕ записи карты, а не выборка. Раньше здесь был жёстко зашитый
# список из шести файлов, и правка любого из остальных восьмидесяти пяти
# проходила локально зелёной — расхождение всплывало только в CI. Полный гейт
# и так живёт в .github/workflows/ci.yml (прогон gen_file_hashes.sh + git diff),
# но узнавать о нём после пуша — это ровно тот цикл, который тест обязан
# закрывать локально. Хеширование 91 файла занимает доли секунды.
drift=0; checked=0; gone=0
for f in $(sed -n 's/^[[:space:]]*"\([^"]*\)":[[:space:]]*"[0-9a-f]\{64\}",\{0,1\}$/\1/p' "$MAN"); do
    checked=$((checked+1))
    if [ ! -f "$HERE/$f" ]; then
        # Запись на удалённый файл так же ядовита: роутер пойдёт его качать,
        # получит 404 и упрётся в проверку содержимого.
        gone=$((gone+1)); printf '       в карте есть, на диске нет: %s\n' "$f"
        continue
    fi
    m=$(lookup "$MAN" "$f"); r=$(sha_of "$HERE/$f")
    [ "$m" = "$r" ] || { drift=$((drift+1)); printf '       рассинхрон: %s\n' "$f"; }
done
[ "$checked" -gt 50 ] \
    && ok "проверена вся карта, а не выборка ($checked записей)" \
    || no "проверена вся карта" ">50 записей" "$checked"
[ "$checked" -gt 0 ] && [ "$drift" = 0 ] && [ "$gone" = 0 ] \
    && ok "манифест синхронен с деревом ($checked файлов проверено)" \
    || {
        # Между релизами манифест НЕ пересобирается: он описывает последний
        # выпущенный срез, а не рабочую копию. Карту и подпись пересобирает
        # только release.sh — иначе подпись перестала бы сходиться на каждом
        # рабочем коммите (см. ci.yml, гейт «манифест»). Поэтому расхождение
        # здесь — ошибка ТОЛЬКО на релизном коммите.
        _pub=$(git -C "$HERE" show origin/z2k-enhanced:UPDATES.json 2>/dev/null \
               | sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        _cur=$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/UPDATES.json" | head -1)
        if [ -n "$_pub" ] && [ "$_pub" = "$_cur" ]; then
            ok "манифест описывает выпущенный срез, а не рабочую копию (расхождений $drift — это норма между релизами)"
        else
            no "манифест синхронен с деревом" "0 расхождений" "drift=$drift gone=$gone"
        fi
    }

# --- 6b. the map must be ordered deterministically ---------------------------
# The generator runs on a developer's machine AND on the CI runner, and CI
# compares the result byte-for-byte. Ordered by the ambient locale, macOS and
# Linux disagree about where "extra-domains.txt" sits relative to "extra_strats/"
# — identical digests, different line order, read as drift, and the gate fails on
# a tree that is perfectly in sync. So collation is pinned, and asserted here.
# Pairs only — the `"files_sha256": {` header line would otherwise be harvested
# as a key of its own and land out of order, failing the check on a good file.
keys=$(sed -n '/"files_sha256"/,/^  },$/p' "$MAN" \
       | grep -v '"files_sha256"' \
       | sed -n 's/^  "\([^"]*\)"[[:space:]]*:[[:space:]]*"[0-9a-f]\{64\}".*/\1/p')
if [ -n "$keys" ]; then
    if [ "$keys" = "$(printf '%s\n' "$keys" | LC_ALL=C sort)" ]; then
        ok "карта хешей отсортирована в C-локали (одинаково на macOS и на Linux)"
    else
        no "карта хешей отсортирована в C-локали" "C-порядок" "порядок ambient-локали"
    fi
else
    no "карта хешей читается" "непустой список ключей" "пусто"
fi
grep -q '^LC_ALL=C' "$HERE/scripts/gen_file_hashes.sh" \
    && ok "генератор пинит локаль явно" \
    || no "генератор пинит локаль явно" "LC_ALL=C" "отсутствует"

# --- 7. staging is emptied before a patch run -------------------------------
# A file left from a previous run, plus its etag, is exactly how a 304 turned
# into "download succeeded" while the old bytes got installed.
apply_body=$(awk '/^au_apply_patch\(\)/{f=1} f{print} f&&/^}/{exit}' "$HERE/lib/auto_update.sh")
case "$apply_body" in
    *'rm -rf "$Z2K_AU_TMP_DIR/dl"'*) ok "au_apply_patch чистит staging перед прогоном" ;;
    *) no "au_apply_patch чистит staging перед прогоном" "rm -rf .../dl" "отсутствует" ;;
esac
# The wipe has to happen BEFORE the first download, or a stale pair is still
# offered to the mirrors on this very run.
rm_ln=$(printf '%s\n' "$apply_body" | grep -n 'rm -rf "\$Z2K_AU_TMP_DIR/dl"' | head -1 | cut -d: -f1)
dl_ln=$(printf '%s\n' "$apply_body" | grep -n 'au_download_repo_file' | head -1 | cut -d: -f1)
if [ -n "$rm_ln" ] && [ -n "$dl_ln" ] && [ "$rm_ln" -lt "$dl_ln" ]; then
    ok "чистка идёт до первой загрузки (строка $rm_ln < $dl_ln)"
else
    no "чистка идёт до первой загрузки" "rm раньше download" "$rm_ln/$dl_ln"
fi
case "$apply_body" in
    *'Z2K_FETCH_SHA256="$_want_sha"'*) ok "патч передаёт ожидаемый sha256 в фетчер" ;;
    *) no "патч передаёт ожидаемый sha256 в фетчер" "экспорт Z2K_FETCH_SHA256" "отсутствует" ;;
esac
case "$apply_body" in
    *'unset Z2K_FETCH_SHA256'*) ok "ожидание сбрасывается после файла (иначе следующий проверится чужим хешем)" ;;
    *) no "ожидание сбрасывается после файла" "unset" "отсутствует" ;;
esac
# and must NOT wipe the parent, which holds .install_rc and the fetched installer
grep -qE 'rm -rf "\$Z2K_AU_TMP_DIR"[[:space:]]*$' "$HERE/lib/auto_update.sh" \
    && no "родительский /tmp/z2k_au не сносится" "нет rm -rf на родителя" "есть" \
    || ok "родительский /tmp/z2k_au не сносится (там .install_rc и установщик)"

# --- 8. the installer must not silently keep an old file --------------------
loop=$(awk '/for tool_script in/{f=1} f{print} f&&/^    done/{exit}' "$HERE/lib/install.sh")
case "$loop" in
    *deploy_critical_file*) ok "tool-loop разворачивает через deploy_critical_file (есть фоллбэк на сеть)" ;;
    *)                      no "tool-loop разворачивает через deploy_critical_file" "deploy_critical_file" "bare cp" ;;
esac
case "$loop" in
    *'print_warning'*) ok "недоставленный инструмент сообщает о себе, а не молчит" ;;
    *)                 no "недоставленный инструмент сообщает о себе" "print_warning" "тишина" ;;
esac

# --- 9. the name collision that would have silently disabled all of this -----
# z2k.sh defines its own _z2k_fetch_ok (resets the DoH fail streak) INSIDE
# z2k_fetch. Shell functions defined in a function are global, so had the
# verifier been given that name it would have been overwritten by the streak
# resetter after the first fetch — a safety check quietly degraded to `return 0`.
grep -q '_z2k_verify_fetched' "$HERE/lib/utils.sh" && grep -q '_z2k_verify_fetched' "$HERE/z2k.sh" \
    && ok "верификатор носит собственное имя в обоих фетчерах" \
    || no "верификатор носит собственное имя" "_z2k_verify_fetched" "отсутствует"
if grep -q '_z2k_verify_fetched()' "$HERE/z2k.sh" && grep -q '_z2k_fetch_ok()' "$HERE/z2k.sh"; then
    ok "две функции сосуществуют, а не затирают друг друга"
else
    no "две функции сосуществуют" "обе определены" "одна отсутствует"
fi

# --- 10. every hop is gated -------------------------------------------------
# One ungated layer is enough to reintroduce the bug: the fetch would return 0
# from it and never reach a verified mirror.
ungated=$(grep -nE '_z2k_curl_etag "|_z2k_curl_doh "' "$HERE/z2k.sh" "$HERE/lib/utils.sh" \
          | grep -v '_z2k_verify_fetched' \
          | grep -vE '\(\)|resolve_args|:[0-9]+:[[:space:]]*#' \
          | grep -c 'dest"' )
[ "$ungated" -le 1 ] && ok "все слои загрузки проходят проверку содержимого" \
                     || no "все слои загрузки проходят проверку содержимого" "<=1 (перенос строки)" "$ungated"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
