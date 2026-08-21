#!/bin/sh
# tests/test_geosite_cache_survives_reinstall.sh — установка не имеет права
# качать заново то, что уже лежит на устройстве и не изменилось у апстрима.
#
# ЗАЧЕМ. Установка звала geosite так:
#
#     FORCE_REFETCH=1 sh "$geosite" fetch --force
#
# а --force первым делом сносит ETag-кеш. То есть механика условных запросов,
# сделанная ровно для того, чтобы не тянуть неизменившееся, выключалась руками
# на каждой установке. Замер 2026-08-21 на роутере Марка: 52.7 с из 405.
#
# Убрать один --force было бы бесполезно: и ETag-кеш, и сами цели лежат ВНУТРИ
# ${ZAPRET2_DIR}, которое step_build_zapret2 уводит в .old.$$. После этого 304
# получать не на что — цель пуста или содержит shipped-снимок. Поэтому правка
# из двух половин: перенести кеш через пересборку дерева И снять --force.
#
# ПОЧЕМУ СНЯТЬ --force БЕЗОПАСНО. Он закрывал один случай: протухший ETag
# отдаёт 304, а в цели при этом лежит shipped-файл, и мы его закрепляем. С тех
# пор этот случай закрыт строже — маркером происхождения `${target}.asset` в
# fetch_asset: 304 принимается, ТОЛЬКО если цель собрана именно этим
# источником, иначе ETag сносится и загрузка идёт заново. --force дублировал
# более слабой мерой то, что уже сделано более сильной, и стоил при этом
# полной перекачки.
#
# Это утверждение здесь не декларируется, а проверяется: раздел «В» гоняет
# настоящие fetch_to_tmp/fetch_asset из z2k-geosite.sh с подставным curl.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="${Z2K_INSTALL_UNDER_TEST:-$ROOT/lib/install.sh}"
GEO="${Z2K_GEOSITE_UNDER_TEST:-$ROOT/files/z2k-geosite.sh}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-geocache.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# ============================================================================
# А. Сцепка: --force снят, и снят он не «просто так»
# ============================================================================

if grep -q 'FORCE_REFETCH=1 sh "$geosite"' "$SRC" || grep -q 'sh "$geosite" fetch --force' "$SRC"; then
    no "установка не форсирует перекачку geosite" "fetch без --force" "--force/FORCE_REFETCH на месте"
else
    ok "установка зовёт geosite без --force"
fi

# Маркер происхождения — то, что заменило --force. Исчезнет он — снятие
# --force перестанет быть безопасным, и узнать об этом надо здесь, а не по
# жалобам на залипший shipped-список.
if grep -q 'asset_marker="${target}.asset"' "$GEO" && grep -q 'prev_asset_304' "$GEO"; then
    ok "маркер происхождения (.asset) в geosite на месте — он и заменяет --force"
else
    no "маркер происхождения в geosite" "asset_marker + проверка на 304" "не найден"
fi

# ============================================================================
# Б. Перенос кеша через пересборку дерева
# ============================================================================
#
# `awk -v` обрабатывает escape-последовательности, поэтому ищем ПОДСТРОКУ.
extract_block() {  # extract_block <опорная подстрока> <отступ>
    awk -v pat="$1" -v ind="$2" '
        index($0, pat) > 0 { inb = 1 }
        inb { print }
        inb && $0 == ind "fi" { exit }
    ' "$SRC"
}
extract_block 'if [ -d "$ZAPRET2_DIR/extra_strats" ] && mkdir -p "$backup_tmp/geosite"' '        ' > "$TMP/backup.sh"
extract_block 'if [ -d "$Z2K_UPGRADE_BACKUP/geosite" ]; then'                           '    '     > "$TMP/restore.sh"

for b in backup restore; do
    if [ -s "$TMP/$b.sh" ] && grep -q 'geosite' "$TMP/$b.sh"; then
        ok "блок $b извлечён из install.sh"
    else
        no "блок $b извлечён" "непустой блок" "пусто"
        printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"; exit 1
    fi
