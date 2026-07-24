#!/bin/sh
# tests/test_warp_lists.sh - webpanel WARP lists (раздел «WARP»): CRUD хендлеры
# warp_* из webpanel/cgi/actions.sh + миграция seed-списка в z2k-warp.sh +
# роутинг/валидация /warp/* в api.sh (полный CGI-вызов с env как у lighttpd).
# POSIX sh compatible (busybox ash).

TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected '%s', got '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    case "$3" in
        *"$2"*) TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1" ;;
        *)      TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: '%s' not in output: %s\n" "$1" "$2" "$3" ;;
    esac
}
assert_not_contains() {
    case "$3" in
        *"$2"*) TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: unexpected '%s' in output\n" "$1" "$2" ;;
        *)      TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- sandbox ---
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
ZAPRET2_DIR="$SB/opt/zapret2";            export ZAPRET2_DIR
CONFIG_FILE="$ZAPRET2_DIR/config";        export CONFIG_FILE
LISTS_DIR="$ZAPRET2_DIR/lists";           export LISTS_DIR
WARP_SCRIPT="$ZAPRET2_DIR/z2k-warp.sh";   export WARP_SCRIPT
WARP_LISTS_DIR="$LISTS_DIR/warp";         export WARP_LISTS_DIR
mkdir -p "$LISTS_DIR"
cp "$SCRIPT_DIR/files/z2k-warp.sh" "$WARP_SCRIPT"
printf 'GAME_WARP_ENABLED=0\n' > "$CONFIG_FILE"
# legacy shipped seed — источник одноразовой миграции
printf '1.2.3.0/24\n5.6.7.8\n9.9.0.0/16\n' > "$LISTS_DIR/game-warp-ips.txt"

# Source the function library (defines warp_lists/warp_list_save/etc).
. "$SCRIPT_DIR/webpanel/cgi/actions.sh" 2>/dev/null

printf "\n--- migration: dir existence = migrated marker ---\n"
warp_lists_ensure_dir
assert_eq "seed migrated into warp dir" "1" "$([ -f "$WARP_LISTS_DIR/game-warp-ips.txt" ] && echo 1 || echo 0)"
rm -f "$WARP_LISTS_DIR/game-warp-ips.txt"
warp_lists_ensure_dir
assert_eq "deleted seed NOT re-seeded (dir exists)" "0" "$([ -f "$WARP_LISTS_DIR/game-warp-ips.txt" ] && echo 1 || echo 0)"
rm -rf "$WARP_LISTS_DIR"
warp_lists_ensure_dir

printf "\n--- warp_name_ok ---\n"
for good in games my.list a_b-c A1; do
    warp_name_ok "$good" && r=0 || r=1
    assert_eq "accepts '$good'" "0" "$r"
done
for badname in "" ".hidden" "-flag" "a/b" "a b" "й" "a;b" "../x"; do
    warp_name_ok "$badname" && r=0 || r=1
    assert_eq "rejects '$badname'" "1" "$r"
done

printf "\n--- migration: engine is the SOLE creator of the lists dir ---\n"
# Каталог lists/warp — это и есть маркер «миграция выполнена». Если движок
# (z2k-warp.sh) не смог его создать, панель НЕ должна создавать его сама:
# пустой mkdir навсегда подавил бы засев shipped-списка (в т.ч. позже, когда
# рабочий движок вернётся). Ожидаем честный отказ, а не тихую потерю seed'а.
rm -rf "$WARP_LISTS_DIR"
OLD_SCRIPT="$SB/old-z2k-warp.sh"
printf '#!/bin/sh\nexit 1\n' > "$OLD_SCRIPT"
WARP_SCRIPT_SAVED="$WARP_SCRIPT"; WARP_SCRIPT="$OLD_SCRIPT"
warp_lists_ensure_dir && r=0 || r=1
WARP_SCRIPT="$WARP_SCRIPT_SAVED"
assert_eq "broken engine -> ensure_dir fails" "1" "$r"
assert_eq "no marker dir left behind"         "0" "$([ -d "$WARP_LISTS_DIR" ] && echo 1 || echo 0)"

