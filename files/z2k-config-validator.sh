#!/bin/sh
# z2k-config-validator.sh
# Валидация конфигурации zapret2 перед применением.
# POSIX sh, совместим с OpenWrt/Keenetic (busybox ash).
#
# Использование: sh z2k-config-validator.sh [путь-к-config]
# По умолчанию: /opt/zapret2/config
#
# Коды возврата:
#   0 — конфигурация валидна
#   1 — есть предупреждения (WARN), но сервис запустится
#   2 — есть критические ошибки (FAIL), сервис не запустится

set -u

# ==============================================================================
# НАСТРОЙКИ
# ==============================================================================

CONFIG_FILE="${1:-/opt/zapret2/config}"
ZAPRET_BASE="${ZAPRET_BASE:-/opt/zapret2}"
NFQWS2_BIN="${ZAPRET_BASE}/nfq2/nfqws2"
FAKE_DIR="${ZAPRET_BASE}/files/fake"
# Init-скрипт — единственное место, где живут строки регистрации блобов
# (`--blob=<имя>:@<путь>`). В конфиге их нет вовсе, поэтому карту имён
# приходится читать отсюда. См. check_blob_references.
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

# Счётчики
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

report_ok() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "[OK]   %s\n" "$1"
}

report_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf "[WARN] %s\n" "$1"
}

report_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "[FAIL] %s\n" "$1"
}

# Проверка неприменима здесь и сейчас — это НЕ замечание к конфигу.
# Отдельно от report_warn намеренно: WARN меняет код возврата на 1, и «не смог
# проверить» стало бы неотличимо от «нашёл, к чему придраться». Валидатор
# запускают и вне роутера, где бинарника нет вовсе.
report_skip() {
    printf "[--]   %s\n" "$1"
}

# ==============================================================================
# 1. ПРОВЕРКА СУЩЕСТВОВАНИЯ И СИНТАКСИСА КОНФИГА
# ==============================================================================

check_config_exists() {
    if [ ! -f "$CONFIG_FILE" ]; then
        report_fail "Файл конфигурации не найден: $CONFIG_FILE"
        return 1
    fi
    if [ ! -r "$CONFIG_FILE" ]; then
        report_fail "Файл конфигурации нечитаем: $CONFIG_FILE"
        return 1
    fi
    report_ok "Файл конфигурации существует: $CONFIG_FILE"
    return 0
}

# Проверка shell-синтаксиса (незакрытые кавычки, скобки и т.п.)
check_shell_syntax() {
    # sh -n делает синтаксический анализ без исполнения
    err=$(sh -n "$CONFIG_FILE" 2>&1)
    if [ $? -ne 0 ]; then
        report_fail "Ошибка shell-синтаксиса в конфиге: $err"
        return 1
    fi
    report_ok "Shell-синтаксис конфига валиден"
    return 0
}

# ==============================================================================
# 2. ПРОВЕРКА БИНАРНИКА NFQWS2
# ==============================================================================

check_nfqws2_binary() {
    if [ ! -f "$NFQWS2_BIN" ]; then
        report_fail "Бинарник nfqws2 не найден: $NFQWS2_BIN"
        return 1
    fi
    if [ ! -x "$NFQWS2_BIN" ]; then
        report_fail "Бинарник nfqws2 не исполняемый: $NFQWS2_BIN"
        return 1
    fi
    report_ok "Бинарник nfqws2 найден и исполняемый"
    return 0
}

