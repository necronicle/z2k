#!/bin/sh
# tests/test_upgrade_from_published.sh — переход МЕЖДУ РЕВИЗИЯМИ в обе стороны.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ НАБОР.
#
# Полторы сотни тестов проверяют HEAD. Два из них — реинсталл (игровые списки,
# кеш geosite) — сеют фикстуру руками и в HEAD-форме: с `.source-count`, с
# дотфайлами кеша, с маркерами происхождения. То есть проверяют «HEAD поверх
# HEAD». А у человека на роутере лежит не HEAD: там состояние, которое оставила
# ОПУБЛИКОВАННАЯ ревизия, и переход на HEAD обязан его пережить. Обратный путь —
# откат на опубликованную ревизию — не проверял вообще никто, хотя именно он
# включается, когда авто-обновление признаёт релиз больным.
#
# Поэтому здесь единственный источник правды о «старом диске» — сама
# опубликованная ревизия: её код берётся через `git show <ref>:<файл>` и
# ИСПОЛНЯЕТСЯ, чтобы разложить артефакты ровно так, как он их раскладывает.
# Ни один файл фикстуры не пишется от руки там, где его умеет написать код.
#
# ЧТО ИМЕННО ЛОВИТСЯ.
#
#   ЧАСТЬ 1 (апгрейд). На диске опубликованной ревизии нет ничего из того, что
#   завёл HEAD: ни маркеров `.rejected`, ни отпечатка списка ложных
#   срабатываний, ни счётчиков полноты переноса. Зато есть то, чего HEAD не
#   ждёт: цели, помеченные `shipped-fallback`. Их перенос через реинсталл
#   означал бы, что поставляемые списки на таком роутере не обновятся уже
#   НИКОГДА — прямо против ARCHITECTURE.md («Штатные Strategy.txt и
#   поставляемые списки заменяются»).
#
#   ЧАСТЬ 2 (откат). HEAD оставляет на диске четыре вида артефактов, которых
#   опубликованная ревизия не знает: `.rejected` в кеше ETag, дотфайлы
#   `games/.<имя>.raw[.etag]`, перенесённые ETag и отпечаток fp-списка вне
#   дерева. Откат обязан их переварить: не упасть, не потерять пользовательские
#   данные и не оставить роутер без обхода.
#
# ПРО ПОДСТАВНОЙ curl. Канонический (tests/lib/common.sh) печатает ДВА поля —
# так просит боевой `-w` в HEAD. Опубликованная ревизия просит ОДНО, и
# двухполевой стаб отдал бы ей `http="200 0.075"`: ветка 200 не сработала бы
# никогда, и красным был бы харнесс, а не код. Здесь стаб печатает одно поле:
# его одинаково разбирают обе ревизии (в HEAD — через `${raw%% *}`), а значит
# одна и та же подстава водит обе, и сравнение ревизий остаётся осмысленным.
#
# POSIX sh.

