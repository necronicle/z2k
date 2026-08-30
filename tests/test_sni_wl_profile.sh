#!/bin/sh
# tests/test_sni_wl_profile.sh — профиль sni_wl: пробой белого списка чужим именем.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Замер на линии владельца, hetzner.com (AS24940):
# контрольное плечо отдаёт 200 и ровно 15994 байта, дальше поток стоит до
# таймаута; то же плечо с фейковым ClientHello, несущим чужое имя
# (disk.rzd.ru), — 163654 байта за 0.64 с. Ни один наш детектор этот обрыв не
# видит (400 обращений детекторов за три зависших захода — ноль событий), то
# есть ротация на этом классе не запустится никогда и имя обязано
# подставляться на ЛЮБОМ плече.
#
# ЧТО ОХРАНЯЕТСЯ:
#
#   1. Пока пуст любой из двух файлов (сети / имя), профиля нет вовсе и конфиг
#      не меняется ни на байт — это обещание тем, кто кампанию не гонял.
#   2. Гейт считает СОДЕРЖАТЕЛЬНЫЕ строки: файл из одних комментариев профиль
#      не включает (иначе в конфиг уехал бы ipset, не совпадающий ни с чем).
#      Часовой 192.0.2.0/24 (RFC 5737 TEST-NET-1) подборщик держит в файле
#      сетей ВСЕГДА — пустой ipset движок трактует как отсутствие фильтра, и
#      профиль ловил бы весь TLS подряд. Для гейта эта строка не сеть, иначе
#      профиль включился бы у всех разом; но из файла её не вырезают — в
#      --ipset он уезжает целиком.
#   3. Профиль стоит СТРОГО РАНЬШЕ rkn_tcp. Движок берёт первый совпавший
#      профиль, а условия sni_wl — надмножество условий rkn_tcp: после него
#      профиль не сработал бы ни разу.
#   4. Совпадение только на ПЕРЕСЕЧЕНИИ: --ipset поражённых сетей И хостлисты
#      РКН И исключающий белый список пользователя.
#   5. Фейк с именем стоит ДО circular и НЕ несёт :strategy=. Инстанс без
#      strategy= circular не вызывает вовсе, а весь хвост плана забирает себе:
#      навесить strategy= или переставить фейк за circular — значит получить
#      мёртвую фичу, молча и без единой ошибки в логе.
#   6. Своё состояние ротации: key=sni_wl, а не key=rkn_tcp.
#   7. Имя не проходящее валидацию хоста (пробел, двоеточие, кавычка, ';',
#      крайний дефис, пустая метка) профиль НЕ включает: имя уезжает в
#      командную строку демона, и одна опечатка кладёт nfqws2 целиком.
#   8. Остальные профили при включении не меняются ни на байт.
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

NETS_OK='# поражённые сети, гранулярность /16 (согласие вердиктов внутри /16 — 81.3%)
213.133.0.0/16'
NAME_OK='disk.rzd.ru'
IPSET_MARK='--ipset=/opt/zapret2/lists/sni_wl_nets.txt'

# Боевые пулы: подделка здесь бессмысленна — проверяется реальный арсенал.
# $1 — содержимое lists/sni_wl_nets.txt (пусто = файла нет вовсе)
# $2 — содержимое lists/sni_wl_name.txt (пусто = файла нет вовсе)
# $3 — значение Z2K_NFQWS2_TEMPLATES (по умолчанию 1)
# $4 — дополнительная строка в config
gen() {
    local root="$TMP/r"
    rm -rf "$root"
    mkdir -p "$root/extra_strats/TCP/YT" "$root/extra_strats/TCP/YT_GV" \
             "$root/extra_strats/TCP/RKN" "$root/extra_strats/UDP/YT" \
             "$root/lists" "$root/ipset"
    echo youtube.com     > "$root/extra_strats/TCP/YT/List.txt"
    echo googlevideo.com > "$root/extra_strats/TCP/YT_GV/List.txt"
    echo youtube.com     > "$root/extra_strats/UDP/YT/List.txt"
    echo rutracker.org   > "$root/extra_strats/TCP/RKN/List.txt"
    echo bank.example    > "$root/lists/whitelist.txt"
    echo "104.21.0.0/17" > "$root/lists/cf_extra_check_ips.txt"
    sed -n '4p' "$ROOT/strats_new2.txt" > "$root/extra_strats/TCP/RKN/Strategy.txt"
    sed -n '6p' "$ROOT/strats_new2.txt" > "$root/extra_strats/TCP/YT/Strategy.txt"
    sed -n '7p' "$ROOT/strats_new2.txt" > "$root/extra_strats/TCP/YT_GV/Strategy.txt"
    sed -n 's/^args=//p' "$ROOT/quic_strats.ini" | head -1 > "$root/extra_strats/UDP/YT/Strategy.txt"
    [ -n "$1" ] && printf '%s\n' "$1" > "$root/lists/sni_wl_nets.txt"
    [ -n "$2" ] && printf '%s\n' "$2" > "$root/lists/sni_wl_name.txt"
    printf 'Z2K_NFQWS2_TEMPLATES=%s\n' "${3:-1}" > "$root/config"
    [ -n "$4" ] && printf '%s\n' "$4" >> "$root/config"
    ( ZAPRET2_DIR="$root" generate_nfqws2_opt_from_strategies 2>/dev/null ) \
        | sed '1d;$d' | sed "s#$root#/opt/zapret2#g"
}

