#!/bin/sh
# lib/strategies.sh - Управление стратегиями zapret2
# Парсинг, тестирование, применение стратегий из strats.txt

# ==============================================================================
# КОНСТАНТЫ ДЛЯ СТРАТЕГИЙ
# ==============================================================================

# TOP-20 предопределенные стратегии HTTPS/TLS (наиболее эффективные по опыту сообщества)
# Теперь выбираются только из 118 HTTPS стратегий (равномерное распределение)
TOP20_STRATEGIES="1 7 13 19 25 31 37 43 49 55 61 67 73 79 85 91 97 103 109 115"

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

        # Фильтр: только HTTPS/TLS стратегии
        if ! echo "$test_cmd" | grep -q "curl_test_https"; then
            continue
        fi

        # Определить тип по команде
        local type="https"
        https_count=$((https_count + 1))

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

# Тест стратегии для конкретной категории с оценкой 0-5
test_strategy_score_category() {
    local category=$1
    local score=0
    local timeout=5

    case "$category" in
        youtube)
            # YouTube главный
            if curl -s -m "$timeout" -I https://www.youtube.com 2>/dev/null | grep -q "200"; then
                score=$((score + 1))
            fi

            # YouTube CDN (googlevideo)
            if curl -s -m "$timeout" -I https://googlevideo.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # YouTube API
            if curl -s -m "$timeout" -I https://www.googleapis.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # YouTube embed
            if curl -s -m "$timeout" -I https://www.youtube-nocookie.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # ytimg (thumbnails)
            if curl -s -m "$timeout" -I https://i.ytimg.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi
            ;;

        discord)
            # Discord главный
            if curl -s -m "$timeout" -I https://discord.com 2>/dev/null | grep -q "200"; then
                score=$((score + 1))
            fi

            # Discord invite links
            if curl -s -m "$timeout" -I https://discord.gg 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # Discord CDN
            if curl -s -m "$timeout" -I https://cdn.discordapp.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # Discord media
            if curl -s -m "$timeout" -I https://media.discordapp.net 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # Discord gateway (для подключения)
            if curl -s -m "$timeout" -I https://gateway.discord.gg 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi
            ;;

        custom)
            # RKN: Meduza
            if curl -s -m "$timeout" -I https://meduza.io 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # RKN: Instagram
            if curl -s -m "$timeout" -I https://www.instagram.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # Общий тест: rutracker
            if curl -s -m "$timeout" -I https://rutracker.org 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # Общий тест: Twitter/X
            if curl -s -m "$timeout" -I https://twitter.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi

            # Общий тест: Facebook
            if curl -s -m "$timeout" -I https://www.facebook.com 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi
            ;;

        *)
            # По умолчанию - общий тест
            if curl -s -m "$timeout" -I https://rutracker.org 2>/dev/null | grep -q "HTTP"; then
                score=$((score + 1))
            fi
            if curl -s -m "$timeout" -I https://www.youtube.com 2>/dev/null | grep -q "200"; then
                score=$((score + 1))
            fi
            if curl -s -m "$timeout" -I https://discord.com 2>/dev/null | grep -q "200"; then
                score=$((score + 1))
            fi
            ;;
    esac

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
        read -r answer </dev/tty </dev/tty

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
    local auto_mode=0

    # Проверить флаг --auto
    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    print_header "Автотест TOP-20 стратегий"

    print_info "Будут протестированы 20 наиболее эффективных стратегий"
    print_info "Оценка: 0-5 баллов (5 доменов)"
    print_info "Это займет около 2-3 минут"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Начать тестирование?"; then
            print_info "Автотест отменен"
            return 0
        fi
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

    # В автоматическом режиме сразу применить
    if [ "$auto_mode" -eq 1 ]; then
        apply_strategy "$best_strategy"
        print_success "Стратегия #$best_strategy применена автоматически"
        return 0
    fi

    # В интерактивном режиме спросить
    printf "\nПрименить стратегию #%s? [Y/n]: " "$best_strategy"
    read -r answer </dev/tty

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
# АВТОТЕСТ ПО КАТЕГОРИЯМ
# ==============================================================================