# Диалект вложенных оболочек задаётся набором, а не хардкодом: на macOS
# /bin/sh — это bash, в CI — dash. См. шапку tests/lib/common.sh.
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { printf '[SKIP] %s — %s\n' "$1" "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="${Z2K_INSTALL_UNDER_TEST:-$ROOT/lib/install.sh}"
GEO="${Z2K_GEOSITE_UNDER_TEST:-$ROOT/files/z2k-geosite.sh}"
UL="${Z2K_UPDATE_LISTS_UNDER_TEST:-$ROOT/files/z2k-update-lists.sh}"
UTILS="$ROOT/lib/utils.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-upgrade.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

OPT="$TMP/opt"          # /opt/zapret2 песочницы
BK="$TMP/bk"            # /opt/z2k-upgrade-backup песочницы
ETC="$TMP/etc"          # /opt/etc песочницы (там живёт отпечаток fp-списка)

# ============================================================================
# 0. Опубликованная ревизия
# ============================================================================
#
# БАЗА ПРИБИТА К ТЕГУ, А НЕ К ВЕТКЕ.
#
# Здесь стояло origin/z2k-enhanced первым кандидатом. Ветка ДВИЖЕТСЯ: робот
# переводит её на каждый выпуск. Через час после релиза r-78 она указывала уже
# на наш собственный коммит, тест сравнивал дерево само с собой, и пять его
# проверок покраснели на ровном месте — включая проверки СОБСТВЕННОЙ фикстуры
# («старая ревизия разложила игровые списки»), потому что «старой» стала
# ревизия, которая эти списки уже переносит.
#
# Ожидания ниже описывают поведение КОНКРЕТНОЙ ревизии: r-77.5 (54b6765) —
# последней, где переустановка games/ не сохраняла. Поэтому и база — этот тег.
# Проверять переход со старого выпуска ценнее, чем с предпоследнего: на новый
# релиз флот переезжает не мгновенно, и апгрейд через несколько версий — самый
# частый реальный путь.
#
# Когда ожидания будут переписаны под другую базу, менять надо ЗДЕСЬ, и это
# видно: имя тега стоит первым кандидатом, а не прячется за движущейся веткой.
PUB=""
for _r in r-77.5 54b6765 origin/z2k-enhanced z2k-enhanced; do
    if git -C "$ROOT" rev-parse --verify --quiet "${_r}^{commit}" >/dev/null 2>&1; then
        PUB="$_r"; break
    fi
done
if [ -z "$PUB" ]; then
    skip "переход между ревизиями" "опубликованная ревизия недоступна (нет git-объекта z2k-enhanced)"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
    exit 0
fi

mkdir -p "$TMP/pub" "$TMP/bin"
for _f in lib/install.sh lib/config.sh files/z2k-geosite.sh files/z2k-update-lists.sh; do
    if ! git -C "$ROOT" show "$PUB:$_f" > "$TMP/pub/$(basename "$_f")" 2>/dev/null; then
        no "файлы опубликованной ревизии извлечены" "$_f" "git show $PUB:$_f не удался"
        printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
        exit 1
    fi
done
PUB_INSTALL="$TMP/pub/install.sh"
PUB_GEO="$TMP/pub/z2k-geosite.sh"
PUB_UL="$TMP/pub/z2k-update-lists.sh"
PUB_CFG="$TMP/pub/config.sh"
ok "код опубликованной ревизии извлечён ($PUB → 4 файла)"

# --- функции ревизий, вынутые для исполнения ---------------------------------
#
# Перечень имён, а не префикс: общие помощники транспорта (z2k_uint,
# z2k_connfail) живут в тех же файлах, и без них цикл Layer 0 в песочнице
# получает пустое число попыток — краснел бы харнесс, а не проверяемый код.
awk '/^(fetch_to_tmp|fetch_asset|apply_new_list|z2k_uint|z2k_connfail)\(\) \{/,/^\}/' \
    "$PUB_GEO" > "$TMP/pub_geo_fns.sh"
awk '/^(fetch_to_tmp|fetch_asset|apply_new_list|_z2k_geosite_reject|z2k_uint|z2k_connfail)\(\) \{/,/^\}/' \
    "$GEO" > "$TMP/head_geo_fns.sh"
awk '/^z2k_mark_shipped_fallback\(\) \{/,/^\}/' "$PUB_CFG" > "$TMP/pub_cfg_fns.sh"
awk '/^z2k_sha256_file\(\) \{/,/^\}/' "$UTILS" > "$TMP/sha_fn.sh"

for _p in pub_geo_fns:fetch_asset head_geo_fns:_z2k_geosite_reject \
          pub_cfg_fns:z2k_mark_shipped_fallback sha_fn:z2k_sha256_file; do
    _file="$TMP/${_p%%:*}.sh"; _fn="${_p##*:}"
    if ! grep -q "^${_fn}() {" "$_file"; then
        no "функция $_fn извлечена" "определение найдено" "нет в ${_file##*/}"
        printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
        exit 1
    fi
done
ok "функции обеих ревизий (geosite, config, utils) извлечены и исполнимы"

# --- блоки HEAD из install.sh ------------------------------------------------
z2k_extract_block "$SRC" 'if [ -d "$ZAPRET2_DIR/extra_strats" ] && mkdir -p "$backup_tmp/geosite"' '        ' > "$TMP/geo_backup.sh"
z2k_extract_block "$SRC" 'if [ -d "$Z2K_UPGRADE_BACKUP/geosite" ]; then'                           '    '     > "$TMP/geo_restore.sh"
# Бэкап WARP берётся ЦЕЛИКОМ внешним блоком: игровые списки лежат внутри него,
# и порядок «сначала личные списки и .enabled, потом games/» — часть проверяемого
# поведения, а не деталь харнесса.
z2k_extract_block "$SRC" 'if [ -d "$ZAPRET2_DIR/lists/warp" ]; then'                               '        ' > "$TMP/warp_backup.sh"
z2k_extract_block "$SRC" 'if [ -d "$backup_tmp/warp-lists" ]; then'                                '    '     > "$TMP/warp_restore.sh"
z2k_extract_block "$SRC" 'if [ -d "$backup_tmp/warp-games" ]'                                      '    '     > "$TMP/games_restore.sh"
z2k_extract_block "$SRC" 'if [ -d "$ZAPRET2_DIR/lists/custom-strategies" ]; then'                   '        ' > "$TMP/cs_backup.sh"
z2k_extract_block "$SRC" 'if [ -d "$backup_tmp/custom-strategies" ]; then'                          '    '     > "$TMP/cs_restore.sh"
z2k_extract_block "$SRC" 'if [ -f "$ZAPRET2_DIR/webpanel/port" ] || [ -f "$ZAPRET2_DIR/webpanel/bind" ]' '        ' > "$TMP/wp_backup.sh"
z2k_extract_block "$SRC" 'local _fp_list="${ZAPRET2_DIR}/lists/rkn-false-positive.txt"'            '    '     > "$TMP/fp_raw.sh"

# Отпечаток fp-списка HEAD держит по ЖЁСТКОМУ пути /opt/etc — намеренно, вне
# дерева, которое реинсталл сносит. В песочнице писать туда нельзя, поэтому
# единственная правка кода под тестом — этот префикс; что подмена состоялась,
# проверяется счётчиком, иначе тест молча гонял бы неизменённый блок.
sed "s|/opt/etc/|$ETC/|g" "$TMP/fp_raw.sh" > "$TMP/fp.sh"
_fp_subs=$(grep -c "$ETC/" "$TMP/fp.sh")
eq "жёсткий путь /opt/etc в блоке отпечатка подменён на песочницу" "1" "$_fp_subs"

for _b in geo_backup geo_restore warp_backup warp_restore games_restore cs_backup cs_restore wp_backup fp; do
    if [ ! -s "$TMP/$_b.sh" ]; then
        no "блок $_b извлечён из install.sh" "непустой блок" "пусто"
        printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
        exit 1
    fi
done
ok "блоки HEAD (geosite ×2, WARP ×3, стратегии ×2, отпечаток fp) извлечены из install.sh"

# --- подставной curl ---------------------------------------------------------
#
# Одно поле в -w: см. шапку. Отмечает КАЖДУЮ загрузку тела в $DL_LOG — так
# «не пошли в сеть» становится измеримым, а не декларируемым.
cat > "$TMP/bin/curl" <<'STUBC'
#!/bin/sh
out=""; cmp=""; save=""; hdr=""; prev=""
for a in "$@"; do
    case "$prev" in
        -o) out="$a" ;;
        --etag-compare) cmp="$a" ;;
        --etag-save) save="$a" ;;
        -D) hdr="$a" ;;
    esac
    prev="$a"
done
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
if [ -n "$cmp" ] && [ -f "$cmp" ] && [ "$(cat "$cmp" 2>/dev/null)" = "$UPSTREAM_ETAG" ]; then
    printf '304'; exit 0
fi
[ -n "$DL_LOG" ] && printf '%s\n' "$STUB_BODY" >> "$DL_LOG"
[ -n "$out" ] && printf '%s\n' "$STUB_BODY" > "$out"
[ -n "$save" ] && printf '%s' "$UPSTREAM_ETAG" > "$save"
printf '200'
exit 0
STUBC
chmod +x "$TMP/bin/curl"

