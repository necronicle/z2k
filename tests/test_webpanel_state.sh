#!/bin/sh
# tests/test_webpanel_state.sh - webpanel rotator state mutation (freeze / manual
# select) + pool parsing. Sources webpanel/cgi/actions.sh as a function library
# and drives state_set / state_read against isolated tmp state files.
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected '%s', got '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    case "$3" in
        *"$2"*) TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1" ;;
        *)      TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: '%s' not in output\n" "$1" "$2" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- isolate state files ---
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
ZAPRET2_DIR="$SB/opt/zapret2"; export ZAPRET2_DIR
mkdir -p "$ZAPRET2_DIR"
STATE_FILE="$SB/state.tsv"
STATE_FILE_FALLBACK="$SB/fallback.tsv"

# Source the function library (defines state_set/state_read/pools_read/etc).
. "$SCRIPT_DIR/webpanel/cgi/actions.sh" 2>/dev/null
# Re-pin the file paths AFTER sourcing (actions.sh sets defaults from ZAPRET2_DIR).
STATE_FILE="$SB/state.tsv"
STATE_FILE_FALLBACK="$SB/fallback.tsv"

# helper: field N of the state_read row matching key+host
row_field() {
    state_read | awk -F'\t' -v k="$1" -v h="$2" -v n="$3" '$1==k && $2==h {print $n}'
}

printf "\n--- state_set: manual select (auto) ---\n"
state_set rkn_tcp example.com 2 auto
assert_eq "set auto: strategy persisted"        "2"    "$(row_field rkn_tcp example.com 3)"
assert_eq "set auto: mode=auto persisted"       "auto" "$(row_field rkn_tcp example.com 5)"

printf "\n--- state_set: freeze ---\n"
state_set discord_udp nohost 3 frozen
assert_eq "freeze: strategy persisted"          "3"      "$(row_field discord_udp nohost 3)"
assert_eq "freeze: mode=frozen persisted"       "frozen" "$(row_field discord_udp nohost 5)"

printf "\n--- state_set: upsert replaces (no duplicate row) ---\n"
state_set discord_udp nohost 5 auto
COUNT=$(state_read | awk -F'\t' '$1=="discord_udp" && $2=="nohost"' | wc -l | tr -d ' ')
assert_eq "upsert: exactly one discord row"     "1"    "$COUNT"
assert_eq "upsert: new strategy"                "5"    "$(row_field discord_udp nohost 3)"
assert_eq "upsert: new mode"                    "auto" "$(row_field discord_udp nohost 5)"

printf "\n--- state_set: validation ---\n"
state_set rkn_tcp host 1 bogus  2>/dev/null; assert_eq "reject bad mode"       "1" "$?"
state_set rkn_tcp host abc auto 2>/dev/null; assert_eq "reject non-numeric"    "1" "$?"
state_set rkn_tcp host 0 auto   2>/dev/null; assert_eq "reject strategy 0"     "1" "$?"
state_set "bad key" host 1 auto 2>/dev/null; assert_eq "reject bad key chars"  "1" "$?"
# Host validation uses _chars_ok (tr), which works on busybox/dash/bash alike —
# so these reject portably (the old [!...|-] glob silently accepted everything).
state_set rkn_tcp 'h;rm'   1 auto   2>/dev/null; assert_eq "reject bad host chars"   "1" "$?"
state_set rkn_tcp 'a&b'    1 auto   2>/dev/null; assert_eq "reject host metachar"    "1" "$?"
state_set rkn_tcp 'host|4' 1 frozen 2>/dev/null; assert_eq "accept host|fam suffix"  "0" "$?"

printf "\n--- state_read tolerates a legacy 4-column row ---\n"
printf '# h\n# h2\nyt_tcp\tyoutube.com\t4\t1000\n' > "$STATE_FILE"
: > "$STATE_FILE_FALLBACK"
assert_eq "legacy 4-col read: strategy" "4" "$(row_field yt_tcp youtube.com 3)"

# ------------------------------------------------------------------------------
# pools_read — считает РАЗНЫЕ strategy=N на каждый circular-ключ.
#
# Здесь исполняется НАСТОЯЩАЯ функция панели, а не её копия. Копия жила в этом
# файле годами и проверяла сама себя: правку в actions.sh она бы не заметила.
# А правка случилась — арсенал переехал в блок --template, и наивный подсчёт
# по сырым токенам стал давать ноль у профилей, которые его импортируют.
# ------------------------------------------------------------------------------
printf "\n--- pools_read: distinct strategy count per key ---\n"

mk_cfg() {   # $1 — тело NFQWS2_OPT
    CONFIG_FILE="$SB/config"
    {
        printf '# комментарий, в котором встречается слово --template и --import\n'
        printf 'NFQWS2_OPT="\n%s\n"\n' "$1"
    } > "$CONFIG_FILE"
}

# 1) Плоский конфиг — как было до шаблонов.
mk_cfg '--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --lua-desync=fake:strategy=1 --lua-desync=split:strategy=2 --lua-desync=fake:strategy=2 --new
--filter-udp=50000 --lua-desync=circular:fails=3:key=discord_udp:nld=2:hostkey=z2k_nohost_key --lua-desync=fake:strategy=1 --lua-desync=fake:strategy=2 --lua-desync=fake:strategy=3'
POOLS=$(pools_read)
assert_contains "pools (плоский): rkn_tcp=2"     "rkn_tcp	2"     "$POOLS"
assert_contains "pools (плоский): discord_udp=3" "discord_udp	3" "$POOLS"

