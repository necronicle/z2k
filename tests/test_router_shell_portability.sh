#!/bin/sh
# tests/test_router_shell_portability.sh — роутерный код не зовёт того, чего на
# роутере нет: ни отсутствующих команд, ни опций, которых нет у BusyBox.
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
           | grep -vE '^[0-9]+:[[:space:]]*#' \
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
          | grep -vE '^[0-9]+:[[:space:]]*#' \
          | grep -cE '\bod +-[a-zA-Z]*[ANtjw-]')
assert_eq "правило ловит исходную строку из issue #43" "1" "$_caught"
# И не срабатывает на том, что BusyBox умеет.
printf '#!/bin/sh\nod -c "$1"\n' > "$SB/lib/fine.sh"
_false=$(grep -n '[^#]*\bod  *-' "$SB/lib/fine.sh" 2>/dev/null \
         | grep -vE '^[0-9]+:[[:space:]]*#' \
         | grep -cE '\bod +-[a-zA-Z]*[ANtjw-]')
assert_eq "и не ругается на разрешённый od -c" "0" "$_false"

# --- 5. Команды, которых на роутере нет вовсе ---------------------------------
#
# ВТОРОЙ СЛУЧАЙ ТОГО ЖЕ КЛАССА, найден при разборе issue #43. Entware собирает
# busybox без апплета pkill: `command -v pkill` пусто, `busybox pkill` отвечает
# «applet not found», в `busybox --list` есть только pgrep и killall. А в коде
# он стоял пять раз — снять зависший lighttpd при удалении панели, добить
# планировщик и движок WARP по cmdline, прибрать осиротевший tcpdump. Все пять
# под `2>/dev/null || true`: не падало, не работало, никто не замечал.
#
# Список — с роутера владельца (aarch64, Entware, busybox 1.37.0). Именно
# ЗАПРЕТ, а не сверка с полным манифестом: манифест по одному роутеру выдал бы
# ложные срабатывания на арках с другой сборкой busybox, а эти семь отсутствуют
# в Entware как таковом.
ABSENT="pkill timeout flock comm realpath nl fold"
BADCMD=""
for f in $(find "$ROOT/lib" "$ROOT/files" "$ROOT/webpanel" -name '*.sh' 2>/dev/null) \
         $(find "$ROOT/files/init.d" "$ROOT/files/ndm" -type f 2>/dev/null) \
         "$ROOT/z2k.sh" "$ROOT/z2k_cleanup.sh" "$ROOT/files/S99zapret2.new"; do
    [ -f "$f" ] || continue
    for c in $ABSENT; do
        # Вызов команды: начало строки, пайп, ;, &&, ( или $( — и сразу имя.
        # Так `--connect-timeout` и `$timeout` под запрет не попадают.
        hits=$(grep -nE "(^|[|;&(]|\\\$\()[[:space:]]*${c}[[:space:]]" "$f" 2>/dev/null \
               | grep -vE '^[0-9]+:[[:space:]]*#' || true)
        [ -n "$hits" ] && BADCMD="$BADCMD
$(basename "$f") зовёт $c: $(printf '%s' "$hits" | head -2)"
    done
done
if [ -z "$BADCMD" ]; then
    ok "роутерный код не зовёт команд, которых на роутере нет"
else
    no "роутерный код не зовёт команд, которых на роутере нет" "ничего" "$BADCMD"
fi

# Отрицательный контроль: правило обязано ловить ту самую строку, что стояла в
# S99z2k-scheduler, и не ругаться на curl --connect-timeout.
printf '#!/bin/sh\npkill -f "z2k-scheduler" 2>/dev/null\n' > "$SB/lib/bait2.sh"
_c2=$(grep -cnE "(^|[|;&(]|\\\$\()[[:space:]]*pkill[[:space:]]" "$SB/lib/bait2.sh" 2>/dev/null)
assert_eq "правило ловит pkill" "1" "$_c2"
printf '#!/bin/sh\ncurl -fsSL --connect-timeout 10 "$1"\n' > "$SB/lib/fine2.sh"
_c3=$(grep -cnE "(^|[|;&(]|\\\$\()[[:space:]]*timeout[[:space:]]" "$SB/lib/fine2.sh" 2>/dev/null)
assert_eq "и не ругается на curl --connect-timeout" "0" "$_c3"

