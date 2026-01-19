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

        # Все стратегии в файле - HTTPS (HTTP удалены из strats.txt)
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

    echo "DEBUG: apply_strategy начало для #$strategy_num" >&2

    # Проверить существование стратегии
    if ! strategy_exists "$strategy_num"; then
        print_error "Стратегия #$strategy_num не найдена"
        return 1
    fi

    echo "DEBUG: Получаем параметры стратегии..." >&2
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

    echo "DEBUG: Генерируем мульти-профиль..." >&2
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

    echo "DEBUG: Перезапускаем сервис..." >&2
    # Перезапустить сервис
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    echo "DEBUG: Ждем 2 сек после рестарта..." >&2
    sleep 2

    echo "DEBUG: Проверяем запуск сервиса..." >&2
    if is_zapret2_running; then
        print_success "Сервис перезапущен"
        echo "DEBUG: apply_strategy завершена успешно" >&2
        return 0
    else
        print_warning "Сервис не запустился, проверьте логи"
        echo "DEBUG: apply_strategy завершена с ошибкой" >&2
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

# Старая функция test_strategy_score_category() удалена
# Используйте test_strategy_tls() вместо неё

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
# ТЕСТИРОВАНИЕ СТРАТЕГИЙ (TLS HANDSHAKE)
# ==============================================================================

# Тест доступности домена через TLS (на основе check_access из Z4R)
# Проверяет TLS 1.2 и TLS 1.3 после применения стратегии
test_strategy_tls() {
    local domain=$1
    local timeout=${2:-3}  # По умолчанию 3 секунды

    local tls12_success=0
    local tls13_success=0

    echo "DEBUG: test_strategy_tls для $domain (timeout=$timeout)" >&2

    # Проверка TLS 1.2
    echo "DEBUG: Пробуем TLS 1.2..." >&2
    if curl --tls-max 1.2 --max-time "$timeout" -s -o /dev/null "https://${domain}" 2>/dev/null; then
        tls12_success=1
        echo "DEBUG: TLS 1.2 успех" >&2
    else
        echo "DEBUG: TLS 1.2 провал" >&2
    fi

    # Проверка TLS 1.3
    echo "DEBUG: Пробуем TLS 1.3..." >&2
    if curl --tlsv1.3 --max-time "$timeout" -s -o /dev/null "https://${domain}" 2>/dev/null; then
        tls13_success=1
        echo "DEBUG: TLS 1.3 успех" >&2
    else
        echo "DEBUG: TLS 1.3 провал" >&2
    fi

    # Успех если хотя бы один из протоколов работает
    if [ "$tls12_success" -eq 1 ] || [ "$tls13_success" -eq 1 ]; then
        echo "DEBUG: test_strategy_tls = SUCCESS" >&2
        return 0
    else
        echo "DEBUG: test_strategy_tls = FAIL" >&2
        return 1
    fi
}

# Генерация тестового домена Google Video (на основе get_yt_cluster_domain из Z4R)
# Использует внешний API для получения реального живого кластера YouTube
generate_gv_domain() {
    # Попытаться получить имя кластера через API
    local cluster_name
    cluster_name=$(curl -s -m 3 "https://redirector.googlevideo.com/report_mapping" 2>/dev/null)

    # Если API не ответил, использовать известный рабочий домен
    if [ -z "$cluster_name" ]; then
        echo "rr1---sn-jvhnu5g-n8vr.googlevideo.com"
        return 0
    fi

    # Карты букв для cipher mapping (как в Z4R)
    local letters_map_a="abcdefghijklmnopqrstuvwxyz234567"
    local letters_map_b="qwertyuiopasdfghjklzxcvbnm012345"

    local converted_name=""
    local i=0

    # Преобразование имени кластера
    while [ "$i" -lt "${#cluster_name}" ]; do
        local char="${cluster_name:$i:1}"

        # Найти позицию символа в map_a
        local pos=0
        local found=0
        while [ "$pos" -lt "${#letters_map_a}" ]; do
            if [ "${letters_map_a:$pos:1}" = "$char" ]; then
                converted_name="${converted_name}${letters_map_b:$pos:1}"
                found=1
                break
            fi
            pos=$((pos + 1))
        done

        # Если символ не найден в map_a, оставить как есть
        if [ "$found" -eq 0 ]; then
            converted_name="${converted_name}${char}"
        fi

        i=$((i + 1))
    done

    echo "rr1---sn-${converted_name}.googlevideo.com"
}

