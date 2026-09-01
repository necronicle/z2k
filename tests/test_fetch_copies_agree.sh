#!/bin/sh
# tests/test_fetch_copies_agree.sh — три копии транспорта должны вести себя одинаково.
#
# ПОЧЕМУ ГЕЙТ, А НЕ ДЕДУПЛИКАЦИЯ. Свести `_z2k_curl_etag` в один файл нельзя:
# z2k.sh качается через `curl | sh` тогда, когда lib/utils.sh в системе ещё нет,
# а чтобы его достать, нужен ровно тот фетчер, который мы бы выносили. Курица и
# яйцо, разрывается только байтами в самом бутстрапе.
#
# Поэтому копии остаются, но обязаны СОВПАДАТЬ В ПОВЕДЕНИИ. Внешнее ревью
# насчитало здесь «дрейф»: в двух копиях провал `mv` не проверялся. Вывод был
# неточен (в z2k.sh и utils.sh сверху стоит sha-гейт, который протухший файл
# сносит), но сама асимметрия была реальной и держалась ни на чём.
#
# Гейт ПОВЕДЕНЧЕСКИЙ, а не текстовый: сверять исходники посимвольно значит
# краснеть от переформатирования и комментариев, то есть от правок, которые
# ничего не меняют. Здесь каждая копия исполняется в песочнице с подставным
# curl, и с неё спрашивается результат.
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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-fetchcopies.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# Копии функции _z2k_curl_etag, за которыми следим. Появится четвёртая — пункт
# 0 ниже об этом скажет.
COPIES="z2k.sh lib/utils.sh files/z2k-update-lists.sh"

# ВАЖНО ПРО ГРАНИЦУ ЭТОГО ГЕЙТА.
#
# files/z2k-geosite.sh — ЧЕТВЁРТАЯ точка выхода на VPS, но у неё СВОЙ curl, а не
# _z2k_curl_etag. Счётчик копий её не видит по построению, и именно так она
# полтора года держала зашитый --connect-timeout 15 без повторов, пока три
# остальные жили по общим ручкам. Считать её пятой копией функции нельзя —
# структура другая; оставить без присмотра тоже. Поэтому ниже отдельный пункт:
# её хоп обязан читать те же ручки.
GEO="${Z2K_GEOSITE_UNDER_TEST:-$ROOT/files/z2k-geosite.sh}"

# --- 0. Копий ровно столько, сколько мы знаем --------------------------------
found=$(grep -rl '^_z2k_curl_etag() {' "$ROOT/z2k.sh" "$ROOT/lib" "$ROOT/files" 2>/dev/null | wc -l | tr -d ' ')
if [ "$found" = "3" ]; then
    ok "копий транспорта ровно три (как заявлено)"
else
    no "копий транспорта ровно три" "3" "$found — появилась новая копия или исчезла старая"
fi

# --- харнесс ------------------------------------------------------------------
#
# Вытаскиваем определение функции из файла и исполняем его в отдельной оболочке
# с подставным curl. Сорсить файл целиком нельзя: там установочная логика.
extract_fn() {
    awk '/^_z2k_curl_etag\(\) \{/,/^\}/' "$1"
}

# Подставной curl: печатает код ответа, кладёт тело и заголовок с ETag.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUBC'
#!/bin/sh
# Разбираем только то, что нам нужно: -D <hdr> -o <body> и -w кодом.
hdr=""; body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -D) hdr="$2"; shift 2 ;;
        -o) body="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
[ -n "$body" ] && printf 'СВЕЖЕЕ-ТЕЛО\n' > "$body"
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\nETag: "новый-etag"\r\n\r\n' > "$hdr"
printf '200'
exit 0
STUBC
chmod +x "$TMP/bin/curl"

