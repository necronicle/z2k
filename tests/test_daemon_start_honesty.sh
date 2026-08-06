#!/bin/sh
# test_daemon_start_honesty.sh
#
# Контракт: init НЕ имеет права рапортовать «zapret2 service started», если
# демон не поднялся. До 2026-08-06 start_daemons и start() возвращали
# захардкоженный 0, поэтому «ERROR: Daemon 1 failed to start» и «service
# started» печатались подряд, а веб-панель показывала зелёное «работает» при
# мёртвом обходе (полевой случай: юзер видит отказ в консоли и успех в панели).
#
# Тест вырезает из S99zapret2.new реальные функции (не копию!) и прогоняет их
# на заглушках, поэтому расхождение кода и теста невозможно.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
INIT="${Z2K_INIT:-$HERE/files/S99zapret2.new}"
TMP="${TMPDIR:-/tmp}/z2k-daemon-honesty.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }
check(){ # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "ждали '$2', получили '$3'"; fi
}

# Вырезать тело функции по имени: от `^name()` до строки `^}`.
extract() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)" { inside=1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$INIT"
}

for fn in z2k_daemon_fail_reset z2k_daemon_fail_note z2k_daemon_fail_count start_daemons start; do
    extract "$fn" > "$TMP/$fn.sh"
    if [ ! -s "$TMP/$fn.sh" ]; then
        bad "извлечение $fn из S99zapret2.new" "функция не найдена"
        printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
        exit 1
    fi
done
ok "все проверяемые функции извлечены из S99zapret2.new"

# Общий пролог: заглушки всего, что start()/start_daemons дёргают наружу.
cat > "$TMP/prelude.sh" <<'PRELUDE'
Z2K_DAEMON_FAIL_FILE="$TMPDIR_T/.fails"
ENABLED=1
INIT_APPLY_FW=0
load_modules() { return 0; }
start_fw() { return 0; }
ensure_autohostlist_files() { return 0; }
sync_autohostlist_to_rkn() { return 0; }
ensure_traffic_debug_files() { return 0; }
traffic_debug_prepare() { return 0; }
traffic_debug_enable_nfqws2_log() { return 0; }
traffic_debug_tcpdump_start() { return 0; }
ensure_autocircular_files() { return 0; }
custom_runner() { return 0; }
repair_autocircular_files_after_daemon_start() { return 0; }
PRELUDE

# Пишет вывод в $TMP/last_out и код возврата в $TMP/last_rc. Ничего не печатает
# и НЕ вызывается в `$(...)`: иначе счётчики PASS/FAIL инкрементировались бы в
# subshell и молча терялись (на этом тест и поймал сам себя при написании).
run_case() {
    # run_case <standard_mode_daemons-body>
    _smd="$1"
    {
        printf 'TMPDIR_T=%s\n' "$TMP"
        cat "$TMP/prelude.sh"
        printf 'standard_mode_daemons() { %s }\n' "$_smd"
        cat "$TMP/z2k_daemon_fail_reset.sh" "$TMP/z2k_daemon_fail_note.sh" \
            "$TMP/z2k_daemon_fail_count.sh" "$TMP/start_daemons.sh" "$TMP/start.sh"
        printf 'start\n'
    } > "$TMP/case.sh"
    sh "$TMP/case.sh" > "$TMP/last_out" 2>&1
    echo $? > "$TMP/last_rc"
}

echo "--- демоны поднялись: успех, как и раньше ---"
run_case 'return 0;'
check "здоровый старт: код возврата" "0" "$(cat "$TMP/last_rc")"
out=$(cat "$TMP/last_out")
if printf '%s' "$out" | grep -q "zapret2 service started"; then
    ok "здоровый старт: печатает 'service started'"
else
    bad "здоровый старт: печатает 'service started'" "не найдено в выводе"
fi

echo "--- демон упал: НЕ рапортовать успех ---"
run_case 'z2k_daemon_fail_note 1; return 0;'
check "провал демона: код возврата" "1" "$(cat "$TMP/last_rc")"
out=$(cat "$TMP/last_out")
if printf '%s' "$out" | grep -q "zapret2 service started"; then
    bad "провал демона: НЕ должно быть 'service started'" "строка присутствует — панель снова покажет зелёное"
else
    ok "провал демона: 'service started' не печатается"
fi
if printf '%s' "$out" | grep -q "NOT started"; then
    ok "провал демона: явное сообщение об отказе"
else
    bad "провал демона: явное сообщение об отказе" "нет строки 'NOT started'"
fi
if printf '%s' "$out" | grep -q "1 daemon(s) failed to start"; then
    ok "провал демона: назван счёт упавших"
else
    bad "провал демона: назван счёт упавших" "нет строки со счётом"
fi

echo "--- счётчик сбрасывается между запусками (нет залипания) ---"
# Оставляем «грязный» файл от прошлого прогона и стартуем здоровым сценарием:
# без reset'а старый провал навсегда заблокировал бы успешный старт.
printf '9\n' > "$TMP/.fails"
run_case 'return 0;'
check "старый провал не залипает: код возврата" "0" "$(cat "$TMP/last_rc")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
