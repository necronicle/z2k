#!/bin/sh
# tests/test_domain_groups_backend.sh — файл групп доменов на роутере.
#
# Группы вкладки «Автоподбор» лежат в lists/domain-groups.txt, а не в
# localStorage: разметка, которую человек делает руками, обязана быть одной на
# телефоне и на компьютере. Отсюда три свойства, которые здесь охраняются:
#
#   * запись — compare-and-swap по версии: правка со вчерашней вкладки на
#     телефоне не затирает молча то, что сделано сегодня с компьютера;
#   * сервер не пускает в файл то, что панель не сможет показать честно:
#     домен в двух группах, домен до первой группы, кривое имя или домен;
#     отказ — целиком и с номером строки, файл при этом не тронут;
#   * файл переживает переустановку — как остальные пользовательские списки.
#
# CGI исполняется настоящий (api.sh + actions.sh) с подменой путей через
# окружение, установщик — вынутыми из lib/install.sh кусками, как в
# test_found_domains_survive_reinstall.sh. Каждое свойство продублировано
# мутантом. POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dgroups.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

# Копия cgi-каталога: мутанты правят её, а не дерево репозитория.
CGI="$TMP/cgi"
mkdir -p "$CGI"
cp "$HERE/webpanel/cgi/api.sh" "$HERE/webpanel/cgi/actions.sh" "$HERE/webpanel/cgi/auth.sh" "$CGI/"

# call МЕТОД ПУТЬ ТЕЛО [QUERY] — печатает «код<TAB>json».
call() {
    _body="$3"
    _out=$(printf '%s' "$_body" | env -i PATH="$PATH" \
        LISTS_DIR="$DATA" ZAPRET2_DIR="$DATA" CONFIG_FILE="$DATA/config" \
        REQUEST_METHOD="$1" PATH_INFO="$2" QUERY_STRING="${4:-}" \
        CONTENT_LENGTH="$(printf '%s' "$_body" | wc -c | tr -d ' ')" CONTENT_TYPE=text/plain \
        HTTP_HOST=127.0.0.1 HTTP_X_Z2K_PANEL=1 HTTP_SEC_FETCH_SITE=same-origin \
        sh "$CGI/api.sh" 2>/dev/null | tr -d '\r')
    _code=$(printf '%s\n' "$_out" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -1)
    printf '%s\t%s\n' "${_code:-?}" "$(printf '%s\n' "$_out" | tail -1)"
}
rev() { call GET /domain-groups "" | cut -f2 | sed -n 's/.*"revision":"\([0-9a-f]*\)".*/\1/p'; }

