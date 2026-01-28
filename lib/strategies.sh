#!/bin/sh
# lib/strategies.sh - Управление стратегиями zapret2
# Парсинг, тестирование, применение стратегий из strats_new2.txt
# QUIC/UDP стратегии берутся из quic_strats.ini

# ==============================================================================
# КОНСТАНТЫ ДЛЯ СТРАТЕГИЙ
# ==============================================================================

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
# РАБОТА С ФАЙЛАМИ СТРАТЕГИЙ ПО КАТЕГОРИЯМ (CONFIG-DRIVEN АРХИТЕКТУРА)
# ==============================================================================

# Сохранить стратегию в файл категории
# $1 - категория (YT, YT_GV, RKN, RUTRACKER)
# $2 - протокол (TCP или UDP)
# $3 - параметры стратегии
save_strategy_to_category() {
    local category=$1
    local protocol=$2
    local params=$3

    if [ -z "$category" ] || [ -z "$protocol" ] || [ -z "$params" ]; then
        print_error "save_strategy_to_category: некорректные параметры"
        return 1
    fi

    local strategy_file="${ZAPRET2_DIR:-/opt/zapret2}/extra_strats/${protocol}/${category}/Strategy.txt"

    # Создать директорию если не существует
    mkdir -p "$(dirname "$strategy_file")" || {
        print_error "Не удалось создать директорию для стратегии $category/$protocol"
        return 1
    }

    # Сохранить параметры
    echo "$params" > "$strategy_file" || {
        print_error "Не удалось сохранить стратегию в $strategy_file"
        return 1
    }

    return 0
}

# Создать дефолтные файлы стратегий при установке
# Вызывается из step_create_config_and_init()
create_default_strategy_files() {
    local extra_strats_dir="${ZAPRET2_DIR:-/opt/zapret2}/extra_strats"

    print_info "Создание дефолтных файлов стратегий..."

    # Дефолтная TCP стратегия
    local default_tcp="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"

    # Дефолтная UDP стратегия (QUIC)
    local default_udp="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"

    # Создать директории и файлы
    mkdir -p "$extra_strats_dir/TCP/YT"
    mkdir -p "$extra_strats_dir/TCP/YT_GV"
    mkdir -p "$extra_strats_dir/TCP/RKN"
    mkdir -p "$extra_strats_dir/UDP/YT"
    mkdir -p "$extra_strats_dir/UDP/RUTRACKER"

    # Сохранить дефолтные стратегии
    echo "$default_tcp" > "$extra_strats_dir/TCP/YT/Strategy.txt"
    echo "$default_tcp" > "$extra_strats_dir/TCP/YT_GV/Strategy.txt"
    echo "$default_tcp" > "$extra_strats_dir/TCP/RKN/Strategy.txt"
    echo "$default_udp" > "$extra_strats_dir/UDP/YT/Strategy.txt"
    echo "$default_udp" > "$extra_strats_dir/UDP/RUTRACKER/Strategy.txt"

    print_success "Дефолтные файлы стратегий созданы"
    return 0
}

# ==============================================================================
# ПАРСИНГ STRATS.TXT → STRATEGIES.CONF
# ==============================================================================

# Генерация strategies.conf из strats_new2.txt
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

# Получить текущую QUIC стратегию для RuTracker
get_rutracker_quic_strategy() {
    local conf="${RUTRACKER_QUIC_STRATEGY_FILE:-${CONFIG_DIR}/rutracker_quic_strategy.conf}"
    if [ -f "$conf" ]; then
        . "$conf"
        [ -n "$RUTRACKER_QUIC_STRATEGY" ] && echo "$RUTRACKER_QUIC_STRATEGY" && return 0
    fi
    echo "43"
}

# Проверить включен ли QUIC для RuTracker
is_rutracker_quic_enabled() {
    local conf="${CONFIG_DIR}/rutracker_quic_enabled.conf"
    if [ -f "$conf" ]; then
        . "$conf"
        [ "$RUTRACKER_QUIC_ENABLED" = "1" ] && return 0
    fi
    return 1
}

