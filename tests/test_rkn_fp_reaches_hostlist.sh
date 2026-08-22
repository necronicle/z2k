#!/bin/sh
# tests/test_rkn_fp_reaches_hostlist.sh — правка списка ложных срабатываний
# обязана доехать до RKN/List.txt, а НЕизменившийся список не должен стоить ни
# одного байта трафика.
#
# ЧТО ЛОМАЛОСЬ. Штатный саппорт-флоу: домен ошибочно исключён из обхода —
# убираем строку из files/lists/rkn-false-positive.txt и выкатываем. Список до
# роутера доезжал, а до хостлиста нет:
#
#   * subtract_false_positive_from_rkn умеет только ВЫЧИТАТЬ и работает по
#     цели, которая уже лежит на диске. Убранный из списка домен обратно в цель
#     не попадает: она собирается один раз при загрузке апстрима;
#   * апстрим при этом не менялся, значит на каждый следующий прогон приходит
#     дешёвый 304, и цель не пересобирается вовсе.
#
# Итог: версия уехала вперёд, в описании релиза домен обещан, а в хостлисте он
# по-прежнему вычтен — до ближайшего переиздания апстрима, то есть на
# неопределённый срок и без единой строчки в логе.
#
# ИНВАРИАНТ, который здесь проверяется: содержимое RKN/List.txt есть функция
# ДВУХ входов — апстримного ассета и fp-списка. Условный запрос стережёт только
# первый. Второй стережёт гейт по отпечатку (_z2k_rkn_fp_gate) на входе в
# fetch_all: сменился отпечаток — ETag ассетов RKN сносится, приходит 200, цель
# пересобирается, и вычитание идёт уже НОВЫМ списком.
#
# Проверяем ИСПОЛНЕНИЕМ: раздел А гоняет настоящий files/z2k-geosite.sh
# четырьмя прогонами с подставным curl и смотрит на содержимое цели и на число
# перекачек. Раздел Б исполняет реальный кусок au_apply_patch. Раздел В
# исполняет ОБА гейта (установки и geosite) подряд и требует, чтобы второй не
# считал работу первого «сменой списка».
#
# POSIX sh.

# Диалект вложенных оболочек задаётся набором, а не хардкодом: на macOS
# /bin/sh — это bash, в CI — dash. См. шапку tests/lib/common.sh.
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { printf '[SKIP] %s\n' "$1"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
GEO="${Z2K_GEOSITE_UNDER_TEST:-$ROOT/files/z2k-geosite.sh}"
AU="${Z2K_AUTO_UPDATE_UNDER_TEST:-$ROOT/lib/auto_update.sh}"
INST="${Z2K_INSTALL_UNDER_TEST:-$ROOT/lib/install.sh}"
UTILS="$ROOT/lib/utils.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-rknfp.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# ============================================================================
# А. Настоящий geosite: четыре прогона подряд
# ============================================================================
#
# ПОДСТАВНОЙ curl СВОЙ, А НЕ ОБЩИЙ (z2k_write_curl_stub). Общий отдаёт ОДНО
# тело на все ассеты, а здесь это ломает сам сценарий: youtube.txt с тем же
# содержимым, что и RKN, заставит subtract_yt_from_rkn выпилить из RKN всё, и
# страж усадки отвергнет цель — тест позеленел бы на пустом месте. Контракт
# `-w '%{http_code} %{time_connect}'` (два поля) держим тот же, что у общего:
# боевой код разбирает именно два.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUBC'
#!/bin/sh
out=""; cmp=""; save=""; hdr=""; prev=""; url=""
for a in "$@"; do
    case "$prev" in
        -o)             out="$a" ;;
        --etag-compare) cmp="$a" ;;
        --etag-save)    save="$a" ;;
        -D)             hdr="$a" ;;
    esac
    case "$a" in https://*) url="$a" ;; esac
    prev="$a"
done
asset="${url##*/}"
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
# Апстрим НЕ меняется ни разу за весь тест: ETag один и тот же на все прогоны.
if [ -n "$cmp" ] && [ -f "$cmp" ] && [ "$(cat "$cmp" 2>/dev/null)" = "upstream-v1" ]; then
    printf 'DL304 %s\n' "$asset" >> "$DL_LOG"
    printf '304 0.075'; exit 0
