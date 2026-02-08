#!/bin/sh
# lib/strategies.sh - Управление стратегиями zapret2
# Парсинг, тестирование, применение стратегий из strats_new2.txt
# QUIC/UDP стратегии берутся из quic_strats.ini

# ==============================================================================
# КОНСТАНТЫ ДЛЯ СТРАТЕГИЙ
# ==============================================================================

# ==============================================================================
# РАБОТА С ФАЙЛАМИ СТРАТЕГИЙ ПО КАТЕГОРИЯМ (CONFIG-DRIVEN АРХИТЕКТУРА)
# ==============================================================================


# ==============================================================================
# ПАРСИНГ STRATS.TXT → STRATEGIES.CONF
# ==============================================================================

# Генерация strategies.conf из strats_new2.txt
# Формат входа: test_name ipv4 domain : nfqws2 <параметры>
# Формат выхода: [NUMBER]|[TYPE]|[PARAMETERS]|[NAME]
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
# Формат: [NUMBER]|[TYPE]|[PARAMETERS]|[NAME]
EOF

    local num=1
    local https_count=0

    # Пропустить первую строку (заголовок)
    # ВАЖНО: разделитель " : " (пробел-двоеточие-пробел), а НЕ ":", т.к. параметры содержат двоеточия!
    tail -n +2 "$input_file" | while read -r line; do
        # Пропустить пустые строки
        [ -z "$line" ] && continue

        # Разделить по " : " используя awk
        local test_cmd
        test_cmd=$(echo "$line" | awk -F ' : ' '{print $1}')
        local nfqws_params
        nfqws_params=$(echo "$line" | awk -F ' : ' '{print $2}')

        local type="https"
        https_count=$((https_count + 1))

        # Извлечь имя стратегии (первое слово test_cmd)
        local name
        name=$(echo "$test_cmd" | awk '{print $1}')

        # Извлечь nfqws2 параметры (удалить " nfqws2 " в начале)
        local params
        params=$(echo "$nfqws_params" | sed 's/^ *nfqws2 *//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # Пропустить если параметры пустые
        [ -z "$params" ] && continue

        # Записать в strategies.conf с именем
        echo "${num}|${type}|${params}|${name}" >> "$output_file"

        num=$((num + 1))
    done

    # Подсчет
    local total_count
    total_count=$(grep -c '^[0-9]' "$output_file" 2>/dev/null || echo "0")

    print_success "Сгенерировано стратегий: $total_count"
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

# Найти номер стратегии по имени (поле 4 в strategies.conf)
# Возвращает первый найденный номер или пустую строку
find_strategy_by_name() {
    local name=$1
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep "|${name}$" "$conf" | head -n 1 | cut -d'|' -f1
}

# Найти номер QUIC стратегии по имени (поле 2 в quic_strategies.conf)
find_quic_strategy_by_name() {
    local name=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep "|${name}|" "$conf" | head -n 1 | cut -d'|' -f1
}

# Получить QUIC стратегию по номеру
get_quic_strategy() {
    local num=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        print_error "Файл QUIC стратегий не найден: $conf"
        return 1
    fi

    grep "^${num}|" "$conf" | cut -d'|' -f3
}

# Получить имя QUIC стратегии
get_quic_strategy_name() {
    local num=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep "^${num}|" "$conf" | cut -d'|' -f2
}

# Получить описание QUIC стратегии
get_quic_strategy_desc() {
    local num=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep "^${num}|" "$conf" | cut -d'|' -f4
}

# Получить общее количество QUIC стратегий
get_quic_strategies_count() {
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        echo "0"
        return
    fi

    grep -c '^[0-9]' "$conf" 2>/dev/null || echo "0"
}

# Получить список всех QUIC стратегий
get_all_quic_strategies_list() {
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep -o '^[0-9]\+' "$conf" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# Проверить существование QUIC стратегии
quic_strategy_exists() {
    local num=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    [ -f "$conf" ] && grep -q "^${num}|" "$conf"
}

# Получить текущую QUIC стратегию
get_current_quic_strategy() {
    local conf="${QUIC_STRATEGY_FILE:-${CONFIG_DIR}/quic_strategy.conf}"
    if [ -f "$conf" ]; then
        . "$conf"
        [ -n "$QUIC_STRATEGY" ] && echo "$QUIC_STRATEGY" && return 0
    fi
    echo "1"
}

# Сохранить текущую QUIC стратегию
set_current_quic_strategy() {
    local num=$1
    local conf="${QUIC_STRATEGY_FILE:-${CONFIG_DIR}/quic_strategy.conf}"
    echo "QUIC_STRATEGY=$num" > "$conf"
}


# Построить параметры QUIC профиля из стратегии
build_quic_profile_params() {
    local params=$1
    echo "--filter-udp=443 --filter-l7=quic ${params}"
}

# Получить параметры текущей QUIC стратегии
get_current_quic_profile_params() {
    local quic_strategy
    quic_strategy=$(get_current_quic_strategy)
    local quic_params
    quic_params=$(get_quic_strategy "$quic_strategy" 2>/dev/null)

    if [ -z "$quic_params" ]; then
        quic_params="--payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"
    fi

    build_quic_profile_params "$quic_params"
}


# Проверить поддержку HTTP/3 (QUIC) в curl
curl_supports_http3() {
    curl --version 2>/dev/null | grep -qi "HTTP3"
}

# Проверка QUIC доступности
test_strategy_quic() {
    local domain=$1
    local timeout=${2:-5}
    local url=$domain

    if ! curl_supports_http3; then
        print_warning "curl не поддерживает HTTP/3, тест QUIC недоступен"
        return 2
    fi

    case "$url" in
        http://*|https://*)
            ;;
        *)
            url="https://${url}"
            ;;
    esac

    curl --http3 -I -s -m "$timeout" "$url" >/dev/null 2>&1
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

# Получить список всех стратегий из strategies.conf
get_all_strategies_list() {
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        return 1
    fi

    grep -o '^[0-9]\+' "$conf" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
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

# Проверки наличия параметров в стратегии
params_has_filter_tcp() {
    case " $1 " in
        *" --filter-tcp="*) return 0 ;;
        *) return 1 ;;
    esac
}

params_has_filter_l7() {
    case " $1 " in
        *" --filter-l7="*) return 0 ;;
        *) return 1 ;;
    esac
}

