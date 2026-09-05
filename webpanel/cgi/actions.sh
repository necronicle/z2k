#!/bin/sh
# z2k webpanel — action handlers.
# Each function mirrors exactly what the corresponding menu_* function in
# lib/menu.sh does, minus the interactive printf/read/pause layer.
# Sourced from api.sh. All functions return 0 on success, non-zero on error
# and write a single-line error to stderr (captured by the caller into JSON).

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_DIR="${CONFIG_DIR:-/opt/etc/zapret2}"
LISTS_DIR="${LISTS_DIR:-$ZAPRET2_DIR/lists}"
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"
WHITELIST_FILE="${WHITELIST_FILE:-$LISTS_DIR/whitelist.txt}"
EXTRA_DOMAINS_FILE="${EXTRA_DOMAINS_FILE:-$LISTS_DIR/extra-domains.txt}"
WARP_SCRIPT="${WARP_SCRIPT:-$ZAPRET2_DIR/z2k-warp.sh}"
WARP_LISTS_DIR="${WARP_LISTS_DIR:-$LISTS_DIR/warp}"
# Списки в $WARP_LISTS_DIR — целиком пользовательские, их не трогает никто, кроме
# панели. Автоматически обновляются только per-game списки в подкаталоге games/
# (z2k-update-lists.sh перезаписывает их целиком), и панель в них не пишет вовсе —
# выбор хранится именами в .enabled. Никакого 3-way-merge, baseline'ов (.<name>.base)
# и tombstone'ов (.<name>.removed) в дереве нет: они существовали для сводного
# game-warp-ips.txt, который снят, а его остатки разово подчищает
# files/z2k-warp.sh (warp_lists_migrate).

# --- read helpers (POSIX sh, no sourcing of lib/utils.sh required) ---

read_flag() {
    # read_flag <key> <file> [default]
    local key="$1" file="$2" def="${3:-0}"
    [ -f "$file" ] || { printf '%s' "$def"; return 0; }
    local raw val
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -1)
    if [ -z "$raw" ]; then
        printf '%s' "$def"
        return 0
    fi
    # Кавычки снимаем оба вида: генератор пишет значение в двойных
    # (config_official.sh), set_flag — в одинарных. Разворачивать shell-эскейп
    # апострофа ('\'') здесь НЕЛЬЗЯ: safe_config_read из lib/utils.sh его тоже не
    # разворачивает, и панель показывала бы не то имя политики, с которым реально
    # работает сервис.
    val=$(printf '%s' "$raw" | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//')
    # An empty value (e.g. `DROP_DPI_RST=` with nothing after the equals)
    # must fall back to the default, not propagate as "" — otherwise the
    # caller's printf emits `"key":,` which breaks JSON. Caught in the wild
    # on Владислав's router 2026-04-15 after a reinstall left DROP_DPI_RST
    # with no value.
    [ -z "$val" ] && val="$def"
    printf '%s' "$val"
}

# set_flag живёт в lib/utils.sh — там же, где его видит и меню.
# Здесь оставлен только запасной вариант на случай, когда utils.sh не
# подгрузился (_gen_libs_source ищет его в двух местах и может не найти):
# CGI не должен падать целиком из-за отсутствия одной библиотеки.
if ! command -v set_flag >/dev/null 2>&1; then
set_flag() {
    # set_flag <key> <value> <file>
    local key="$1" val="$2" file="$3"
    [ -f "$file" ] || { echo "file not found: $file" >&2; return 1; }
    # Конфиг ИСПОЛНЯЕТСЯ как скрипт (files/S99zapret2.new: `. "$ZAPRET_CONFIG"`),
    # поэтому голое POLICY_NAME=Через ВПН уводит второе слово на исполнение как
    # команду. Всё, что не является голым безопасным словом, пишем в ОДИНАРНЫХ
    # кавычках: двойные оставили бы работающими $ и обратную кавычку. Внутренний
    # апостроф закрывается и вставляется отдельно ('\''), как это делает shell.
    #
    # Значения из [A-Za-z0-9_.-] (то есть все флаги 0/1) остаются голыми
    # намеренно: ровно так их пишет генератор (lib/config_official.sh), и на этот
    # вид завязаны проверки вида `grep -q "^ENABLED=1"` в files/000-zapret2.sh и
    # z2k-nfqueue-selfheal.sh. Один ключ не должен выглядеть в конфиге
    # по-разному в зависимости от того, кто его последним трогал.
    local _val _esc
    case "$val" in
        ''|*[!A-Za-z0-9_.-]*) _val="'$(printf '%s' "$val" | sed "s/'/'\\\\''/g")'" ;;
        *) _val="$val" ;;
    esac
    # Второй слой — для sed: разделитель здесь слэш, & в замене означает «весь
    # совпавший текст», а обратный слэш мог прийти из экранирования апострофа.
    _esc=$(printf '%s' "$_val" | sed 's/[&/\\]/\\&/g')
    if grep -q "^${key}=" "$file"; then
        sed -i "s/^${key}=.*/${key}=${_esc}/" "$file"
    else
        printf '%s=%s\n' "$key" "$_val" >> "$file"
    fi
}
fi

# --- запись в файлы-списки -------------------------------------------------
#
# Общая часть для whitelist / extra-domains / nozapret / state.tsv. mod_cgi
# выполняет запросы ПАРАЛЛЕЛЬНО, поэтому имя временного файла обязано быть
# уникальным: две вкладки панели делили один "$file.z2k-new", и запись одной
# уезжала в файл другой.

# Сериализация правок одного списка.
#
# Это не про «много пользователей» — пользователь один. Кнопки удаления в панели
# не блокируются на время запроса, поэтому два быстрых клика подряд (обычная
# чистка списка) уходят двумя запросами, а lighttpd выполняет CGI ПАРАЛЛЕЛЬНО.
# Оба процесса читают файл целиком, и второй mv затирает результат первого:
# запись показывает «Удалено», а после перезагрузки страницы возвращается.
# Проверено на роутере — теряется 5 раз из 5, то есть это не редкая гонка.
#
# flock на Entware нет, дробного sleep в busybox тоже. Каталог — атомарный
# примитив на любой ФС, паузы даёт usleep (он есть); без него деградируем на
# посекундный sleep.
_list_lock() {
    local d="$1.z2k-lock" n=0
    while ! mkdir "$d" 2>/dev/null; do
        # Держатель мог уйти вместе с убитым CGI. Лок старше минуты — битый:
        # любая наша критическая секция это единицы миллисекунд.
        if [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$d" 2>/dev/null
            continue
        fi
        n=$((n + 1))
        [ "$n" -gt 100 ] && return 1
        usleep 20000 2>/dev/null || sleep 1
    done
    return 0
}

_list_unlock() { rmdir "$1.z2k-lock" 2>/dev/null; return 0; }

# --- замок state.tsv, общий с Lua ------------------------------------------
#
# У state.tsv ДВА писателя: демон (files/lua/z2k-state-persist.lua) и вот эта
# панель. Замок был только у демона, и панель его не брала вовсе — то есть он
# охранял писателя, которого не существует (демон один и сам с собой не
# гоняется), и не охранял реального.
#
# Цена проигранной гонки — не порча файла (обе стороны пишут через атомарную
# подмену), а ПОТЕРЯ НАМЕРЕНИЯ оператора: заморозка, пин или удаление строки,
# сделанные из панели между «демон прочитал диск» и «демон переименовал свой
# временный файл», затираются его снимком из памяти. Человек видит, что кнопка
# сработала, а через секунду всё как было.
#
# Протокол ровно тот же, что в Lua, иначе взаимного исключения не выйдет:
#   • файл "<path>.lock", содержимое — unix-время захвата;
#   • пустой или нечисловой = ничей (процесс умер между созданием и записью);
#   • старше 10 секунд = протухший, забираем;
#   • метка из будущего = часы уехали, забираем.
# `set -C` даёт атомарное создание (O_EXCL) без flock, которого на Entware нет.
_state_lock() {
    local f="$1.lock" n=0 now content lt
    while :; do
        now=$(date +%s 2>/dev/null || echo 0)
        if [ -f "$f" ]; then
            content=$(cat "$f" 2>/dev/null | tr -d ' \t\r\n')
            lt=$(printf '%s' "$content" | grep -E '^[0-9]+$' || true)
            if [ -z "$lt" ]; then
                rm -f "$f" 2>/dev/null            # ничей
            elif [ "$lt" -gt "$((now + 10))" ] 2>/dev/null; then
                rm -f "$f" 2>/dev/null            # из будущего
            elif [ "$((now - lt))" -gt 10 ] 2>/dev/null; then
                rm -f "$f" 2>/dev/null            # протух
            fi
        fi
        if ( set -C; printf '%s' "$now" > "$f" ) 2>/dev/null; then
            return 0
        fi
        n=$((n + 1))
        [ "$n" -gt 100 ] && return 1
        usleep 20000 2>/dev/null || sleep 1
    done
}

_state_unlock() { rm -f "$1.lock" 2>/dev/null; return 0; }

_file_replace() {
    # _file_replace <dest> <tmp> — подменить содержимое уже заполненным temp'ом.
    # Прежний `cat "$tmp" > "$dest"` СНАЧАЛА обнуляет цель: обрыв питания, ENOSPC
    # или гонка на середине оставляли пустой список (для state.tsv — стёртый
    # стейт ротатора вместе с заморозками). mv в пределах одной ФС атомарен, но
    # уносит inode ВМЕСТЕ с правами и владельцем, поэтому и то и другое снимаем
    # с цели и переносим на temp ДО подмены.
    #
    # Владелец здесь не формальность: state.tsv принадлежит nobody:nobody
    # (S99zapret2 делает chown, потому что lua внутри nfqws2 работает под
    # --user=nobody). Одна правка из панели, выполняемой от root, — и файл
    # становится root-owned, а демон теряет право записи в собственный стейт.
    local dest="$1" tmp="$2" meta mode owner
    # busybox: ни stat -c, ни chmod --reference; режим восстанавливаем из
    # символьного вида ls, владельца берём в числовом (-n) — на роутере у uid
    # 65534 имени может не быть вовсе.
    meta=$(ls -ldn "$dest" 2>/dev/null | awk '
        {
            p = substr($1, 2, 9); m = 0; c = ""
            if (substr(p, 1, 1) == "r") m += 400
            if (substr(p, 2, 1) == "w") m += 200
            c = substr(p, 3, 1)
            if (c == "x" || c == "s") m += 100
            if (c == "s" || c == "S") m += 4000
            if (substr(p, 4, 1) == "r") m += 40
            if (substr(p, 5, 1) == "w") m += 20
            c = substr(p, 6, 1)
            if (c == "x" || c == "s") m += 10
            if (c == "s" || c == "S") m += 2000
            if (substr(p, 7, 1) == "r") m += 4
            if (substr(p, 8, 1) == "w") m += 2
            c = substr(p, 9, 1)
            if (c == "x" || c == "t") m += 1
            if (c == "t" || c == "T") m += 1000
            printf "%d %s:%s\n", m, $3, $4
            exit
        }')
    if [ -n "$meta" ]; then
        mode=${meta%% *}; owner=${meta#* }
        # chown ДО chmod: смена владельца сбрасывает setuid/setgid.
        chown "$owner" "$tmp" 2>/dev/null
        chmod "$mode" "$tmp" 2>/dev/null
    else
        chmod 644 "$tmp" 2>/dev/null
    fi
    mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

_list_remove_line() {
    # _list_remove_line <file> <entry> — выкинуть строку целиком.
    # grep возвращает 1, когда не осталось НИ ОДНОЙ строки — это пустой
    # результат, а не ошибка: на списке из одной записи прежний код уходил в
    # return 1, и удалить её было нельзя вообще. Настоящая ошибка чтения — это
    # код >1, её по-прежнему не глотаем.
    local file="$1" entry="$2" tmp="$1.z2k-new.$$" rc
    grep -vxF "$entry" "$file" > "$tmp"; rc=$?
    [ "$rc" -le 1 ] || { rm -f "$tmp"; return 1; }
    _file_replace "$file" "$tmp"
}

_list_end_nl() {
    # _list_end_nl <file> — дописать перевод строки, если файл им не кончается.
    # Файл могли править руками или подложить снаружи; без этого новая запись
    # приклеивается к последней (old.combar.com), и обе перестают находиться
    # и дедупом grep -qxF, и удалением.
    [ -s "$1" ] || return 0
    [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] && printf '\n' >> "$1"
    return 0
}

_str_len_chars() {
    # _str_len_chars <строка> — длина в СИМВОЛАХ, а не в байтах.
    # ${#var} на ash считает байты, awk на роутере тоже байто-ориентированный
    # (length("привет") == 12), поэтому считаем сами: выбрасываем продолжающие
    # байты UTF-8 (10xxxxxx) — остаётся ровно по одному байту на символ.
    # LC_ALL=C обязателен: в UTF-8-локали диапазон \200-\277 у GNU tr означает
    # символы, а не байты, и не совпадёт ни с чем.
    local s
    s=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' 2>/dev/null)
    # tr нет или он поперхнулся — считаем байты, как раньше: лучше более строгий
    # лимит, чем пропуск строки любой длины.
    [ -z "$s" ] && [ -n "$1" ] && s="$1"
    printf '%s' "${#s}"
}

is_installed() {
    [ -d "$ZAPRET2_DIR" ] && [ -x "$ZAPRET2_DIR/nfq2/nfqws2" ]
}

is_running() {
    # Матчим по отличительной части cmdline демона, как tunnel_pid: голое
    # `pgrep -f nfqws2` ловит и процесс проверки стратегии ("$engine" --dry-run),
    # который панель порождает сама в strategy_validate, — и параллельный опрос
    # /status во время проверки рапортовал running:true на остановленном роутере,
    # а restart_service_if_running в этом окне уходил в ветку рестарта.
    # --fwmark добавляет только init-скрипт (NFQWS2_OPT_BASE в S99zapret2.new),
    # в NFQWS2_OPT из конфига его нет, поэтому под dry-run он не попадает.
    pgrep -f "nfqws2 .*--fwmark=" >/dev/null 2>&1
}

service_status_string() {
    if is_running; then
        echo "active"
    elif is_installed; then
        echo "stopped"
    else
        echo "not_installed"
    fi
}

# Source BOTH utils.sh (for safe_config_read and helpers) and
# config_official.sh (for create_official_config). Without utils.sh,
# safe_config_read is undefined → every saved_* variable becomes "" →
# the heredoc emits empty-value flags → toggle never sticks. This was
# the root cause of the game-mode toggle bug (2026-04-16).
#
# Ручного спасения путей вокруг сорсинга здесь БОЛЬШЕ НЕТ. Оно было нужно, пока
# lib/utils.sh присваивал ZAPRET2_DIR/CONFIG_DIR/LISTS_DIR/INIT_SCRIPT
# безусловно: env-override, честно принятый в шапке этого файла, терялся при
# первой же перегенерации, а CONFIG_FILE/WHITELIST_FILE/STATE_FILE оставались
# от прежних значений — внутри одного запроса набор путей оказывался наполовину
# переключённым. Причина устранена в самом utils.sh (присваивание стало
# условным, ${VAR:-умолчание}), и лечить симптом здесь больше незачем.
_gen_libs_source() {
    local utils="" lib=""
    for d in "$ZAPRET2_DIR/lib" /tmp/z2k/lib; do
        [ -f "$d/utils.sh" ] && [ -z "$utils" ] && utils="$d/utils.sh"
        [ -f "$d/config_official.sh" ] && [ -z "$lib" ] && lib="$d/config_official.sh"
    done
    [ -z "$lib" ] && return 1
    # shellcheck disable=SC1090
    [ -n "$utils" ] && . "$utils"
    # shellcheck disable=SC1090
    . "$lib"
    return 0
}

regenerate_config() {
    _gen_libs_source || { echo "config_official.sh not found" >&2; return 1; }
    create_official_config "$CONFIG_FILE" >/dev/null 2>&1
    return $?
}

# ---- custom per-pool strategies -------------------------------------------
# User-owned, unlike shipped Strategy.txt (whose edits an update wipes by
# design). Read by the generator on EVERY regeneration, so they survive toggles,
# reinstalls and auto-updates.
STRATEGY_POOLS="rkn_tcp yt_tcp gv_tcp yt_quic discord_udp"
CUSTOM_STRAT_DIR="${CUSTOM_STRAT_DIR:-$ZAPRET2_DIR/lists/custom-strategies}"

strategy_pool_ok() {
    for _p in $STRATEGY_POOLS; do [ "$1" = "$_p" ] && return 0; done
    return 1
}

# _strategy_pool_source <пул> — поставляемый файл стратегий этого пула.
# Те же пути, что читает генератор конфига (lib/config_official.sh).
_strategy_pool_source() {
    case "$1" in
        rkn_tcp) printf '%s\n' "$ZAPRET2_DIR/extra_strats/TCP/RKN/Strategy.txt" ;;
        yt_tcp)  printf '%s\n' "$ZAPRET2_DIR/extra_strats/TCP/YT/Strategy.txt" ;;
        gv_tcp)  printf '%s\n' "$ZAPRET2_DIR/extra_strats/TCP/YT_GV/Strategy.txt" ;;
        yt_quic) printf '%s\n' "$ZAPRET2_DIR/extra_strats/UDP/YT/Strategy.txt" ;;
        # У голосового пула шипованного файла НЕТ: его строка живёт прямо в
        # генераторе (lib/config_official.sh, discord_udp). Дублировать её сюда
        # нельзя — две копии длинной строки разъедутся на первом же изменении,
        # и панель начнёт достраивать каркасом от прошлой версии. Поэтому
        # каркас берётся из СГЕНЕРИРОВАННОГО конфига, где лежит ровно то, что
        # сейчас работает; см. _strategy_pool_skeleton_from_config.
        discord_udp) return 1 ;;
        *) return 1 ;;
    esac
}

# _strategy_pool_skeleton_from_config <ключ> — вытащить строку профиля из
# работающего конфига по ключу ротатора.
#
# Нужно пулам без шипованного файла. Читаем то, что реально запущено, поэтому
# каркас не может отстать от генератора.
_strategy_pool_skeleton_from_config() {
    [ -s "$CONFIG_FILE" ] || return 1
    awk -v key="key=$1" '
        index($0, key) { print; found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$CONFIG_FILE"
}

# strategy_complete_line <пул> — читает строку со stdin и печатает готовую.
#
# ЗАЧЕМ. Подбор по домену выдаёт ОДИН приём:
#   --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=1
# а движку нужен полный набор опций профиля: фильтры портов и уровня, полезная
# нагрузка, окно и токен circular С КЛЮЧОМ ПУЛА (у РКН key=rkn_tcp, у ютуба
# yt_tcp). Человек вставлял то, что дал инструмент, и получал «не удалось
# собрать конфиг» — формат был виноват, а выглядело как поломка.
#
# Достраиваем каркасом ТОГО ПУЛА, куда вставляют: берём поставляемую строку и
# отрезаем её по первому приёму, оставляя всё до него включительно с circular.
# Ключ пула таким образом всегда правильный — он приезжает из каркаса, а не
# угадывается.
#
# Не трогаем строку, если в ней уже есть --filter-: значит человек принёс полный
# набор и знает, что делает. И не трогаем, если приёма нет вовсе — пусть
# валидатор скажет своё, молча дописывать каркас к мусору незачем.
# _strategy_tag_arms — читает строку со stdin и печатает её же, проставив
# приёмам номер strategy=1, если в строке есть ротатор circular, а номеров нет
# ни у одного приёма.
#
# Ротатор выбирает приём ПО НОМЕРУ. Приёмы без номера не принадлежат ни одному
# плечу, и ротатор не применяет НИЧЕГО: строка синтаксически верна, движок
# молчит, обхода нет. Инструмент подбора отдаёт приёмы без номеров — ему номера
# не нужны, он их применяет сам, — поэтому склейка обязана их проставить.
#
# Поле 2026-09-01, bdsmx.tube: приём, подобранный инструментом, открывал сайт
# (200, 75624 байта, 3 из 3), та же строка под ротатором без номеров давала RST
# на ClientHello (0 из 4), она же с :strategy=1 — снова 200 (4 из 4).
_strategy_tag_arms() {
    awk '{
        has_circ = 0; has_num = 0
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^--lua-desync=circular/) { has_circ = 1; continue }
            if ($i ~ /^--lua-desync=/ && $i ~ /:strategy=/) has_num = 1
        }
        if (!has_circ || has_num) { print; next }
        out = ""
        for (i = 1; i <= NF; i++) {
            t = $i
            if (t ~ /^--lua-desync=/ && t !~ /^--lua-desync=circular/) t = t ":strategy=1"
            out = out (out == "" ? "" : " ") t
        }
        print out
    }'
}

