#!/bin/sh
# lib/strategies.sh - Управление стратегиями zapret2
# Парсинг, тестирование, применение стратегий из strats.txt

# ==============================================================================
# КОНСТАНТЫ ДЛЯ СТРАТЕГИЙ
# ==============================================================================

# TOP-20 предопределенные стратегии (наиболее эффективные по опыту сообщества)
TOP20_STRATEGIES="4 7 11 21 23 24 27 30 51 65 80 88 101 110 125 150 200 250 300 350"

# Домены для тестирования стратегий
TEST_DOMAINS="
http://rutracker.org
https://rutracker.org
https://www.youtube.com
https://discord.com
https://googlevideo.com
"

# ==============================================================================
# ПАРСИНГ STRATS.TXT → STRATEGIES.CONF
# ==============================================================================

# Генерация strategies.conf из strats.txt
# Формат входа: curl_test_http[s] ipv4 rutracker.org : nfqws2 <параметры>
# Формат выхода: [NUMBER]|[TYPE]|[PARAMETERS]
generate_strategies_conf() {
    local input_file=$1
    local output_file=$2

    if [ ! -f "$input_file" ]; then
        print_error "Файл не найден: $input_file"
        return 1
    fi

    print_info "Парсинг $input_file..."

    # Создать заголовок
    cat > "$output_file" <<'EOF'
# Zapret2 Strategies Database
# Сгенерировано из blockcheck2 output
# Формат: [NUMBER]|[TYPE]|[PARAMETERS]
EOF

    local num=1
    local http_count=0
    local https_count=0

    # Пропустить первую строку (заголовок)
    tail -n +2 "$input_file" | while IFS=':' read -r test_cmd nfqws_params; do
        # Пропустить пустые строки
        [ -z "$test_cmd" ] && continue

        # Определить тип по команде
        local type="other"
        if echo "$test_cmd" | grep -q "curl_test_https"; then
            type="https"
            https_count=$((https_count + 1))
        elif echo "$test_cmd" | grep -q "curl_test_http"; then
            type="http"
            http_count=$((http_count + 1))
        fi

        # Извлечь nfqws2 параметры (удалить " nfqws2 " в начале)
        local params
        params=$(echo "$nfqws_params" | sed 's/^ *nfqws2 *//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # Пропустить если параметры пустые
        [ -z "$params" ] && continue

        # Записать в strategies.conf
        echo "${num}|${type}|${params}" >> "$output_file"

        num=$((num + 1))
    done

    # Подсчет
    local total_count
    total_count=$(grep -c '^[0-9]' "$output_file" 2>/dev/null || echo "0")

    print_success "Сгенерировано стратегий: $total_count"
    print_info "HTTP стратегии: ~$http_count"
    print_info "HTTPS стратегии: ~$https_count"

    return 0
}

# ==============================================================================
# РАБОТА СО СТРАТЕГИЯМИ
# ==============================================================================

# Получить стратегию по номеру
get_strategy() {
    local num=$1
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        print_error "Файл стратегий не найден: $conf"
        return 1
    fi

    grep "^${num}|" "$conf" | cut -d'|' -f3
}

# Получить тип стратегии (http/https)
get_strategy_type() {
    local num=$1
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep "^${num}|" "$conf" | cut -d'|' -f2
}

# Получить общее количество стратегий
get_strategies_count() {
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        echo "0"
        return
    fi

    grep -c '^[0-9]' "$conf" 2>/dev/null || echo "0"
}

# Проверить существование стратегии
strategy_exists() {
    local num=$1
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    [ -f "$conf" ] && grep -q "^${num}|" "$conf"
}

# Список стратегий по типу
list_strategies_by_type() {
    local type=$1
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep "|${type}|" "$conf"
}

# ==============================================================================
# ГЕНЕРАЦИЯ MULTI-PROFILE КОНФИГУРАЦИИ
# ==============================================================================

# Генерация мульти-профиля (TCP + UDP) из базовых параметров
generate_multiprofile() {
    local base_params=$1
    local type=$2

    if [ "$type" = "http" ]; then
        # HTTP стратегия: TCP:80,443 + UDP:443 QUIC
        cat <<PROFILE
# TCP Profile (HTTP)
--filter-tcp=80,443
--filter-l7=http
$base_params

--new

# UDP Profile (QUIC)
--filter-udp=443
--filter-l7=quic
--payload=quic_initial
--lua-desync=fake:blob=fake_default_quic:repeats=4
PROFILE
    else
        # HTTPS/TLS стратегия: TCP:443 TLS + UDP:443 QUIC
        cat <<PROFILE
# TCP Profile (HTTPS/TLS)
--filter-tcp=443
--filter-l7=tls
--payload=tls_client_hello
$base_params

--new

# UDP Profile (QUIC)
--filter-udp=443
--filter-l7=quic
--payload=quic_initial
--lua-desync=fake:blob=fake_default_quic:repeats=4
PROFILE
    fi
}

# ==============================================================================
# ПРИМЕНЕНИЕ СТРАТЕГИЙ К INIT СКРИПТУ
# ==============================================================================

# Применить стратегию к init скрипту
apply_strategy() {
    local strategy_num=$1
    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    # Проверить существование стратегии
    if ! strategy_exists "$strategy_num"; then
        print_error "Стратегия #$strategy_num не найдена"
        return 1
    fi

    # Получить параметры стратегии
    local params
    params=$(get_strategy "$strategy_num")

    if [ -z "$params" ]; then
        print_error "Не удалось получить параметры стратегии #$strategy_num"
        return 1
    fi

    # Получить тип стратегии
    local type
    type=$(get_strategy_type "$strategy_num")

    print_info "Применение стратегии #$strategy_num (тип: $type)..."

    # Генерация мульти-профиля
    local multiprofile
    multiprofile=$(generate_multiprofile "$params" "$type")

    # Создать backup init скрипта
    if [ -f "$init_script" ]; then
        backup_file "$init_script" || {
            print_error "Не удалось создать backup"
            return 1
        }
    else
        print_error "Init скрипт не найден: $init_script"
        return 1
    fi

    # Заменить секцию между STRATEGY_MARKER_START и STRATEGY_MARKER_END
    awk -v profile="$multiprofile" '
        BEGIN { in_marker=0; marker_found=0 }
        /STRATEGY_MARKER_START/ {
            print
            print profile
            in_marker=1
            marker_found=1
            next
        }
        /STRATEGY_MARKER_END/ {
            in_marker=0
            print
            next
        }
        !in_marker { print }
        END {
            if (!marker_found) {
                print "ERROR: STRATEGY_MARKER not found" > "/dev/stderr"
                exit 1
            }
        }
    ' "$init_script" > "${init_script}.tmp"

    # Проверить успешность awk
    if [ $? -ne 0 ]; then
        print_error "Ошибка модификации init скрипта"
        return 1
    fi

    # Заменить init скрипт
    mv "${init_script}.tmp" "$init_script" || {
        print_error "Не удалось заменить init скрипт"
        return 1
    }

    chmod +x "$init_script"

    # Сохранить номер текущей стратегии
    mkdir -p "$CONFIG_DIR"
    echo "CURRENT_STRATEGY=$strategy_num" > "$CURRENT_STRATEGY_FILE"

    print_success "Стратегия #$strategy_num применена"

    # Перезапустить сервис
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    sleep 2

    if is_zapret2_running; then
        print_success "Сервис перезапущен"
        return 0
    else
        print_warning "Сервис не запустился, проверьте логи"
        return 1
    fi
}

# ==============================================================================
# ТЕСТИРОВАНИЕ СТРАТЕГИЙ
# ==============================================================================

# Тест одной стратегии с оценкой 0-5
test_strategy_score() {
    local score=0
    local timeout=5

    # Тест HTTP rutracker.org
    if curl -s -m "$timeout" -I http://rutracker.org 2>/dev/null | grep -q "HTTP"; then
        score=$((score + 1))
    fi

    # Тест HTTPS rutracker.org
    if curl -s -m "$timeout" -I https://rutracker.org 2>/dev/null | grep -q "HTTP"; then
        score=$((score + 1))
    fi

    # Тест YouTube
    if curl -s -m "$timeout" -I https://www.youtube.com 2>/dev/null | grep -q "200"; then
        score=$((score + 1))
    fi

    # Тест Discord
    if curl -s -m "$timeout" -I https://discord.com 2>/dev/null | grep -q "200"; then
        score=$((score + 1))
    fi

    # Тест googlevideo
    if curl -s -m "$timeout" -I https://googlevideo.com 2>/dev/null | grep -q "HTTP"; then
        score=$((score + 1))
    fi

    echo "$score"
}

# Применить стратегию с тестом и откатом при неудаче
apply_strategy_safe() {
    local num=$1
    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    # Применить стратегию
    if ! apply_strategy "$num"; then
        return 1
    fi

    # Подождать 3 секунды
    print_info "Тестирование стратегии..."
    sleep 3

    # Протестировать
    local score
    score=$(test_strategy_score)

    printf "Оценка стратегии #%s: %s/5\n" "$num" "$score"

    if [ "$score" -lt 3 ]; then
        print_warning "Стратегия работает плохо (оценка: $score/5)"
        printf "Применить всё равно? [y/N]: "
        read -r answer

        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                print_info "Стратегия оставлена по выбору пользователя"
                return 0
                ;;
            *)
                print_info "Откат к предыдущей конфигурации..."
                restore_backup "$init_script" || {
                    print_error "Не удалось откатиться!"
                    return 1
                }
                "$init_script" restart >/dev/null 2>&1
                print_info "Откат выполнен"
                return 1
                ;;
        esac
    fi

    print_success "Стратегия #$num применена успешно (оценка: $score/5)"
    return 0
}

