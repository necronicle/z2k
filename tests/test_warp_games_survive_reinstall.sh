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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-warpgames.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- извлечение блоков из install.sh -----------------------------------------
#
# Оба блока живут внутри огромных функций, целиком их не вынуть. Экстрактор
# общий (tests/lib/common.sh): третьей копией того же awk стал бы каждый новый
# тест реинсталла.
z2k_extract_block "$SRC" 'if [ -d "$ZAPRET2_DIR/lists/warp/games" ]' '            ' > "$TMP/backup.sh"
z2k_extract_block "$SRC" 'if [ -d "$backup_tmp/warp-games" ]'        '    '        > "$TMP/restore.sh"

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
#
# Второй аргумент — что положить рядом со списками и как это испортить:
#
#   (пусто)      только <имя>.txt, как было до появления переноса кеша;
#   full         .txt + .<имя>.raw + .<имя>.raw.etag на каждый список — так
#                каталог выглядит на роутере, где хоть раз отработал update_list;
#   raw-trunc    то же, но .game2.raw обрублен ПОСРЕДИ строки (обрыв записи);
#   txt-ff       то же, но game2.txt забит 0xFF (мёртвый NAND);
#   orphan-etag  .txt + пара .raw/.raw.etag плюс осиротевший .Ghost.raw.etag,
#                у которого своего .raw нет вовсе.
run_cycle() {  # run_cycle <сколько игровых списков положить> [что положить рядом]
    _n="$1"; _mode="${2:-}"
    rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/opt/lists/warp/games" "$TMP/bk"
    printf 'мой-личный-список\n' > "$TMP/opt/lists/warp/user.txt"
    printf '1\n' > "$TMP/opt/lists/warp/.enabled"
    _i=1
    while [ "$_i" -le "$_n" ]; do
        printf 'домен-%s.example\n' "$_i" > "$TMP/opt/lists/warp/games/game$_i.txt"
        case "$_mode" in
            '') : ;;
            *)  # кеш условных запросов пишется в ASCII — .raw это тело ответа
                printf 'host%s.example.com\n' "$_i" > "$TMP/opt/lists/warp/games/.game$_i.raw"
                printf '"etag-%s"\n' "$_i" > "$TMP/opt/lists/warp/games/.game$_i.raw.etag" ;;
        esac
        _i=$((_i + 1))
    done
    case "$_mode" in
        raw-trunc)
            # обрыв записи режет посреди строки: перевода строки в конце нет
            printf 'host1.example.com\nhost2.exa' > "$TMP/opt/lists/warp/games/.game2.raw" ;;
        txt-ff)
            printf '\377\377\377\377\377\377\377\377\n' > "$TMP/opt/lists/warp/games/game2.txt" ;;
        orphan-etag)
            printf '"etag-призрак"\n' > "$TMP/opt/lists/warp/games/.Ghost.raw.etag" ;;
    esac

    env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" \
        SB="$TMP" GATEEXPR="$GATE" "$Z2K_TEST_SH" -c '
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

