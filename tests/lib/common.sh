# tests/lib/common.sh — общее для тест-набора. Сорсится, не исполняется.
#
# ЗАЧЕМ ЭТОТ ФАЙЛ.
#
# 1. Z2K_TEST_SH. Локальный прогон не предсказывал вердикт GitHub. Тесты зовут
#    вложенные оболочки жёстко как `/bin/sh -c`, а /bin/sh — это bash на macOS
#    и dash на ubuntu-latest. Отличие не косметическое: под bash `. файл` с
#    синтаксической ошибкой в конце успевает выполнить всё до неё и тест
#    зеленеет, а под dash тот же файл не разбирается вовсе и переменные пусты.
#    Ровно так два набора (reasm, diag) были зелёными локально и красными в CI.
#    Подмена ВНЕШНЕГО интерпретатора (`dash tests/run_all.sh`) этого не лечила:
#    жёсткий /bin/sh внутри теста её игнорирует. Теперь диалект задаётся здесь
#    и наследуется всеми вложенными оболочками.
#
# 2. z2k_extract_block. Байт-в-байт одинаковый awk-экстрактор был скопирован в
#    двух тестах реинсталла, а третьей копией стал бы каждый новый.
#
# 3. z2k_write_curl_stub. Подставной curl с контрактом `-w '%{http_code}
#    %{time_connect}'` написан в наборе шесть раз. Расхождение копий стоит
#    дороже дублирования: стаб, печатающий одно поле там, где боевой код ждёт
#    два, даёт зелёный тест на коде, который в бою разбирает мусор.
#
# POSIX sh.

# Диалект вложенных оболочек. На роутере это BusyBox ash, в CI — dash;
# /bin/sh здесь только умолчание, а не утверждение о диалекте.
Z2K_TEST_SH="${Z2K_TEST_SH:-/bin/sh}"
export Z2K_TEST_SH