# Спросить сам движок, а не наши представления о нём.
#
# Всё выше и ниже — наши собственные проверки: пути, блобы, структура профилей.
# Они ловят то, что мы догадались проверить, и по определению отстают от nfqws2:
# добавили в движок аргумент — валидатор о нём не знает. При этом у бинарника
# есть `--dry-run`, который разбирает параметры, грузит списки и блобы, НЕ
# занимает очередь и выходит. Это последняя инстанция, и до 2026-08-13 мы её не
# спрашивали: при отказе старта человека отправляли сюда, а воспроизвести отказ
# эта команда не умела.
check_nfqws2_dry_run() {
    if [ ! -x "$NFQWS2_BIN" ]; then
        report_skip "Проверку движком пропускаю — бинарник недоступен"
        return 0
    fi
    if ! "$NFQWS2_BIN" --help 2>&1 | grep -q -- '--dry-run'; then
        report_skip "Проверку движком пропускаю — эта сборка nfqws2 не умеет --dry-run"
        return 0
    fi

    _dry_out=$(
        set -f
        # shellcheck disable=SC2086  # строка опций, словоделение здесь и нужно
        set -- $NFQWS2_OPT_TEXT
        "$NFQWS2_BIN" --dry-run --qnum=299 "$@" 2>&1
    )
    _dry_rc=$?
    if [ "$_dry_rc" -eq 0 ]; then
        report_ok "nfqws2 разобрал конфигурацию (--dry-run)"
        return 0
    fi

    report_fail "nfqws2 ОТВЕРГ конфигурацию (--dry-run, код $_dry_rc):"
    printf '%s\n' "$_dry_out" | grep -viE '^loading|^Loaded |^Running as|^github version|^$' \
        | tail -n 6 | sed 's/^/      /'
    return 1
}

# ==============================================================================
# 3. ИЗВЛЕЧЕНИЕ NFQWS2_OPT ИЗ КОНФИГА
# ==============================================================================

# Извлечь значение NFQWS2_OPT (многострочная переменная в кавычках).
# Возвращает содержимое через stdout.
extract_nfqws2_opt() {
    # Sourcing конфиг опасен на хост-машине (переменные, side-effects).
    # Парсим вручную: ищем NFQWS2_OPT="..." (heredoc-style, многострочный).
    _in_opt=0
    _result=""
    while IFS= read -r _line; do
        case "$_in_opt" in
            0)
                # Начало блока NFQWS2_OPT="
                case "$_line" in
                    NFQWS2_OPT=\"*)
                        _val="${_line#NFQWS2_OPT=\"}"
                        # Однострочное значение?
                        case "$_val" in
                            *\")
                                # Убрать закрывающую кавычку
                                _result="${_val%\"}"
                                printf "%s" "$_result"
                                return 0
                                ;;
                            *)
                                _result="$_val"
                                _in_opt=1
                                ;;
                        esac
                        ;;
                esac
                ;;
            1)
                # Конец блока — строка начинающаяся с "
                case "$_line" in
                    \"*)
                        printf "%s" "$_result"
                        return 0
                        ;;
                    *)
                        _result="$_result
$_line"
                        ;;
                esac
                ;;
        esac
    done < "$CONFIG_FILE"

    # Если _in_opt=1 и мы дошли сюда — незакрытая кавычка
    if [ "$_in_opt" = "1" ]; then
        printf "%s" "$_result"
        return 1
    fi
    # Не нашли NFQWS2_OPT
    return 2
}

# ==============================================================================
# 4. ВАЛИДАЦИЯ ПОРТОВ В --filter-tcp / --filter-udp
# ==============================================================================

# Проверить один порт или диапазон: число 1-65535 или число-число
validate_port_spec() {
    _spec="$1"
    case "$_spec" in
        *-*)
            _lo="${_spec%%-*}"
            _hi="${_spec#*-}"
            # Оба должны быть числами
            case "$_lo" in ''|*[!0-9]*) return 1 ;; esac
            case "$_hi" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_lo" -ge 1 ] && [ "$_lo" -le 65535 ] || return 1
            [ "$_hi" -ge 1 ] && [ "$_hi" -le 65535 ] || return 1
            [ "$_lo" -le "$_hi" ] || return 1
            ;;
        *)
            case "$_spec" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_spec" -ge 1 ] && [ "$_spec" -le 65535 ] || return 1
            ;;
    esac
    return 0
}

check_filter_ports() {
    _opt_text="$1"
    _port_errors=0

    # Извлечь все --filter-tcp=... и --filter-udp=... значения
    _filter_vals=""
    for _tok in $(printf "%s\n" "$_opt_text" | tr '\n' ' '); do
        case "$_tok" in
            --filter-tcp=*|--filter-udp=*)
                _filter_vals="$_filter_vals ${_tok}"
                ;;
        esac
    done

    for _fv in $_filter_vals; do
        _ports="${_fv#*=}"
        _saved_ifs="$IFS"
        IFS=','
        for _p in $_ports; do
            if ! validate_port_spec "$_p"; then
                report_fail "Некорректный порт/диапазон '$_p' в '$_fv'"
                _port_errors=$((_port_errors + 1))
            fi
        done
        IFS="$_saved_ifs"
    done

    if [ "$_port_errors" -eq 0 ]; then
        report_ok "Все порты в --filter-tcp/--filter-udp валидны"
    fi
}

