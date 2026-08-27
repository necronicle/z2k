#!/bin/sh
# tests/test_layer0_shared_fences.sh — общий код транспорта размножен по
# четырём файлам, и это должно быть видно.
#
# ПОЧЕМУ КОПИИ, А НЕ ОБЩИЙ ФАЙЛ. z2k.sh качается через `curl | sh` тогда, когда
# lib/utils.sh в системе ещё нет, а files/z2k-update-lists.sh и
# files/z2k-geosite.sh запускаются из cron самостоятельными скриптами и utils.sh
# не сорсят вовсе. Вынести транспорт некуда: чтобы достать общий файл, нужен
# ровно тот фетчер, который мы бы выносили.
#
# ПОЭТОМУ ЗАБОР. Три блока огорожены комментариями-маркерами (тот же приём, что
# у awk-фильтра адресов в files/z2k-warp.sh) и обязаны совпадать ДОСЛОВНО во
# всех четырёх файлах:
#
#   z2k shared shell helpers  — z2k_uint и z2k_connfail;
#   z2k layer0 vps knobs      — чтение ручек Layer 0;
#   z2k layer0 retry gate     — условие повтора.
#
# Существующие гейты (test_fetch_copies_agree.sh, test_fetch_vps_layer_budget.sh)
# сторожат ТРИ копии функции _z2k_curl_etag и четвёртую точку выхода не видят по
# построению: у geosite своя структура и своего _z2k_curl_etag нет. Именно так
# она полтора года держала зашитый --connect-timeout 15 без повторов, пока три
# остальные жили по общим ручкам. Здесь считаются ЧЕТЫРЕ.
#
# Отступ у четвёртой копии свой (блок лежит глубже по вложенности), поэтому
# сравниваем со срезанными ведущими пробелами — как это делает
# tests/test_warp_lists.sh для фильтра адресов.
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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-fences.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

COPIES="z2k.sh lib/utils.sh files/z2k-update-lists.sh files/z2k-geosite.sh"

