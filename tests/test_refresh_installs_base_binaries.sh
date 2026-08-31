#!/bin/sh
# tests/test_refresh_installs_base_binaries.sh — базовый бинарник, которого нет,
# обновление обязано поставить; необязательный — нет.
#
# ЧТО СЛУЧИЛОСЬ. Шаг обновления бинарников пропускал ЛЮБОЙ отсутствующий файл:
# «его тут не должно быть». Для WARP это верно — его движок ставится кнопкой, и
# тащить семь мегабайт тому, кто WARP не включал, незачем. Но под то же правило
# попал z2k-detect, появившийся ПОЗЖЕ установки у части людей: установка второй
# раз не случается, обновление умеет только обновлять — и они не получали его
# НИКОГДА. Десять выпусков подряд в жалобах стояло «нет /opt/sbin/z2k-detect»,
# и ни один не мог помочь, потому что чинили доставку файлов, а дыра была здесь.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT

mkdir -p "$SB/sbin" "$SB/tmp"
MAN="$SB/tmp/UPDATES.json"
cat > "$MAN" <<'JSON'
{"files_sha256": {
 "z2k-detect/builds/z2k-detect-linux-arm64": "aa",
 "z2k-warpd/builds/z2k-warpd-linux-arm64": "bb",
 "mtproxy-client/builds/tg-mtproxy-client-linux-arm64": "cc"
}}
JSON

ZAPRET2_DIR="$SB"
Z2K_AU_TMP_DIR="$SB/tmp"
Z2K_AU_SBIN="$SB/sbin"
# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$ROOT/lib/auto_update.sh" >/dev/null 2>&1

# Заглушки — после подключения, иначе их затрёт сам модуль.
au_log() { printf '%s\n' "$1" >> "$SB/log"; }
au_gen_libs_source() { return 0; }
au_bin_goarch() { echo arm64; }
au_manifest_file_sha() { echo "aa"; }
# Сумма только у существующего файла: у отсутствующего её быть не может, а
# заглушка, отдающая её всегда, заставляла код решить «обновлять нечего».
z2k_sha256_file() { [ -f "$1" ] && echo "aa" || echo ""; }
au_download_repo_file() { printf 'бинарник\n' > "$2"; printf '%s\n' "$1" >> "$SB/скачано"; return 0; }
au_service_for_binary() { echo ""; }
is_running() { return 1; }

: > "$SB/log"; : > "$SB/скачано"
au_step_refresh_binaries >/dev/null 2>&1

# --- 1. z2k-detect обязан появиться ------------------------------------------
if [ -f "$SB/sbin/z2k-detect" ]; then
    ok "отсутствующий z2k-detect поставлен"
else
    bad "z2k-detect не поставлен — механизм не заработает ни при каком числе выпусков"
fi

# --- 2. WARP по-прежнему не тащим --------------------------------------------
# Семь мегабайт тому, кто кнопку не нажимал, — это не забота, а самоуправство.
if [ -f "$SB/sbin/z2k-warpd" ]; then
    bad "движок WARP приехал без спроса"
else
    ok "необязательный z2k-warpd не ставится"
fi

# --- 3. Причина названа в журнале --------------------------------------------
grep -q "базовый компонент" "$SB/log" \
    && ok "в журнале видно, почему файл поставлен" \
    || bad "поставили молча — в следующий раз разбирать будет нечего"

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