done

cycle() {  # cycle <есть ли что переносить: 1/0>
    _have="$1"
    rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/bk"
    mkdir -p "$TMP/opt/extra_strats/TCP/RKN" "$TMP/opt/extra_strats/cache/geosite-etag"
    if [ "$_have" = "1" ]; then
        printf 'prev.example.com\n'   > "$TMP/opt/extra_strats/TCP/RKN/List.txt"
        printf 'shipped.example.com\n' > "$TMP/opt/extra_strats/TCP/RKN/List.txt.shipped"
        printf 'ru-blocked.txt\n'   > "$TMP/opt/extra_strats/TCP/RKN/List.txt.asset"
        printf '"старый-etag"\n'    > "$TMP/opt/extra_strats/cache/geosite-etag/ru-blocked.txt.etag"
    fi

    env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" /bin/sh -c '
        ZAPRET2_DIR="$SB/opt"; backup_tmp="$SB/bk"; Z2K_UPGRADE_BACKUP="$SB/bk"
        print_info() { :; }; print_warning() { :; }
        _b() { . "$SB/backup.sh"; }; _b
        # mv дерева в .old.$$ — для нового дерева это исчезновение содержимого.
        rm -rf "$ZAPRET2_DIR"
        mkdir -p "$ZAPRET2_DIR/extra_strats/TCP/RKN"
        # …и shipped-снимок, который кладёт download_domain_lists.
        printf "shipped-снимок\n" > "$ZAPRET2_DIR/extra_strats/TCP/RKN/List.txt"
        _r() { . "$SB/restore.sh"; }; _r
    ' 2>/dev/null
}

cycle 1
if [ "$(cat "$TMP/opt/extra_strats/cache/geosite-etag/ru-blocked.txt.etag" 2>/dev/null)" = '"старый-etag"' ]; then
    ok "ETag пережил пересборку дерева"
else
    no "ETag пережил пересборку" '"старый-etag"' "$(cat "$TMP/opt/extra_strats/cache/geosite-etag/ru-blocked.txt.etag" 2>/dev/null)"
fi
if [ "$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt" 2>/dev/null)" = "prev.example.com" ]; then
    ok "цель пережила пересборку и перекрыла shipped-снимок"
else
    no "цель пережила пересборку" "prev.example.com" "$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt" 2>/dev/null)"
fi
if [ "$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt.asset" 2>/dev/null)" = "ru-blocked.txt" ]; then
    ok "маркер происхождения пережил пересборку"
else
    no "маркер происхождения пережил пересборку" "ru-blocked.txt" "нет"
fi

cycle 0
if [ "$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt" 2>/dev/null)" = "shipped-снимок" ]; then
    ok "на свежей установке переносить нечего — shipped-снимок не тронут"
else
    no "свежая установка" "shipped-снимок" "$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt" 2>/dev/null)"
fi

# ============================================================================
# В. Настоящий geosite: доказываем, что 304-путь работает и когда надо — не
#    срабатывает. Это и есть обоснование снятия --force.
# ============================================================================
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUBC'
#!/bin/sh
# Эмулируем --etag-compare/--etag-save: 304, если присланный ETag совпал
# с апстримным. Каждая ЗАГРУЗКА ТЕЛА отмечается в $DL_LOG.
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
printf 'СКАЧАНО\n' >> "$DL_LOG"
[ -n "$out" ] && printf 'свежий.домен\n' > "$out"
[ -n "$save" ] && printf '%s' "$UPSTREAM_ETAG" > "$save"
printf '200'
exit 0
STUBC
chmod +x "$TMP/bin/curl"

awk '/^(fetch_to_tmp|fetch_asset)\(\) \{/,/^\}/' "$GEO" > "$TMP/geo_fns.sh"
if grep -q '^fetch_asset() {' "$TMP/geo_fns.sh" && grep -q '^fetch_to_tmp() {' "$TMP/geo_fns.sh"; then
    ok "fetch_to_tmp/fetch_asset извлечены из z2k-geosite.sh"