# --- 0. Копий ровно четыре ----------------------------------------------------
#
# Пятая копия — это не «ещё одно место»: это место, о котором ни один гейт не
# знает, и разъезжаться оно начнёт молча.
_found=$(grep -rl -- '--- z2k shared shell helpers (canonical' \
            "$ROOT/z2k.sh" "$ROOT/lib" "$ROOT/files" "$ROOT/webpanel" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_found" = "4" ]; then
    ok "копий общего блока ровно четыре (как заявлено в маркере)"
else
    no "копий общего блока четыре" "4" "$_found — появилась новая копия или исчезла старая"
fi

# --- 1. Каждый забор совпадает во всех четырёх файлах -------------------------
_block_of() {  # _block_of <файл> <имя блока>
    awk -v b="$2" '
        index($0, "--- z2k " b " (canonical") > 0 { inb = 1 }
        inb { sub(/^[[:space:]]+/, ""); print }
        inb && index($0, "--- end z2k " b " ---") > 0 { exit }
    ' "$1"
}

for _blk in "shared shell helpers" "layer0 vps knobs" "layer0 retry gate"; do
    _ref=""; _refname=""; _bad=""; _empty=""
    for _f in $COPIES; do
        _b=$(_block_of "$ROOT/$_f" "$_blk")
        if [ -z "$_b" ]; then _empty="$_empty $_f"; continue; fi
        if [ -z "$_refname" ]; then _ref="$_b"; _refname="$_f"; continue; fi
        [ "$_b" = "$_ref" ] || _bad="$_bad $_f"
    done
    if [ -n "$_empty" ]; then
        no "забор «${_blk}» есть во всех копиях" "четыре блока" "нет в:$_empty"
    elif [ -n "$_bad" ]; then
        no "забор «${_blk}» совпадает" "байт в байт с $_refname" "разошлись:$_bad"
    else
        ok "забор «${_blk}» совпадает во всех четырёх копиях"
    fi
done

# --- 2. z2k_uint: таблица ------------------------------------------------------
#
# Ручки приходят из окружения (cron, install.sh, рука человека). Мусор в них
# стоил целого слоя: TRIES=abc роняло `test` с «Illegal number», цикл не
# исполнялся ни разу, Layer 0 выключался на весь прогон — и всё это с ошибкой
# прямо в потоке установки.
#
# Выход за границы ЗАЖИМАЕТСЯ, а не сбрасывается в дефолт: потолок обязан
# оставаться потолком (иначе TRIES=100000 вернулся бы к двум попыткам вместо
# обещанных пяти), а ноль уезжает в пол, потому что --connect-timeout 0 у curl
# означает «без ограничения вовсе» — то есть дефолт здесь был бы ОПАСНЕЕ пола.
awk '/^z2k_uint\(\) \{/,/^\}/'     "$ROOT/lib/utils.sh" >  "$TMP/helpers.sh"
awk '/^z2k_connfail\(\) \{/,/^\}/' "$ROOT/lib/utils.sh" >> "$TMP/helpers.sh"

uint() {
    env -i PATH="$Z2K_TEST_PATH" SB="$TMP" A="$1" B="$2" C="${3:-}" D="${4:-}" \
        "$Z2K_TEST_SH" -c '
        . "$SB/helpers.sh"
        z2k_uint "$A" "$B" ${C:+"$C"} ${D:+"$D"}
    ' 2>/dev/null
}
_t() { r=$(uint "$1" "$2" "$3" "$4"); [ "$r" = "$5" ] \
       && ok "z2k_uint($1,$2,${3:-–},${4:-–}) = $5" \
       || no "z2k_uint($1,$2,${3:-–},${4:-–})" "$5" "$r"; }
_t "abc"    2 1 5 2
_t ""       3 1 "" 3
_t "0"      2 1 5 1
_t "0"      3 1 "" 1
_t "100000" 2 1 5 5
_t "7"      3 1 "" 7
_t " 3"     3 1 "" 3

# Код возврата ВСЕГДА нулевой: в z2k.sh активен set -e, и присваивание из
# подстановки не имеет права ронять установку из-за мусора в переменной среды.
_rc=$(env -i PATH="$Z2K_TEST_PATH" SB="$TMP" "$Z2K_TEST_SH" -c '
    set -e
    . "$SB/helpers.sh"
    v=$(z2k_uint "abc" 2 1 5)
    v=$(z2k_uint "100000" 2 1 5)
    v=$(z2k_uint "" 3 1)
    printf "жив=%s" "$v"
' 2>/dev/null)
if [ "$_rc" = "жив=3" ]; then
    ok "z2k_uint не роняет set -e ни на мусоре, ни на переполнении"
else
    no "z2k_uint не роняет set -e" "жив=3" "${_rc:-оболочка умерла}"
fi

# --- 3. z2k_connfail: что имеет смысл повторять -------------------------------
#
# Гейт повтора смотрел на %{time_connect}, и это ловило меньше, чем обещало:
# time_connect считает ОДИН TCP-хендшейк, а --connect-timeout по curl(1)
# ограничивает DNS+TCP+TLS целиком. Замер: коннект в чёрную дыру даёт
# tc=0.000000 (повтор), а «TCP встал, TLS не ответил» — tc=0.032246, то есть
# уходило в break, хотя это ровно тот же класс отказа.
cf() {
    env -i PATH="$Z2K_TEST_PATH" SB="$TMP" RC="$1" HTTP="$2" "$Z2K_TEST_SH" -c '
        . "$SB/helpers.sh"
        if z2k_connfail "$RC" "$HTTP"; then printf повтор; else printf нет; fi
    ' 2>/dev/null
}
_c() { r=$(cf "$1" "$2"); [ "$r" = "$3" ] \
       && ok "z2k_connfail(rc=$1, http=${2:-пусто}) = $3" \
       || no "z2k_connfail(rc=$1, http=${2:-пусто})" "$3" "$r"; }
_c 28 000 повтор
_c 28 ""  повтор
_c 35 000 повтор
_c 6  000 повтор
_c 7  000 повтор
# УСТАНОВИЛИСЬ и встали посреди передачи: rc=28, но код ответа пришёл. Повтор
# здесь удваивает цену отказа и тянет файл дважды целиком.
_c 28 200 нет
_c 0  500 нет
_c 18 200 нет
_c 56 000 нет

# --- 4. Разбор строки -w (F7) -------------------------------------------------
#
# curl просят напечатать «%{http_code} %{time_connect}», но напечатать он может
# и одно поле — например, выйдя с rc=2 на непарсимом --connect-timeout. На
# НЕПУСТОМ выводе без пробела `${x##* }` возвращает СТРОКУ ЦЕЛИКОМ: in=[200]
# давало CONNECT=[200], и гейт повтора принимал код ответа за время коннекта.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUBW'
#!/bin/sh
prev=""; body=""; hdr=""
for a in "$@"; do
    case "$prev" in -o) body="$a" ;; -D) hdr="$a" ;; esac
    prev="$a"
done
[ -n "$body" ] && printf 'ТЕЛО\n' > "$body"
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
# ОДНО поле, без пробела — ровно тот вывод, на котором разбор ломался.
printf '200'
exit 0
STUBW
chmod +x "$TMP/bin/curl"

for _f in z2k.sh lib/utils.sh files/z2k-update-lists.sh; do
    _sb="$TMP/w"; rm -rf "$_sb"; mkdir -p "$_sb"
    awk '/^(_z2k_curl_etag|z2k_connfail)\(\) \{/,/^\}/' "$ROOT/$_f" > "$_sb/fn.sh"
    _r=$(env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" SB="$_sb" "$Z2K_TEST_SH" -c '
        . "$SB/fn.sh"
        _z2k_curl_etag "https://example.invalid/x" "$SB/dest" "" >/dev/null 2>&1
        printf "connect=%s" "${Z2K_LAST_CONNECT:-пусто}"
    ' 2>/dev/null)
    case "$_r" in
        "connect=0")
            ok "$_f: -w без пробела → CONNECT=0, а не код ответа" ;;
        *)  no "$_f: разбор -w без пробела" "connect=0" \
               "$_r — код ответа принят за время коннекта" ;;
    esac