# Что осталось в games/ после цикла. Считаем через find, а не глобом: весь кеш
# условных запросов — ДОТФАЙЛЫ, и именно они делали прежний откат пустым
# обещанием, потому что под `*.txt` не попадают.
games_have() {  # games_have <regexp по имени файла> → число
    find "$TMP/opt/lists/warp/games" -maxdepth 1 -type f 2>/dev/null \
        | sed 's|.*/||' | grep -c -- "$1"
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

# --- 3b. Порядок в исходнике ---------------------------------------------------
#
# Харнесс гоняет блоки в своём порядке и на их реальное место не смотрит. А
# дефект, ради которого всё писалось, — именно порядок: передвинь бэкап ЗА
# `mv "$ZAPRET2_DIR" "$_old_tree"`, и копировать будет уже нечего, каталог
# снова окажется пуст на каждом реинстале, и тест остался бы зелёным.
_ln_bk=$(grep -n 'if \[ -d "\$ZAPRET2_DIR/lists/warp/games" \]' "$SRC" | head -1 | cut -d: -f1)
_ln_mv=$(grep -n 'if mv "\$ZAPRET2_DIR" "\$_old_tree"' "$SRC" | head -1 | cut -d: -f1)
_ln_rs=$(grep -n 'if \[ -d "\$backup_tmp/warp-games" \]' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_ln_bk" ] && [ -n "$_ln_mv" ] && [ -n "$_ln_rs" ] \
   && [ "$_ln_bk" -lt "$_ln_mv" ] && [ "$_ln_mv" -lt "$_ln_rs" ]; then
    ok "бэкап (${_ln_bk}) до mv (${_ln_mv}), восстановление (${_ln_rs}) после"
else
    no "порядок: бэкап → mv → восстановление" "строки по возрастанию" \
       "бэкап=${_ln_bk:-нет} mv=${_ln_mv:-нет} restore=${_ln_rs:-нет}"
fi

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

# ============================================================================
# 7. Кеш условных запросов переносится вместе со списками
# ============================================================================
#
# Списки лежат как games/<имя>.txt, а рядом — дотфайлы .<имя>.raw и
# .<имя>.raw.etag: это то, чем update_list спрашивает «изменилось?». Под glob
# *.txt они не попадают. Пока переносились только .txt, первый же ночной прогон
# после переустановки тянул все 740 КБ заново: сравнивать было не с чем.
rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/opt/lists/warp/games" "$TMP/bk"
printf 'a.example.com\n' > "$TMP/opt/lists/warp/games/Game1.txt"
printf 'a.example.com\n' > "$TMP/opt/lists/warp/games/.Game1.raw"
printf '"etag-1"\n'      > "$TMP/opt/lists/warp/games/.Game1.raw.etag"
env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
    ZAPRET2_DIR="$SB/opt"; backup_tmp="$SB/bk"
    print_warning() { :; }; print_info() { :; }
    _b() { . "$SB/backup.sh"; }; _b
    rm -rf "$ZAPRET2_DIR"; mkdir -p "$ZAPRET2_DIR/lists/warp"
    _r() { . "$SB/restore.sh"; }; _r
' 2>/dev/null
_raw=$([ -s "$TMP/opt/lists/warp/games/.Game1.raw" ] && echo да || echo нет)
_et=$([ -s "$TMP/opt/lists/warp/games/.Game1.raw.etag" ] && echo да || echo нет)
if [ "$_raw" = "да" ] && [ "$_et" = "да" ]; then
    ok "кеш условных запросов (.raw + .raw.etag) пережил переустановку"
else
    no "кеш условных запросов пережил переустановку" "оба на месте" ".raw=$_raw .raw.etag=$_et"
fi

# ============================================================================
# 8. Частичный БЭКАП не должен проходить гейт «всё или ничего»
# ============================================================================
#
# Бэкап сам best-effort: cp каждого файла может упасть по отдельности, и на
# кончающейся флешке доедет, скажем, два файла из двадцати одного. Если гейт
# сравнивает с содержимым БЭКАПА, он такой перенос объявит полным — каталог
# станет непустым, и недостающие списки не подтянет уже никто: ни установка,
# ни self-heal авто-обновления, ни планировщик, все смотрят на ту же пустоту.
rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/opt/lists/warp/games" "$TMP/bk"
_i=1
while [ "$_i" -le 5 ]; do printf 'd%s.example.com\n' "$_i" > "$TMP/opt/lists/warp/games/G$_i.txt"; _i=$((_i+1)); done
env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" GATE="$GATE" "$Z2K_TEST_SH" -c '
    ZAPRET2_DIR="$SB/opt"; backup_tmp="$SB/bk"
    print_warning() { :; }; print_info() { :; }
    _b() { . "$SB/backup.sh"; }; _b
    # флешка кончилась: до бэкапа доехали только два файла из пяти
    rm -f "$backup_tmp/warp-games/G3.txt" "$backup_tmp/warp-games/G4.txt" "$backup_tmp/warp-games/G5.txt"
    rm -rf "$ZAPRET2_DIR"; mkdir -p "$ZAPRET2_DIR/lists/warp"
    _r() { . "$SB/restore.sh"; }; _r
' 2>/dev/null
_left=$(ls "$TMP/opt/lists/warp/games/"*.txt 2>/dev/null | wc -l | tr -d ' ')
if [ "$_left" = "0" ]; then
    ok "частичный перенос откачен целиком — гейт увидит пустоту и всё скачается"
else
    no "частичный перенос откачен" "0 файлов" "$_left — гейт решит, что переносить больше нечего"
fi


# ============================================================================
# 9. Пропавший счётчик источника НЕ должен выключать гейт
# ============================================================================
#
# Счётчик пишется с `|| true` — падать он права не имеет. Но если место на
# флешке кончилось ровно между копированием списков и его записью, счётчика
# нет. Раньше это молча превращалось в 0 и гейт «всё или ничего» отключался:
# частичный перенос проходил за полный. Сценарий тот же самый, под который
# гейт и писался.
rm -rf "$TMP/opt" "$TMP/bk"; mkdir -p "$TMP/opt/lists/warp/games" "$TMP/bk"
_i=1
while [ "$_i" -le 4 ]; do printf 'd%s.example.com\n' "$_i" > "$TMP/opt/lists/warp/games/S$_i.txt"; _i=$((_i+1)); done
env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
    ZAPRET2_DIR="$SB/opt"; backup_tmp="$SB/bk"
    print_warning() { :; }; print_info() { :; }
    _b() { . "$SB/backup.sh"; }; _b
    rm -f "$backup_tmp/warp-games/.source-count"   # место кончилось на этой записи
    rm -rf "$ZAPRET2_DIR"; mkdir -p "$ZAPRET2_DIR/lists/warp"
    _r() { . "$SB/restore.sh"; }; _r
' 2>/dev/null
_left=$(ls "$TMP/opt/lists/warp/games/"*.txt 2>/dev/null | wc -l | tr -d ' ')
if [ "$_left" = "0" ]; then
    ok "без счётчика перенос не принимается — гейт увидит пустоту и всё скачается"
else
    no "без счётчика перенос не принимается" "0 файлов" "$_left — гейт молча выключился"
fi


# ============================================================================
# 10. Порча содержимого откатывает перенос ЦЕЛИКОМ — вместе с дотфайлами
# ============================================================================
#
# До появления переноса порчу лечила сама переустановка: games/ пересевался с
# нуля. Теперь каталог едет вперёд, и битый файл уехал бы вместе с ним
# НАВСЕГДА: ночной прогон получает 304 против выжившего .raw.etag, санитайзер
# пересобирает .txt из ТОГО ЖЕ битого .raw, а страж усадки сравнивает файл сам
# с собой. Ни один из трёх слоёв порчу не видит.
#
# Отдельно и не менее важно — ЧТО именно сносит откат. Пока там стоял один
# glob *.txt, откат был обещанием на словах: дотфайлы .<имя>.raw и
# .<имя>.raw.etag под него не попадают. Гейт «games/ пуст» после такого отката
# звал обновлялку, каждый список отвечал 304 против выжившего .raw.etag, и
# .txt пересобирался из того же обрубка — в сеть не уходило ни байта, хотя
# сообщение обещало перекачку. Поэтому здесь проверяется не только пустота по
# *.txt, но и по обоим дотфайлам.

# (в) сначала контрольная точка: всё цело — перенос ОБЯЗАН быть принят.
# Без неё «откат целиком» проходил бы и на коде, который откатывает всегда.
r=$(run_cycle 3 full)
_t=$(games_have '\.txt$'); _rw=$(games_have '^\..*\.raw$'); _et=$(games_have '\.raw\.etag$')
if [ "$r" = "ПРОПУСК:3" ] && [ "$_t" = "3" ] && [ "$_rw" = "3" ] && [ "$_et" = "3" ]; then
    ok "целый каталог со списками и кешем перенесён полностью, гейт пропускает загрузку"
else
    no "целый каталог перенесён полностью" "ПРОПУСК:3, txt=3 raw=3 etag=3" \
       "$r, txt=$_t raw=$_rw etag=$_et"
fi

# (а) .<имя>.raw обрублен посреди строки, а все .txt целы. Гейт «games/ пуст»
#     такую порчу не видит вовсе — каталог-то непустой.
r=$(run_cycle 3 raw-trunc)
_t=$(games_have '\.txt$'); _rw=$(games_have '^\..*\.raw$'); _et=$(games_have '\.raw\.etag$')
if [ "$r" = "СЕТЬ:0" ] && [ "$_t" = "0" ] && [ "$_rw" = "0" ] && [ "$_et" = "0" ]; then
    ok "обрубленный .raw при целых .txt откатывает перенос целиком — не осталось ни .txt, ни .raw, ни .raw.etag"
else
    no "обрубленный .raw откатывает перенос целиком" "СЕТЬ:0, txt=0 raw=0 etag=0" \
       "$r, txt=$_t raw=$_rw etag=$_et"
fi

# (б) 0xFF в самом списке — штатный отказ мёртвого NAND на этой платформе.
r=$(run_cycle 3 txt-ff)
_t=$(games_have '\.txt$'); _rw=$(games_have '^\..*\.raw$'); _et=$(games_have '\.raw\.etag$')
if [ "$r" = "СЕТЬ:0" ] && [ "$_t" = "0" ] && [ "$_rw" = "0" ] && [ "$_et" = "0" ]; then
    ok "список, забитый 0xFF, откатывает перенос целиком — каталог пуст и всё скачается заново"
else
    no "0xFF в списке откатывает перенос целиком" "СЕТЬ:0, txt=0 raw=0 etag=0" \
       "$r, txt=$_t raw=$_rw etag=$_et"
fi


# ============================================================================
# 11. Осиротевший .<имя>.raw.etag в бэкап не попадает
# ============================================================================
#
# ETag без своего тела — это не «половина кеша», это ХУЖЕ пустоты: следующий
# условный запрос получает 304 «не изменилось», а сравнивать не с чем —
# санитайзеру нечего пересобирать, и цель остаётся без содержимого. Осиротеть
# .raw.etag может ровно тем же обрывом, что и всё прочее здесь.
#
# Поэтому бэкап ходит по .raw и берёт .raw.etag ТОЛЬКО прицепом к своему телу.
r=$(run_cycle 1 orphan-etag)
_ghost_bk=$([ -f "$TMP/bk/warp-games/.Ghost.raw.etag" ] && echo взят || echo пропущен)
_ghost_tree=$([ -f "$TMP/opt/lists/warp/games/.Ghost.raw.etag" ] && echo есть || echo нет)
_pair=$([ -f "$TMP/opt/lists/warp/games/.game1.raw" ] && \
        [ -f "$TMP/opt/lists/warp/games/.game1.raw.etag" ] && echo цела || echo неполна)
if [ "$_ghost_bk" = "пропущен" ] && [ "$_ghost_tree" = "нет" ] \
   && [ "$_pair" = "цела" ] && [ "$r" = "ПРОПУСК:1" ]; then
    ok "осиротевший .raw.etag не взят в бэкап и не воскрес в дереве, а полная пара доехала"
else
    no "осиротевший .raw.etag не переносится" "в бэкапе=пропущен, в дереве=нет, пара=цела, ПРОПУСК:1" \
       "в бэкапе=$_ghost_bk, в дереве=$_ghost_tree, пара=$_pair, $r"
fi


# ============================================================================
# 12. Метёлка временных файлов: все четыре суффикса, со счётом и отчётом
# ============================================================================
#
# Живёт она в том же step_build_zapret2 и в той же его части «до mv дерева»,
# что и бэкап игровых списков выше, — потому и пинится здесь.
#
# Суффиксов четыре, и раньше убирался ровно один: .carry.<pid> — полная копия
# geosite-цели (1,2 МБ у ru-blocked, ~24 МБ у ru-blocked-all) от прерванного
# переноса; .probe — проба записи из z2k-geosite.sh; .new.<pid> и .hdr.<pid> —
# тело и заголовки от оборванного условного запроса (lib/utils.sh,
# files/z2k-update-lists.sh пишут их РЯДОМ С ЦЕЛЬЮ, то есть и в games/ тоже).
# Каждый обрыв оставляет свой хвост, а типичная причина обрыва — нехватка
# места: круг замыкается, следующая попытка падает вероятнее предыдущей.
#
# Метёлка не заканчивается на `fi` (это while с here-doc), поэтому общий
# z2k_extract_block сюда не подходит: берём от первой строки до строки отчёта
# включительно.
awk -v s='local _junk _jfreed=0' -v e='Убрано временных файлов' '
    index($0, s) > 0 { inb = 1 }
    inb { print }
    inb && index($0, e) > 0 { exit }
' "$SRC" > "$TMP/junk.sh"
if [ -s "$TMP/junk.sh" ] && grep -q 'carry' "$TMP/junk.sh" && grep -q 'TMPJUNK' "$TMP/junk.sh"; then
    ok "блок метёлки временных файлов извлечён из install.sh"
else
    no "блок метёлки извлечён" "непустой блок с here-doc" "пусто"
fi

sweep() {  # sweep <класть ли мусор: 1/0> → "<лог>|<что осталось>"
    rm -rf "$TMP/j"; mkdir -p "$TMP/j/extra_strats/TCP/RKN" \
                              "$TMP/j/extra_strats/cache/geosite-etag" \
                              "$TMP/j/lists/warp/games"
    # рабочие файлы — их трогать нельзя
    printf 'upstream.example.com\n' > "$TMP/j/extra_strats/TCP/RKN/List.txt"
    printf 'ru-blocked.txt\n'       > "$TMP/j/extra_strats/TCP/RKN/List.txt.asset"
    printf '"etag"\n'               > "$TMP/j/extra_strats/cache/geosite-etag/ru-blocked.txt.etag"
    printf 'steam.example.com\n'    > "$TMP/j/lists/warp/games/Steam.txt"
    printf 'steam.example.com\n'    > "$TMP/j/lists/warp/games/.Steam.raw"
    if [ "$1" = "1" ]; then
        # по одному хвосту на каждый суффикс, имена ровно как их пишет боевой код
        printf 'x\n' > "$TMP/j/extra_strats/TCP/RKN/List.txt.carry.4242"
        printf 'x\n' > "$TMP/j/extra_strats/TCP/RKN/List.txt.probe"
        printf 'x\n' > "$TMP/j/lists/warp/games/.Steam.raw.new.4242"
        printf 'x\n' > "$TMP/j/lists/warp/games/.Steam.raw.hdr.4242"
    fi
    env -i PATH="$Z2K_TEST_PATH" HOME="$TMP" TMPDIR="$TMP" SB="$TMP" "$Z2K_TEST_SH" -c '
        ZAPRET2_DIR="$SB/j"
        print_info() { printf "%s\n" "$1"; }
        _sweep() { . "$SB/junk.sh"; }
        _sweep
    ' 2>/dev/null | tr '\n' ' '
    printf '|'
    # LC_ALL=C: порядок сортировки не должен зависеть от локали машины.
    find "$TMP/j" -type f 2>/dev/null | sed "s|$TMP/j/||" | LC_ALL=C sort | tr '\n' ' '
}

_sw=$(sweep 1)
_left=${_sw#*|}
case "$_sw" in
    *"Убрано временных файлов от прерванных прогонов: 4"*)
        ok "метёлка убрала все четыре суффикса и сказала сколько (4)" ;;
    *)  no "метёлка убирает все четыре суффикса и считает их" \
           "отчёт «Убрано ...: 4»" "${_sw%%|*}" ;;
esac
_expected='extra_strats/TCP/RKN/List.txt extra_strats/TCP/RKN/List.txt.asset extra_strats/cache/geosite-etag/ru-blocked.txt.etag lists/warp/games/.Steam.raw lists/warp/games/Steam.txt '
if [ "$_left" = "$_expected" ]; then
    ok "рабочие файлы метёлка не тронула (списки, кеш .raw, ETag, маркер происхождения)"
else
    no "рабочие файлы не тронуты" "$_expected" "$_left"
fi

# Мусора нет — молчим. Иначе установка на каждом запуске рапортовала бы о нуле.
_sw0=$(sweep 0)
case "${_sw0%%|*}" in
    *"Убрано временных файлов"*)
        no "без мусора метёлка молчит" "пустой вывод" "${_sw0%%|*}" ;;
    *)  ok "без мусора метёлка молчит — про ноль убранного не рапортует" ;;
esac


printf '\n%s: PASS=%s FAIL=%s\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
