#!/bin/sh
# Пропажа игрового списка у апстрима не должна выглядеть как поломка у нас.
#
# ЧТО БЫЛО В ПОЛЕ (диагностика 31.08.2026, r-81.6). Апстрим ru-gaming-blocklist
# перечисляет в индексе три игры, файлов под которые нет. Мягкое сообщение для
# этого случая существовало, но включалось только по признакам «все зеркала
# ответили 404» либо «авторитетный слой ответил 404». У человека слой 0 был
# выключен на прогон, прямой raw не ответил — ни одного признака не набралось,
# и каждую ночь в журнал уходило три строки «FAIL: all mirrors failed». Дальше
# они всплывали в диагностике под «errors across all logs», и человек шёл в
# поддержку с поломкой, которой нет.
#
# Правило: состав игровых списков задаёт ЧУЖОЙ живой репозиторий. Исчезновение
# игры — новость, а не отказ. Итог прогона держит сводная строка.
#
# Тест исполняемый: гоняет НАСТОЯЩИЙ update_list и настоящий update_warp_game_list.
TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

Z2K_UL_SOURCE_ONLY=1
export Z2K_UL_SOURCE_ONLY
# shellcheck disable=SC1091
. "$SCRIPT_DIR/files/z2k-update-lists.sh"

ZAPRET2_DIR="$SB/opt/zapret2"
LOG_FILE="$SB/update-lists.log"
mkdir -p "$ZAPRET2_DIR/lists/warp/games"

INDEX="$SB/sources.json"
# Воспроизводим ровно ту обстановку, в которой рождался ложный FAIL:
# ни «все ответили 404», ни «авторитетный 404» — зеркало моргнуло, слой 0 выключен.
z2k_fetch() {
    Z2K_FETCH_ALL_404=0
    Z2K_FETCH_AUTH_404=0
    case "$1" in
        *sources.json) cp -f "$INDEX" "$2" 2>/dev/null; return 0 ;;
        *) return 1 ;;
    esac
}

printf '{\n "output": {"games_dir": "games"},\n "game_map": {\n  "GearsOfWar": ["hint"],\n  "Steam": ["hint"]\n },\n "domain_game_hints": {}\n}\n' > "$INDEX"

# --- 1. Настоящий прогон обновления игровых списков ---------------------------
: > "$LOG_FILE"
update_warp_game_list >/dev/null 2>&1
assert_eq "исчезнувшая игра не пишется как FAIL" "0" \
    "$(grep -c 'FAIL: download warp-game' "$LOG_FILE")"
assert_eq "вместо этого — понятная строка" "2" \
    "$(grep -c 'у апстрима нет или недоступен, пропускаю' "$LOG_FILE")"

# --- 2. Обычные списки глушить НЕЛЬЗЯ ----------------------------------------
# Тот же отказ на списке РКН обязан остаться ошибкой: там пропажа означает, что
# у людей протухнет обход, и молчать об этом нельзя.
: > "$LOG_FILE"
update_list "rkn-list" "https://example.invalid/list.txt" "$SB/rkn.txt" >/dev/null 2>&1
assert_eq "отказ на списке РКН остаётся ошибкой" "1" \
    "$(grep -c 'FAIL: download rkn-list' "$LOG_FILE")"

# --- 3. Флаг не должен протекать за пределы игрового цикла -------------------
# Он объявлен local внутри update_warp_game_list; ash делает local видимым
# вызываемым функциям, но не соседним вызовам в том же прогоне.
: > "$LOG_FILE"
update_warp_game_list >/dev/null 2>&1
update_list "rkn-list" "https://example.invalid/list.txt" "$SB/rkn.txt" >/dev/null 2>&1
assert_eq "после игрового цикла ошибки снова печатаются" "1" \
    "$(grep -c 'FAIL: download rkn-list' "$LOG_FILE")"

printf "\nPASSED: %s\nFAILED: %s\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" = 0 ]