params_has_payload() {
    case " $1 " in
        *" --payload="*) return 0 ;;
        *) return 1 ;;
    esac
}

build_tls_profile_params() {
    local params=$1
    local prefix=""
    local payload=""

    if ! params_has_filter_tcp "$params"; then
        prefix="--filter-tcp=443,2053,2083,2087,2096,8443"
    fi
    if ! params_has_filter_l7 "$params"; then
        prefix="${prefix} --filter-l7=tls"
    fi
    if ! params_has_payload "$params"; then
        payload="--payload=tls_client_hello"
    fi

    # --out-range: прекращает обработку Lua после 32768+1460 байт исходящих данных.
    # После TLS хендшейка DPI уже не вмешивается — экономим CPU на роутере.
    local out_range=""
    case " $params " in
        *" --out-range="*) ;;
        *) out_range="--out-range=-s34228" ;;
    esac

    printf "%s" "${prefix:+$prefix }${payload:+$payload }${out_range:+$out_range }${params}"
}

build_http_profile_params() {
    local params=$1
    local prefix=""
    local payload=""

    if ! params_has_filter_tcp "$params"; then
        prefix="--filter-tcp=80"
    fi
    if ! params_has_filter_l7 "$params"; then
        prefix="${prefix} --filter-l7=http"
    fi
    if ! params_has_payload "$params"; then
        payload="--payload=http_req"
    fi

    printf "%s %s %s" "$prefix" "$payload" "$params"
}

# ==============================================================================
# ПРИМЕНЕНИЕ СТРАТЕГИЙ (УПРОЩЁННАЯ АРХИТЕКТУРА)
# ==============================================================================