# Профиль не сгенерировался ни в каком виде?
absent() {   # $1 — файл вывода
    if grep -q 'sni_wl' "$1"; then echo "есть"; else echo "нет"; fi
}

gen ""        ""        > "$TMP/off.txt"
gen "$NETS_OK" "$NAME_OK" > "$TMP/on.txt"
awk -f "$FLATTEN" "$TMP/off.txt" > "$TMP/off_flat.txt"
awk -f "$FLATTEN" "$TMP/on.txt"  > "$TMP/on_flat.txt"

# --- 1. Без файлов профиля нет и конфиг не меняется ни на байт ---------------
_a=$(absent "$TMP/off.txt")
[ "$_a" = "нет" ] && ok "без файлов нет ни упоминания sni_wl" \
    || no "без файлов профиля нет" "нет" "$_a"

gen ""        ""        > "$TMP/off2.txt"
if cmp -s "$TMP/off.txt" "$TMP/off2.txt"; then
    ok "генератор детерминирован (эталон сравнения честный)"
else
    no "детерминизм генератора" "равны" "разошлись"
fi

# --- 2. Половина условий — профиля всё равно нет ------------------------------
gen "$NETS_OK" "" > "$TMP/half1.txt"
_a=$(absent "$TMP/half1.txt")
[ "$_a" = "нет" ] && ok "сети есть, имени нет — профиля нет" \
    || no "нужны оба файла (нет имени)" "нет" "$_a"

gen "" "$NAME_OK" > "$TMP/half2.txt"
_a=$(absent "$TMP/half2.txt")
[ "$_a" = "нет" ] && ok "имя есть, сетей нет — профиля нет" \
    || no "нужны оба файла (нет сетей)" "нет" "$_a"

# --- 3. Гейт по содержательным строкам, а не по размеру файла -----------------
gen '# одни комментарии
   ' "$NAME_OK" > "$TMP/cmt1.txt"
_a=$(absent "$TMP/cmt1.txt")
[ "$_a" = "нет" ] && ok "файл сетей из одних комментариев профиль не включает" \
    || no "комментарии не считаются сетью" "нет" "$_a"

gen "$NETS_OK" '# имя ещё не подобрано' > "$TMP/cmt2.txt"
_a=$(absent "$TMP/cmt2.txt")
[ "$_a" = "нет" ] && ok "файл имени из одних комментариев профиль не включает" \
    || no "комментарии не считаются именем" "нет" "$_a"

# --- 3a. Часовой не считается сетью ------------------------------------------
# Подборщик держит 192.0.2.0/24 в файле ВСЕГДА: опустевший файл сетей — это
# пустой ipset, а пустой ipset движок трактует как отсутствие фильтра, и
# профиль ловит весь TLS подряд. Значит непустым файл теперь бывает и там, где
# не найдено ни одной поражённой сети, и гейт обязан вычитать часового из
# подсчёта — иначе защита 99% исчезает.
gen '# сети не найдены, файл держится непустым часовым
192.0.2.0/24' "$NAME_OK" > "$TMP/sent1.txt"
_a=$(absent "$TMP/sent1.txt")
[ "$_a" = "нет" ] && ok "только комментарии и часовой — профиля нет" \
    || no "часовой не считается сетью" "нет" "$_a"

# Одна настоящая сеть рядом с часовым — профиль обязан появиться.
gen '192.0.2.0/24
213.133.0.0/16' "$NAME_OK" > "$TMP/sent2.txt"
_a=$(absent "$TMP/sent2.txt")
[ "$_a" = "есть" ] && ok "часовой плюс настоящая сеть — профиль есть" \
    || no "часовой не глушит настоящую сеть" "есть" "$_a"