strategy_complete_line() {
    local pool="$1" body src skel joined raw
    body=$(cat)

    case "$body" in
        *--filter-*)     printf '%s\n' "$body" | _strategy_tag_arms; return 0 ;;
        *--lua-desync=*) ;;
        *)               printf '%s\n' "$body" | _strategy_tag_arms; return 0 ;;
    esac

    # Каркас берём из ТЕКУЩЕЙ строки пула, если она есть, и только иначе из
    # поставляемой. Иначе своя настройка человека — другие порты, другое окно —
    # молча пропадала бы при каждой вставке нового приёма: он-то менял приём, а
    # получал сброс всего остального к заводскому.
    src="$CUSTOM_STRAT_DIR/$pool.txt"
    if [ ! -s "$src" ]; then
        if ! src=$(_strategy_pool_source "$pool"); then
            # Пул без шипованного файла: каркас берём из работающего конфига.
            raw=$(_strategy_pool_skeleton_from_config "$pool") || {
                printf '%s\n' "$body" | _strategy_tag_arms; return 0; }
            # Временный файл вместо trap RETURN: тот в POSIX sh не определён,
            # а на BusyBox ash ведёт себя непредсказуемо. Удаляем явно ниже, на
            # каждом выходе из функции.
            src="/tmp/z2k-skel.$$"
            printf '%s\n' "$raw" > "$src"
        fi
    fi
    [ -s "$src" ] || { rm -f "/tmp/z2k-skel.$$"; printf '%s\n' "$body" | _strategy_tag_arms; return 0; }

    # Каркас: всё до ПЕРВОГО приёма. circular остаётся, он часть каркаса.
    skel=$(awk '{ sub(/\r$/,""); sub(/^[[:space:]]*#.*$/,"") } NF { printf "%s ", $0 }' "$src" \
        | awk '{ out=""
                 for (i = 1; i <= NF; i++) {
                     if ($i ~ /^--lua-desync=/ && $i !~ /^--lua-desync=circular/) break
                     out = out (out == "" ? "" : " ") $i
                 }
                 print out }')
    case "$skel" in
        *--lua-desync=circular*) ;;
        *) rm -f "/tmp/z2k-skel.$$"; printf '%s\n' "$body" | _strategy_tag_arms; return 0 ;;
    esac

    # Тело человека приводим к одной строке: инструмент отдаёт одну, но из чата
    # приходит и с переносами.
    joined=$(printf '%s\n' "$body" | awk '{ sub(/\r$/,"") } NF { printf "%s ", $0 }' | sed 's/[[:space:]]*$//')
    rm -f "/tmp/z2k-skel.$$"
    printf '%s %s\n' "$skel" "$joined" | _strategy_tag_arms
}

# strategy_validate — the load-bearing part of this feature.
#
# One typo takes down nfqws2 ENTIRELY, not just the pool it was written for:
# the daemon parses all profiles as one option string and refuses to start if
# any of it is wrong. So a candidate is never applied on trust.
#
# Validation runs against the WHOLE generated option string with the candidate
# in place, not against the fragment alone — a line can be fine by itself and
# still break the result (duplicate separators, a filter that swallows the next
# profile). The engine's own --dry-run is the oracle: rc 0 = parses, rc 1 = does
# not. Verified on hardware, including that a bad --lua-desync name fails it.
#
# Живой $CUSTOM_STRAT_DIR/<pool>.txt не пишется НИ РАЗУ: генерация идёт в
# теневом дереве (_strategy_shadow_build). Класть кандидата в боевой файл «на
# время проверки» нельзя — убитый между записью и откатом CGI оставлял битую
# строку живой, параллельный toggle успевал запечь её в NFQWS2_OPT, а два
# одновременных validate одного пула снимали кандидата друг друга как «прежнее
# состояние», и откат уезжал навсегда.
#
# stdin: candidate text. $1: pool. Echoes the engine's complaint on failure.
# Символы, которые превращают строку стратегии в команду.
#
# ПРОВЕРЕНО ЭКСПЕРИМЕНТОМ 2026-08-08, это не теория. Тело пула попадает в конфиг
# как  NFQWS2_OPT="<тело>"  (config_official.sh), а конфиг сорсится root-овым
# init-скриптом. Одна кавычка внутри тела закрывает присваивание, и всё, что за
# ней, исполняется:
#
#     --dpi-desync=fake " ; touch /tmp/PWNED ; : "
#
# даёт в конфиге строку, после сорсинга которой файл /tmp/PWNED создан. Обратите
# внимание: отдельная строка из кавычки не нужна — z2k_custom_strategy склеивает
# тело в ОДНУ строку, и кавычка работает из середины.
#
# Внутри двойных кавычек шелл раскрывает ещё обратные кавычки и $(...), поэтому
# запрещены и они. Отказ, а не экранирование: у этих символов нет законного
# применения в опциях nfqws2, а экранирование пришлось бы держать в согласии с
# генератором конфига вечно.
#
# Полагаться на строгость `nfqws2 --dry-run` здесь нельзя: чужой парсер не может
# быть границей безопасности, и достаточно одной опции, принимающей произвольную
# строку, чтобы проверка перестала ловить.
_strategy_body_is_safe() {
    # LC_ALL=C — иначе классы символов зависят от локали.
    if LC_ALL=C grep -q '["`$]' "$1" 2>/dev/null; then
        return 1
    fi
    # Управляющие байты (в т.ч. \0 и перевод строки в неожиданных местах)
    if LC_ALL=C grep -q '[[:cntrl:]]' "$1" 2>/dev/null; then
        return 1
    fi
    return 0
}

strategy_validate() {
    local pool="$1"
    strategy_pool_ok "$pool" || { echo "unknown pool"; return 1; }

    local engine="$ZAPRET2_DIR/nfq2/nfqws2"
    [ -x "$engine" ] || { echo "движок не найден: $engine"; return 1; }

    local shadow="/tmp/z2k-strat-shadow.$$"
    # Своя тень (PID мог быть переиспользован) — и заодно чужие, брошенные
    # убитым CGI: проверка стратегии задачу не заводит, и без этого вызова
    # осиротевшие тени не подчистил бы никто.
    rm -rf "$shadow" 2>/dev/null
    _tmp_reap_orphans
    _strategy_shadow_build "$shadow" "$pool" || {
        rm -rf "$shadow" 2>/dev/null
        echo "не удалось подготовить каталог для проверки"
        return 1
    }

    local cand="$shadow/lists/custom-strategies/$pool.txt"
    # Достраиваем ЗДЕСЬ, а не у вызывающего: проверка и сохранение обязаны
    # видеть одну и ту же строку, иначе «Проверить» скажет одно, а применится
    # другое.
    strategy_complete_line "$pool" > "$cand" || {
        rm -rf "$shadow" 2>/dev/null
        echo "не удалось записать кандидата"
        return 1
    }

    # Опасные символы отсекаем ПЕРВЫМИ — до генерации конфига и до dry-run.
    # Дальше по цепочке тело попадает в NFQWS2_OPT="…", который сорсится root'ом,
    # и там кавычка уже не текст, а конец присваивания.
    if ! _strategy_body_is_safe "$cand"; then
        rm -rf "$shadow" 2>/dev/null
        echo 'в строке стратегии недопустимы символы " ` $ и управляющие: они превращают её в команду'
        return 1
    fi

    # Строка без единой опции (пусто или одни комментарии) — не «прошедшая
    # проверку стратегия»: генератор такой файл пропускает и собирает конфиг из
    # штатной Strategy.txt, dry-run одобряет ЕЁ, а человек получает карточку
    # «своя стратегия» поверх работающей штатной с ротацией.
    if ! _strategy_body_has_options "$cand"; then
        rm -rf "$shadow" 2>/dev/null
        echo "пустая стратегия: нет ни одной строки с опциями (комментарии не в счёт)"
        return 1
    fi

    local tmpcfg="/tmp/z2k-strategy-check.$$"
    local rc=0 opt="" err=""
    if ( ZAPRET2_DIR="$shadow"; export ZAPRET2_DIR; regenerate_config_to "$tmpcfg" ); then
        opt=$(sed -n '/^NFQWS2_OPT="/,/^"$/{ /^NFQWS2_OPT="/d; /^"$/d; p; }' "$tmpcfg")
    else
        rc=1; err="не удалось собрать конфиг с этой строкой"
    fi

    if [ "$rc" = 0 ]; then
        if [ -z "$opt" ]; then
            rc=1; err="в собранном конфиге пустые опции nfqws2"
        else
            # --qnum ОБЯЗАТЕЛЕН, и его нет в NFQWS2_OPT: номер очереди
            # подставляет init при запуске, а в конфиг он не пишется. Без него
            # движок отвечает «Need queue number» на ЛЮБУЮ строку — то есть
            # проверка отвергала и заведомо исправные, включая поставляемые
            # пуловые (проверено на роутере 31.08.2026). Номер здесь любой:
            # при --dry-run движок разбирает опции и ничего не занимает.
            # shellcheck disable=SC2086
            err=$("$engine" --dry-run --qnum=200 $opt 2>&1) || rc=1
        fi
    fi

    rm -f "$tmpcfg"
    rm -rf "$shadow" 2>/dev/null

    [ "$rc" = 0 ] || { printf '%s\n' "$err" | tail -3; return 1; }
    return 0
}

# Теневая копия $ZAPRET2_DIR для проверки кандидата: верхний уровень —
# симлинки на всё, кроме lists; вместо lists настоящий каталог с симлинками на
# всё, кроме custom-strategies; вместо custom-strategies настоящий каталог с
# симлинками на чужие пулы. Проверяемый пул кладёт уже вызывающий — реальным
# файлом, поверх которого ничего не симлинчено.
#
# Подсунуть генератору пустой каталог НЕЛЬЗЯ: lib/config_official.sh берёт из
# ZAPRET2_DIR не только custom-strategies, но и config (флаги), extra_strats и
# lists — на пустом дереве проверялась бы не та строка опций, что соберётся в бою.
# Симлинк не создался — честный отказ; тихо вернуться к записи в живой файл
# значит вернуть ровно тот баг, ради которого всё это и сделано.
_strategy_shadow_build() {
    local root="$1" pool="$2" f base
    mkdir -p "$root/lists/custom-strategies" 2>/dev/null || return 1
    for f in "$ZAPRET2_DIR"/* "$ZAPRET2_DIR"/.[!.]*; do
        [ -e "$f" ] || continue
        base=${f##*/}
        [ "$base" = "lists" ] && continue
        ln -s "$f" "$root/$base" 2>/dev/null || return 1
    done
    for f in "$ZAPRET2_DIR/lists"/* "$ZAPRET2_DIR/lists"/.[!.]*; do
        [ -e "$f" ] || continue
        base=${f##*/}
        [ "$base" = "custom-strategies" ] && continue
        ln -s "$f" "$root/lists/$base" 2>/dev/null || return 1
    done
    for f in "$CUSTOM_STRAT_DIR"/*.txt; do
        [ -f "$f" ] || continue
        base=${f##*/}
        [ "$base" = "$pool.txt" ] && continue
        ln -s "$f" "$root/lists/custom-strategies/$base" 2>/dev/null || return 1
    done
    return 0
}

# Есть ли в файле хоть одна строка с опциями. Отбрасываем ровно то же, что
# отбрасывает z2k_custom_strategy в lib/config_official.sh (комментарии и пустые
# строки), иначе «проверка прошла» и «генератор это увидит» разъедутся.
_strategy_body_has_options() {
    awk '{ sub(/\r$/, ""); sub(/^[[:space:]]*#.*$/, "") } NF { found = 1; exit } END { exit (found ? 0 : 1) }' "$1"
}

# Same as regenerate_config but writes somewhere else — used by the check above
# so a candidate is never able to overwrite the config the router is running on.
regenerate_config_to() {
    local dest="$1"
    _gen_libs_source || return 1
    create_official_config "$dest" >/dev/null 2>&1
}

strategy_pool_read() {
    strategy_pool_ok "$1" || return 1
    [ -f "$CUSTOM_STRAT_DIR/$1.txt" ] || return 2
    cat "$CUSTOM_STRAT_DIR/$1.txt"
}

# Save only what validates. A rejected line leaves the previous state exactly as
# it was — silently falling back to the shipped strategy would leave the user
# convinced their own is running.
strategy_pool_save() {
    local pool="$1" body
    strategy_pool_ok "$pool" || { echo "unknown pool" >&2; return 1; }
    body=$(strategy_complete_line "$pool")
    printf '%s\n' "$body" | strategy_validate "$pool" >"/tmp/z2k-strategy-err.$$" 2>&1 || {
        cat "/tmp/z2k-strategy-err.$$" >&2; rm -f "/tmp/z2k-strategy-err.$$"; return 1; }
    rm -f "/tmp/z2k-strategy-err.$$"
    mkdir -p "$CUSTOM_STRAT_DIR" 2>/dev/null || return 1
    printf '%s\n' "$body" > "$CUSTOM_STRAT_DIR/$pool.txt" || return 1
    chmod 644 "$CUSTOM_STRAT_DIR/$pool.txt" 2>/dev/null
    regenerate_config || return 1
    # nfqws2 gets NFQWS2_OPT as argv at startup and never re-reads it, so a
    # regenerated config alone changes nothing that is running. Without this the
    # panel says «применена» while the daemon keeps the previous strategy — the
    # exact «переключил, а не применилось» the toggle handlers were fixed for.
    restart_service_if_running
    return 0
}

strategy_pool_reset() {
    strategy_pool_ok "$1" || { echo "unknown pool" >&2; return 1; }
    rm -f "$CUSTOM_STRAT_DIR/$1.txt" || return 1
    regenerate_config || return 1
    restart_service_if_running
    return 0
}

restart_service_if_running() {
    if is_running; then
        # Output goes to caller's stdout/stderr — svc_action_async
        # tees those into the job log so UI shows live progress.
        ensure_init_exec
        "$INIT_SCRIPT" restart 2>&1 || true
    else
        echo "Сервис не запущен — пропускаю restart"
    fi
}

# --- service control ---
# Output не silenced — caller (svc_action_async) подхватывает stdout/stderr
# и пишет в job-log для UI live-polling'а.

# Self-heal the init script's executable bit before invoking it. p-42 shipped
# S99zapret2 via the patch path, which could drop +x on some BusyBox builds
# ("/opt/etc/init.d/S99zapret2: Permission denied", rc 126) — chmod here so a
# webpanel start/stop/restart recovers even on a router not yet reinstalled.
# Эти три обёртки были мертвы, а /service/start|stop|restart в api.sh дёргал
# "$INIT_SCRIPT" напрямую — то есть ровно на том пути, ради которого писался
# self-heal, chmod не выполнялся, и обещание r-43 не работало. Эндпоинты
# переведены на обёртки; вызывать init-скрипт напрямую отсюда больше не нужно.
ensure_init_exec() { [ -f "$INIT_SCRIPT" ] && chmod +x "$INIT_SCRIPT" 2>/dev/null; return 0; }
svc_start()   { ensure_init_exec; "$INIT_SCRIPT" start   2>&1; }
svc_stop()    { ensure_init_exec; "$INIT_SCRIPT" stop    2>&1; }
svc_restart() { ensure_init_exec; "$INIT_SCRIPT" restart 2>&1; }

