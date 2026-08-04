#!/bin/sh
# tests/test_migrate_austerus.sh — поведение migrate_drop_austerus_mode().
#
# Режим Austerusj (all_tcp443.conf) снят 2026-08-04. Он был опасен тем, что
# закорачивал ВСЮ генерацию конфига: роутер получал три строки стратегий из
# Zapret1 без хостлистов, без circular-ротации и без --hostlist-exclude=
# whitelist.txt. Включить или выключить его из интерфейса было нельзя с
# 2026-04-15, а файл лежит в /opt/etc/zapret2 и переживал каждый reinstall
# (тот меняет /opt/zapret2).
#
# Здесь проверяется САМА функция, а не наличие строк в исходнике: именно она
# отработает на роутерах. Функция вытаскивается из lib/install.sh по имени со
# сопоставлением скобок и исполняется со стабами — сорсить install.sh целиком
# нельзя, он тянет за собой пол-установщика.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k_austerus.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '[FAIL] %s\n      ожидалось: %s\n      получено: %s\n' "$1" "$2" "$3"; }

# Вытащить функцию по имени, считая фигурные скобки.
FN=$(awk '
    /^migrate_drop_austerus_mode\(\)/ { grab=1 }
    grab {
        print
        n = gsub(/\{/, "{"); depth += n
        n = gsub(/\}/, "}"); depth -= n
        if (depth == 0 && seen) exit
        if (depth > 0) seen = 1
    }
' "$ROOT/lib/install.sh")

if [ -z "$FN" ]; then
    printf '[FAIL] migrate_drop_austerus_mode() не найдена в lib/install.sh\n'
    exit 1
fi

# Стабы: реальный safe_config_read живёт в utils.sh, но тащить весь utils.sh
# ради одной функции незачем — поведение читателя тривиально и здесь важна
# логика самой миграции, а не парсинг conf.
safe_config_read() {
    _k=$1; _f=$2; _d=$3
    [ -f "$_f" ] || { printf '%s' "$_d"; return 0; }
    _v=$(sed -n "s/^${_k}=\(.*\)$/\1/p" "$_f" 2>/dev/null | head -1)
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$_d"
}
print_warning() { printf 'WARN:%s\n' "$1"; }
print_info()    { printf 'INFO:%s\n' "$1"; }

eval "$FN"

# --- Случай 1: режим БЫЛ включён — файл сносится И человека предупреждают ---
CONFIG_DIR="$TMP/case1"; mkdir -p "$CONFIG_DIR"
printf 'ENABLED=1\nSTRATEGY=1\n' > "$CONFIG_DIR/all_tcp443.conf"
OUT=$(migrate_drop_austerus_mode 2>&1)

if [ ! -f "$CONFIG_DIR/all_tcp443.conf" ]; then
    ok "включённый режим: файл снесён"
else
    no "включённый режим: файл снесён" "файла нет" "файл на месте"
fi
case "$OUT" in
    *WARN:*Austerusj*) ok "включённый режим: человек предупреждён о смене поведения" ;;
    *) no "включённый режим: человек предупреждён о смене поведения" "WARN про Austerusj" "$OUT" ;;
esac

# --- Случай 2: режим был выключен — файл всё равно сносится, но МОЛЧА ---
# Мёртвый файл с ENABLED=0 мы же и создавали при каждой установке; пугать им
# человека незачем, а оставлять нельзя — откат на старую версию подхватит его.
CONFIG_DIR="$TMP/case2"; mkdir -p "$CONFIG_DIR"
printf 'ENABLED=0\nSTRATEGY=1\n' > "$CONFIG_DIR/all_tcp443.conf"
OUT=$(migrate_drop_austerus_mode 2>&1)

if [ ! -f "$CONFIG_DIR/all_tcp443.conf" ]; then
    ok "выключенный режим: файл снесён"
else
    no "выключенный режим: файл снесён" "файла нет" "файл на месте"
fi
if [ -z "$OUT" ]; then
    ok "выключенный режим: молча, без лишнего шума"
else
    no "выключенный режим: молча, без лишнего шума" "пустой вывод" "$OUT"
fi

# --- Случай 3: чистый роутер — noop, без ошибок ---
CONFIG_DIR="$TMP/case3"; mkdir -p "$CONFIG_DIR"
OUT=$(migrate_drop_austerus_mode 2>&1); RC=$?
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
    ok "чистый роутер: noop с rc=0"
else
    no "чистый роутер: noop с rc=0" "rc=0, пустой вывод" "rc=$RC, out=$OUT"
fi

# --- Случай 4: идемпотентность — повторный прогон не падает ---
OUT=$(migrate_drop_austerus_mode 2>&1); RC=$?
if [ "$RC" = "0" ]; then
    ok "идемпотентно: повторный прогон rc=0"
else
    no "идемпотентно: повторный прогон rc=0" "rc=0" "rc=$RC"
fi

printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
[ "$FAIL" = "0" ]