# И часовой остаётся в ФАЙЛЕ, который уехал в --ipset: вычитать его положено
# из подсчёта, а не из файла — вырежи его оттуда, и вернётся тот самый пустой
# ipset. В бою он безвреден: реального трафика в TEST-NET-1 не бывает.
# Файл тот же, что писал gen() (его корень — $TMP/r), генератор к нему не
# прикасается.
_nf="$TMP/r/lists/sni_wl_nets.txt"
if [ -f "$_nf" ] && grep -q -x -F -- '192.0.2.0/24' "$_nf"; then
    ok "часовой остался в файле, скормленном --ipset"
else
    no "часовой в файле --ipset" "192.0.2.0/24 на месте" "вырезан"
fi
case "$(grep -F -- "$IPSET_MARK" "$TMP/sent2.txt" | head -1)" in
    *"$IPSET_MARK"*) ok "--ipset указывает на тот же файл сетей целиком" ;;
    *) no "--ipset на файл сетей" "$IPSET_MARK" "нет" ;;
esac

# --- 4. Оба файла непусты: ровно один профиль ---------------------------------
_n=$(grep -c -F -- "$IPSET_MARK" "$TMP/on_flat.txt")
[ "$_n" = "1" ] && ok "профиль sni_wl сгенерирован ровно один раз" \
    || no "один профиль sni_wl" "1" "$_n"

SNI_LINE=$(grep -F -- "$IPSET_MARK" "$TMP/on_flat.txt" | head -1)

# --- 5. Пересечение всех трёх условий в ОДНОМ профиле -------------------------
for _need in "$IPSET_MARK" \
             '--hostlist=/opt/zapret2/extra_strats/TCP/RKN/List.txt' \
             '--hostlist-exclude=/opt/zapret2/lists/whitelist.txt' \
             '--filter-l7=tls'; do
    case "$SNI_LINE" in
        *"$_need"*) ok "условие в профиле: $_need" ;;
        *)          no "условие в профиле" "$_need" "нет" ;;
    esac
done

# --- 6. Порядок: sni_wl строго раньше rkn_tcp ---------------------------------
_a=$(grep -n -F -- "$IPSET_MARK" "$TMP/on_flat.txt" | head -1 | cut -d: -f1)
_b=$(grep -n -F -- 'key=rkn_tcp' "$TMP/on_flat.txt" | head -1 | cut -d: -f1)
if [ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ]; then
    ok "sni_wl стоит раньше rkn_tcp (профиль $_a против $_b)"
else
    no "sni_wl раньше rkn_tcp" "sni_wl < rkn_tcp" "sni_wl=$_a rkn_tcp=$_b"
fi

# --- 7. Своё состояние ротации ------------------------------------------------
case "$SNI_LINE" in
    *'--lua-desync=circular:'*'key=sni_wl'*) ok "circular профиля несёт key=sni_wl" ;;
    *) no "key=sni_wl у circular" "есть" "нет" ;;
esac
case "$SNI_LINE" in
    *'key=rkn_tcp'*) no "профиль не делит состояние с основным пулом" "нет key=rkn_tcp" "есть" ;;
    *) ok "профиль не делит nstrategy с rkn_tcp" ;;
esac

# --- 8. Фейк: есть, до circular, без :strategy= --------------------------------
_toks="$TMP/toks.txt"
printf '%s\n' "$SNI_LINE" | tr ' ' '\n' > "$_toks"
FAKE_TOK=$(grep -F "sni=$NAME_OK" "$_toks" | head -1)
if [ -n "$FAKE_TOK" ]; then
    ok "фейк несёт подобранное имя (sni=$NAME_OK)"
else
    no "фейк с подобранным именем" "sni=$NAME_OK" "нет"
fi
case "$FAKE_TOK" in
    --lua-desync=fake:*) ok "имя подставлено именно в fake-инстанс" ;;
    *) no "fake-инстанс с именем" "--lua-desync=fake:" "$FAKE_TOK" ;;
esac
case "$FAKE_TOK" in
    *:strategy=*) no "фейк с именем без :strategy=" "без суффикса" "$FAKE_TOK" ;;
    *) ok "фейк без :strategy= — применяется на любом плече" ;;
esac
_pf=$(grep -n -F "sni=$NAME_OK" "$_toks" | head -1 | cut -d: -f1)
_pc=$(grep -n -- '--lua-desync=circular:' "$_toks" | head -1 | cut -d: -f1)
if [ -n "$_pf" ] && [ -n "$_pc" ] && [ "$_pf" -lt "$_pc" ]; then
    ok "фейк объявлен ДО circular (токен $_pf против $_pc)"
