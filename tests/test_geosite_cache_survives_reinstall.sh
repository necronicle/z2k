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

# Диалект вложенных оболочек задаётся набором, а не хардкодом: на macOS
# /bin/sh — это bash, в CI — dash, и один и тот же тест под ними ведёт себя
# по-разному. См. шапку tests/lib/common.sh.
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

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
# Экстрактор общий (tests/lib/common.sh) — байт-в-байт та же awk-выборка была
# скопирована в тесте игровых списков, третьей копией стал бы каждый новый.
z2k_extract_block "$SRC" 'if [ -d "$ZAPRET2_DIR/extra_strats" ] && mkdir -p "$backup_tmp/geosite"' '        ' > "$TMP/backup.sh"
z2k_extract_block "$SRC" 'if [ -d "$Z2K_UPGRADE_BACKUP/geosite" ]; then'                           '    '     > "$TMP/restore.sh"

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

    env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
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

# ПЕРЕЧЕНЬ ИМЁН, А НЕ ПРЕФИКС: общие помощники транспорта (z2k_uint,
# z2k_connfail) живут в том же файле и без них цикл Layer 0 в песочнице
# получает пустое число попыток — то есть краснеет харнесс, а не проверяемый
# код. Новый общий помощник обязан появиться и здесь.
awk '/^(fetch_to_tmp|fetch_asset|apply_new_list|_z2k_geosite_reject|z2k_uint|z2k_connfail)\(\) \{/,/^\}/' "$GEO" > "$TMP/geo_fns.sh"
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
        UPSTREAM_ETAG="${3:-\"апстрим-v1\"}" "$Z2K_TEST_SH" -c '
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
env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
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

# ============================================================================
# Д. Сквозной цикл ETag: первый запрос сохраняет, ВТОРОЙ обязан дать 304
# ============================================================================
#
# Разделы выше клали etag-файл в фикстуре руками и потому проверяли только
# ПОТРЕБЛЕНИЕ кеша, а не его ЗАПИСЬ. Этого мало: --etag-save пишет в отдельный
# файл (${etag_file}.new), и если перенос в рабочий etag_file пропадёт, кеш
# перестанет существовать вовсе — каждый прогон пойдёт за полным телом, а все
# прежние проверки останутся зелёными. Ровно так один раз и случилось: патч
# наложился наполовину, --etag-save уехал в .new, а переноса не было.
#
# Здесь etag-файл НЕ создаётся заранее. Два запроса подряд, каждый со своим
# TMP_DIR (иначе fetch_to_tmp отдаст кеш этого же прогона), общий ETAG_DIR.
_g2="$TMP/geo2"; rm -rf "$_g2"; mkdir -p "$_g2/etag" "$_g2/t"
printf 'prev.example.com\n' > "$_g2/t/List.txt"
printf 'ru-blocked.txt\n'   > "$_g2/t/List.txt.asset"
_cycle_run() {
    rm -rf "$_g2/tmp$1"; mkdir -p "$_g2/tmp$1"
    env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
        G="$_g2" FNS="$TMP/geo_fns.sh" DL_LOG="$_g2/dl$1.log" \
        UPSTREAM_ETAG='"апстрим-v1"' N="$1" "$Z2K_TEST_SH" -c '
            : > "$DL_LOG"
            . "$FNS"
            ETAG_DIR="$G/etag"; TMP_DIR="$G/tmp$N"
            RELEASE_BASE="https://example.invalid/dl"
            log() { :; }
            _z2k_vps_gh_resolve() { printf ""; }
            apply_new_list() { cp -f "$1" "$2" && printf "%s\n" "$3" > "$2.asset"; }
            fetch_asset "ru-blocked.txt" "$G/t/List.txt" >/dev/null 2>&1
            n=$(grep -c СКАЧАНО "$DL_LOG" 2>/dev/null); [ -n "$n" ] || n=0
            printf "%s" "$n"
        ' 2>/dev/null
}
_d1=$(_cycle_run 1)
_d2=$(_cycle_run 2)
_etag_saved=$([ -s "$_g2/etag/ru-blocked.txt.etag" ] && echo да || echo нет)
if [ "$_d1" = "1" ] && [ "$_d2" = "0" ] && [ "$_etag_saved" = "да" ]; then
    ok "ETag сохраняется первым запросом и работает на втором (загрузки 1 → 0)"