# ==============================================================================
# АВТОТЕСТ TOP-20
# ==============================================================================

# Автоматическое тестирование TOP-20 стратегий
auto_test_top20() {
    print_header "Автотест TOP-20 стратегий"

    print_info "Будут протестированы 20 наиболее эффективных стратегий"
    print_info "Оценка: 0-5 баллов (5 доменов)"
    print_info "Это займет около 2-3 минут"
    printf "\n"

    if ! confirm "Начать тестирование?"; then
        print_info "Автотест отменен"
        return 0
    fi

    local best_score=0
    local best_strategy=0
    local tested=0
    local total=20

    for num in $TOP20_STRATEGIES; do
        tested=$((tested + 1))

        printf "\n[%d/%d] Тестирование стратегии #%s...\n" "$tested" "$total" "$num"

        # Применить стратегию (без подтверждения)
        apply_strategy "$num" >/dev/null 2>&1 || {
            print_warning "Не удалось применить стратегию #$num"
            continue
        }

        # Подождать
        sleep 3

        # Протестировать
        local score
        score=$(test_strategy_score)

        printf "  Оценка: %s/5\n" "$score"

        # Обновить лучшую
        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best_strategy=$num
            print_success "  Новый лидер: #$num ($score/5)"
        fi
    done

    printf "\n"
    print_separator
    print_success "Автотест завершен"
    printf "Лучшая стратегия: #%s (оценка: %s/5)\n" "$best_strategy" "$best_score"
    print_separator

    if [ "$best_strategy" -eq 0 ]; then
        print_error "Не найдено работающих стратегий"
        print_info "Попробуйте ручной выбор из меню"
        return 1
    fi

    printf "\nПрименить стратегию #%s? [Y/n]: " "$best_strategy"
    read -r answer

    case "$answer" in
        [Nn]|[Nn][Oo])
            print_info "Стратегия не применена"
            print_info "Используйте меню для ручного выбора"
            return 0
            ;;
        *)
            apply_strategy "$best_strategy"
            print_success "Стратегия #$best_strategy применена"
            return 0
            ;;
    esac
}