# Убрать файлы прошлых задач. Каждый запуск задачи из панели оставляет в /tmp
# три файла (.log, .pid, .exit), и до 2026-08-04 их не удалял никто: на роутере
# владельца накопилось 11 штук от четырёх запусков, два лога по 30 КБ. Само по
# себе немного, но /tmp это tmpfs, то есть ОПЕРАТИВКА, и растёт этот мусор
# только вверх до перезагрузки.
#
# Час, а не «всё кроме текущей»: панель после перезагрузки страницы теряет
# job_id и может запросить лог недавней задачи по прямой ссылке, а обновление
# идёт минуты. Час покрывает это с запасом и при этом не копит.
#
# -mmin и -delete у busybox find на роутере есть (проверено), но на всякий
# случай без -delete есть запасной путь: отсутствие find не должно ронять
# запуск задачи.
job_reap() {
    # Сносим только ЗАВЕРШЁННЫЕ задачи. Прежняя версия удаляла всё старше часа
    # без разбора, включая .pid работающей задачи: job_status тогда отвечает
    # "unknown", поллер панели крутится вечно, глобальный UI-лок не снимается, а
    # модалка «Обновление идёт» всплывает при каждой перезагрузке вкладки —
    # то есть уборка мусора ломала живое обновление. Установка на медленном
    # роутере через час не укладывается запросто.
    #
    # Признак завершения — файл .exit (его пишут оба создателя задач по выходу).
    # Если его нет, проверяем, жив ли процесс: не жив — задача умерла и её тоже
    # можно убрать.
    local f id pid
    for f in /tmp/z2k-job-*.log; do
        [ -f "$f" ] || continue
        id=${f#/tmp/z2k-job-}; id=${id%.log}
        # моложе часа — не трогаем в любом случае
        find "$f" -maxdepth 0 -mmin +60 >/dev/null 2>&1 || continue
        if [ ! -f "/tmp/z2k-job-${id}.exit" ]; then
            pid=$(cat "/tmp/z2k-job-${id}.pid" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                continue    # задача ещё идёт — не трогаем
            fi
        fi
        rm -f "/tmp/z2k-job-${id}.log" "/tmp/z2k-job-${id}.pid" "/tmp/z2k-job-${id}.exit" 2>/dev/null
    done
    _tmp_reap_orphans
    return 0
}

# Осиротевший скретч в /tmp. Свой каталог/файл каждый обработчик сносит сам, но
# CGI, убитый lighttpd'ом на таймауте или ушедший вместе с перезапуском сервера,
# уносит уборку с собой, а очистка «по своему $$» в начале обработчика спасает
# только при совпадении PID. /tmp на роутере — tmpfs, то есть ОПЕРАТИВКА, и
# растёт этот мусор только вверх до перезагрузки (ради этого писался job_reap).
#
# Час — та же мера, что и для задач: заведомо дольше любой проверки стратегии и
# любой проверки обновлений, то есть живое не задеваем.
_tmp_reap_orphans() {
    local f
    for f in /tmp/z2k-strat-shadow.* /tmp/z2k-strategy-check.* /tmp/z2k-strategy-err.* \
             "${AU_MANIFEST_CACHE:-/tmp/z2k-au-manifest.json}".new.*; do
        [ -e "$f" ] || continue
        # Проверять надо ВЫВОД find, а не его код возврата: несовпадение по
        # -mmin это не ошибка, find печатает пустоту и выходит с нулём. На коде
        # возврата уборщик сносил свежие скретчи — в том числе файл, в который
        # соседний обработчик прямо сейчас пишет сообщение об ошибке.
        [ -n "$(find "$f" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue
        rm -rf "$f" 2>/dev/null
    done
    return 0
}

# --- async job launcher ---
#
# Запускает любую shell-команду в фоне с tee всех её stdout/stderr в
# /tmp/z2k-job-<id>.log (тот же путь который job_log endpoint раздаёт).
# Возвращает job_id. Frontend получает id, открывает openJobModal с
# live-polling /job?id=...
#
# Закрытие stdin/stdout/stderr (</dev/null >/dev/null 2>&1 на subshell)
# критично — без этого lighttpd не финализирует HTTP-ответ пока хоть
# один наследник держит fd 1/2. Внутреннее `>> log 2>&1` уже после
# наследования /dev/null заменяет fd на лог.
#
# Использование:
#   job_id=$(svc_action_async "Перезапуск сервиса" "/opt/etc/init.d/S99zapret2 restart")
svc_action_async() {
    job_reap
    local label="$1"; shift
    local cmd="$*"
    local job_id
    job_id=$(date +%s)$$
    local log="/tmp/z2k-job-${job_id}.log"
    (
        printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$label" > "$log"
        printf '─────────────────────────────────────────\n' >> "$log"
        eval "$cmd" >> "$log" 2>&1
        local rc=$?
        printf '─────────────────────────────────────────\n' >> "$log"
        if [ "$rc" = "0" ]; then
            printf '[%s] Готово ✓\n' "$(date '+%H:%M:%S')" >> "$log"
        else
            printf '[%s] Завершено с кодом %s\n' "$(date '+%H:%M:%S')" "$rc" >> "$log"
        fi
        echo "$rc" > "/tmp/z2k-job-${job_id}.exit"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "/tmp/z2k-job-${job_id}.pid"
    printf '%s' "$job_id"
}

# --- toggles ---
#
# Each toggle reads the current flag, sets the new value, optionally regenerates
# NFQWS2_OPT via create_official_config (only for toggles that affect it), and
# restarts the running service. Idempotent — setting the same value twice is a no-op.

# RST-фильтр и Silent fallback РКН сняты 2026-08-17 — оба тумблера удалены
# вместе с механизмами. RST-фильтр вырезал входящий RST до детекторов, на
# которых стоит ротация и автохостлист; silent fallback к тому моменту
# сводился к одному лишнему --payload перед circular и только сужал обзор.

# WARP — игровой режим поверх нашего движка z2k-warpd. Маршрутизация, не
# десинк: никакого regenerate_config / рестарта nfqws2. Движок — z2k-warp.sh.
# Коды enable — контракт: 0 ready; 2 включено, туннель поднимается (флаг
# остаётся, причина — код в статусе, панель переводит его в текст); 1 — нет
# бинаря (флаг откатывается).
toggle_game_warp() {
    local want="$1" rc
    if [ "$want" = "1" ]; then
        sh "$WARP_SCRIPT" enable; rc=$?
        if [ "$rc" = "2" ]; then
            echo "Туннель ещё не поднялся — причина в статусе раздела WARP. Режим оставлен включённым, трафик пока идёт напрямую; движок продолжает попытки в фоне." >&2
            return 0
        fi
        if [ "$rc" != "0" ]; then
            echo "WARP не установлен — нажмите «Установить» в разделе WARP" >&2
            return 1
        fi
    else
        sh "$WARP_SCRIPT" disable
    fi
}

# Установка движка: скачать бинарь под арку, зарегистрировать устройство.
# Ничего не запускает — это делает тумблер. Удаление: всё кроме device.json.
warp_install_action() { sh "$WARP_SCRIPT" install; }
warp_remove_action()  { sh "$WARP_SCRIPT" remove; }

toggle_customd() {
    # Note: 1 = ENABLED, 0 = DISABLED in our API; the config flag is
    # DISABLE_CUSTOM which is the INVERSE. We flip here so the web UI
    # stays consistent with "on = feature active".
    local want="$1"
    if [ "$want" = "0" ]; then
        # DISABLING. The firewall unapply (S99zapret2 stop -> zapret_unapply_firewall
        # -> custom_runner zapret_custom_firewall 0) is what removes the custom.d
        # NFQUEUE rules (qnum 65300/65301). But custom_runner early-returns once
        # DISABLE_CUSTOM=1, so flipping the flag FIRST (then restart) leaves those
        # rules ORPHANED in POSTROUTING — they keep shadowing the main profiles
        # (Discord voice stayed broken even after "disabling"). So: stop while the
        # flag is still 0 (clean teardown of custom daemons + firewall), THEN flip,
        # THEN start.
        ensure_init_exec
        local _running=0
        is_running && _running=1
        [ "$_running" = "1" ] && "$INIT_SCRIPT" stop 2>&1
        set_flag "DISABLE_CUSTOM" "1" "$CONFIG_FILE" || return 1
        [ "$_running" = "1" ] && "$INIT_SCRIPT" start 2>&1
        # Итог тумблера — записанный флаг, а не код init-скрипта. Без этого
        # return на остановленном сервисе AND-list отдавал 1 при УСПЕШНОМ
        # выключении, код уезжал в .exit джоба, и панель откатывала галочку с
        # «Не получилось» поверх записанного DISABLE_CUSTOM=1. Ветка включения
        # ниже тоже не смотрит на код рестарта (restart_service_if_running
        # глушит его сама).
        return 0
    else
        set_flag "DISABLE_CUSTOM" "0" "$CONFIG_FILE" || return 1
        restart_service_if_running
    fi
}

toggle_dynamic_ttl() {
    # Z2K_DYNAMIC_TTL — feature flag for NDM TTL bypass injection in
    # NFQWS2_OPT. Mobile operators (МТС/Билайн) detect tethering via TTL
    # decrement; we counter-inject a fresh TTL. Some users with explicit
    # NDM TTL-fix turn it off (Z2K_DYNAMIC_TTL=0). Default = 1.
    local want="$1"
    set_flag "Z2K_DYNAMIC_TTL" "$want" "$CONFIG_FILE" || return 1
    regenerate_config
    restart_service_if_running
}

toggle_stats() {
    # Z2K_STATS — anonymized strategy telemetry to the project VPS (default 1).
    # Out-of-band: it does NOT affect NFQWS2_OPT and is read fresh by
    # z2k-stats-upload.sh each daily run, so neither a config regen nor a
    # service restart is needed — just flip the flag.
    local want="$1"
    set_flag "Z2K_STATS" "$want" "$CONFIG_FILE" || return 1
}

toggle_auto_update() {
    # Z2K_AUTO_UPDATE_ENABLED — nightly unattended update (default 1).
    # Out-of-band like toggle_stats: it does not touch NFQWS2_OPT and is read
    # fresh by z2k-auto-update.sh on each run, so no config regen and no service
    # restart. Turning it off does NOT block the "Обновить" button — that path
    # marks itself manual, so a user who opts out of automatic updates can still
    # update deliberately.
    local want="$1"
    set_flag "Z2K_AUTO_UPDATE_ENABLED" "$want" "$CONFIG_FILE" || return 1
}

toggle_autohostlist() {
    # Z2K_AUTOHOSTLIST — switches MODE_FILTER between hostlist and autohostlist
    # (see lib/config_official.sh). Unlike toggle_stats this is NOT out-of-band:
    # the mode is baked into the generated config, so the config must be
    # regenerated and the service restarted for it to mean anything.
    local want="$1"
    set_flag "Z2K_AUTOHOSTLIST" "$want" "$CONFIG_FILE" || return 1
    regenerate_config || return 1
    # The comment above says "and the service restarted" — and for a release the
    # code did not do it. Regenerating alone writes MODE_FILTER into the config
    # while the daemon keeps running with the old one, which is exactly the
    # "flipped it and nothing happened" the user reports, made worse by the UI
    # showing a restart that never occurred.
    restart_service_if_running
}

toggle_ppe() {
    # Z2K_PPE_DEOFFLOAD — per-flow hardware-offload exclusion on Keenetic
    # MediaTek (default 1). Hangs the firmware `-j PPE` target on the handshake
    # window of bypass-port flows so nfqws2 sees CH retransmits and the circular
    # rotator advances for offload-blinded silent-drop hosts. It
    # DOES affect NFQWS2_OPT: config_official.sh sets circular retrans=1 when on
    # / leaves retrans=2 when off — so a config regen + service restart IS
    # required, in addition to applying/removing the mangle rules.
    local want="$1"
    set_flag "Z2K_PPE_DEOFFLOAD" "$want" "$CONFIG_FILE" || return 1
    if [ "$want" = "0" ]; then
        [ -r /opt/zapret2/z2k-ppe-deoffload.sh ] && \
            ( . /opt/zapret2/z2k-ppe-deoffload.sh && z2k_ppe_remove_rules ) >/dev/null 2>&1
        regenerate_config
        restart_service_if_running
    else
        regenerate_config
        restart_service_if_running
        # Best-effort: ensure_rules returns 1 where the firmware `-j PPE` target
        # is absent (every non-Keenetic-MediaTek box) — that is an EXPECTED
        # no-op, NOT a toggle failure. Swallow it so toggle_ppe returns 0 and the
        # webpanel doesn't falsely revert the switch (the flag/config/restart all
        # succeeded). The genuine failure (set_flag) is already gated above.
        [ -r /opt/zapret2/z2k-ppe-deoffload.sh ] && \
            ( . /opt/zapret2/z2k-ppe-deoffload.sh && z2k_ppe_ensure_rules ) >/dev/null 2>&1
        return 0
    fi
}

# --- policy access (Keenetic NDM ip policy filter) ---

# policy_exists <name>: returns 0 if a Keenetic IP policy с description = <name>
# существует, иначе 1. Reuse тот же awk parser что в S99zapret2.new.
policy_exists() {
    local name="$1"
    [ -z "$name" ] && return 1
    local ndmc_bin="ndmc"
    [ -x /bin/ndmc ] && ndmc_bin="/bin/ndmc"
    LD_LIBRARY_PATH= "$ndmc_bin" -c "show ip policy" 2>/dev/null | awk -v want="$(printf '%s' "$name" | tr 'A-Z' 'a-z')" '
        function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
        function unquote(s) { s=trim(s); if (s ~ /^".*"$/) { sub(/^"/, "", s); sub(/"$/, "", s) } return s }
        function strip_colon(s) { sub(/:+$/, "", s); return s }
        BEGIN { want = strip_colon(want); found = 0 }
        /description[ \t]*=/ {
            desc = $0
            sub(/.*description[ \t]*=[ \t]*/, "", desc)
            desc = strip_colon(tolower(unquote(desc)))
            if (desc == want) { found = 1; exit }
        }
        END { exit (found ? 0 : 1) }
    '
}

policy_status() {
    # Stdout-эмиссия для api.sh: "name=...|exclude=...|exists=0|1".
    local name exclude exists
    name=$(read_flag "POLICY_NAME" "$CONFIG_FILE" "nfqws")
    exclude=$(read_flag "POLICY_EXCLUDE" "$CONFIG_FILE" "0")
    if policy_exists "$name"; then exists=1; else exists=0; fi
    printf 'name=%s|exclude=%s|exists=%s\n' "$name" "$exclude" "$exists"
}

policy_save() {
    local name="$1" exclude="$2"
    # Имя validation: 1-32 chars, [A-Za-z0-9_-]. Пустое разрешено = выключить
    # фильтр (config_official.sh fallback на nfqws default).
    # Проверка от ОБРАТНОГО: запрещаем то, что ломает, а не разрешаем только
    # латиницу. Прежний список [A-Za-z0-9_-] отбивал и пробел, и кириллицу —
    # а имена политик в Keenetic человек пишет по-русски и с пробелами.
    #
    # Запрещено ровно то, что опасно при `. config`: кавычка рвёт строку,
    # доллар и обратная кавычка подставляют/выполняют, обратный слэш экранирует.
    # Перевод строки и точка с запятой позволили бы дописать команду.
    #
    # Апостроф запрещён не из-за исполнения (set_flag его экранирует как '\'' и
    # `. config` читает имя верно), а потому что обратно его не разворачивает
    # никто: safe_config_read из lib/utils.sh отдаёт O'\''Brien, и следующая же
    # перегенерация — её вызывает сам policy_save — записывает испорченное имя в
    # конфиг навсегда.
    # Вертикальная черта — разделитель полей в выдаче policy_status
    # (name=%s|exclude=%s|exists=%s), имя с ней приезжает в панель обрезанным.
    case "$name" in
        '') name="" ;;
        *[\"\$\`\\\']*|*'|'*|*';'*|*'
'*) echo "invalid policy name" >&2; return 1 ;;
    esac
    # Длина — в СИМВОЛАХ: ${#name} на ash считает БАЙТЫ, и кириллическое имя
    # длиннее ~16 символов отвергалось при лимите формы в 32.
    if [ -n "$name" ] && [ "$(_str_len_chars "$name")" -gt 32 ]; then
        echo "policy name too long" >&2; return 1
    fi
    case "$exclude" in
        0|1) ;;
        *) echo "invalid exclude value" >&2; return 1 ;;
    esac
    set_flag "POLICY_NAME" "$name" "$CONFIG_FILE" || return 1
    set_flag "POLICY_EXCLUDE" "$exclude" "$CONFIG_FILE" || return 1
    regenerate_config
    restart_service_if_running
}

# --- исключения по адресату (nozapret) ---
#
# Отличие от whitelist: тот исключает ДОМЕН из десинка на TCP-профилях
# (--hostlist-exclude, матч по SNI). Здесь исключение по АДРЕСАТУ, на уровне
# файрвола: адрес в сете nozapret проверяется в КАЖДОМ NFQUEUE-правиле
# (`$IPSET_EXCLUDE dst`), поэтому работает и там, где имени нет вообще — UDP,
# STUN, P2P-камеры, домофоны, WebRTC. Именно этого не хватало юзеру с камерами
# EasyLive: у профиля Discord/STUN хостлиста нет, и whitelist там бессилен.
#
# Файл читаем только мы: засев z2k_seed_user_exclusions в S99zapret2 при старте
# файрвола и эта панель. Апстримная ночная пересборка (ipset/get_config.sh ->
# mdig -> ipset flush nozapret) убрана из планировщика 2026-09-02: она читала
# файл в своей грамматике и сбрасывала сет. Панель кладёт адрес в живой сет
# сразу, засев восстанавливает его после перезапуска.
EXCLUDE_FILE="${EXCLUDE_FILE:-$ZAPRET2_DIR/ipset/zapret-hosts-user-exclude.txt}"

# Одна строка файла -> значение записи. Разбор ОБЯЗАН совпадать с тем, что
# делает z2k_seed_user_exclusions в S99zapret2: он режет хвостовой комментарий
# и пробелы, а панель раньше отдавала строку как есть. Из-за расхождения
# «203.0.113.5 # камера» реально работал (сеялся в nozapret), но в панели висел
# в блоке «эти записи ничего не делают», и кнопка удаления отвечала 400 —
# убрать запись было нельзя вообще. То же с ведущим пробелом и с CRLF.
_exclude_norm() {
    local v="${1%%#*}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    printf '%s' "$v"
}

exclude_list() {
    [ -f "$EXCLUDE_FILE" ] || { echo ""; return 0; }
    grep -vE '^[[:space:]]*(#|$)' "$EXCLUDE_FILE"
}

# Домены, осевшие в адресном файле, пока панель их сюда принимала. Они не
# действовали никогда, и вычищать их молча нельзя — человек их вписывал
# осознанно. Показываем отдельно, чтобы он сам решил перенести или удалить.
exclude_list_legacy_domains() {
    [ -f "$EXCLUDE_FILE" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$EXCLUDE_FILE" | while IFS= read -r _e; do
        _e=$(_exclude_norm "$_e")
        [ -n "$_e" ] || continue
        _exclude_looks_like_ip "$_e" || printf '%s\n' "$_e"
    done
}

exclude_list_addresses() {
    [ -f "$EXCLUDE_FILE" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$EXCLUDE_FILE" | while IFS= read -r _e; do
        _e=$(_exclude_norm "$_e")
        [ -n "$_e" ] || continue
        _exclude_looks_like_ip "$_e" && printf '%s\n' "$_e"
    done
}

# Настоящая проверка адреса, а не «похоже на адрес». Прежняя эвристика пускала
# в ipset всё, что состоит из цифр, точек и слеша, плюс ЛЮБУЮ строку с
# двоеточием — то есть example.com:443 и https://example.com проезжали как IPv6
# ровно через тот гейт, который заводился, чтобы домены сюда не попадали.
# А ошибку ipset глушил `2>/dev/null`, поэтому панель рапортовала «Добавлено» и
# показывала запись как действующую, хотя исключения не появлялось.
#
# Ведущие нули запрещены отдельно: ipset читает 010.1.2.3 как восьмеричное.
# Ровно четыре октета — тоже: 1.2.3 он дополняет нулём В СЕРЕДИНЕ и заводит
# 1.2.0.3, то есть исключает адрес, которого человек не называл. Проверено на
# роутере.
_octet_ok() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
    esac
    [ "$1" -le 255 ]
}

_prefix_ok() {  # $1=длина, $2=потолок
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
    esac
    [ "$1" -le "$2" ]
}

_exclude_is_ipv4() {
    local a="$1" pfx="" o1 o2 o3 o4 rest o
    case "$a" in
        */*) pfx="${a#*/}"; a="${a%%/*}"
             case "$pfx" in *[/]*) return 1 ;; esac
             _prefix_ok "$pfx" 32 || return 1 ;;
    esac
    IFS=. read -r o1 o2 o3 o4 rest <<EOF
$a
EOF
    [ -z "$rest" ] || return 1
    for o in "$o1" "$o2" "$o3" "$o4"; do _octet_ok "$o" || return 1; done
    return 0
}

_exclude_is_ipv6() {
    local a="$1" pfx="" dd
    case "$a" in
        */*) pfx="${a#*/}"; a="${a%%/*}"
             case "$pfx" in *[/]*) return 1 ;; esac
             _prefix_ok "$pfx" 128 || return 1 ;;
    esac
    case "$a" in
        *:*) ;;
        *) return 1 ;;
    esac
    case "$a" in *[!0-9A-Fa-f:]*) return 1 ;; esac
    case "$a" in *:::*) return 1 ;; esac
    dd=$(printf '%s' "$a" | awk '{print gsub(/::/,"::")}')
    [ "${dd:-0}" -le 1 ]
}

_exclude_looks_like_ip() {
    case "$1" in
        *:*) _exclude_is_ipv6 "$1" ;;
        *)   _exclude_is_ipv4 "$1" ;;
    esac
}

# Применить/снять запись в живом сете. Тихо: сет может отсутствовать (сервис
# остановлен) — это не ошибка, файл всё равно подхватится при следующем старте.
_exclude_ipset_apply() {
    local op="$1" entry="$2" set4="nozapret" set6="nozapret6"
    command -v ipset >/dev/null 2>&1 || return 0
    case "$entry" in
        *:*) ipset "$op" "$set6" "$entry" -exist 2>/dev/null || true ;;
        *)   ipset "$op" "$set4" "$entry" -exist 2>/dev/null || true ;;
    esac
    return 0
}

_exclude_validate() {
    # Домены, IPv4/CIDR и IPv6/CIDR. Ведущий `-` отвергаем — легитимной записи
    # с него не начинается, а в shell-путях он превратился бы во флаг.
    case "$1" in
        ''|*' '*) return 1 ;;
        -*) return 1 ;;
        *[!a-zA-Z0-9.:/-]*) return 1 ;;
        *) return 0 ;;
    esac
}

exclude_add() {
    _list_lock "$EXCLUDE_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _exclude_add_locked "$@"; _rc=$?
    _list_unlock "$EXCLUDE_FILE"
    return $_rc
}

_exclude_add_locked() {
    local entry="$1"
    _exclude_validate "$entry" || { echo "invalid entry" >&2; return 1; }
    # Домен сюда больше не принимаем. Раньше принимали — и он молча оседал в
    # файле навсегда: в ipset имя выразить нельзя, а цепочка, которая по замыслу
    # апстрима резолвила бы его в адреса, в z2k не выполняется. Исключение по
    # имени работает в другом месте (--hostlist-exclude, lists/whitelist.txt) и
    # применяется живьём.
    # Домен и опечатка в адресе — разные ошибки, и советовать по ним надо разное.
    # Раньше 999.1.2.3 получал «это домен, идите во вкладку Домены», что для
    # человека выглядит как издевательство.
    if ! _exclude_looks_like_ip "$entry"; then
        case "$entry" in
            *[a-zA-Z]*)
                echo "это домен — добавьте его во вкладке «Домены», здесь только адреса и подсети" >&2 ;;
            *)
                echo "не похоже на адрес или подсеть: проверьте запись (пример: 203.0.113.7 или 203.0.113.0/24)" >&2 ;;
        esac
        return 1
    fi
    mkdir -p "$(dirname "$EXCLUDE_FILE")" 2>/dev/null
    touch "$EXCLUDE_FILE" 2>/dev/null
    if ! grep -qxF "$entry" "$EXCLUDE_FILE"; then
        _list_end_nl "$EXCLUDE_FILE"
        printf '%s\n' "$entry" >> "$EXCLUDE_FILE"
        chmod 644 "$EXCLUDE_FILE" 2>/dev/null || true
    fi
    # Адрес — применяем сразу; домен — подхватится обновлением списков.
    if _exclude_looks_like_ip "$entry"; then
        _exclude_ipset_apply add "$entry"
    fi
    return 0
}