else
    no "сквозной цикл ETag" "загрузки 1 → 0, etag сохранён" \
       "загрузки ${_d1} → ${_d2}, etag сохранён=${_etag_saved}"
fi


# ============================================================================
# Е. Отказ применения обязан снимать ETag, иначе он залипает и ИСЧЕЗАЕТ ИЗ ОТЧЁТА
# ============================================================================
#
# fetch_to_tmp переносит ETag в рабочий кеш сразу по ответу 200 — до того, как
# выяснится, ляжет ли содержимое в цель. Если apply_new_list откажет (страж
# усадки, обрубок нормализации, провал записи), ETag всё равно записан, и
# следующий прогон получает честный 304: цель непустая, маркер происхождения
# совпадает (источник тот же) — и fetch_asset рапортует «unchanged, keep
# existing» с кодом 0. Отказ закрепляется до следующей смены апстрима, а
# счётчик failed обнуляется, то есть в отчёте его не видно вовсе.
#
# Раньше замок ломала установка своим --force. Она это делать перестала.
# Здесь гоняется НАСТОЯЩИЙ apply_new_list со своим стражем усадки.
_g3="$TMP/geo3"; rm -rf "$_g3"; mkdir -p "$_g3/etag" "$_g3/t"
_i=1; : > "$_g3/t/List.txt"
while [ "$_i" -le 100 ]; do printf 'host%s.example.com\n' "$_i" >> "$_g3/t/List.txt"; _i=$((_i+1)); done
printf 'ru-blocked.txt\n' > "$_g3/t/List.txt.asset"
printf '"upstream-v1"'    > "$_g3/etag/ru-blocked.txt.etag"

# апстрим усох вдвое и сменил ETag → 200, страж усадки обязан отвергнуть
cat > "$TMP/bin/shrunk" <<'SH'
#!/bin/sh
i=1; while [ "$i" -le 50 ]; do printf 'host%s.example.com\n' "$i"; i=$((i+1)); done
SH
chmod +x "$TMP/bin/shrunk"
_run3() {
    rm -rf "$_g3/tmp$1"; mkdir -p "$_g3/tmp$1"
    env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
        G="$_g3" FNS="$TMP/geo_fns.sh" DL_LOG="$_g3/dl$1.log" \
        UPSTREAM_ETAG="$2" N="$1" "$Z2K_TEST_SH" -c '
            : > "$DL_LOG"
            . "$FNS"
            ETAG_DIR="$G/etag"; TMP_DIR="$G/tmp$N"
            RELEASE_BASE="https://example.invalid/dl"
            log() { :; }
            _z2k_vps_gh_resolve() { printf ""; }
            if fetch_asset "ru-blocked.txt" "$G/t/List.txt"; then rc=0; else rc=1; fi
            n=$(grep -c СКАЧАНО "$DL_LOG" 2>/dev/null); [ -n "$n" ] || n=0
            printf "rc=%s качали=%s" "$rc" "$n"
        ' 2>/dev/null
}
# стаб отдаёт усохший список
sed -i.bak 's|printf .свежий\.домен\\n. > "$out"|"$SHRUNK" > "$out"|' "$TMP/bin/curl" 2>/dev/null || true
cp "$TMP/bin/curl" "$TMP/bin/curl.orig"
cat > "$TMP/bin/curl" <<'STUBC'
#!/bin/sh
out=""; cmp=""; save=""; hdr=""; prev=""
for a in "$@"; do
    case "$prev" in
        -o) out="$a" ;; --etag-compare) cmp="$a" ;; --etag-save) save="$a" ;; -D) hdr="$a" ;;
    esac
    prev="$a"
done
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
if [ -n "$cmp" ] && [ -f "$cmp" ] && [ "$(cat "$cmp" 2>/dev/null)" = "$UPSTREAM_ETAG" ]; then
    printf '304'; exit 0
fi
printf 'СКАЧАНО\n' >> "$DL_LOG"
[ -n "$out" ] && shrunk > "$out"
[ -n "$save" ] && printf '%s' "$UPSTREAM_ETAG" > "$save"
printf '200'
exit 0
STUBC
chmod +x "$TMP/bin/curl"

