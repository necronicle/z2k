#!/bin/sh
# tests/test_updater_resources_itself.sh — после раскладки апдейтер обязан
# перечитать свой файл, иначе шаги исполняет код ПРОШЛОГО выпуска.
#
# Повод: 05.09.2026. Обновление применяет апдейтер, лежавший на роутере до
# него. Правка в lib/auto_update.sh поэтому не работает в том выпуске, который
# её привозит (так сгорел p-67.9). Хуже: на следующий прогон версии совпадают,
# апдейтер отвечает «обновление не нужно» и шагов не запускает вовсе — значит
# исправленный шаг не отработает никогда, пока не выйдет ещё один выпуск,
# объявляющий тот же шаг.
#
# Первая половина теста доказывает САМУ СЕМАНТИКУ, на которую опирается
# правка: функция, переопределённая во время собственного исполнения,
# доигрывает старым телом, а последующие вызовы уходят в новое. Это поведение
# dash и busybox ash, и полагаться на него без доказательства нельзя.
# POSIX sh (busybox ash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/z2k-resrc-$$"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP" || exit 1

# --- 1. семантика: переопределение на ходу -----------------------------------
cat > "$TMP/v1.sh" <<'V1'
step() { echo "шаг-старый"; }
driver() {
    . "$LIB2"
    step
    echo "драйвер-доиграл-старым"
}
V1
cat > "$TMP/v2.sh" <<'V2'
step() { echo "шаг-новый"; }
driver() { echo "драйвер-новый-НЕ-ДОЛЖЕН-ЗВУЧАТЬ"; }
V2

for sh_bin in sh dash busybox; do
    case "$sh_bin" in
        busybox) command -v busybox >/dev/null 2>&1 || continue; run="busybox sh" ;;
        dash)    command -v dash    >/dev/null 2>&1 || continue; run="dash" ;;
        *)       run="sh" ;;
    esac
    # Пути — переменными окружения, а не позиционно: аргументы после `sh -c`
    # переживают не всякую оболочку роутера, и tests/test_router_shell_portability.sh
    # держит это правило для всех наборов.
    out=$(LIB1="$TMP/v1.sh" LIB2="$TMP/v2.sh" $run -c '. "$LIB1"; driver' 2>&1)
    got_new_step=$(echo "$out" | grep -c 'шаг-новый')
    finished_old=$(echo "$out" | grep -c 'драйвер-доиграл-старым')
    if [ "$got_new_step" -eq 1 ] && [ "$finished_old" -eq 1 ]; then
        ok "$run: после source вызовы идут в новый код, текущая функция доигрывает старым"
    else
        bad "$run: семантика не та — вывод: $(echo "$out" | tr '\n' '/')"
    fi
done

# --- 2. апдейтер действительно перечитывает себя ДО шагов --------------------
AU="$ROOT/lib/auto_update.sh"
body=$(awk '/^au_apply_converge\(\) \{/{f=1} f{print} f && /^}/{exit}' "$AU")
if [ -z "$body" ]; then
    bad "не нашёл au_apply_converge"
else
    resrc=$(echo "$body" | grep -n '_ac_self' | head -1 | cut -d: -f1)
    steps=$(echo "$body" | grep -n 'au_run_steps' | head -1 | cut -d: -f1)
    if [ -n "$resrc" ] && [ -n "$steps" ] && [ "$resrc" -lt "$steps" ]; then
        ok "au_apply_converge перечитывает свой файл ДО запуска шагов"
    else
        bad "au_apply_converge не перечитывает себя перед шагами (шаги исполнит код прошлого выпуска)"
    fi
fi

# Битый файл не должен переопределять половину функций.
if echo "$body" | grep -q 'sh -n "\$_ac_self"'; then
    ok "перед source проверяется разбор файла"
else
    bad "нет проверки разбора перед source — битый файл оставит смесь двух версий"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
