#!/bin/sh
# tests/test_detector_names_resolvable.sh — каждое имя детектора в конфиге
# обязано быть определено в отгружаемом lua.
#
# ЗАЧЕМ. nfqws2 резолвит детекторы ПО ИМЕНИ и на неизвестном имени валится в
# error() — на каждом пакете профиля. Это не «детектор не работает»: профиль
# становится пустышкой при зелёном статусе службы и пустом логе. Сам конфиг
# при этом выглядит корректным, и глазами такое не ловится.
#
# Проверка появилась 26.08.2026, когда удаление мёртвого z2k-detectors.lua
# оставило в генераторе четыре инжекции имён из него. По умолчанию их срезал
# более поздний проход, поэтому в боевом конфиге их не было — но при
# Z2K_NATIVE_DETECTORS=0 они доехали бы до движка. Мина лежала бы тихо.
#
# Тест держит ИНВАРИАНТ, а не список имён: перечисление пришлось бы обновлять
# руками при каждом новом детекторе, а забытое обновление — ровно та ошибка,
# от которой тест и заводится.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

MOCK=$(mktemp -d) || exit 1
trap 'rm -rf "$MOCK"' EXIT INT TERM
mkdir -p "$MOCK/extra_strats/TCP/YT" "$MOCK/extra_strats/TCP/YT_GV" \
         "$MOCK/extra_strats/TCP/RKN" "$MOCK/extra_strats/UDP/YT" \
         "$MOCK/lists" "$MOCK/lua"
echo youtube.com     > "$MOCK/extra_strats/TCP/YT/List.txt"
echo googlevideo.com > "$MOCK/extra_strats/TCP/YT_GV/List.txt"
echo youtube.com     > "$MOCK/extra_strats/UDP/YT/List.txt"
echo example.com     > "$MOCK/extra_strats/TCP/RKN/List.txt"
printf 'ISP_INTERFACE=eth3\n' > "$MOCK/config"
cp files/lua/*.lua "$MOCK/lua/" 2>/dev/null

OPT=$(
    . ./lib/utils.sh 2>/dev/null
    . ./lib/config_official.sh
    ZAPRET2_DIR="$MOCK" generate_nfqws2_opt_from_strategies 2>/dev/null
)
[ -n "$OPT" ] || { printf 'SKIP: генератор ничего не выдал\n'; exit 0; }

# Имена, на которые конфиг ссылается: детекторы, генератор host-ключей и
# fooling-функции — движок резолвит по имени всё перечисленное.
NAMES=$(printf '%s' "$OPT" | tr ' :' '\n\n' \
        | grep -oE '^(failure_detector|success_detector|hostkey|fool)=[A-Za-z_][A-Za-z0-9_]*' \
        | cut -d= -f2 | sort -u)

if [ -z "$NAMES" ]; then
    no "конфиг не содержит ни одной ссылки по имени — проверка потеряла смысл"
else
    for n in $NAMES; do
        # Определение ищем ТОЛЬКО в том, что реально отгружается: files/lua.
        # Апстримные standard_* приходят с движком и здесь не проверяются.
        case "$n" in
            standard_*) ok "$n — штатное имя движка"; continue ;;
        esac
        if grep -rqE "^(local )?function ${n}[[:space:]]*\(" files/lua/ 2>/dev/null; then
            ok "$n определён в files/lua"
        else
            no "$n НЕ определён ни в одном отгружаемом lua — движок упадёт в error()"
        fi
    done
fi

# Обратная сторона: удалённый файл не должен грузиться и скачиваться.
if grep -q 'z2k-detectors\.lua' files/S99zapret2.new 2>/dev/null; then
    if grep -E 'LUA_Z2K_DETECTORS|--lua-init=@.*z2k-detectors' files/S99zapret2.new >/dev/null 2>&1; then
        no "S99zapret2.new всё ещё грузит удалённый z2k-detectors.lua"
    else
        ok "в S99zapret2.new остался только комментарий об удалении"
    fi
else
    ok "S99zapret2.new не ссылается на удалённый файл"
fi
if grep -qE 'z2k_fetch .*z2k-detectors\.lua|output=.*z2k-detectors\.lua' z2k.sh 2>/dev/null; then
    no "z2k.sh всё ещё скачивает удалённый z2k-detectors.lua"
else
    ok "z2k.sh не скачивает удалённый файл"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