exclude_delete() {
    _list_lock "$EXCLUDE_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _exclude_delete_locked "$@"; _rc=$?
    _list_unlock "$EXCLUDE_FILE"
    return $_rc
}

_exclude_delete_locked() {
    local entry="$1"
    # Проверка мягче, чем при добавлении, и намеренно. Удалять приходится и то,
    # что добавлением сегодня уже не пропустить: легаси-домены с подчёркиванием
    # или звёздочкой панель показывает с кнопкой «удалить», а строгий чарсет
    # отвечал на неё 400 — то есть блок «уберите это отсюда» не работал ровно
    # на своём содержимом. Значение приходит из нашего же листинга; опасен тут
    # только перевод строки, он бы разъехался на две записи.
    # Перевод строки задаётся литералом: $(printf '\n') не годится — подстановка
    # срезает хвостовые переводы строк, шаблон вырождается в пустой и матчит всё.
    case "$entry" in
        ''|*'
'*) echo "invalid entry" >&2; return 1 ;;
    esac
    if _exclude_looks_like_ip "$entry"; then
        _exclude_ipset_apply del "$entry"
    fi
    [ -f "$EXCLUDE_FILE" ] || return 0
    # Удаляем по ЗНАЧЕНИЮ, а не по точному совпадению строки: панель показывает
    # запись уже нормализованной, и «203.0.113.5» обязан убирать строку
    # «203.0.113.5 # камера», иначе кнопка удаления не работает ровно на тех
    # записях, которые человек правил руками.
    local tmp="$EXCLUDE_FILE.z2k-new.$$" found=0
    while IFS= read -r _l || [ -n "$_l" ]; do
        if [ "$(_exclude_norm "$_l")" = "$entry" ]; then found=1; continue; fi
        printf '%s\n' "$_l"
    done < "$EXCLUDE_FILE" > "$tmp" || { rm -f "$tmp"; echo "не удалось сохранить список" >&2; return 1; }
    [ "$found" = "1" ] || { rm -f "$tmp"; return 0; }
    _file_replace "$EXCLUDE_FILE" "$tmp" || { echo "не удалось сохранить список" >&2; return 1; }
    return 0
}

# --- whitelist ---

whitelist_list() {
    [ -f "$WHITELIST_FILE" ] || { echo ""; return 0; }
    grep -vE '^[[:space:]]*(#|$)' "$WHITELIST_FILE"
}

whitelist_add() {
    _list_lock "$WHITELIST_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _whitelist_add_locked "$@"; _rc=$?
    _list_unlock "$WHITELIST_FILE"
    return $_rc
}

_whitelist_add_locked() {
    local domain="$1"
    # Basic sanity: lowercase letters/digits/.-, no spaces, no shell metachars.
    # Reject leading `-` defensively — no legitimate hostname starts with one
    # and any shell-out path would treat it as an option flag.
    case "$domain" in
        ''|*' '*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    # Симметрично адресной вкладке. Этот список уходит движку как
    # --hostlist-exclude, то есть сверяется с ИМЕНЕМ хоста; вписанный сюда адрес
    # не совпадёт ни с чем никогда, а панель отвечала «Добавлено» и показывала
    # его в списке — то же тихое ничегонеделание, что было с доменами в адресах.
    if _exclude_is_ipv4 "$domain"; then
        echo "это адрес — добавьте его во вкладке «Адреса», здесь только домены" >&2
        return 1
    fi
    mkdir -p "$LISTS_DIR" 2>/dev/null
    touch "$WHITELIST_FILE" 2>/dev/null
    if grep -qxF "$domain" "$WHITELIST_FILE"; then
        return 0  # idempotent
    fi
    _list_end_nl "$WHITELIST_FILE"
    printf '%s\n' "$domain" >> "$WHITELIST_FILE"
    # nfqws2 runs as nobody (uid 65534) and must be able to read the file.
    chmod 644 "$WHITELIST_FILE" 2>/dev/null || true
    # NB: НЕ рестартим сервис — whitelist подхватывается live, как и extra-domains
    # (feedback_no_service_restart_for_hostlist).
}

whitelist_import() {
    # ПОД ЗАМКОМ, как whitelist_add и whitelist_delete рядом.
    #
    # Импорт единственный из троих его не брал, хотя пишет в тот же файл и делает
    # это дольше всех: сначала снимает снимок существующих строк через grep, потом
    # дописывает новые через `cat >>`. Между этими двумя шагами удаление,
    # пришедшее из панели или из меню, успевает переписать файл целиком — и его
    # версия, уже без удалённого домена, затирается нашим дописыванием поверх
    # устаревшего снимка. Пропадает не импорт, а ЧУЖОЕ удаление, поэтому человек
    # ничего не замечает: домен, который он только что убрал, просто снова здесь.
    _list_lock "$WHITELIST_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _whitelist_import_locked "$@"; _rc=$?
    _list_unlock "$WHITELIST_FILE"
    return $_rc
}

_whitelist_import_locked() {
    # Bulk merge — читает многострочный список доменов из stdin (TXT файл).
    # Per-line: trim CR/spaces, skip empty/comments (#), lowercase, validate.
    # Dedup vs existing whitelist через sort + comm. Append only new entries.
    # Single service restart в конце (а не на каждый домен).
    # Output: "added=N skipped_dup=N skipped_invalid=N" на stdout.
    local skipped_invalid=0
    mkdir -p "$LISTS_DIR" 2>/dev/null
    touch "$WHITELIST_FILE" 2>/dev/null

    local tmpnew tmpexisting tmpnewuniq tmpadd
    tmpnew=$(mktemp) || { echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }
    tmpexisting=$(mktemp) || { rm -f "$tmpnew"; echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }
    tmpnewuniq=$(mktemp) || { rm -f "$tmpnew" "$tmpexisting"; echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }
    tmpadd=$(mktemp) || { rm -f "$tmpnew" "$tmpexisting" "$tmpnewuniq"; echo "added=0 skipped_dup=0 skipped_invalid=0"; return 1; }

    local line domain
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading/trailing whitespace INCLUDING the CR of a CRLF file —
        # [[:space:]] covers \r, so this also strips the Windows line ending.
        # (The old `${line%$'\r'}` was a no-op on busybox ash: $'...' ANSI-C
        # quoting is not supported there, so it never matched a real CR.)
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        domain=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
        # A leading '-', any internal space, or any char outside [a-z0-9.-] is
        # rejected; the charset check also covers tab/CR, so no $'\t' pattern
        # (which is inert in busybox ash anyway) is needed.
        case "$domain" in
            -*|*' '*)      skipped_invalid=$((skipped_invalid + 1)); continue ;;
            *[!a-z0-9.-]*) skipped_invalid=$((skipped_invalid + 1)); continue ;;
        esac
        printf '%s\n' "$domain" >> "$tmpnew"
    done

    sort -u "$tmpnew" > "$tmpnewuniq"
    grep -vE '^[[:space:]]*(#|$)' "$WHITELIST_FILE" | sort -u > "$tmpexisting"
    # busybox `comm` ненадёжен (Input/output error на Entware) — используем awk:
    # первым файлом проходит существующий список, marks each in `e[]`;
    # затем по новому списку печатает только те которые НЕ в `e[]`.
    #
    # Разделяем файлы по FILENAME, а не по NR==FNR: на ПУСТОМ существующем
    # списке awk не читает из него ни одной записи, NR==FNR остаётся истинным
    # для всего второго файла — и весь импорт уезжает в e[], не печатая ничего.
    # Это путь первого импорта у каждого нового пользователя: whitelist.txt ещё
    # пуст, и панель отвечала added=0 на любой файл.
    awk -v ex="$tmpexisting" 'FILENAME == ex { e[$0]=1; next } !e[$0]' \
        "$tmpexisting" "$tmpnewuniq" > "$tmpadd"
    local added skipped_dup
    added=$(wc -l < "$tmpadd" | tr -d ' ')
    skipped_dup=$(awk -v ex="$tmpexisting" 'FILENAME == ex { e[$0]=1; next } e[$0]' \
        "$tmpexisting" "$tmpnewuniq" | wc -l | tr -d ' ')

    if [ "$added" -gt 0 ]; then
        _list_end_nl "$WHITELIST_FILE"
        cat "$tmpadd" >> "$WHITELIST_FILE"
        chmod 644 "$WHITELIST_FILE" 2>/dev/null || true
        # NB: НЕ рестартим — whitelist live.
    fi

    rm -f "$tmpnew" "$tmpexisting" "$tmpnewuniq" "$tmpadd"
    printf 'added=%d skipped_dup=%d skipped_invalid=%d\n' "$added" "$skipped_dup" "$skipped_invalid"
}

whitelist_delete() {
    _list_lock "$WHITELIST_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _whitelist_delete_locked "$@"; _rc=$?
    _list_unlock "$WHITELIST_FILE"
    return $_rc
}

_whitelist_delete_locked() {
    local domain="$1"
    [ -f "$WHITELIST_FILE" ] || return 0
    case "$domain" in
        ''|*' '*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    if ! grep -qxF "$domain" "$WHITELIST_FILE"; then
        return 0  # idempotent
    fi
    _list_remove_line "$WHITELIST_FILE" "$domain" || { echo "не удалось сохранить список" >&2; return 1; }
    # NB: НЕ рестартим — whitelist live (см. whitelist_add).
    return 0
}

# --- где ещё встречается домен -------------------------------------------------
#
# Вписывать в «Доп домены» то, что уже лежит в РКН, YouTube или Discord, — чистая
# самообманка: обход для такого домена и так работает, запись ничего не меняет, а
# человек уверен, что что-то настроил. Хуже, когда домен лежит в исключениях: там
# он намеренно выключен, и добавление в доп домены выглядит как «включил», хотя
# исключение всё равно победит.
#
# Совпадением считается сам домен ИЛИ любой его родитель: хостлисты матчат
# поддомены, поэтому при наличии example.com запись www.example.com избыточна.
# Обратное неверно — example.com при наличии www.example.com добавлять можно, он
# шире.
_domain_lists_catalog() {
    # <метка>|<путь>. Порядок = порядок проверки; первым идёт то, что человеку
    # понятнее увидеть в ответе.
    cat <<CATALOG
исключения|${LISTS_DIR}/whitelist.txt
РКН|${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt
YouTube|${ZAPRET2_DIR}/extra_strats/TCP/YT/List.txt
YouTube (видео)|${ZAPRET2_DIR}/extra_strats/TCP/YT_GV/List.txt
YouTube (QUIC)|${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt
Discord|${ZAPRET2_DIR}/extra_strats/TCP_Discord.txt
автохостлист|${LISTS_DIR}/autohostlist-domains.txt
найденные автоматически|${LISTS_DIR}/discovered-domains.txt
CATALOG
}

# Домен и все его родители, по одному на строку: для www.a.example.com это
# www.a.example.com, a.example.com, example.com. Односегментные хвосты (com)
# отбрасываем — они в списках не встречаются, а искать их дорого и опасно.
_domain_suffixes() {
    printf '%s' "$1" | awk '
    {
        n = split($0, a, ".")
        for (i = 1; i <= n - 1; i++) {
            s = a[i]
            for (j = i + 1; j <= n; j++) s = s "." a[j]
            print s
        }
    }'
}

# Печатает «метка|совпавшая запись», если домен уже покрыт каким-то списком.
# Пусто — значит нигде не встречается.
#
# Один grep на список, а не на каждый суффикс: в РКН-списке 75 тысяч строк, и
# перебор по домену превратил бы добавление одной записи в несколько секунд.
# Цикл читает каталог через here-doc, а НЕ из конвейера: за конвейером тело
# while уезжает в подоболочку, и выход из него по первому совпадению перестаёт
# работать — проверялись бы все списки до последнего.
_domain_in_lists() {
    local domain="$1" pats label path hit
    pats=$(_domain_suffixes "$domain")
    [ -n "$pats" ] || return 0
    while IFS='|' read -r label path; do
        [ -n "$path" ] && [ -s "$path" ] || continue
        hit=$(printf '%s\n' "$pats" | grep -m1 -xF -f - "$path" 2>/dev/null)
        if [ -n "$hit" ]; then
            printf '%s|%s\n' "$label" "$hit"
            return 0
        fi
    done <<CATALOG
$(_domain_lists_catalog)
CATALOG
    return 0
}

# --- extra-domains ---
# Live hostlist для autocircular. Подхватывается сервисом без рестарта
# (memory feedback_no_service_restart_for_hostlist). Если файл редактируют
# вручную или через webpanel — z2k увидит изменения в течение нескольких
# секунд через файловый poll.

extra_domains_list() {
    [ -f "$EXTRA_DOMAINS_FILE" ] || { echo ""; return 0; }
    grep -vE '^[[:space:]]*(#|$)' "$EXTRA_DOMAINS_FILE"
}

# Домены, которые автохостлист подобрал сам. Файл ведёт сервис
# (sync_autohostlist_to_rkn): туда попадает всё найденное, и оттуда же оно
# восстанавливается после обновления РКН-списка с апстрима.
AUTOHOSTLIST_DOMAINS_FILE="${AUTOHOSTLIST_DOMAINS_FILE:-$LISTS_DIR/autohostlist-domains.txt}"

autohostlist_domains_list() {
    [ -f "$AUTOHOSTLIST_DOMAINS_FILE" ] || { echo ""; return 0; }
    grep -vE '^[[:space:]]*(#|$)' "$AUTOHOSTLIST_DOMAINS_FILE"
}

# Удаление — это «автохостлист ошибся, домен сюда не относится». Убираем и из
# накопленного, и из РКН-списка, иначе следующий старт вернёт его обратно.
autohostlist_domains_delete() {
    # ПОД ЗАМКОМ — как extra_domains_delete и whitelist_delete ниже.
    #
    # Функция трогает ДВА файла, и второй из них, extra_strats/TCP/RKN/List.txt,
    # переписывает не только панель: его же обновляет фоновая синхронизация
    # списков. Схема «grep -v в temp, затем mv» атомарна сама по себе, но не
    # защищает от того, что снимок для grep взят до чужой записи: тогда mv
    # возвращает файл к состоянию, в котором чужих правок ещё не было, и они
    # исчезают. Замок берём на каждый файл по очереди, а не один общий: они
    # независимы, и держать оба разом значило бы связать панель с фоновой
    # задачей крепче, чем нужно.
    local domain="$1" rkn tmp _f_rc
    case "$domain" in
        ''|*' '*|-*|*[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    domain=$(printf '%s' "$domain" | tr 'A-Z' 'a-z'); domain="${domain%.}"
    [ -n "$domain" ] || { echo "invalid domain" >&2; return 1; }
    rkn="${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt"
    # Третий файл — живой автолист движка. Пока его тут не было, удаление
    # работало только до следующего слива: домен лежал в ipset/zapret-hosts-auto.txt,
    # и старт сервиса возвращал его и в накопленное, и в РКН-список.
    local auto_live="${ZAPRET2_DIR}/ipset/zapret-hosts-auto.txt"
    for f in "$AUTOHOSTLIST_DOMAINS_FILE" "$auto_live" "$rkn"; do
        [ -f "$f" ] || continue
        _list_lock "$f" || { echo "список занят, повторите" >&2; return 1; }
        tmp="${f}.z2k.$$"
        grep -vxF "$domain" "$f" > "$tmp" 2>/dev/null
        # grep -v выходит с единицей, когда не осталось ни строки, — на статус
        # тут смотреть нельзя, иначе удаление последней записи молча отменится.
        _f_rc=0
        if [ -f "$tmp" ]; then
            mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; _f_rc=1; }
        else
            _f_rc=1
        fi
        _list_unlock "$f"
        [ "$_f_rc" -eq 0 ] || { echo "не удалось переписать $f" >&2; return 1; }
    done
    return 0
}

extra_domains_add() {
    _list_lock "$EXTRA_DOMAINS_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _extra_domains_add_locked "$@"; _rc=$?
    _list_unlock "$EXTRA_DOMAINS_FILE"
    return $_rc
}

_extra_domains_add_locked() {
    local domain="$1"
    case "$domain" in
        ''|*' '*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    # Lowercase + strip trailing dot (как делает normalize_hostkey_for_state
    # в lua, чтобы UI consistent).
    domain=$(printf '%s' "$domain" | tr 'A-Z' 'a-z')
    domain="${domain%.}"
    [ -z "$domain" ] && { echo "invalid domain" >&2; return 1; }
    mkdir -p "$LISTS_DIR" 2>/dev/null
    touch "$EXTRA_DOMAINS_FILE" 2>/dev/null
    if grep -qxF "$domain" "$EXTRA_DOMAINS_FILE"; then
        return 0  # idempotent
    fi
    # Уже покрыт другим списком — добавлять нечего. Сообщение уходит в stderr,
    # оттуда его подхватывает api.sh и показывает человеку целиком: без имени
    # списка ответ «уже есть» бесполезен, искать домен по восьми файлам он не
    # пойдёт.
    local _found _flabel _fentry
    _found=$(_domain_in_lists "$domain")
    if [ -n "$_found" ]; then
        _flabel="${_found%%|*}"
        _fentry="${_found#*|}"
        if [ "$_fentry" = "$domain" ]; then
            echo "домен уже есть в списке «${_flabel}»" >&2
        else
            echo "домен уже покрыт записью ${_fentry} в списке «${_flabel}»" >&2
        fi
        return 1
    fi
    _list_end_nl "$EXTRA_DOMAINS_FILE"
    printf '%s\n' "$domain" >> "$EXTRA_DOMAINS_FILE"
    chmod 644 "$EXTRA_DOMAINS_FILE" 2>/dev/null || true
    # NB: НЕ рестартим сервис — extra-domains.txt подхватывается live.
}

extra_domains_delete() {
    _list_lock "$EXTRA_DOMAINS_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _extra_domains_delete_locked "$@"; _rc=$?
    _list_unlock "$EXTRA_DOMAINS_FILE"
    return $_rc
}

_extra_domains_delete_locked() {
    local domain="$1"
    [ -f "$EXTRA_DOMAINS_FILE" ] || return 0
    case "$domain" in
        ''|*' '*) echo "invalid domain" >&2; return 1 ;;
        -*) echo "invalid domain" >&2; return 1 ;;
        *[!a-zA-Z0-9.-]*) echo "invalid domain" >&2; return 1 ;;
    esac
    domain=$(printf '%s' "$domain" | tr 'A-Z' 'a-z')
    domain="${domain%.}"
    [ -z "$domain" ] && { echo "invalid domain" >&2; return 1; }
    if ! grep -qxF "$domain" "$EXTRA_DOMAINS_FILE"; then
        return 0  # idempotent
    fi
    _list_remove_line "$EXTRA_DOMAINS_FILE" "$domain" || { echo "не удалось сохранить список" >&2; return 1; }
    # NB: НЕ рестартим сервис.
    return 0
}

# --- WARP lists (webpanel «WARP» section) ---
# User-owned IPv4/CIDR lists in $WARP_LISTS_DIR — z2k-warp.sh loads ALL *.txt
# there into the z2k_warp ipset. Те же правила записи, что и у whitelist:
# наполненный temp подменяет файл целиком через _file_replace (rename, а не
# «обнулить и залить»), режим и владелец переносятся на новый inode, сервис не
# перезапускается. After any mutation, if WARP is enabled we rebuild the live
# ipset (`z2k-warp.sh ipset`, an ipset-restore bulk load — subsecond even for
# the 18k-entry game list).