# ==============================================================================
# 5. ПРОВЕРКА --hostlist= И --hostlist-exclude= ФАЙЛОВ
# ==============================================================================

check_hostlist_files() {
    _opt_text="$1"
    _missing=""
    _empty=""
    _empty_excl=""
    for _tok in $(printf "%s\n" "$_opt_text" | tr '\n' ' '); do
        case "$_tok" in
            --hostlist=*)
                _path="${_tok#*=}"
                [ -z "$_path" ] && continue
                if [ ! -f "$_path" ]; then
                    _missing="$_missing $_path"
                elif [ ! -s "$_path" ]; then
                    # Накопители пустуют по построению, пока автоматика ничего
                    # не нашла. Ругаться на это — учить человека не читать
                    # предупреждения.
                    case "${_path##*/}" in
                        zapret-hosts-auto.txt|autohostlist-domains.txt|discovered-domains.txt) : ;;
                        *) _empty="$_empty $_path" ;;
                    esac
                fi
                ;;
            --hostlist-auto=*)
                # Автолист движка. Он его сам и наполняет — проверяем только
                # существование: без файла демон не стартует вообще.
                _path="${_tok#*=}"
                [ -z "$_path" ] && continue
                [ -f "$_path" ] || _missing="$_missing $_path"
                ;;
            --hostlist-exclude=*)
                _path="${_tok#*=}"
                [ -z "$_path" ] && continue
                if [ ! -f "$_path" ]; then
                    _missing="$_missing $_path"
                elif [ ! -s "$_path" ]; then
                    _empty_excl="$_empty_excl $_path"
                fi
                ;;
        esac
    done

    for _p in $_missing; do
        report_fail "Hostlist файл не найден: $_p"
    done
    for _p in $_empty; do
        report_warn "Hostlist файл пуст: $_p (профиль не будет матчить домены)"
    done
    for _p in $_empty_excl; do
        report_warn "Hostlist-exclude файл пуст: $_p"
    done

    if [ -z "$_missing" ] && [ -z "$_empty" ] && [ -z "$_empty_excl" ]; then
        report_ok "Все hostlist файлы существуют и непусты"
    fi
}

# ==============================================================================
# 6. ПРОВЕРКА --blob= ССЫЛОК
# ==============================================================================