_r1=$(_run3 1 '"upstream-v2"')          # 200, страж отвергает
_etag_after=$([ -s "$_g3/etag/ru-blocked.txt.etag" ] && echo остался || echo снят)
_r2=$(_run3 2 '"upstream-v2"')          # апстрим не менялся

if [ "$_etag_after" = "снят" ]; then
    ok "отказ стража усадки снимает ETag"
else
    no "отказ стража усадки снимает ETag" "снят" "остался — отказ залипнет"
fi
case "$_r2" in
    *"качали=1"*) ok "после отказа следующий прогон ПОВТОРЯЕТ загрузку, а не рапортует «unchanged»" ;;
    *) no "после отказа идёт повторная попытка" "качали=1" "$_r2 (отказ исчез из отчёта)" ;;
esac
# цель при этом не испорчена — остался прежний стослойный список
_tl=$(wc -l < "$_g3/t/List.txt" 2>/dev/null | tr -d ' ')
if [ "$_tl" = "100" ]; then
    ok "цель не испорчена отвергнутым списком (осталось $_tl строк)"
else
    no "цель не испорчена" "100 строк" "$_tl"
fi
cp "$TMP/bin/curl.orig" "$TMP/bin/curl" 2>/dev/null || true


# ============================================================================
# Ж. geosite — ЧЕТВЁРТАЯ копия транспорта: тот же бюджет и тот же повтор
# ============================================================================
#
# У этого файла собственный curl на VPS, и правка Layer 0 (бюджет 3 с + вторая
# попытка) до него сначала не доехала: тут был зашит --connect-timeout 15 без
# повторов. Один потерянный пакет рукопожатия стоил 15 с на VPS-хопе плюс
# столько же на прямом, и так на каждый ассет.
#
# Здесь пинится и повтор, и то, что при ВЫКЛЮЧЕННОМ Layer 0 запрос всё равно
# делается: раньше первый curl и был прямым, и цикл не должен был это сломать.
_g4="$TMP/geo4"; rm -rf "$_g4"; mkdir -p "$_g4/bin" "$_g4/etag" "$_g4/tmp" "$_g4/t"
cat > "$_g4/bin/curl" <<'STUBD'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
    *--resolve*)
        n=$(cat "$CALLS.v" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$CALLS.v"
        if [ "$n" = "1" ]; then printf '000 0.000000'; exit 28; fi ;;
esac
prev=""; out=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf 'ok.example.com\n' > "$out"
printf '200 0.075'
exit 0
STUBD
chmod +x "$_g4/bin/curl"
_geo4() {  # _geo4 <включён ли Layer 0>
    : > "$_g4/calls"; rm -f "$_g4/calls.v"; rm -rf "$_g4/tmp"; mkdir -p "$_g4/tmp"
    env -i PATH="$_g4/bin:/usr/bin:/bin" HOME="$TMP" G="$_g4" FNS="$TMP/geo_fns.sh" \
        CALLS="$_g4/calls" L0="$1" "$Z2K_TEST_SH" -c '
            . "$FNS"
            ETAG_DIR="$G/etag"; TMP_DIR="$G/tmp"; RELEASE_BASE="https://example.invalid/dl"
            log() { :; }
            if [ "$L0" = "1" ]; then _z2k_vps_gh_resolve() { printf " --resolve h:443:203.0.113.9"; }
            else _z2k_vps_gh_resolve() { printf ""; }; fi
            fetch_to_tmp "ru-blocked.txt" >/dev/null 2>&1
            v=$(grep -c -- "--resolve" "$CALLS" 2>/dev/null); [ -n "$v" ] || v=0
            d=$(grep -vc -- "--resolve" "$CALLS" 2>/dev/null); [ -n "$d" ] || d=0
            printf "vps=%s direct=%s" "$v" "$d"
        ' 2>/dev/null
}
_r4=$(_geo4 1)
case "$_r4" in
    "vps=2 direct=0") ok "geosite повторяет VPS-хоп на потерянном рукопожатии и не уходит в прямой" ;;
    *) no "geosite повторяет VPS-хоп" "vps=2 direct=0" "$_r4" ;;