warp_name_ok() {
    # List name (WITHOUT .txt): 1-64 chars of [A-Za-z0-9._-]. The charset
    # excludes '/', so no path can escape $WARP_LISTS_DIR; leading '.' (hidden
    # files / "..") and leading '-' (option injection) rejected explicitly.
    case "$1" in
        ''|.*|-*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
        devices) return 1 ;;   # зарезервировано: список устройств, не адресов
    esac
    [ "${#1}" -le 64 ]
}

warp_lists_ensure_dir() {
    # Directory layout and the one-shot purge of the legacy aggregate have EXACTLY one
    # implementation — z2k-warp.sh warp_lists_migrate. Keeping a second copy here as a
    # fallback is how two migrations drift apart, so the panel only ever delegates.
    #
    # What we must NOT do is create the directory ourselves when the engine is unavailable:
    # the callers would then report success while games/ is missing and the purge never ran.
    # Better an honest "lists dir unavailable".
    #
    # The cheap guard is the purge marker, not the directory. The directory alone used to
    # mean "already migrated" back when migration meant seeding a starter list; now the
    # engine is idempotent and the marker is what says the one-time work is done.
    [ -d "$WARP_LISTS_DIR" ] && [ -f "$WARP_LISTS_DIR/.legacy-aggregate-purged" ] && return 0
    [ -f "$WARP_SCRIPT" ] || return 1
    sh "$WARP_SCRIPT" migrate >/dev/null 2>&1
    [ -d "$WARP_LISTS_DIR" ]
}

warp_ipset_reload_if_enabled() {
    # Live-apply list edits: rebuild the ipset only while the feature is ON.
    # While OFF the set is left alone — enable does a full load anyway.
    [ "$(read_flag "GAME_WARP_ENABLED" "$CONFIG_FILE" "0")" = "1" ] || return 0
    [ -f "$WARP_SCRIPT" ] || return 0
    sh "$WARP_SCRIPT" ipset >/dev/null 2>&1 || true
}

warp_status_info() {
    # Stdout для api.sh — строка key=value от z2k-warp.sh status (он читает
    # status.json движка; проб здесь нет и быть не должно — это путь опроса
    # панели). enabled берём из конфига сами: значение может быть битым, и
    # контрактный тест требует донести его как есть.
    local st=""
    [ -f "$WARP_SCRIPT" ] && st=$(sh "$WARP_SCRIPT" status 2>/dev/null)
    printf '%s enabled=%s\n' "$st" "$(read_flag "GAME_WARP_ENABLED" "$CONFIG_FILE" "0")"
}

# ---------- устройства «всё в WARP» (lists/warp/devices.txt) ----------
# Строка — IPv4 или MAC; MAC нормализуется к нижнему регистру с двоеточиями.
# Мусор отбрасывается и считается. Живой ipset пересобирается, если режим включён.
warp_devices_read() {
    [ -f "$WARP_LISTS_DIR/devices.txt" ] && cat "$WARP_LISTS_DIR/devices.txt"
    return 0
}

# Устройства в сети — из Keenetic (`show ip hotspot`): имя, которое юзер дал
# устройству в веб-интерфейсе роутера, hostname, IP, сеть, онлайн. TSV:
#   mac<TAB>ip<TAB>label<TAB>net<TAB>active(0/1)<TAB>on(0/1)
# on — MAC уже в devices.txt. Без ndmc (не Keenetic / тесты) — пусто.
# WARP_NDMC — стаб в тестах.
# Перерегистрация устройства у Cloudflare.
#
# Сносим ТОЛЬКО запись устройства и поднимаем демон заново — он зарегистрируется
# с нуля. Нужно ровно для одного случая: в записи стоит адрес из диапазона,
# который режут провайдеры, и починить его нечем — «Удалить WARP» намеренно
# сохраняет ключ, поэтому переустановка возвращает ту же мёртвую запись.
#
# Действие не бесплатное: у Cloudflare есть лимит устройств на аккаунт, и каждое
# нажатие тратит одно. Поэтому кнопка снабжена предупреждением, а не спрятана:
# спрятанный рычаг ищут наугад, предупреждённый — по делу.
# --- проверка DNS ---------------------------------------------------------
#
# Обёртка над files/z2k-dns-check.sh: он спрашивает публичные серверы и решает,
# кто отвечает честно. Ничего не меняет, пишет только в tmpfs.
#
# Долгая по природе (заблокированный сервер стоит полного таймаута), поэтому
# вызывается задачей, как установка WARP, а не синхронно из запроса.
DNS_CHECK_SCRIPT="${DNS_CHECK_SCRIPT:-$ZAPRET2_DIR/z2k-dns-check.sh}"
DNS_CHECK_OUT="${DNS_CHECK_OUT:-/tmp/z2k-dns-check.json}"
DNS_CHECK_OWN="${DNS_CHECK_OWN:-$ZAPRET2_DIR/lists/dns-check.txt}"

dns_check_run() {
    [ -f "$DNS_CHECK_SCRIPT" ] || { echo "нет $DNS_CHECK_SCRIPT"; return 1; }
    # Прогресс скрипт пишет в stderr, готовый JSON — в stdout и в файл.
    # В журнал задачи пускаем ТОЛЬКО прогресс: JSON там нечитаем, а человек
    # смотрит туда, чтобы понять, что работа идёт.
    # Порядок редиректов здесь ОБРАТНЫЙ обычному и нарочно: сперва stderr
    # уходит туда, куда сейчас смотрит stdout (в журнал), и только потом stdout
    # затыкается. Написав привычное `>/dev/null 2>&1`, мы отправили бы в никуда
    # и прогресс тоже.
    # shellcheck disable=SC2069
    Z2K_DNS_OUT="$DNS_CHECK_OUT" Z2K_DNS_OWN="$DNS_CHECK_OWN" \
        sh "$DNS_CHECK_SCRIPT" 2>&1 >/dev/null || return 1
    return 0
}

# Последний результат. Пусто — проверку ещё не запускали.
dns_check_last() {
    [ -s "$DNS_CHECK_OUT" ] && cat "$DNS_CHECK_OUT"
}

# Свои серверы человека. Одна строка — один сервер: адрес для UDP или ссылка
# для DoH. Файл лежит в lists/ рядом с остальными пользовательскими списками,
# поэтому переживает обновление и переустановку.
dns_check_own_read() {
    [ -f "$DNS_CHECK_OWN" ] && cat "$DNS_CHECK_OWN"
    return 0
}

dns_check_own_save() {
    local tmp="${DNS_CHECK_OWN}.new.$$" kept=0 dropped=0 line
    mkdir -p "$(dirname "$DNS_CHECK_OWN")" 2>/dev/null
    : > "$tmp" || return 1
    # `|| [ -n "$line" ]` — БЕЗ НЕГО ТЕРЯЕТСЯ ПОСЛЕДНЯЯ СТРОКА.
    #
    # Тело POST приходит через $(read_body), а подстановка срезает хвостовой
    # перевод строки. `read` на незавершённой строке возвращает ненулевой код,
    # и цикл заканчивается ДО обработки — то есть до тела не доходит ровно то,
    # что человек набрал последним. Вписал один сервер, не нажав Enter, —
    # сохранилось ноль записей, а форма честно сказала «Сохранено», потому что
    # провала не было. Ровно эта жалоба и пришла из поля.
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d ' \t\r')
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in
            https://*)
                printf '%s\n' "$line" >> "$tmp"; kept=$((kept + 1)) ;;
            *[!0-9.]*)
                dropped=$((dropped + 1)) ;;
            *.*.*.*)
                printf '%s\n' "$line" >> "$tmp"; kept=$((kept + 1)) ;;
            *)
                dropped=$((dropped + 1)) ;;
        esac
    done
    mv -f "$tmp" "$DNS_CHECK_OWN" && chmod 644 "$DNS_CHECK_OWN"
    printf 'entries=%s dropped=%s\n' "$kept" "$dropped"
    return 0
}