# ==============================================================================
# АВТОТЕСТ ПО КАТЕГОРИЯМ (Z4R МЕТОД)
# ==============================================================================

# Автотест YouTube TCP (youtube.com)
# Тестирует TOP-20 стратегий и возвращает номер первой работающей
auto_test_youtube_tcp() {
    local strategies_list="${1:-$TOP20_STRATEGIES}"
    local domain="www.youtube.com"
    local tested=0
    local total=20

    print_info "Тестирование YouTube TCP (youtube.com)..."
    echo "DEBUG: Начало цикла тестирования" >&2

    for num in $strategies_list; do
        tested=$((tested + 1))
        echo "DEBUG: Тест $tested/$total, стратегия #$num" >&2
        printf "  [%d/%d] Стратегия #%s... " "$tested" "$total" "$num" >&2

        echo "DEBUG: Применяем стратегию #$num..." >&2

        # Применить стратегию (показываем вывод для debug)
        if ! apply_strategy "$num" 2>&1; then
            printf "ОШИБКА\n" >&2
            echo "DEBUG: Ошибка применения стратегии #$num" >&2
            continue
        fi

        echo "DEBUG: Стратегия применена, ждем 2 сек..." >&2
        # Подождать 2 секунды для применения
        sleep 2

        echo "DEBUG: Тестируем TLS для $domain..." >&2
        # Протестировать через TLS
        if test_strategy_tls "$domain" 3; then
            printf "РАБОТАЕТ\n" >&2
            print_success "Найдена работающая стратегия для YouTube TCP: #$num"
            echo "$num"
            return 0
        else
            printf "НЕ РАБОТАЕТ\n" >&2
        fi
    done

    # Если ничего не работает, вернуть стратегию по умолчанию
    print_warning "Не найдено работающих стратегий для YouTube TCP, используется #1"
    echo "1"
    return 1
}

# Автотест YouTube GV (googlevideo CDN)
# Тестирует TOP-20 стратегий для Google Video и возвращает номер первой работающей
auto_test_youtube_gv() {
    local strategies_list="${1:-$TOP20_STRATEGIES}"
    local tested=0
    local total=20

    print_info "Генерация тестового домена Google Video..."
    local domain
    domain=$(generate_gv_domain)
    print_info "Тестовый домен: $domain"

    print_info "Тестирование YouTube GV (Google Video)..."
    echo "DEBUG: Начало цикла тестирования GV" >&2

    for num in $strategies_list; do
        tested=$((tested + 1))
        echo "DEBUG: GV Тест $tested/$total, стратегия #$num" >&2
        printf "  [%d/%d] Стратегия #%s... " "$tested" "$total" "$num" >&2

        # Применить стратегию (показываем вывод для debug)
        if ! apply_strategy "$num" 2>&1; then
            printf "ОШИБКА\n" >&2
            continue
        fi

        # Подождать 2 секунды для применения
        sleep 2

        # Протестировать через TLS
        if test_strategy_tls "$domain" 3; then
            printf "РАБОТАЕТ\n" >&2
            print_success "Найдена работающая стратегия для YouTube GV: #$num"
            echo "$num"
            return 0
        else
            printf "НЕ РАБОТАЕТ\n" >&2
        fi
    done

    # Если ничего не работает, вернуть стратегию по умолчанию
    print_warning "Не найдено работающих стратегий для YouTube GV, используется #1"
    echo "1"
    return 1
}