# Прогон одной копии. Отказ записи эмулируем подменой `mv` на заведомо падающую
# функцию — это и надёжнее, и честнее любых игр с правами.
#
# Первая версия харнесса делала каталогом сам dest, рассчитывая, что mv туда не
# сработает. Это было неверно: `mv файл каталог/` успешно кладёт файл ВНУТРЬ, и
# тест краснел на исправном коде. Ошибка была в проверке, а не в проверяемом.
run_copy() {
    _file="$1"; _sandbox="$TMP/run"
    rm -rf "$_sandbox"; mkdir -p "$_sandbox"
    extract_fn "$ROOT/$_file" > "$_sandbox/fn.sh"
    [ -s "$_sandbox/fn.sh" ] || { printf 'NOFN'; return; }

    mkdir -p "$_sandbox/ro"
    : > "$_sandbox/ro/target"
    # Песочница едет ПЕРЕМЕННОЙ ОКРУЖЕНИЯ, а не позиционным аргументом:
    # /bin/sh на Keenetic — NDM Shell Wrapper v1.0.10, и аргументы `sh -c` он
    # теряет (замер на роутере владельца 2026-08-27). С пустым $1 функция
    # вызывалась на путь "/fn.sh", ничего не находила, и три проверки краснели
    # на роутере, не выполнив ни строчки проверяемого кода.
    _out=$(env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" SBX="$_sandbox" \
        "$Z2K_TEST_SH" -c '
            . "$SBX/fn.sh"
            # Запись цели не удалась — единственное, что здесь проверяется.
            mv() { return 1; }
            if _z2k_curl_etag "https://example.invalid/x" "$SBX/ro/target" ""; then
                printf "RC0"
            else
                printf "RC1"
            fi
            [ -e "$SBX/ro/target.etag" ] && printf ":ETAG-ОСТАЛСЯ" || printf ":БЕЗ-ETAG"
        ' 2>/dev/null)
    printf '%s' "$_out"
}

# --- 1. Провал записи: все копии обязаны ответить одинаково -------------------
#
# Правильное поведение: вернуть НЕуспех и не оставить etag. Оставленный etag —
# это самозакрепляющаяся порча: следующий запрос пошлёт If-None-Match, получит
# честный 304 на рассогласование «старое тело + новый etag» и примет протухший
# файл как валидный.
results=""
for f in $COPIES; do
    r=$(run_copy "$f")
    results="$results$f=$r "
    case "$r" in
        RC1:БЕЗ-ETAG) ok "$f: провал записи → неуспех, etag не оставлен" ;;
        NOFN)         no "$f: функция найдена" "определение есть" "не найдено" ;;
        RC0:*)        no "$f: провал записи → неуспех" "RC1" "$r (ложный успех)" ;;
        *:ETAG-ОСТАЛСЯ) no "$f: etag не оставлен" "БЕЗ-ETAG" "$r" ;;
        *)            no "$f: поведение при провале записи" "RC1:БЕЗ-ETAG" "$r" ;;
    esac
done

# --- 2. И совпасть между собой ------------------------------------------------
#
# Даже если все три вдруг станут вести себя ОДИНАКОВО НЕПРАВИЛЬНО, пункт 1 это
# поймает. А этот пункт ловит другое: расхождение между копиями, из-за которого
# один и тот же отказ на разных путях обрабатывается по-разному.
uniq_behaviours=$(for f in $COPIES; do run_copy "$f"; printf '\n'; done | sort -u | wc -l | tr -d ' ')
if [ "$uniq_behaviours" = "1" ]; then
    ok "все три копии ведут себя одинаково"
else
    no "все три копии ведут себя одинаково" "1 вариант поведения" \
       "$uniq_behaviours варианта: $results"
fi

# --- 2b. Четвёртая точка выхода на VPS ---------------------------------------
#
# Гейт выше сторожит согласие ФУНКЦИИ. Здесь — согласие ПОВЕДЕНИЯ с той копией,
# у которой функции нет: geosite ходит на VPS своим curl, и разъехаться она
# может молча, что уже однажды и произошло.
_geo_knobs=0
grep -q 'Z2K_FETCH_VPS_CONNECT_TIMEOUT' "$GEO" && _geo_knobs=$((_geo_knobs + 1))
grep -q 'Z2K_FETCH_VPS_TRIES' "$GEO" && _geo_knobs=$((_geo_knobs + 1))
if [ "$_geo_knobs" = "2" ]; then
    ok "хоп geosite читает те же ручки Layer 0, что и три копии функции"
else
    no "хоп geosite читает те же ручки" "обе ручки" \
       "$_geo_knobs из 2 — четвёртая точка выхода снова разъехалась"