esac
_b4=$(grep -- "--resolve" "$_g4/calls" 2>/dev/null | sed -n 's/.*--connect-timeout \([^ ]*\).*/\1/p' | sort -u | tr '\n' ',' | sed 's/,$//')
# 3 -> 8 секунд, 26.08.2026, одновременно во всех четырёх копиях транспорта.
# Три секунды — это один ретрансмит SYN: на плохом канале рукопожатие в них не
# укладывается, и клиент уходил на зеркала при ЖИВОМ VPS. Прямой путь у geosite
# по-прежнему держит свои 15 с — там запасного пути за спиной нет.
if [ "$_b4" = "8" ]; then
    ok "бюджет VPS-хопа geosite = 8 с (было 3, до того зашито 15)"
else
    no "бюджет VPS-хопа geosite" "8" "${_b4:-нет}"
fi
_r5=$(_geo4 0)
case "$_r5" in
    "vps=0 direct=1") ok "при выключенном Layer 0 запрос всё равно делается, ровно один" ;;
    *) no "выключенный Layer 0 не отменяет запрос" "vps=0 direct=1" "$_r5" ;;
esac
_b5=$(grep -v -- "--resolve" "$_g4/calls" 2>/dev/null | sed -n 's/.*--connect-timeout \([^ ]*\).*/\1/p' | sort -u | tr '\n' ',' | sed 's/,$//')
if [ "$_b5" = "15" ]; then
    ok "без Layer 0 бюджет остаётся 15 с — за этим запросом никого нет"
else
    no "бюджет без Layer 0" "15" "${_b5:-нет}"
fi


# ============================================================================
# З. Карантин: повтор ОДИН раз на версию, а не каждую ночь
# ============================================================================
#
# Снимать ETag на каждом отказе нельзя. Разовый отказ (обрубок нормализации при
# нехватке места в /tmp, провал записи) повтора заслуживает. А стойкий — апстрим
# правда опубликовал список ниже 80% — превращал бы один дешёвый 304 в полную
# перекачку КАЖДУЮ ночь: ru-blocked ~1.7 МБ, ru-blocked-all ~33 МБ, и всё через
# нормализацию в тмпфс, который здесь RAM. Различаем по ETag отвергнутой версии.
#
# Продолжение сценария раздела Е: апстрим остаётся усохшим и не меняется.
# Повтор уже состоялся в разделе Е (прогон 2 качал заново). Здесь смотрим, что
# он был ПОСЛЕДНИМ для этой версии: карантин уже проставлен.
_r3=$(_run3 3 '"upstream-v2"')
case "$_r3" in
    *"качали=0"*) ok "после единственного повтора та же версия больше не качается" ;;
    *) no "повтор был последним для версии" "качали=0" "$_r3 (качали бы каждую ночь)" ;;
esac
_r4=$(_run3 4 '"upstream-v2"')
case "$_r4" in
    *"качали=0"*) ok "ТРЕТЬЕЙ перекачки той же версии нет — карантин держит" ;;
    *) no "третьей перекачки нет" "качали=0" "$_r4 (качали бы каждую ночь)" ;;
esac
_tl3=$(wc -l < "$_g3/t/List.txt" 2>/dev/null | tr -d ' ')
if [ "$_tl3" = "100" ]; then
    ok "цель всё это время держит прежний список ($_tl3 строк)"
else
    no "цель держит прежний список" "100 строк" "$_tl3"
fi


# ============================================================================
# И. Оборванная на середине загрузка НЕ считается успехом
# ============================================================================
#
# curl печатает %{http_code}=200, даже когда тело оборвалось: rc=18 (partial
# file), rc=56 (reset), rc=23 (write error на забитой флешке), rc=28 (упор в
# --speed-time). В цели тогда огрызок — НЕПУСТОЙ, то есть проверку `-s` он
# проходит. Дальше огрызок уезжает в цель, рядом встаёт маркер происхождения,
# ETag ПОЛНОЙ версии уходит в кеш — и следующий прогон отвечает «unchanged».
# Список замирает огрызком до следующей публикации апстрима, а geosite
# рапортует «ok» и выходит с нулём.
#
# На чистом устройстве ловить это больше нечем: страж усадки там намеренно
# пропущен (происхождения цели ещё нет), а внутренний порог 50% сравнивает
# нормализованный вывод с тем же огрызком на входе.
_g5="$TMP/geo5"; rm -rf "$_g5"; mkdir -p "$_g5/bin" "$_g5/etag" "$_g5/tmp" "$_g5/t"
cat > "$_g5/bin/curl" <<'STUBE'
#!/bin/sh
prev=""; out=""; save=""
for a in "$@"; do
    case "$prev" in -o) out="$a" ;; --etag-save) save="$a" ;; esac
    prev="$a"