else
    no "фейк до circular" "fake < circular" "fake=$_pf circular=$_pc"
fi

# --- 9. Недопустимое имя профиль НЕ включает ----------------------------------
# Каждое из этих имён сломало бы разбор опций nfqws2 или сам синтаксис
# lua-desync (разделители там ':' и ','), то есть демон не поднялся бы вовсе.
for _bad in 'disk rzd.ru' 'disk.rzd.ru:8443' 'disk,rzd.ru' 'disk"rzd.ru' \
            'disk.rzd.ru;id' '-disk.rzd.ru' 'disk.rzd.ru-' '.disk.rzd.ru' \
            'disk..rzd.ru' 'disk.rzd.ru/x' '$(id)'; do
    gen "$NETS_OK" "$_bad" > "$TMP/bad.txt"
    _a=$(absent "$TMP/bad.txt")
    [ "$_a" = "нет" ] && ok "имя отвергнуто: [$_bad]" \
        || no "имя отвергнуто: [$_bad]" "профиля нет" "профиль есть"
done

# Допустимое имя-сосед по списку кандидатов профиль включает.
gen "$NETS_OK" 'akashi.vk-portal.net' > "$TMP/alt.txt"
_n=$(grep -c -F -- 'sni=akashi.vk-portal.net' "$TMP/alt.txt")
[ "$_n" -ge 1 ] && ok "имя с дефисом внутри метки принимается" \
    || no "akashi.vk-portal.net принимается" "есть" "$_n"

# --- 10. Мастер-тумблер -------------------------------------------------------
gen "$NETS_OK" "$NAME_OK" 1 'Z2K_SNI_WL_FAKE=0' > "$TMP/flagoff.txt"
_a=$(absent "$TMP/flagoff.txt")
[ "$_a" = "нет" ] && ok "Z2K_SNI_WL_FAKE=0 профиль выключает" \
    || no "тумблер выключает профиль" "нет" "$_a"

gen "$NETS_OK" "$NAME_OK" 1 '' > "$TMP/flagdef.txt"
_a=$(absent "$TMP/flagdef.txt")
[ "$_a" = "есть" ] && ok "без строки в config фича включена (умолчание 1)" \
    || no "умолчание тумблера" "есть" "$_a"

# --- 11. Остальные профили не изменились ни на байт ----------------------------
grep -v -F -- "$IPSET_MARK" "$TMP/on_flat.txt" > "$TMP/on_rest.txt"
if cmp -s "$TMP/on_rest.txt" "$TMP/off_flat.txt"; then
    ok "прочие профили при включении не изменились ни на байт"
else
    no "прочие профили не тронуты" "побайтно равны" "разошлись"
fi
_c_on=$(grep -c . "$TMP/on_flat.txt")
_c_off=$(grep -c . "$TMP/off_flat.txt")
[ "$_c_on" = "$((_c_off + 1))" ] && ok "профилей стало ровно на один больше" \
    || no "ровно +1 профиль" "$((_c_off + 1))" "$_c_on"

# --- 12. Плоская форма (Z2K_NFQWS2_TEMPLATES=0) --------------------------------
gen "$NETS_OK" "$NAME_OK" 0 > "$TMP/flat.txt"
FLAT_LINE=$(grep -F -- "$IPSET_MARK" "$TMP/flat.txt" | head -1)
if [ -n "$FLAT_LINE" ]; then
    ok "плоская форма тоже содержит профиль sni_wl"
else
    no "профиль в плоской форме" "есть" "нет"
fi
printf '%s\n' "$FLAT_LINE" | tr ' ' '\n' > "$_toks"
_pf=$(grep -n -F "sni=$NAME_OK" "$_toks" | head -1 | cut -d: -f1)
_pc=$(grep -n -- '--lua-desync=circular:' "$_toks" | head -1 | cut -d: -f1)
if [ -n "$_pf" ] && [ -n "$_pc" ] && [ "$_pf" -lt "$_pc" ]; then
    ok "плоская форма: фейк тоже до circular"
else
    no "плоская форма: фейк до circular" "fake < circular" "fake=$_pf circular=$_pc"
fi
case "$FLAT_LINE" in
    *--template=*|*--import=*) no "плоская форма без шаблонов" "нет --template/--import" "есть" ;;
    *) ok "плоская форма не ссылается на шаблон" ;;
esac
case "$FLAT_LINE" in
    *'key=sni_wl'*) ok "плоская форма: key=sni_wl" ;;
    *) no "плоская форма key=sni_wl" "есть" "нет" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
