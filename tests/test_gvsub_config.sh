#!/bin/sh
# Реальный генератор, чистый /tmp-эквивалент, до любого S99/validate.
# Не требует nfqws2 для Linux на машине разработчика.
# Необязательный аргумент — дерево кандидата для репетиции релиза.
set -e
ROOT=${1:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
ZAPRET2_DIR="$TMP/router"
Z2K_GVSUB_IPS="$TMP/volatile/ips"
export ZAPRET2_DIR Z2K_GVSUB_IPS
mkdir -p "$ZAPRET2_DIR/extra_strats/TCP/YT" \
    "$ZAPRET2_DIR/extra_strats/TCP/YT_GV" "$ZAPRET2_DIR/extra_strats/UDP/YT" "$ZAPRET2_DIR/lua" \
    "$ZAPRET2_DIR/lists" "$TMP/volatile"
printf 'youtube.com\n' > "$ZAPRET2_DIR/extra_strats/TCP/YT/List.txt"
printf 'youtube.com\ngooglevideo.com\n' > "$ZAPRET2_DIR/extra_strats/UDP/YT/List.txt"
printf 'googlevideo.com\n' > "$ZAPRET2_DIR/extra_strats/TCP/YT_GV/List.txt"
cp "$ROOT/files/lua/z2k-preflight.lua" "$ZAPRET2_DIR/lua/"
# shellcheck disable=SC1091
. "$ROOT/lib/utils.sh" 2>/dev/null
# shellcheck disable=SC1091
sed "s@/opt/zapret2/config@$ZAPRET2_DIR/config@g" "$ROOT/lib/config_official.sh" > "$TMP/generator.sh"
. "$TMP/generator.sh"
printf '0.0.0.0/32\n::/128\n' > "$TMP/want"
generate() {
    # Флаги явно включены: тест не должен зависеть от будущих умолчаний.
    printf 'ENABLED=1\nZ2K_GV_SERVER_REPLY2=1\nZ2K_REFACTOR_PHASE3=0\n' > "$ZAPRET2_DIR/config"
    create_official_config "$ZAPRET2_DIR/config" > "$TMP/generator.out" 2>&1
}
has_profile() {
    grep -qF -- "--ipset=$Z2K_GVSUB_IPS " "$ZAPRET2_DIR/config" || {
        echo 'FAIL: enabled GV profile was not generated with the requested ipset path' >&2
        return 1
    }
}
generate
if grep -q '^Z2K_PROVIDER_CACHE=' "$ZAPRET2_DIR/config"; then
    echo 'FAIL: retired key created by default'; exit 1
fi
has_profile
cmp "$TMP/want" "$Z2K_GVSUB_IPS"
echo 'PASS: create_official_config prepares missing ipset before validate/S99'

: > "$Z2K_GVSUB_IPS"
generate
has_profile
cmp "$TMP/want" "$Z2K_GVSUB_IPS"

printf '74.125.110.70\n2a00:1450:4001::9\n' > "$Z2K_GVSUB_IPS"
printf '74.125.110.70\n2a00:1450:4001::9\n' >> "$TMP/want"
generate
has_profile
cmp "$TMP/want" "$Z2K_GVSUB_IPS"
ln "$Z2K_GVSUB_IPS" "$TMP/original"
generate
cmp "$TMP/want" "$Z2K_GVSUB_IPS"
test "$(ls -i "$Z2K_GVSUB_IPS" | awk '{print $1}')" = "$(ls -i "$TMP/original" | awk '{print $1}')"
echo 'PASS: regeneration preserves addresses and complete snapshot inode'

# Ошибка гарантирована даже под root: компонент пути является файлом.
Z2K_GVSUB_IPS="$TMP/original/ips"
generate
if grep -qF -- '--ipset=' "$ZAPRET2_DIR/config"; then
    echo 'FAIL: generation published inaccessible ipset' >&2
    exit 1
fi
grep -qF -- "--hostlist=$ZAPRET2_DIR/extra_strats/TCP/YT_GV/List.txt" "$ZAPRET2_DIR/config"
echo 'PASS: write failure survives errexit and keeps hostlist without broken IP profile'

# An old key is inert in either state and survives regeneration silently.
Z2K_GVSUB_IPS="$TMP/volatile/ips"
for old in 0 1; do
    printf 'ENABLED=1\nZ2K_GV_SERVER_REPLY2=1\nZ2K_REFACTOR_PHASE3=0\nZ2K_PROVIDER_CACHE=%s\n' "$old" > "$ZAPRET2_DIR/config"
    create_official_config "$ZAPRET2_DIR/config" > "$TMP/legacy.out" 2>&1
    grep -q "^Z2K_PROVIDER_CACHE=$old$" "$ZAPRET2_DIR/config"
    if grep -qiE 'provider|кэш|кеш' "$TMP/legacy.out"; then
        echo 'FAIL: inert key produced a warning'; exit 1
    fi
    if grep -qE -- '--lua-desync=z2k_provider_reject|отказ провайдерскому видеокэшу' "$ZAPRET2_DIR/config"; then
        echo 'FAIL: retired action regenerated'; exit 1
    fi
    sed '/^Z2K_PROVIDER_CACHE=/d' "$ZAPRET2_DIR/config" > "$TMP/normalized.$old"
done
cmp "$TMP/normalized.0" "$TMP/normalized.1"
echo 'PASS: old key 0/1 preserved silently with identical generated behavior'

# Explicit server-reply switch must also cover DNS IPs with the merged layout.
printf 'ENABLED=1\nZ2K_GV_SERVER_REPLY2=1\nZ2K_REFACTOR_PHASE3=1\n' > "$ZAPRET2_DIR/config"
create_official_config "$ZAPRET2_DIR/config" > "$TMP/merged.out" 2>&1
has_profile
echo 'PASS: explicit server-reply switch covers DNS IPs in merged layout'