else
    no "функции geosite извлечены" "обе" "не найдены"
    printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"; exit 1
fi

# geo <etag на диске?> <маркер на диске?> → "<rc>:<сколько раз качали тело>"
geo() {
    _etag="$1"; _marker="$2"
    _g="$TMP/geo"; rm -rf "$_g"; mkdir -p "$_g/etag" "$_g/tmp" "$_g/t"
    printf 'prev.example.com\n' > "$_g/t/List.txt"
    [ "$_etag"   = "1" ] && printf '"апстрим-v1"' > "$_g/etag/ru-blocked.txt.etag"
    [ "$_marker" = "1" ] && printf 'ru-blocked.txt\n' > "$_g/t/List.txt.asset"

    env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
        G="$_g" FNS="$TMP/geo_fns.sh" DL_LOG="$_g/dl.log" \
        UPSTREAM_ETAG="${3:-\"апстрим-v1\"}" /bin/sh -c '
            : > "$DL_LOG"
            . "$FNS"
            ETAG_DIR="$G/etag"; TMP_DIR="$G/tmp"
            RELEASE_BASE="https://example.invalid/dl"
            log() { :; }
            _z2k_vps_gh_resolve() { printf ""; }
            # Применение — только то, что важно этому тесту: содержимое цели
            # и маркер происхождения рядом с ней.
            apply_new_list() { cp -f "$1" "$2" && printf "%s\n" "$3" > "$2.asset"; }
            if fetch_asset "ru-blocked.txt" "$G/t/List.txt"; then rc=0; else rc=1; fi
            n=$(grep -c СКАЧАНО "$DL_LOG" 2>/dev/null); [ -n "$n" ] || n=0
            printf "%s:%s" "$rc" "$n"
        ' 2>/dev/null
}

# 1) Перенесли всё: etag + цель + маркер. Апстрим не изменился → 0 загрузок.
r=$(geo 1 1)
case "$r" in
    0:0) ok "перенесённый кеш даёт 304 и НИ ОДНОЙ загрузки тела" ;;
    *)   no "перенесённый кеш даёт 0 загрузок" "0:0" "$r" ;;
esac

# 2) ETag перенесён, а маркера нет (в цели shipped-файл) — ровно тот случай,
#    ради которого стоял --force. Загрузка ОБЯЗАНА произойти.
r=$(geo 1 0)
case "$r" in
    0:1) ok "ETag без маркера происхождения не закрепляет shipped-файл — качаем заново" ;;
    *)   no "304 без маркера форсирует перекачку" "0:1" "$r" ;;
esac

# 3) Апстрим изменился → ETag не совпал → качаем.
r=$(geo 1 1 '"апстрим-v2"')
case "$r" in
    0:1) ok "изменившийся апстрим скачивается, кеш не залипает" ;;
    *)   no "изменившийся апстрим скачивается" "0:1" "$r" ;;
esac

# 4) Свежая установка: ETag'а нет вовсе → качаем.
r=$(geo 0 0)
case "$r" in
    0:1) ok "без ETag (свежая установка) загрузка идёт как раньше" ;;
    *)   no "без ETag загрузка идёт" "0:1" "$r" ;;
esac