# Автоматическое тестирование TOP-20 стратегий для каждой категории
auto_test_categories() {
    local auto_mode=0

    # Проверить флаг --auto
    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    print_header "Автоподбор стратегий по категориям"

    print_info "Будут протестированы стратегии для каждой категории:"
    print_info "  - YouTube (видео и CDN)"
    print_info "  - Discord (сообщения и голос)"
    print_info "  - Custom (RKN и общие домены)"
    print_info "Это займет около 5-7 минут"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Начать тестирование?"; then
            print_info "Автотест отменен"
            return 0
        fi
    fi

    local categories="youtube discord custom"
    local best_strategies=""
    local config_file="${CONFIG_DIR}/category_strategies.conf"

    # Создать конфиг файл если не существует
    mkdir -p "$CONFIG_DIR"

    for category in $categories; do
        printf "\n"
        print_separator
        print_info "Категория: $category"
        print_separator

        local best_score=0
        local best_strategy=0
        local tested=0

        for num in $TOP20_STRATEGIES; do
            tested=$((tested + 1))

            printf "\n[%d/20] Тестирование стратегии #%s для $category...\n" "$tested" "$num"

            # Применить стратегию (без подтверждения)
            apply_strategy "$num" >/dev/null 2>&1 || {
                print_warning "Не удалось применить стратегию #$num"
                continue
            }

            # Подождать
            sleep 3

            # Протестировать для этой категории
            local score
            score=$(test_strategy_score_category "$category")

            printf "  Оценка для $category: %s/5\n" "$score"

            # Обновить лучшую
            if [ "$score" -gt "$best_score" ]; then
                best_score=$score
                best_strategy=$num
                print_success "  Новый лидер для $category: #$num ($score/5)"
            fi
        done

        print_separator
        if [ "$best_strategy" -eq 0 ]; then
            print_warning "Для $category не найдено работающих стратегий, используется стратегия #1"
            best_strategy=1
            best_strategies="${best_strategies}${category}:${best_strategy}:0 "
        else
            print_success "Лучшая для $category: #$best_strategy (оценка: $best_score/5)"
            best_strategies="${best_strategies}${category}:${best_strategy}:${best_score} "
        fi
    done

    # Сохранить результаты в файл
    printf "# Category Strategies Configuration\n" > "$config_file"
    printf "# Format: CATEGORY:STRATEGY_NUM:SCORE\n" >> "$config_file"
    printf "# Generated: %s\n\n" "$(date)" >> "$config_file"

    for entry in $best_strategies; do
        echo "$entry" >> "$config_file"
    done

    printf "\n"
    print_separator
    print_success "Автотест по категориям завершен"
    print_separator

    # Показать итоговую таблицу
    printf "\nРезультаты:\n"
    printf "%-15s | %-10s | %s\n" "Категория" "Стратегия" "Оценка"
    print_separator

    for entry in $best_strategies; do
        local cat=$(echo "$entry" | cut -d: -f1)
        local strat=$(echo "$entry" | cut -d: -f2)
        local sc=$(echo "$entry" | cut -d: -f3)
        printf "%-15s | #%-9s | %s/5\n" "$cat" "$strat" "$sc"
    done

    print_separator

    # В автоматическом режиме сразу применить
    if [ "$auto_mode" -eq 1 ]; then
        print_info "Применение стратегий по категориям..."
        apply_category_strategies "$best_strategies"
        print_success "Стратегии применены автоматически"
        return 0
    fi

    # В интерактивном режиме спросить
    printf "\nПрименить эти стратегии? [Y/n]: "
    read -r answer </dev/tty

    case "$answer" in
        [Nn]|[Nn][Oo])
            print_info "Стратегии не применены"
            print_info "Используйте меню для ручного выбора"
            return 0
            ;;
        *)
            apply_category_strategies "$best_strategies"
            print_success "Стратегии применены"
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
        read -r answer </dev/tty </dev/tty

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
# ПРИМЕНЕНИЕ СТРАТЕГИЙ ПО КАТЕГОРИЯМ
# ==============================================================================

