#!/bin/sh
# tests/test_nfqws2_templates.sh — общий арсенал объявляется один раз.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Профиль cf_extra был дословной копией арсенала rkn_tcp:
# 13 154 байта совпадали побайтно, отличалось одно слово (key= у circular).
# Копия делалась sed'ом по готовой строке — значит любая правка арсенала
# уезжала в оба места молча, а длина командной строки платилась дважды.
# Движок умеет объявить набор один раз (--template) и подставить (--import).
#
# ЧТО ОХРАНЯЕТСЯ:
#
#   1. Шаблон объявлен РАНЬШЕ первого импорта. Ссылка вперёд движком не
#      поддерживается — он падает с «template not found», то есть обход не
#      поднимется вовсе.
#   2. circular стоит ДО --import в каждом импортирующем профиле. Инстансы
#      шаблона дописываются в хвост, а план оркестратора строится только из
#      инстансов ПОСЛЕ него: перепутать порядок — значит получить пустой план
#      и падение circular.
#   3. Раскрытый шаблонный конфиг эквивалентен плоскому: у каждого профиля тот
#      же набор токенов. Это оракул эквивалентности в CI; на живом движке та
#      же пара строк даёт побайтно одинаковый дамп профилей (проверено
#      nfqws2 --dry-run --debug на роутере).
#   4. Аварийный выключатель Z2K_NFQWS2_TEMPLATES=0 возвращает плоскую форму
#      целиком, без единого --template/--import.
#   5. Шаблон не объявляется, если его некому импортировать.
#   6. В шаблоне нет --hostlist-auto: движок отказывается стартовать, если
#      автолист есть и в шаблоне, и в профиле.
#
# POSIX sh. Исполняется настоящий генератор на временном дереве.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FLATTEN="$HERE/lib/nfqws2_flatten.awk"
[ -f "$FLATTEN" ] || { printf '[FAIL] нет %s\n' "$FLATTEN"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$ROOT/lib/config_official.sh" >/dev/null 2>&1

# Боевые пулы: подделка здесь бессмысленна — вся суть в реальном арсенале.
gen() {   # $1 — Z2K_NFQWS2_TEMPLATES, $2 — «empty-rkn» чтобы обнулить РКН-список
    local root="$TMP/r"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" \
             "$root/lists" "$root/ipset"
    echo youtube.com     > "$root/extra_strats/TCP/YT/List.txt"
    echo googlevideo.com > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo youtube.com     > "$root/extra_strats/UDP/YT/List.txt"
    if [ "$2" = "empty-rkn" ]; then : > "$root/extra_strats/TCP/RKN/List.txt"
    else echo rutracker.org > "$root/extra_strats/TCP/RKN/List.txt"; fi
    echo bank.example    > "$root/lists/whitelist.txt"
    echo "104.21.0.0/17" > "$root/lists/cf_extra_check_ips.txt"
    sed -n '4p' "$ROOT/strats_new2.txt" > "$root/extra_strats/TCP/RKN/Strategy.txt"
    sed -n '6p' "$ROOT/strats_new2.txt" > "$root/extra_strats/TCP/YT/Strategy.txt"
    sed -n '7p' "$ROOT/strats_new2.txt" > "$root/extra_strats/TCP/YT_GV/Strategy.txt"
    sed -n 's/^args=//p' "$ROOT/quic_strats.ini" | head -1 > "$root/extra_strats/UDP/YT/Strategy.txt"
    printf 'Z2K_CF_EXTRA_CHECK=1\nZ2K_NFQWS2_TEMPLATES=%s\n' "$1" > "$root/config"
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null ) \
        | sed '1d;$d' | sed "s#$root#/opt/zapret2#g"
}

gen 1 > "$TMP/tpl.txt"
gen 0 > "$TMP/flat.txt"

# --- 1. Один шаблон, оба профиля его импортируют -----------------------------
_n_tpl=$(grep -c -- '--template=z2k_rkn_arsenal' "$TMP/tpl.txt")
_n_imp=$(grep -c -- '--import=z2k_rkn_arsenal' "$TMP/tpl.txt")
[ "$_n_tpl" = "1" ] && ok "шаблон объявлен ровно один раз" \
    || no "один шаблон" "1" "$_n_tpl"
[ "$_n_imp" = "2" ] && ok "импортируют оба профиля (rkn_tcp и cf_extra)" \
    || no "два импорта" "2" "$_n_imp"

# --- 2. Объявление раньше импорта -------------------------------------------
_ln_tpl=$(grep -n -- '--template=' "$TMP/tpl.txt" | head -1 | cut -d: -f1)
_ln_imp=$(grep -n -- '--import=' "$TMP/tpl.txt" | head -1 | cut -d: -f1)
if [ -n "$_ln_tpl" ] && [ -n "$_ln_imp" ] && [ "$_ln_tpl" -lt "$_ln_imp" ]; then
    ok "шаблон объявлен раньше первого импорта"
else
    no "порядок объявления" "template раньше import" "template=$_ln_tpl import=$_ln_imp"
fi