# ============================================================================
# ЧАСТЬ 1. АПГРЕЙД: диск, оставленный опубликованной ревизией
# ============================================================================
#
# Раскладку делает САМ старый код. От руки пишутся только пользовательские
# файлы — те, что кладёт человек, а не программа.
seed_published_disk() {
    rm -rf "$OPT" "$BK" "$ETC"
    mkdir -p "$OPT/extra_strats/TCP/RKN" "$OPT/extra_strats/TCP/YT" "$OPT/extra_strats/UDP/YT" \
             "$OPT/extra_strats/cache/geosite-etag" \
             "$OPT/extra_strats/cache/autocircular" \
             "$OPT/lists/warp/games" "$OPT/lists/custom-strategies" "$OPT/webpanel" \
             "$OPT/ipset" "$OPT/tmp" "$BK" "$ETC" || return 1

    # --- пользовательские данные (их пишет человек, не код) ---
    printf 'GAME_WARP_ENABLED=0\nZ2K_DYNAMIC_TTL=0\nENABLED=1\nPOLICY_NAME=Zapret\n' > "$OPT/config"
    printf 'мой-сайт.example\n'        > "$OPT/lists/whitelist.txt"
    printf 'мой-домен.example\n'       > "$OPT/lists/extra-domains.txt"
    printf '203.0.113.7\n'             > "$OPT/ipset/zapret-hosts-user-exclude.txt"
    printf 'мой-warp-список\n'         > "$OPT/lists/warp/my-own.txt"
    printf 'Steam\n'                   > "$OPT/lists/warp/.enabled"
    printf '%s\n' '--dpi-desync=fake' > "$OPT/lists/custom-strategies/yt_tcp.txt"
    printf 'yt_tcp\tfake\t42\n'        > "$OPT/extra_strats/cache/autocircular/state.tsv"
    printf 'ключ-туннеля\n'            > "$OPT/.z2k-relay-id"
    mkdir -p "$OPT/webpanel"
    printf '0.0.0.0\n'                 > "$OPT/webpanel/bind"
    printf '8088\n'                    > "$OPT/webpanel/port"
    printf 'ложное.срабатывание\n'     > "$OPT/lists/rkn-false-positive.txt"
    # Шипнутый бандл, как его кладёт download_domain_lists.
    printf 'бандл-старый-a.example\nбандл-старый-b.example\n' > "$OPT/extra_strats/TCP/RKN/List.txt"
    printf 'бандл-старый-yt.example\n'                        > "$OPT/extra_strats/UDP/YT/List.txt"
    printf 'бандл-старый-ytcp.example\n'                      > "$OPT/extra_strats/TCP/YT/List.txt"

    # --- а вот это раскладывает старый код ---
    #
    # RKN: апстрим когда-то доехал. Старая fetch_asset скачивает (стаб curl),
    # старая apply_new_list кладёт цель, снимок `.shipped` и маркер `.asset`,
    # а ETag в кеш пишет сам curl через --etag-save.
    #
    # UDP/YT: geosite до этого роутера не добрался ни разу (сеть режет), и
    # цель осталась помеченной как шипнутый фоллбек — это делает
    # z2k_mark_shipped_fallback из lib/config.sh опубликованной ревизии.
    env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
        OPT="$OPT" GEOFNS="$TMP/pub_geo_fns.sh" CFGFNS="$TMP/pub_cfg_fns.sh" \
        DL_LOG="$TMP/seed-dl.log" STUB_BODY='domain:апстрим-1.example' \
        UPSTREAM_ETAG='"pub-v1"' "$Z2K_TEST_SH" -c '
            . "$CFGFNS"
            . "$GEOFNS"
            ETAG_DIR="$OPT/extra_strats/cache/geosite-etag"
            TMP_DIR="$OPT/tmp"
            RELEASE_BASE="https://example.invalid/dl"
            log() { :; }
            _z2k_vps_gh_resolve() { printf ""; }
            z2k_mark_shipped_fallback "$OPT/extra_strats/TCP/RKN/List.txt"
            z2k_mark_shipped_fallback "$OPT/extra_strats/TCP/YT/List.txt"
            z2k_mark_shipped_fallback "$OPT/extra_strats/UDP/YT/List.txt"
            fetch_asset "ru-blocked.txt" "$OPT/extra_strats/TCP/RKN/List.txt"
            fetch_asset "youtube.txt"    "$OPT/extra_strats/TCP/YT/List.txt"
        ' >/dev/null 2>&1

    # Игровые списки WARP раскладывает update_warp_game_list опубликованной
    # ревизии. Подставляется только update_list — ровно теми побочными
    # эффектами, что у настоящего: тело в $dest и ETag в ${dest}.etag (их
    # пишет _z2k_curl_etag). Всё остальное — имена, фильтр адресов, решение
    # писать или удалять .txt — настоящее.
    #
    # Steam и Roblox есть у апстрима; Fortnite апстрим ПЕРЕСТАЛ публиковать —
    # старая ревизия уборки не знала вовсе, поэтому такой список у человека
    # на диске лежит и после его исчезновения из индекса.
    printf 'Fortnite-остался-от-старой-ревизии\n' > "$OPT/lists/warp/games/Fortnite.txt"
    printf '9.9.9.9\n'                            > "$OPT/lists/warp/games/.Fortnite.raw"
    printf '"игра-fortnite-v1"'                   > "$OPT/lists/warp/games/.Fortnite.raw.etag"
    env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
        OPT="$OPT" PUB_UL="$PUB_UL" SB="$TMP" Z2K_UL_SOURCE_ONLY=1 \
        "$Z2K_TEST_SH" -c '
            # ZAPRET2_DIR ставится ПОСЛЕ сорса: файл присваивает его сам,
            # безусловно, и заданное заранее значение он затирает.
            . "$PUB_UL"
            ZAPRET2_DIR="$OPT"; LOG_FILE="$SB/ul.log"
            z2k_fetch() { cp -f "$SB/index.json" "$2" 2>/dev/null; }
            update_list() {
                _d="$3"; _g=${2##*/}; _g=${_g%.txt}
                [ -f "$SB/up/$_g.txt" ] || return 1
                cp -f "$SB/up/$_g.txt" "$_d"
                printf %s "\"игра-$_g-v1\"" > "${_d}.etag"
                return 2
            }
            update_warp_game_list
        ' >/dev/null 2>&1
}

# Апстрим-индекс и тела игровых списков — общие для обеих ревизий.
mkdir -p "$TMP/up"
printf '5.6.7.8\n9.9.9.9\n' > "$TMP/up/Steam.txt"
printf '1.1.1.1\n'           > "$TMP/up/Roblox.txt"
printf '{\n "output": {"games_dir": "games"},\n "game_map": {\n  "Steam": ["h"],\n  "Roblox": ["h"]\n },\n "domain_game_hints": {}\n}\n' > "$TMP/index.json"

seed_published_disk

# --- Инварианты фикстуры: это ДЕЙСТВИТЕЛЬНО диск старой ревизии --------------
#
# Без этой сверки набор мог бы годами гонять «HEAD поверх HEAD» под вывеской
# апгрейда: достаточно, чтобы фикстуру однажды поправили в HEAD-форму.
_pub_new=$(find "$OPT" "$ETC" \( -name '*.rejected' -o -name '*.etag.new' \
                                 -o -name '.source-count' -o -name '.source-raw-count' \
                                 -o -name '.z2k-rkn-fp.sha256' -o -name '*.carry.*' \) \
                2>/dev/null | wc -l | tr -d ' ')
eq "на диске опубликованной ревизии нет артефактов HEAD" "0" "$_pub_new"
eq "ETag записан старым кодом (прямо в кеш, без .new)" '"pub-v1"' \
   "$(cat "$OPT/extra_strats/cache/geosite-etag/ru-blocked.txt.etag" 2>/dev/null)"
eq "апстримная цель RKN собрана старым apply_new_list" "апстрим-1.example" \
   "$(cat "$OPT/extra_strats/TCP/RKN/List.txt" 2>/dev/null)"
eq "снимок .shipped оставлен старым кодом" "бандл-старый-a.example" \
   "$(head -1 "$OPT/extra_strats/TCP/RKN/List.txt.shipped" 2>/dev/null)"
eq "цель, до которой geosite не дошёл, помечена шипнутым фоллбеком" "shipped-fallback" \
   "$(cat "$OPT/extra_strats/UDP/YT/List.txt.asset" 2>/dev/null)"
_pub_games=$(ls "$OPT/lists/warp/games/"*.txt 2>/dev/null | wc -l | tr -d ' ')
_pub_raws=$(ls "$OPT/lists/warp/games/".*.raw 2>/dev/null | wc -l | tr -d ' ')
eq "старая ревизия разложила игровые списки (Steam, Roblox + осиротевший Fortnite)" "3" "$_pub_games"
eq "рядом с ними её кеш условных запросов (.<имя>.raw)" "3" "$_pub_raws"
eq "ETag игрового списка записан старым кодом" '"игра-Steam-v1"' \
   "$(cat "$OPT/lists/warp/games/.Steam.raw.etag" 2>/dev/null)"

# --- пары «сохранить X» / «вернуть X» ---------------------------------------
#
# Половинки разнесены по install.sh почти на тысячу строк и сцеплены только
# именем файла в бэкапе. Разъехаться они могут молча — человек узнает об этом
# как «настройки не пережили обновление». Поэтому драйвер собирается ИЗ САМОГО
# ИСХОДНИКА: берутся все реальные вызовы, отрезаются `||`-хвосты (die/warn —
# это реакция на сбой копирования, а не часть пары) и `if/elif ...; then`.
awk '/z2k_backup_file "/ {
        sub(/^[ \t]+/, ""); sub(/[ \t]*\|\|.*$/, ""); print }' "$SRC" > "$TMP/pairs_backup.sh"
