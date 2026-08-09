#!/bin/sh
# tests/test_manifest_signature.sh — подпись манифеста и храповик доверия.
#
# ЗАЧЕМ ЭТО ВООБЩЕ. Манифест — корень доверия: из него берётся и решение «что
# ставить», и хеши, которыми проверяется каждый скачанный файл. Кто подменил
# манифест, тот подменил и эталоны, и вся дальнейшая сверка подтверждает
# подмену вместо того, чтобы её ловить. Карта сумм закрывает подменённое
# зеркало, но не того, кто получил доступ к самому репозиторию.
#
# ИСТОРИЯ, КОТОРУЮ НАДО ЗНАТЬ. Подпись уже была построена (5f17861) и откачена
# через день (6fbe694). Причина отката не техническая: потеря ключа замораживала
# флот навсегда, потому что ключ на роутерах меняется только обновлением, а оно
# должно быть подписано ключом, которого нет. Нынешняя схема эту причину
# снимает конструктивно — подпись гейтит ТОЛЬКО авто-канал, ручная переустановка
# не гейтится и приносит новый ключ. Тесты ниже держат обе половины: и то, что
# подпись работает, и то, что она не может запереть установку насмерть.
#
# POSIX sh + openssl с Ed25519 (на macOS системный LibreSSL не годится).

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
AU="$ROOT/lib/auto_update.sh"
[ -f "$AU" ] || { printf '[FAIL] нет %s\n' "$AU"; exit 1; }

# --- статические свойства (не требуют openssl) --------------------------------

# Проверка обязана стоять ДО разбора: иначе враждебный манифест успеет доехать
# до кода, который читает из него пути и хеши.
_v=$(grep -n 'au_manifest_verify "$out" "$sig"' "$AU" | head -1 | cut -d: -f1)
_p=$(grep -n '^au_manifest_current()' "$AU" | head -1 | cut -d: -f1)
if [ -n "$_v" ] && [ -n "$_p" ] && [ "$_v" -lt "$_p" ]; then
    ok "проверка подписи стоит до разбора манифеста"
else
    no "проверка подписи стоит до разбора манифеста" "verify раньше parse" "verify=$_v parse=$_p"
fi

