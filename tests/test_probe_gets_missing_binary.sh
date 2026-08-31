#!/bin/sh
# tests/test_probe_gets_missing_binary.sh — проба обязана САМА достать бинарник,
# которого нет.
#
# ЧТО СЛУЧИЛОСЬ. Механизм не включался у людей три выпуска подряд. В их журналах
# стояло «нет /opt/zapret2/z2k-detect» и мгновенный выход: бинарника не было
# вовсе — сборки z2k-detect годами не попадали в карту сумм, и установка их не
# клала.
#
# Самолечение в пробе БЫЛО, но стояло НИЖЕ проверки на наличие файла, то есть
# срабатывало только для случая «бинарник есть, но старый». Случай «бинарника
# нет» до него не доходил никогда.
#
# А когда я поднял самолечение выше, оно всё равно ничего не сделало: оно звало
# au_step_refresh_binaries, а тот ПРИНЦИПИАЛЬНО не ставит отсутствующее — иначе
# тащил бы движок WARP на роутеры, где WARP не включали. Проверено на живом
# роутере: шаг отработал молча и не положил ничего.
#
# Поэтому проба тянет сборку сама, штатной загрузкой с проверкой суммы.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/files/z2k-tcp16-probe.sh"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT

# --- 1. Ветка «нет бинарника» ведёт к загрузке, а не к выходу -----------------
# Вырезаем блок добычи и смотрим на его СОДЕРЖИМОЕ: он обязан звать загрузчик
# файлов, а не шаг обновления бинарников.
blk=$(awk '/БИНАРНИКА НЕТ ВОВСЕ/,/^fi$/' "$PROBE")
[ -n "$blk" ] || bad "в пробе нет блока добычи бинарника"

case "$blk" in
    *au_download_repo_file*) ok "проба тянет сборку штатной загрузкой" ;;
    *) bad "проба не зовёт au_download_repo_file — доставать нечем" ;;
esac
case "$blk" in
    *au_step_refresh_binaries*) bad "проба зовёт au_step_refresh_binaries — он НЕ ставит отсутствующее" ;;
    *) ok "шаг refresh-binaries для этого случая не используется" ;;
esac
case "$blk" in
    *au_manifest_file_sha*) ok "сумма сборки берётся из манифеста" ;;
    *) bad "сборка ставится без сверки суммы" ;;
esac

# --- 2. Проверка наличия не стоит ПЕРЕД добычей -------------------------------
# Ровно это и ломало: `[ -x "$DETECT" ] || exit` выше самолечения.
early=$(awk '/^DETECT="\$\{DETECT:-/,/БИНАРНИКА НЕТ ВОВСЕ/' "$PROBE" | grep -c 'exit 2' || true)
if [ "${early:-0}" -eq 0 ]; then
    ok "до блока добычи проба не выходит по отсутствию бинарника"
else
    bad "перед добычей стоит ранний выход — случай «бинарника нет» до неё не дойдёт"
fi

# --- 3. Поведение целиком: бинарника нет, загрузчик подсунут ------------------
# Гоняем НАСТОЯЩУЮ пробу с подменёнными зависимостями: она обязана дойти до
# запуска движка, а не выйти на проверке.
mkdir -p "$SB/opt/zapret2/lib" "$SB/opt/zapret2/lists" "$SB/opt/zapret2/state" "$SB/sbin" "$SB/tmp"
cat > "$SB/opt/zapret2/lib/utils.sh" <<'LIB'
z2k_uint() { echo "${1:-$2}"; }
LIB
cat > "$SB/opt/zapret2/lib/auto_update.sh" <<LIB
au_fetch_manifest() { mkdir -p "\$Z2K_AU_TMP_DIR"; printf '{}' > "\$Z2K_AU_TMP_DIR/UPDATES.json"; return 0; }
au_bin_goarch() { echo arm64; }
au_manifest_file_sha() { echo "0000000000000000000000000000000000000000000000000000000000000000"; }
au_download_repo_file() {
    # изображаем скачанную сборку: она умеет tcp16 -h и печатает итог
    printf '#!/bin/sh\ncase "\$1\$2" in tcp16-h) exit 0 ;; esac\necho "ЗАПУЩЕН движок: \$*"\nexit 0\n' > "\$2"
    chmod 755 "\$2"
    return 0
}
LIB
printf 'example.com\n' > "$SB/opt/zapret2/lists/tcp16_targets.txt"
printf 'a.example\n'   > "$SB/opt/zapret2/lists/sni_wl_candidates.txt"

out=$(ZAPRET2_DIR="$SB/opt/zapret2" DETECT_DIRS="$SB/sbin" \
      Z2K_AU_TMP_DIR="$SB/tmp/z2k_au" \
      sh "$PROBE" 2>&1)
case "$out" in
    *"бинарника пробы нет"*) ok "проба сообщает, что бинарника нет" ;;
    *) bad "нет сообщения об отсутствии бинарника: $out" ;;
esac
case "$out" in
    *"достать бинарник не удалось"*) bad "проба сдалась вместо того, чтобы достать: $out" ;;
    *) ok "проба не сдаётся на отсутствии бинарника" ;;
esac

# --- 4. Без суммы в манифесте бинарник НЕ ставится ----------------------------
# Загрузчик сверяет байты, только когда сумма передана. С пустой он берёт что
# дали, а среди источников есть чужие зеркала. Речь про исполняемый файл,
# который потом запускается от root.
cat > "$SB/opt/zapret2/lib/auto_update.sh" <<LIB
au_fetch_manifest() { mkdir -p "\$Z2K_AU_TMP_DIR"; printf '{}' > "\$Z2K_AU_TMP_DIR/UPDATES.json"; }
au_bin_goarch() { echo arm64; }
au_manifest_file_sha() { echo ""; }
au_download_repo_file() { : > "\$SBDIR/скачано"; printf '#!/bin/sh\nexit 0\n' > "\$2"; chmod 755 "\$2"; }
LIB
rm -f "$SB/скачано"
SBDIR="$SB" ZAPRET2_DIR="$SB/opt/zapret2" DETECT_DIRS="$SB/sbin2" \
    Z2K_AU_TMP_DIR="$SB/tmp/au2" sh "$PROBE" >"$SB/out2" 2>&1
if [ -f "$SB/скачано" ]; then
    bad "бинарник скачан без суммы — это установка непроверенного исполняемого файла"
else
    ok "без суммы в манифесте загрузка не начинается"
fi
grep -q "не ставлю непроверенный" "$SB/out2" \
    && ok "причина названа в журнале" \
    || bad "молча отложили, не объяснив почему"

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