awk '/z2k_restore_file / {
        sub(/^[ \t]+/, "");
        if (substr($0, 1, 1) == "#") next;
        sub(/^if /, ""); sub(/^elif /, "");
        sub(/;[ \t]*then[ \t]*$/, ""); sub(/[ \t]*\|\|.*$/, ""); print }' "$SRC" > "$TMP/pairs_restore.sh"
awk '/^(z2k_backup_file|z2k_restore_file)\(\) \{/,/^\}/' "$SRC" > "$TMP/pair_helpers.sh"

_nb=$(grep -c 'z2k_backup_file' "$TMP/pairs_backup.sh")
_nr=$(grep -c 'z2k_restore_file' "$TMP/pairs_restore.sh")
if [ "$_nb" -ge 3 ] && [ "$_nr" -ge 3 ] && grep -q '^z2k_restore_file() {' "$TMP/pair_helpers.sh"; then
    ok "пары бэкап/восстановление вынуты из install.sh (сохраняем ${_nb}, возвращаем ${_nr})"
else
    no "пары бэкап/восстановление вынуты" "≥3 с каждой стороны + помощники" "b=$_nb r=$_nr"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
    exit 1
fi

# --- один цикл обновления HEAD поверх старого диска --------------------------
#
# Порядок повторяет установку: бэкапы → дерево уезжает в .old (для нового
# дерева это исчезновение всего) → шаг списков кладёт СВЕЖИЙ шипнутый бандл и
# метит его как фоллбек → восстановления → перенос кеша geosite → отпечаток
# fp-списка.
head_upgrade_cycle() {
    env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
        OPT="$OPT" BK="$BK" SB="$TMP" LOG="$TMP/cycle.log" "$Z2K_TEST_SH" -c '
            ZAPRET2_DIR="$OPT"; backup_tmp="$BK"; Z2K_UPGRADE_BACKUP="$BK"
            Z2K_RESET_STATE=0
            : > "$LOG"
            print_info()    { printf "INFO %s\n" "$1" >> "$LOG"; }
            print_warning() { printf "WARN %s\n" "$1" >> "$LOG"; }
            print_success() { printf "OK %s\n"   "$1" >> "$LOG"; }
            print_error()   { printf "ERR %s\n"  "$1" >> "$LOG"; }
            die()           { printf "DIE %s\n"  "$1" >> "$LOG"; exit 90; }
            . "$SB/pair_helpers.sh"
            . "$SB/sha_fn.sh"

            rm -rf "$backup_tmp"; mkdir -p "$backup_tmp"
            _bw() { . "$SB/warp_backup.sh"; . "$SB/cs_backup.sh"; . "$SB/wp_backup.sh"; }; _bw
            _bg() { . "$SB/geo_backup.sh";  }; _bg
            . "$SB/pairs_backup.sh"

            # mv "$ZAPRET2_DIR" .old.$$ — для нового дерева это исчезновение
            # всего содержимого.
            rm -rf "$ZAPRET2_DIR"
            mkdir -p "$ZAPRET2_DIR/lists/warp" "$ZAPRET2_DIR/lists" \
                     "$ZAPRET2_DIR/extra_strats/TCP/RKN" "$ZAPRET2_DIR/extra_strats/TCP/YT" \
                     "$ZAPRET2_DIR/extra_strats/UDP/YT" \
                     "$ZAPRET2_DIR/extra_strats/cache/autocircular"
            # Шаг 8 кладёт СВЕЖИЙ шипнутый бандл и метит его происхождение —
            # ровно то, что делает download_domain_lists через
            # z2k_mark_shipped_fallback.
            printf "бандл-СВЕЖИЙ-a.example\n" > "$ZAPRET2_DIR/extra_strats/TCP/RKN/List.txt"
            printf "бандл-СВЕЖИЙ-yt.example\n" > "$ZAPRET2_DIR/extra_strats/UDP/YT/List.txt"
            printf "бандл-СВЕЖИЙ-ytcp.example\n" > "$ZAPRET2_DIR/extra_strats/TCP/YT/List.txt"
            printf "shipped-fallback\n" > "$ZAPRET2_DIR/extra_strats/TCP/RKN/List.txt.asset"
            printf "shipped-fallback\n" > "$ZAPRET2_DIR/extra_strats/UDP/YT/List.txt.asset"
            printf "shipped-fallback\n" > "$ZAPRET2_DIR/extra_strats/TCP/YT/List.txt.asset"
            # …и шипнутый список ложных срабатываний.
            printf "ложное.срабатывание\n" > "$ZAPRET2_DIR/lists/rkn-false-positive.txt"

            _rw() { . "$SB/warp_restore.sh"; . "$SB/cs_restore.sh"; }; _rw
            _rg() { . "$SB/games_restore.sh"; }; _rg
            . "$SB/pairs_restore.sh"
            _rc() { . "$SB/geo_restore.sh"; }; _rc
            _fp() { . "$SB/fp.sh"; };          _fp
        ' 2>>"$TMP/cycle.err"
}

head_upgrade_cycle
_cycle_rc=$?
eq "цикл обновления прошёл без аварийного die" "0" "$_cycle_rc"

# --- 1.1 Пользовательские данные целы и не задвоены --------------------------
#
# Каждое имя, которое восстановление ИЩЕТ в бэкапе, обязано кем-то туда
# класться. Имя без пары — это молча потерянная настройка: восстановление
# просто ничего не находит и печатает тишину.
_orphan=""
while IFS= read -r _rl; do
    _rn=$(printf '%s\n' "$_rl" | awk '{print $2}')
    [ -n "$_rn" ] || continue
    grep -q "z2k_backup_file .* $_rn\$" "$TMP/pairs_backup.sh" || _orphan="$_orphan $_rn"