# Автотест RKN (meduza.io, facebook.com, rutracker.org)
# Тестирует TOP-20 стратегий для RKN доменов и возвращает номер первой работающей
auto_test_rkn() {
    local strategies_list="${1:-$TOP20_STRATEGIES}"
    local test_domains="meduza.io facebook.com rutracker.org"
    local tested=0
    local total=20

    print_info "Тестирование RKN (meduza.io, facebook.com, rutracker.org)..."
    echo "DEBUG: Начало цикла тестирования RKN" >&2

    for num in $strategies_list; do
        tested=$((tested + 1))
        echo "DEBUG: RKN Тест $tested/$total, стратегия #$num" >&2
        printf "  [%d/%d] Стратегия #%s... " "$tested" "$total" "$num" >&2

        # Применить стратегию (показываем вывод для debug)
        if ! apply_strategy "$num" 2>&1; then
            printf "ОШИБКА\n" >&2
            continue
        fi

        # Подождать 2 секунды для применения
        sleep 2

        # Протестировать на всех трех доменах
        local success_count=0
        for domain in $test_domains; do
            echo "DEBUG: Тестируем $domain..." >&2
            if test_strategy_tls "$domain" 3; then
                success_count=$((success_count + 1))
            fi
        done

        # Успех если работает хотя бы на 2 из 3 доменов
        if [ "$success_count" -ge 2 ]; then
            printf "РАБОТАЕТ (%d/3)\n" "$success_count" >&2
            print_success "Найдена работающая стратегия для RKN: #$num"
            echo "$num"
            return 0
        else
            printf "НЕ РАБОТАЕТ (%d/3)\n" "$success_count" >&2
        fi
    done

    # Если ничего не работает, вернуть стратегию по умолчанию
    print_warning "Не найдено работающих стратегий для RKN, используется #1"
    echo "1"
    return 1
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
# АВТОТЕСТ ПО КАТЕГОРИЯМ V2 (Z4R РЕФЕРЕНС)
# ==============================================================================

# Автоматическое тестирование TOP-20 стратегий для каждой категории (Z4R метод)
# Тестирует 3 категории: YouTube TCP, YouTube GV, RKN
# Каждая категория получает свою первую работающую стратегию
auto_test_all_categories_v2() {
    local auto_mode=0

    # Проверить флаг --auto
    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    print_header "Автоподбор стратегий по категориям (Z4R метод)"

    print_info "Будут протестированы стратегии для каждой категории:"
    print_info "  - YouTube TCP (youtube.com)"
    print_info "  - YouTube GV (googlevideo CDN)"
    print_info "  - RKN (meduza.io, facebook.com, rutracker.org)"
    print_info "Это займет около 8-10 минут"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Начать тестирование?"; then
            print_info "Автотест отменен"
            return 0
        fi
    fi

    local config_file="${CONFIG_DIR}/category_strategies.conf"
    mkdir -p "$CONFIG_DIR"

    # Тестировать каждую категорию
    # Используем временные файлы вместо subshell чтобы функции utils.sh были доступны
    local result_file_tcp="/tmp/z2k_yt_tcp_result.txt"
    local result_file_gv="/tmp/z2k_yt_gv_result.txt"
    local result_file_rkn="/tmp/z2k_rkn_result.txt"

    print_separator
    print_info "Тестирование YouTube TCP..."
    auto_test_youtube_tcp "$TOP20_STRATEGIES" > "$result_file_tcp"
    local yt_tcp_result=$?
    local yt_tcp_strategy=$(cat "$result_file_tcp" 2>/dev/null || echo "1")

    printf "\n"
    print_separator
    print_info "Тестирование YouTube GV..."
    auto_test_youtube_gv "$TOP20_STRATEGIES" > "$result_file_gv"
    local yt_gv_result=$?
    local yt_gv_strategy=$(cat "$result_file_gv" 2>/dev/null || echo "1")

    printf "\n"
    print_separator
    print_info "Тестирование RKN..."
    auto_test_rkn "$TOP20_STRATEGIES" > "$result_file_rkn"
    local rkn_result=$?
    local rkn_strategy=$(cat "$result_file_rkn" 2>/dev/null || echo "1")

    # Очистить временные файлы
    rm -f "$result_file_tcp" "$result_file_gv" "$result_file_rkn"

    # Сохранить результаты
    cat > "$config_file" <<EOF
# Category Strategies Configuration (Z4R format)
# Format: CATEGORY:STRATEGY_NUM
# Generated: $(date)

youtube_tcp:$yt_tcp_strategy
youtube_gv:$yt_gv_strategy
rkn:$rkn_strategy
EOF

    # Показать итоговую таблицу
    printf "\n"
    print_separator
    print_success "Автотест завершен"
    print_separator
    printf "\nРезультаты:\n"
    printf "%-15s | %-10s | %s\n" "Категория" "Стратегия" "Статус"
    print_separator
    printf "%-15s | #%-9s | %s\n" "YouTube TCP" "$yt_tcp_strategy" "$([ $yt_tcp_result -eq 0 ] && echo 'OK' || echo 'ДЕФОЛТ')"
    printf "%-15s | #%-9s | %s\n" "YouTube GV" "$yt_gv_strategy" "$([ $yt_gv_result -eq 0 ] && echo 'OK' || echo 'ДЕФОЛТ')"
    printf "%-15s | #%-9s | %s\n" "RKN" "$rkn_strategy" "$([ $rkn_result -eq 0 ] && echo 'OK' || echo 'ДЕФОЛТ')"
    print_separator

    # В автоматическом режиме сразу применить
    if [ "$auto_mode" -eq 1 ]; then
        printf "\n"
        apply_category_strategies_v2 "$yt_tcp_strategy" "$yt_gv_strategy" "$rkn_strategy"
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
            apply_category_strategies_v2 "$yt_tcp_strategy" "$yt_gv_strategy" "$rkn_strategy"
            return 0
            ;;
    esac
}

# Алиас для обратной совместимости
auto_test_categories() {
    auto_test_all_categories_v2 "$@"
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

# Применить разные стратегии для YouTube TCP, YouTube GV, RKN (Z4R метод)
# Параметры: номера стратегий для каждой категории
apply_category_strategies_v2() {
    local yt_tcp_strategy=$1
    local yt_gv_strategy=$2
    local rkn_strategy=$3

    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    if [ ! -f "$init_script" ]; then
        print_error "Init скрипт не найден: $init_script"
        return 1
    fi

    print_info "Применение стратегий по категориям..."
    print_info "  YouTube TCP -> стратегия #$yt_tcp_strategy"
    print_info "  YouTube GV  -> стратегия #$yt_gv_strategy"
    print_info "  RKN         -> стратегия #$rkn_strategy"

    # Получить параметры для каждой стратегии
    local yt_tcp_params
    yt_tcp_params=$(get_strategy "$yt_tcp_strategy")
    if [ -z "$yt_tcp_params" ]; then
        print_warning "Стратегия #$yt_tcp_strategy не найдена, используется дефолтная"
        yt_tcp_params="--lua-desync=fake:blob=fake_default_tls:repeats=6"
    fi

    local yt_gv_params
    yt_gv_params=$(get_strategy "$yt_gv_strategy")
    if [ -z "$yt_gv_params" ]; then
        print_warning "Стратегия #$yt_gv_strategy не найдена, используется дефолтная"
        yt_gv_params="--lua-desync=fake:blob=fake_default_tls:repeats=6"
    fi

    local rkn_params
    rkn_params=$(get_strategy "$rkn_strategy")
    if [ -z "$rkn_params" ]; then
        print_warning "Стратегия #$rkn_strategy не найдена, используется дефолтная"
        rkn_params="--lua-desync=fake:blob=fake_default_tls:repeats=6"
    fi

    # Формировать полные параметры TCP для каждой категории
    local yt_tcp_full="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ${yt_tcp_params}"
    local yt_gv_full="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ${yt_gv_params}"
    local rkn_full="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ${rkn_params}"

    # UDP параметры (одинаковые для всех)
    local udp_full="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"

    # Обновить маркеры в init скрипте
    update_init_section "YOUTUBE_TCP" "$yt_tcp_full" "$udp_full" "$init_script"
    update_init_section "YOUTUBE_GV" "$yt_gv_full" "$udp_full" "$init_script"
    update_init_section "RKN" "$rkn_full" "$udp_full" "$init_script"

    print_success "Стратегии применены к init скрипту"

    # Перезапустить сервис
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    sleep 2

    if is_zapret2_running; then
        print_success "Сервис перезапущен с новыми стратегиями"
        return 0
    else
        print_error "Сервис не запустился, проверьте логи"
        return 1
    fi
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