fi
# ГЕЙТ, КОТОРЫЙ МОЖЕТ УПАСТЬ.
#
# Прежняя проверка была вакуумной: условие требовало ОТСУТСТВИЯ подстроки
# `_ct=15`, а она стоит в самом geosite (ветка «Layer 0 выключен»). То есть
# второй операнд всегда ложь, и брался всегда `ok`. Гейт зеленел бы и на
# коде, где VPS-хоп снова зашит на 15 с — ровно то, ради чего он писался.
#
# Спрашиваем не текст, а поведение: гоняем настоящий fetch_to_tmp с подставным
# curl и смотрим, КАКОЙ бюджет доехал до каждого хопа.
_gsb="$TMP/geo"; rm -rf "$_gsb"; mkdir -p "$_gsb/etag" "$_gsb/tmp"
awk '/^(fetch_to_tmp|z2k_uint|z2k_connfail)\(\) \{/,/^\}/' "$GEO" > "$_gsb/fns.sh"
z2k_write_curl_stub "$TMP/bin/curl_geo"
mkdir -p "$_gsb/bin"; cp "$TMP/bin/curl_geo" "$_gsb/bin/curl"

# geo_budget <включён ли Layer 0> → "vps=<бюджеты> direct=<бюджеты>"
geo_budget() {
    rm -rf "$_gsb/tmp"; mkdir -p "$_gsb/tmp"; : > "$_gsb/curl.log"; rm -f "$_gsb/curl.log.v"
    env -i PATH="$_gsb/bin:$Z2K_TEST_PATH" HOME="$TMP" G="$_gsb" L0="$1" \
        Z2K_STUB_LOG="$_gsb/curl.log" Z2K_STUB_MODE="${GEO_MODE:-direct_fail}" \
        Z2K_FETCH_VPS_CONNECT_TIMEOUT=7 \
        "$Z2K_TEST_SH" -c '
            . "$G/fns.sh"
            ETAG_DIR="$G/etag"; TMP_DIR="$G/tmp"; RELEASE_BASE="https://example.invalid/dl"
            log() { :; }
            if [ "$L0" = "1" ]; then _z2k_vps_gh_resolve() { printf " --resolve h:443:203.0.113.9"; }
            else _z2k_vps_gh_resolve() { printf ""; }; fi
            fetch_to_tmp "ru-blocked.txt" >/dev/null 2>&1
        ' 2>/dev/null
    printf 'vps=%s direct=%s' \
        "$(grep -- '--resolve' "$_gsb/curl.log" 2>/dev/null | sed -n 's/.*--connect-timeout \([^ ]*\).*/\1/p' | sort -u | tr '\n' ',' | sed 's/,$//')" \
        "$(grep -v -- '--resolve' "$_gsb/curl.log" 2>/dev/null | sed -n 's/.*--connect-timeout \([^ ]*\).*/\1/p' | sort -u | tr '\n' ',' | sed 's/,$//')"
}

# Прямой путь ходит ПЕРВЫМ, поэтому наблюдать бюджет VPS-хопа можно только
# когда прямой упал: режим direct_fail роняет его по фазе соединения.
# Прямой при этом идёт с коротким бюджетом пробы (3 с) — за ним есть запасной
# путь; VPS берёт свои 7 из ручки.
_gb=$(geo_budget 1)
case "$_gb" in
    "vps=7 direct=3")
        ok "geosite: прямой пробует первым (3 с), VPS-хоп берёт бюджет из ручки (7)" ;;
    *)  no "geosite: порядок и бюджеты хопов" "vps=7 direct=3" \
           "$_gb — четвёртая точка выхода снова живёт своей жизнью" ;;
esac

# Layer 0 выключен — этот же запрос И ЕСТЬ прямой, торопиться с ним нельзя.
_gb0=$(geo_budget 0)
case "$_gb0" in
    "vps= direct=15") ok "geosite без Layer 0: единственный запрос идёт с 15 с, а не с коротким бюджетом" ;;
    *) no "geosite без Layer 0 не торопится" "vps= direct=15" "$_gb0" ;;
esac