done < "$TMP/pairs_restore.sh"
eq "у каждого восстановления есть парный бэкап" "" "$_orphan"

eq "доменные исключения пережили апгрейд"      "мой-сайт.example"  "$(cat "$OPT/lists/whitelist.txt" 2>/dev/null)"
eq "state.tsv пережил апгрейд"                 "yt_tcp	fake	42" "$(cat "$OPT/extra_strats/cache/autocircular/state.tsv" 2>/dev/null)"
eq "идентичность туннеля пережила апгрейд"     "ключ-туннеля"      "$(cat "$OPT/.z2k-relay-id" 2>/dev/null)"
eq "личный список WARP пережил апгрейд"        "мой-warp-список"   "$(cat "$OPT/lists/warp/my-own.txt" 2>/dev/null)"
eq "пользовательская стратегия пережила апгрейд" "--dpi-desync=fake" \
   "$(cat "$OPT/lists/custom-strategies/yt_tcp.txt" 2>/dev/null)"
eq "выбор включённых игр (.enabled) пережил апгрейд" "Steam"       "$(cat "$OPT/lists/warp/.enabled" 2>/dev/null)"
# Адрес вебпанели. Возвращает его step_finalize (это пинит
# test_webpanel_bind_survives_update); здесь проверяется другое и специфичное
# для перехода между ревизиями: раскладка на диске СТАРОЙ ревизии — та самая,
# из которой бэкап HEAD его и читает. Разъедься путь между ревизиями — адрес
# терялся бы молча, а меню обещает, что он переживёт обновление.
eq "адрес вебпанели со старого диска попал в бэкап" "0.0.0.0" \
   "$(cat "$BK/webpanel-bind" 2>/dev/null)"
eq "порт вебпанели тоже" "8088" "$(cat "$BK/webpanel-port" 2>/dev/null)"
# Не задвоены: личный список остаётся ОДНИМ файлом в lists/warp и не уезжает
# заодно в games/, а строки внутри не удваиваются повторным cp.
eq "личный список не размножился по дереву" "1" \
   "$(find "$OPT" -name 'my-own.txt' 2>/dev/null | wc -l | tr -d ' ')"
eq "строки личного списка не задвоились" "1" \
   "$(wc -l < "$OPT/lists/warp/my-own.txt" 2>/dev/null | tr -d ' ')"

# --- 1.2 Кеш geosite перенесён, а шипнутый фоллбек — НЕТ ---------------------
#
# Это и есть обещание ARCHITECTURE.md: пользовательское переживает, а
# поставляемые списки заменяются свежими. Цель, которую старый код пометил
# `shipped-fallback` (geosite до этого роутера не доехал), переносить нельзя:
# иначе прошлогодняя копия легла бы поверх бандла, только что записанного
# шагом списков, geosite ответил бы «unchanged» — и правки шипнутых списков не
# приезжали бы на такой роутер уже никогда.
eq "ETag geosite перенесён — апстрим спросят условным запросом" '"pub-v1"' \
   "$(cat "$OPT/extra_strats/cache/geosite-etag/youtube.txt.etag" 2>/dev/null)"
eq "апстримная цель перенесена и перекрыла свежий бандл" "апстрим-1.example" \
   "$(cat "$OPT/extra_strats/TCP/RKN/List.txt" 2>/dev/null)"
eq "маркер происхождения перенесён (иначе 304 не примут)" "ru-blocked.txt" \
   "$(cat "$OPT/extra_strats/TCP/RKN/List.txt.asset" 2>/dev/null)"
eq "снимок .shipped старой ревизии пережил апгрейд" "бандл-старый-a.example" \
   "$(head -1 "$OPT/extra_strats/TCP/RKN/List.txt.shipped" 2>/dev/null)"
eq "цель с пометкой shipped-fallback НЕ перенесена — победил свежий бандл" \
   "бандл-СВЕЖИЙ-yt.example" "$(cat "$OPT/extra_strats/UDP/YT/List.txt" 2>/dev/null)"
eq "и её маркер остался фоллбековым" "shipped-fallback" \
   "$(cat "$OPT/extra_strats/UDP/YT/List.txt.asset" 2>/dev/null)"
# Временные копии переноса (.carry.<pid>) не имеют права оставаться на диске:
# это полные копии целей, а на роутере они по мегабайту.
eq "после переноса не осталось временных копий" "0" \
   "$(find "$OPT" -name '*.carry.*' 2>/dev/null | wc -l | tr -d ' ')"

# --- 1.3 Игровые списки: артефакта, которого ждёт HEAD, ещё нет --------------
#
# Счётчиков полноты (.source-count/.source-raw-count) на старом диске нет — их
# заводит сам бэкап HEAD. Проверяем, что он их и завёл, а перенос прошёл
# целиком: гейт «games/ пуст» после этого обязан пропустить загрузку.
eq "игровые списки перенесены полностью" "3" \
   "$(ls "$OPT/lists/warp/games/"*.txt 2>/dev/null | wc -l | tr -d ' ')"
eq "кеш условных запросов перенесён вместе с ними" "3" \
   "$(ls "$OPT/lists/warp/games/".*.raw 2>/dev/null | wc -l | tr -d ' ')"
eq "ETag игрового списка перенесён" '"игра-Steam-v1"' \
   "$(cat "$OPT/lists/warp/games/.Steam.raw.etag" 2>/dev/null)"
eq "содержимое игрового списка доехало неповреждённым" "5.6.7.8" \
   "$(head -1 "$OPT/lists/warp/games/Steam.txt" 2>/dev/null)"