fi
printf 'DL200 %s\n' "$asset" >> "$DL_LOG"
case "$asset" in
    ru-blocked*.txt)
        [ -n "$out" ] && printf 'restored.example.com\nb1.example.com\nb2.example.com\nb3.example.com\nb4.example.com\nb5.example.com\nb6.example.com\nb7.example.com\nb8.example.com\nb9.example.com\n' > "$out" ;;
    youtube.txt)
        [ -n "$out" ] && printf 'youtube.com\nyoutu.be\n' > "$out" ;;
    *)
        [ -n "$out" ] && printf 'discord.com\ndiscordapp.com\n' > "$out" ;;
esac
[ -n "$save" ] && printf 'upstream-v1' > "$save"
printf '200 0.075'
exit 0
STUBC
chmod +x "$TMP/bin/curl"

SB="$TMP/sb"
EX="$SB/opt/extra_strats"
FPL="$SB/opt/lists/rkn-false-positive.txt"

seed() {
    rm -rf "$SB"
    mkdir -p "$EX/TCP/RKN" "$EX/TCP/YT" "$EX/TCP/YT_GV" "$EX/UDP/YT" \
             "$EX/cache/geosite-etag" "$SB/opt/lists"
    # Устоявшееся состояние роутера: RKN уже собран из апстрима, и
    # restored.example.com из него ВЫЧТЕН как ложное срабатывание.
    printf 'b1.example.com\nb2.example.com\nb3.example.com\nb4.example.com\nb5.example.com\nb6.example.com\nb7.example.com\nb8.example.com\nb9.example.com\n' \
        > "$EX/TCP/RKN/List.txt"
    printf 'ru-blocked.txt\n' > "$EX/TCP/RKN/List.txt.asset"
    printf 'youtube.com\nyoutu.be\n' > "$EX/TCP/YT/List.txt"
    printf 'youtube.txt\n'   > "$EX/TCP/YT/List.txt.asset"
    printf 'youtube.com\nyoutu.be\n' > "$EX/UDP/YT/List.txt"
    printf 'youtube.txt\n'   > "$EX/UDP/YT/List.txt.asset"
    printf 'googlevideo.com\n' > "$EX/TCP/YT_GV/List.txt"
    printf 'discord.com\ndiscordapp.com\n' > "$EX/TCP/RKN/Discord.txt"
    printf 'discord.txt\n'   > "$EX/TCP/RKN/Discord.txt.asset"
    printf 'discord.com\ndiscordapp.com\n' > "$EX/TCP_Discord.txt"
    printf 'discord.txt\n'   > "$EX/TCP_Discord.txt.asset"
    # ETag'и всех трёх ассетов на руках — значит по умолчанию весь прогон
    # обязан быть тремя дешёвыми 304 без единой перекачки тела.
    for a in ru-blocked.txt youtube.txt discord.txt; do
        printf 'upstream-v1' > "$EX/cache/geosite-etag/${a}.etag"
    done
    printf '# RKN false-positive\nrestored.example.com\n' > "$FPL"
}

# run — один прогон настоящего z2k-geosite.sh. Печатает число перекачанных тел.
run() {
    : > "$TMP/dl.log"
    env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
        ZAPRET2_DIR="$SB/opt" \
        ZAPRET2_FALSE_POSITIVE_LIST="$FPL" \
        Z2K_GEOSITE_RKN_ASSET="ru-blocked.txt" \
        Z2K_RKN_FP_MARK="$SB/mark.sha256" \
        Z2K_RKN_FP_COPY="$SB/mark.list" \
        Z2K_VPS_GH_IP="" \
        DL_LOG="$TMP/dl.log" \
        "$Z2K_TEST_SH" "$GEO" fetch >>"$TMP/geo.log" 2>&1
    grep -c '^DL200' "$TMP/dl.log" 2>/dev/null | tr -d ' \t'
}

dl200_of() { grep '^DL200' "$TMP/dl.log" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' '; }
rkn_has()  { grep -qx "$1" "$EX/TCP/RKN/List.txt" 2>/dev/null; }

seed
: > "$TMP/geo.log"

# --- 1) первый прогон с гейтом ---------------------------------------------
# Отпечатка ещё нет, и что именно вычтено из цели — неизвестно. Одна перекачка
# RKN здесь неизбежна и законна; трогать ЧУЖИЕ ассеты гейт при этом не вправе.
n=$(run)
if [ "$n" = "1" ] && [ "$(dl200_of)" = "ru-blocked.txt " ]; then
    ok "первый прогон: пересобран ровно RKN, youtube/discord остались на 304"
else
    no "первый прогон трогает только RKN" "1 (ru-blocked.txt)" "$n ($(dl200_of))"
fi
if rkn_has restored.example.com; then
    no "домен из fp-списка вычтен из RKN" "restored.example.com отсутствует" "присутствует"