# --- 6. Позиционные аргументы `sh -c` требуют гарантии интерпретатора --------
#
# ТРЕТИЙ СЛУЧАЙ ТОГО ЖЕ КЛАССА. /bin/sh на Keenetic — не ash, а NDM Shell
# Wrapper v1.0.10, и позиционные аргументы `sh -c` он ТЕРЯЕТ. Замер на роутере
# владельца 2026-08-27:
#
#   /bin/sh     -c 'echo [$0] [$1]' _ ААА  →  [/opt/bin/sh] []
#   /opt/bin/sh -c 'echo [$0] [$1]' _ ААА  →  [_] [ААА]
#
# В files/z2k-blocked-monitor.sh так запускался tcpdump с ДВЕНАДЦАТЬЮ
# аргументами, а PATH скрипт не объявлял вовсе — единственный из наших. Под
# cron (у Entware там нет /opt/bin) команда захвата собиралась из пустых строк.
#
# Кто зовёт `sh -c` с аргументами — обязан объявить PATH, где /opt впереди:
# тогда `sh` разрешается в busybox, а он POSIX соблюдает.
BADSHC=""
for f in $(find "$ROOT/files" "$ROOT/lib" "$ROOT/webpanel" -name '*.sh' 2>/dev/null) \
         $(find "$ROOT/files/init.d" "$ROOT/files/ndm" -type f 2>/dev/null) \
         "$ROOT/z2k.sh" "$ROOT/z2k_cleanup.sh"; do
    [ -f "$f" ] || continue
    # Идиома передачи аргументов: закрывающая кавычка, затем `_` и аргументы.
    # Комментарии отбрасываем: разбор этой самой аварии написан прямо в них,
    # и без отсева правило ловило бы собственное объяснение вместо кода.
    grep -vE '^[[:space:]]*#' "$f" 2>/dev/null | grep -qE "' _( |\\\\|\$)" || continue
    grep -qE '^[[:space:]]*export PATH=.*/opt/(sbin|bin)' "$f" 2>/dev/null && continue
    BADSHC="$BADSHC $(basename "$f")"
done
if [ -z "$BADSHC" ]; then
    ok "sh -c с аргументами — только там, где PATH гарантирует busybox"
else
    no "sh -c с аргументами — только там, где PATH гарантирует busybox" "ничего" "$BADSHC"
fi

# Отрицательный контроль: правило обязано ловить файл с аргументами и без PATH.
mkdir -p "$SB/bait3"
cat > "$SB/bait3/bad.sh" <<'BAIT'
#!/bin/sh
sh -c '"$1" -i "$2"' _ "$a" "$b"
BAIT
_b3=0
grep -qE "^[[:space:]]*' _( |\\|$)|sh -c .*' _ " "$SB/bait3/bad.sh" 2>/dev/null \
  && ! grep -qE '^[[:space:]]*export PATH=.*/opt/(sbin|bin)' "$SB/bait3/bad.sh" 2>/dev/null && _b3=1
assert_eq "правило ловит sh -c с аргументами без PATH" "1" "$_b3"

# --- 7. Сами наборы тоже не имеют права зависеть от аргументов `sh -c` -------
#
# Иначе набор просто СЛЕПНЕТ на роутере: вложенная оболочка получает пустые
# аргументы, проверяемый код не исполняется, и красное означает не дефект, а
# неспособность теста что-либо проверить. Прогон 2026-08-27 дал так 13 таких
# мест в шести наборах — включая проверку слов согласия («y», «да»), которая
# на роутере читала пустую строку и объявляла мёртвой живую функцию.
#
# Аргумент передаётся переменной окружения — она переживает любую оболочку.
BADT=""
for f in "$ROOT"/tests/test_*.sh; do
    [ -f "$f" ] || continue
    case "$f" in *test_router_shell_portability.sh) continue ;; esac
    grep -vE '^[[:space:]]*#' "$f" 2>/dev/null | grep -qE "' _( |\\\\|\$)" \
        && BADT="$BADT $(basename "$f")"
done
if [ -z "$BADT" ]; then
    ok "наборы передают аргументы окружением, а не позиционно"
else
    no "наборы передают аргументы окружением" "ничего" "$BADT"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
