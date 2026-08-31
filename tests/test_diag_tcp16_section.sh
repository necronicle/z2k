#!/bin/sh
# tests/test_diag_tcp16_section.sh — раздел диагностики про блок по объёму.
#
# Раздел нужен ровно для одного: увидеть РАСХОЖДЕНИЕ между тем, что намерила
# проба, и тем, что попало в конфиг. Именно им отличается «обновилось и молчит»
# (r-81.1) от «блока на линии нет». Поэтому проверяется запуском на трёх
# состояниях, а не наличием строк.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIAG="$DIR/files/z2k-diag.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/state" "$SB/lists"
printf 'NFQWS2_OPT="--filter-tcp=443"\n' > "$SB/config"
: > "$SB/lists/tcp16_nets.txt"; : > "$SB/lists/sni_wl_candidates.txt"

sect() { ZAPRET2_DIR="$SB" sh "$DIAG" full 2>/dev/null | sed -n '/блок по объёму/,/^$/p'; }

# --- 1. Не мерили -----------------------------------------------------------
OUT=$(sect)
case "$OUT" in *"не измерялась"*) ok "без замера так и написано" ;; *) bad "не сказано, что линия не измерялась" ;; esac
# Счётчики на пустых файлах: `grep -c || echo 0` печатал «0\n0» и ломал вывод.
if printf '%s' "$OUT" | grep -qE '^(сетей с блоком|карта сетей) +: [0-9]+( записей)?$'; then
    ok "счётчики печатаются одним числом"
else
    bad "счётчики разъехались: $(printf '%s' "$OUT" | grep -A1 'сетей с блоком' | tr '\n' '|')"
fi

# --- 2. Блока нет -----------------------------------------------------------
printf '0\n' > "$SB/state/tcp16.flag"; date +%s > "$SB/state/tcp16.flag.ts"
OUT=$(sect)
case "$OUT" in *"блока нет"*) ok "«блока нет» показывается отдельно от «не мерили»" ;; *) bad "не отличает «блока нет» от «не мерили»" ;; esac

# --- 3. Блок есть, а механизма в конфиге нет — тот самый случай r-81.1 -------
printf '1\n' > "$SB/state/tcp16.flag"
printf '24940\n' > "$SB/state/tcp16_asn.txt"
printf '24940\t300.ya.ru\n' > "$SB/state/tcp16_sni.txt"
OUT=$(sect)
case "$OUT" in
    *"РАСХОЖДЕНИЕ"*) ok "расхождение «намерено, но не применено» названо прямо" ;;
    *) bad "расхождение не показано — по диагностике причину не отличить" ;;
esac
case "$OUT" in *"300.ya.ru"*) ok "видно, какой сети какое имя досталось" ;; *) bad "карта имён не показана" ;; esac

# --- 4. Механизм в конфиге — расхождения быть не должно ---------------------
printf 'NFQWS2_OPT="--filter-tcp=443 --lua-desync=z2k_sni_pick:blob=z2k_ch"\n' > "$SB/config"
OUT=$(sect)
case "$OUT" in
    *"РАСХОЖДЕНИЕ"*) bad "расхождение показано там, где всё сошлось" ;;
    *) ok "когда всё сошлось, тревоги нет" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