printf "\n--- migration: working engine seeds the shipped list ---\n"
rm -rf "$WARP_LISTS_DIR"
warp_lists_ensure_dir && r=0 || r=1
assert_eq "engine present -> ensure_dir ok"   "0" "$r"
assert_eq "engine seeded the game list"       "1" "$([ -s "$WARP_LISTS_DIR/game-warp-ips.txt" ] && echo 1 || echo 0)"
rm -rf "$WARP_LISTS_DIR"
warp_lists_ensure_dir

printf "\n--- warp_list_save: sanitize + counts ---\n"
OUT=$(printf '10.0.0.1\r\n172.16.0.0/12\n# note\n\n999.1.1.1\n2a00:1450::1\n1.2.3.4/33\ngarbage\n8.8.8.8\n' | warp_list_save test replace)
assert_contains "3 valid lines saved"      "saved=3"           "$OUT"
assert_contains "4 junk lines skipped"     "skipped_invalid=4" "$OUT"
CONTENT=$(cat "$WARP_LISTS_DIR/test.txt")
assert_contains     "CRLF entry kept (CR stripped)" "10.0.0.1"  "$CONTENT"
assert_contains     "comment preserved"             "# note"    "$CONTENT"
assert_not_contains "bad octet filtered"            "999"       "$CONTENT"
assert_not_contains "IPv6 filtered"                 "2a00"      "$CONTENT"
assert_not_contains "prefix>32 filtered"            "/33"       "$CONTENT"
CR_COUNT=$(tr -cd '\r' < "$WARP_LISTS_DIR/test.txt" | wc -c | tr -d ' ')
assert_eq "no CR bytes in stored file" "0" "$CR_COUNT"

printf "\n--- warp_list_save: ipset-грамматика (то, что restore не переживёт) ---\n"
# /0 и ведущие нули ipset либо не парсит (08.8.8.8, /08 → abort всего restore-
# стрима), либо парсит ОКТАЛЬНО (010.1.2.3 → 8.1.2.3). Фильтр обязан резать.
OUT=$(printf '0.0.0.0/0\n8.8.8.8/0\n08.8.8.8\n010.1.2.3\n1.2.3.4/08\n0.1.2.3\n1.2.3.4/32\n5.5.5.5/1\n7.7.7.7\n' | warp_list_save strict replace)
assert_contains "only 3 grammar-valid lines saved" "saved=3"           "$OUT"
assert_contains "6 ipset-hostile lines skipped"    "skipped_invalid=6" "$OUT"
CONTENT=$(cat "$WARP_LISTS_DIR/strict.txt")
assert_not_contains "prefix /0 filtered"           "/0"       "$CONTENT"
assert_not_contains "leading-zero octet filtered"  "08."      "$CONTENT"
assert_not_contains "octal-octet filtered"         "010."     "$CONTENT"
assert_not_contains "zero first octet filtered"    "0.1.2.3"  "$CONTENT"
assert_contains     "/32 kept"                     "1.2.3.4/32" "$CONTENT"
assert_contains     "/1 kept"                      "5.5.5.5/1"  "$CONTENT"
warp_list_delete strict

printf "\n--- warp_list_save: mode=create ---\n"
OUT=$(printf '6.6.6.6\n' | warp_list_save fresh create)
assert_contains "create new list ok" "saved=1" "$OUT"
printf '9.9.9.9\n' | warp_list_save fresh create 2>/dev/null && r=0 || r=1
assert_eq "create refuses existing list" "1" "$r"
assert_eq "existing list untouched by refused create" "6.6.6.6" "$(cat "$WARP_LISTS_DIR/fresh.txt")"
warp_list_delete fresh

printf "\n--- warp_list_save: append mode ---\n"
OUT=$(printf '4.4.4.4\n' | warp_list_save test append)
assert_contains "append saved=1" "saved=1" "$OUT"
assert_eq "old line survived append" "1" "$(grep -c '^8.8.8.8$' "$WARP_LISTS_DIR/test.txt")"
assert_eq "new line appended"        "1" "$(grep -c '^4.4.4.4$' "$WARP_LISTS_DIR/test.txt")"