# --- Б2. Порядок в исходнике, а не только в песочнице ------------------------
#
# Харнесс выше гоняет блоки в порядке, который сам же и задаёт. Реальный
# порядок — «download_domain_lists → восстановление → geosite fetch» — держит
# на себе всю правку: восстановишь ДО shipped-списков, и они затрут перенос;
# восстановишь ПОСЛЕ fetch — переносить будет уже поздно. Здесь пинится он.
_ln_ship=$(grep -n 'download_domain_lists ||' "$SRC" | head -1 | cut -d: -f1)
_ln_rest=$(grep -n 'if \[ -d "\$Z2K_UPGRADE_BACKUP/geosite" \]; then' "$SRC" | head -1 | cut -d: -f1)
_ln_fetch=$(grep -n 'sh "\$geosite" fetch' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_ln_ship" ] && [ -n "$_ln_rest" ] && [ -n "$_ln_fetch" ] \
   && [ "$_ln_ship" -lt "$_ln_rest" ] && [ "$_ln_rest" -lt "$_ln_fetch" ]; then
    ok "восстановление стоит после shipped-списков (${_ln_ship}) и до fetch (${_ln_fetch})"
else
    no "порядок: shipped → восстановление → fetch" "строки по возрастанию" \
       "shipped=${_ln_ship:-нет} restore=${_ln_rest:-нет} fetch=${_ln_fetch:-нет}"
fi

# Бэкап обязан стоять ДО переноса дерева в .old.$$ — иначе копировать уже нечего.
_ln_bk=$(grep -n 'mkdir -p "\$backup_tmp/geosite"' "$SRC" | head -1 | cut -d: -f1)
_ln_mv=$(grep -n 'if mv "\$ZAPRET2_DIR" "\$_old_tree"' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_ln_bk" ] && [ -n "$_ln_mv" ] && [ "$_ln_bk" -lt "$_ln_mv" ]; then
    ok "бэкап кеша geosite стоит до mv дерева в .old (${_ln_bk} < ${_ln_mv})"
else
    no "бэкап до mv дерева" "backup < mv" "backup=${_ln_bk:-нет} mv=${_ln_mv:-нет}"
fi

# ============================================================================
# Г. Порча не переносится, а .shipped переносится
# ============================================================================
#
# Порчу раньше лечила сама переустановка: цель пересевалась с нуля. Теперь она
# переносится, а 304-путь содержимого не проверяет — забитый 0xFF файл остался
# бы живым --hostlist навсегда. Отдельно: .shipped обязан доехать, иначе
# обещанный в шапке geosite ручной откат `cp *.shipped <name>` откатывал бы на
# апстримный список вместо шипнутого.
cycle 1
if [ "$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt.shipped" 2>/dev/null)" = "shipped.example.com" ]; then
    ok ".shipped пережил пересборку — ручной откат остался откатом"
else
    no ".shipped пережил пересборку" "shipped.example.com" \
       "$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt.shipped" 2>/dev/null)"
fi

rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/bk"
mkdir -p "$TMP/opt/extra_strats/TCP/RKN" "$TMP/opt/extra_strats/cache/geosite-etag"
printf '\377\377\377\377\377\377\377\377\n' > "$TMP/opt/extra_strats/TCP/RKN/List.txt"
printf 'ru-blocked.txt\n' > "$TMP/opt/extra_strats/TCP/RKN/List.txt.asset"
env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" /bin/sh -c '
    ZAPRET2_DIR="$SB/opt"; backup_tmp="$SB/bk"; Z2K_UPGRADE_BACKUP="$SB/bk"
    print_info() { :; }; print_warning() { :; }
    _b() { . "$SB/backup.sh"; }; _b
    rm -rf "$ZAPRET2_DIR"; mkdir -p "$ZAPRET2_DIR/extra_strats/TCP/RKN"
    printf "shipped.example.com\n" > "$ZAPRET2_DIR/extra_strats/TCP/RKN/List.txt"
    _r() { . "$SB/restore.sh"; }; _r
' 2>/dev/null
_got=$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt" 2>/dev/null)
_mk=$([ -f "$TMP/opt/extra_strats/TCP/RKN/List.txt.asset" ] && echo есть || echo нет)
if [ "$_got" = "shipped.example.com" ] && [ "$_mk" = "нет" ]; then
    ok "битый список (0xFF) не переносится, и маркер за ним не кладётся"
else
    no "битый список не переносится" "цель=shipped.example.com, маркер=нет" "цель=${_got}, маркер=${_mk}"
fi

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