warp_reregister() {
    local dev="${WARP_DEVICE:-/opt/etc/z2k-warp/device.json}"
    local init="${WARP_INIT:-/opt/etc/init.d/S51z2k-warp}"
    [ -f "$dev" ] || { echo "запись устройства и так отсутствует — регистрация произойдёт при следующем запуске"; return 0; }
    # Копию держим до конца: если новая регистрация не удастся, человек
    # останется хотя бы с прежней записью, а не без устройства вовсе.
    cp -f "$dev" "${dev}.prev" 2>/dev/null
    rm -f "$dev" 2>/dev/null
    echo "запись устройства снята, поднимаю движок заново"
    [ -x "$init" ] && "$init" restart 2>&1
    sleep 8
    if [ -s "$dev" ]; then
        echo "новая регистрация получена: $(sed -n 's/.*"v4": *"\([^"]*\)".*/адрес \1/p' "$dev" | head -1)"
        rm -f "${dev}.prev" 2>/dev/null
        return 0
    fi
    echo "новая регистрация не получена — возвращаю прежнюю запись"
    [ -f "${dev}.prev" ] && mv -f "${dev}.prev" "$dev"
    [ -x "$init" ] && "$init" restart >/dev/null 2>&1
    return 1
}

warp_neighbors() {
    local ndmc_bin="${WARP_NDMC:-ndmc}"
    [ -x /bin/ndmc ] && [ -z "${WARP_NDMC:-}" ] && ndmc_bin="/bin/ndmc"
    command -v "$ndmc_bin" >/dev/null 2>&1 || return 0
    local sel="$WARP_LISTS_DIR/devices.txt"
    [ -f "$sel" ] || sel=/dev/null
    LD_LIBRARY_PATH= "$ndmc_bin" -c "show ip hotspot" 2>/dev/null | awk -v sel="$sel" '
    BEGIN {
        while ((getline l < sel) > 0) {
            gsub(/\r/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); l = tolower(l); gsub(/-/, ":", l)
            if (l ~ /^([0-9a-f][0-9a-f]:)+[0-9a-f][0-9a-f]$/) on[l] = 1
        }
    }
    function flush() {
        if (mac == "") return
        # Авто-имя Keenetic «<mac|host> - Home network - 2026-01-24» — не имя:
        # берём hostname, а без него — часть до « - ».
        if (name ~ / - [^-]* network -/) {
            base = name; sub(/ - .*$/, "", base)
            name = (host != "") ? host : base
        }
        label = name; if (label == "") label = host; if (label == "") label = mac
        if (ip == "0.0.0.0") ip = ""
        # Разделитель — \037 (unit separator), а НЕ таб.
        #
        # Таб входит в число IFS-ПРОБЕЛЬНЫХ символов, и `read` схлопывает
        # подряд идущие пробельные разделители в один — даже когда IFS явно
        # выставлен ровно в таб. У офлайн-устройства пусты и адрес, и сегмент:
        # два таба подряд превращались в один, все поля съезжали влево, и
        # панель показывала имя на месте адреса, а на месте имени и сегмента —
        # остатки числовых полей. \037 пробельным не является, пустые поля
        # переживают чтение, и в выводе ndmc он встретиться не может.
        printf "%s\037%s\037%s\037%s\037%d\037%d\n", mac, ip, label, net, active, (mac in on)
        mac = ""; ip = ""; host = ""; name = ""; net = ""; active = 0
    }
    {
        sub(/^[ \t]+/, ""); k = $1; sub(/^[^:]*:[ \t]*/, ""); v = $0
        if (k == "mac:") { flush(); mac = tolower(v) }
        else if (k == "ip:") ip = v
        else if (k == "hostname:") host = v
        else if (k == "name:" && net == "" && mac != "" && !iface) { name = v }
        else if (k == "interface:") iface = 1
        else if (k == "name:" && iface) { net = v; iface = 0 }
        else if (k == "active:") active = (v == "yes")
    }
    END { flush() }' | awk -F'\037' '{ gsub(/"/, "", $3); print }' OFS='\037' | sort -t "$(printf '\037')" -k5,5r -k3,3f
}

# Включить/выключить устройство по MAC: строка в devices.txt добавляется или
# убирается; ручные строки (IP, чужие MAC) не трогаются.
warp_device_toggle() {
    local mac val="$2" f="$WARP_LISTS_DIR/devices.txt" tmp
    mac=$(printf '%s' "$1" | tr 'A-Z-' 'a-z:')
    case "$mac" in
        ??:??:??:??:??:??) ;;
        *) return 1 ;;
    esac
    case "$mac" in *[!0-9a-f:]*) return 1 ;; esac
    warp_lists_ensure_dir || return 1
    tmp="$WARP_LISTS_DIR/.devices.$$"
    {
        [ -f "$f" ] && awk -v m="$mac" '{ l = tolower($0); gsub(/-/, ":", l); gsub(/^[ \t]+|[ \t]+$/, "", l); if (l != m) print }' "$f"
        [ "$val" = "1" ] && printf '%s\n' "$mac"
        true
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$f" && chmod 644 "$f"
    warp_ipset_reload_if_enabled
    return 0
}

warp_devices_save() {
    # stdin → devices.txt; stdout: "entries=N dropped=M"
    warp_lists_ensure_dir || return 1
    local tmp="$WARP_LISTS_DIR/.devices.$$"
    awk '
    # --- z2k warp SOURCE filter (canonical; keep byte-identical in both copies) ---
    # Поле означает УСТРОЙСТВО В ЛОКАЛЬНОЙ СЕТИ, и фильтр обязан это отражать.
    # Раньше принималось всё с первым октетом 1-255 — включая 127.0.0.1 и любой
    # ПУБЛИЧНЫЙ адрес. Цена ошибки не теоретическая: MARK-правило для источников
    # стоит в PREROUTING БЕЗ `-i`, то есть матчится и на lo, и на входе с WAN.
    # Публичный адрес в этом списке метит ВХОДЯЩИЙ трафик от того хоста и уводит
    # ответы ему в туннель — так можно отрезать роутеру, например, его апстрим.
    # Поэтому: только приватные и CGNAT-диапазоны, где LAN-устройство и живёт.
    # Отброшенное не теряется молча — панель возвращает "entries=N dropped=M".
    function ip_ok(s,  o) {
        if (s !~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) return 0
        split(s, o, ".")
        if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return 0
        if (o[1] == 10) return 1
        if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 1
        if (o[1] == 192 && o[2] == 168) return 1
        if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 1
        return 0
    }
    # --- end z2k warp SOURCE filter ---
    {
        sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0 == "" || $0 ~ /^#/) next
        m = tolower($0); gsub(/-/, ":", m)
        if (m ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) { print m; n++; next }
        if (ip_ok($0)) { print $0; n++; next }
        d++
    }
    END { printf "entries=%d dropped=%d\n", n, d > "/dev/stderr" }' > "$tmp" 2> "$tmp.stat" || { rm -f "$tmp" "$tmp.stat"; return 1; }
    mv -f "$tmp" "$WARP_LISTS_DIR/devices.txt" && chmod 644 "$WARP_LISTS_DIR/devices.txt"
    cat "$tmp.stat"; rm -f "$tmp.stat"
    warp_ipset_reload_if_enabled
    return 0
}

warp_lists() {
    # TSV на stdout: name<TAB>entries<TAB>size<TAB>mtime (name без .txt).
    warp_lists_ensure_dir
    local f name entries size mtime
    for f in "$WARP_LISTS_DIR"/*.txt; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .txt)
        [ "$name" = "devices" ] && continue   # устройства — своя карточка, не список адресов
        entries=$(awk '{sub(/\r$/,""); gsub(/^[ \t]+|[ \t]+$/,"")} /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$/{n++} END{print n+0}' "$f")
        size=$(wc -c < "$f" | tr -d ' ')
        # busybox: date -r (no stat -c), see update_status_string
        mtime=$(date -r "$f" +%s 2>/dev/null)
        printf '%s\t%s\t%s\t%s\n' "$name" "${entries:-0}" "${size:-0}" "${mtime:-0}"
    done
}

# ---- upstream per-game lists (read-only) -------------------------------------
# These come from medvedeff-true/ru-gaming-blocklist, one file per game, and are
# refreshed wholesale by z2k-update-lists.sh. The panel may switch them on and
# off but must never edit them: the next refresh would overwrite the edit, and a
# setting that silently reverts is worse than no setting.
#
# The choice lives in lists/warp/.enabled (one name per line) rather than in
# file naming, for the same reason — a refresh recreates the files.
WARP_GAMES_DIR="${WARP_GAMES_DIR:-$WARP_LISTS_DIR/games}"
WARP_ENABLED_FILE="${WARP_ENABLED_FILE:-$WARP_LISTS_DIR/.enabled}"

warp_game_enabled() {
    [ -f "$WARP_ENABLED_FILE" ] || return 1
    grep -qxF "$1" "$WARP_ENABLED_FILE" 2>/dev/null
}

warp_games() {
    # TSV: name<TAB>entries<TAB>enabled(0|1)
    warp_lists_ensure_dir
    local f name entries
    for f in "$WARP_GAMES_DIR"/*.txt; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .txt)
        entries=$(awk '{sub(/\r$/,""); gsub(/^[ \t]+|[ \t]+$/,"")} /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$/{n++} END{print n+0}' "$f")
        printf '%s\t%s\t%s\n' "$name" "${entries:-0}" "$(warp_game_enabled "$name" && echo 1 || echo 0)"
    done
}

warp_game_toggle() {
    # ПОД ЗАМКОМ. Каждый чекбокс на странице WARP шлёт свой запрос, и человек
    # щёлкает их подряд: два запроса читают один и тот же .enabled, каждый
    # переписывает его целиком своим вариантом, и побеждает тот, кто закончил
    # вторым. Первый тумблер откатывается сам собой через секунду после нажатия.
    _list_lock "$WARP_ENABLED_FILE" || { echo "список занят, повторите" >&2; return 1; }
    _warp_game_toggle_locked "$@"; _rc=$?
    _list_unlock "$WARP_ENABLED_FILE"
    return $_rc
}

_warp_game_toggle_locked() {
    # warp_game_toggle <name> <0|1>
    local name="$1" want="$2" tmp
    warp_name_ok "$name" || { echo "invalid list name" >&2; return 1; }
    case "$want" in 0|1) ;; *) echo "value must be 0 or 1" >&2; return 1 ;; esac
    [ -f "$WARP_GAMES_DIR/$name.txt" ] || { echo "no such game list" >&2; return 1; }
    warp_lists_ensure_dir
    tmp="${WARP_ENABLED_FILE}.$$"
    # Rewrite without the name, then re-add it when switching on. Doing it in
    # that order makes a double-on idempotent instead of writing the name twice,
    # which would survive one toggle-off and look like a stuck switch.
    if [ -f "$WARP_ENABLED_FILE" ]; then
        grep -vxF "$name" "$WARP_ENABLED_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
    else
        : > "$tmp"
    fi
    [ "$want" = "1" ] && printf '%s\n' "$name" >> "$tmp"
    mv -f "$tmp" "$WARP_ENABLED_FILE" || { rm -f "$tmp"; echo "save failed" >&2; return 1; }
    chmod 644 "$WARP_ENABLED_FILE" 2>/dev/null
    return 0
}

warp_list_save() {
    # stdin: raw list text (textarea save or .txt import).
    # $1=name (без .txt), $2=mode replace|append|create (create = replace, но
    # отказывается затирать существующий файл — защита «нового списка» в UI
    # от гонки со stale-кэшем имён).
    # Per-line: trim + strip CR, keep comments (#...) as the user's annotations,
    # drop empty lines, validate address lines STRICTLY (mirrors the loader in
    # z2k-warp.sh warp_ipset_load — keep in sync): IPv4/CIDR, octets 0-255
    # WITHOUT leading zeros (ipset parses 010.1.2.3 as octal 8.1.2.3 and
    # doesn't parse 08.8.8.8 at all), first octet >= 1, prefix 1-32 (hash:net
    # rejects /0). One unparseable line aborts a whole `ipset restore` stream,
    # and v6 entries would silently do nothing (WARP routing has no v6 leg).
    # Output: "saved=N skipped_invalid=M" (N = valid address lines written).
    local name="$1" mode="${2:-replace}"
    warp_name_ok "$name" || { echo "invalid list name" >&2; return 1; }
    case "$mode" in replace|append|create) ;; *) echo "invalid mode" >&2; return 1 ;; esac
    warp_lists_ensure_dir
    [ -d "$WARP_LISTS_DIR" ] || { echo "lists dir unavailable" >&2; return 1; }
    local file="$WARP_LISTS_DIR/$name.txt"
    if [ "$mode" = "create" ]; then
        # Заявка на имя атомарна. Проверка [ -f ] и запись ниже разнесены во
        # времени на всё чтение тела, и два одновременных «создать» с одним
        # именем проходили её оба — второй молча затирал первый.
        # noclobber-перенаправление либо создаёт файл, либо падает; -C ставим в
        # подоболочке, иначе опция осталась бы висеть на всём запросе.
        #
        # Причину отказа различаем по факту: «имя занято» — это когда файл после
        # неудачи есть. Иначе создать не дали (RO-раздел, нет места, права), и
        # сообщать про занятое имя тут — врать; человек ищет чужой список, а
        # чинить надо раздел.
        local _mkerr
        _mkerr=$( ( set -C; : > "$file" ) 2>&1 ) || {
            if [ -e "$file" ]; then
                echo "list already exists" >&2
            else
                echo "не удалось создать список: ${_mkerr:-нет доступа к $WARP_LISTS_DIR}" >&2
            fi
            return 1
        }
    fi
    # $$-suffixed temps: concurrent CGI saves of the same list must not share
    # scratch files (lighttpd mod_cgi runs requests in parallel).
    local raw="$file.z2k-raw.$$" tmp="$file.z2k-new.$$"

    cat > "$raw" || { rm -f "$raw"; _warp_create_abort "$mode" "$file"; echo "read body failed" >&2; return 1; }
    awk '
# --- z2k warp address filter (canonical; keep byte-identical in all 3 copies) ---
function z2k_warp_addr_ok(s,   ip, h, o) {
    if (s !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/) return 0
    ip = s
    if (split(s, h, "/") == 2) ip = h[1]
    # No width cap. There was one at /10, on the reasoning that no game lives on
    # a /8 — but the blocks it cut are 3.0.0.0/8 and 15.0.0.0/8, i.e. Amazon,
    # which is exactly what people switch WARP on for. /0 is still impossible:
    # the grammar above only accepts prefixes 1-32.
    split(ip, o, ".")
    if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return 0
    if (o[1] == 10 || o[1] == 127 || o[1] >= 224) return 0
    if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 0
    if (o[1] == 169 && o[2] == 254) return 0
    if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 0
    if (o[1] == 192 && o[2] == 168) return 0
    if (o[1] == 192 && o[2] == 0 && (o[3] == 0 || o[3] == 2)) return 0
    if (o[1] == 198 && (o[2] == 18 || o[2] == 19)) return 0
    if (o[1] == 198 && o[2] == 51 && o[3] == 100) return 0
    if (o[1] == 203 && o[2] == 0 && o[3] == 113) return 0
    return 1
}
# --- end z2k warp address filter ---
        {
            sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
            if ($0 == "") next
            if ($0 ~ /^#/) { print; next }
            if (z2k_warp_addr_ok($0)) print
        }' "$raw" > "$tmp" || { rm -f "$raw" "$tmp"; _warp_create_abort "$mode" "$file"; echo "sanitize failed" >&2; return 1; }

    local total saved skipped
    total=$(awk '{sub(/\r$/,""); gsub(/^[ \t]+|[ \t]+$/,"")} $0 != "" && $0 !~ /^#/ {n++} END{print n+0}' "$raw")
    saved=$(awk '$0 !~ /^#/ && $0 != "" {n++} END{print n+0}' "$tmp")
    skipped=$((total - saved))
    rm -f "$raw"

    if [ "$mode" = "append" ]; then
        touch "$file" 2>/dev/null
        # Файл мог остаться без завершающего перевода строки (правка руками,
        # импорт со стороны): без этого 1.2.3.4 и дописанный 5.6.7.8 склеиваются
        # в 1.2.3.45.6.7.8 — панель рапортует saved=1, а загрузчик ipset и
        # счётчик записей видят НОЛЬ валидных адресов, пропадают оба.
        _list_end_nl "$file"
        cat "$tmp" >> "$file" || { rm -f "$tmp"; echo "write failed" >&2; return 1; }
    else
        # Подмена целиком, а не `cat "$tmp" > "$file"`: cat СНАЧАЛА обнуляет
        # цель, и обрыв питания или ENOSPC на середине превращал список из 18k
        # адресов в пустой, после чего warp_ipset_reload_if_enabled заливал
        # пустой ipset. Заявку create (noclobber выше) rename не снимает: имя не
        # освобождается ни на мгновение, оно лишь начинает указывать на новый
        # inode, и параллельный create по-прежнему упирается в занятое имя.
        _file_replace "$file" "$tmp" || { _warp_create_abort "$mode" "$file"; echo "write failed" >&2; return 1; }
    fi
    rm -f "$tmp"
    chmod 644 "$file" 2>/dev/null || true
    warp_ipset_reload_if_enabled
    printf 'saved=%d skipped_invalid=%d\n' "${saved:-0}" "${skipped:-0}"
}

_warp_create_abort() {
    # Освободить заявленное create-именем пустое место, если тело так и не
    # записалось: иначе повторная попытка упрётся в «список уже существует»
    # на файле, которого пользователь никогда не видел.
    [ "$1" = "create" ] && rm -f "$2"
    return 0
}

warp_list_read_path() {
    # Валидация имени + печать пути файла (для raw-отдачи в api.sh).
    local name="$1"
    warp_name_ok "$name" || { echo "invalid list name" >&2; return 1; }
    local file="$WARP_LISTS_DIR/$name.txt"
    [ -f "$file" ] || return 2
    printf '%s' "$file"
}

warp_list_delete() {
    local name="$1"
    warp_name_ok "$name" || { echo "invalid list name" >&2; return 1; }
    local file="$WARP_LISTS_DIR/$name.txt"
    # Удаление ИДЕМПОТЕНТНО: несуществующий список — это уже требуемый
    # результат, а не ошибка. Повторный клик по «удалить» (панель успевает
    # отправить два запроса) не должен показывать «не получилось» на списке,
    # которого и так больше нет.
    [ -f "$file" ] || return 0
    rm -f "$file" || { echo "delete failed" >&2; return 1; }
    warp_ipset_reload_if_enabled
    return 0
}

# --- tunnel (Telegram) ---

tunnel_pid() {
    # Match by cmdline contains `--listen=:1443` — S97z2k-http-tunnel
    # уs eventually runs the SAME tg-mtproxy-client binary but with
    # `--listen=:1444` (cdnbase tunnel). Без фильтра `pgrep -f tg-mtproxy-client`
    # сматчит S97 sibling и /status report'ит tg-tunnel.running=true даже
    # когда S98 daemon реально остановлен. Field-bug 2026-05-24 (юзер
    # отключал TG-туннель, badge показывал «ВКЛЮЧЁН»).
    pgrep -f "tg-mtproxy-client .*--listen=:1443" 2>/dev/null | head -1
}

tunnel_enable() {
    # Clear user-disabled flag before starting so the watchdog resumes
    # auto-restarting on real crashes.
    local cfg="${ZAPRET2_DIR}/config"
    if [ -f "$cfg" ]; then
        if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg"; then
            echo "Снимаю флаг TG_PROXY_USER_DISABLED → 0 в /opt/zapret2/config"
            sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=0/' "$cfg"
        fi
    fi
    if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
        echo "Запускаю S98tg-tunnel..."
        /opt/etc/init.d/S98tg-tunnel start 2>&1
    else
        echo "tunnel init script missing" >&2
        return 1
    fi
    # cdnbase-туннель (:1444) — тот же бинарник и та же пользовательская
    # сущность, поэтому включается и выключается вместе с телеграмным.
    if [ -x "/opt/etc/init.d/S97z2k-http-tunnel" ]; then
        echo "Запускаю S97z2k-http-tunnel (cdnbase)..."
        /opt/etc/init.d/S97z2k-http-tunnel start 2>&1
    fi
    echo "Туннель запущен."
}

tunnel_disable() {
    # Set user-disabled marker BEFORE stopping so the watchdog (fired
    # by z2k-scheduler every ~minute) sees the flag and respects the
    # user's intent instead of resurrecting the daemon ~3 min later.
    # Output verbose так чтобы svc_action_async log показывал
    # реальный прогресс, не «пустую секцию между разделителями».
    local cfg="${ZAPRET2_DIR}/config"
    if [ -f "$cfg" ]; then
        if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg"; then
            echo "Устанавливаю TG_PROXY_USER_DISABLED=1 в /opt/zapret2/config"
            sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=1/' "$cfg"
        else
            echo "Добавляю TG_PROXY_USER_DISABLED=1 в /opt/zapret2/config"
            echo "TG_PROXY_USER_DISABLED=1" >> "$cfg"
        fi
    else
        echo "Конфиг /opt/zapret2/config не найден — флаг не записан"
    fi
    if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
        echo "Останавливаю S98tg-tunnel..."
        /opt/etc/init.d/S98tg-tunnel stop 2>&1
    else
        echo "Init-скрипт S98tg-tunnel не найден — пропускаю"
    fi
    # И cdnbase-туннель (:1444): один бинарник, одна сущность для человека.
    # Раньше он оставался жить (~8 МБ) — со стороны это выглядело как «выключил
    # туннель, а процесс tg-mtproxy-client всё равно висит в памяти».
    if [ -x "/opt/etc/init.d/S97z2k-http-tunnel" ]; then
        echo "Останавливаю S97z2k-http-tunnel (cdnbase)..."
        /opt/etc/init.d/S97z2k-http-tunnel stop 2>&1
    fi
    echo "Туннель остановлен, watchdog респектнёт флаг и не будет его перезапускать."
}

# --- async jobs ---

job_status() {
    local id="$1"
    local pid_file="/tmp/z2k-job-$id.pid"
    local exit_file="/tmp/z2k-job-$id.exit"
    local log_file="/tmp/z2k-job-$id.log"
    [ -f "$pid_file" ] || { echo "unknown"; return 1; }
    if [ -f "$exit_file" ]; then
        echo "done"
    else
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "running"
        else
            echo "done"
        fi
    fi
}

job_log() {
    local id="$1"
    local log_file="/tmp/z2k-job-$id.log"
    [ -f "$log_file" ] || return 0
    local size body
    size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ')
    if [ "${size:-0}" -le 16384 ] 2>/dev/null; then
        cat "$log_file"
        return 0
    fi
    # Резать по границе БАЙТА нельзя: логи русские, и разрез посреди UTF-8
    # последовательности даёт битый байт в ответе с charset=utf-8 — response.json()
    # во фронте бросает исключение, и модалка живого лога виснет намертво на любой
    # задаче длиннее лимита (переустановка — всегда длиннее). Первую строку среза
    # выбрасываем целиком: только она может быть обрезана.
    body=$(tail -c 16384 "$log_file" | tail -n +2)
    if [ -n "$body" ]; then
        printf '%s\n' "$body"
        return 0
    fi
    # Вырожденный случай: в последних 16 КБ нет ни одного перевода строки —
    # прогресс идёт через \r (curl, opkg), и вся отдача это одна строка.
    # Выбрасывать нечего, поэтому сдвигаем сам срез вправо до начала символа:
    # считаем, сколько продолжающих байт UTF-8 (10xxxxxx) стоит в его начале, и
    # берём на столько байт меньше. Иначе в ответ снова уезжает обрубок
    # последовательности и модалка виснет ровно так же.
    # Считаем продолжающие байты БЕЗ od: BusyBox знает у него только
    # -abcdeFfhiloxsv, а здесь стояло `od -An -N3 -tu1`. На роутере это давало
    # `invalid option -- 'A'` в закрытый stderr, skip всегда выходил нулём — то
    # есть починка не работала ни разу и модалка живого лога висла ровно так же,
    # как до неё. Тот же класс, что issue #43.
    #
    # tr -d '\200-\277' выбрасывает продолжающие байты UTF-8: если байт после
    # этого исчез — он был продолжающим. Диапазоны busybox tr понимает
    # (проверено на роутере), в отличие от опций od.
    local skip=0 _i _b
    for _i in 1 2 3; do
        _b=$(tail -c 16384 "$log_file" | dd bs=1 skip=$((_i - 1)) count=1 2>/dev/null \
             | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
        [ "${_b:-1}" = "0" ] || break
        skip=$_i
    done
    tail -c $((16384 - skip)) "$log_file"
}

job_exit_code() {
    local id="$1"
    cat "/tmp/z2k-job-$id.exit" 2>/dev/null || echo ""
}

# --- diag (Phase 3) ---
#
# Runs z2k-diag.sh in full mode. The raw output is a plain-text multi-section
# report designed for copy-paste. API caller embeds it as a JSON string and
# the UI renders it inside a <pre> block.

diag_run() {
    local diag="$ZAPRET2_DIR/z2k-diag.sh"
    if [ ! -x "$diag" ]; then
        echo "(z2k-diag.sh not installed — reinstall z2k to get it)"
        return 0
    fi
    # $1 = "report" → полные хвосты логов, для отдачи файлом. Без аргумента —
    # компактная сводка, которую вставляют в сообщение целиком.
    # Код возврата ПРОПАГИРУЕМ. Раньше он терялся здесь, и оба маршрута API
    # отдавали оборванный отчёт как успешный: при set -u, kill/OOM или битом
    # скрипте человек получал правдоподобный обрезок и нёс его в поддержку как
    # полную картину.
    if [ "${1:-}" = "report" ]; then
        sh "$diag" --report 2>&1
    else
        sh "$diag" 2>&1
    fi
}

# Доехал ли отчёт до конца. Полная форма (--report) печатает маркер последней
# строкой; его отсутствие означает обрыв даже там, где код возврата нулевой
# (например, скрипт убили сигналом на середине пайпа).
diag_is_complete() {
    printf '%s' "$1" | grep -q '=== end of diag ===' 2>/dev/null
}

# --- rotator state (Phase 3) ---
#
# /opt/zapret2/extra_strats/cache/autocircular/state.tsv is a tab-separated
# file maintained by z2k-autocircular.lua. Format:
#   key\thost\tstrategy\tts
# Lines starting with # are comments (header). Empty lines are skipped.

STATE_FILE="${STATE_FILE:-$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv}"
# Fallback snapshot the lua also writes (RAM-disk; survives a RO/full /opt).
# It must be cleaned in lockstep with the primary — load_state() merges both on
# the next restart with newer-ts winning, so a stale fallback row would
# otherwise resurrect a host the operator just deleted.
STATE_FILE_FALLBACK="${STATE_FILE_FALLBACK:-/tmp/z2k-autocircular-state.tsv}"

state_read() {
    # Display-truth: read the SAME merged view the persist bridge actually writes
    # to — primary (/opt) AND the /tmp fallback, newer-ts wins per (key,host). On
    # a read-only /opt the bridge writes ONLY the fallback, so reading just the
    # primary would show stale/empty data while the live truth is in /tmp.
    local pf='' ff=''
    [ -f "$STATE_FILE" ] && pf="$STATE_FILE"
    [ -f "$STATE_FILE_FALLBACK" ] && ff="$STATE_FILE_FALLBACK"
    [ -z "$pf" ] && [ -z "$ff" ] && return 0
    awk -F'\t' '!/^#/ && NF>=3 {
        k=$1 FS $2; t=($4=="")?0:$4+0
        if (!(k in seen) || t>=ts[k]) { ts[k]=t; seen[k]=1; row[k]=$0 }
    } END { for (k in row) print row[k] }' $pf $ff 2>/dev/null
}

# Return 0 if $1 contains ONLY characters from the tr-set $2, else 1.
# Uses `tr -d`, NOT a `*[!...]*` glob: busybox ash (the router shell) mis-parses
# a '|' inside a bracket expression (treats it as alternation), so the negated
# glob silently ACCEPTS everything — verified on-device 2026-06-08. tr evaluates
# the set correctly on busybox/dash/bash alike.
_chars_ok() {
    [ -z "$(printf '%s' "$1" | tr -d "$2" 2>/dev/null)" ]
}

# Remove one row by host+key from a single state file.
# Caller has already validated key/host. No-op if the file is absent.
_state_delete_one_file() {
    local file="$1" key="$2" host="$3"
    [ -f "$file" ] || return 0
    # Use awk field-equality, NOT a regex grep -v — host literals contain "."
    # which is the ERE wildcard, so a regex match for foo.example.com would
    # also drop foo-example-com and friends from a neighbouring rotator key.
    # Even though the caller's sanitiser rejects non-DNS chars, the wildcard
    # semantics inside the regex itself still over-match legitimately-named
    # hosts that differ only by punctuation.
    local tmp="$file.z2k-new.$$"
    awk -F'\t' -v key="$key" -v host="$host" '
        ($1 == key && $2 == host) { next }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    _file_replace "$file" "$tmp"
}

# Delete one row by host+key. Host and key together uniquely identify a row.
#
# No service restart: z2k-state-persist.lua reconciles external edits to
# state.tsv against the live rotator within ~2s (reconcile_external_edits) — a
# deleted host has its in-RAM rotation reset to strategy 1 on its next packet,
# so the "× resets to the first strategy" semantics apply live, without bouncing
# nfqws. We clean BOTH the primary and the /tmp fallback so a later restart's
# merge can't revive the row.
state_delete() {
    local key="$1" host="$2"
    [ -z "$key" ] && { echo "key required" >&2; return 1; }
    [ -z "$host" ] && { echo "host required" >&2; return 1; }
    # Sanitize: key is [a-z0-9_], host is letters/digits/dots/dashes plus "|"
    # for the per-address-family rotation suffix (host|4 / host|6, fork r5+).
    _chars_ok "$key"  'a-zA-Z0-9_'   || { echo "bad key" >&2; return 1; }
    _chars_ok "$host" 'a-zA-Z0-9.|-' || { echo "bad host" >&2; return 1; }
    # Замок на первичный файл: демон пишет оба, и одного общего рубежа хватает,
    # чтобы наша правка не разошлась с его снимком.
    _state_lock "$STATE_FILE" || { echo "state busy" >&2; return 1; }
    _state_delete_one_file "$STATE_FILE" "$key" "$host" || { _state_unlock "$STATE_FILE"; return 1; }
    _state_delete_one_file "$STATE_FILE_FALLBACK" "$key" "$host" || { _state_unlock "$STATE_FILE"; return 1; }
    _state_unlock "$STATE_FILE"
}

# Wipe ALL rotator rows from both state files (header kept, inode preserved by
# truncate-in-place). Same live semantics as the per-row × delete: on its next
# packet z2k-state-persist.lua's reconcile resets every host to strategy 1 (its
# write path won't resurrect rows gone from a readable disk), clearing any freeze
# too — no service restart. Both primary and /tmp fallback are wiped so a later
# restart's merge can't revive anything.
state_clear_all() {
    local _f _rc=0
    _state_lock "$STATE_FILE" || { echo "state busy" >&2; return 1; }
    for _f in "$STATE_FILE" "$STATE_FILE_FALLBACK"; do
        [ -f "$_f" ] || continue
        if ! printf '# z2k autocircular state (persisted circular nstrategy)\n# key\thost\tstrategy\tts\tmode\n' > "$_f"; then
            _rc=1; break
        fi
        chmod 644 "$_f" 2>/dev/null || true
    done
    _state_unlock "$STATE_FILE"
    return $_rc
}

# Upsert one row (key,host) with strategy+mode+ts into a single state file,
# creating it (with header) if absent. Preserves all other rows; field-equality
# replace (NOT regex — see _state_delete_one_file for why).
# Caller has validated all fields.
_state_set_one_file() {
    local file="$1" key="$2" host="$3" strat="$4" mode="$5" ts="$6"
    local dir; dir=$(dirname "$file")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
    if [ ! -f "$file" ]; then
        printf '# z2k autocircular state (persisted circular nstrategy)\n# key\thost\tstrategy\tts\tmode\n' \
            > "$file" 2>/dev/null || return 1
        # Файл создали мы — задаём права явно. Дальше _file_replace переносит на
        # новый inode права и владельца ЦЕЛИ, то есть режим от umask lighttpd
        # закрепился бы навсегда, а читать этот файл nfqws2 должен от nobody.
        chmod 644 "$file" 2>/dev/null
    fi
    local tmp="$file.z2k-new.$$"
    # Шестая колонка (подобранное имя для белого SNI) переносится из прежней
    # строки. Она принадлежит ротатору, а не панели: панель про имя ничего не
    # знает и знать не должна. Без переноса любой клик по замку или по номеру
    # стратегии стирал бы находку, и перебор — до двух десятков неудачных
    # загрузок у человека на глазах — начинался бы заново.
    awk -F'\t' -v key="$key" -v host="$host" -v strat="$strat" -v mode="$mode" -v ts="$ts" '
        BEGIN { OFS="\t"; sni = "" }
        ($1 == key && $2 == host) { if ($6 != "") sni = $6; next }  # drop prior row, keep its name
        { print }
        END { if (sni != "") print key, host, strat, ts, mode, sni
              else            print key, host, strat, ts, mode }
    ' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    _file_replace "$file" "$tmp" || return 1
    return 0
}

# Метка времени строки состояния означает «когда эта стратегия стала текущей»,
# а не «когда по строке последний раз кликнули». Lua уже держит это правило:
# z2k-state-persist.lua обновляет ts ТОЛЬКО при смене номера
# (`if prev == n then return false end`). Панель это правило нарушала: замок и
# разморозка переписывали ts всегда, и возраст страты обнулялся от каждого
# клика — человек переставал видеть, сколько она на самом деле продержалась.
#
# Возвращаем прежнюю метку, если номер стратегии не изменился. Смотрим ту же
# склейку двух файлов, что читают все остальные (побеждает более свежая метка),
# иначе панель считала бы возраст не по тому, что показывает.
_state_prev_ts() {
    local key="$1" host="$2" strat="$3" f
    for f in "$STATE_FILE" "$STATE_FILE_FALLBACK"; do
        [ -f "$f" ] || continue
        awk -F'\t' -v k="$key" -v h="$host" '
            $1 == k && $2 == h && $4 ~ /^[0-9]+$/ { print $3 "\t" $4 }
        ' "$f" 2>/dev/null
    done | awk -F'\t' -v strat="$strat" '
        # Побеждает самая свежая строка — то же правило, что у читателей.
        $2 + 0 > best + 0 { best = $2; beststrat = $1 }
        END {
            # Номер тот же — метку сохраняем. Другой (или строки не было) —
            # печатаем пусто, и вызывающий поставит текущее время.
            if (best != "" && beststrat + 0 == strat + 0) print best
        }
    '
}

# Set (pin / manually select) a rotator row's strategy + mode.
#   mode=auto   → adopt this strategy live; rotation continues (skip a broken
#                 strategy, or test one without locking it).
#   mode=frozen → adopt this strategy live AND stop the rotator from changing it.
# The lua reconcile (reconcile_external_edits, ~2s) adopts the edit into the live
# rotator; the freeze gate then pins a frozen row every packet. Writes BOTH the
# primary and the /tmp fallback so the merged (newer-ts wins) view the lua reads
# picks it up regardless of which file backs the live state. Success = at least
# one write landed (a read-only /opt still has the writable /tmp fallback).
state_set() {
    local key="$1" host="$2" strat="$3" mode="$4"
    [ -z "$key" ]  && { echo "key required" >&2; return 1; }
    [ -z "$host" ] && { echo "host required" >&2; return 1; }
    [ -z "$mode" ] && mode="auto"
    _chars_ok "$key"  'a-zA-Z0-9_'   || { echo "bad key" >&2; return 1; }
    _chars_ok "$host" 'a-zA-Z0-9.|-' || { echo "bad host" >&2; return 1; }
    case "$strat" in ''|*[!0-9]*) echo "bad strategy" >&2; return 1 ;; esac
    [ "$strat" -ge 1 ] 2>/dev/null || { echo "strategy must be >=1" >&2; return 1; }
    case "$mode" in auto|frozen) ;; *) echo "bad mode" >&2; return 1 ;; esac
    # Метку сохраняем, если стратегия та же — см. _state_prev_ts выше.
    local ts; ts=$(_state_prev_ts "$key" "$host" "$strat")
    [ -n "$ts" ] || ts=$(date +%s 2>/dev/null || echo 0)
    local ok=1
    # Тот же общий с Lua замок: пин и заморозка — это как раз то намерение
    # оператора, которое проигранная гонка стирает молча.
    _state_lock "$STATE_FILE" || { echo "state busy" >&2; return 1; }
    _state_set_one_file "$STATE_FILE" "$key" "$host" "$strat" "$mode" "$ts" && ok=0
    _state_set_one_file "$STATE_FILE_FALLBACK" "$key" "$host" "$strat" "$mode" "$ts" && ok=0
    _state_unlock "$STATE_FILE"
    return $ok
}

# Parse the per-category strategy pool size (distinct strategy=N tags under each
# circular key). Reads the STABLE config file ($CONFIG_FILE) — the exact args
# nfqws2 runs — NOT the live /proc cmdline. The cmdline is briefly empty while
# nfqws2 restarts (e.g. right after an update), which made /pools return nothing
# → the webpanel then capped every strategy dropdown at the row's current
# rotation position instead of the full category pool ("после обновления видно
# только сколько настрочила ротация"). The config file survives the restart and
# carries the identical pools. Falls back to the live cmdline only if the config
# is unreadable. Emits TSV "key<TAB>count".
pools_read() {
    local src="" pid
    if [ -r "$CONFIG_FILE" ]; then
        # ТОЛЬКО значение NFQWS2_OPT, а не весь конфиг.
        #
        # Раньше сюда шёл файл целиком, и это работало лишь потому, что в
        # комментариях случайно не встречалось нужных токенов. Теперь в строке
        # опций есть блок --template, и достаточно одного слова «--template» в
        # комментарии, чтобы разбор посчитал шаблоном первый настоящий профиль
        # и /pools потерял целый пул.
        src=$(sed -n '/^NFQWS2_OPT="/,/^"[[:space:]]*$/p' "$CONFIG_FILE" 2>/dev/null | sed '1d;$d')
    fi
    if [ -z "$src" ]; then
        pid=$(pidof nfqws2 2>/dev/null | tr ' ' '\n' | head -1)
        [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && src=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    fi
    [ -n "$src" ] || return 0
    printf '%s\n' "$src" | awk '
    { all = all " " $0 }                         # accumulate (config is multi-line)
    # Арсенал объявляется один раз (--template=имя) и подставляется в профили
    # (--import=имя). Считать стратегии по сырым токенам после этого нельзя:
    # у рабочего профиля есть свой circular:key=, а инстансы со strategy=N
    # лежат в блоке шаблона — без раскрытия каждый пул показал бы ноль.
    function expand(body, depth,   i, n, p, out, nm) {
        if (depth > 8) return body
        n = split(body, p, " ")
        out = ""
        for (i = 1; i <= n; i++) {
            if (p[i] == "") continue
            if (p[i] ~ /^--import=/) {
                nm = substr(p[i], 10)
                if (nm in TPL) { out = out " " expand(TPL[nm], depth + 1); continue }
            }
            out = out " " p[i]
        }
        return out
    }
    END {
        nb = split(all, blocks, / --new( |$)/)
        # Первый проход — шаблоны. Объявление всегда раньше импорта.
        for (b = 1; b <= nb; b++) {
            nm = ""; istpl = 0
            n = split(blocks[b], p, " ")
            for (i = 1; i <= n; i++) {
                if (p[i] == "--template") istpl = 1
                else if (p[i] ~ /^--template=/) { istpl = 1; nm = substr(p[i], 12) }
                else if (p[i] ~ /^--name=/ && nm == "") nm = substr(p[i], 8)
            }
            if (istpl && nm != "") { body = blocks[b]; gsub(/--template(=[^ ]*)?/, "", body); TPL[nm] = body }
            if (istpl) skip[b] = 1
        }
        # Второй — считаем стратегии по каждому рабочему профилю отдельно.
        for (b = 1; b <= nb; b++) {
            if (b in skip) continue
            n = split(expand(blocks[b], 0), toks, " ")
            ck = ""
            for (i = 1; i <= n; i++) {
                t = toks[i]
                if (t ~ /^--lua-desync=circular:/) {
                    if (match(t, /key=[a-z0-9_]+/)) ck = substr(t, RSTART+4, RLENGTH-4); else ck = ""
                }
                if (ck != "" && match(t, /:strategy=[0-9]+/)) {
                    s = substr(t, RSTART+10, RLENGTH-10)
                    kk = ck SUBSEP s
                    if (!(kk in seen)) { seen[kk] = 1; cnt[ck]++ }
                }
            }
        }
        for (k in cnt) print k "\t" cnt[k]
    }'
}


# --- debug flag (Phase 3) ---
#
# Touch/rm /opt/zapret2/extra_strats/cache/autocircular/debug.flag. When
# present, z2k-autocircular.lua writes per-packet decisions to
# /opt/zapret2/extra_strats/cache/autocircular/debug.log. Useful for
# debugging silent-stuck rotator behavior.

debug_flag_path() {
    printf '%s' "$ZAPRET2_DIR/extra_strats/cache/autocircular/debug.flag"
}

debug_flag_state() {
    if [ -f "$(debug_flag_path)" ]; then
        printf '1'
    else
        printf '0'
    fi
}

debug_flag_set() {
    local want="$1"
    local p
    p=$(debug_flag_path)
    mkdir -p "$(dirname "$p")" 2>/dev/null
    if [ "$want" = "1" ]; then
        touch "$p" 2>/dev/null && return 0
        return 1
    else
        rm -f "$p" 2>/dev/null
        return 0
    fi
}

# --- auto-update status / apply ---
#
# UI surfaces the same auto-update mechanism that z2k-scheduler runs at
# 02:00 — the user sees "available: <tag>" and can trigger apply manually
# instead of waiting for the nightly window. The check path is cached on
# disk (5 min) so dashboard refreshes don't hammer raw.githubusercontent.

AU_TAG_FILE="${AU_TAG_FILE:-$ZAPRET2_DIR/.z2k-installed-tag}"
AU_MANIFEST_CACHE="${AU_MANIFEST_CACHE:-/tmp/z2k-au-manifest.json}"
AU_MANIFEST_CACHE_TTL="${AU_MANIFEST_CACHE_TTL:-300}"
# Негативный кэш. Неудача не оставляла на диске ничего, TTL-гейт выше не
# срабатывал, и КАЖДАЯ загрузка дашборда заново гоняла весь забег по зеркалам —
# ровно на тех сетях, ради которых зеркала и появились.
AU_MANIFEST_FAIL_STAMP="${AU_MANIFEST_FAIL_STAMP:-${AU_MANIFEST_CACHE}.fail}"
AU_MANIFEST_FAIL_TTL="${AU_MANIFEST_FAIL_TTL:-300}"
# Потолок на ВСЮ попытку. z2k_fetch — это до четырёх хопов, каждый со своими
# --connect-timeout 10 --max-time 180 (lib/utils.sh), то есть до ~12 минут
# синхронного CGI на GET /update/status, который фронт дёргает при каждой
# инициализации дашборда.
AU_MANIFEST_FETCH_TIMEOUT="${AU_MANIFEST_FETCH_TIMEOUT:-20}"
# Чем тянули манифест в последний раз: mirrors (z2k_fetch со всеми зеркалами)
# или curl (деградация — lib/utils.sh не нашлась). api.sh читает это через
# update_manifest_source и показывает человеку: stderr отсюда он глушит, и
# «деградация не молча» иначе остаётся обещанием.
AU_MANIFEST_SOURCE_FILE="${AU_MANIFEST_SOURCE_FILE:-${AU_MANIFEST_CACHE}.source}"
AU_SCRIPT="${AU_SCRIPT:-$ZAPRET2_DIR/z2k-auto-update.sh}"
AU_LOG_FILE="${AU_LOG_FILE:-/opt/var/log/z2k-auto-update.log}"

update_installed_tag() {
    if [ -f "$AU_TAG_FILE" ]; then
        head -1 "$AU_TAG_FILE" 2>/dev/null | tr -d ' \r\n'
    else
        printf 'unknown'
    fi
}

# Get mtime of a file as a Unix timestamp. BusyBox `stat -c` doesn't exist
# on Entware (even /opt/bin/stat is BusyBox), but `date -r FILE +%s` does.
file_mtime() {
    [ -f "$1" ] || { echo 0; return; }
    date -r "$1" +%s 2>/dev/null || echo 0
}

# Refresh /tmp manifest cache when older than TTL (or force=1).
update_refresh_manifest() {
    local force="${1:-0}" age now mtime url tmp
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$force" != "1" ]; then
        if [ -s "$AU_MANIFEST_CACHE" ]; then
            mtime=$(file_mtime "$AU_MANIFEST_CACHE")
            age=$((now - mtime))
            [ "$age" -lt "$AU_MANIFEST_CACHE_TTL" ] && return 0
        fi
        # Недавняя неудача — в сеть не идём вовсе. Ручная кнопка «проверить»
        # (force=1) этот гейт минует: человек ждёт результата и знает, чего ждёт.
        if [ -f "$AU_MANIFEST_FAIL_STAMP" ]; then
            mtime=$(file_mtime "$AU_MANIFEST_FAIL_STAMP")
            age=$((now - mtime))
            if [ "$age" -lt "$AU_MANIFEST_FAIL_TTL" ]; then
                [ -s "$AU_MANIFEST_CACHE" ] && return 0
                return 1
            fi
        fi
    fi
    url="https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/UPDATES.json"
    # $$ в имени: mod_cgi выполняет запросы параллельно, общий temp двух
    # одновременных проверок — это подмена тела на полпути.
    tmp="${AU_MANIFEST_CACHE}.new.$$"
    if _update_fetch_manifest "$url" "$tmp" && _update_manifest_sane "$tmp"; then
        mv -f "$tmp" "$AU_MANIFEST_CACHE"
        rm -f "$tmp.etag" "$AU_MANIFEST_FAIL_STAMP"
        return 0
    fi
    rm -f "$tmp" "$tmp.etag"
    : > "$AU_MANIFEST_FAIL_STAMP" 2>/dev/null
    # Cache fallback — keep stale file if the fetch failed.
    [ -s "$AU_MANIFEST_CACHE" ] && return 0
    return 1
}

# Чем тянули манифест в последний раз: mirrors | curl | пусто (не пробовали).
# Для api.sh — единственный способ показать деградацию: stderr обработчиков он
# уводит в /dev/null.
update_manifest_source() {
    [ -f "$AU_MANIFEST_SOURCE_FILE" ] || { printf ''; return 0; }
    head -1 "$AU_MANIFEST_SOURCE_FILE" 2>/dev/null | tr -d ' \r\n'
}

# Манифест тянем той же z2k_fetch, что и весь проект (VPS-хоп -> raw -> jsdelivr
# -> gh-proxy -> ndmc-DNS), а не голым curl'ом на raw.githubusercontent: у
# ЦЕЛЕВОЙ аудитории проекта raw заблокирован, и панель показывала «обновлений
# нет» ровно там, где ночной апдейтер их прекрасно видит.
#
# utils.sh подключаем в ПОДоболочке: он безусловно переприсваивает
# ZAPRET2_DIR и соседей, а stdout здесь — тело HTTP-ответа CGI, туда не должно
# попасть ни байта постороннего.
_update_fetch_manifest() {
    local url="$1" dest="$2" utils="" d pid rc flag waited=0
    for d in "$ZAPRET2_DIR/lib" /tmp/z2k/lib; do
        [ -f "$d/utils.sh" ] && [ -z "$utils" ] && utils="$d/utils.sh"
    done
    if [ -z "$utils" ]; then
        printf 'curl\n' > "$AU_MANIFEST_SOURCE_FILE" 2>/dev/null
        echo "lib/utils.sh не найден: проверка обновлений идёт голым curl'ом мимо зеркал — на сети, где raw.githubusercontent заблокирован, панель будет уверять, что обновлений нет" >&2
        curl -fsSL --max-time 15 "$url" -o "$dest" 2>/dev/null
        return $?
    fi
    printf 'mirrors\n' > "$AU_MANIFEST_SOURCE_FILE" 2>/dev/null
    # Забег по зеркалам сам себя по времени не ограничивает, а мы синхронный CGI,
    # поэтому держим его на своём поводке: фоновый процесс + опрос маркера.
    # Маркер, а не `kill -0`: завершившийся, но ещё не собранный wait'ом ребёнок
    # остаётся зомби, и kill -0 по нему успешен — ждали бы полный таймаут даже
    # после мгновенной удачи. Код возврата кладём в маркер целиком собранным
    # (mv), чтобы не прочитать пустой файл на полпути.
    flag="${dest}.done.$$"
    rm -f "$flag" "$flag.part"
    # shellcheck disable=SC1090
    ( . "$utils"; z2k_fetch "$url" "$dest"; printf '%s' "$?" > "$flag.part"; mv -f "$flag.part" "$flag" ) \
        </dev/null >/dev/null 2>&1 &
    pid=$!
    while [ ! -f "$flag" ] && [ "$waited" -lt "$AU_MANIFEST_FETCH_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ -f "$flag" ]; then
        rc=$(cat "$flag" 2>/dev/null)
        case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    else
        _kill_tree "$pid"
        rc=1
    fi
    wait "$pid" 2>/dev/null
    rm -f "$flag" "$flag.part"
    return "$rc"
}

_kill_tree() {
    # Убить процесс вместе с прямыми потомками. Одного kill по $! мало: curl —
    # отдельный процесс, он переживает смерть подоболочки, ещё до трёх минут
    # держит соединение и в конце кладёт скачанное в наш temp, когда отказ уже
    # засчитан. PPID читаем из /proc: у busybox ps нет -o ppid, а pkill -P нет
    # вовсе. `read` — встроенная команда, обхода /proc она не удорожает.
    local pid="$1" p line rest kid
    for p in /proc/[0-9]*; do
        [ -r "$p/stat" ] || continue
        kid=${p#/proc/}
        read -r line < "$p/stat" 2>/dev/null || continue
        rest=${line#*") "}      # после имени процесса в скобках идут state ppid ...
        rest=${rest#* }
        [ "${rest%% *}" = "$pid" ] && kill -TERM "$kid" 2>/dev/null
    done
    kill -TERM "$pid" 2>/dev/null
    return 0
}

# Похоже ли скачанное на UPDATES.json. Прежняя проверка [ -s ] принимала любое
# непустое тело — HTML-заглушку провайдера, страницу ошибки зеркала — и дальше
# это кэшировалось на 5 минут и разбиралось как манифест.
_update_manifest_sane() {
    local f="$1"
    [ -s "$f" ] || return 1
    head -c 1 "$f" 2>/dev/null | grep -q '{' || return 1
    grep -q '"current"[[:space:]]*:[[:space:]]*"' "$f" 2>/dev/null || return 1
    grep -q '"history"[[:space:]]*:' "$f" 2>/dev/null || return 1
    return 0
}

update_manifest_current() {
    [ -s "$AU_MANIFEST_CACHE" ] || { printf ''; return; }
    sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AU_MANIFEST_CACHE" | head -1
}

# Count how many history entries appear AFTER installed_tag.
# Matches au_history_entries_after semantics in lib/auto_update.sh —
# history-order, not numeric.
update_behind_count() {
    local installed="$1"
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '0'; return; }
    [ -z "$installed" ] || [ "$installed" = "unknown" ] && { printf '0'; return; }
    awk -v inst="$installed" '
        /"v"[[:space:]]*:[[:space:]]*"/ {
            line = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            v = line
            if (found) { count++; next }
            if (v == inst) { found = 1 }
        }
        END {
            # count+0, не count: когда installed == current, ветка count++ ни разу
            # не выполняется, count остаётся неинициализированной и awk печатает
            # ПУСТУЮ строку. Сейчас это спасает только "${behind:-0}" у
            # вызывающего (api.sh) — без него в JSON уходит "behind":, .
            print (found ? count+0 : 0)
        }
    ' "$AU_MANIFEST_CACHE"
}

update_last_check_ts() {
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '0'; return; }
    file_mtime "$AU_MANIFEST_CACHE"
}

# Провалилась ли ПОСЛЕДНЯЯ попытка сходить за манифестом.
#
# Это единственное, что отличает «вы на актуальной версии» от «канал обновлений
# мёртв, а мы показываем позавчерашний кэш». update_refresh_manifest при отказе
# сети возвращает 0 и оставляет протухший кэш (иначе панель мигала бы ошибкой
# на каждом чихе связи) — то есть по её коду возврата отличить нельзя. Зато она
# оставляет метку неудачи; до 2026-08-08 эту метку не читал никто, и наружу
# не уходило ни одного признака. Человек видел «установлена актуальная версия»
# при полностью нерабочем обновлении.
update_last_fetch_failed() {
    [ -f "$AU_MANIFEST_FAIL_STAMP" ] && printf 'true' || printf 'false'
}

# Возраст последней УДАЧНОЙ проверки в секундах; -1 если удачных не было.
update_last_check_age() {
    local ts now
    ts=$(update_last_check_ts)
    [ "${ts:-0}" -gt 0 ] 2>/dev/null || { printf '%s' "-1"; return; }
    now=$(date +%s 2>/dev/null || echo 0)
    [ "$now" -gt "$ts" ] 2>/dev/null && printf '%s' "$((now - ts))" || printf '0'
}

# Extract history entries strictly newer than installed_tag, in
# history-file order. Output is a JSON array — entries are emitted
# verbatim (each one is a single-line JSON object in UPDATES.json), no
# field re-serialization. Returns "[]" when installed is unknown or
# nothing is pending.
update_pending_entries() {
    local installed="$1"
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '[]'; return; }
    if [ -z "$installed" ] || [ "$installed" = "unknown" ]; then
        printf '[]'
        return
    fi
    awk -v inst="$installed" '
        /"v"[[:space:]]*:[[:space:]]*"/ {
            v = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", v)
            sub(/".*/, "", v)
            if (found) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                sub(/,$/, "", line)
                entries[++n] = line
                next
            }
            if (v == inst) { found = 1 }
        }
        END {
            printf "["
            for (i=1; i<=n; i++)
                printf "%s%s", (i>1?",":""), entries[i]
            printf "]"
        }
    ' "$AU_MANIFEST_CACHE"
}