# ==============================================================================
# ТЕСТИРОВАНИЕ ДИАПАЗОНА СТРАТЕГИЙ
# ==============================================================================

# Тест диапазона стратегий
test_strategy_range() {
    local start=$1
    local end=$2

    if [ -z "$start" ] || [ -z "$end" ]; then
        print_error "Укажите начало и конец диапазона"
        return 1
    fi

    if [ "$start" -gt "$end" ]; then
        print_error "Начало диапазона больше конца"
        return 1
    fi

    local total=$((end - start + 1))
    print_header "Тест стратегий #$start-#$end"
    print_info "Всего стратегий для теста: $total"

    if ! confirm "Начать тестирование?"; then
        return 0
    fi

    local best_score=0
    local best_strategy=0
    local tested=0

    local num=$start
    while [ "$num" -le "$end" ]; do
        tested=$((tested + 1))

        printf "\n[%d/%d] Тестирование стратегии #%s...\n" "$tested" "$total" "$num"

        # Применить стратегию
        apply_strategy "$num" >/dev/null 2>&1 || {
            print_warning "Не удалось применить стратегию #$num"
            num=$((num + 1))
            continue
        }

        sleep 3

        # Тест
        local score
        score=$(test_strategy_score)

        printf "  Оценка: %s/5\n" "$score"

        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best_strategy=$num
            print_success "  Новый лидер: #$num ($score/5)"
        fi

        num=$((num + 1))
    done

    printf "\n"
    print_separator
    print_success "Тестирование завершено"
    printf "Лучшая стратегия: #%s (оценка: %s/5)\n" "$best_strategy" "$best_score"
    print_separator

    if [ "$best_strategy" -ne 0 ]; then
        printf "\nПрименить стратегию #%s? [Y/n]: " "$best_strategy"
        read -r answer

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Стратегия не применена"
                ;;
            *)
                apply_strategy "$best_strategy"
                ;;
        esac
    fi
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