else
    ok "домен, пока он в fp-списке, из RKN вычтен"
fi

# --- 2) ничего не менялось ---------------------------------------------------
n=$(run)
if [ "$n" = "0" ]; then
    ok "неизменившийся fp-список не стоит ни одной перекачки — три 304"
else
    no "прогон без изменений не качает тела" "0" "$n ($(dl200_of))"
fi

# --- 3) САППОРТ-ФЛОУ: домен убирают из fp-списка -----------------------------
printf '# RKN false-positive\n' > "$FPL"
n=$(run)
if [ "$n" = "1" ] && [ "$(dl200_of)" = "ru-blocked.txt " ]; then
    ok "правка fp-списка пересобирает РОВНО RKN (youtube/discord не перекачиваются)"
else
    no "правка fp-списка пересобирает только RKN" "1 (ru-blocked.txt)" "$n ($(dl200_of))"
fi
if rkn_has restored.example.com; then
    ok "домен вернулся в RKN/List.txt в тот же прогон — без ожидания переиздания апстрима"
else
    no "домен вернулся в RKN/List.txt" "restored.example.com присутствует" \
       "отсутствует: $(tr '\n' ' ' < "$EX/TCP/RKN/List.txt")"
fi
# Вычитание не должно превратиться в «не вычитаем вовсе»: остальные строки
# апстрима обязаны остаться на месте.
if rkn_has b1.example.com && rkn_has b9.example.com; then
    ok "остальной апстрим-список на месте (пересборка, а не обрубок)"
else
    no "апстрим-список на месте" "b1 и b9 присутствуют" "$(tr '\n' ' ' < "$EX/TCP/RKN/List.txt")"
fi

# --- 4) и снова тишина -------------------------------------------------------
n=$(run)
if [ "$n" = "0" ]; then
    ok "после применения правки прогоны снова бесплатны (304)"
else
    no "гейт срабатывает РОВНО ОДИН раз на правку" "0" "$n ($(dl200_of))"
fi
if rkn_has restored.example.com; then
    ok "вернувшийся домен держится в цели и на следующих прогонах"
else
    no "домен держится в цели" "restored.example.com присутствует" "исчез"
fi

# --- 5) роутер без sha256: запасной путь по копии списка ---------------------
# На таком роутере гейт установки не делает вовсе ничего (ему нечем считать),
# поэтому единственный шанс правки доехать — сравнение с копией.
mkdir -p "$TMP/nosha"
for c in awk sort sed grep cat cp mv rm mkdir wc tr cmp printf date touch find dirname basename; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$TMP/nosha/$c"
done
ln -sf "$TMP/bin/curl" "$TMP/nosha/curl"
seed
: > "$TMP/dl.log"
run_nosha() {
    : > "$TMP/dl.log"
    env -i PATH="$TMP/nosha" HOME="$TMP" TMPDIR="$TMP" \
        ZAPRET2_DIR="$SB/opt" ZAPRET2_FALSE_POSITIVE_LIST="$FPL" \
        Z2K_GEOSITE_RKN_ASSET="ru-blocked.txt" \
        Z2K_RKN_FP_MARK="$SB/mark.sha256" Z2K_RKN_FP_COPY="$SB/mark.list" \
        Z2K_VPS_GH_IP="" DL_LOG="$TMP/dl.log" \
        "$Z2K_TEST_SH" "$GEO" fetch >>"$TMP/geo.log" 2>&1
    grep -c '^DL200' "$TMP/dl.log" 2>/dev/null | tr -d ' \t'
}
if [ -x "$TMP/nosha/awk" ] && [ -x "$TMP/nosha/cmp" ]; then
    run_nosha >/dev/null                       # первый прогон: снимок списка
    n=$(run_nosha)
    if [ "$n" = "0" ]; then
        ok "без sha256: неизменившийся список по-прежнему бесплатен"
    else
        no "без sha256 прогон без изменений бесплатен" "0" "$n"
    fi
    printf '# RKN false-positive\n' > "$FPL"
    n=$(run_nosha)
    if [ "$n" = "1" ] && rkn_has restored.example.com; then
        ok "без sha256 правка доезжает до хостлиста по побайтному сравнению копии"
    else
        no "без sha256 правка доезжает" "1 перекачка + домен в цели" \
           "$n / $(rkn_has restored.example.com && echo есть || echo нет)"
    fi
else
    skip "песочница без sha256 не собралась (нет awk/cmp в PATH)"
fi