# Launch auto-update apply asynchronously, return job_id for /job?id=...
# polling. Output streams to /tmp/z2k-job-<id>.log so the UI can tail it via
# the existing job_log path. The real auto-update log at /opt/var/log/...
# is appended by au_log; we duplicate to the per-job temp log for the UI.
update_apply_async() {
    [ -x "$AU_SCRIPT" ] || { echo "auto-update script missing: $AU_SCRIPT" >&2; return 1; }
    job_reap
    local job_id
    job_id=$(date +%s)$$
    # Daemonize: close stdin and detach stdout/stderr from the CGI pipes.
    # Without `</dev/null >/dev/null 2>&1` on the subshell, the background
    # apply (and every grandchild like `curl`, `sh install`, `lighttpd`
    # restart) inherits fd 1/2 pointing at lighttpd's CGI response pipe.
    # lighttpd won't finalize the HTTP response until EVERY fd 1 holder
    # closes — which means apiPost hangs for the entire 1-2 min install,
    # the browser's confirm closes, and the modal never opens because
    # the response that carries job_id is still in flight. Innermost
    # `> log 2>&1` then overrides /dev/null with the actual job log
    # for the apply itself.
    # Z2K_AU_MANUAL=1 — a human pressed the button, so this apply runs even when
    # nightly auto-update is switched off.
    #
    # Z2K_AU_NO_JITTER=1 — the updater sleeps a deterministic 0..90min per-host
    # jitter to spread the fleet's nightly GitHub hits, and it decides "this is
    # the nightly run" from stdin not being a tty. This subshell closes stdin
    # (it has to — see the note above), so a button press was indistinguishable
    # from cron and could sit there sleeping for up to an hour and a half with an
    # empty job log. The menu path already passed this flag; the panel did not.
    # trap '' HUP — БЕЗ него обновление через панель обрывается на середине.
    #
    # busybox ash шлёт SIGHUP фоновым детям, когда обёртка завершается, а
    # CGI-обёртка обязана завершиться немедленно: она возвращает браузеру
    # job_id. Плюс сама установка перезапускает панель, под которой и живёт эта
    # задача. По умолчанию Go- и sh-процессы от HUP умирают, поэтому установка
    # падала где-то на пятом шаге из двенадцати — ровно там, где переезжает
    # дерево /opt/zapret2, — и роутер оставался с переименованным деревом и без
    # панели. Снаружи это выглядело как «панель ответила 404, чем кончилась
    # задача неизвестно»: сообщать о провале было уже некому и нечем.
    #
    # Приём тот же, что у S98tg-tunnel и S97z2k-http-tunnel (там он появился
    # из-за MIPS): ребёнок наследует игнорирование HUP. Замерено на роутере —
    # без строки задача умирает на HUP, с ней доживает до конца.
    (
        trap '' HUP
        env Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1 \
            sh "$AU_SCRIPT" apply > "/tmp/z2k-job-$job_id.log" 2>&1
        echo "$?" > "/tmp/z2k-job-$job_id.exit"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "/tmp/z2k-job-$job_id.pid"
    printf '%s' "$job_id"
}

# Проверка одного домена — то же, что пункт [Y] в терминальном меню.
#
# ЧТО ЭТО. z2k-detect probe делает одну пробу домена мимо нашего обхода
# (raw-сокет с SO_MARK) и печатает, чем именно кончилась каждая стадия —
# DNS, TCP, TLS, HTTP, — плюс вердикт: блокирует ли DPI и есть ли домен в
# наших списках. Команда СТАТЕЛЕСС: не открывает состояние демона, ничего не
# пишет в списки и в discovered-domains.txt. Поэтому её безопасно дёргать из
# панели по кнопке.
#
# ПОЧЕМУ СИНХРОННО, БЕЗ МАШИНЕРИИ ЗАДАЧ. У пробы свой внутренний потолок в
# 1500 мс на стадию, а стадии идут параллельно — «worst-case latency from
# sum(timeouts) to max(timeouts)». Замерено на роутере: 0,18 с на
# несуществующем домене, 0,34 с на живом, 1,0 с на заблокированном, 3,2 с в
# худшем виденном случае. Заводить ради этого фоновую задачу с опросом —
# сложность без выигрыша.
#
# СТОРОЖ ВСЁ РАВНО ЕСТЬ. `timeout` на Entware отсутствует, а зависший CGI
# держит соединение и воркер lighttpd. Поэтому ждём сами и добиваем.
detect_probe_domain() {
    local domain="$1"
    local bin="${Z2K_DETECT_BIN:-/opt/sbin/z2k-detect}"

    # Проверка ТУТ, а не только на странице: панель без пароля доверяет всей
    # локальной сети, а значение уходит в командную строку. Набор символов тот
    # же, что у пункта [Y] в меню.
    case "$domain" in
        ""|*[!a-zA-Z0-9.-]*) echo "bad domain" >&2; return 2 ;;
    esac
    # 253 — потолок длины полного доменного имени.
    [ "${#domain}" -le 253 ] || { echo "domain too long" >&2; return 2; }

    [ -x "$bin" ] || { echo "z2k-detect not installed" >&2; return 3; }

    local out="/tmp/z2k-probe.$$"
    "$bin" probe "$domain" > "$out" 2>&1 &
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 20 ] && { kill -9 "$pid" 2>/dev/null; rm -f "$out"; echo "probe timeout" >&2; return 4; }
        sleep 1
    done
    wait "$pid" 2>/dev/null
    cat "$out"
    rm -f "$out"
    return 0
}