done

# Z2K_LAST_HTTP живёт только в files/z2k-update-lists.sh: на нём висит решение
# «у апстрима файла нет» против «зеркала не отвечают» (`[ "$Z2K_LAST_HTTP" =
# "404" ]`). Обрезка времени коннекта не имеет права его пачкать.
_sb="$TMP/wh"; rm -rf "$_sb"; mkdir -p "$_sb"
awk '/^(_z2k_curl_etag|z2k_connfail)\(\) \{/,/^\}/' "$ROOT/files/z2k-update-lists.sh" > "$_sb/fn.sh"
_rh=$(env -i PATH="$TMP/bin:$Z2K_TEST_PATH" HOME="$TMP" SB="$_sb" "$Z2K_TEST_SH" -c '
    . "$SB/fn.sh"
    _z2k_curl_etag "https://example.invalid/x" "$SB/dest" "" >/dev/null 2>&1
    printf "%s" "${Z2K_LAST_HTTP:-пусто}"
' 2>/dev/null)
[ "$_rh" = "200" ] && ok "Z2K_LAST_HTTP остаётся чистым кодом ответа и на выводе без пробела" \
                   || no "Z2K_LAST_HTTP чист" "200" "$_rh"

# --- 5. Гейт повтора Layer 0 (R7) ---------------------------------------------
#
# Раньше повтор гейтился по %{time_connect}, и «TLS не ответил» (ненулевое
# время коннекта) уходило в break. Здесь стаб печатает НЕНУЛЕВОЕ время
# коннекта в TLS-случае — именно тот сценарий, который прежний гейт терял.
cat > "$TMP/bin/curl_r7" <<'STUBR'
#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
resolve=0
for a in "$@"; do [ "$a" = "--resolve" ] && resolve=1; done
prev=""; body=""; hdr=""
for a in "$@"; do
    case "$prev" in -o) body="$a" ;; -D) hdr="$a" ;; esac
    prev="$a"
done
if [ "$resolve" = "1" ]; then
    case "$CASE" in
        tls)     printf '000 0.032246'; exit 35 ;;
        halfway) printf '200 0.075';    exit 28 ;;
        srv5xx)  printf '500 0.075';    exit 0  ;;
    esac
fi
[ -n "$body" ] && printf 'ТЕЛО\n' > "$body"
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
printf '200 0.075'
exit 0
STUBR
chmod +x "$TMP/bin/curl_r7"

r7() {  # r7 <файл> <CASE> → "vps=<хопов Layer 0>"
    _sb="$TMP/r7"; rm -rf "$_sb"; mkdir -p "$_sb/bin"
    cp "$TMP/bin/curl_r7" "$_sb/bin/curl"
    awk '/^(_z2k_[a-z_]+|z2k_fetch|z2k_uint|z2k_connfail)\(\) \{/,/^\}/' "$ROOT/$1" > "$_sb/fns.sh"
    env -i PATH="$_sb/bin:$Z2K_TEST_PATH" HOME="$TMP" SB="$_sb" LOG="$_sb/log" CASE="$2" \
        "$Z2K_TEST_SH" -c '
            : > "$LOG"
            . "$SB/fns.sh"
            GITHUB_RAW="https://raw.githubusercontent.com/o/r/main"
            Z2K_VPS_GH_IP="203.0.113.9"
            Z2K_FETCH_ALL_404=0
            _z2k_curl_doh() { return 1; }
            _z2k_manifest_sha() { printf ""; }
            z2k_fetch "/файл.txt" "$SB/dest" >/dev/null 2>&1
            v=$(grep -c -- "--resolve" "$LOG" 2>/dev/null); [ -n "$v" ] || v=0
            printf "vps=%s" "$v"
        ' 2>/dev/null
}
for _f in z2k.sh lib/utils.sh files/z2k-update-lists.sh; do
    r=$(r7 "$_f" tls)
    [ "$r" = "vps=2" ] && ok "$_f: TLS не ответил (rc=35, http 000) → повтор" \
                       || no "$_f: rc=35 при http 000 повторяется" "vps=2" "$r"
    r=$(r7 "$_f" halfway)
    [ "$r" = "vps=1" ] && ok "$_f: обрыв УЖЕ идущей передачи (rc=28, http 200) → без повтора" \
                       || no "$_f: rc=28 при http 200 не повторяется" "vps=1" "$r"
    r=$(r7 "$_f" srv5xx)
    [ "$r" = "vps=1" ] && ok "$_f: 5xx на установленном соединении → без повтора" \
                       || no "$_f: 5xx не повторяется" "vps=1" "$r"
done

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
