#!/bin/sh
# tests/test_warp_games_survive_reinstall.sh — игровые списки WARP обязаны
# пережить переустановку, иначе гейт на их загрузку — пустое обещание.
#
# ЗАЧЕМ. В install.sh стоит гейт:
#
#     [ -z "$(ls "${ZAPRET2_DIR}/lists/warp/games/"*.txt 2>/dev/null)" ]
#
# с комментарием «gated on the directory being empty, so a reinstall that
# already has them does not go out to the network at all». Сработать он не мог
# НИКОГДА: за восемьдесят секунд до него step_build_zapret2 делает
#
#     mv "$ZAPRET2_DIR" "${ZAPRET2_DIR}.old.$$"
#
# и обратно из .old ничего не переносится — единственный путь назад
# (z2k_restore_old_tree) срабатывает только при ПРОВАЛЕ установки. Значит на
# реинсталле каталог пуст всегда, и шаг, который сам себя подписывает «это
# самый долгий шаг установки», отрабатывает каждый раз целиком.
#
# Замер 2026-08-21 на роутере Марка: 79.7 с из 405, 21 файл, 740 КБ — при
# GAME_WARP_ENABLED=0, то есть при выключенной фиче.
#
# Здесь пинится ровно то, что чинилось: списки уезжают в backup ДО mv и
# возвращаются ПОСЛЕ, а гейт после этого видит непустой каталог.
#
# Гейт берётся ИЗ ИСХОДНИКА, а не переписывается сюда: если бэкап начнёт
# складывать файлы по одному пути, а гейт спрашивать другой, правка станет
# бесполезной молча — тест обязан это поймать.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="${Z2K_INSTALL_UNDER_TEST:-$ROOT/lib/install.sh}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-warpgames.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- извлечение блоков из install.sh -----------------------------------------
#
# Оба блока живут внутри огромных функций, целиком их не вынуть. Берём по
# опорной строке и до закрывающего `fi` на том же отступе.
# `awk -v` обрабатывает escape-последовательности в присваивании, поэтому
# regexp сюда передавать нельзя: `\[` доехало бы как `[` и открыло класс
# символов. Ищем ПОДСТРОКУ через index().
extract_block() {  # extract_block <опорная подстрока> <отступ>
    awk -v pat="$1" -v ind="$2" '
        index($0, pat) > 0 { inb = 1 }
        inb { print }
        inb && $0 == ind "fi" { exit }
    ' "$SRC"
}

extract_block 'if [ -d "$ZAPRET2_DIR/lists/warp/games" ]' '            ' > "$TMP/backup.sh"
extract_block 'if [ -d "$backup_tmp/warp-games" ]'        '    '        > "$TMP/restore.sh"

for b in backup restore; do
    if [ -s "$TMP/$b.sh" ] && grep -q 'warp-games' "$TMP/$b.sh"; then
        ok "блок $b извлечён из install.sh"
    else
        no "блок $b извлечён" "непустой блок" "пусто"
        printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$((FAIL))"
        exit 1
    fi
done

# Гейт — дословно из исходника (та строка, что решает, идти ли в сеть).
GATE=$(grep -n 'lists/warp/games/"\*\.txt 2>/dev/null)" \]; then' "$SRC" \
       | head -1 | sed 's/^[0-9]*: *//; s/; then$//')
if [ -n "$GATE" ]; then
    ok "гейт загрузки найден в исходнике: ${GATE}"
else
    no "гейт загрузки найден в исходнике" "выражение с games/*.txt" "не найдено"
fi

