#!/bin/sh
# tests/test_fastroute_retired.sh — маршрутный кэш (nf_conntrack_fastroute) больше
# не гасится, а заводская единица, снятая версиями до p-87.21, возвращается ровно
# один раз.
#
# С 18.09 по 07.11.2026 S99 ставил fastroute=0 там, где нет драйвера аппаратного
# NAT (портированная KeeneticOS на Cudy), и в панели был тумблер. Это оказалось
# заблуждением. Функции вытаскиваются из S99zapret2.new (extract_fn), каталог
# сисктлов, драйвера и состояния подменяются.
HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-$HERE/files/S99zapret2.new}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fastroute.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}
FNS="$TMP/fns.sh"
{
    extract_fn z2k_fastroute_retire_once "$INIT"; echo
    extract_fn z2k_conntrack_tune_start  "$INIT"; echo
    extract_fn z2k_conntrack_tune_stop   "$INIT"; echo
} > "$FNS"
for f in z2k_fastroute_retire_once z2k_conntrack_tune_start z2k_conntrack_tune_stop; do
    grep -q "^$f()" "$FNS" && ok "extracted $f()" || no "extracted $f()" "a definition" "none"
done

mk_sysctl() {
    rm -rf "$TMP/nf" "$TMP/z2k"; mkdir -p "$TMP/nf" "$TMP/z2k/state"
    echo 0 > "$TMP/nf/nf_conntrack_tcp_be_liberal"
    echo 1 > "$TMP/nf/nf_conntrack_checksum"
    echo 1 > "$TMP/nf/nf_conntrack_fastnat"
    echo 1 > "$TMP/nf/nf_conntrack_fastnat_xfrm"
    echo "$1" > "$TMP/nf/nf_conntrack_fastroute"
}
val() { cat "$TMP/nf/$1"; }
MARK="$TMP/z2k/state/fastroute-retired.done"

# run <hwnat_present 0|1> <fn>
run() {
    local hwdir="$TMP/hw_nat_absent"
    [ "$1" = "1" ] && { hwdir="$TMP/hw_nat"; mkdir -p "$hwdir"; }
    ( Z2K_NF_SYSCTL="$TMP/nf" Z2K_HWNAT_DIR="$hwdir" ZAPRET2_DIR="$TMP/z2k" sh -c ". \"$FNS\"; $2" ) >"$TMP/out" 2>&1
}

# 1. Заводское значение: старт его не трогает, fastnat гасится как раньше.
mk_sysctl 1; run 0 z2k_conntrack_tune_start
[ "$(val nf_conntrack_fastroute)" = 1 ] && ok "нет hw_nat: старт больше не гасит fastroute" || no "старт" 1 "$(val nf_conntrack_fastroute)"
[ "$(val nf_conntrack_fastnat)" = 0 ]   && ok "fastnat -> 0 как раньше"                    || no "fastnat" 0 "$(val nf_conntrack_fastnat)"

# 2. Наследство прежней версии: 0 на плате без драйвера возвращается в 1.
mk_sysctl 0; run 0 z2k_conntrack_tune_start
[ "$(val nf_conntrack_fastroute)" = 1 ] && ok "fastroute=0 от прежней версии возвращён в 1" || no "возврат" 1 "$(val nf_conntrack_fastroute)"
grep -q "fastroute=1" "$TMP/out" && ok "возврат записан в журнал старта" || no "журнал" "fastroute=1" "$(cat "$TMP/out")"
[ -f "$MARK" ] && ok "маркер поставлен" || no "маркер" present absent

# 3. Только один раз: ручной 0 после возврата не перетирается.
echo 0 > "$TMP/nf/nf_conntrack_fastroute"
( Z2K_NF_SYSCTL="$TMP/nf" Z2K_HWNAT_DIR="$TMP/hw_nat_absent" ZAPRET2_DIR="$TMP/z2k" sh -c ". \"$FNS\"; z2k_conntrack_tune_start" ) >/dev/null 2>&1
[ "$(val nf_conntrack_fastroute)" = 0 ] && ok "повторный старт не трогает ручной 0" || no "повтор" 0 "$(val nf_conntrack_fastroute)"

# 4. Драйвер аппаратного NAT есть: там мы fastroute не гасили и не возвращаем.
mk_sysctl 0; run 1 z2k_conntrack_tune_start
[ "$(val nf_conntrack_fastroute)" = 0 ] && ok "есть hw_nat: чужой 0 не тронут" || no "hw_nat" 0 "$(val nf_conntrack_fastroute)"

# 5. Стоп кэш не трогает.
mk_sysctl 1; run 0 z2k_conntrack_tune_stop
[ "$(val nf_conntrack_fastroute)" = 1 ] && ok "stop не трогает fastroute" || no "stop" 1 "$(val nf_conntrack_fastroute)"
mk_sysctl 0; run 0 z2k_conntrack_tune_stop
[ "$(val nf_conntrack_fastroute)" = 0 ] && ok "stop не пишет fastroute ни в какую сторону" || no "stop 0" 0 "$(val nf_conntrack_fastroute)"

# 6. Файла сисктла нет (старое ядро): старт не падает и ничего не создаёт.
mk_sysctl 1; rm -f "$TMP/nf/nf_conntrack_fastroute"; run 0 z2k_conntrack_tune_start
[ $? -eq 0 ] && ok "нет файла fastroute: старт возвращает 0" || no "нет файла" 0 "$?"
[ ! -e "$TMP/nf/nf_conntrack_fastroute" ] && ok "нет файла fastroute: не создан" || no "файл создан" "absent" "present"

# 7. Ни тумблера, ни ключа, ни маршрута API больше нет.
for f in webpanel/cgi/actions.sh webpanel/cgi/api.sh webpanel/www/js/pages/toggles.js lib/config_official.sh files/S99zapret2.new files/z2k-diag.sh; do
    n=$(grep -c 'Z2K_FASTROUTE_OFF\|toggle_fastroute\|toggle/fastroute\|fastroute_snapshot' "$HERE/$f")
    [ "$n" = 0 ] && ok "$f: следов тумблера нет" || no "$f: следы тумблера" 0 "$n"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
