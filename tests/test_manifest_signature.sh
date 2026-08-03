#!/bin/sh
# tests/test_manifest_signature.sh
#
# UPDATES.json решает всё: в нём карта files_sha256, по которой роутер сверяет
# каждый скачанный файл. Пока манифест принимался на веру, вся защита держалась
# на транспорте — а среди зеркал есть gh-proxy, который терминирует TLS у себя.
# То есть подмена манифеста давала root на всём парке (issue #28).
#
# Здесь проверяется именно поведение проверки подписи, а не то, что «код на месте»:
#   * верная подпись пропускается;
#   * подменённый хоть на байт манифест отвергается;
#   * сорванная/отсутствующая подпись при наличии ключа отвергается — иначе
#     атака сводится к «удали .sig и проходи»;
#   * отсутствие ключа НЕ роняет обновление: роутер, установленный до появления
#     подписи, ключ получает именно этим обновлением.
#
# Ed25519 требует настоящий OpenSSL: LibreSSL на macOS его не умеет, поэтому
# тест ищет рабочий бинарник и честно пропускается, если такого нет.
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
AU="$HERE/lib/auto_update.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/msig.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$AU" ] || { printf '[FAIL] нет %s\n' "$AU"; exit 1; }

# --- рабочий openssl с ed25519 ------------------------------------------------
OSSL=""
for c in /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" genpkey -algorithm ed25519 -out "$TMP/probe.pem" >/dev/null 2>&1 || continue
    OSSL="$c"; break
done
if [ -z "$OSSL" ]; then
    printf '[SKIP] openssl с поддержкой ed25519 не найден\n'
    printf '\nPASSED: 0\nFAILED: 0\nSKIPPED: 1\n'
    exit 0
fi

"$OSSL" genpkey -algorithm ed25519 -out "$TMP/priv.pem" 2>/dev/null
"$OSSL" pkey -in "$TMP/priv.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null
printf '{"schema":1,"current":"p-1"}\n' > "$TMP/UPDATES.json"
"$OSSL" pkeyutl -sign -inkey "$TMP/priv.pem" -rawin -in "$TMP/UPDATES.json" -out "$TMP/real.sig" 2>/dev/null
[ -s "$TMP/real.sig" ] || { printf '[FAIL] не удалось подписать тестовый манифест\n'; exit 1; }

# Подменяем один байт — этого должно хватить.
sed 's/p-1/p-2/' "$TMP/UPDATES.json" > "$TMP/tampered.json"

# --- прогон функции из шипящегося кода ----------------------------------------
# Вытаскиваем ровно ту функцию, что поедет на роутер, и подставляем зависимости.
run_case() {
    # $1 — путь к манифесту, $2 — путь к ключу, $3 — 1 если .sig доступна
    (
        au_log() { :; }
        # На роутере в PATH стоит OpenSSL 3.x и функция зовёт его напрямую. На
        # macOS в PATH LibreSSL, который ed25519 не умеет, поэтому подменяем на
        # найденный выше рабочий бинарник — проверяется логика функции, а не то,
        # какой openssl оказался у разработчика.
        openssl() { "$OSSL" "$@"; }
        Z2K_AU_PUBKEY="$2"
        Z2K_AU_MANIFEST_URL="stub"
        if [ "$3" = 1 ]; then
            z2k_fetch() { cp "$TMP/real.sig" "$2"; }
        else
            z2k_fetch() { return 1; }
        fi
        # shellcheck disable=SC1090
        . "$TMP/fn.sh"
        au_verify_manifest_signature "$1"
    )
}

awk '/^au_verify_manifest_signature\(\)/,/^}/' "$AU" > "$TMP/fn.sh"
grep -q '^au_verify_manifest_signature()' "$TMP/fn.sh" \
    && ok "функция проверки извлечена из шипящегося кода" \
    || no "функция проверки извлечена" "определение" "нет"

run_case "$TMP/UPDATES.json" "$TMP/pub.pem" 1
[ $? = 0 ] && ok "верная подпись пропускается" \
           || no "верная подпись пропускается" "rc=0" "rc!=0"

run_case "$TMP/tampered.json" "$TMP/pub.pem" 1
[ $? != 0 ] && ok "подменённый манифест отвергается" \
            || no "подменённый манифест отвергается" "rc!=0" "rc=0"

run_case "$TMP/UPDATES.json" "$TMP/pub.pem" 0
[ $? != 0 ] && ok "срыв подписи при наличии ключа отвергается" \
            || no "срыв подписи отвергается" "rc!=0" "rc=0"

run_case "$TMP/UPDATES.json" "$TMP/nokey.pem" 1
[ $? = 0 ] && ok "без ключа обновление не рушится (старый роутер)" \
           || no "без ключа обновление не рушится" "rc=0" "rc!=0"

# --- проводка -----------------------------------------------------------------
# Проверка обязана стоять в au_fetch_manifest, иначе манифест доедет до разбора
# непроверенным и подпись превратится в украшение.
awk '/^au_fetch_manifest\(\)/,/^}/' "$AU" | grep -q 'au_verify_manifest_signature' \
    && ok "проверка вызывается прямо из au_fetch_manifest" \
    || no "проверка вызывается из au_fetch_manifest" "вызов" "нет"

# Публичный ключ должен ставиться на роутер, иначе проверять нечем.
grep -q 'files/etc/z2k-update-pub.pem' "$HERE/lib/install.sh" \
    && ok "публичный ключ ставится установщиком" \
    || no "публичный ключ ставится установщиком" "deploy" "нет"
[ -s "$HERE/files/etc/z2k-update-pub.pem" ] \
    && ok "публичный ключ лежит в репозитории" \
    || no "публичный ключ лежит в репозитории" "файл" "нет"

# А приватный — не должен. Это единственное, чего нет у того, кто получит доступ
# к репозиторию, и ровно поэтому подпись что-то значит.
if git -C "$HERE" ls-files | grep -qiE '(priv|private).*\.pem$'; then
    no "приватного ключа нет в репозитории" "отсутствует" "найден"
else
    ok "приватного ключа нет в репозитории"
fi

# Релизный скрипт обязан подписывать и падать без ключа — иначе однажды уедет
# неподписанный манифест, и весь парк с ключом его отвергнет.
grep -q 'pkeyutl -sign' "$HERE/release.sh" \
    && ok "release.sh подписывает манифест" \
    || no "release.sh подписывает манифест" "pkeyutl -sign" "нет"
grep -q 'pkeyutl -verify' "$HERE/release.sh" \
    && ok "release.sh сам проверяет получившуюся подпись" \
    || no "release.sh проверяет подпись" "pkeyutl -verify" "нет"

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