# --- харнесс ------------------------------------------------------------------
#
# Блоки исполняются как есть, обёрнутые в функцию: в restore есть `local`, а
# вне функции ash/dash на нём падает.
run_cycle() {  # run_cycle <сколько игровых списков положить>
    _n="$1"
    rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/opt/lists/warp/games" "$TMP/bk"
    printf 'мой-личный-список\n' > "$TMP/opt/lists/warp/user.txt"
    printf '1\n' > "$TMP/opt/lists/warp/.enabled"
    _i=1
    while [ "$_i" -le "$_n" ]; do
        printf 'домен-%s.example\n' "$_i" > "$TMP/opt/lists/warp/games/game$_i.txt"
        _i=$((_i + 1))
    done

    env -i PATH="/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
        SB="$TMP" GATEEXPR="$GATE" /bin/sh -c '
            ZAPRET2_DIR="$SB/opt"; backup_tmp="$SB/bk"
            print_warning() { printf "WARN %s\n" "$1" >> "$SB/log"; }
            print_info()    { printf "INFO %s\n" "$1" >> "$SB/log"; }
            : > "$SB/log"

            # --- как в установке: сохранить, снести дерево, восстановить ---
            _backup() { . "$SB/backup.sh"; }
            _backup

            # mv "$ZAPRET2_DIR" .old.$$ — с точки зрения нового дерева это
            # ровно исчезновение всего содержимого.
            rm -rf "$ZAPRET2_DIR"; mkdir -p "$ZAPRET2_DIR/lists/warp"

            _restore() { . "$SB/restore.sh"; }
            _restore

            # Гейт из исходника: истина = «пойдём в сеть».
            if eval "$GATEEXPR"; then printf "СЕТЬ"; else printf "ПРОПУСК"; fi
            printf ":%s" "$(ls "$ZAPRET2_DIR/lists/warp/games/"*.txt 2>/dev/null | wc -l | tr -d " ")"
        ' 2>/dev/null
}

# --- 1. ГЛАВНОЕ: списки пережили цикл, гейт больше не гонит в сеть -----------
r=$(run_cycle 3)
case "$r" in
    ПРОПУСК:3) ok "три игровых списка пережили переустановку, гейт пропускает загрузку" ;;
    СЕТЬ:*)    no "гейт пропускает загрузку после переноса" "ПРОПУСК:3" "$r (всё ещё идём в сеть)" ;;
    *)         no "игровые списки пережили переустановку" "ПРОПУСК:3" "$r" ;;
esac

# --- 2. Содержимое, а не только имена ----------------------------------------
if [ "$(cat "$TMP/opt/lists/warp/games/game2.txt" 2>/dev/null)" = "домен-2.example" ]; then
    ok "содержимое списка доехало неповреждённым"
else
    no "содержимое списка доехало" "домен-2.example" "$(cat "$TMP/opt/lists/warp/games/game2.txt" 2>/dev/null)"
fi

# --- 3. Свежая установка по-прежнему идёт в сеть ------------------------------
#
# Иначе правка обернулась бы худшим из исходов: новый роутер остался бы вообще
# без списков, и до ночного обновления взять их было бы неоткуда.
r=$(run_cycle 0)
case "$r" in
    СЕТЬ:0) ok "на свежей установке (списков не было) гейт по-прежнему идёт в сеть" ;;
    *)      no "свежая установка идёт в сеть" "СЕТЬ:0" "$r" ;;
esac

# --- 4. Перенос best-effort, а не fail-closed ---------------------------------
#
# Игровые списки — единственное в этом блоке, что восстановимо загрузкой.
# Падать из-за них установка не имеет права: не скопировалось — просто качаем,
# как качали раньше.
if grep -q 'die ' "$TMP/backup.sh"; then
    no "перенос игровых списков best-effort" "без die" "в блоке есть die — установка упадёт из-за кеша"
else
    ok "перенос игровых списков best-effort (без die), как и должен быть кеш"
fi

# --- 5. Личные списки WARP не задеты ------------------------------------------
#
# Рядом лежит user-owned каталог с fail-closed бэкапом. Правка не должна была
# его тронуть — проверяем, что старый механизм цел.
if grep -q 'warp-lists' "$SRC" && grep -q 'Не удалось сохранить списки WARP' "$SRC"; then
    ok "fail-closed бэкап личных списков WARP на месте"
else
    no "fail-closed бэкап личных списков WARP" "цел" "исчез"
fi

# --- 6. Комментарий в auto_update.sh не остался враньём -----------------------
#
# Там стояло «games/ is deliberately not preserved across a reinstall» — ровно
# та посылка, которую эта правка отменяет. Комментарий, переживший своё
# основание, вреднее отсутствующего.
AU="$ROOT/lib/auto_update.sh"
if grep -q 'deliberately not' "$AU" 2>/dev/null; then
    no "auto_update.sh не утверждает, что games/ не переносится" "обновлён" "старая посылка на месте"
else
    ok "auto_update.sh не утверждает больше, что games/ не переносится"
fi

printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