# Z2K_TEST_PATH — PATH для песочниц `env -i`.
#
# Наборы писали `env -i PATH="/usr/bin:/bin"` руками. На маке и на
# ubuntu-latest там coreutils, и всё работало. На Keenetic там НЕТ НИЧЕГО:
# /bin — это sh и одиннадцать демонов прошивки (ndm, ndmc, wind, tsmb-*),
# /usr/bin — пять посторонних бинарников (dropbearkey, iperf3, lpac,
# minidlna, uart_launcher). Ни grep, ни sed, ни cat, ни awk: всё в /opt.
#
# Песочница получалась пустой, проверяемый код не выполнял ни строчки, и
# прогон на роутере 2026-08-27 дал 87 красных проверок из 186 — ни одна из
# них не про ошибку в коде. Хуже того: до починки эти наборы физически не
# могли проверить роутер, ради которого написаны.
#
# Собираем из МЕСТ, ГДЕ УТИЛИТЫ ЛЕЖАТ НА САМОМ ДЕЛЕ. Изоляция при этом
# сохраняется: `env -i` по-прежнему выносит всё окружение, кроме PATH.
z2k_test_path() {
    _ztp=""
    for _ztu in sh grep sed awk cat od tr wc; do
        _ztd=$(command -v "$_ztu" 2>/dev/null) || continue
        # Встроенные в оболочку команды `command -v` отдаёт БЕЗ пути, и
        # `${x%/*}` вернул бы само имя — «printf» попадало в PATH как каталог.
        case "$_ztd" in /*) ;; *) continue ;; esac
        _ztd="${_ztd%/*}"
        case ":$_ztp:" in
            *":$_ztd:"*) ;;
            *) _ztp="${_ztp:+$_ztp:}$_ztd" ;;
        esac
    done
    printf '%s' "${_ztp:-/usr/bin:/bin}"
}
Z2K_TEST_PATH="${Z2K_TEST_PATH:-$(z2k_test_path)}"
export Z2K_TEST_PATH

# Z2K_TEST_FRAC_SLEEP — умеет ли хозяин `sleep 0.1`.
#
# Busybox НЕ умеет: его usage — `sleep [N]...`, дробь даёт «invalid number».
# Наборы писали `sleep 0.1 2>/dev/null || sleep 1`, и на роутере цикл из
# тридцати итераций растягивался с трёх секунд до тридцати — проверка
# «работа доживает до конца» читала результат, которого ещё не было.
if sleep 0.05 2>/dev/null; then Z2K_TEST_FRAC_SLEEP=1; else Z2K_TEST_FRAC_SLEEP=0; fi
export Z2K_TEST_FRAC_SLEEP

# z2k_test_stamp <дней_назад>
#
# Отметка времени для `touch -t`. Наборы писали
# `date -v-Nd … || date -d "-N days" …` — это BSD и GNU. Busybox не знает НИ
# ОДНОГО из двух: `-v` — «invalid option», `-d "-3 days"` — «invalid date».
# Подстановка отдавала пусто, touch молча не срабатывал, возраст установки
# оставался нулевым, и проверка «через трое суток ожидание кончается» краснела
# на роутере, не проверив ничего (замер 2026-08-27).
#
# Считаем в эпохе, а форматируем тем, что понимает хозяин: `-d @эпоха` —
# GNU и busybox, `-r эпоха` — BSD/macOS. Порядок важен: у busybox `-r` берёт
# ФАЙЛ, поэтому он обязан быть вторым.
z2k_test_stamp() {
    _zts=$(( $(date +%s) - ${1:-0} * 86400 ))
    date -d "@$_zts" '+%Y%m%d%H%M' 2>/dev/null \
        || date -r "$_zts" '+%Y%m%d%H%M' 2>/dev/null
}

# z2k_write_date_stub <путь>
#
# Подставной date: `+%s` сдвигается на $Z2K_TEST_NOW_SHIFT секунд вперёд, всё
# остальное — включая `date -r ФАЙЛ +%s` — отдаётся настоящему.
#
# ЗАЧЕМ. Наборы старили файлы через `touch -t`. Busybox touch этого НЕ УМЕЕТ:
# его usage — `touch [-ch] FILE...`, ни -t, ни -d, ни -r. Метка не ставилась,
# «просроченный замок» оставался свежим, и на роутере краснели проверки, ни
# одна из которых не про дефект.
#
# Прод меряет возраст как `now - date -r ФАЙЛ`, поэтому эквивалентно и
# портируемо сдвинуть now, а не mtime.
#
# Путь к настоящему date зашивается при создании: `command date` внутри стаба
# снова нашёл бы стаб (command обходит функции, но не PATH) — рекурсия.
z2k_write_date_stub() {
    _zdreal=$(command -v date)
    cat > "$1" <<STUBDATE
#!/bin/sh
if [ "\$1" = "+%s" ] && [ -n "\${Z2K_TEST_NOW_SHIFT:-}" ]; then
    printf '%s\\n' "\$(( \$($_zdreal +%s) + Z2K_TEST_NOW_SHIFT ))"
    exit 0
fi
exec $_zdreal "\$@"
STUBDATE
    chmod +x "$1"
}

# z2k_backdate <файл> <YYYYMMDDhhmm[.ss]>
#
# Ставит старую метку времени. Возвращает 1, если хозяин этого не умеет:
# busybox touch знает только `[-ch] FILE...` — ни -t, ни -d, ни -r.
#
# ПОДДЕЛЫВАТЬ НЕЧЕМ, И ЭТО НАДО ГОВОРИТЬ ВСЛУХ. Там, где прод меряет возраст
# как `now - date -r ФАЙЛ`, работает z2k_write_date_stub (сдвиг «сейчас»). Но
# `find -mmin` смотрит на РЕАЛЬНЫЕ часы, и обмануть его нечем: на busybox такую
# проверку остаётся честно пропустить, а не имитировать стабом самого find —
# иначе тест перестанет проверять то, ради чего написан.
z2k_backdate() {
    touch -t "$2" "$1" 2>/dev/null || return 1
}

# z2k_pct_bytes — читает stdin и печатает %XX для каждого БАЙТА.
#
# Наборы писали `od -An -tx1 -v`. Busybox знает у od только -abcdeFfhiloxsv:
# ни -A, ни -t, ни -v. Команда падала в закрытый stderr, подстановка выходила
# пустой — тот же класс, что issue #43.
#
# `od -b` есть и у busybox, и у GNU, и у BSD, и печатает одинаково: смещение в
# первом поле, дальше октальные байты. Октальное в шестнадцатеричное считаем
# руками: strtonum() — это gawk, у busybox его нет.
z2k_pct_bytes() {
    # -v ОБЯЗАТЕЛЕН: без него od схлопывает повторяющиеся строки в «*», и
    # длинная строка из одинаковых символов теряет байты — имя из 33 кириллиц
    # приезжало короче и проходило проверку длины. -v есть у busybox
    # (usage: [-abcdeFfhiloxsv]), у GNU и у BSD.
    od -b -v | awk '
        { for (i = 2; i <= NF; i++) {
              v = 0
              for (k = 1; k <= length($i); k++) v = v * 8 + substr($i, k, 1)
              printf "%%%02X", v
          } }'
}

# z2k_extract_block <файл> <опорная подстрока> <отступ>
#
# Блоки, которые нужно исполнить, живут внутри огромных функций установки —
# целиком их не вынуть. Берём от опорной строки до закрывающего `fi` на
# заданном отступе.
#
# `awk -v` обрабатывает escape-последовательности в присваивании, поэтому
# regexp сюда передавать нельзя: `\[` доехало бы как `[` и открыло класс
# символов. Ищем ПОДСТРОКУ через index().
z2k_extract_block() {
    awk -v pat="$2" -v ind="$3" '
        index($0, pat) > 0 { inb = 1 }
        inb { print }
        inb && $0 == ind "fi" { exit }
    ' "$1"
}

# z2k_extract_fn <файл> <имя функции>
#
# Парный к z2k_extract_block: тот кончается на `fi` заданного отступа, а
# функции кончаются `}` в нулевой колонке. Разделение намеренное — общий
# «умный» экстрактор пришлось бы учить границам обеих форм, и он молча брал бы
# не то на первой же вложенной функции.
#
# Имя сравнивается целиком со строкой `<имя>() {`, а не подстрокой: `_print_x`
# и `_print_xyz` иначе матчились бы одной выборкой.
z2k_extract_fn() {
    awk -v fn="$2" '
        $0 == fn "() {" { inb = 1 }
        inb { print }
        inb && $0 == "}" { exit }
    ' "$1"
}

# z2k_write_curl_stub <путь>
#
# Канонический подставной curl. Печатает ДВА поля — код ответа и время
# коннекта, — потому что именно это просит боевой `-w`. Стаб на одно поле
# делает вакуумно-зелёными все проверки разбора этой строки.
#
# Поведение задаётся окружением на стороне вызывающего:
#   Z2K_STUB_LOG   — файл, куда дописывается argv каждого вызова (и рядом
#                    .v — счётчик вызовов с --resolve, то есть хопов Layer 0);
#   Z2K_STUB_MODE  — ok (умолчание) | m304 | empty | e500 | vps_fail |
#                    vps_flap | vps_5xx;
#   Z2K_STUB_BODY  — что класть в -o (умолчание «ТЕЛО»);
#   Z2K_STUB_ETAG  — какой ETag отдавать в заголовках (пусто = без ETag);
#   Z2K_STUB_WCODE — чем перебить печатаемый код ответа (для разбора -w).
#
# vps_fail/vps_flap — измеренная картина отказа Layer 0: SYN-ACK потерян,
# соединение не установилось, curl выходит с 28 и НУЛЕВЫМ временем коннекта.
# vps_5xx — противоположный случай: соединились, ответ негодный, повторять
# нечего.
z2k_write_curl_stub() {
    cat > "$1" <<'Z2KSTUB'
#!/bin/sh
[ -n "${Z2K_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$Z2K_STUB_LOG"
hdr=""; body=""; cmp=""; save=""; resolve=0; prev=""
for a in "$@"; do
    case "$prev" in
        -D) hdr="$a" ;;
        -o) body="$a" ;;
        --etag-compare) cmp="$a" ;;
        --etag-save) save="$a" ;;
    esac
    [ "$a" = "--resolve" ] && resolve=1
    prev="$a"
done
_mode="${Z2K_STUB_MODE:-ok}"
if [ "$resolve" = "1" ] && [ -n "${Z2K_STUB_LOG:-}" ]; then
    n=$(cat "${Z2K_STUB_LOG}.v" 2>/dev/null || echo 0)
    n=$((n + 1)); printf '%s' "$n" > "${Z2K_STUB_LOG}.v"
else
    n=0
fi
if [ "$resolve" = "1" ]; then
    case "$_mode" in
        vps_fail)  printf '000 0.000000'; exit 28 ;;
        vps_flap)  [ "$n" = "1" ] && { printf '000 0.000000'; exit 28; } ;;
        vps_5xx)   printf '500 0.075'; exit 0 ;;
    esac
fi
case "$_mode" in
    m304)
        [ -n "$hdr" ] && printf 'HTTP/1.1 304 Not Modified\r\n\r\n' > "$hdr"
        printf '%s 0.075' "${Z2K_STUB_WCODE:-304}"; exit 0 ;;
    empty)
        [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
        [ -n "$body" ] && : > "$body"
        printf '%s 0.075' "${Z2K_STUB_WCODE:-200}"; exit 0 ;;
    e500)
        [ -n "$hdr" ] && printf 'HTTP/1.1 500 Oops\r\n\r\n' > "$hdr"
        printf '%s 0.075' "${Z2K_STUB_WCODE:-500}"; exit 0 ;;
esac
# --etag-compare/--etag-save: тот же замок, что у боевого geosite-хопа.
if [ -n "$cmp" ] && [ -f "$cmp" ] && [ -n "${Z2K_STUB_UPSTREAM_ETAG:-}" ] \
   && [ "$(cat "$cmp" 2>/dev/null)" = "$Z2K_STUB_UPSTREAM_ETAG" ]; then
    printf '%s 0.075' "${Z2K_STUB_WCODE:-304}"; exit 0
fi
[ -n "$body" ] && printf '%s\n' "${Z2K_STUB_BODY:-ТЕЛО}" > "$body"
[ -n "$save" ] && printf '%s' "${Z2K_STUB_UPSTREAM_ETAG:-}" > "$save"
if [ -n "$hdr" ]; then
    if [ -n "${Z2K_STUB_ETAG:-}" ]; then
        printf 'HTTP/1.1 200 OK\r\nETag: "%s"\r\n\r\n' "$Z2K_STUB_ETAG" > "$hdr"
    else
        printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
    fi
fi
printf '%s 0.075' "${Z2K_STUB_WCODE:-200}"
exit 0
Z2KSTUB
    chmod +x "$1"
}