printf "\n--- warp_list_save: replace preserves inode ---\n"
INODE_BEFORE=$(ls -i "$WARP_LISTS_DIR/test.txt" | awk '{print $1}')
printf '7.7.7.7\n' | warp_list_save test replace >/dev/null
INODE_AFTER=$(ls -i "$WARP_LISTS_DIR/test.txt" | awk '{print $1}')
assert_eq "inode unchanged on replace" "$INODE_BEFORE" "$INODE_AFTER"
assert_eq "replace really replaced" "7.7.7.7" "$(cat "$WARP_LISTS_DIR/test.txt")"

printf "\n--- warp_lists: TSV inventory ---\n"
OUT=$(warp_lists)
assert_contains "lists TSV has test row" "test" "$OUT"
ENTRIES=$(warp_lists | awk -F'\t' '$1=="test"{print $2}')
assert_eq "entry count = valid lines only" "1" "$ENTRIES"

printf "\n--- warp_list_delete ---\n"
warp_list_delete test
assert_eq "file removed" "0" "$([ -f "$WARP_LISTS_DIR/test.txt" ] && echo 1 || echo 0)"
warp_list_delete test && r=0 || r=1
assert_eq "delete idempotent" "0" "$r"
warp_list_delete "../game-warp-ips" 2>/dev/null && r=0 || r=1
assert_eq "hostile delete name rejected" "1" "$r"