check_blob_references() {
    _opt_text="$1"
    _bad_blobs=""
    _bad_reg=""

    # СНАЧАЛА КАРТА РЕГИСТРАЦИЙ, ПОТОМ ПРОВЕРКА ССЫЛОК.
    #
    # `--blob=<имя>:@<путь>` — это и есть авторитетное отображение имени в файл,
    # и путь там АБСОЛЮТНЫЙ: движок берёт файл по нему, а не по имени. Проверка,
    # игнорировавшая регистрацию и искавшая files/fake/<имя>[.bin], объявляла
    # ненайденным блоб, который движок прекрасно грузит.
    #
    # Цена ошибки здесь не косметическая. Автообновление трактует ненулевой код
    # валидатора как вето на перезапуск и откатывает релиз ЦЕЛИКОМ. Так и легло
    # r-80 у всех до единого: файл назывался ACTIVE_DISCORD_UDP.bin, был
    # зарегистрирован под именем active_discord_udp с абсолютным путём, движком
    # читался — а валидатор искал по имени, не нашёл и снёс релиз всему парку.
    #
    # Поэтому порядок такой: есть регистрация — проверяем файл по её пути;
    # регистрации нет — падаем на прежний files/fake/<имя>[.bin] (так находятся
    # блобы, чьё имя совпадает с именем файла, и старые имена под симлинками).
    # Карта берётся ИЗ INIT-СКРИПТА, а не из конфига: в конфиге строк
    # регистрации нет ни одной, там только места использования `blob=<имя>`.
    # Путь в регистрации записан через переменную — разворачиваем её тут же по
    # присваиванию в том же файле, подставляя известный нам ZAPRET_BASE.
    _reg_map=""
    if [ -f "$INIT_SCRIPT" ]; then
        for _rt in $(grep -o -- '--blob=[A-Za-z_][A-Za-z0-9_]*:@[^" ]*' "$INIT_SCRIPT" 2>/dev/null); do
            _rname="${_rt#--blob=}"
            _rref="${_rname#*:@}"
            _rname="${_rname%%:@*}"
            [ -n "$_rname" ] && [ -n "$_rref" ] || continue
            case "$_rref" in
                '$'*)   # и $VAR, и ${VAR} — оба начинаются с $
                    _rvar="${_rref#\$}"; _rvar="${_rvar#\{}"; _rvar="${_rvar%\}}"
                    _rpath=$(sed -n "s/^[[:space:]]*${_rvar}=\"\\([^\"]*\\)\".*/\\1/p" \
                             "$INIT_SCRIPT" 2>/dev/null | head -1)
                    ;;
                *) _rpath="$_rref" ;;
            esac
            [ -n "$_rpath" ] || continue
            _rpath=$(printf '%s' "$_rpath" | sed -e "s|\${ZAPRET_BASE}|${ZAPRET_BASE}|g" \
                                                 -e "s|\$ZAPRET_BASE|${ZAPRET_BASE}|g")
            case "$_rpath" in
                /*) ;;
                *) continue ;;
            esac
            _reg_map="${_reg_map}${_rname}=${_rpath}
"
            if [ ! -f "$_rpath" ]; then
                _bad_reg="$_bad_reg ${_rname}=${_rpath}"
            fi
        done
    fi

    for _tok in $(printf "%s\n" "$_opt_text" | tr '\n' ' '); do
        # Сами строки регистрации уже проверены выше по своему пути.
        case "$_tok" in
            --blob=*:@*) continue ;;
        esac
        case "$_tok" in
            *blob=*)
                # Извлечь значение blob из формата key=value:key=value
                # Примеры: --lua-desync=fake:blob=quic5:repeats=3
                #          --lua-desync=fake:payload=http_req:dir=out:blob=zero_256:badsum
                _remainder="$_tok"
                # Найти blob= часть
                case "$_remainder" in
                    *:blob=*|*blob=*)
                        # Вырезать всё до blob=
                        _after="${_remainder#*blob=}"
                        # Вырезать всё после следующего : (параметры)
                        _blob_name="${_after%%:*}"
                        # Пропустить inline hex блобы (0x...)
                        case "$_blob_name" in
                            0x*|0X*) continue ;;
                        esac
                        # Пропустить пустые
                        [ -z "$_blob_name" ] && continue
                        # Пропустить встроенные блобы nfqws2 (hardcoded в бинарнике)
                        case "$_blob_name" in
                            fake_default_tls|fake_default_http|fake_default_quic) continue ;;
                        esac
                        # Имя, объявленное регистрацией, уже разобрано по её пути.
                        if printf '%s' "$_reg_map" | grep -q "^${_blob_name}="; then
                            continue
                        fi
                        # Проверить файл в fake директории
                        if [ ! -f "${FAKE_DIR}/${_blob_name}" ] && [ ! -f "${FAKE_DIR}/${_blob_name}.bin" ]; then
                            _bad_blobs="$_bad_blobs $_blob_name"
                        fi
                        ;;
                esac
                ;;
        esac
    done

    for _r in $_bad_reg; do
        report_fail "Blob зарегистрирован, но файла нет: ${_r#*=} (имя ${_r%%=*})"
    done

    if [ -n "$_bad_blobs" ]; then
        # Уникализировать
        _seen=""
        for _b in $_bad_blobs; do
            case " $_seen " in
                *" $_b "*) continue ;;
            esac
            _seen="$_seen $_b"
            report_fail "Blob файл не найден: ${FAKE_DIR}/${_b}[.bin]"
        done
    elif [ -z "$_bad_reg" ]; then
        report_ok "Все blob файлы найдены"
    fi
}

# ==============================================================================
# 7. ПРОВЕРКА --lua-desync= ДЕЙСТВИЙ
# ==============================================================================

# Известные action names для --lua-desync=<action>:...
# Список основан на nfqws2 + z2k Lua-плагинах
# rst/rstack/synack — настоящие функции движка (lua/zapret-antidpi.lua), а не
# наши добавки. Их отсутствие здесь означало, что валидатор объявлял рабочую
# конфигурацию ошибочной: человек с корректной стратегией получал предупреждение
# о «неизвестном действии» и шёл искать несуществующую опечатку.
KNOWN_LUA_DESYNC_ACTIONS="fake send drop circular \
fakedsplit fakeddisorder multisplit multidisorder \
hostfakesplit http_methodeol syndata pktmod udplen \
rst rstack synack \
z2k_quic_morph_v2 z2k_timing_morph z2k_ipfrag3 z2k_ipfrag3_tiny"

is_known_action() {
    _action="$1"
    for _a in $KNOWN_LUA_DESYNC_ACTIONS; do
        [ "$_action" = "$_a" ] && return 0
    done
    return 1
}

check_lua_desync_actions() {
    _opt_text="$1"
    _unknown=""

    for _tok in $(printf "%s\n" "$_opt_text" | tr '\n' ' '); do
        case "$_tok" in
            --lua-desync=*)
                # Формат: --lua-desync=<action>:<key=val>:<key=val>...
                _val="${_tok#--lua-desync=}"
                # Извлечь action name (до первого :)
                _action="${_val%%:*}"
                [ -z "$_action" ] && continue
                if ! is_known_action "$_action"; then
                    _unknown="$_unknown $_action"
                fi
                ;;
        esac
    done

    if [ -n "$_unknown" ]; then
        _seen=""
        for _a in $_unknown; do
            case " $_seen " in
                *" $_a "*) continue ;;
            esac
            _seen="$_seen $_a"
            report_warn "Неизвестное lua-desync действие: '$_a' (возможно, новый плагин?)"
        done
    else
        report_ok "Все lua-desync действия известны"
    fi
}

# ==============================================================================
# 8. ПРОВЕРКА СТРУКТУРЫ ПРОФИЛЕЙ (--new)
# ==============================================================================

check_profile_structure() {
    _opt_text="$1"

    # Разбиваем на профили по --new
    # Каждый профиль должен начинаться с --filter-tcp или --filter-udp
    _profile_idx=0
    _missing_filter=0
    _prev_had_filter=0
    _consecutive_new=0
    _filters_seen=""
    _dup_filters=""

    # Преобразуем в строку токенов
    _tokens=$(printf "%s\n" "$_opt_text" | tr '\n' ' ' | sed 's/  */ /g')

    # Проверяем каждый профиль
    _current_filters=""
    _in_profile=1
    # Блок шаблона (--template) — не профиль: он не участвует в подборе и
    # фильтров у него нет по построению. Считать его профилем значит выдавать
    # предупреждение «нет --filter-tcp» на каждой генерации конфига.
    _is_template=0
    _templates=0

    for _tok in $_tokens; do
        case "$_tok" in
            --template|--template=*)
                _is_template=1
                continue
                ;;
        esac
        case "$_tok" in
            --new)
                if [ "$_is_template" = "1" ]; then
                    _templates=$((_templates + 1))
                    _is_template=0
                    _current_filters=""
                    _in_profile=1
                    continue
                fi
                # Конец текущего профиля
                if [ "$_in_profile" = "1" ] && [ -z "$_current_filters" ]; then
                    # Профиль без --filter-tcp/--filter-udp
                    if [ "$_profile_idx" -gt 0 ]; then
                        report_warn "Профиль #${_profile_idx} не содержит --filter-tcp/--filter-udp"
                        _missing_filter=$((_missing_filter + 1))
                    fi
                fi
                # Проверить дубликаты фильтров
                if [ -n "$_current_filters" ]; then
                    for _cf in $_current_filters; do
                        case " $_filters_seen " in
                            *" $_cf "*)
                                _dup_filters="$_dup_filters $_cf"
                                ;;
                        esac
                    done
                    _filters_seen="$_filters_seen $_current_filters"
                fi
                _current_filters=""
                _profile_idx=$((_profile_idx + 1))
                _in_profile=1
                ;;
            --filter-tcp=*|--filter-udp=*)
                _current_filters="$_current_filters $_tok"
                ;;
        esac
    done

    # Последний профиль (после последнего --new или без --new)
    if [ "$_in_profile" = "1" ] && [ -n "$_current_filters" ]; then
        for _cf in $_current_filters; do
            case " $_filters_seen " in
                *" $_cf "*)
                    _dup_filters="$_dup_filters $_cf"
                    ;;
            esac
        done
    fi

    _total_profiles=$((_profile_idx + 1))

    if [ "$_total_profiles" -gt 1 ]; then
        report_ok "Найдено ${_total_profiles} профилей (${_profile_idx} разделителей --new)"
    else
        report_ok "Конфигурация содержит 1 профиль"
    fi
    [ "${_templates:-0}" -gt 0 ] && report_ok "Найдено ${_templates} шаблон(ов) --template"

    if [ "$_missing_filter" -gt 0 ]; then
        report_warn "${_missing_filter} профиль(ей) без --filter-tcp/--filter-udp"
    fi

    # Дубликаты фильтров (не всегда ошибка, но подозрительно)
    if [ -n "$_dup_filters" ]; then
        _seen=""
        for _d in $_dup_filters; do
            case " $_seen " in
                *" $_d "*) continue ;;
            esac
            _seen="$_seen $_d"
            report_warn "Дублирующийся фильтр между профилями: $_d"
        done
    fi
}