# ============================================================================
# Б. Патч-путь: чем именно au_apply_patch дёргает geosite
# ============================================================================
#
# Гейт снял нужду в общем FORCE_REFETCH на правку fp-списка: форс сносил
# ETag'и ВСЕХ ассетов, то есть за одну строку в списке платили перекачкой
# RKN + youtube + discord. Форс остаётся там, где он по делу — на правке
# самого z2k-geosite.sh (сменился разбор, старую цель надо пересобрать).
#
# Терминатор блока здесь — строка `EOF` (конец heredoc'а со списком файлов), а
# не `fi`, поэтому общий z2k_extract_block не подходит.
extract_to_eof() {
    awk -v pat="$1" '
        index($0, pat) > 0 { inb = 1 }
        inb { print }
        inb && $0 == "EOF" { exit }
    ' "$AU"
}
extract_to_eof 'local restart_set="S99zapret2"' > "$TMP/au_case.sh"
z2k_extract_block "$AU" 'if [ "$geosite_refresh" = "1" ]' '    ' > "$TMP/au_call.sh"

if [ -s "$TMP/au_case.sh" ] && [ -s "$TMP/au_call.sh" ] \
   && grep -q 'geosite_refresh=1' "$TMP/au_case.sh" \
   && grep -q 'z2k-geosite.sh' "$TMP/au_call.sh"; then
    ok "разбор changed_files и вызов geosite извлечены из au_apply_patch"
else
    no "блоки au_apply_patch извлечены" "оба непустые" "case=$(wc -c <"$TMP/au_case.sh") call=$(wc -c <"$TMP/au_call.sh")"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"; exit 1
fi

# Подставной geosite: единственное, что он делает, — записывает, с каким
# FORCE_REFETCH его позвали. Восклицать `sh` тут будет боевой код, не тест.
patched_with() {  # patched_with <список изменённых файлов> → "FORCE=<...>"
    _pw_zd="$TMP/zd"; rm -rf "$_pw_zd"; mkdir -p "$_pw_zd"
    cat > "$_pw_zd/z2k-geosite.sh" <<PWSTUB
#!/bin/sh
printf 'FORCE=%s\n' "\${FORCE_REFETCH:-unset}" > "$TMP/force.out"
exit 0
PWSTUB
    rm -f "$TMP/force.out"
    env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
        CASE="$TMP/au_case.sh" CALL="$TMP/au_call.sh" ZD="$_pw_zd" FILES="$1" \
        "$Z2K_TEST_SH" -c '
            au_log() { :; }
            zd="$ZD"; files="$FILES"
            # Блоки живут внутри функции — в них `local`, а вне функции dash
            # на нём падает.
            _run() { . "$CASE"; . "$CALL"; }
            _run
        ' >/dev/null 2>&1
    cat "$TMP/force.out" 2>/dev/null || printf 'НЕ ВЫЗВАН\n'
}

r=$(patched_with "files/lists/rkn-false-positive.txt")
case "$r" in
    "FORCE=0") ok "патч правки fp-списка зовёт geosite БЕЗ форса — гейт по отпечатку пересоберёт ровно RKN" ;;
    "FORCE=1") no "патч fp-списка не форсирует перекачку всех ассетов" "FORCE=0" "FORCE=1" ;;
    *)         no "патч fp-списка вообще зовёт geosite" "FORCE=0" "$r" ;;
esac

r=$(patched_with "files/z2k-geosite.sh")
case "$r" in
    "FORCE=1") ok "патч самого z2k-geosite.sh по-прежнему форсирует перекачку — новый разбор применяется к целям" ;;
    *)         no "патч z2k-geosite.sh форсирует перекачку" "FORCE=1" "$r" ;;
esac

r=$(patched_with "files/lua/nfqws2.lua")
case "$r" in
    "НЕ ВЫЗВАН") ok "посторонний патч geosite не трогает" ;;
    *)           no "посторонний патч geosite не трогает" "НЕ ВЫЗВАН" "$r" ;;
esac

# ============================================================================
# В. Два гейта — один отпечаток (иначе пинг-понг)
# ============================================================================
#
# Такой же гейт стоит в lib/install.sh. Если он и geosite считают/пишут
# отпечаток ПО-РАЗНОМУ, каждый будет видеть запись другого как «список
# изменился»: снос ETag и полная перекачка RKN на КАЖДОМ прогоне, молча.
# Проверяем исполнением: прогоняем гейт установки, затем гейт geosite и
# требуем, чтобы второй промолчал.
z2k_extract_block "$INST" 'local _fp_list="${ZAPRET2_DIR}/lists/rkn-false-positive.txt"' '    ' \
    > "$TMP/inst_gate.sh"
