#!/bin/sh
# lib/config.sh - Управление конфигурацией и списками доменов
# Скачивание, обновление и управление списками для zapret2

# ==============================================================================
# УПРАВЛЕНИЕ СПИСКАМИ ДОМЕНОВ
# ==============================================================================

# Скачать списки доменов из zapret4rocket (z4r)
download_domain_lists() {
    print_header "Загрузка списков доменов"
    print_info "Источник: zapret4rocket (master branch)"
    print_info "Списки используются как есть, без модификаций"

    # Создать структуру директорий
    local yt_tcp_dir="${ZAPRET2_DIR}/extra_strats/TCP/YT"
    local rkn_tcp_dir="${ZAPRET2_DIR}/extra_strats/TCP/RKN"
    local yt_udp_dir="${ZAPRET2_DIR}/extra_strats/UDP/YT"
    local rt_udp_dir="${ZAPRET2_DIR}/extra_strats/UDP/RUTRACKER"

    mkdir -p "$yt_tcp_dir" "$rkn_tcp_dir" "$yt_udp_dir" "$rt_udp_dir" "$LISTS_DIR" || {
        print_error "Не удалось создать директории"
        return 1
    }

    # 1. YouTube TCP - загрузить из extra_strats/TCP/YT/List.txt
    print_info "Загрузка YouTube TCP list..."
    if curl -fsSL "${Z4R_BASE_URL}/extra_strats/TCP/YT/List.txt" -o "${yt_tcp_dir}/List.txt"; then
        local count
        count=$(wc -l < "${yt_tcp_dir}/List.txt" 2>/dev/null || echo "0")
        print_success "YouTube TCP: $count доменов"
    else
        print_error "Ошибка загрузки YouTube TCP list"
    fi

    # 2. YouTube GV - использует --hostlist-domains=googlevideo.com (список не нужен)
    print_info "YouTube GV: используется --hostlist-domains=googlevideo.com"

    # 3. RKN - загрузить из extra_strats/TCP/RKN/List.txt (БЕЗ модификаций)
    print_info "Загрузка RKN list..."
    if curl -fsSL "${Z4R_BASE_URL}/extra_strats/TCP/RKN/List.txt" -o "${rkn_tcp_dir}/List.txt"; then
        local count
        count=$(wc -l < "${rkn_tcp_dir}/List.txt" 2>/dev/null || echo "0")
        print_success "RKN: $count доменов"
    else
        print_error "Ошибка загрузки RKN list"
    fi

    # 4. QUIC YouTube - загрузить из extra_strats/UDP/YT/List.txt
    print_info "Загрузка QUIC YouTube list..."
    if curl -fsSL "${Z4R_BASE_URL}/extra_strats/UDP/YT/List.txt" -o "${yt_udp_dir}/List.txt"; then
        local count
        count=$(wc -l < "${yt_udp_dir}/List.txt" 2>/dev/null || echo "0")
        print_success "QUIC YouTube: $count доменов"
    else
        print_warning "Не удалось загрузить QUIC YouTube list"
    fi

    # 5. Discord - загрузить из lists/russia-discord.txt
    print_info "Загрузка Discord list..."
    if curl -fsSL "${Z4R_LISTS_URL}/russia-discord.txt" -o "${LISTS_DIR}/discord.txt"; then
        local count
        count=$(wc -l < "${LISTS_DIR}/discord.txt" 2>/dev/null || echo "0")
        print_success "Discord: $count доменов"
    else
        print_error "Ошибка загрузки Discord list"
    fi

    # 6. Custom - создать пустой файл для пользовательских доменов
    if [ ! -f "${LISTS_DIR}/custom.txt" ]; then
        touch "${LISTS_DIR}/custom.txt"
        print_info "Создан custom.txt для пользовательских доменов"
    fi

    # 7. RuTracker QUIC - локальный список
    cat > "${rt_udp_dir}/List.txt" <<'EOF'
rutracker.org
www.rutracker.org
static.rutracker.cc
fastpic.org
t-ru.org
www.t-ru.org
EOF
    print_success "RuTracker QUIC: создан локальный список"

    print_separator
    print_success "Списки доменов загружены"

    return 0
}