# ==============================================================================
# 9. ПРОВЕРКА ПРОПУЩЕННОГО --new МЕЖДУ ПРОФИЛЯМИ
# ==============================================================================

check_missing_new_separator() {
    _opt_text="$1"
    _prev_was_filter=0
    _issues=0
    _tokens=$(printf "%s\n" "$_opt_text" | tr '\n' ' ' | sed 's/  */ /g')

    for _tok in $_tokens; do
        case "$_tok" in
            --filter-tcp=*|--filter-udp=*)
                if [ "$_prev_was_filter" = "1" ]; then
                    # Два фильтра подряд без --new — это нормально для одного профиля
                    # (один профиль может иметь и --filter-tcp и --filter-udp)
                    :
                fi
                _prev_was_filter=1
                ;;
            --new)
                _prev_was_filter=0
                ;;
            --lua-desync=*|--hostlist=*|--hostlist-exclude=*|--payload=*|--out-range=*|--in-range=*|--filter-l7=*|--ipset=*|--hostlist-domains=*|--hostlist-auto=*|--hostlist-auto-*)
                _prev_was_filter=0
                ;;
        esac
    done

    # Ищем паттерн: --lua-desync=... --filter-tcp/udp без --new между ними
    # Это явный признак пропущенного --new
    _prev_tok=""
    _found_missing=0
    for _tok in $_tokens; do
        case "$_tok" in
            --filter-tcp=*|--filter-udp=*)
                case "$_prev_tok" in
                    --lua-desync=*|--blob=*)
                        report_fail "Возможно пропущен --new перед '$_tok' (предыдущий токен: '$_prev_tok')"
                        _found_missing=$((_found_missing + 1))
                        ;;
                esac
                ;;
        esac
        _prev_tok="$_tok"
    done

    if [ "$_found_missing" -eq 0 ]; then
        report_ok "Разделители --new между профилями расставлены корректно"
    fi
}

