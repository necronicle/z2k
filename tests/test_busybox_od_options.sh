#!/bin/sh
# tests/test_busybox_od_options.sh — роутерный код не зовёт od с опциями,
# которых у BusyBox нет.
#
# ЗАЧЕМ. Issue #43: переустановка объявляла повреждёнными ВСЕ 21 игровой список
# WARP и все 22 файла кеша, отменяла перенос целиком и заново качала их из сети.
# Причина — одна строка:
#
#     _wgt=$(tail -c 1 "$1" 2>/dev/null | od -An -c 2>/dev/null | tr -d ' ')
#     [ "$_wgt" = "\n" ]
#
# BusyBox od знает ТОЛЬКО -abcdeFfhiloxsv. На -A он отвечает «od: invalid option
# -- 'A'» и выходит с ошибкой; stderr здесь закрыт, поэтому подстановка отдавала
# пусто, сравнение не проходило НИКОГДА, и проверка целостности превращалась в
# «всё битое». Та же строка стояла в переносе geosite-целей (роутер откатывался
# на шипнутый снапшот RKN вместо своего свежего) и в срезе живого лога панели.
#
# ПОЧЕМУ ЭТОГО НЕ ВИДЕЛ СЬЮТ. Тесты идут на маке и на ubuntu-latest, где od —
# из GNU coreutils, и -A/-N/-t там есть. Ни один поведенческий тест такое не
# поймает по построению: он проверяет не тот od. Ловится только запретом на
# уровне текста — и это ровно тот случай, где текстовая проверка честнее
# поведенческой.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM

# --- 1. Статический запрет ----------------------------------------------------
#
# Роутерный код — это lib/, files/, webpanel/ и корневые скрипты. scripts/ и
# tests/ идут на машине разработчика и в CI, там coreutils, и запрет к ним не
# относится.
#
# Разрешённые опции взяты из самой строки помощи BusyBox v1.37.0 на роутере:
#   Usage: od [-abcdeFfhiloxsv] [FILE]
BAD=""
for f in $(find "$ROOT/lib" "$ROOT/files" "$ROOT/webpanel" -name '*.sh' 2>/dev/null) \
         "$ROOT/z2k.sh" "$ROOT/z2k_cleanup.sh" "$ROOT/files/S99zapret2.new"; do
    [ -f "$f" ] || continue
    # od с опцией вне набора busybox. Комментарии не считаем: в них разбор
    # этой самой аварии.
    hits=$(grep -n '[^#]*\bod  *-' "$f" 2>/dev/null \
           | grep -v '^[0-9]*: *#' \
           | grep -E '\bod +-[a-zA-Z]*[ANtjw-]' || true)
    [ -n "$hits" ] && BAD="$BAD
$(basename "$f"): $hits"
done
if [ -z "$BAD" ]; then
    ok "od зовётся только с опциями, которые есть у BusyBox"
else
    no "od зовётся только с опциями, которые есть у BusyBox" "ничего" "$BAD"
fi

# --- 2. Поведение замены ------------------------------------------------------
#
# Проверка «файл кончается переводом строки» теперь делается подстановкой
# команды: она съедает завершающие переводы строки, значит пустой результат и
# есть перевод строки. Гоняем ТУ САМУЮ функцию из install.sh, а не её копию.
sed -n '/_wg_sane() {/,/^        }/p' "$ROOT/lib/install.sh" \
    | sed 's/^        //' > "$SB/fn.sh"
if [ ! -s "$SB/fn.sh" ]; then
    no "_wg_sane извлекается из install.sh" "функция" "не найдена"
else
    ok "_wg_sane извлекается из install.sh"
    printf 'steamcommunity.com\nsteampowered.com\n' > "$SB/good.txt"
    printf 'steamcommunity.com\nsteampowe'          > "$SB/cut.txt"
    printf 'steamcommunity.com\n\377\377\377\n'     > "$SB/junk.txt"
    : > "$SB/empty.txt"
    run() { sh -c ". '$SB/fn.sh'; _wg_sane '$1'; echo \$?"; }
    assert_eq "целый список принимается"            "0" "$(run "$SB/good.txt")"
    assert_eq "обрубок без перевода строки отвергнут" "1" "$(run "$SB/cut.txt")"
    assert_eq "файл с 0xFF отвергнут"                "1" "$(run "$SB/junk.txt")"
    assert_eq "пустой файл отвергнут"                "1" "$(run "$SB/empty.txt")"
fi

# --- 3. Обе копии проверки перешли на подстановку -----------------------------
#
# Их две — игровые списки WARP и цели geosite, — и они разъезжались уже дважды.
_subst=$(grep -c -- '-z "$(tail -c 1' "$ROOT/lib/install.sh")
assert_eq "обе проверки конца файла — подстановкой, не od" "2" "$_subst"

# --- 4. Отрицательный контроль ------------------------------------------------
#
# Запрет обязан ЛОВИТЬ ту самую строку, из-за которой всё и случилось. Без этой
# проверки правило легко выродилось бы в регулярку, не совпадающую ни с чем, и
# зеленело бы вечно.
mkdir -p "$SB/lib"
printf '#!/bin/sh\n_t=$(tail -c 1 "$1" | od -An -c | tr -d " ")\n' > "$SB/lib/bait.sh"
_caught=$(grep -n '[^#]*\bod  *-' "$SB/lib/bait.sh" 2>/dev/null \
          | grep -v '^[0-9]*: *#' \
          | grep -cE '\bod +-[a-zA-Z]*[ANtjw-]')
assert_eq "правило ловит исходную строку из issue #43" "1" "$_caught"
# И не срабатывает на том, что BusyBox умеет.
printf '#!/bin/sh\nod -c "$1"\n' > "$SB/lib/fine.sh"
_false=$(grep -n '[^#]*\bod  *-' "$SB/lib/fine.sh" 2>/dev/null \
         | grep -v '^[0-9]*: *#' \
         | grep -cE '\bod +-[a-zA-Z]*[ANtjw-]')
assert_eq "и не ругается на разрешённый od -c" "0" "$_false"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
