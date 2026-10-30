#!/bin/sh
# tests/test_rkn_pool_passthrough.sh — плечи пула rkn доходят до конфига
# движка побайтно такими, как записаны в strats_new2.txt.
#
# Плечи референсного набора для winws в пуле rkn приведены к нему один в один
# (переведены на nfqws2 и сверены с nfqws1 пакет в пакет). Любая правка плеча по
# дороге — наш фулинг, диапазон повторов, подмена блоба — разводит его с
# первоисточником. Тест прогоняет боевой пул через генератор и
# сравнивает каждый экземпляр с номером стратегии.
# POSIX sh compatible (busybox ash).
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$ROOT/lib/config_official.sh" >/dev/null 2>&1

POOL=$(grep '^manual_autocircular_rkn ' "$ROOT/strats_new2.txt" | head -1 | sed 's/^.* : nfqws2 //')
[ -n "$POOL" ] || { no "в strats_new2.txt есть пул rkn"; printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/extra_strats/TCP/RKN" "$TMP/extra_strats/TCP/YT" "$TMP/extra_strats/TCP/YT_GV" \
         "$TMP/extra_strats/UDP/YT" "$TMP/extra_strats/cache/autocircular" "$TMP/lists" "$TMP/lua"
echo rutracker.org > "$TMP/extra_strats/TCP/RKN/List.txt"
echo youtube.com > "$TMP/extra_strats/TCP/YT/List.txt"
echo googlevideo.com > "$TMP/extra_strats/TCP/YT_GV/List.txt"
echo youtube.com > "$TMP/extra_strats/UDP/YT/List.txt"
echo w > "$TMP/lists/whitelist.txt"
printf '%s\n' "$POOL" > "$TMP/extra_strats/TCP/RKN/Strategy.txt"
cp "$ROOT"/files/lua/*.lua "$TMP/lua/" 2>/dev/null
: > "$TMP/config"
OUT=$( ZAPRET2_DIR="$TMP" generate_nfqws2_opt_from_strategies 2>/dev/null )
[ -n "$OUT" ] && ok "генератор отработал" || no "генератор отработал"

# Плечи с badseq генератор раскрывает в tcp_seq/tcp_ack с умолчаниями nfqws1
# (-10000 и -66000): это задокументированное преобразование грамматики winws, а
# не правка плеча. Такие экземпляры сверяем по остатку — порчу последовательности
# снимаем с обеих сторон, всё прочее обязано совпасть, а в конфиге обязаны
# появиться оба сдвига. Остальные экземпляры должны доехать байт в байт.
canon_seq() {
    printf '%s' "$1" | sed -E 's/:badseq(_increment=-?[0-9]+)?//g; s/:badack_increment=-?[0-9]+//g; s/:tcp_seq=-?[0-9]+//g; s/:tcp_ack=-?[0-9]+//g'
}
pool_instance_present() {   # $1 — экземпляр пула, $2 — файл экземпляров конфига
    grep -qxF -- "$1" "$2" && return 0
    case "$1" in *:badseq|*:badseq:*|*:badseq_increment=*) ;; *) return 1 ;; esac
    _wantc=$(canon_seq "$1")
    while IFS= read -r _got; do
        case "$_got" in *tcp_seq=*) ;; *) continue ;; esac
        case "$_got" in *tcp_ack=*) ;; *) continue ;; esac
        [ "$(canon_seq "$_got")" = "$_wantc" ] && return 0
    done < "$2"
    return 1
}

base_numbered=$(printf '%s\n' "$OUT" | tr ' ' '\n' | grep -E '^--lua-desync=.*:strategy=[0-9]+$' | grep -v '^--lua-desync=circular')
# При измеренном блоке работает ограниченный отправитель, без clone + fake.
mkdir -p "$TMP/state"
printf '1\n' > "$TMP/state/tcp16.flag"
for mode in 0 1; do
    printf 'Z2K_NFQWS2_TEMPLATES=%s\nZ2K_SNI_STALL=1\n' "$mode" > "$TMP/config"
    measured=$( ZAPRET2_DIR="$TMP" generate_nfqws2_opt_from_strategies 2>/dev/null )
    case "$measured" in
        *z2k_sni_pick*|*blob=z2k_ch*) no "общий фейк остался (templates=$mode)" ;;
        *z2k_sni_fake*) ok "компактный отправитель включён (templates=$mode)" ;;
        *) no "отправитель отсутствует (templates=$mode)" ;;
    esac
    got_numbered=$(printf '%s\n' "$measured" | tr ' ' '\n' | grep -E '^--lua-desync=.*:strategy=[0-9]+$' | grep -v '^--lua-desync=circular')
    # Сверяем не с сырым пулом, а с тем же конфигом без механизма: обе стороны
    # проходят одинаковое раскрытие badseq, и остаётся ровно вопрос «тронул ли
    # плечи механизм».
    if [ "$got_numbered" = "$base_numbered" ]; then
        ok "порядок и содержимое всех плеч сохранены с механизмом (templates=$mode)"
    else
        no "пул изменён при включённом механизме (templates=$mode)"
    fi
done

# Экземпляры с номером стратегии: в пуле и в конфиге (профиль rkn — шаблон
# арсенала или сам профиль; ищем токены, а не строки).
printf '%s\n' "$POOL" | tr ' ' '\n' | grep -E '^--lua-desync=.*:strategy=[0-9]+$' | grep -v '^--lua-desync=circular' > "$TMP/want"
printf '%s\n' "$OUT" | tr ' ' '\n' | grep -E '^--lua-desync=' > "$TMP/all"
n_want=$(wc -l < "$TMP/want" | tr -d ' ')
miss=0
while IFS= read -r t; do
    pool_instance_present "$t" "$TMP/all" || { miss=$((miss+1)); [ "$miss" -le 3 ] && printf '  нет в конфиге: %s\n' "$t"; }
done < "$TMP/want"
[ "$miss" = 0 ] && ok "все $n_want экземпляров пула в конфиге как есть" || no "экземпляров пула изменено или потеряно: $miss из $n_want"

max=$(grep -o ':strategy=[0-9]*$' "$TMP/want" | sed 's/.*=//' | sort -n | tail -1)
seq_ok=1; i=1
while [ "$i" -le "$max" ]; do grep -q ":strategy=$i\$" "$TMP/want" || seq_ok=0; i=$((i+1)); done
[ "$seq_ok" = 1 ] && ok "номера плеч сплошные 1..$max" || no "номера плеч сплошные 1..$max"
[ "$max" = 57 ] && ok "в пуле rkn 57 плеч" || no "в пуле rkn 57 плеч (got $max)"

case "$POOL" in *fool=*) no "в пуле rkn нет fool=" ;; *) ok "в пуле rkn нет fool=" ;; esac
if printf '%s\n' "$POOL" | tr ' :' '\n\n' | grep -Eq '^repeats=[0-9]+-[0-9]+$'; then
    no "в пуле rkn нет диапазонов повторов"; else ok "в пуле rkn нет диапазонов повторов"; fi

printf 'PASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