STRATEGY_PICK_OUT="${STRATEGY_PICK_OUT:-/tmp/z2k-strategy-pick.json}"

# Подбор стратегии под один домен — наш аналог blockcheck.
#
# ЧТО ЭТО. Замеряем, чем именно режут домен, и выводим готовую строку
# параметров. Не перебор заранее заготовленных плеч: инструмент задаёт коробке
# несколько вопросов и собирает ответ из измеренных свойств. Обе команды
# СТАТЕЛЕСС — не пишут ни в конфиг, ни в списки, ни в состояние ротации.
# Человек сам решает, что делать со строкой.
#
# ДВА ПРОТОКОЛА, И ОБА ВСЕГДА. Человек, у которого не грузится сайт, не знает,
# каким протоколом ходит его браузер, а браузер ходит обоими: современный
# Chrome предпочитает HTTP/3 и откатывается на TCP молча и не всегда. Спрашивать
# у человека «TCP или QUIC» — перекладывать на него наш вопрос, поэтому меряем
# оба и показываем оба.
#
# ЗАМЕРЫ ИДУТ ПАРАЛЛЕЛЬНО, а не по очереди. Они независимы: разные протоколы,
# разные сокеты, разные пятёрки. Последовательный прогон удвоил бы ожидание
# ровно ни за чем.
#
# ЧАСТИЧНЫЙ УСПЕХ — ЭТО УСПЕХ. Хост может не обслуживать HTTP/3 вовсе, и тогда
# QUIC-замер честно скажет «резать нечего». Объявлять из-за этого провалившимся
# весь прогон нельзя: строка по второму протоколу человеку всё равно нужна.
#
# ПОЧЕМУ ЗАДАЧЕЙ, А НЕ СИНХРОННО, В ОТЛИЧИЕ ОТ detect_probe_domain ВЫШЕ. Та
# проба укладывается в секунды (замерено: 0,18–3,2 с), эта идёт до двух минут:
# зондов полтора десятка, и каждый повторяется трижды — вердикт выносится
# только при единогласии. Синхронный CGI на минуту занял бы воркер lighttpd.
#
# ЖУРНАЛ НЕ ДОЛЖЕН МОЛЧАТЬ. С -json на stdout уходит только итоговый JSON, а
# человек смотрит в журнал задачи, чтобы понять, что работа идёт. Поэтому
# отбиваем такт сами.
strategy_pick_run() {
    local domain="$1" mode="${2:-tcp13}"
    # Прочерк — это «домена нет», его ставит вызывающий, чтобы позиция
    # аргументов не зависела от пустоты значения.
    [ "$domain" = "-" ] && domain=""
    local bin="${Z2K_DETECT_BIN:-/opt/sbin/z2k-detect}"

    # Проверка ТУТ, а не только на странице: панель без пароля доверяет всей
    # локальной сети, а значение уходит в командную строку.
    case "$mode" in
        tcp13|tcp12|mixed|quic|voice) ;;
        *) echo "неизвестный режим замера" >&2; return 2 ;;
    esac
    # Набор символов проверяем ВСЕГДА: значение уходит в командную строку, и
    # режим не должен решать, проверять его или нет. Пустой домен допустим
    # только у голоса — там его не существует.
    case "$domain" in
        *[!a-zA-Z0-9.-]*) echo "в имени домена есть недопустимые символы" >&2; return 2 ;;
    esac
    [ "${#domain}" -le 253 ] || { echo "слишком длинное имя домена" >&2; return 2; }
    if [ "$mode" != voice ] && [ -z "$domain" ]; then
        echo "не указан домен" >&2; return 2
    fi
    [ -x "$bin" ] || { echo "модуль замера не установлен" >&2; return 3; }

    rm -f "$STRATEGY_PICK_OUT"
    local tcp_out="/tmp/z2k-strategy-pick-tcp.$$"
    local quic_out="/tmp/z2k-strategy-pick-quic.$$"
    local voice_out="/tmp/z2k-strategy-pick-voice.$$"

    # РЕЖИМ ВЫБИРАЕТ ЧЕЛОВЕК, А НЕ МЫ ЗА НЕГО.
    #
    # Раньше замер всегда шёл по обоим протоколам, а подбор под старые
    # устройства включался по списку доменов. И то и другое — гадание: у одного
    # дома телевизор, у другого нет, одному важен браузер, другому приставка, и
    # сколько человек готов ждать, мы не знаем. Теперь он говорит сам, а мы
    # честно предупреждаем о цене.
    #
    # GODEBUG — тот же, что у службы: без него Go-бинарники падают на MIPS от
    # асинхронного вытеснения.
    local tcp_pid= quic_pid= voice_pid= limit=300
    case "$mode" in
        tcp13)
            echo "Замеряю $domain по TCP для современных устройств — браузеры, телефоны."
            echo "Это занимает до двух минут."
            GODEBUG=asyncpreemptoff=1 "$bin" classify -json -hello modern "${domain}:443" \
                > "$tcp_out" 2>/dev/null &
            tcp_pid=$!
            ;;
        tcp12)
            echo "Замеряю $domain по TCP для старых устройств — телевизоры, приставки."
            echo "Это занимает до двух минут."
            GODEBUG=asyncpreemptoff=1 "$bin" classify -json -hello legacy "${domain}:443" \
                > "$tcp_out" 2>/dev/null &
            tcp_pid=$!
            ;;
        mixed)
            echo "Замеряю $domain по TCP и подбираю приём, который возьмёт И современные"
            echo "устройства, И старые. Это занимает 3-5 минут: сперва ищем приём на одном"
            echo "приветствии, потом проверяем каждую находку на втором."
            limit=420
            GODEBUG=asyncpreemptoff=1 "$bin" classify -json -hello both "${domain}:443" \
                > "$tcp_out" 2>/dev/null &
            tcp_pid=$!
            ;;
        quic)
            echo "Замеряю $domain по QUIC — так ходят браузеры по HTTP/3."
            echo "Это занимает около минуты."
            GODEBUG=asyncpreemptoff=1 "$bin" quic -json "$domain" > "$quic_out" 2>/dev/null &
            quic_pid=$!
            ;;
        voice)
            echo "Замеряю голос Дискорда. Адрес беру из ИДУЩЕГО разговора: у голоса нет"
            echo "имени, которое можно вписать, сервер выдаётся на сессию."
            echo "Если разговор не начат — замер это честно скажет."
            limit=120
            GODEBUG=asyncpreemptoff=1 "$bin" voice -json > "$voice_out" 2>/dev/null &
            voice_pid=$!
            ;;
    esac

    local i=0
    while { [ -n "$tcp_pid" ] && kill -0 "$tcp_pid" 2>/dev/null; } ||
          { [ -n "$quic_pid" ] && kill -0 "$quic_pid" 2>/dev/null; } ||
          { [ -n "$voice_pid" ] && kill -0 "$voice_pid" 2>/dev/null; }; do
        i=$((i + 1))
        # Потолок свой на режим: смешанный честно дороже остальных, и общий
        # потолок либо резал бы его, либо был бы бессмысленно велик для прочих.
        if [ "$i" -gt "$limit" ]; then
            # СПЕРВА МЯГКО. Сырые зонды на время работы вешают правило iptables
            # и снимают его при закрытии соединения; kill -9 такой возможности
            # не даёт, и правило остаётся висеть в OUTPUT. Даём процессу
            # секунду на уборку и только потом добиваем.
            for _p in $tcp_pid $quic_pid $voice_pid; do kill "$_p" 2>/dev/null; done
            sleep 1
            [ -n "$tcp_pid" ] && kill -9 "$tcp_pid" 2>/dev/null
            [ -n "$quic_pid" ] && kill -9 "$quic_pid" 2>/dev/null
            [ -n "$voice_pid" ] && kill -9 "$voice_pid" 2>/dev/null
            rm -f "$tcp_out" "$quic_out" "$voice_out"
            echo "замер не уложился в отведённое время" >&2
            return 4
        fi
        [ $((i % 15)) = 0 ] && echo "  идёт замер, ${i} с"
        sleep 1
    done
    [ -n "$tcp_pid" ] && wait "$tcp_pid" 2>/dev/null
    [ -n "$quic_pid" ] && wait "$quic_pid" 2>/dev/null
    [ -n "$voice_pid" ] && wait "$voice_pid" 2>/dev/null

    if [ ! -s "$tcp_out" ] && [ ! -s "$quic_out" ] && [ ! -s "$voice_out" ]; then
        rm -f "$tcp_out" "$quic_out" "$voice_out"
        echo "замер не дал результата" >&2
        return 5
    fi

    # Форма ответа одна на все режимы: половина, которую не мерили, остаётся
    # null. Так странице не нужно знать, что именно запрашивали, — она рисует
    # то, что пришло.
    #
    # Склейка литералами, а не разбором: куски — JSON, выданный нашими же
    # бинарниками, и переписывать их шеллом значило бы завести второй формат,
    # который поедет вслед за первым.
    local all="/tmp/z2k-strategy-pick-all.$$"
    # Режим кладём в ответ: страница читает ПОСЛЕДНИЙ результат и без этого не
    # знала бы, что именно мерили, — подписала бы замер под старые устройства
    # как обычный TCP.
    printf '{"mode":"%s","tcp":' "$mode" > "$all"
    if [ -s "$tcp_out" ]; then cat "$tcp_out" >> "$all"; else printf 'null' >> "$all"; fi
    printf ',"quic":' >> "$all"
    if [ -s "$quic_out" ]; then cat "$quic_out" >> "$all"; else printf 'null' >> "$all"; fi
    printf ',"voice":' >> "$all"
    if [ -s "$voice_out" ]; then cat "$voice_out" >> "$all"; else printf 'null' >> "$all"; fi
    printf '}\n' >> "$all"
    rm -f "$tcp_out" "$quic_out" "$voice_out"
    mv -f "$all" "$STRATEGY_PICK_OUT"
    echo "Замер закончен за ${i} с."
    return 0
}

# Последний результат замера. Пусто — ни разу не запускали.
strategy_pick_last() {
    [ -s "$STRATEGY_PICK_OUT" ] && cat "$STRATEGY_PICK_OUT"
}

# Удаление z2k целиком, фоновой задачей.
#
# ОТЛИЧИЕ ОТ ВСЕХ ОСТАЛЬНЫХ ЗАДАЧ, И ОНО ГЛАВНОЕ: панель, из которой задачу
# запустили, входит в удаляемое. uninstall_zapret2 гасит S96z2k-webpanel и
# добивает lighttpd по маске — то есть сервер, отдавший этот ответ, перестанет
# существовать где-то в середине работы, и обратно не поднимется никогда.
# Поэтому:
#   * задача обязана пережить смерть своего родителя — отсюда trap '' HUP и
#     полная отвязка от CGI-конвейеров, ровно как у обновления;
#   * лог лежит в /tmp, а не в /opt/zapret2 — иначе он был бы стёрт вместе с
#     деревом ровно в тот момент, когда он единственный источник правды;
#   * фронт НЕ должен ждать возвращения панели. Для обновления ожидание
#     правильно, здесь оно означало бы «ждём вечно».
#
# Скрипт зовём по абсолютному пути из дерева, а не через /opt/bin/z2k: симлинк
# удаляется в процессе, и полагаться на него внутри собственного удаления
# нельзя.
uninstall_async() {
    local z2k_sh="${Z2K_SH:-$ZAPRET2_DIR/z2k.sh}"
    [ -x "$z2k_sh" ] || { echo "z2k script missing: $z2k_sh" >&2; return 1; }
    job_reap
    local job_id
    job_id=$(date +%s)$$
    (
        trap '' HUP
        env Z2K_UNINSTALL_CONFIRMED=1 \
            sh "$z2k_sh" uninstall > "/tmp/z2k-job-$job_id.log" 2>&1
        echo "$?" > "/tmp/z2k-job-$job_id.exit"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "/tmp/z2k-job-$job_id.pid"
    printf '%s' "$job_id"
}