# 2) Шаблон + импорт: два профиля делят один арсенал, у каждого свой ключ.
mk_cfg '--template=z2k_rkn_arsenal --lua-desync=fake:strategy=1 --lua-desync=split:strategy=2 --lua-desync=fake:strategy=2 --new
--filter-tcp=443 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --import=z2k_rkn_arsenal --new
--filter-tcp=443 --ipset=/tmp/cf.txt --lua-desync=circular:fails=3:key=cf_extra:nld=2 --import=z2k_rkn_arsenal --new
--filter-udp=50000 --lua-desync=circular:fails=3:key=discord_udp:nld=2:hostkey=z2k_nohost_key --lua-desync=fake:strategy=1 --lua-desync=fake:strategy=2 --lua-desync=fake:strategy=3'
POOLS=$(pools_read)
assert_contains "pools (шаблон): rkn_tcp=2"     "rkn_tcp	2"     "$POOLS"
assert_contains "pools (шаблон): cf_extra=2"    "cf_extra	2"    "$POOLS"
assert_contains "pools (шаблон): discord_udp=3" "discord_udp	3" "$POOLS"
# Сам шаблон не должен превратиться в пул: у него нет своего ключа.
case "$POOLS" in
    *z2k_rkn_arsenal*) printf '[FAIL] шаблон попал в список пулов\n'; TESTS_FAILED=$((TESTS_FAILED+1)) ;;
    *) printf '[PASS] шаблон не считается пулом\n'; TESTS_PASSED=$((TESTS_PASSED+1)) ;;
esac
rm -f "$CONFIG_FILE"

printf "\n--- возраст страты: метка живёт, пока живёт стратегия ---\n"
# ЗАЧЕМ. Замечание пользователя: «страта работает сутки, жму замок — счётчик
# обнуляется, снимаю замок — снова обнуляется. Не ясно, сколько страта была
# живой». Метка означает «когда эта стратегия стала текущей», а не «когда по
# строке кликнули». Lua это правило уже держит (z2k-state-persist.lua:
# `if prev == n then return false end`), панель его нарушала.
rm -f "$STATE_FILE" "$STATE_FILE_FALLBACK"
state_set rkn_tcp age.example 7 auto
TS0=$(awk -F'\t' '$1=="rkn_tcp" && $2=="age.example" { print $4 }' "$STATE_FILE")

# Состариваем строку на сутки, как в жалобе.
DAY_AGO=$((TS0 - 86400))
awk -F'\t' -v OFS='\t' -v d="$DAY_AGO" '
    $1=="rkn_tcp" && $2=="age.example" { $4=d } { print }
' "$STATE_FILE" > "$STATE_FILE.aged" && mv "$STATE_FILE.aged" "$STATE_FILE"
awk -F'\t' -v OFS='\t' -v d="$DAY_AGO" '
    $1=="rkn_tcp" && $2=="age.example" { $4=d } { print }
' "$STATE_FILE_FALLBACK" > "$STATE_FILE_FALLBACK.aged" \
    && mv "$STATE_FILE_FALLBACK.aged" "$STATE_FILE_FALLBACK"

# Замок на ТОЙ ЖЕ стратегии — возраст обязан уцелеть.
state_set rkn_tcp age.example 7 frozen
TS_FROZEN=$(awk -F'\t' '$1=="rkn_tcp" && $2=="age.example" { print $4 }' "$STATE_FILE")
assert_eq "замок не обнуляет возраст" "$DAY_AGO" "$TS_FROZEN"
assert_contains "но режим переключился" "age.example	7	$DAY_AGO	frozen" "$(cat "$STATE_FILE")"

# Разморозка — тоже смена только режима.
state_set rkn_tcp age.example 7 auto
TS_THAWED=$(awk -F'\t' '$1=="rkn_tcp" && $2=="age.example" { print $4 }' "$STATE_FILE")
assert_eq "разморозка не обнуляет возраст" "$DAY_AGO" "$TS_THAWED"

# А вот смена номера — обязана обнулить: пошёл отсчёт другой стратегии.
state_set rkn_tcp age.example 8 auto
TS_NEW=$(awk -F'\t' '$1=="rkn_tcp" && $2=="age.example" { print $4 }' "$STATE_FILE")
if [ "$TS_NEW" -gt "$DAY_AGO" ] 2>/dev/null; then
    printf '[PASS] смена стратегии начинает отсчёт заново\n'; TESTS_PASSED=$((TESTS_PASSED+1))
else
    printf '[FAIL] смена стратегии начинает отсчёт заново (метка осталась %s)\n' "$TS_NEW"
    TESTS_FAILED=$((TESTS_FAILED+1))
fi

# Оба файла обязаны нести ОДНУ метку: читатели склеивают их по «свежее
# побеждает», и расхождение показало бы возраст то одной строки, то другой.
TS_P=$(awk -F'\t' '$1=="rkn_tcp" && $2=="age.example" { print $4 }' "$STATE_FILE")
TS_F=$(awk -F'\t' '$1=="rkn_tcp" && $2=="age.example" { print $4 }' "$STATE_FILE_FALLBACK")
assert_eq "основной файл и запасной несут одну метку" "$TS_P" "$TS_F"

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Results: %d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