# --- 1.5 Первый ночной прогон ПОСЛЕ апгрейда --------------------------------
#
# Тут и выясняется, был ли перенос настоящим. Перенесённый кеш обязан дать
# условный запрос (тела не качаем), а санитайзер — собрать .txt из ТОГО ЖЕ
# .raw. И заодно всплывает мусор, который опубликованная ревизия собрать не
# умела: уборки в ней нет вовсе, поэтому список игры, выпавшей из
# апстрим-индекса, лежал на диске вечно.
env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
    OPT="$OPT" UL="$UL" SB="$TMP" Z2K_UL_SOURCE_ONLY=1 "$Z2K_TEST_SH" -c '
        . "$UL"
        ZAPRET2_DIR="$OPT"; LOG_FILE="$SB/ul-head.log"
        : > "$SB/nightly-dl.log"
        z2k_fetch() { cp -f "$SB/index.json" "$2" 2>/dev/null; }
        # Контракт настоящей update_list: 0 — не изменилось (условный запрос
        # получил 304, тело не качали), 2 — обновилось, 1 — не вышло.
        update_list() {
            _d="$3"; _g=${2##*/}; _g=${_g%.txt}
            if [ -s "$_d" ] && [ -f "${_d}.etag" ]; then return 0; fi
            [ -f "$SB/up/$_g.txt" ] || return 1
            printf %s\\n "$_g" >> "$SB/nightly-dl.log"
            cp -f "$SB/up/$_g.txt" "$_d"
            printf %s "\"игра-$_g-v2\"" > "${_d}.etag"
            return 2
        }
        update_warp_game_list
    ' >/dev/null 2>&1
eq "ночной прогон после апгрейда не скачал ни одного тела" "0" \
   "$(wc -l < "$TMP/nightly-dl.log" 2>/dev/null | tr -d ' ')"
eq "…и пересобрал список из перенесённого кеша" "5.6.7.8" \
   "$(head -1 "$OPT/lists/warp/games/Steam.txt" 2>/dev/null)"
eq "…не потеряв ни одной строки" "2" \
   "$(wc -l < "$OPT/lists/warp/games/Steam.txt" 2>/dev/null | tr -d ' ')"
eq "выпавшая из индекса игра убрана вместе со своим кешем" "нет" \
   "$([ -f "$OPT/lists/warp/games/Fortnite.txt" ] || [ -f "$OPT/lists/warp/games/.Fortnite.raw" ] \
       || [ -f "$OPT/lists/warp/games/.Fortnite.raw.etag" ] && echo есть || echo нет)"
eq "личный список WARP уборка не тронула" "мой-warp-список" \
   "$(cat "$OPT/lists/warp/my-own.txt" 2>/dev/null)"

# --- 1.4 Артефакт, которого на старом диске ещё нет: отпечаток fp-списка -----
#
# HEAD перестал звать geosite с --force, а --force среди прочего возвращал в
# RKN-хостлист домены, вычеркнутые из rkn-false-positive.txt: список умеет
# только ВЫЧИТАТЬ, и вернуть домен может лишь полная пересборка цели из
# апстрима. Взамен заведён отпечаток шипнутого списка — файл, которого на
# диске опубликованной ревизии нет по определению.
#
# Поведение на первом апгрейде обязано быть консервативным: отпечатка нет,
# значит сравнить не с чем, значит ETag RKN снимаем и собираем хостлист
# заново. Молча — человеку сообщать не о чем, у него ничего не менялось.
eq "первый апгрейд снял ETag RKN (сравнить с чем — нечем)" "нет" \
   "$([ -f "$OPT/extra_strats/cache/geosite-etag/ru-blocked.txt.etag" ] && echo есть || echo нет)"
eq "…и ETag второго класса RKN тоже" "нет" \
   "$([ -f "$OPT/extra_strats/cache/geosite-etag/ru-blocked-all.txt.etag" ] && echo есть || echo нет)"
eq "…но ETag прочих ассетов не тронут" '"pub-v1"' \
   "$(cat "$OPT/extra_strats/cache/geosite-etag/youtube.txt.etag" 2>/dev/null)"
eq "отпечаток записан" "1" \
   "$([ -s "$ETC/.z2k-rkn-fp.sha256" ] && echo 1 || echo 0)"
eq "первый апгрейд молчит про РКН — у человека ничего не менялось" "0" \
   "$(grep -c 'ложных срабатываний' "$TMP/cycle.log" 2>/dev/null | tr -d ' ')"

# Повторный апгрейд с ТЕМ ЖЕ шипнутым списком: ETag снимать больше не за что,
# ускорение обязано вернуться. И наоборот — правка списка обязана снова
# пересобрать хостлист, теперь уже вслух.
FPOPT="$TMP/fp-opt"
fp_cycle() {  # fp_cycle <содержимое rkn-false-positive.txt> → "<ETag жив?>:<сказали ли вслух>"
    rm -rf "$FPOPT"; mkdir -p "$FPOPT/lists" "$FPOPT/extra_strats/cache/geosite-etag"
    printf '%s\n' "$1" > "$FPOPT/lists/rkn-false-positive.txt"
    # ETag, как его вернул бы очередной ночной прогон geosite.
    printf '"pub-v2"' > "$FPOPT/extra_strats/cache/geosite-etag/ru-blocked.txt.etag"
    env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
        OPT="$FPOPT" ETC="$ETC" SB="$TMP" LOG="$TMP/fp.log" "$Z2K_TEST_SH" -c '
            ZAPRET2_DIR="$OPT"; : > "$LOG"
            print_info() { printf "INFO %s\n" "$1" >> "$LOG"; }
            . "$SB/sha_fn.sh"
            _f() { . "$SB/fp.sh"; }; _f
        ' >/dev/null 2>&1
    printf '%s:%s' \
        "$([ -f "$FPOPT/extra_strats/cache/geosite-etag/ru-blocked.txt.etag" ] && echo жив || echo снят)" \
        "$(grep -c 'ложных срабатываний' "$TMP/fp.log" 2>/dev/null | tr -d ' ')"
}
eq "повторный апгрейд с тем же списком ETag не трогает — экономия сохранена" "жив:0" \
   "$(fp_cycle 'ложное.срабатывание')"
eq "правка шипнутого списка пересобирает RKN и говорит об этом вслух" "снят:1" \
   "$(fp_cycle 'ложное.срабатывание
ещё.одно.ложное')"

# Отпечаток обязан лежать ВНЕ дерева: всё, что внутри, реинсталл уносит в .old
# вместе с деревом, и механизм сам себя обнулял бы на каждой установке — то
# есть RKN качался бы целиком при КАЖДОЙ установке, ровно как с --force.
# Проверяем действием: сносим дерево, как это делает step_build_zapret2.
fp_cycle 'отпечаток.вне.дерева' >/dev/null
_fp_before=$(cat "$ETC/.z2k-rkn-fp.sha256" 2>/dev/null)
rm -rf "$FPOPT"
eq "отпечаток пережил снос дерева установкой" "$_fp_before" \
   "$(cat "$ETC/.z2k-rkn-fp.sha256" 2>/dev/null)"
eq "…и он непустой (иначе сверять было бы не с чем)" "1" \
   "$([ -s "$ETC/.z2k-rkn-fp.sha256" ] && echo 1 || echo 0)"

# ============================================================================
# ЧАСТЬ 2. ОТКАТ: диск, оставленный HEAD, отдают опубликованной ревизии
# ============================================================================
#
# Авто-обновление умеет откатываться, и откат — это установка СТАРОГО кода
# поверх состояния, которое оставил новый. Проверять тут нечего только на
# словах: HEAD завёл четыре вида артефактов, которых старая ревизия не знает
# (`.rejected` в кеше ETag, дотфайлы кеша игровых списков, перенесённые ETag,
# отпечаток fp-списка вне дерева). Требование к откату минимальное и жёсткое:
# не упасть, не потерять пользовательское, не оставить роутер без обхода.

# Маркер карантина кладёт САМ HEAD — своей настоящей функцией.
env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
    OPT="$OPT" SB="$TMP" "$Z2K_TEST_SH" -c '
        . "$SB/head_geo_fns.sh"
        ETAG_DIR="$OPT/extra_strats/cache/geosite-etag"
        TMP_DIR="$OPT/tmp"; mkdir -p "$TMP_DIR"
        log() { :; }
        _z2k_geosite_reject "youtube.txt"
    ' >/dev/null 2>&1
eq "HEAD оставил маркер карантина .rejected" '"pub-v1"' \
   "$(cat "$OPT/extra_strats/cache/geosite-etag/youtube.txt.rejected" 2>/dev/null)"
# …а следующей ночью апстрим опубликовал новую версию, и HEAD её забрал. ETag
# в кеш пишет при этом САМ HEAD — через временный `${etag}.new` и mv. Это и
# есть тот артефакт, который потом достанется откату: подделывать его руками
# нельзя, иначе часть 2 проверяла бы фикстуру, а не код.
env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
    OPT="$OPT" SB="$TMP" DL_LOG="$TMP/head-night.log" \
    STUB_BODY='domain:апстрим-1.example' UPSTREAM_ETAG='"pub-v2"' "$Z2K_TEST_SH" -c '
        . "$SB/head_geo_fns.sh"
        ETAG_DIR="$OPT/extra_strats/cache/geosite-etag"
        TMP_DIR="$OPT/tmp"; rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
        RELEASE_BASE="https://example.invalid/dl"
        log() { :; }
        _z2k_vps_gh_resolve() { printf ""; }
        fetch_asset "youtube.txt" "$OPT/extra_strats/TCP/YT/List.txt"
    ' >/dev/null 2>&1
eq "HEAD довёл свежий ETag до рабочего кеша (через .new + mv)" '"pub-v2"' \
   "$(cat "$OPT/extra_strats/cache/geosite-etag/youtube.txt.etag" 2>/dev/null)"
eq "…и не оставил после себя недоделанного .new" "0" \
   "$(find "$OPT" -name '*.etag.new' 2>/dev/null | wc -l | tr -d ' ')"

# Снимок диска, оставленного HEAD. Установка ниже сносит дерево, а старым
# geosite и старой обновлялке нужно то же самое состояние — гоняем их по копии.
HL="$TMP/head-left"
rm -rf "$HL"; cp -R "$OPT" "$HL"

# --- блоки опубликованной ревизии --------------------------------------------
z2k_extract_block "$PUB_INSTALL" 'if [ -d "$ZAPRET2_DIR/lists/warp" ]; then'                              '        ' > "$TMP/o_warp_b.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -d "$backup_tmp/warp-lists" ]; then'                               '    '     > "$TMP/o_warp_r.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -d "$ZAPRET2_DIR/lists/custom-strategies" ]; then'                 '        ' > "$TMP/o_cs_b.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -d "$backup_tmp/custom-strategies" ]; then'                        '    '     > "$TMP/o_cs_r.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -f "$ZAPRET2_DIR/lists/whitelist.txt" ]; then'                     '        ' > "$TMP/o_wl_b.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -f "$backup_tmp/whitelist.txt" ]; then'                            '        ' > "$TMP/o_wl_r.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -f "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv" ]; then' '        ' > "$TMP/o_st_b.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -f "$backup_tmp/state.tsv" ]; then'                                '        ' > "$TMP/o_st_r.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -f "$ZAPRET2_DIR/.z2k-relay-id" ]; then'                           '        ' > "$TMP/o_id_b.sh"
z2k_extract_block "$PUB_INSTALL" 'if [ -f "$backup_tmp/z2k-relay-id" ]; then'                             '        ' > "$TMP/o_id_r.sh"
# Гейт загрузки игровых списков — дословно из опубликованной ревизии.
OGATE=$(grep -n 'lists/warp/games/"\*\.txt 2>/dev/null)" \]; then' "$PUB_INSTALL" \
        | head -1 | sed 's/^[0-9]*: *//; s/; then$//; s/^if //')