awk '/^_z2k_rkn_fp_gate\(\) \{/,/^\}/'  "$GEO"   > "$TMP/geo_gate.sh"
awk '/^_z2k_geosite_sha256\(\) \{/,/^\}/' "$GEO" >> "$TMP/geo_gate.sh"
awk '/^z2k_sha256_file\(\) \{/,/^\}/'   "$UTILS" > "$TMP/utils_sha.sh"

if ! grep -q 'z2k_rkn_fp_gate' "$TMP/geo_gate.sh"; then
    no "гейт geosite извлечён" "_z2k_rkn_fp_gate" "не найден"
elif [ ! -s "$TMP/inst_gate.sh" ] || ! grep -q 'z2k-rkn-fp' "$TMP/inst_gate.sh"; then
    # Гейт установки объявлен лишним и снят — проверять согласованность не с
    # чем. Это не провал: инвариант держит geosite на всех путях.
    skip "гейта отпечатка в install.sh больше нет — согласовывать не с чем"
else
    # Сначала — сам ПУТЬ. Исполнением его не сверить: обе стороны пишут в
    # системный каталог, и в песочнице путь приходится подменять. Поэтому
    # сравниваем две константы напрямую; разойдись они, гейты перестанут
    # видеть работу друг друга, и никакая проверка ниже этого уже не поймает.
    _inst_mark=$(sed -n 's/.*_fp_mark="\([^"]*\)".*/\1/p' "$INST" | head -1)
    _geo_mark=$(sed -n 's/^Z2K_RKN_FP_MARK="${Z2K_RKN_FP_MARK:-\(.*\)}"$/\1/p' "$GEO" | head -1)
    if [ -n "$_geo_mark" ] && [ "$_inst_mark" = "$_geo_mark" ]; then
        ok "оба гейта держат отпечаток в одном файле ($_geo_mark)"
    else
        no "оба гейта держат отпечаток в одном файле" "install=$_inst_mark" "geosite=${_geo_mark:-не найден}"
    fi

    # Путь маркера в install.sh вписан литералом (/opt/etc/...). В песочницу
    # его подменяем: тест не имеет права писать в системный каталог.
    sed "s#/opt/etc/.z2k-rkn-fp.sha256#$TMP/pp/mark.sha256#" "$TMP/inst_gate.sh" \
        > "$TMP/inst_gate_sb.sh"
    mkdir -p "$TMP/pp/opt/lists" "$TMP/pp/opt/extra_strats/cache/geosite-etag"
    printf '# fp\nrestored.example.com\n' > "$TMP/pp/opt/lists/rkn-false-positive.txt"
    printf 'upstream-v1' > "$TMP/pp/opt/extra_strats/cache/geosite-etag/ru-blocked.txt.etag"
    rm -f "$TMP/pp/mark.sha256"

    pp=$(env -i PATH="/usr/bin:/bin" HOME="$TMP" \
        IG="$TMP/inst_gate_sb.sh" GG="$TMP/geo_gate.sh" US="$TMP/utils_sha.sh" \
        PP="$TMP/pp" "$Z2K_TEST_SH" -c '
            . "$US"
            . "$GG"
            print_info() { :; }
            log() { :; }
            ZAPRET2_DIR="$PP/opt"
            ETAG_DIR="$PP/opt/extra_strats/cache/geosite-etag"
            FP_LIST="$PP/opt/lists/rkn-false-positive.txt"
            Z2K_RKN_FP_MARK="$PP/mark.sha256"
            Z2K_RKN_FP_COPY="$PP/mark.list"
            # 1) гейт установки: отпечатка нет → обязан снести ETag и записать
            _ig() { . "$IG"; }
            _ig
            a=нет; [ -f "$ETAG_DIR/ru-blocked.txt.etag" ] && a=есть
            # 2) следом гейт geosite по ТОМУ ЖЕ файлу: он обязан промолчать
            printf "upstream-v1" > "$ETAG_DIR/ru-blocked.txt.etag"
            _z2k_rkn_fp_gate
            b=нет; [ -f "$ETAG_DIR/ru-blocked.txt.etag" ] && b=есть
            printf "%s:%s" "$a" "$b"
        ' 2>/dev/null)

    case "$pp" in
        "нет:есть") ok "гейты установки и geosite пишут ОДИН отпечаток — второй не пересносит ETag за первым" ;;
        "нет:нет")  no "гейт geosite не считает запись установки сменой списка" "нет:есть" "$pp (пинг-понг: полная перекачка каждый прогон)" ;;
        *)          no "гейт установки сносит ETag на первом прогоне" "нет:есть" "$pp" ;;
    esac
fi

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