done
# тело оборвалось на середине: непустой огрызок, код 200, НЕнулевой возврат
[ -n "$out" ] && printf 'огрызок.example.com\n' > "$out"
[ -n "$save" ] && printf '"полная-версия"' > "$save"
printf '200 0.075'
exit 18
STUBE
chmod +x "$_g5/bin/curl"
_trunc=$(env -i PATH="$_g5/bin:/usr/bin:/bin" HOME="$TMP" G="$_g5" FNS="$TMP/geo_fns.sh" "$Z2K_TEST_SH" -c '
    . "$FNS"
    ETAG_DIR="$G/etag"; TMP_DIR="$G/tmp"; RELEASE_BASE="https://example.invalid/dl"
    log() { :; }
    _z2k_vps_gh_resolve() { printf ""; }
    if fetch_to_tmp "ru-blocked.txt"; then rc=0; else rc=$?; fi
    printf "rc=%s тело=%s etag=%s" "$rc" \
        "$([ -s "$G/tmp/ru-blocked.txt" ] && echo осталось || echo снято)" \
        "$([ -s "$G/etag/ru-blocked.txt.etag" ] && echo принят || echo отвергнут)"
' 2>/dev/null)
case "$_trunc" in
    "rc=1 тело=снято etag=отвергнут")
        ok "оборванная загрузка отвергнута: огрызок снят, ETag не принят" ;;
    *)  no "оборванная загрузка отвергнута" "rc=1 тело=снято etag=отвергнут" \
           "$_trunc — огрызок уедет в цель и замрёт там" ;;
esac


# ============================================================================
# К. Обрубок не переносится — он из печатных символов, 0xFF-проверки мало
# ============================================================================
#
# Обрубленный список — валидный текст: полсписка доменов проходит любую
# проверку на печатность. А попав в цель вместе с маркером происхождения и
# ETag, он замирает там до следующей публикации апстрима: на 304 geosite
# смотрит только на непустоту цели и совпадение маркера. Раньше это лечила
# сама переустановка, пересевая цель с нуля; перенос это самолечение отменил.
rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/bk"
mkdir -p "$TMP/opt/extra_strats/TCP/RKN" "$TMP/opt/extra_strats/cache/geosite-etag"
printf 'a.example.com\nb.exa' > "$TMP/opt/extra_strats/TCP/RKN/List.txt"   # обрыв посреди строки
printf 'ru-blocked.txt\n' > "$TMP/opt/extra_strats/TCP/RKN/List.txt.asset"
env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
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
    ok "обрубок не перенесён, маркер за ним не положен — список скачается заново"
else
    no "обрубок не переносится" "цель=shipped.example.com, маркер=нет" "цель=${_got}, маркер=${_mk}"
fi


# ============================================================================
# Л. Шипнутая цель НЕ переносится — свежий бандл обязан победить снимок
# ============================================================================
#
# Тот же маркер *.asset пишет не только geosite. lib/config.sh
# (z2k_mark_shipped_fallback) кладёт в него слово shipped-fallback на списки ИЗ
# БАНДЛА — TCP/YT, TCP/RKN, UDP/YT и TCP_Discord помечаются так на КАЖДОЙ
# установке. Пока перенос смотрел только на наличие маркера, он тащил вперёд и
# их, а это регресс с бесконечным сроком: на роутере, где geosite ни разу не
# доехал (сеть режет), реинсталл клал прошлогоднюю копию поверх бандла,
# который шаг списков только что записал, geosite отвечал «keeping existing» —
# и правки поставляемых списков не приезжали бы туда уже НИКОГДА. ARCHITECTURE
# обещает обратное: поставляемые списки заменяются.
#
# Проверяем обе цели за один цикл, чтобы отличить «не переносит шипнутое» от
# «не переносит вообще ничего».
rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/bk"
mkdir -p "$TMP/opt/extra_strats/TCP/RKN" "$TMP/opt/extra_strats/TCP/YT" \
         "$TMP/opt/extra_strats/cache/geosite-etag"