# --- 3. Матрица поведения: одна ветка из пяти — это не гейт -------------------
#
# Прежние пункты гоняли ровно один сценарий (провал записи) и требовали от
# каждой копии одну и ту же литеральную строку. Из-за этого:
#   * ветки 304, «200 с пустым телом» и сброса протухшего ETag не исполнялись
#     вовсе — мутация в любой из них оставляла тест зелёным;
#   * 4-й параметр (бюджет соединения) не передавался, то есть расхождение
#     копий по бюджету было не видно;
#   * пункт 2 логически следовал из пункта 1 и своей силы не имел.
#
# Проверено: три независимые мутации в lib/utils.sh (бюджет, сброс ETag,
# семантика 304) — каждая создаёт настоящее расхождение с двумя другими
# копиями — оставляли набор зелёным 5/0.
#
# Здесь каждая копия прогоняется по матрице сценариев, и сверяется ВЕСЬ ответ.
cat > "$TMP/bin/curl2" <<'STUB2'
#!/bin/sh
printf '%s\n' "$*" >> "$CLOG"
hdr=""; body=""; prev=""
for a in "$@"; do
    case "$prev" in -D) hdr="$a" ;; -o) body="$a" ;; esac
    prev="$a"
done
case "$MODE" in
    m304)  [ -n "$hdr" ] && printf 'HTTP/1.1 304 Not Modified\r\n\r\n' > "$hdr"
           printf '304 0.075'; exit 0 ;;
    empty) [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
           : > "$body"; printf '200 0.075'; exit 0 ;;
    e500)  [ -n "$hdr" ] && printf 'HTTP/1.1 500 Oops\r\n\r\n' > "$hdr"
           printf '500 0.075'; exit 0 ;;
    *)     [ -n "$body" ] && printf 'ТЕЛО\n' > "$body"
           [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\nETag: "новый"\r\n\r\n' > "$hdr"
           printf '200 0.075'; exit 0 ;;
esac
STUB2
chmod +x "$TMP/bin/curl2"

# probe <файл> <MODE> <есть ли уже etag+тело> <4-й аргумент или пусто>
# Печатает: rc, остался ли etag, каким стало тело, какой бюджет ушёл в curl.
probe() {
    _f="$1"; _m="$2"; _pre="$3"; _to="$4"
    _sb="$TMP/probe"; rm -rf "$_sb"; mkdir -p "$_sb"
    extract_fn "$ROOT/$_f" > "$_sb/fn.sh"
    if [ "$_pre" = "1" ]; then
        printf 'СТАРОЕ\n' > "$_sb/target"
        printf '"старый"\n' > "$_sb/target.etag"
    else
        : > "$_sb/target"
    fi
    env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" \
        SB="$_sb" MODE="$_m" TO="$_to" CLOG="$_sb/clog" \
        "$Z2K_TEST_SH" -c '
            : > "$CLOG"
            cp "$(command -v curl2)" "$(dirname "$(command -v curl2)")/curl" 2>/dev/null
            . "$SB/fn.sh"
            if [ -n "$TO" ]; then _z2k_curl_etag "https://example.invalid/x" "$SB/target" "" "$TO"
            else _z2k_curl_etag "https://example.invalid/x" "$SB/target" ""; fi
            rc=$?
            printf "rc=%s etag=%s тело=%s бюджет=%s" "$rc" \
                "$([ -s "$SB/target.etag" ] && echo есть || echo нет)" \
                "$(head -c 12 "$SB/target" 2>/dev/null | tr -d "\n")" \
                "$(sed -n "s/.*--connect-timeout \([^ ]*\).*/\1/p" "$CLOG" | head -1)"
        ' 2>/dev/null
}

# Сценарий: <MODE> <есть ли кеш> <4-й аргумент>
for _sc in "ok 0 " "ok 0 4" "m304 1 " "empty 1 " "e500 1 "; do
    set -- $_sc
    _m="$1"; _pre="$2"; _to="${3:-}"
    _seen=""; _n=0
    for f in $COPIES; do
        _r=$(probe "$f" "$_m" "$_pre" "$_to")
        _seen="${_seen}[$f] $_r
"
        _n=$((_n + 1))
    done
    _uniq=$(printf '%s' "$_seen" | sed 's/^\[[^]]*\] //' | sort -u | grep -c .)
    if [ "$_uniq" = "1" ]; then
        ok "сценарий $_m (кеш=$_pre, бюджет=${_to:-умолчание}): все копии совпали"
    else
        no "сценарий $_m (кеш=$_pre, бюджет=${_to:-умолчание})" "1 вариант" \
           "$_uniq варианта:
$_seen"
    fi
done

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