# Применить стратегию (единый профиль для всех доменов)
# Сохраняет номер стратегии и обновляет NFQWS2_OPT в config
apply_strategy_simple() {
    local strategy_num=$1
    local zapret_config="${ZAPRET2_DIR:-/opt/zapret2}/config"

    if ! strategy_exists "$strategy_num"; then
        print_error "Стратегия #$strategy_num не найдена"
        return 1
    fi

    # Сохранить номер текущей стратегии
    mkdir -p "$CONFIG_DIR"
    echo "CURRENT_STRATEGY=$strategy_num" > "$CURRENT_STRATEGY_FILE"

    # Обновить NFQWS2_OPT в config
    . "${LIB_DIR}/config_official.sh"
    update_nfqws2_opt_in_config "$zapret_config" || return 1

    # Перезапустить сервис
    local init_script="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
    [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1
    sleep 2

    if is_zapret2_running; then
        print_success "Стратегия #$strategy_num применена"
        return 0
    else
        print_warning "Сервис не запустился"
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

    if test_strategy_http "rutracker.org" "$timeout"; then
        score=$((score + 1))
    fi

    if test_strategy_tls "rutracker.org" "$timeout"; then
        score=$((score + 1))
    fi

    # Тест YouTube
    if test_strategy_tls "www.youtube.com" "$timeout"; then
        score=$((score + 1))
    fi

    # Тест Discord
    if test_strategy_tls "discord.com" "$timeout"; then
        score=$((score + 1))
    fi

    # Тест googlevideo
    if test_strategy_tls "googlevideo.com" "$timeout"; then
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
    if ! apply_strategy_simple "$num"; then
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
        read -r answer </dev/tty

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

    # КРИТИЧНО: Добавить временные правила в OUTPUT chain для curl с роутера
    iptables -t mangle -I OUTPUT -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null
    iptables -t mangle -I OUTPUT -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null

    # Гарантировать очистку iptables при любом выходе (Ctrl+C, ошибка и т.д.)
    trap 'iptables -t mangle -D OUTPUT -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null; iptables -t mangle -D OUTPUT -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null' EXIT INT TERM

    # Проверка TLS 1.2
    if curl --tls-max 1.2 --max-time "$timeout" -s -o /dev/null "https://${domain}" 2>/dev/null; then
        tls12_success=1
    fi

    # Проверка TLS 1.3
    if curl --tlsv1.3 --max-time "$timeout" -s -o /dev/null "https://${domain}" 2>/dev/null; then
        tls13_success=1
    fi

    # Удалить временные правила и снять trap
    iptables -t mangle -D OUTPUT -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null
    iptables -t mangle -D OUTPUT -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null
    trap - EXIT INT TERM

    # Успех если хотя бы один из протоколов работает
    if [ "$tls12_success" -eq 1 ] || [ "$tls13_success" -eq 1 ]; then
        return 0
    else
        return 1
    fi
}

test_strategy_http() {
    local domain=$1
    local timeout=${2:-3}

    iptables -t mangle -I OUTPUT -p tcp --dport 80 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null

    if curl -s -m "$timeout" -I "http://${domain}" 2>/dev/null | grep -q "HTTP"; then
        iptables -t mangle -D OUTPUT -p tcp --dport 80 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null
        return 0
    fi

    iptables -t mangle -D OUTPUT -p tcp --dport 80 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null
    return 1
}

# Генерация тестового домена Google Video (на основе get_yt_cluster_domain из Z4R)
# Использует внешний API для получения реального живого кластера YouTube
generate_gv_domain() {
    # Оригинальный алгоритм из zapret4rocket (lib/netcheck.sh)
    # Карты букв для cipher mapping (32 символа через пробелы)
    local letters_map_a="u z p k f a 5 0 v q l g b 6 1 w r m h c 7 2 x s n i d 8 3 y t o j e 9 4 -"
    local letters_map_b="0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z -"

    # Получить cluster codename (ДВА РАЗА для пробития нерелевантного ответа)
    local cluster_codename
    cluster_codename=$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no" 2>/dev/null | sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')
    # Второй раз для пробития нерелевантного ответа
    cluster_codename=$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no" 2>/dev/null | sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')

    # Если не удалось получить, вернуть известный рабочий домен
    if [ -z "$cluster_codename" ]; then
        print_warning "GV redirector недоступен, используем fallback домен" >&2
        echo "rr1---sn-5goeenes.googlevideo.com"
        return 0
    fi

    # Cipher mapping
    local converted_name=""
    local i=0
    while [ "$i" -lt "${#cluster_codename}" ]; do
        # Получить символ
        local char
        if command -v cut >/dev/null 2>&1; then
            char=$(echo "$cluster_codename" | cut -c$((i+1)))
        else
            # Fallback для систем без cut
            char="${cluster_codename:$i:1}"
        fi

        # Найти индекс в map_a
        local idx=1
        for a in $letters_map_a; do
            if [ "$a" = "$char" ]; then
                break
            fi
            idx=$((idx+1))
        done

        # Получить соответствующий символ из map_b
        local b
        b=$(echo "$letters_map_b" | cut -d' ' -f $idx)
        converted_name="${converted_name}${b}"

        i=$((i+1))
    done

    echo "rr1---sn-${converted_name}.googlevideo.com"
}

# Генерация quic_strategies.conf из quic_strats.ini
# Формат входа: INI секции [name], desc=..., args=...
# Формат выхода: [NUMBER]|[NAME]|[ARGS]|[DESC]
generate_quic_strategies_conf() {
    local input_file=$1
    local output_file=$2

    if [ ! -f "$input_file" ]; then
        print_error "Файл не найден: $input_file"
        return 1
    fi

    print_info "Парсинг $input_file..."

    cat > "$output_file" <<'EOF'
# Zapret2 QUIC/UDP Strategies Database
# Сгенерировано из quic_strats.ini
# Формат: [NUMBER]|[NAME]|[ARGS]|[DESC]
EOF

    local num=1
    local name=""
    local desc=""
    local args=""

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
            \[*\])
                if [ -n "$name" ] && [ -n "$args" ]; then
                    echo "${num}|${name}|${args}|${desc}" >> "$output_file"
                    num=$((num + 1))
                fi
                name=$(echo "$line" | sed 's/^\[\(.*\)\]$/\1/')
                desc=""
                args=""
                ;;
            desc=*)
                desc=${line#desc=}
                ;;
            args=*)
                args=${line#args=}
                ;;
        esac
    done < "$input_file"

    if [ -n "$name" ] && [ -n "$args" ]; then
        echo "${num}|${name}|${args}|${desc}" >> "$output_file"
    fi

    local total_count
    total_count=$(grep -c '^[0-9]' "$output_file" 2>/dev/null || echo "0")
    print_success "Сгенерировано QUIC стратегий: $total_count"

    return 0
}

# ==============================================================================
# АВТОТЕСТ ПО КАТЕГОРИЯМ (Z4R МЕТОД)
# ==============================================================================

# Автотест YouTube TCP (youtube.com)
# Тестирует все стратегии и возвращает номер первой работающей
auto_test_youtube_tcp() {
    local strategies_list="${1:-$(get_all_strategies_list)}"
    local domain="www.youtube.com"
    local tested=0
    local total=0

    for _ in $strategies_list; do
        total=$((total + 1))
    done

    if [ "$total" -eq 0 ]; then
        print_warning "Список стратегий пуст"
        echo "1"
        return 1
    fi

    print_info "Тестирование YouTube TCP (youtube.com)..." >&2

    for num in $strategies_list; do
        tested=$((tested + 1))
        printf "  [%d/%d] Стратегия #%s... " "$tested" "$total" "$num" >&2

        # Применить стратегию (подавляем вывод для чистоты)
        apply_strategy_simple "$num" >/dev/null 2>&1
        local apply_result=$?
        if [ "$apply_result" -ne 0 ]; then
            printf "ОШИБКА\n" >&2
            continue
        fi

        # Подождать 2 секунды для применения
        sleep 2

        # Протестировать через TLS
        if test_strategy_tls "$domain" 3; then
            printf "РАБОТАЕТ\n" >&2
            print_success "Найдена работающая стратегия для YouTube TCP: #$num" >&2
            echo "$num"
            return 0
        else
            printf "НЕ РАБОТАЕТ\n" >&2
        fi
    done

    # Если ничего не работает, вернуть стратегию по умолчанию
    print_warning "Не найдено работающих стратегий для YouTube TCP, используется #1" >&2
    echo "1"
    return 1
}