printf 'upstream.example.com\n' > "$TMP/opt/extra_strats/TCP/RKN/List.txt"
printf 'ru-blocked.txt\n'       > "$TMP/opt/extra_strats/TCP/RKN/List.txt.asset"
printf 'прошлогодний-бандл.example\n' > "$TMP/opt/extra_strats/TCP/YT/List.txt"
printf 'shipped-fallback\n'           > "$TMP/opt/extra_strats/TCP/YT/List.txt.asset"
env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
    ZAPRET2_DIR="$SB/opt"; backup_tmp="$SB/bk"; Z2K_UPGRADE_BACKUP="$SB/bk"
    print_info() { :; }; print_warning() { :; }
    _b() { . "$SB/backup.sh"; }; _b
    rm -rf "$ZAPRET2_DIR"
    mkdir -p "$ZAPRET2_DIR/extra_strats/TCP/RKN" "$ZAPRET2_DIR/extra_strats/TCP/YT"
    # …и свежий бандл, который download_domain_lists только что записал.
    printf "свежий-бандл.example\n" > "$ZAPRET2_DIR/extra_strats/TCP/YT/List.txt"
    printf "shipped-fallback\n"     > "$ZAPRET2_DIR/extra_strats/TCP/YT/List.txt.asset"
    printf "shipped-снимок\n"       > "$ZAPRET2_DIR/extra_strats/TCP/RKN/List.txt"
    _r() { . "$SB/restore.sh"; }; _r
' 2>/dev/null
_yt=$(cat "$TMP/opt/extra_strats/TCP/YT/List.txt" 2>/dev/null)
_yt_bk=$([ -f "$TMP/bk/geosite/targets/extra_strats/TCP/YT/List.txt" ] && echo взят || echo пропущен)
_rkn=$(cat "$TMP/opt/extra_strats/TCP/RKN/List.txt" 2>/dev/null)
if [ "$_yt" = "свежий-бандл.example" ] && [ "$_yt_bk" = "пропущен" ]; then
    ok "цель с маркером shipped-fallback не переносится — свежий бандл остался на месте"
else
    no "shipped-fallback не переносится" "цель=свежий-бандл.example, в бэкапе=пропущен" \
       "цель=${_yt}, в бэкапе=${_yt_bk}"
fi
if [ "$_rkn" = "upstream.example.com" ]; then
    ok "цель с апстримным маркером переносится как раньше — гейт бьёт по слову, а не по всем подряд"
else
    no "апстримная цель переносится" "upstream.example.com" "${_rkn}"
fi


# ============================================================================
# М. Смена шипнутого списка ложных срабатываний обязана пересобрать RKN
# ============================================================================
#
# subtract_false_positive_from_rkn умеет только ВЫЧИТАТЬ. Домен, который мы из
# rkn-false-positive.txt убрали (перепроверили — он таки блокируется), в цель
# сам не вернётся: она собирается один раз при загрузке апстрима, дальше
# только урезается. Раньше возврат делала сама установка своим --force: ETag
# сносился, RKN качался целиком, вычитание шло уже новым списком. --force
# снят, ETag переносится — и правка доезжает до роутера файлом, но в хостлисте
# не отражается до ближайшего переиздания апстрима.
#
# Гейт по отпечатку. Ускорение установки при этом обязано остаться: в обычной
# установке список тот же, и 304 работает как задумано.
awk '/^z2k_sha256_file\(\) \{/,/^\}/' "$ROOT/lib/utils.sh" > "$TMP/sha.sh"
if grep -q '^z2k_sha256_file() {' "$TMP/sha.sh"; then
    ok "z2k_sha256_file извлечена из lib/utils.sh (считает НАСТОЯЩИЙ отпечаток)"
else
    no "z2k_sha256_file извлечена" "функция" "не найдена"
fi

# Единственная подмена в извлечённом блоке — абсолютный путь отпечатка.
# Держать его вне дерева обязательно (дерево умирает на каждой переустановке),
# но писать в настоящий /opt/etc с теста нельзя. Что подмена состоялась,
# проверяем: иначе тест молча проверял бы пустоту.
mkdir -p "$TMP/fp"
z2k_extract_block "$SRC" 'local _fp_list=' '    ' \
    | sed "s|/opt/etc/\.z2k-rkn-fp\.sha256|$TMP/fp/mark|" > "$TMP/fp.sh"