# --- 3. circular раньше --import внутри профиля ------------------------------
_bad=0
while IFS= read -r _line; do
    case "$_line" in *--import=*) ;; *) continue ;; esac
    _pos_c=$(printf '%s' "$_line" | awk '{ for(i=1;i<=NF;i++) if ($i ~ /^--lua-desync=circular:/) { print i; exit } }')
    _pos_i=$(printf '%s' "$_line" | awk '{ for(i=1;i<=NF;i++) if ($i ~ /^--import=/) { print i; exit } }')
    if [ -z "$_pos_c" ] || [ "$_pos_c" -gt "$_pos_i" ]; then _bad=$((_bad+1)); fi
done < "$TMP/tpl.txt"
[ "$_bad" = "0" ] && ok "во всех импортирующих профилях circular стоит до --import" \
    || no "порядок circular/import" "0 нарушений" "$_bad"

# --- 4. Эквивалентность плоской и шаблонной формы ----------------------------
awk -f "$FLATTEN" "$TMP/tpl.txt" > "$TMP/tpl_flat.txt"
_a=$(wc -l < "$TMP/flat.txt" | tr -d ' ')
_b=$(wc -l < "$TMP/tpl_flat.txt" | tr -d ' ')
if [ "$_a" = "$_b" ] && [ "$_a" -gt 0 ]; then
    ok "профилей одинаково ($_a)"
else
    no "число профилей" "$_a" "$_b"
fi
_diffs=0; _i=0
while IFS= read -r _x && IFS= read -r _y <&3; do
    _i=$((_i+1))
    _sx=$(printf '%s' "$_x" | tr ' ' '\n' | grep -v '^--new$' | grep -v '^$' | sort -u)
    _sy=$(printf '%s' "$_y" | tr ' ' '\n' | grep -v '^--new$' | grep -v '^$' | sort -u)
    [ "$_sx" = "$_sy" ] || { _diffs=$((_diffs+1)); printf '      профиль %s расходится\n' "$_i"; }
done < "$TMP/flat.txt" 3< "$TMP/tpl_flat.txt"
[ "$_diffs" = "0" ] && ok "у каждого профиля тот же набор токенов, что в плоской форме" \
    || no "эквивалентность" "0 расхождений" "$_diffs"

# --- 5. Выигрыш в длине ------------------------------------------------------
_sz_flat=$(wc -c < "$TMP/flat.txt" | tr -d ' ')
_sz_tpl=$(wc -c < "$TMP/tpl.txt" | tr -d ' ')
_saved=$((_sz_flat - _sz_tpl))
if [ "$_saved" -gt 10000 ]; then
    ok "строка короче на $_saved байт ($_sz_flat → $_sz_tpl)"
else
    no "выигрыш в длине" ">10000 байт" "$_saved (шаблон перестал экономить — проверьте, что импортируют оба профиля)"
fi

# --- 6. Аварийный выключатель ------------------------------------------------
if grep -q -- '--template\|--import' "$TMP/flat.txt"; then
    no "Z2K_NFQWS2_TEMPLATES=0 отключает шаблоны" "ни одного --template/--import" "остались"
else
    ok "Z2K_NFQWS2_TEMPLATES=0 возвращает плоскую форму"
fi

# --- 7. Некому импортировать — нет и шаблона ---------------------------------
#
# Пустой РКН-список выкидывает профили rkn_tcp и http_rkn; cf_extra при этом
# эмитится и импорт сохраняет, поэтому шаблон обязан остаться. Проверяем
# обратное свойство на выключенном cf_extra и пустом РКН — не остаётся ни
# одного импортёра.
_root="$TMP/r2"; rm -rf "$_root"
mkdir -p "$_root/extra_strats/TCP/YT" "$_root/extra_strats/TCP/YT_GV" \
         "$_root/extra_strats/TCP/RKN" "$_root/extra_strats/UDP/YT" "$_root/lists" "$_root/ipset"
echo youtube.com > "$_root/extra_strats/TCP/YT/List.txt"
echo googlevideo.com > "$_root/extra_strats/TCP/YT_GV/List.txt"
echo youtube.com > "$_root/extra_strats/UDP/YT/List.txt"
: > "$_root/extra_strats/TCP/RKN/List.txt"
echo bank.example > "$_root/lists/whitelist.txt"
sed -n '4p' "$ROOT/strats_new2.txt" > "$_root/extra_strats/TCP/RKN/Strategy.txt"
sed -n '6p' "$ROOT/strats_new2.txt" > "$_root/extra_strats/TCP/YT/Strategy.txt"
sed -n '7p' "$ROOT/strats_new2.txt" > "$_root/extra_strats/TCP/YT_GV/Strategy.txt"
printf 'Z2K_CF_EXTRA_CHECK=0\nZ2K_NFQWS2_TEMPLATES=1\n' > "$_root/config"
_out=$( ZAPRET2_DIR="$_root" generate_nfqws2_opt_from_strategies 2>/dev/null )
case "$_out" in
    *--template=*) no "шаблон без импортёров не объявляется" "нет --template" "объявлен впустую" ;;
    *) ok "шаблон без импортёров не объявляется" ;;
esac

# --- 8. В шаблоне нет автолиста ---------------------------------------------
_tpl_block=$(grep -- '--template=' "$TMP/tpl.txt" | head -1)
case "$_tpl_block" in
    *--hostlist-auto=*) no "в шаблоне нет --hostlist-auto" "нет" "есть — движок откажется стартовать" ;;
    *) ok "в шаблоне нет --hostlist-auto (движок запрещает его замещение импортом)" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