# Прогон всех свойств CGI. Печатает OK/BAD-строки, как сценарии панели.
cgi_suite() {
    DATA="$TMP/data.$$.$1"; rm -rf "$DATA"; mkdir -p "$DATA"
    t() { if [ "$2" = 1 ]; then echo "OK $1"; else echo "BAD $1 — $3"; fi; }

    r=$(call GET /domain-groups "")
    case "$r" in 200*'"text":""'*) t "пустой файл отдаётся пустым текстом" 1 ;; *) t "пустой файл отдаётся пустым текстом" 0 "$r" ;; esac
    r0=$(rev)

    good=$(printf '# мои\n[Discord]\nDiscord.com\ndiscord.media\ndiscord.com\n\n[YouTube 📺]\nyoutube.com\n')
    r=$(call POST /domain-groups/save "$good" "revision=$r0")
    case "$r" in 200*) t "корректный файл сохраняется" 1 ;; *) t "корректный файл сохраняется" 0 "$r" ;; esac
    want=$(printf '# мои\n[Discord]\ndiscord.com\ndiscord.media\n\n[YouTube 📺]\nyoutube.com')
    [ "$(cat "$DATA/domain-groups.txt")" = "$want" ] \
        && t "домены приведены к нижнему регистру, повтор внутри группы схлопнут, комментарий и эмодзи на месте" 1 \
        || t "нормализация файла" 0 "$(tr '\n' '|' < "$DATA/domain-groups.txt")"

    r1=$(rev)
    before=$(cat "$DATA/domain-groups.txt")
    bad_case() {
        r=$(call POST /domain-groups/save "$(printf "$2")" "revision=$r1")
        case "$r" in "400	"*"$3"*) t "отказ: $1" 1 ;; *) t "отказ: $1" 0 "$r" ;; esac
    }
    bad_case "домен в двух группах"          '[A]\nx.com\n[B]\nx.com\n'         'Строка 4: домен x.com уже входит в группу «A»'
    bad_case "домен до первой группы"         'x.com\n'                          'до первой группы'
    bad_case "двойник имени группы"           '[Mail]\na.com\n[mail]\nb.com\n'   'уже есть в строке 1'
    bad_case "группа без имени"               '[ ]\n'                            'нет имени'
    bad_case "незакрытая скобка"              '[A\n'                             'квадратных скобках'
    bad_case "адрес вместо домена"            '[A]\nhttps://x.com/\n'            'некорректный домен'
    bad_case "скобка внутри имени"            '[a]b]\n'                          'нельзя использовать'
    [ "$(cat "$DATA/domain-groups.txt")" = "$before" ] \
        && t "отказ не трогает файл" 1 || t "отказ не трогает файл" 0 "файл изменён"

    # Устаревшая версия: вкладка открыта до чужой правки.
    r=$(call POST /domain-groups/save "$(printf '[Late]\nlate.org\n')" "revision=$r0")
    case "$r" in "409	"*"другом устройстве"*) t "правка по устаревшей версии отклонена с 409" 1 ;; *) t "правка по устаревшей версии отклонена с 409" 0 "$r" ;; esac
    [ "$(cat "$DATA/domain-groups.txt")" = "$before" ] \
        && t "устаревшая правка не затёрла файл" 1 || t "устаревшая правка не затёрла файл" 0 "$(tr '\n' '|' < "$DATA/domain-groups.txt")"

    r=$(call POST /domain-groups/save "$(printf '[A]\nx.com\n')" "revision=zzz")
    case "$r" in "400	"*) t "мусор вместо версии отклонён" 1 ;; *) t "мусор вместо версии отклонён" 0 "$r" ;; esac

    big=$(awk 'BEGIN { printf "[Big]\n"; for (i = 0; i < 20000; i++) printf "host%05d.example\n", i }')
    r=$(call POST /domain-groups/save "$big" "revision=$r1")
    case "$r" in "413	"*) t "больше 256 КБ — 413" 1 ;; *) t "больше 256 КБ — 413" 0 "$(printf '%s' "$r" | cut -c1-80)" ;; esac
}

run_cgi() {
    cgi_suite "$1" | while IFS= read -r line; do
        case "$line" in
            "OK "*)  printf '[PASS] %s\n' "${line#OK }" ;;
            "BAD "*) printf '[FAIL] %s\n' "${line#BAD }" ;;
        esac
    done
}

out=$(run_cgi main)
printf '%s\n' "$out"
PASS=$((PASS + $(printf '%s\n' "$out" | grep -c '^\[PASS\]')))
FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^\[FAIL\]')))

