#!/bin/sh
# tests/test_tcp16_chain_wiring.sh — цепочка обхода по объёму целиком: от
# доставки бинарника до применения имени.
#
# Повод: r-81.1 … r-81.4. Каждый выпуск чинил одно звено, а рвалось следующее:
#   вето валидатора → порядок «конфиг раньше пробы» → шаг очистки без функции →
#   проба искала бинарник не по тому пути → сборок вовсе не было в манифесте.
# Общее у всех: ломалась СВЯЗКА, а тесты проверяли отдельные детали.
#
# Здесь сторожатся все звенья разом, и каждое — исполняемой или предметной
# проверкой, а не совпадением строки.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$DIR/files/z2k-tcp16-probe.sh"
MANIFEST="$DIR/UPDATES.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

# --- 1. Бинарник ищется там, куда его кладёт установщик ----------------------
# Установщик кладёт в /opt/sbin; проба искала в каталоге обхода, и у КАЖДОГО
# пользователя падала первой строкой «нет /opt/zapret2/z2k-detect».
#
# Проверяем УМОЛЧАНИЕ, не подсовывая его через окружение: первая же версия
# этой проверки задавала DETECT_DIRS сама и потому не проверяла ничего.
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
DIRS=$(ZAPRET2_DIR="$SB" sh -c "
    unset DETECT_DIRS DETECT
    $(sed -n '/^DETECT_DIRS=/,/^fi$/p' "$PROBE")
    printf '%s' \"\$DETECT_DIRS\"")
case "$DIRS" in
    /opt/sbin*) ok "по умолчанию бинарник ищется сперва в /opt/sbin" ;;
    *) bad "умолчание не смотрит в /opt/sbin: [$DIRS]" ;;
esac

# --- 2. Сборки попадут в карту сумм -----------------------------------------
# Шаг refresh-binaries берёт список ИЗ карты сумм: чего там нет, то у людей не
# обновляется никогда. Карту пересобирает только скрипт выпуска, поэтому между
# релизами она законно отстаёт — проверяем ПРАВИЛО в генераторе, а совпадение
# самой карты гейтит выпуск (scripts/release.sh).
grep -q 'z2k-detect/builds/\*' "$DIR/scripts/gen_file_hashes.sh" \
    && ok "генератор вносит сборки z2k-detect в карту сумм" \
    || bad "генератор не вносит сборки z2k-detect — refresh-binaries их не обновит"

grep -q 'refresh-binaries не обновит их у людей' "$DIR/scripts/release.sh" \
    && ok "выпуск не состоится, если сборок нет в карте" \
    || bad "в выпуске нет гейта на состав сборок"

# --- 3. MIPS: Go-бинарник без этого флага падает ----------------------------
# Проверяем ЗАПУСКОМ, а не грепом: строка GODEBUG есть и в комментарии, и
# первая версия этой проверки проходила даже с вырезанным кодом.
mkdir -p "$SB/lists" "$SB/state"
cat > "$SB/detect" <<'STUB'
#!/bin/sh
printf '%s\n' "$GODEBUG" > "$SBDIR/env.seen"
exit 0
STUB
chmod +x "$SB/detect"
printf 'T1\t24940\t*\tHetzner\t192.0.2.1\t443\n' > "$SB/lists/tcp16_targets.txt"
printf 'example.com\n' > "$SB/lists/sni_wl_candidates.txt"
SBDIR="$SB" DETECT="$SB/detect" ZAPRET2_DIR="$SB" \
    TARGETS="$SB/lists/tcp16_targets.txt" CAND="$SB/lists/sni_wl_candidates.txt" \
    LOG="$SB/probe.log" sh "$PROBE" >/dev/null 2>&1
if [ "$(cat "$SB/env.seen" 2>/dev/null)" = "asyncpreemptoff=1" ]; then
    ok "бинарник запускается с защитой для MIPS"
else
    bad "GODEBUG не передан бинарнику: [$(cat "$SB/env.seen" 2>/dev/null)] — на MIPS проба упадёт"
fi

# --- 4. Шаги обновления не зависят от того, кто их позвал --------------------
# На неявной зависимости от utils.sh уже молчал шаг очистки записей.
for st in au_step_cleanup_ip_hosts au_step_refresh_binaries; do
    if sed -n "/^$st()/,/^}/p" "$DIR/lib/auto_update.sh" | grep -q 'au_gen_libs_source'; then
        ok "$st подключает библиотеки сам"
    else
        bad "$st полагается на вызывающего — повторится молчаливый пропуск"
    fi
done

# --- 5. Все файлы механизма доставляются ------------------------------------
SHA_BLOCK=$(awk '/"files_sha256"/{f=1} f{print} f&&/^  }/{exit}' "$MANIFEST")
MISS=""
for f in files/z2k-tcp16-probe.sh files/lists/tcp16_targets.txt \
         files/lists/tcp16_nets.txt files/lists/sni_wl_candidates.txt \
         files/lua/z2k-alert.lua files/z2k-config-validator.sh; do
    printf '%s' "$SHA_BLOCK" | grep -q "\"$f\"" || MISS="$MISS $f"
done
[ -z "$MISS" ] && ok "все файлы механизма объявлены к доставке" \
               || bad "не доставляются:$MISS"

# --- 6. Устаревший бинарник проба чинит сама --------------------------------
# Шаг refresh-binaries выполняется, только если релиз его объявил, а объявляется
# он по изменению сборок. Полагаться на «кто-то не забудет» уже нельзя: четыре
# выпуска подряд бинарник у людей оставался прежним, без команды tcp16, и
# механизм молчал. Проверяем запуском: подставной бинарник, не знающий tcp16,
# обязан привести к вызову обновления.
mkdir -p "$SB/heal/lib" "$SB/heal/state" "$SB/heal/lists"
cat > "$SB/heal/detect" <<'STUB'
#!/bin/sh
[ "$1" = "tcp16" ] && [ -f "$SBDIR/heal/upgraded" ] && exit 0
[ "$1" = "tcp16" ] && exit 2
exit 0
STUB
chmod +x "$SB/heal/detect"
printf 'au_fetch_manifest() { :; }
au_step_refresh_binaries() { : > "$SBDIR/heal/upgraded"; }
'     > "$SB/heal/lib/auto_update.sh"
: > "$SB/heal/lib/utils.sh"
printf 'T1\t24940\t*\tHetzner\t192.0.2.1\t443\n' > "$SB/heal/lists/tcp16_targets.txt"
printf 'example.com\n' > "$SB/heal/lists/sni_wl_candidates.txt"
SBDIR="$SB" DETECT="$SB/heal/detect" ZAPRET2_DIR="$SB/heal" \
    TARGETS="$SB/heal/lists/tcp16_targets.txt" CAND="$SB/heal/lists/sni_wl_candidates.txt" \
    LOG="$SB/heal/probe.log" sh "$PROBE" >/dev/null 2>&1
[ -f "$SB/heal/upgraded" ] \
    && ok "устаревший бинарник проба обновляет сама" \
    || bad "проба не пытается обновить бинарник — механизм останется мёртвым"

# --- 6. Проба замыкает петлю: сама пересобирает конфиг -----------------------
# Иначе флаг появляется после пересборки, и механизм не попадает в конфиг —
# ровно то, из-за чего r-81.1 «установился и молчал».
grep -q 'create_official_config' "$PROBE" \
    && ok "проба пересобирает конфиг после измерения" \
    || bad "проба не пересобирает конфиг — механизм не включится до следующего раза"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