# Автотест YouTube GV (googlevideo CDN)
# Тестирует все стратегии для Google Video и возвращает номер первой работающей
auto_test_youtube_gv() {
    local strategies_list="${1:-$(get_all_strategies_list)}"
    local tested=0
    local total=0

    for _ in $strategies_list; do
        total=$((total + 1))
    done

    if [ "$total" -eq 0 ]; then
        print_warning "Список стратегий пуст"
        echo "1"
        return 1
    fi

    print_info "Генерация тестового домена Google Video..." >&2
    local domain
    domain=$(generate_gv_domain)
    print_info "Тестовый домен: $domain" >&2

    print_info "Тестирование YouTube GV (Google Video)..." >&2

    for num in $strategies_list; do
        tested=$((tested + 1))
        printf "  [%d/%d] Стратегия #%s... " "$tested" "$total" "$num" >&2

        # Применить стратегию (подавляем вывод для чистоты)
        apply_strategy_simple "$num" >/dev/null 2>&1
        local apply_result=$?
        if [ "$apply_result" -ne 0 ]; then
            printf "ОШИБКА\n" >&2
            continue
        fi

        # Подождать 2 секунды для применения
        sleep 2

        # Протестировать через TLS
        if test_strategy_tls "$domain" 3; then
            printf "РАБОТАЕТ\n" >&2
            print_success "Найдена работающая стратегия для YouTube GV: #$num" >&2
            echo "$num"
            return 0
        else
            printf "НЕ РАБОТАЕТ\n" >&2
        fi
    done

    # Если ничего не работает, вернуть стратегию по умолчанию
    print_warning "Не найдено работающих стратегий для YouTube GV, используется #1" >&2
    echo "1"
    return 1
}

# Автотест RKN (meduza.io, facebook.com, rutracker.org)
# Тестирует все стратегии для RKN доменов и возвращает номер первой работающей
auto_test_rkn() {
    local strategies_list="${1:-$(get_all_strategies_list)}"
    local test_domains="meduza.io facebook.com rutracker.org"
    local tested=0
    local total=0

    for _ in $strategies_list; do
        total=$((total + 1))
    done

    if [ "$total" -eq 0 ]; then
        print_warning "Список стратегий пуст"
        echo "1"
        return 1
    fi

    print_info "Тестирование RKN (meduza.io, facebook.com, rutracker.org)..." >&2

    for num in $strategies_list; do
        tested=$((tested + 1))
        printf "  [%d/%d] Стратегия #%s... " "$tested" "$total" "$num" >&2

        # Применить стратегию (подавляем вывод для чистоты)
        apply_strategy_simple "$num" >/dev/null 2>&1
        local apply_result=$?
        if [ "$apply_result" -ne 0 ]; then
            printf "ОШИБКА\n" >&2
            continue
        fi

        # Подождать 2 секунды для применения
        sleep 2

        # Протестировать на всех трех доменах
        local success_count=0
        for domain in $test_domains; do
            if test_strategy_tls "$domain" 3; then
                success_count=$((success_count + 1))
            fi
        done

        # Успех если работает хотя бы на 2 из 3 доменов
        if [ "$success_count" -ge 2 ]; then
            printf "РАБОТАЕТ (%d/3)\n" "$success_count" >&2
            print_success "Найдена работающая стратегия для RKN: #$num" >&2
            echo "$num"
            return 0
        else
            printf "НЕ РАБОТАЕТ (%d/3)\n" "$success_count" >&2
        fi
    done

    # Если ничего не работает, вернуть стратегию по умолчанию
    print_warning "Не найдено работающих стратегий для RKN, используется #1" >&2
    echo "1"
    return 1
}

# ==============================================================================
# АВТОТЕСТ ВСЕХ СТРАТЕГИЙ
# ==============================================================================