if grep -q "$TMP/fp/mark" "$TMP/fp.sh" && ! grep -q '/opt/etc' "$TMP/fp.sh" \
   && grep -q 'ru-blocked-all.txt.etag' "$TMP/fp.sh"; then
    ok "гейт по отпечатку извлечён, путь отпечатка уведён в песочницу"
else
    no "гейт по отпечатку извлечён" "блок с обоими ETag и путём в песочнице" \
       "$(head -c 120 "$TMP/fp.sh")"
fi

_fp_run() {  # _fp_run <содержимое шипнутого списка> → "<ru>:<all>:<сказал ли>"
    rm -rf "$TMP/fp/tree"
    mkdir -p "$TMP/fp/tree/lists" "$TMP/fp/tree/extra_strats/cache/geosite-etag"
    printf '%s\n' "$1" > "$TMP/fp/tree/lists/rkn-false-positive.txt"
    printf '"etag-ru"\n'  > "$TMP/fp/tree/extra_strats/cache/geosite-etag/ru-blocked.txt.etag"
    printf '"etag-all"\n' > "$TMP/fp/tree/extra_strats/cache/geosite-etag/ru-blocked-all.txt.etag"
    _said=$(env -i PATH="/usr/bin:/bin" HOME="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
        ZAPRET2_DIR="$SB/fp/tree"
        print_info() { printf "СКАЗАЛ" ; }
        . "$SB/sha.sh"
        _fp() { . "$SB/fp.sh"; }
        _fp
    ' 2>/dev/null)
    printf '%s:%s:%s' \
        "$([ -f "$TMP/fp/tree/extra_strats/cache/geosite-etag/ru-blocked.txt.etag" ] && echo цел || echo снят)" \
        "$([ -f "$TMP/fp/tree/extra_strats/cache/geosite-etag/ru-blocked-all.txt.etag" ] && echo цел || echo снят)" \
        "${_said:-молчал}"
}

# 1) Первая установка: отпечатка ещё нет. ETag снимаем — сравнивать не с чем,
#    и ошибаться тут надо в сторону перекачки. Человеку при этом сказать
#    нечего: с его точки зрения ничего не менялось.
r=$(_fp_run 'vk.com')
case "$r" in
    "снят:снят:молчал") ok "первая установка (отпечатка нет): ETag обоих RKN-ассетов снесён, молча" ;;
    *) no "первая установка снимает ETag" "снят:снят:молчал" "$r" ;;
esac

# 2) Обычная установка: список тот же. ETag обязан уцелеть — иначе гейт стоил
#    бы полной перекачки RKN (1,7 МБ / 33 МБ) на КАЖДОЙ установке, то есть
#    ровно того, ради чего снимался --force.
r=$(_fp_run 'vk.com')
case "$r" in
    "цел:цел:молчал") ok "повторная установка с тем же списком: ETag цел, ускорение не потеряно" ;;
    *) no "тот же список не трогает ETag" "цел:цел:молчал" "$r" ;;
esac

# 3) Список ложных срабатываний изменился — RKN обязан собраться из апстрима
#    заново, и об этом надо сказать: перекачка на 33 МБ не должна выглядеть
#    зависанием.
r=$(_fp_run 'vk.com
ok.ru')
case "$r" in
    "снят:снят:СКАЗАЛ") ok "изменившийся fp-список снимает ETag обоих RKN-ассетов и говорит об этом" ;;
    *) no "изменившийся fp-список снимает ETag" "снят:снят:СКАЗАЛ" "$r" ;;
esac