# Применить разные стратегии для разных категорий
# Параметр: строка вида "youtube:4:5 discord:7:4 custom:11:3"
apply_category_strategies() {
    local category_strategies=$1
    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    if [ -z "$category_strategies" ]; then
        print_error "Не указаны стратегии для категорий"
        return 1
    fi

    if [ ! -f "$init_script" ]; then
        print_error "Init скрипт не найден: $init_script"
        return 1
    fi

    print_info "Применение стратегий по категориям..."

    # Обработать каждую категорию
    for entry in $category_strategies; do
        local category=$(echo "$entry" | cut -d: -f1)
        local strategy_num=$(echo "$entry" | cut -d: -f2)
        local score=$(echo "$entry" | cut -d: -f3)

        print_info "  $category -> стратегия #$strategy_num (оценка: $score/5)"

        # Получить параметры стратегии
        local params
        params=$(get_strategy "$strategy_num")

        if [ -z "$params" ]; then
            print_warning "Стратегия #$strategy_num не найдена, пропускаем $category"
            continue
        fi

        # Конвертировать в TCP/UDP профили
        local tcp_params
        local udp_params

        # Определить тип стратегии
        local type
        type=$(get_strategy_type "$strategy_num")

        if [ "$type" = "https" ]; then
            # HTTPS стратегия
            tcp_params="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ${params}"
            udp_params="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
        else
            # HTTP стратегия (на всякий случай)
            tcp_params="--filter-tcp=80,443 --filter-l7=http ${params}"
            udp_params="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
        fi

        # Обновить маркеры в init скрипте
        case "$category" in
            youtube)
                update_init_section "YOUTUBE" "$tcp_params" "$udp_params" "$init_script"
                ;;
            discord)
                update_init_section "DISCORD" "$tcp_params" "$udp_params" "$init_script"
                ;;
            custom)
                update_init_section "CUSTOM" "$tcp_params" "$udp_params" "$init_script"
                ;;
        esac
    done

    print_success "Стратегии применены к init скрипту"

    # Перезапустить сервис
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    sleep 2

    if is_zapret2_running; then
        print_success "Сервис перезапущен с новыми стратегиями"
        return 0
    else
        print_warning "Сервис не запустился, проверьте логи"
        return 1
    fi
}

# Обновить секцию в init скрипте для конкретной категории
update_init_section() {
    local marker=$1
    local tcp_params=$2
    local udp_params=$3
    local init_script=$4

    local start_marker="${marker}_MARKER_START"
    local end_marker="${marker}_MARKER_END"

    # Создать временный файл
    local temp_file="${init_script}.tmp"

    # Флаг - внутри ли мы секции для замены
    local inside_section=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "# ${start_marker}"; then
            # Начало секции - записать маркер и новые параметры
            echo "$line"
            echo "${marker}_TCP=\"${tcp_params}\""
            echo "${marker}_UDP=\"${udp_params}\""
            inside_section=1
        elif echo "$line" | grep -q "# ${end_marker}"; then
            # Конец секции - записать маркер и выйти из режима
            echo "$line"
            inside_section=0
        elif [ "$inside_section" -eq 0 ]; then
            # Вне секции - просто копировать
            echo "$line"
        fi
        # Внутри секции - пропускать старые строки (кроме маркеров)
    done < "$init_script" > "$temp_file"

    # Заменить init скрипт
    mv "$temp_file" "$init_script" || {
        print_error "Не удалось обновить init скрипт"
        return 1
    }

    chmod +x "$init_script"
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