# Включить/выключить QUIC для RuTracker
set_rutracker_quic_enabled() {
    local enabled=$1  # 1 или 0
    local conf="${CONFIG_DIR}/rutracker_quic_enabled.conf"
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    echo "RUTRACKER_QUIC_ENABLED=${enabled}" > "$conf"
}


# Сохранить текущую QUIC стратегию
set_current_quic_strategy() {
    local num=$1
    local conf="${QUIC_STRATEGY_FILE:-${CONFIG_DIR}/quic_strategy.conf}"
    echo "QUIC_STRATEGY=$num" > "$conf"
}

# Сохранить текущую QUIC стратегию для RuTracker
set_rutracker_quic_strategy() {
    local num=$1
    local conf="${RUTRACKER_QUIC_STRATEGY_FILE:-${CONFIG_DIR}/rutracker_quic_strategy.conf}"
    echo "RUTRACKER_QUIC_STRATEGY=$num" > "$conf"
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

# Получить параметры QUIC профиля для RuTracker
get_rutracker_quic_profile_params() {
    local quic_strategy
    quic_strategy=$(get_rutracker_quic_strategy)
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

    printf "%s %s %s" "$prefix" "$payload" "$params"
}

# ==============================================================================
# ГЕНЕРАЦИЯ MULTI-PROFILE КОНФИГУРАЦИИ
# ==============================================================================

# Генерация мульти-профиля (TCP + UDP) из базовых параметров
generate_multiprofile() {
    local base_params=$1
    local type=$2

    # Генерация переменных для init скрипта (применяется ко всем категориям)
    local tcp_params

    if [ "$type" = "http" ]; then
        tcp_params=$(build_http_profile_params "$base_params")
    else
        tcp_params=$(build_tls_profile_params "$base_params")
    fi

    local quic_params
    quic_params=$(get_current_quic_profile_params)

    local discord_udp
    discord_udp=$(get_init_udp_params "DISCORD" "${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}")
    if [ -z "$discord_udp" ]; then
        discord_udp="--filter-udp=50000-50099,1400,3478-3481,5349 --filter-l7=discord,stun --payload=stun,discord_ip_discovery --out-range=-n10 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2"
    fi

    # Генерировать переменные для всех категорий (YouTube TCP, GV, RKN)
    cat <<PROFILE
# YouTube TCP стратегия (интерфейс YouTube)
# YOUTUBE_TCP_MARKER_START
YOUTUBE_TCP_TCP="$tcp_params"
YOUTUBE_TCP_UDP=""
# YOUTUBE_TCP_MARKER_END

# YouTube GV стратегия (Google Video CDN)
# YOUTUBE_GV_MARKER_START
YOUTUBE_GV_TCP="$tcp_params"
YOUTUBE_GV_UDP=""
# YOUTUBE_GV_MARKER_END

# RKN стратегия (заблокированные сайты)
# RKN_MARKER_START
RKN_TCP="$tcp_params"
RKN_UDP=""
# RKN_MARKER_END

# Discord стратегия (сообщения и голос)
# DISCORD_MARKER_START
DISCORD_TCP="$tcp_params"
DISCORD_UDP="$discord_udp"
# DISCORD_MARKER_END

# Custom стратегия (пользовательские домены)
# CUSTOM_MARKER_START
CUSTOM_TCP="$tcp_params"
CUSTOM_UDP=""
# CUSTOM_MARKER_END

# QUIC стратегия (YouTube UDP 443)
# QUIC_MARKER_START
QUIC_TCP=""
QUIC_UDP="$quic_params"
# QUIC_MARKER_END

# QUIC стратегия (RuTracker UDP 443)
# QUIC_RKN_MARKER_START
QUIC_RKN_TCP=""
QUIC_RKN_UDP="$quic_params"
# QUIC_RKN_MARKER_END
PROFILE
}

# ==============================================================================
# ПРИМЕНЕНИЕ СТРАТЕГИЙ К INIT СКРИПТУ
# ==============================================================================

# Применить стратегию (config-driven архитектура)
# Сохраняет стратегию в файлы категорий и обновляет config файл
apply_strategy() {
    local strategy_num=$1
    local zapret_config="${ZAPRET2_DIR:-/opt/zapret2}/config"
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

    # Построить полные TCP параметры
    local tcp_params
    if [ "$type" = "http" ]; then
        tcp_params=$(build_http_profile_params "$params")
    else
        tcp_params=$(build_tls_profile_params "$params")
    fi

    # Получить текущие QUIC параметры
    local udp_params
    udp_params=$(get_current_quic_profile_params)

    # Сохранить стратегию во все категории (единая стратегия для всех)
    print_info "Сохранение стратегии в файлы категорий..."
    save_strategy_to_category "YT" "TCP" "$tcp_params" || return 1
    save_strategy_to_category "YT_GV" "TCP" "$tcp_params" || return 1
    save_strategy_to_category "RKN" "TCP" "$tcp_params" || return 1
    save_strategy_to_category "YT" "UDP" "$udp_params" || return 1
    save_strategy_to_category "RUTRACKER" "UDP" "$udp_params" || return 1

    # Обновить config файл (NFQWS2_OPT секцию)
    print_info "Обновление config файла..."
    . "${LIB_DIR}/config_official.sh" || {
        print_error "Не удалось загрузить config_official.sh"
        return 1
    }

    update_nfqws2_opt_in_config "$zapret_config" || {
        print_error "Не удалось обновить config файл"
        return 1
    }

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

    # КРИТИЧНО: Добавить временные правила в OUTPUT chain для curl с роутера
    iptables -t mangle -I OUTPUT -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null
    iptables -t mangle -I OUTPUT -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null

    # Проверка TLS 1.2
    if curl --tls-max 1.2 --max-time "$timeout" -s -o /dev/null "https://${domain}" 2>/dev/null; then
        tls12_success=1
    fi

    # Проверка TLS 1.3
    if curl --tlsv1.3 --max-time "$timeout" -s -o /dev/null "https://${domain}" 2>/dev/null; then
        tls13_success=1
    fi

    # Удалить временные правила
    iptables -t mangle -D OUTPUT -p tcp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null
    iptables -t mangle -D OUTPUT -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null

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
        echo "rr1---sn-5goeenes.googlevideo.com" >&2
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

        # Применить стратегию (показываем ошибки для отладки)
        apply_strategy "$num" >&2
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

        # Применить стратегию (показываем ошибки для отладки)
        apply_strategy "$num" >&2
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

        # Применить стратегию (показываем ошибки для отладки)
        apply_strategy "$num" >&2
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

# Автоматическое тестирование всех стратегий для каждой категории (Z4R метод)
# Тестирует 3 категории: YouTube TCP, YouTube GV, RKN
# Каждая категория получает свою первую работающую стратегию
auto_test_all_categories_v2() {
    local auto_mode=0

    # Проверить флаг --auto
    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    if [ ! -f "${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}" ]; then
        print_error "Файл стратегий не найден: ${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"
        return 1
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
    local strategies_list
    strategies_list=$(get_all_strategies_list)
    auto_test_youtube_tcp "$strategies_list" > "$result_file_tcp"
    local yt_tcp_result=$?
    local yt_tcp_strategy=$(tail -1 "$result_file_tcp" 2>/dev/null | tr -d '\n' || echo "1")

    printf "\n"
    print_separator
    print_info "Тестирование YouTube GV..."
    auto_test_youtube_gv "$strategies_list" > "$result_file_gv"
    local yt_gv_result=$?
    local yt_gv_strategy=$(tail -1 "$result_file_gv" 2>/dev/null | tr -d '\n' || echo "1")

    printf "\n"
    print_separator
    print_info "Тестирование RKN..."
    auto_test_rkn "$strategies_list" > "$result_file_rkn"
    local rkn_result=$?
    local rkn_strategy=$(tail -1 "$result_file_rkn" 2>/dev/null | tr -d '\n' || echo "1")

    # Очистить временные файлы
    rm -f "$result_file_tcp" "$result_file_gv" "$result_file_rkn"

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

    # Применить стратегии (в авто и интерактивном режиме одинаково)
    if [ "$auto_mode" -eq 0 ]; then
        # В интерактивном режиме спросить подтверждение
        printf "\nПрименить эти стратегии? [Y/n]: "
        read -r answer </dev/tty

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Стратегии не применены"
                print_info "Используйте меню для ручного выбора"
                return 0
                ;;
        esac
    fi

    # Применить выбранные стратегии (автотест и дефолтные работают одинаково)
    printf "\n"
    apply_category_strategies_v2 "$yt_tcp_strategy" "$yt_gv_strategy" "$rkn_strategy"
    return 0
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
            tcp_params="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello ${params}"
            udp_params=""
        else
            tcp_params="--filter-tcp=80,443 --filter-l7=http ${params}"
            udp_params=""
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
    local found_section=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "# ${start_marker}"; then
            # Начало секции - записать маркер и новые параметры
            echo "$line"
            echo "${marker}_TCP=\"${tcp_params}\""
            echo "${marker}_UDP=\"${udp_params}\""
            inside_section=1
            found_section=1
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

    # Если секции не было в файле - добавить в конец
    if [ "$found_section" -eq 0 ]; then
        {
            echo ""
            echo "# ${start_marker}"
            echo "${marker}_TCP=\"${tcp_params}\""
            echo "${marker}_UDP=\"${udp_params}\""
            echo "# ${end_marker}"
        } >> "$temp_file"
    fi

    # Заменить init скрипт
    mv "$temp_file" "$init_script" || {
        print_error "Не удалось обновить init скрипт"
        return 1
    }

    chmod +x "$init_script"
}

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

    local config_file="${CONFIG_DIR}/category_strategies.conf"
    local current_yt_tcp="1"
    local current_yt_gv="1"
    local current_rkn="1"
    if [ -f "$config_file" ]; then
        current_yt_tcp=$(grep "^youtube_tcp:" "$config_file" 2>/dev/null | cut -d':' -f2)
        current_yt_gv=$(grep "^youtube_gv:" "$config_file" 2>/dev/null | cut -d':' -f2)
        current_rkn=$(grep "^rkn:" "$config_file" 2>/dev/null | cut -d':' -f2)
        [ -z "$current_yt_tcp" ] && current_yt_tcp="1"
        [ -z "$current_yt_gv" ] && current_yt_gv="1"
        [ -z "$current_rkn" ] && current_rkn="1"
    fi

    local original_quic
    original_quic=$(get_current_quic_strategy)

    for num in $strategies_list; do
        tested=$((tested + 1))

        printf "\n[%d/%d] Тестирование QUIC стратегии #%s...\n" "$tested" "$total" "$num"

        set_current_quic_strategy "$num"
        apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn" >/dev/null 2>&1 || {
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
        apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn" >/dev/null 2>&1 || true
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

    if [ "$auto_mode" -eq 1 ]; then
        set_current_quic_strategy "$best_strategy"
        apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn"
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
            set_current_quic_strategy "$best_strategy"
            apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn"
            print_success "QUIC стратегия применена"
            return 0
            ;;
    esac
}

# Получить текущие TCP параметры из init скрипта для секции
get_init_tcp_params() {
    local marker=$1
    local init_script=$2

    if [ ! -f "$init_script" ]; then
        return 1
    fi

    local line
    line=$(grep "^${marker}_TCP=" "$init_script" 2>/dev/null | head -n 1)
    echo "$line" | sed "s/^${marker}_TCP=\"//" | sed 's/\"$//'
}

# Получить текущие UDP параметры из init скрипта для секции
get_init_udp_params() {
    local marker=$1
    local init_script=$2

    if [ ! -f "$init_script" ]; then
        return 1
    fi

    local line
    line=$(grep "^${marker}_UDP=" "$init_script" 2>/dev/null | head -n 1)
    echo "$line" | sed "s/^${marker}_UDP=\"//" | sed 's/\"$//'
}

# Применить разные стратегии для YouTube TCP, YouTube GV, RKN (Z4R метод)
# Параметры: номера стратегий для каждой категории
apply_category_strategies_v2() {
    local yt_tcp_strategy=$1
    local yt_gv_strategy=$2
    local rkn_strategy=$3

    local zapret_config="${ZAPRET2_DIR:-/opt/zapret2}/config"
    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

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
    local yt_tcp_full
    local yt_gv_full
    local rkn_full
    yt_tcp_full=$(build_tls_profile_params "$yt_tcp_params")
    yt_gv_full=$(build_tls_profile_params "$yt_gv_params")
    rkn_full=$(build_tls_profile_params "$rkn_params")

    # QUIC параметры (единый профиль)
    local udp_quic
    udp_quic=$(get_current_quic_profile_params)

    # Сохранить стратегии в файлы категорий (config-driven)
    print_info "Сохранение стратегий в файлы категорий..."
    save_strategy_to_category "YT" "TCP" "$yt_tcp_full" || return 1
    save_strategy_to_category "YT_GV" "TCP" "$yt_gv_full" || return 1
    save_strategy_to_category "RKN" "TCP" "$rkn_full" || return 1
    save_strategy_to_category "YT" "UDP" "$udp_quic" || return 1
    save_strategy_to_category "RUTRACKER" "UDP" "$udp_quic" || return 1

    # Обновить config файл (NFQWS2_OPT секцию)
    print_info "Обновление config файла..."
    . "${LIB_DIR}/config_official.sh" || {
        print_error "Не удалось загрузить config_official.sh"
        return 1
    }

    update_nfqws2_opt_in_config "$zapret_config" || {
        print_error "Не удалось обновить config файл"
        return 1
    }

    # Сохранить выбранные стратегии в конфигурацию
    save_category_strategies "$yt_tcp_strategy" "$yt_gv_strategy" "$rkn_strategy"

    print_success "Стратегии применены"

    # Перезапустить сервис
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    sleep 2

    if ! is_zapret2_running; then
        # Иногда nfqws2 стартует с задержкой
        sleep 2
    fi

    if is_zapret2_running; then
        print_success "Сервис перезапущен с новыми стратегиями"
        return 0
    else
        print_error "Сервис не запустился, проверьте логи"
        return 1
    fi
}

# Сохранить стратегии по категориям (YouTube TCP/GV/RKN)
save_category_strategies() {
    local yt_tcp_strategy=$1
    local yt_gv_strategy=$2
    local rkn_strategy=$3
    local config_file="${CONFIG_DIR}/category_strategies.conf"

    mkdir -p "$CONFIG_DIR" 2>/dev/null

    cat > "$config_file" <<EOF
# Category Strategies Configuration (Z4R format)
# Format: CATEGORY:STRATEGY_NUM
# Updated: $(date)

youtube_tcp:${yt_tcp_strategy}
youtube_gv:${yt_gv_strategy}
rkn:${rkn_strategy}
EOF
}

# ==============================================================================
# ПРИМЕНЕНИЕ ДЕФОЛТНЫХ СТРАТЕГИЙ
# ==============================================================================

# Применить дефолтные стратегии без автоподбора
apply_default_strategies() {
    local auto_mode=0

    # Проверить флаг --auto
    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    print_header "Применение дефолтных стратегий"

    # Дефолтные стратегии:
    # YouTube TCP: #252
    # YouTube GV:  #790
    # RKN:         #3
    local default_yt_tcp=252
    local default_yt_gv=790
    local default_rkn=3

    print_info "Будут применены следующие стратегии:"
    print_info "  YouTube TCP: #$default_yt_tcp"
    print_info "  YouTube GV:  #$default_yt_gv"
    print_info "  RKN:         #$default_rkn"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Применить дефолтные стратегии?"; then
            print_info "Отменено"
            return 0
        fi
    fi

    # Проверить существование стратегий
    if ! strategy_exists "$default_yt_tcp"; then
        print_warning "Стратегия #$default_yt_tcp не найдена, используется #1"
        default_yt_tcp=1
    fi

    if ! strategy_exists "$default_yt_gv"; then
        print_warning "Стратегия #$default_yt_gv не найдена, используется #1"
        default_yt_gv=1
    fi

    if ! strategy_exists "$default_rkn"; then
        print_warning "Стратегия #$default_rkn не найдена, используется #1"
        default_rkn=1
    fi

    # Применить стратегии (работает абсолютно так же как автотест)
    apply_category_strategies_v2 "$default_yt_tcp" "$default_yt_gv" "$default_rkn"

    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