printf "\n--- z2k-warp.sh: loader ipset stream validation ---\n"
# Без ipset в PATH загрузчик не прогнать целиком, но awk-фильтр — можно
# (инлайн-копия фильтра warp_ipset_load из files/z2k-warp.sh — держать в
# синхроне!): он обязан выкидывать всё, что ipset restore не переживёт
# (/0, ведущие нули, битые октеты) или молча исказит (октальные октеты).
mkdir -p "$WARP_LISTS_DIR"
printf '1.2.3.0/24\n999.1.1.1\n8.8.8.8/33\n0.0.0.0/0\n08.8.8.8\n010.1.2.3\n1.2.3.4/08\n8.8.4.4\n' > "$WARP_LISTS_DIR/loader.txt"
STREAM=$(cat "$WARP_LISTS_DIR"/*.txt 2>/dev/null | awk -v set="z2k_warp" '
    {
        sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0 !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/) next
        ip = $0
        if (split($0, halves, "/") == 2) ip = halves[1]
        split(ip, o, ".")
        if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) next
        print "add " set " " $0 " -exist"
    }')
assert_contains     "loader keeps valid CIDR"        "add z2k_warp 1.2.3.0/24 -exist" "$STREAM"
assert_contains     "loader keeps valid host"        "add z2k_warp 8.8.4.4 -exist"    "$STREAM"
assert_not_contains "loader drops bad octet"         "999"                            "$STREAM"
assert_not_contains "loader drops prefix>32"         "/33"                            "$STREAM"
assert_not_contains "loader drops /0"                "/0"                             "$STREAM"
assert_not_contains "loader drops leading-zero IP"   "08.8.8.8"                       "$STREAM"
assert_not_contains "loader drops octal octet"       "010."                           "$STREAM"
assert_not_contains "loader drops leading-zero pfx"  "/08"                            "$STREAM"
rm -f "$WARP_LISTS_DIR/loader.txt"

printf "\n--- filter parity: loader (z2k-warp.sh) vs save (actions.sh) ---\n"
# Оба фильтра обязаны использовать ОДИН регэксп — рассинхрон означает, что
# сохранённая строка может убить restore-поток. Ищем literal-вхождение
# канонического регэкспа в обоих файлах (fixed-string grep).
RE_LITERAL='/^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/'
assert_eq "loader has canonical regex" "1" "$(grep -cF "$RE_LITERAL" "$SCRIPT_DIR/files/z2k-warp.sh")"
assert_eq "save has canonical regex"   "1" "$(grep -cF "$RE_LITERAL" "$SCRIPT_DIR/webpanel/cgi/actions.sh")"

printf "\n--- api.sh: /warp/* routing (full CGI invocation) ---\n"
API="$SCRIPT_DIR/webpanel/cgi/api.sh"
cgi() { # cgi <METHOD> <PATH_INFO> <QUERY> [bodyfile]
    _m="$1"; _p="$2"; _q="$3"; _b="${4:-}"
    if [ -n "$_b" ]; then
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" CONTENT_LENGTH="$(wc -c < "$_b" | tr -d ' ')" \
            sh "$API" < "$_b" 2>/dev/null
    else
        env REQUEST_METHOD="$_m" PATH_INFO="$_p" QUERY_STRING="$_q" \
            HTTP_HOST="192.168.1.1" CONTENT_LENGTH=0 \
            sh "$API" < /dev/null 2>/dev/null
    fi
}
cgi_body() { awk 'blank{print} /^\r?$/{blank=1}'; }

BODYF="$SB/body.txt"
printf '10.1.1.1\nмусор\n' > "$BODYF"
OUT=$(cgi POST /warp/list/save "name=cgi-test&mode=replace" "$BODYF" | cgi_body)
assert_contains "save via CGI: ok"              '"ok":true'           "$OUT"
assert_contains "save via CGI: saved=1"         '"saved":1'           "$OUT"
assert_contains "save via CGI: skipped=1"       '"skipped_invalid":1' "$OUT"

OUT=$(cgi GET /warp/lists "" | cgi_body)
assert_contains "lists via CGI: has cgi-test"   '"name":"cgi-test"'   "$OUT"

OUT=$(cgi GET /warp/list "name=cgi-test" | cgi_body)
assert_eq "raw read via CGI" "10.1.1.1" "$OUT"

OUT=$(cgi GET /warp/list "name=nope" | cgi_body)
assert_contains "missing list -> 404 json"      "no such list"        "$OUT"

OUT=$(cgi POST /warp/list/save "name=..%2Fevil&mode=replace" "$BODYF" | cgi_body)
assert_contains "traversal name -> 400"         '"ok":false'          "$OUT"
assert_eq "no file escaped lists dir" "0" "$([ -e "$LISTS_DIR/evil.txt" ] && echo 1 || echo 0)"

OUT=$(cgi GET /warp/status "" | cgi_body)
assert_contains "status: enabled flag"          '"enabled":"0"'       "$OUT"
assert_contains "status: entries field"         '"entries":'          "$OUT"

printf 'name=cgi-test' > "$BODYF"
OUT=$(cgi POST /warp/list/delete "" "$BODYF" | cgi_body)
assert_contains "delete via CGI: ok"            '"ok":true'           "$OUT"
assert_eq "file gone after CGI delete" "0" "$([ -f "$WARP_LISTS_DIR/cgi-test.txt" ] && echo 1 || echo 0)"

printf "\n--- update-lists: medvedeff fetch sanitize (offline, awk only) ---\n"
# Игровой список тянется живьём из medvedeff-true/ru-gaming-blocklist в
# z2k-update-lists.sh и санитайзится тем же строгим IPv4-фильтром. Здесь
# проверяем именно санитайз-стадию на сыром upstream-образце (v6 + мусор).
RAW="$SB/upstream.raw"
printf '1.0.0.0/24\n1.1.1.0/24\n2a00:1450::/32\n0.0.0.0/0\n08.8.8.8\n# comment\n203.0.113.5\n' > "$RAW"
SAN=$(awk '
    { sub(/\r$/,""); gsub(/^[ \t]+|[ \t]+$/,"") }
    $0=="" || $0 ~ /^#/ { next }
    $0 !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/ { next }
    { ip=$0; if (split($0,h,"/")==2) ip=h[1]; split(ip,o,".")
      if (o[1]>255||o[2]>255||o[3]>255||o[4]>255) next; print }
' "$RAW")
assert_contains     "keeps valid /24"    "1.0.0.0/24"   "$SAN"
assert_contains     "keeps valid host"   "203.0.113.5"  "$SAN"
assert_not_contains "drops IPv6"         "2a00"         "$SAN"
assert_not_contains "drops /0"           "0.0.0.0/0"    "$SAN"
assert_not_contains "drops leading-zero" "08.8.8.8"     "$SAN"
assert_not_contains "drops comment"      "# comment"    "$SAN"
assert_eq "update-lists uses canonical regex" "1" "$(grep -cF '/^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/' "$SCRIPT_DIR/files/z2k-update-lists.sh")"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