# Обновить списки доменов
update_domain_lists() {
    print_header "Обновление списков доменов"

    # Скачать обновленные списки
    download_domain_lists

    # Показать статистику
    print_separator
    show_domain_lists_stats

    # Спросить о перезапуске сервиса
    if is_zapret2_running; then
        printf "\nПерезапустить сервис для применения изменений? [Y/n]: "
        read -r answer </dev/tty

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Сервис не перезапущен"
                print_info "Перезапустите вручную: /opt/etc/init.d/S99zapret2 restart"
                ;;
            *)
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                sleep 2
                if is_zapret2_running; then
                    print_success "Сервис перезапущен"
                else
                    print_error "Не удалось перезапустить сервис"
                fi
                ;;
        esac
    fi

    return 0
}

# Показать статистику по спискам доменов
show_domain_lists_stats() {
    print_header "Статистика списков доменов"

    printf "%-30s | %-10s\n" "Список" "Доменов"
    print_separator

    # YouTube TCP
    local yt_tcp_list="${ZAPRET2_DIR}/extra_strats/TCP/YT/List.txt"
    if [ -f "$yt_tcp_list" ]; then
        local count
        count=$(wc -l < "$yt_tcp_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "YouTube TCP" "$count"
    fi

    # YouTube GV
    printf "%-30s | %-10s\n" "YouTube GV" "--hostlist-domains"

    # RKN
    local rkn_list="${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt"
    if [ -f "$rkn_list" ]; then
        local count
        count=$(wc -l < "$rkn_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "RKN" "$count"
    fi

    # QUIC YouTube
    local quic_yt_list="${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt"
    if [ -f "$quic_yt_list" ]; then
        local count
        count=$(wc -l < "$quic_yt_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "QUIC YouTube" "$count"
    fi

    # Discord
    local discord_list="${LISTS_DIR}/discord.txt"
    if [ -f "$discord_list" ]; then
        local count
        count=$(wc -l < "$discord_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "Discord" "$count"
    fi

    # Custom
    local custom_list="${LISTS_DIR}/custom.txt"
    if [ -f "$custom_list" ]; then
        local count
        count=$(wc -l < "$custom_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "Custom" "$count"
    fi

    # RuTracker QUIC
    local rt_quic_list="${ZAPRET2_DIR}/extra_strats/UDP/RUTRACKER/List.txt"
    if [ -f "$rt_quic_list" ]; then
        local count
        count=$(wc -l < "$rt_quic_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "RuTracker QUIC" "$count"
    fi

    print_separator
}

# Показать какие списки обрабатываются и режим работы
show_active_processing() {
    print_header "Активная обработка трафика"

    # Проверить режим ALL_TCP443
    local all_tcp443_enabled=0
    local all_tcp443_strategy=""
    local all_tcp443_conf="${CONFIG_DIR}/all_tcp443.conf"

    if [ -f "$all_tcp443_conf" ]; then
        . "$all_tcp443_conf"
        all_tcp443_enabled=$ENABLED
        all_tcp443_strategy=$STRATEGY
    fi

    # Проверить QUIC RuTracker
    local rkn_quic_enabled=0
    if is_rutracker_quic_enabled 2>/dev/null; then
        rkn_quic_enabled=1
    fi

    # Показать режим работы
    print_info "Режим обработки трафика:"
    printf "\n"

    if [ "$all_tcp443_enabled" = "1" ]; then
        print_warning "⚠️  РЕЖИМ ALL TCP-443 ВКЛЮЧЕН"
        printf "    Обрабатывается ВЕСЬ HTTPS трафик (порт 443)\n"
        printf "    Стратегия: #%s\n" "$all_tcp443_strategy"
        printf "    Списки доменов НЕ используются!\n"
        print_separator
    else
        print_success "✓ Режим по спискам доменов (нормальный)"
        printf "\n"
    fi

    # Показать активные списки
    print_info "Обрабатываемые списки доменов:"
    print_separator
    printf "%-30s | %-10s | %s\n" "Категория" "Доменов" "Статус"
    print_separator

    # RKN TCP
    local rkn_list="${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt"
    if [ -f "$rkn_list" ]; then
        local count
        count=$(wc -l < "$rkn_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "RKN (заблокированные)" "$count" "Активен"
    fi

    # YouTube TCP
    local yt_tcp_list="${ZAPRET2_DIR}/extra_strats/TCP/YT/List.txt"
    if [ -f "$yt_tcp_list" ]; then
        local count
        count=$(wc -l < "$yt_tcp_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "YouTube TCP" "$count" "Активен"
    fi

    # YouTube GV
    printf "%-30s | %-10s | %s\n" "YouTube GV (CDN)" "googlevideo.com" "Активен"

    # QUIC YouTube
    local quic_yt_list="${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt"
    if [ -f "$quic_yt_list" ]; then
        local count
        count=$(wc -l < "$quic_yt_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "QUIC YouTube (UDP 443)" "$count" "Активен"
    fi

    # QUIC RuTracker
    local rt_quic_list="${ZAPRET2_DIR}/extra_strats/UDP/RUTRACKER/List.txt"
    if [ -f "$rt_quic_list" ]; then
        local count
        count=$(wc -l < "$rt_quic_list" 2>/dev/null || echo "0")
        local status
        if [ "$rkn_quic_enabled" = "1" ]; then
            status="Активен"
        else
            status="Выключен"
        fi
        printf "%-30s | %-10s | %s\n" "QUIC RuTracker (UDP 443)" "$count" "$status"
    fi

    # Discord
    local discord_list="${LISTS_DIR}/discord.txt"
    if [ -f "$discord_list" ]; then
        local count
        count=$(wc -l < "$discord_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "Discord (TCP+UDP)" "$count" "Активен"
    fi

    # Custom
    local custom_list="${LISTS_DIR}/custom.txt"
    if [ -f "$custom_list" ]; then
        local count
        count=$(wc -l < "$custom_list" 2>/dev/null || echo "0")
        local status="Пустой"
        if [ "$count" -gt 0 ]; then
            status="Активен"
        fi
        printf "%-30s | %-10s | %s\n" "Custom (пользовательские)" "$count" "$status"
    fi

    print_separator

    # Показать исключения
    print_info "Исключения (whitelist):"
    local whitelist="${LISTS_DIR}/whitelist.txt"
    if [ -f "$whitelist" ]; then
        local count
        count=$(grep -v "^#" "$whitelist" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
        printf "  %s доменов исключено из обработки\n" "$count"
        printf "  Файл: %s\n" "$whitelist"
    else
        printf "  Whitelist не найден\n"
    fi

    print_separator

    # Итого
    if [ "$all_tcp443_enabled" = "1" ]; then
        print_warning "ВНИМАНИЕ: Весь HTTPS трафик обрабатывается!"
        print_info "Чтобы выключить: sh z2k.sh menu → [A] Режим ALL TCP-443"
    else
        print_success "Режим работы: только списки доменов (рекомендуется)"
    fi
}

# Добавить домен в custom.txt
add_custom_domain() {
    local domain=$1

    if [ -z "$domain" ]; then
        print_error "Укажите домен для добавления"
        return 1
    fi

    local custom_list="${LISTS_DIR}/custom.txt"

    # Создать файл если не существует
    if [ ! -f "$custom_list" ]; then
        mkdir -p "$LISTS_DIR"
        touch "$custom_list"
    fi

    # Проверить, не существует ли уже
    if grep -qx "$domain" "$custom_list" 2>/dev/null; then
        print_warning "Домен уже в списке: $domain"
        return 0
    fi

    # Добавить домен
    echo "$domain" >> "$custom_list"
    print_success "Добавлен домен: $domain"

    return 0
}

# Удалить домен из custom.txt
remove_custom_domain() {
    local domain=$1
    local custom_list="${LISTS_DIR}/custom.txt"

    if [ -z "$domain" ]; then
        print_error "Укажите домен для удаления"
        return 1
    fi

    if [ ! -f "$custom_list" ]; then
        print_error "Файл custom.txt не найден"
        return 1
    fi

    # Удалить домен
    if grep -qx "$domain" "$custom_list"; then
        grep -vx "$domain" "$custom_list" > "${custom_list}.tmp"
        mv "${custom_list}.tmp" "$custom_list"
        print_success "Удален домен: $domain"
    else
        print_warning "Домен не найден в списке: $domain"
    fi

    return 0
}

# Показать custom.txt
show_custom_domains() {
    local custom_list="${LISTS_DIR}/custom.txt"

    print_header "Пользовательские домены"

    if [ ! -f "$custom_list" ]; then
        print_info "Список пустой (файл не создан)"
        return 0
    fi

    local count
    count=$(wc -l < "$custom_list" 2>/dev/null || echo "0")

    if [ "$count" -eq 0 ]; then
        print_info "Список пустой"
    else
        print_info "Всего доменов: $count"
        print_separator
        cat "$custom_list"
        print_separator
    fi

    return 0
}

# Очистить custom.txt
clear_custom_domains() {
    local custom_list="${LISTS_DIR}/custom.txt"

    if [ ! -f "$custom_list" ]; then
        print_info "Список уже пустой"
        return 0
    fi

    printf "Очистить список пользовательских доменов? [y/N]: "
    read -r answer </dev/tty

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            > "$custom_list"
            print_success "Список очищен"
            ;;
        *)
            print_info "Отменено"
            ;;
    esac

    return 0
}

# ==============================================================================
# УПРАВЛЕНИЕ КОНФИГУРАЦИЕЙ
# ==============================================================================

# Создать базовую конфигурацию zapret2
create_base_config() {
    print_info "Создание базовой конфигурации..."

    mkdir -p "$CONFIG_DIR" || {
        print_error "Не удалось создать $CONFIG_DIR"
        return 1
    }

    # Копировать strategies.conf из рабочей директории
    if [ -f "${WORK_DIR}/strategies.conf" ]; then
        cp "${WORK_DIR}/strategies.conf" "$STRATEGIES_CONF" || {
            print_error "Не удалось скопировать strategies.conf"
            return 1
        }
        print_success "Создан файл стратегий: $STRATEGIES_CONF"
    fi

    # Копировать quic_strategies.conf из рабочей директории
    if [ -f "${WORK_DIR}/quic_strategies.conf" ]; then
        cp "${WORK_DIR}/quic_strategies.conf" "$QUIC_STRATEGIES_CONF" || {
            print_error "Не удалось скопировать quic_strategies.conf"
            return 1
        }
        print_success "Создан файл QUIC стратегий: $QUIC_STRATEGIES_CONF"
    fi

    # Создать файл для текущей стратегии
    touch "$CURRENT_STRATEGY_FILE"

    # Создать файл для текущей QUIC стратегии
    if [ ! -f "$QUIC_STRATEGY_FILE" ]; then
        echo "QUIC_STRATEGY=24" > "$QUIC_STRATEGY_FILE"
    fi

    # Создать файл для QUIC стратегии RuTracker
    if [ ! -f "$RUTRACKER_QUIC_STRATEGY_FILE" ]; then
        echo "RUTRACKER_QUIC_STRATEGY=43" > "$RUTRACKER_QUIC_STRATEGY_FILE"
    fi

    # Создать конфиг для включения/выключения QUIC RuTracker (по умолчанию выключено)
    local rutracker_quic_enabled_conf="${CONFIG_DIR}/rutracker_quic_enabled.conf"
    if [ ! -f "$rutracker_quic_enabled_conf" ]; then
        echo "RUTRACKER_QUIC_ENABLED=0" > "$rutracker_quic_enabled_conf"
        print_success "RuTracker QUIC по умолчанию выключен"
    fi

    # Удалить старый файл QUIC стратегий по категориям (больше не используется)
    local quic_category_conf="${CONFIG_DIR}/quic_category_strategies.conf"
    if [ -f "$quic_category_conf" ]; then
        rm -f "$quic_category_conf"
    fi

    # Создать конфиг для режима ALL_TCP443 (без хостлистов)
    local all_tcp443_conf="${CONFIG_DIR}/all_tcp443.conf"
    if [ ! -f "$all_tcp443_conf" ]; then
        cat > "$all_tcp443_conf" <<'EOF'
# Режим работы по ВСЕМ доменам TCP-443 без хостлистов
# ВНИМАНИЕ: Этот режим применяет стратегию ко всему трафику HTTPS
# Может замедлить соединения, но обходит любые блокировки

# Включить режим: 1 = включен, 0 = выключен
ENABLED=0

# Номер стратегии для применения (1-199)
STRATEGY=1
EOF
        print_success "Создан конфиг режима ALL_TCP443"
    fi

    # Создать директорию для списков если не существует
    if ! mkdir -p "$LISTS_DIR" 2>/dev/null; then
        print_error "Не удалось создать директорию: $LISTS_DIR"
        print_info "Проверьте права доступа"
        return 1
    fi

    # Проверить что директория действительно существует
    if [ ! -d "$LISTS_DIR" ]; then
        print_error "Директория не существует: $LISTS_DIR"
        return 1
    fi

    # Создать whitelist для исключения критичных сервисов
    local whitelist="${LISTS_DIR}/whitelist.txt"
    if [ ! -f "$whitelist" ]; then
        cat > "$whitelist" <<'EOF'
# Whitelist - домены исключенные из обработки zapret2
# Сервисы, которые могут работать некорректно с DPI bypass

# Социальные сети и медиа
pinterest.com
vkvideo.ru
vk.com
rutube.ru

# E-commerce и объявления
avito.ru

# Стриминг
netflix.com
vsetop.org
twitch.tv
ttvnw.net
static-cdn.jtvnw.net

# Google API
jnn-pa.googleapis.com
ogs.google.com
encrypted-tbn0.gstatic.com
encrypted-tbn1.gstatic.com
encrypted-tbn2.gstatic.com
encrypted-tbn3.gstatic.com

# Gaming
steamcommunity.com
steampowered.com
tarkov.com
escapefromtarkov.com

# Мониторинг и CDN
browser-intake-datadoghq.com
datadoghq.com
okcdn.ru
api.mycdn.me

# Госуслуги
gosuslugi.ru

# Разработка
raw.githubusercontent.com
EOF

        # Проверить что файл действительно создался
        if [ ! -f "$whitelist" ]; then
            print_error "Не удалось создать whitelist: $whitelist"
            print_info "Проверьте права доступа к директории"
            return 1
        fi

        print_success "Создан whitelist: $whitelist"
    fi

    print_success "Базовая конфигурация создана"
    return 0
}

# Показать текущую конфигурацию
show_current_config() {
    print_header "Текущая конфигурация"

    printf "%-25s: %s\n" "Директория zapret2" "$ZAPRET2_DIR"
    printf "%-25s: %s\n" "Директория конфига" "$CONFIG_DIR"
    printf "%-25s: %s\n" "Директория списков" "$LISTS_DIR"
    printf "%-25s: %s\n" "Init скрипт" "$INIT_SCRIPT"

    print_separator

    printf "%-25s: %s\n" "Статус сервиса" "$(get_service_status)"
    printf "%-25s: #%s\n" "Текущая стратегия" "$(get_current_strategy)"

    if [ -f "$STRATEGIES_CONF" ]; then
        local count
        count=$(get_strategies_count)
        printf "%-25s: %s\n" "Всего стратегий" "$count"
    else
        printf "%-25s: %s\n" "Всего стратегий" "не установлено"
    fi

    if [ -f "$QUIC_STRATEGIES_CONF" ]; then
        local qcount
        qcount=$(get_quic_strategies_count)
        printf "%-25s: %s\n" "QUIC стратегий" "$qcount"
    fi

    if [ -f "$QUIC_STRATEGY_FILE" ]; then
        printf "%-25s: #%s\n" "QUIC YouTube" "$(get_current_quic_strategy)"
    fi
    if [ -f "$RUTRACKER_QUIC_STRATEGY_FILE" ]; then
        printf "%-25s: #%s\n" "QUIC RuTracker" "$(get_rutracker_quic_strategy)"
    fi

    print_separator

    # Списки доменов
    if [ -d "$LISTS_DIR" ]; then
        print_info "Списки доменов:"
        for list in discord.txt youtube.txt rkn.txt custom.txt; do
            if [ -f "${LISTS_DIR}/${list}" ]; then
                local count
                count=$(wc -l < "${LISTS_DIR}/${list}" 2>/dev/null || echo "0")
                printf "  %-20s: %s доменов\n" "$list" "$count"
            fi
        done
        local yt_quic_list="${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt"
        if [ -f "$yt_quic_list" ]; then
            local yt_quic_count
            yt_quic_count=$(wc -l < "$yt_quic_list" 2>/dev/null || echo "0")
            printf "  %-20s: %s доменов\n" "extra_strats/UDP/YT/List.txt" "$yt_quic_count"
        fi
        local rt_quic_list="${ZAPRET2_DIR}/extra_strats/UDP/RUTRACKER/List.txt"
        if [ -f "$rt_quic_list" ]; then
            local rt_quic_count
            rt_quic_count=$(wc -l < "$rt_quic_list" 2>/dev/null || echo "0")
            printf "  %-20s: %s доменов\n" "extra_strats/UDP/RUTRACKER/List.txt" "$rt_quic_count"
        fi
    else
        print_info "Списки доменов: не установлены"
    fi

    print_separator
}

# Сбросить конфигурацию к defaults
reset_config() {
    print_header "Сброс конфигурации"

    print_warning "Это удалит:"
    print_warning "  - Текущую стратегию"
    print_warning "  - Пользовательские домены (custom.txt)"
    print_warning "Списки discord/youtube НЕ будут удалены"

    printf "\nПродолжить сброс? [y/N]: "
    read -r answer </dev/tty

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            # Очистить текущую стратегию
            if [ -f "$CURRENT_STRATEGY_FILE" ]; then
                rm -f "$CURRENT_STRATEGY_FILE"
                print_info "Сброшена текущая стратегия"
            fi

            # Очистить custom.txt
            if [ -f "${LISTS_DIR}/custom.txt" ]; then
                > "${LISTS_DIR}/custom.txt"
                print_info "Очищен список пользовательских доменов"
            fi

            print_success "Конфигурация сброшена"

            # Предложить перезапуск
            if is_zapret2_running; then
                printf "\nПерезапустить сервис? [Y/n]: "
                read -r restart_answer </dev/tty

                case "$restart_answer" in
                    [Nn]|[Nn][Oo])
                        print_info "Сервис не перезапущен"
                        ;;
                    *)
                        "$INIT_SCRIPT" restart
                        print_success "Сервис перезапущен"
                        ;;
                esac
            fi
            ;;
        *)
            print_info "Отменено"
            ;;
    esac

    return 0
}

# Создать backup конфигурации
backup_config() {
    local backup_dir="${CONFIG_DIR}/backups"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/config_backup_${timestamp}.tar.gz"

    print_header "Создание резервной копии"

    mkdir -p "$backup_dir" || {
        print_error "Не удалось создать директорию backup"
        return 1
    }

    print_info "Создание архива..."

    # Создать tar.gz с конфигурацией
    tar -czf "$backup_file" \
        -C "$CONFIG_DIR" \
        strategies.conf \
        current_strategy \
        -C "$LISTS_DIR" \
        custom.txt \
        2>/dev/null

    if [ -f "$backup_file" ]; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        print_success "Backup создан: $backup_file ($size)"
        return 0
    else
        print_error "Не удалось создать backup"
        return 1
    fi
}

# Восстановить конфигурацию из backup
restore_config() {
    local backup_dir="${CONFIG_DIR}/backups"

    print_header "Восстановление конфигурации"

    if [ ! -d "$backup_dir" ]; then
        print_error "Директория backups не найдена"
        return 1
    fi

    # Найти последний backup
    local latest_backup
    latest_backup=$(ls -t "${backup_dir}"/config_backup_*.tar.gz 2>/dev/null | head -n 1)

    if [ -z "$latest_backup" ]; then
        print_error "Резервные копии не найдены"
        return 1
    fi

    print_info "Последний backup: $latest_backup"
    printf "Восстановить? [y/N]: "
    read -r answer </dev/tty

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            print_info "Восстановление..."

            # Извлечь backup
            tar -xzf "$latest_backup" -C "$CONFIG_DIR" 2>/dev/null

            if [ $? -eq 0 ]; then
                print_success "Конфигурация восстановлена"

                # Предложить перезапуск
                if is_zapret2_running; then
                    printf "Перезапустить сервис? [Y/n]: "
                    read -r restart_answer </dev/tty

                    case "$restart_answer" in
                        [Nn]|[Nn][Oo])
                            print_info "Сервис не перезапущен"
                            ;;
                        *)
                            "$INIT_SCRIPT" restart
                            print_success "Сервис перезапущен"
                            ;;
                    esac
                fi
            else
                print_error "Ошибка восстановления"
                return 1
            fi
            ;;
        *)
            print_info "Отменено"
            ;;
    esac

    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
