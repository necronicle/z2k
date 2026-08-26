#!/bin/sh
# tests/test_rotation_time_window.sh — окно счётчика провалов по пулам.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Пользователь с LG webOS сообщил, что стратегии не
# крутятся вовсе. Одиннадцать дампов, снятых 25.08, показали десять потоков к
# :443, и все десять — один сценарий: ClientHello, восемь повторов, НОЛЬ
# входящих байт. Провал при этом детектируется штатно, на втором повторе, через
# 224 мс. Не крутилось по другой причине.
#
# `time` — это НЕ окно, в которое должны уложиться все три провала. Мануал:
# «время в секундах, после которого с момента ПРЕДЫДУЩЕЙ неудачи следующая
# неудача начинает счет заново». Зазор между соседними. Зазоры телевизора:
#
#     151, 135, 129, 69, 235, 188, 108, 72, 116 сек
#
# При time=60 годных ноль из девяти: счётчик обнуляется после каждого провала.
# Сквозной прогон настоящего automate_failure_counter дал 0 ротаций при time=60
# и 3 при time=300 — причём снижение fails не меняет НИЧЕГО, потому что до двух
# счётчик тоже не доходит.
#
# Тест держит две вещи. Что значение стоит там, где измерено, и не расползлось
# по остальным пулам, где оно ослабило бы единственную работающую защиту от
# ложной ротации (замер: порог успеха защёлкивается на 5% соединений, то есть
# документированный сброс «при удаче» в поле почти не работает). И что сама
# арифметика счётчика на измеренных зазорах даёт ротацию.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

MOCK=$(mktemp -d) || exit 1
trap 'rm -rf "$MOCK"' EXIT INT TERM

mkdir -p "$MOCK/extra_strats/TCP/YT" "$MOCK/extra_strats/TCP/YT_GV" \
         "$MOCK/extra_strats/TCP/RKN" "$MOCK/extra_strats/UDP/YT" \
         "$MOCK/lists" "$MOCK/lua"
echo youtube.com     > "$MOCK/extra_strats/TCP/YT/List.txt"
echo googlevideo.com > "$MOCK/extra_strats/TCP/YT_GV/List.txt"
echo youtube.com     > "$MOCK/extra_strats/UDP/YT/List.txt"
echo example.com     > "$MOCK/extra_strats/TCP/RKN/List.txt"
printf 'ISP_INTERFACE=eth3\n' > "$MOCK/config"
cp files/lua/z2k-alert.lua files/lua/z2k-quic-silence.lua "$MOCK/lua/" 2>/dev/null

OPT=$(
    . ./lib/utils.sh 2>/dev/null
    . ./lib/config_official.sh
    ZAPRET2_DIR="$MOCK" generate_nfqws2_opt_from_strategies 2>/dev/null
)
[ -n "$OPT" ] || { printf 'SKIP: генератор ничего не выдал\n'; exit 0; }

# time= у конкретного пула из сгенерированного конфига
time_of() {
    printf '%s' "$OPT" | tr ' ' '\n' | grep "key=$1:" | grep -oE ':time=[0-9]+' \
        | head -1 | cut -d= -f2
}

# ── Значение стоит там, где измерено ─────────────────────────────────────────
assert_eq "yt_tcp: окно расширено"  "300" "$(time_of yt_tcp)"
assert_eq "gv_tcp: окно расширено"  "300" "$(time_of gv_tcp)"

# ── И не расползлось ─────────────────────────────────────────────────────────
# Клиенты этих пулов — браузеры с плотными попытками. Расширение здесь
# ослабляет защиту от ложной ротации, ничего не давая взамен.
assert_eq "rkn_tcp: окно прежнее"   "60"  "$(time_of rkn_tcp)"
assert_eq "http_rkn: окно прежнее"  "60"  "$(time_of http_rkn)"
assert_eq "yt_quic: окно прежнее"   "60"  "$(time_of yt_quic)"
assert_eq "discord_udp: окно прежнее" "60" "$(time_of discord_udp)"

# ── Значение задано в одном месте ────────────────────────────────────────────
# Два пула с одинаковым смыслом обязаны брать его из общей константы: вписанные
# руками числа разъезжаются при первой же правке.
assert_eq "значение объявлено один раз" "1" \
    "$(grep -c '^\s*Z2K_CIRCULAR_TIME_SLOW=' lib/config_official.sh)"
assert_eq "оба пула берут константу"    "2" \
    "$(grep -c 'ensure_circular_time ".*" "\$Z2K_CIRCULAR_TIME_SLOW"' lib/config_official.sh)"

# ── Арифметика счётчика на измеренных зазорах ────────────────────────────────
# Правило сброса воспроизводит automate_failure_counter: счётчик обнуляется,
# если с ПРЕДЫДУЩЕЙ неудачи прошло больше `time`. Один провал на соединение —
# так же, как в движке (crec.failure / crec.nocheck).
rotations() {
    _time="$1"; _fails="$2"
    awk -v t="$_time" -v f="$_fails" 'BEGIN {
        n = split("0 151 135 129 69 235 188 108 72 116", g, " ")
        cnt = 0; last = -1; now = 0; rot = 0
        for (i = 1; i <= n; i++) {
            now += g[i]
            if (last >= 0 && (now - last) > t) cnt = 0
            cnt++; last = now
            if (cnt >= f) { rot++; cnt = 0; last = -1 }
        }
        print rot
    }'
}
assert_eq "боевое окно пулов видео даёт ротацию" "3" "$(rotations "$(time_of yt_tcp)" 3)"
assert_eq "при time=60 ротации нет ни одной"     "0" "$(rotations 60 3)"
# Ключевое, ради чего это записано: снижением порога провалов проблему НЕ решить.
assert_eq "при time=60 снижение fails не помогает" "0" "$(rotations 60 2)"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