# ==============================================================================
# 10. ПРОВЕРКА ОБЯЗАТЕЛЬНЫХ ПЕРЕМЕННЫХ КОНФИГА
# ==============================================================================

check_required_vars() {
    # Безопасно грепаем переменные из конфига (не source-им)
    _has_enabled=0
    _has_nfqws2_enable=0
    _has_nfqws2_opt=0

    while IFS= read -r _line; do
        # Пропустить комментарии и пустые строки
        case "$_line" in
            '#'*|'') continue ;;
        esac
        case "$_line" in
            ENABLED=*) _has_enabled=1 ;;
            NFQWS2_ENABLE=*) _has_nfqws2_enable=1 ;;
            NFQWS2_OPT=*) _has_nfqws2_opt=1 ;;
        esac
    done < "$CONFIG_FILE"

    if [ "$_has_enabled" = "1" ]; then
        report_ok "Переменная ENABLED задана"
    else
        report_fail "Переменная ENABLED не найдена в конфиге"
    fi

    if [ "$_has_nfqws2_enable" = "1" ]; then
        report_ok "Переменная NFQWS2_ENABLE задана"
    else
        report_warn "Переменная NFQWS2_ENABLE не найдена (будет использован default)"
    fi

    if [ "$_has_nfqws2_opt" = "1" ]; then
        report_ok "Переменная NFQWS2_OPT задана"
    else
        report_fail "Переменная NFQWS2_OPT не найдена — нечего передать nfqws2"
    fi
}