# Автоматическое тестирование всех стратегий
auto_test_top20() {
    local auto_mode=0

    # Проверить флаг --auto
    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    if [ ! -f "${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}" ]; then
        print_error "Файл стратегий не найден: ${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"
        return 1
    fi

    print_header "Автотест стратегий"

    print_info "Будут протестированы все доступные стратегии"
    print_info "Оценка: 0-5 баллов (5 доменов)"
    print_info "Это займет около 2-3 минут"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Начать тестирование?"; then
            print_info "Автотест отменен"
            return 0
        fi
    fi

    local strategies_list
    strategies_list=$(get_all_strategies_list)
    local best_score=0
    local best_strategy=0
    local tested=0
    local total=0

    for _ in $strategies_list; do
        total=$((total + 1))
    done

    if [ "$total" -eq 0 ]; then
        print_error "Не найдены стратегии для тестирования"
        return 1
    fi

    for num in $strategies_list; do
        tested=$((tested + 1))

        printf "\n[%d/%d] Тестирование стратегии #%s...\n" "$tested" "$total" "$num"

        # Применить стратегию (без подтверждения)
        apply_strategy_simple "$num" >/dev/null 2>&1 || {
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
        apply_strategy_simple "$best_strategy"
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
            apply_strategy_simple "$best_strategy"
            print_success "Стратегия #$best_strategy применена"
            return 0
            ;;
    esac
}

# ==============================================================================
# АВТОТЕСТ ПО КАТЕГОРИЯМ V2 (Z4R РЕФЕРЕНС)
# ==============================================================================

# Автоматическое тестирование стратегий (единая для всех доменов)
# Тестирует YouTube TCP, YouTube GV, RKN и выбирает лучшую общую стратегию
auto_test_all_categories_v2() {
    local auto_mode=0

    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    if [ ! -f "${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}" ]; then
        print_error "Файл стратегий не найден: ${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"
        return 1
    fi

    print_header "Автоподбор лучшей стратегии"

    print_info "Тестируются все стратегии на нескольких доменах"
    print_info "Это займет около 5-8 минут"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Начать тестирование?"; then
            print_info "Автотест отменен"
            return 0
        fi
    fi

    # Делегируем в auto_test_top20 с --auto если нужно
    if [ "$auto_mode" -eq 1 ]; then
        auto_test_top20 --auto
    else
        auto_test_top20
    fi
    return $?
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
        apply_strategy_simple "$num" >/dev/null 2>&1 || {
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
        read -r answer </dev/tty

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Стратегия не применена"
                ;;
            *)
                apply_strategy_simple "$best_strategy"
                ;;
        esac
    fi
}

# ==============================================================================
# ПРИМЕНЕНИЕ СТРАТЕГИЙ ПО КАТЕГОРИЯМ
# ==============================================================================


# ==============================================================================
# АВТОТЕСТ QUIC СТРАТЕГИЙ
# ==============================================================================

auto_test_quic() {
    local auto_mode=0

    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    if ! curl_supports_http3; then
        print_warning "curl не поддерживает HTTP/3, QUIC автотест недоступен"
        return 1
    fi

    if [ ! -f "${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}" ]; then
        print_error "Файл QUIC стратегий не найден: ${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"
        return 1
    fi

    print_header "Автотест QUIC стратегий (UDP 443)"
    print_info "Будут протестированы QUIC стратегии"
    print_info "Домен(ы): rutracker.org, static.rutracker.cc"
    print_info "Оценка: 0-2 балла"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Начать тестирование?" "Y"; then
            print_info "Автотест отменен"
            return 0
        fi
    fi

    local strategies_list
    strategies_list=$(get_all_quic_strategies_list)
    local best_score=0
    local best_strategy=0
    local tested=0
    local total=0

    for _ in $strategies_list; do
        total=$((total + 1))
    done

    if [ "$total" -eq 0 ]; then
        print_error "Не найдены QUIC стратегии для тестирования"
        return 1
    fi

    local original_quic
    original_quic=$(get_current_quic_strategy)

    for num in $strategies_list; do
        tested=$((tested + 1))

        printf "\n[%d/%d] Тестирование QUIC стратегии #%s...\n" "$tested" "$total" "$num"

        set_current_quic_strategy "$num"
        . "${LIB_DIR}/config_official.sh"
        update_nfqws2_opt_in_config "${ZAPRET2_DIR:-/opt/zapret2}/config" >/dev/null 2>&1
        local init_script="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
        [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1 || {
            print_warning "Не удалось применить QUIC стратегию #$num"
            continue
        }

        sleep 3

        local score=0
        if test_strategy_quic "youtube.com" 5; then
            score=$((score + 1))
        fi
        if test_strategy_quic "googlevideo.com" 5; then
            score=$((score + 1))
        fi

        printf "  Оценка: %s/2\n" "$score"

        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best_strategy=$num
            print_success "  Новый лидер: #$num ($score/2)"
        fi
    done

    if [ -n "$original_quic" ]; then
        set_current_quic_strategy "$original_quic"
        . "${LIB_DIR}/config_official.sh"
        update_nfqws2_opt_in_config "${ZAPRET2_DIR:-/opt/zapret2}/config" >/dev/null 2>&1 || true
        [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1 || true
    fi

    printf "\n"
    print_separator
    print_success "QUIC автотест завершен"
    printf "Лучшая QUIC стратегия: #%s (оценка: %s/2)\n" "$best_strategy" "$best_score"
    print_separator

    if [ "$best_strategy" -eq 0 ]; then
        print_error "Не найдено работающих QUIC стратегий"
        return 1
    fi

    _apply_quic_choice() {
        set_current_quic_strategy "$best_strategy"
        . "${LIB_DIR}/config_official.sh"
        update_nfqws2_opt_in_config "${ZAPRET2_DIR:-/opt/zapret2}/config" >/dev/null 2>&1
        local _init="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
        [ -f "$_init" ] && "$_init" restart >/dev/null 2>&1
    }

    if [ "$auto_mode" -eq 1 ]; then
        _apply_quic_choice
        print_success "QUIC стратегия #$best_strategy применена автоматически"
        return 0
    fi

    printf "\nПрименить QUIC стратегию #%s? [Y/n]: " "$best_strategy"
    read -r answer </dev/tty

    case "$answer" in
        [Nn]|[Nn][Oo])
            print_info "QUIC стратегия не применена"
            return 0
            ;;
        *)
            _apply_quic_choice
            print_success "QUIC стратегия применена"
            return 0
            ;;
    esac
}


# Применить autocircular стратегии (автоперебор внутри профиля)
# Динамически находит стратегии с circular оркестратором по имени в базе
apply_autocircular_strategies() {
    local auto_mode=0

    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    print_header "Применение autocircular стратегий"

    # Динамический поиск TCP autocircular стратегии
    local tcp_num
    tcp_num=$(find_strategy_by_name "manual_autocircular_yt")
    if [ -z "$tcp_num" ]; then
        print_warning "Autocircular TCP стратегия не найдена в базе, используется #1"
        tcp_num=1
    fi

    # Динамический поиск QUIC autocircular стратегии
    local quic_num
    quic_num=$(find_quic_strategy_by_name "yt_quic_autocircular")
    if [ -z "$quic_num" ]; then
        print_warning "Autocircular QUIC стратегия не найдена в базе, используется #1"
        quic_num=1
    fi

    # Показать информацию о найденных стратегиях
    local tcp_params
    tcp_params=$(get_strategy "$tcp_num")
    if [ -n "$tcp_params" ]; then
        case "$tcp_params" in
            *"--lua-desync=circular:"*)
                print_info "  TCP: #$tcp_num (circular, $(echo "$tcp_params" | grep -o 'strategy=[0-9]*' | wc -l) вариантов)" ;;
            *)
                print_info "  TCP: #$tcp_num (без circular оркестратора)" ;;
        esac
    fi

    local quic_params
    quic_params=$(get_quic_strategy "$quic_num" 2>/dev/null)
    if [ -n "$quic_params" ]; then
        case "$quic_params" in
            *"--lua-desync=circular:"*)
                print_info "  QUIC: #$quic_num (circular, $(echo "$quic_params" | grep -o 'strategy=[0-9]*' | wc -l) вариантов)" ;;
            *)
                print_info "  QUIC: #$quic_num (без circular оркестратора)" ;;
        esac
    fi

    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Применить autocircular стратегии?"; then
            print_info "Отменено"
            return 0
        fi
    fi

    # Применить TCP стратегию
    apply_strategy_simple "$tcp_num"

    # Применить QUIC стратегию
    if quic_strategy_exists "$quic_num"; then
        set_current_quic_strategy "$quic_num"
    else
        print_warning "QUIC стратегия #$quic_num не найдена, оставляю текущую"
    fi

    # Перегенерировать config с обеими стратегиями
    . "${LIB_DIR}/config_official.sh"
    update_nfqws2_opt_in_config "${ZAPRET2_DIR:-/opt/zapret2}/config" || return 1

    # Перезапустить сервис
    local init_script="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
    [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1
    sleep 2

    if is_zapret2_running; then
        print_success "Autocircular стратегии применены"
    else
        print_warning "Сервис не запустился"
    fi

    return 0
}