# --- переустановка -----------------------------------------------------------
INST="$HERE/lib/install.sh"
MARK='for _grp in domain-groups; do'
extract() {
    awk -v want="$1" -v mark="$MARK" '
        index($0, mark) { n++; if (n == want) grab = 1 }
        grab { print }
        grab && /^[[:space:]]*done[[:space:]]*$/ { exit }
    ' "$2"
}
install_suite() {
    _inst="$1"
    extract 1 "$_inst" > "$TMP/backup.sh"
    extract 2 "$_inst" > "$TMP/restore.sh"
    if ! [ -s "$TMP/backup.sh" ] || ! [ -s "$TMP/restore.sh" ]; then
        echo "BAD обе половины переноса групп найдены в install.sh"; return
    fi
    TREE="$TMP/inst/opt/zapret2"; BK="$TMP/inst/backup"
    rm -rf "$TMP/inst"; mkdir -p "$TREE/lists" "$BK"
    printf '[Discord]\ndiscord.com\n' > "$TREE/lists/domain-groups.txt"
    (
        print_info() { :; }; print_warning() { :; }; die() { exit 7; }
        ZAPRET2_DIR="$TREE"; backup_tmp="$BK"
        . "$TMP/backup.sh"
    )
    rm -rf "$TREE"; mkdir -p "$TREE/lists"
    (
        print_info() { :; }; print_warning() { :; }; die() { exit 7; }
        ZAPRET2_DIR="$TREE"; backup_tmp="$BK"
        . "$TMP/restore.sh"
    )
    if [ "$(cat "$TREE/lists/domain-groups.txt" 2>/dev/null)" = "$(printf '[Discord]\ndiscord.com')" ]; then
        echo "OK группы доменов переживают переустановку"
    else
        echo "BAD группы доменов переживают переустановку"
    fi
    if grep -q 'lists/autohostlist-domains.txt lists/domain-groups.txt' "$_inst"; then
        echo "OK группы спасаются и из сироты прерванной установки"
    else
        echo "BAD группы спасаются и из сироты прерванной установки"
    fi
}
out=$(install_suite "$INST" | sed -e 's/^OK /[PASS] /' -e 's/^BAD /[FAIL] /')
printf '%s\n' "$out"
PASS=$((PASS + $(printf '%s\n' "$out" | grep -c '^\[PASS\]')))
FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^\[FAIL\]')))

# --- мутанты -----------------------------------------------------------------
# Краснеть обязана проверка, а не загрузка: мутант, сломавший синтаксис, тоже
# дал бы красное и выдал бы себя за пойманную поломку — поэтому dash -n.
cgi_mut() {
    _label="$1"; _sed="$2"
    sed "$_sed" "$HERE/webpanel/cgi/actions.sh" > "$CGI/actions.sh"
    if cmp -s "$CGI/actions.sh" "$HERE/webpanel/cgi/actions.sh"; then
        no "мутант собрался: $_label" "файл изменён" "не изменился"
    elif ! dash -n "$CGI/actions.sh" 2>/dev/null; then
        no "мутант синтаксически цел: $_label" "dash -n" "ошибка"
    elif run_cgi "mut" | grep -q '^\[FAIL\]'; then
        ok "тест ловит поломку: $_label"
    else
        no "тест ловит поломку: $_label" "набор краснеет" "зелёный"
    fi
    cp "$HERE/webpanel/cgi/actions.sh" "$CGI/actions.sh"
}
cgi_mut "сохранение без сверки версии" 's/\[ "\$current" = "\$expected" \] || {$/[ "$current" = "$current" ] || {/'
cgi_mut "домен в двух группах пропускается" 's/^                if (owner\[d\] == cur) next$/                next/'
cgi_mut "домен до первой группы пропускается" 's/if (cur == "") fail(/if (0) fail(/'
cgi_mut "отказ оставляет частично записанный файл" 's/^    '"'"' "\$raw" > "\$tmp" || exit 2$/    '"'"' "$raw" > "$tmp"; cp "$tmp" "$target"; [ -s "$tmp" ] || exit 2; grep -q . "$tmp" || exit 2/'

inst_mut() {
    _label="$1"; _sed="$2"
    sed "$_sed" "$INST" > "$TMP/install.mut.sh"
    if cmp -s "$TMP/install.mut.sh" "$INST"; then
        no "мутант собрался: $_label" "файл изменён" "не изменился"
    elif install_suite "$TMP/install.mut.sh" | grep -q '^BAD'; then
        ok "тест ловит поломку: $_label"
    else
        no "тест ловит поломку: $_label" "набор краснеет" "зелёный"
    fi
}
inst_mut "бэкап групп не делается" 's|cp -f "$ZAPRET2_DIR/lists/${_grp}.txt" "$backup_tmp/${_grp}.txt"|true|'
inst_mut "группы не возвращаются" 's|if cp -f "$backup_tmp/${_grp}.txt" "${ZAPRET2_DIR}/lists/${_grp}.txt" 2>/dev/null; then|if true; then|'

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