# Храповик обязан жить ВНЕ /opt/zapret2 — иначе переустановка снесла бы его
# вместе с деревом, и защита превратилась бы в декорацию.
_pin=$(sed -n 's/^Z2K_AU_TRUST_PIN="\${Z2K_AU_TRUST_PIN:-\([^}]*\)}".*/\1/p' "$AU" | head -1)
case "$_pin" in
    /opt/zapret2/*) no "храповик вне сносимого дерева" "не под /opt/zapret2" "$_pin" ;;
    /*)             ok "храповик вне сносимого дерева ($_pin)" ;;
    *)              no "храповик задан абсолютным путём" "абсолютный путь" "$_pin" ;;
esac

OSSL=""
for c in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
         /usr/local/bin/openssl "$(command -v openssl 2>/dev/null)"; do
    [ -x "$c" ] || continue
    "$c" genpkey -algorithm ed25519 -out /dev/null >/dev/null 2>&1 || continue
    OSSL="$c"; break
done
if [ -z "$OSSL" ]; then
    SKIP=$((SKIP+1))
    printf '[SKIP] поведение подписи (нет openssl с Ed25519; в CI проверяется)\n'
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-sig.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

"$OSSL" genpkey -algorithm ed25519 -out "$TMP/k" 2>/dev/null
"$OSSL" pkey -in "$TMP/k" -pubout -out "$TMP/pub.pem" 2>/dev/null
"$OSSL" genpkey -algorithm ed25519 -out "$TMP/other" 2>/dev/null

printf '{"schema":1,"seq":7,"current":"p-1"}\n' > "$TMP/m.json"
"$OSSL" pkeyutl -sign -rawin -inkey "$TMP/k" -in "$TMP/m.json" -out "$TMP/m.sig" 2>/dev/null

# Подключаем только нужные функции: сорсить auto_update.sh целиком нельзя,
# он тянет окружение установки.
au_log() { :; }
eval "$(awk '/^au_manifest_verify\(\) \{/,/^\}/' "$AU")"
eval "$(awk '/^au_trust_pinned\(\) \{/,/^\}/' "$AU")"
eval "$(awk '/^au_trust_pin\(\) \{/,/^\}/' "$AU")"

# Проверяльщику передаём НАЙДЕННЫЙ openssl: на macOS в PATH лежит LibreSSL,
# который Ed25519 не умеет, и без этого тест проверял бы не то.
Z2K_AU_OPENSSL="$OSSL"
Z2K_AU_PUBKEY="$TMP/pub.pem"
Z2K_AU_TRUST_PIN="$TMP/pinned"

# --- 1. Подпись делает то, что обещает ----------------------------------------
au_manifest_verify "$TMP/m.json" "$TMP/m.sig" \
    && ok "валидная подпись принимается" \
    || no "валидная подпись принимается" "принята" "отвергнута"

printf '{"schema":1,"seq":8,"current":"p-1"}\n' > "$TMP/bad.json"
au_manifest_verify "$TMP/bad.json" "$TMP/m.sig" \
    && no "подменённый манифест отвергается" "отвергнут" "принят" \
    || ok "подменённый манифест отвергается"

"$OSSL" pkeyutl -sign -rawin -inkey "$TMP/other" -in "$TMP/m.json" -out "$TMP/other.sig" 2>/dev/null
au_manifest_verify "$TMP/m.json" "$TMP/other.sig" \
    && no "подпись чужим ключом отвергается" "отвергнута" "принята" \
    || ok "подпись чужим ключом отвергается"

# Отсутствие подписи — не то же самое, что неверная подпись, но принимать
# её нельзя: иначе атака сводится к «удали .sig».
au_manifest_verify "$TMP/m.json" "$TMP/nosuch.sig" \
    && no "отсутствующая подпись не считается валидной" "отвергнута" "принята" \
    || ok "отсутствующая подпись не считается валидной"

# --- 2. «Нечем проверить» отличается от «не сошлась» --------------------------
#
# Это разные состояния, и путать их нельзя: первое штатно для установки,
# которая ключа ещё не получила, второе — атака.
_saved_pub="$Z2K_AU_PUBKEY"
Z2K_AU_PUBKEY="$TMP/nokey.pem"
au_manifest_verify "$TMP/m.json" "$TMP/m.sig"
[ "$?" = "2" ] && ok "без ключа возвращается «нечем проверить» (2), а не «не сошлось»" \
               || no "без ключа возвращается 2" "2" "$?"
Z2K_AU_PUBKEY="$_saved_pub"

# openssl без поддержки -rawin (1.1.1) обязан давать «нечем проверить», а не
# «подделка»: иначе роутер со старым openssl и защёлкнутым храповиком отказался
# бы обновляться навсегда.
_saved_ossl="$Z2K_AU_OPENSSL"
cat > "$TMP/oldssl" <<'OLDSSL'
#!/bin/sh
case "$1" in
    pkeyutl) shift; case "$1" in -help) echo "usage: pkeyutl [-sign] [-verify]"; exit 0 ;; esac ;;
esac
exit 1
OLDSSL
chmod +x "$TMP/oldssl"
Z2K_AU_OPENSSL="$TMP/oldssl"
au_manifest_verify "$TMP/m.json" "$TMP/m.sig"
[ "$?" = "2" ] && ok "openssl без -rawin даёт «нечем проверить», а не «подделка»" \
               || no "openssl без -rawin даёт 2" "2" "$?"
Z2K_AU_OPENSSL="$_saved_ossl"

# --- 3. Храповик ---------------------------------------------------------------
au_trust_pinned && no "храповик изначально не защёлкнут" "не защёлкнут" "защёлкнут" \
                || ok "храповик изначально не защёлкнут"
au_trust_pin
au_trust_pinned && ok "храповик защёлкивается" \
                || no "храповик защёлкивается" "защёлкнут" "нет"

# --- 4. Ключ и подпись в дереве согласованы -----------------------------------
#
# Если публичный ключ в репозитории перестанет соответствовать подписи рядом с
# манифестом, каждый роутер с защёлкнутым храповиком отвергнет релиз. Это
# худший сорт отказа: он одновременный и у всех.
if [ -s "$ROOT/files/etc/z2k-update-pub.pem" ] && [ -s "$ROOT/UPDATES.json.sig" ]; then
    if "$OSSL" pkeyutl -verify -rawin -pubin -inkey "$ROOT/files/etc/z2k-update-pub.pem" \
         -in "$ROOT/UPDATES.json" -sigfile "$ROOT/UPDATES.json.sig" >/dev/null 2>&1; then
        ok "подпись манифеста в дереве сходится с опубликованным ключом"
    else
        no "подпись манифеста в дереве сходится с опубликованным ключом" \
           "сходится" "НЕ сходится — роутеры отвергнут релиз"
    fi
else
    SKIP=$((SKIP+1))
    printf '[SKIP] подпись манифеста в дереве (нет ключа или .sig — релиз ещё не подписывали)\n'
fi

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