# ==============================================================================
# КОНСТРУКТОР CIRCULAR СТРАТЕГИЙ
# ==============================================================================

# Парсинг диапазона: "1,3,5-10,15" → "1 3 5 6 7 8 9 10 15"
parse_strategy_range() {
    local input=$1
    local result=""
    local items
    items=$(echo "$input" | tr ',' ' ')

    for item in $items; do
        case "$item" in
            *-*)
                local range_start range_end
                range_start=$(echo "$item" | cut -d'-' -f1)
                range_end=$(echo "$item" | cut -d'-' -f2)
                case "$range_start$range_end" in *[!0-9]*) continue ;; esac
                [ "$range_start" -gt "$range_end" ] 2>/dev/null && continue
                local i=$range_start
                while [ "$i" -le "$range_end" ]; do
                    result="$result $i"
                    i=$((i + 1))
                done
                ;;
            *)
                case "$item" in *[!0-9]*) continue ;; esac
                [ -n "$item" ] && result="$result $item"
                ;;
        esac
    done
    echo "$result" | sed 's/^ *//'
}

# Извлечь --lua-desync=... инстансы из параметров стратегии
extract_desync_instances() {
    local params=$1
    local result=""
    local rest="$params"

    while true; do
        case "$rest" in
            *"--lua-desync="*)
                rest="${rest#*--lua-desync=}"
                local value
                case "$rest" in
                    *" --"*) value="${rest%% --*}"; rest="${rest#* }" ;;
                    *) value="$rest"; rest="" ;;
                esac
                result="$result --lua-desync=$value"
                ;;
            *) break ;;
        esac
    done
    echo "$result" | sed 's/^ *//'
}

# Собрать circular TCP стратегию из набора
# $1 - номера стратегий (пробел), $2 - fails, $3 - time
build_circular_params() {
    local strategy_nums=$1
    local fails=${2:-2}
    local time_sec=${3:-60}

    local prefix="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --out-range=-n10"
    local head="--lua-desync=circular:fails=${fails}:time=${time_sec}"
    local instances=""
    local sn=1

    for num in $strategy_nums; do
        local params
        params=$(get_strategy "$num")
        [ -z "$params" ] && continue

        local desync_parts
        desync_parts=$(extract_desync_instances "$params")
        [ -z "$desync_parts" ] && continue

        local part_rest="$desync_parts"
        while true; do
            case "$part_rest" in
                *"--lua-desync="*)
                    part_rest="${part_rest#*--lua-desync=}"
                    local value
                    case "$part_rest" in
                        *" --lua-desync="*) value="${part_rest%% --lua-desync=*}"; part_rest="--lua-desync=${part_rest#* --lua-desync=}" ;;
                        *) value="$part_rest"; part_rest="" ;;
                    esac
                    value=$(echo "$value" | sed 's/:strategy=[0-9]*//g')
                    case "$value" in
                        *":payload="*) ;;
                        "circular:"*) ;;
                        *) value="${value}:payload=tls_client_hello:dir=out" ;;
                    esac
                    case "$value" in
                        "circular:"*) ;;
                        *) instances="$instances --lua-desync=${value}:strategy=${sn}" ;;
                    esac
                    ;;
                *) break ;;
            esac
        done
        sn=$((sn + 1))
    done

    [ -z "$instances" ] && return 1
    echo "${prefix} ${head}${instances}"
}