# ============================================================================
# Н. Порядок бэкапа: дешёвое и незаменимое — раньше объёмного geosite
# ============================================================================
#
# Перенос geosite-целей это около 2,5 МБ по умолчанию и около 26 МБ на
# роутере, выбравшем ru-blocked-all. Пока он шёл первым, место на /opt
# кончалось именно на том, что идёт следом, — а следом лежат две вещи по
# несколько байт, которые загрузкой не восстанавливаются: идентичность туннеля
# (переминт = осиротевшая запись в реестре) и адрес вебпанели. Наблюдать это в
# песочнице нечем — порядок пинится по исходнику, как и в разделе Б2.
_ln_relay=$(grep -n 'z2k_backup_file "\$ZAPRET2_DIR/\.z2k-relay-id"' "$SRC" | head -1 | cut -d: -f1)
_ln_wp=$(grep -n 'cp -f "\$ZAPRET2_DIR/webpanel/\$_wpf"' "$SRC" | head -1 | cut -d: -f1)
_ln_geo=$(grep -n 'mkdir -p "\$backup_tmp/geosite"' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_ln_relay" ] && [ -n "$_ln_wp" ] && [ -n "$_ln_geo" ] \
   && [ "$_ln_relay" -lt "$_ln_geo" ] && [ "$_ln_wp" -lt "$_ln_geo" ]; then
    ok "relay-id (${_ln_relay}) и адрес вебпанели (${_ln_wp}) бэкапятся до объёмного geosite (${_ln_geo})"
else
    no "незаменимое бэкапится раньше объёмного geosite" "relay<geosite и webpanel<geosite" \
       "relay=${_ln_relay:-нет} webpanel=${_ln_wp:-нет} geosite=${_ln_geo:-нет}"
fi


# ============================================================================
# О. Удавшийся откат не оставляет каталог бэкапа на диске
# ============================================================================
#
# Каталог пользовательских данных сносился ровно в двух местах — в начале
# СЛЕДУЮЩЕЙ установки и в конце удачного finalize. То есть любой отказ на
# поздних шагах оставлял копию на /opt до следующей УДАЧНОЙ установки. Раньше
# там лежали config, whitelist, extra-domains и state.tsv (сотни килобайт),
# теперь ещё и полные копии geosite-целей со всеми игровыми списками. А
# типичная причина отказа — нехватка места: круг замыкается.
#
# Вторая половина не менее важна первой: если откат ПРОВАЛИЛСЯ, каталог обязан
# остаться. Дерево не вернулось, и настройки в нём — единственная копия.
awk '/^(z2k_restore_old_tree|z2k_restore_external)\(\) \{/,/^\}/' "$SRC" > "$TMP/rollback.sh"
if grep -q '^z2k_restore_old_tree() {' "$TMP/rollback.sh"; then
    ok "z2k_restore_old_tree извлечена из install.sh"
else
    no "z2k_restore_old_tree извлечена" "функция" "не найдена"
fi

_rollback() {  # _rollback <ok|fail — удастся ли mv дерева> → "rc=..:дерево=..:бэкап=.."
    rm -rf "$TMP/rb"; mkdir -p "$TMP/rb/bin" "$TMP/rb/old" "$TMP/rb/bk" "$TMP/rb/new"
    printf 'рабочая-установка\n' > "$TMP/rb/old/marker"
    printf 'частичная-новая\n'   > "$TMP/rb/new/marker"
    printf 'настройки\n'         > "$TMP/rb/bk/config"
    if [ "$1" = "fail" ]; then
        # единственный способ смоделировать «дерево вернуть не удалось»
        printf '#!/bin/sh\nexit 1\n' > "$TMP/rb/bin/mv"; chmod +x "$TMP/rb/bin/mv"
    fi
    env -i PATH="$TMP/rb/bin:/usr/bin:/bin" HOME="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
        . "$SB/rollback.sh"
        ZAPRET2_DIR="$SB/rb/new"
        Z2K_OLD_TREE_BACKUP="$SB/rb/old"
        Z2K_UPGRADE_BACKUP="$SB/rb/bk"
        print_error() { :; }; print_success() { :; }; print_warning() { :; }
        if z2k_restore_old_tree; then rc=0; else rc=1; fi
        printf "rc=%s:дерево=%s:бэкап=%s" "$rc" \
            "$(cat "$SB/rb/new/marker" 2>/dev/null || echo нет)" \
            "$([ -d "$SB/rb/bk" ] && echo остался || echo убран)"
    ' 2>/dev/null
}

r=$(_rollback ok)
case "$r" in
    "rc=0:дерево=рабочая-установка:бэкап=убран")
        ok "удавшийся откат вернул прежнее дерево и убрал за собой каталог бэкапа" ;;
    *)  no "удавшийся откат убирает каталог бэкапа" \
           "rc=0:дерево=рабочая-установка:бэкап=убран" "$r" ;;
esac

r=$(_rollback fail)
case "$r" in
    *":бэкап=остался")
        ok "провалившийся откат каталог бэкапа НЕ трогает — в нём единственная копия настроек" ;;
    *)  no "провалившийся откат сохраняет каталог бэкапа" "бэкап=остался" "$r" ;;
esac


printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