# ==============================================================================
# ОСНОВНАЯ ЛОГИКА
# ==============================================================================

main() {
    printf "=== z2k-config-validator ===\n"
    printf "Конфигурация: %s\n" "$CONFIG_FILE"
    printf "============================\n\n"

    # --- Этап 1: файл конфига ---
    printf "%s\n" "--- Файл конфигурации ---"
    if ! check_config_exists; then
        printf "\n=== ИТОГ: 0 OK, 0 WARN, %d FAIL ===\n" "$FAIL_COUNT"
        return 2
    fi
    check_shell_syntax
    check_required_vars

    # --- Этап 2: бинарник nfqws2 ---
    printf "\n%s\n" "--- Бинарник nfqws2 ---"
    check_nfqws2_binary

    # --- Этап 3: извлечь и проверить NFQWS2_OPT ---
    printf "\n%s\n" "--- Извлечение NFQWS2_OPT ---"
    NFQWS2_OPT_TEXT=$(extract_nfqws2_opt)
    _extract_rc=$?

    if [ "$_extract_rc" -eq 2 ]; then
        report_fail "NFQWS2_OPT не найден в конфиге"
        # Показать итог и выйти
        printf "\n=== ИТОГ: %d OK, %d WARN, %d FAIL ===\n" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
        return 2
    elif [ "$_extract_rc" -eq 1 ]; then
        report_fail "NFQWS2_OPT: незакрытая кавычка (многострочный блок не завершён)"
    else
        # NFQWS2_OPT="" (или только пробелы/переводы строк) парсится успешно, но
        # означает, что nfqws2 запустится БЕЗ единой стратегии десинка — то есть
        # обход не работает вообще. Это критическая ошибка конфига, не OK.
        _opt_stripped=$(printf "%s" "$NFQWS2_OPT_TEXT" | tr -d ' \t\r\n')
        if [ -z "$_opt_stripped" ]; then
            report_fail "NFQWS2_OPT пуст — нет ни одной стратегии десинка (обход не работает)"
        else
            report_ok "NFQWS2_OPT успешно извлечён"
        fi
    fi

    if [ -n "$NFQWS2_OPT_TEXT" ]; then
        printf "\n%s\n" "--- Валидация портов ---"
        check_filter_ports "$NFQWS2_OPT_TEXT"

        printf "\n%s\n" "--- Валидация hostlist файлов ---"
        check_hostlist_files "$NFQWS2_OPT_TEXT"

        printf "\n%s\n" "--- Валидация blob файлов ---"
        check_blob_references "$NFQWS2_OPT_TEXT"

        printf "\n%s\n" "--- Валидация lua-desync действий ---"
        check_lua_desync_actions "$NFQWS2_OPT_TEXT"

        printf "\n%s\n" "--- Структура профилей ---"
        check_profile_structure "$NFQWS2_OPT_TEXT"
        check_missing_new_separator "$NFQWS2_OPT_TEXT"

        # Последней — она единственная говорит от имени самого движка.
        printf "\n%s\n" "--- Проверка движком (nfqws2 --dry-run) ---"
        check_nfqws2_dry_run
    fi

    # --- Итог ---
    printf "\n============================\n"
    printf "=== ИТОГ: %d OK, %d WARN, %d FAIL ===\n" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf "Статус: ОШИБКИ — nfqws2 может не запуститься!\n"
        return 2
    elif [ "$WARN_COUNT" -gt 0 ]; then
        printf "Статус: ПРЕДУПРЕЖДЕНИЯ — проверьте перед применением\n"
        return 1
    else
        printf "Статус: OK — конфигурация валидна\n"
        return 0
    fi
}

main