# Собрать circular QUIC стратегию
# $1 - номера, $2 - fails, $3 - time, $4 - udp_in, $5 - udp_out
build_quic_circular_params() {
    local strategy_nums=$1
    local fails=${2:-2}
    local time_sec=${3:-60}
    local udp_in=${4:-1}
    local udp_out=${5:-4}

    local prefix="--filter-udp=443 --filter-l7=quic --in-range=a --out-range=a --payload=all"
    local head="--lua-desync=circular:fails=${fails}:time=${time_sec}:udp_in=${udp_in}:udp_out=${udp_out}"
    local instances=""
    local sn=1

    for num in $strategy_nums; do
        local params
        params=$(get_quic_strategy "$num" 2>/dev/null)
        [ -z "$params" ] && continue

        local desync_parts
        desync_parts=$(extract_desync_instances "$params")
        [ -z "$desync_parts" ] && continue

        local part_rest="$desync_parts"
        while true; do
            case "$part_rest" in
                *"--lua-desync="*)
                    part_rest="${part_rest#*--lua-desync=}"
                    local value
                    case "$part_rest" in
                        *" --lua-desync="*) value="${part_rest%% --lua-desync=*}"; part_rest="--lua-desync=${part_rest#* --lua-desync=}" ;;
                        *) value="$part_rest"; part_rest="" ;;
                    esac
                    value=$(echo "$value" | sed 's/:strategy=[0-9]*//g')
                    case "$value" in
                        "circular:"*) ;;
                        *":payload="*) instances="$instances --lua-desync=${value}:strategy=${sn}" ;;
                        *) instances="$instances --lua-desync=${value}:payload=quic_initial:dir=out:strategy=${sn}" ;;
                    esac
                    ;;
                *) break ;;
            esac
        done
        sn=$((sn + 1))
    done

    [ -z "$instances" ] && return 1
    echo "${prefix} ${head}${instances}"
}

# Параметры circular: загрузка/сохранение
load_circular_params() {
    CIRCULAR_FAILS=2; CIRCULAR_TIME=60; CIRCULAR_UDP_IN=1; CIRCULAR_UDP_OUT=4
    [ -f "${CONFIG_DIR}/circular_params.conf" ] && . "${CONFIG_DIR}/circular_params.conf"
}

save_circular_params() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    cat > "${CONFIG_DIR}/circular_params.conf" <<EOF
CIRCULAR_FAILS=${CIRCULAR_FAILS:-2}
CIRCULAR_TIME=${CIRCULAR_TIME:-60}
CIRCULAR_UDP_IN=${CIRCULAR_UDP_IN:-1}
CIRCULAR_UDP_OUT=${CIRCULAR_UDP_OUT:-4}
EOF
}

# Состав circular: сохранение/загрузка
save_circular_strategies() {
    local category=$1 strategy_list=$2
    local conf="${CONFIG_DIR}/circular_strategies.conf"
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    local csv
    csv=$(echo "$strategy_list" | tr ' ' ',')
    if [ -f "$conf" ] && grep -q "^${category}:" "$conf" 2>/dev/null; then
        sed -i "s|^${category}:.*|${category}:${csv}|" "$conf"
    else
        echo "${category}:${csv}" >> "$conf"
    fi
}

load_circular_strategies() {
    local category=$1
    [ -f "${CONFIG_DIR}/circular_strategies.conf" ] && \
        grep "^${category}:" "${CONFIG_DIR}/circular_strategies.conf" 2>/dev/null | cut -d':' -f2 | tr ',' ' '
}

# Применить custom circular TCP стратегию
# В новой архитектуре circular записывается как стратегия и применяется через config
apply_custom_circular() {
    local category=$1 strategy_nums=$2
    load_circular_params
    local circular_params
    circular_params=$(build_circular_params "$strategy_nums" "$CIRCULAR_FAILS" "$CIRCULAR_TIME") || {
        print_error "Не удалось собрать circular"; return 1
    }
    local count
    count=$(echo "$circular_params" | grep -o 'strategy=[0-9]*' | wc -l)
    print_info "TCP Circular: $count вариантов (fails=$CIRCULAR_FAILS, time=$CIRCULAR_TIME)"
    save_circular_strategies "TCP" "$strategy_nums"

    # Сохранить параметры circular в конфиг и применить
    mkdir -p "${CONFIG_DIR}" 2>/dev/null
    echo "CUSTOM_CIRCULAR_TCP_PARAMS=$circular_params" > "${CONFIG_DIR}/custom_circular_tcp.conf"

    . "${LIB_DIR}/config_official.sh"
    update_nfqws2_opt_in_config "${ZAPRET2_DIR:-/opt/zapret2}/config" || return 1
    local init_script="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
    [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1
}

# Применить circular QUIC
apply_custom_quic_circular() {
    local strategy_nums=$1
    load_circular_params
    local circular_params
    circular_params=$(build_quic_circular_params "$strategy_nums" "$CIRCULAR_FAILS" "$CIRCULAR_TIME" "$CIRCULAR_UDP_IN" "$CIRCULAR_UDP_OUT") || {
        print_error "Не удалось собрать QUIC circular"; return 1
    }
    local count
    count=$(echo "$circular_params" | grep -o 'strategy=[0-9]*' | wc -l)
    print_info "QUIC Circular: $count вариантов"
    save_circular_strategies "QUIC" "$strategy_nums"

    mkdir -p "${CONFIG_DIR}" 2>/dev/null
    echo "CUSTOM_CIRCULAR_QUIC_PARAMS=$circular_params" > "${CONFIG_DIR}/custom_circular_quic.conf"

    . "${LIB_DIR}/config_official.sh"
    update_nfqws2_opt_in_config "${ZAPRET2_DIR:-/opt/zapret2}/config" || return 1
    local init_script="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
    [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1
}

# Показать текущий circular набор
show_circular_info() {
    print_header "Текущие circular стратегии"

    # TCP стратегия
    local tcp_num
    tcp_num=$(find_strategy_by_name "manual_autocircular_yt")
    if [ -n "$tcp_num" ]; then
        local p
        p=$(get_strategy "$tcp_num")
        case "$p" in
            *"--lua-desync=circular:"*)
                local c; c=$(echo "$p" | grep -o 'strategy=[0-9]*' | wc -l)
                local fl; fl=$(echo "$p" | sed -n 's/.*circular:fails=\([0-9]*\).*/\1/p')
                local t; t=$(echo "$p" | sed -n 's/.*:time=\([0-9]*\).*/\1/p')
                printf "  TCP:     circular (%d вариантов, fails=%s, time=%s)\n" "$c" "$fl" "$t" ;;
            *) printf "  TCP:     обычная стратегия #%s\n" "$tcp_num" ;;
        esac
    else
        local cur; cur=$(get_current_strategy)
        printf "  TCP:     стратегия #%s\n" "$cur"
    fi

    # QUIC стратегия
    local quic_num
    quic_num=$(get_current_quic_strategy)
    local qp
    qp=$(get_quic_strategy "$quic_num" 2>/dev/null)
    if [ -n "$qp" ]; then
        case "$qp" in
            *"--lua-desync=circular:"*)
                local c; c=$(echo "$qp" | grep -o 'strategy=[0-9]*' | wc -l)
                local fl; fl=$(echo "$qp" | sed -n 's/.*circular:fails=\([0-9]*\).*/\1/p')
                local t; t=$(echo "$qp" | sed -n 's/.*:time=\([0-9]*\).*/\1/p')
                printf "  QUIC:    circular (%d вариантов, fails=%s, time=%s)\n" "$c" "$fl" "$t" ;;
            *) printf "  QUIC:    обычная стратегия #%s\n" "$quic_num" ;;
        esac
    else
        printf "  QUIC:    стратегия #%s\n" "$quic_num"
    fi
}