_o_missing=""
for _b in o_warp_b o_warp_r o_cs_b o_cs_r o_wl_b o_wl_r o_st_b o_st_r o_id_b o_id_r; do
    [ -s "$TMP/$_b.sh" ] || _o_missing="$_o_missing $_b"
done
if [ -z "$_o_missing" ] && [ -n "$OGATE" ]; then
    ok "блоки опубликованной ревизии извлечены (10 половинок + гейт игровых списков)"
else
    no "блоки опубликованной ревизии извлечены" "все 10 + гейт" "нет:${_o_missing:-—} гейт:${OGATE:-нет}"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
    exit 1
fi

# --- 2.1 Старая установка поверх состояния HEAD ------------------------------
BK2="$TMP/bk-rollback"
env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
    OPT="$OPT" BK="$BK2" SB="$TMP" LOG="$TMP/rollback.log" GATEEXPR="$OGATE" \
    "$Z2K_TEST_SH" -c '
        ZAPRET2_DIR="$OPT"; backup_tmp="$BK"
        Z2K_RESET_STATE=0
        : > "$LOG"
        print_info()    { printf "INFO %s\n" "$1" >> "$LOG"; }
        print_warning() { printf "WARN %s\n" "$1" >> "$LOG"; }
        print_success() { printf "OK %s\n"   "$1" >> "$LOG"; }
        die()           { printf "DIE %s\n"  "$1" >> "$LOG"; exit 90; }
        rm -rf "$backup_tmp"; mkdir -p "$backup_tmp"
        _b() {
            . "$SB/o_wl_b.sh"; . "$SB/o_warp_b.sh"; . "$SB/o_cs_b.sh"
            . "$SB/o_st_b.sh"; . "$SB/o_id_b.sh"
        }; _b
        rm -rf "$ZAPRET2_DIR"
        mkdir -p "$ZAPRET2_DIR/lists/warp" "$ZAPRET2_DIR/extra_strats/cache/autocircular"
        _r() {
            . "$SB/o_warp_r.sh"; . "$SB/o_cs_r.sh"; . "$SB/o_wl_r.sh"
            . "$SB/o_st_r.sh"; . "$SB/o_id_r.sh"
        }; _r
        # Гейт старой ревизии: после её установки games/ пуст, значит списки
        # обязаны поехать из сети — иначе роутер остался бы без них.
        if eval "$GATEEXPR"; then printf "СЕТЬ" > "$SB/ogate.out"; else printf "ПРОПУСК" > "$SB/ogate.out"; fi
    ' 2>>"$TMP/rollback.err"
_rb_rc=$?

