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
                    _empty="$_empty $_path"
                fi
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

    for _tok in $(printf "%s\n" "$_opt_text" | tr '\n' ' '); do
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
                        # Проверить файл в fake директории
                        if [ ! -f "${FAKE_DIR}/${_blob_name}" ] && [ ! -f "${FAKE_DIR}/${_blob_name}.bin" ]; then
                            _bad_blobs="$_bad_blobs $_blob_name"
                        fi
                        ;;
                esac
                ;;
        esac
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
    else
        report_ok "Все blob файлы найдены в ${FAKE_DIR}/"
    fi
}

# ==============================================================================
# 7. ПРОВЕРКА --lua-desync= ДЕЙСТВИЙ
# ==============================================================================

# Известные action names для --lua-desync=<action>:...
# Список основан на nfqws2 + z2k Lua-плагинах
KNOWN_LUA_DESYNC_ACTIONS="fake send drop circular circular_locked \
fakedsplit fakeddisorder multisplit multidisorder \
hostfakesplit http_methodeol syndata pktmod udplen \
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

    for _tok in $_tokens; do
        case "$_tok" in
            --new)
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
            --lua-desync=*|--hostlist=*|--hostlist-exclude=*|--payload=*|--out-range=*|--in-range=*|--filter-l7=*|--ipset=*|--hostlist-domains=*)
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
    printf "--- Файл конфигурации ---\n"
    if ! check_config_exists; then
        printf "\n=== ИТОГ: 0 OK, 0 WARN, %d FAIL ===\n" "$FAIL_COUNT"
        return 2
    fi
    check_shell_syntax
    check_required_vars

    # --- Этап 2: бинарник nfqws2 ---
    printf "\n--- Бинарник nfqws2 ---\n"
    check_nfqws2_binary

    # --- Этап 3: извлечь и проверить NFQWS2_OPT ---
    printf "\n--- Извлечение NFQWS2_OPT ---\n"
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
        report_ok "NFQWS2_OPT успешно извлечён"
    fi

    if [ -n "$NFQWS2_OPT_TEXT" ]; then
        printf "\n--- Валидация портов ---\n"
        check_filter_ports "$NFQWS2_OPT_TEXT"

        printf "\n--- Валидация hostlist файлов ---\n"
        check_hostlist_files "$NFQWS2_OPT_TEXT"

        printf "\n--- Валидация blob файлов ---\n"
        check_blob_references "$NFQWS2_OPT_TEXT"

        printf "\n--- Валидация lua-desync действий ---\n"
        check_lua_desync_actions "$NFQWS2_OPT_TEXT"

        printf "\n--- Структура профилей ---\n"
        check_profile_structure "$NFQWS2_OPT_TEXT"
        check_missing_new_separator "$NFQWS2_OPT_TEXT"
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