# ==============================================================================
# МОНИТОРИНГ NFQWS2
# ==============================================================================

send_nfqws2_signal() {
    local sig=$1
    is_zapret2_running || { print_error "nfqws2 не запущен"; return 1; }
    local pid; pid=$(pgrep -f "nfqws2" | head -n 1)
    [ -z "$pid" ] && { print_error "PID не найден"; return 1; }
    kill -"$sig" "$pid" 2>/dev/null || { print_error "Ошибка отправки $sig"; return 1; }
    print_success "Сигнал $sig отправлен (PID: $pid)"
}

# Чтение логов nfqws2 с платформо-зависимым источником
_read_nfqws2_log() {
    local lines=${1:-50}
    if [ -f /opt/var/log/messages ]; then
        grep -i "nfqws2" /opt/var/log/messages | tail -"$lines"
    elif command -v logread >/dev/null 2>&1; then
        logread 2>/dev/null | grep -i "nfqws2" | tail -"$lines"
    elif [ -f /var/log/syslog ]; then
        grep -i "nfqws2" /var/log/syslog | tail -"$lines"
    elif command -v journalctl >/dev/null 2>&1; then
        journalctl -u zapret2 --no-pager -n "$lines" 2>/dev/null
    else
        print_info "Лог не найден. Попробуйте: cat /opt/var/log/messages | grep nfqws2"
    fi
}

show_circular_state() {
    print_header "Состояние circular (SIGUSR2)"
    send_nfqws2_signal USR2 || return 1
    sleep 1
    _read_nfqws2_log 30
}

show_conntrack_pool() {
    print_header "Conntrack пул (SIGUSR1)"
    send_nfqws2_signal USR1 || return 1
    sleep 1
    _read_nfqws2_log 50
}

show_nfqws2_logs() {
    print_header "Логи nfqws2 (последние ${1:-50} строк)"
    _read_nfqws2_log "${1:-50}"
}

# ==============================================================================
# АВТОСБОРКА CIRCULAR ИЗ ТЕСТИРОВАНИЯ
# ==============================================================================

# Тестировать стратегии и вернуть рабочие
auto_discover_working_strategies() {
    local test_domain=${1:-"youtube.com"} strategy_nums=$2 min_score=${3:-3}
    local working="" tested=0 total=0
    for _ in $strategy_nums; do total=$((total + 1)); done

    for num in $strategy_nums; do
        tested=$((tested + 1))
        printf "\r  [%d/%d] #%s..." "$tested" "$total" "$num" >&2
        apply_strategy_simple "$num" >/dev/null 2>&1 || continue
        sleep 3
        local score; score=$(test_strategy_score)
        if [ "$score" -ge "$min_score" ]; then
            printf " OK (%d/5)\n" "$score" >&2
            working="$working $num"
        else
            printf " (%d/5)\n" "$score" >&2
        fi
    done
    printf "\n" >&2
    echo "$working" | sed 's/^ *//'
}

# Автосборка circular для категории
auto_build_circular() {
    local category=$1 range=${2:-"1-12"} min_score=${3:-3}
    local nums; nums=$(parse_strategy_range "$range")
    [ -z "$nums" ] && { print_error "Неверный диапазон: $range"; return 1; }

    local total; total=$(echo "$nums" | wc -w)
    print_info "Тестирование $total стратегий для $category..."

    local td
    case "$category" in
        YT) td="youtube.com" ;; YT_GV) td="googlevideo.com" ;; RKN) td="rutracker.org" ;; *) td="youtube.com" ;;
    esac

    local working; working=$(auto_discover_working_strategies "$td" "$nums" "$min_score")
    [ -z "$working" ] && { print_warning "Рабочих стратегий не найдено"; return 1; }

    local wc; wc=$(echo "$working" | wc -w)
    print_success "Найдено $wc рабочих стратегий: $working"
    apply_custom_circular "$category" "$working"
}