eq "откатная установка не упала аварийно" "0" "$_rb_rc"
eq "и ни одного die в её журнале" "0" "$(grep -c '^DIE' "$TMP/rollback.log" 2>/dev/null | tr -d ' ')"
eq "доменные исключения пережили откат"  "мой-сайт.example" "$(cat "$OPT/lists/whitelist.txt" 2>/dev/null)"
eq "личный список WARP пережил откат"    "мой-warp-список"  "$(cat "$OPT/lists/warp/my-own.txt" 2>/dev/null)"
eq "выбор включённых игр пережил откат"  "Steam"            "$(cat "$OPT/lists/warp/.enabled" 2>/dev/null)"
eq "пользовательская стратегия пережила откат" "--dpi-desync=fake" \
   "$(cat "$OPT/lists/custom-strategies/yt_tcp.txt" 2>/dev/null)"
eq "state.tsv пережил откат" "yt_tcp	fake	42" \
   "$(cat "$OPT/extra_strats/cache/autocircular/state.tsv" 2>/dev/null)"
eq "идентичность туннеля пережила откат" "ключ-туннеля" "$(cat "$OPT/.z2k-relay-id" 2>/dev/null)"
eq "личный список не задвоился при откате" "1" \
   "$(wc -l < "$OPT/lists/warp/my-own.txt" 2>/dev/null | tr -d ' ')"
# Игровые списки старая ревизия не переносит — и не должна: они восстановимы
# загрузкой. Важно, что она это ЗАМЕТИТ и пойдёт за ними, а не оставит роутер
# с пустым каталогом.
eq "после отката старый гейт видит пустой games/ и идёт в сеть" "СЕТЬ" \
   "$(cat "$TMP/ogate.out" 2>/dev/null)"

# --- 2.2 Старый geosite поверх артефактов HEAD -------------------------------
#
# В кеше лежит `.rejected` — файл, которого опубликованная ревизия не знает
# вовсе. Требование: он не мешает. Ни на условном запросе (304 по
# перенесённому ETag), ни на настоящей загрузке.
old_geo() {   # old_geo <ETag апстрима> → "<rc>:<скачано тел>"
    rm -rf "$HL/tmp"; mkdir -p "$HL/tmp"
    : > "$TMP/rb-dl.log"
    env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
        HL="$HL" FNS="$TMP/pub_geo_fns.sh" DL_LOG="$TMP/rb-dl.log" \
        STUB_BODY='domain:после-отката.example' UPSTREAM_ETAG="$1" \
        "$Z2K_TEST_SH" -c '
            . "$FNS"
            ETAG_DIR="$HL/extra_strats/cache/geosite-etag"
            TMP_DIR="$HL/tmp"
            RELEASE_BASE="https://example.invalid/dl"
            log() { :; }
            _z2k_vps_gh_resolve() { printf ""; }
            fetch_asset "youtube.txt" "$HL/extra_strats/TCP/YT/List.txt"
            printf "%s" "$?" > "$HL/rc.out"
        ' >/dev/null 2>&1
    printf '%s:%s' "$(cat "$HL/rc.out" 2>/dev/null)" \
                   "$(wc -l < "$TMP/rb-dl.log" 2>/dev/null | tr -d ' ')"
}

eq "старый geosite принял перенесённый ETag: 304, ни байта в сеть" "0:0" \
   "$(old_geo '"pub-v2"')"
eq "…и цель осталась той же" "апстрим-1.example" \
   "$(cat "$HL/extra_strats/TCP/YT/List.txt" 2>/dev/null)"
eq "…маркер карантина от HEAD его не смутил" '"pub-v1"' \
   "$(cat "$HL/extra_strats/cache/geosite-etag/youtube.txt.rejected" 2>/dev/null)"

eq "апстрим сменился — старый geosite качает и применяет" "0:1" \
   "$(old_geo '"pub-v3"')"
eq "…цель обновилась, роутер не остался без списка" "после-отката.example" \
   "$(cat "$HL/extra_strats/TCP/YT/List.txt" 2>/dev/null)"
eq "…снимок .shipped не затёрт апстримом" "бандл-старый-ytcp.example" \
   "$(head -1 "$HL/extra_strats/TCP/YT/List.txt.shipped" 2>/dev/null)"
eq "…ETag обновлён прямо в кеше, как это делает старый код" '"pub-v3"' \
   "$(cat "$HL/extra_strats/cache/geosite-etag/youtube.txt.etag" 2>/dev/null)"

# --- 2.3 Старая обновлялка поверх кеша игровых списков от HEAD ---------------
#
# HEAD перенёс через реинсталл дотфайлы `.<имя>.raw` и `.<имя>.raw.etag`.
# Опубликованная ревизия читает их теми же именами — значит откат обязан
# получить условный запрос, а не перекачку, и собрать .txt из того же кеша.
: > "$TMP/rb-games-dl.log"
env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
    HL="$HL" PUB_UL="$PUB_UL" SB="$TMP" Z2K_UL_SOURCE_ONLY=1 "$Z2K_TEST_SH" -c '
        . "$PUB_UL"
        ZAPRET2_DIR="$HL"; LOG_FILE="$SB/ul-rollback.log"
        z2k_fetch() { cp -f "$SB/index.json" "$2" 2>/dev/null; }
        update_list() {
            _d="$3"; _g=${2##*/}; _g=${_g%.txt}
            if [ -s "$_d" ] && [ -f "${_d}.etag" ]; then return 0; fi
            [ -f "$SB/up/$_g.txt" ] || return 1
            printf %s\\n "$_g" >> "$SB/rb-games-dl.log"
            cp -f "$SB/up/$_g.txt" "$_d"
            return 2
        }
        update_warp_game_list
    ' >/dev/null 2>&1
eq "старая обновлялка приняла кеш HEAD: ни одного тела в сеть" "0" \
   "$(wc -l < "$TMP/rb-games-dl.log" 2>/dev/null | tr -d ' ')"
eq "…и собрала список из того же .raw" "5.6.7.8" \
   "$(head -1 "$HL/lists/warp/games/Steam.txt" 2>/dev/null)"
eq "…все игровые списки на месте" "2" \
   "$(ls "$HL/lists/warp/games/"*.txt 2>/dev/null | wc -l | tr -d ' ')"
eq "…личный список WARP не тронут" "мой-warp-список" \
   "$(cat "$HL/lists/warp/my-own.txt" 2>/dev/null)"

# --- 2.4 Отпечаток fp-списка после отката ------------------------------------
#
# Он лежит вне дерева и переживает откат. Старый код его не читает и читать не
# должен — но и мешать он не имеет права: при откате установка зовёт geosite с
# --force, то есть сносит ETag-кеш сама, и хостлист РКН пересобирается из
# апстрима независимо от любых отпечатков.
eq "отпечаток пережил откат и никому не помешал" "1" \
   "$([ -s "$ETC/.z2k-rkn-fp.sha256" ] && echo 1 || echo 0)"
if grep -q 'rm -f "$ETAG_DIR"/\*\.etag' "$PUB_GEO"; then
    ok "--force опубликованной ревизии сносит ETag-кеш сам — откат не залипает на перенесённом ETag"
else
    no "--force старой ревизии сносит ETag-кеш" "rm -f \$ETAG_DIR/*.etag" "не найдено"
fi

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
