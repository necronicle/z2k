#!/bin/sh
# lib/config.sh - Управление конфигурацией и списками доменов
# Скачивание, обновление и управление списками для zapret2

# ==============================================================================
# УПРАВЛЕНИЕ СПИСКАМИ ДОМЕНОВ (СТАНДАРТНЫЙ IPSET)
# ==============================================================================

# Создать начальные списки доменов (seed) для стандартного ipset
seed_standard_lists() {
    print_header "Создание начальных списков доменов"

    local ipset_dir="${IPSET_DIR:-${ZAPRET2_DIR}/ipset}"
    mkdir -p "$ipset_dir" || {
        print_error "Не удалось создать $ipset_dir"
        return 1
    }

    local hosts_user="${HOSTS_USER:-${ipset_dir}/zapret-hosts-user.txt}"
    local hosts_exclude="${HOSTS_USER_EXCLUDE:-${ipset_dir}/zapret-hosts-user-exclude.txt}"

    # Создать zapret-hosts-user.txt (seed домены)
    if [ ! -f "$hosts_user" ]; then
        cat > "$hosts_user" <<'EOF'
# zapret-hosts-user.txt - Seed домены для autohostlist
# Эти домены будут в списке сразу, без ожидания автоматического обнаружения

# YouTube
youtube.com
youtu.be
googlevideo.com
ytimg.com
ggpht.com
googleapis.com
gstatic.com

# Discord
discord.com
discord.gg
discordapp.com
discord.media
discordapp.net

# RKN (known blocked)
rutracker.org
meduza.io
facebook.com
instagram.com
twitter.com
x.com
EOF
        print_success "Создан seed список: $hosts_user"
    else
        print_info "Seed список уже существует: $hosts_user"
    fi

    # Создать zapret-hosts-user-exclude.txt (whitelist)
    if [ ! -f "$hosts_exclude" ]; then
        local whitelist="${LISTS_DIR}/whitelist.txt"
        if [ -f "$whitelist" ]; then
            # Копировать существующий whitelist
            cp "$whitelist" "$hosts_exclude"
            print_success "Whitelist скопирован в: $hosts_exclude"
        else
            cat > "$hosts_exclude" <<'EOF'
# zapret-hosts-user-exclude.txt - Домены исключенные из обработки
# Сервисы, которые могут работать некорректно с DPI bypass

# Социальные сети и медиа
pinterest.com
vkvideo.ru
vk.com
rutube.ru

# E-commerce
avito.ru

# Стриминг
netflix.com
twitch.tv

# Google API
jnn-pa.googleapis.com

# Gaming
steamcommunity.com
steampowered.com

# Госуслуги
gosuslugi.ru

# Разработка
raw.githubusercontent.com
EOF
            print_success "Создан exclude список: $hosts_exclude"
        fi
    else
        print_info "Exclude список уже существует: $hosts_exclude"
    fi

    print_success "Начальные списки созданы"
    return 0
}

# Запустить стандартный скрипт загрузки списков
# При наличии config — через get_config.sh (читает GETLIST из config)
# Без config (первый запуск при установке) — вызывает get_refilter_domains.sh напрямую
run_getlist() {
    local ipset_dir="${ZAPRET2_DIR}/ipset"
    local config_file="${ZAPRET2_DIR}/config"

    # ВАЖНО: Скрипты zapret2 используют ZAPRET_BASE для поиска common/base.sh
    export ZAPRET_BASE="${ZAPRET2_DIR}"

    # Если config уже есть — штатный путь через get_config.sh
    if [ -f "$config_file" ] && grep -q "^GETLIST=" "$config_file" 2>/dev/null; then
        local getlist_script="${ipset_dir}/get_config.sh"
        if [ -x "$getlist_script" ]; then
            print_info "Запуск $getlist_script (GETLIST из config)..."
            "$getlist_script"
            return $?
        fi
    fi

    # Fallback: вызвать get_refilter_domains.sh напрямую (установка, config ещё не создан)
    local refilter_script="${ipset_dir}/get_refilter_domains.sh"
    if [ -x "$refilter_script" ]; then
        print_info "Запуск $refilter_script напрямую..."
        "$refilter_script"
        return $?
    fi

    # Ни один скрипт не найден
    print_warning "Скрипты загрузки списков не найдены в $ipset_dir"
    print_info "Списки будут загружены автоматически при первом запуске cron"
    return 1
}

# Показать статистику по спискам доменов
show_domain_lists_stats() {
    print_header "Статистика списков доменов"

    local ipset_dir="${IPSET_DIR:-${ZAPRET2_DIR}/ipset}"

    printf "%-35s | %-10s\n" "Список" "Записей"
    print_separator

    # User hosts (seed)
    local hosts_user="${HOSTS_USER:-${ipset_dir}/zapret-hosts-user.txt}"
    if [ -f "$hosts_user" ]; then
        local count
        count=$(grep -v "^#" "$hosts_user" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
        printf "%-35s | %-10s\n" "zapret-hosts-user.txt (seed)" "$count"
    fi

    # Exclude hosts
    local hosts_exclude="${HOSTS_USER_EXCLUDE:-${ipset_dir}/zapret-hosts-user-exclude.txt}"
    if [ -f "$hosts_exclude" ]; then
        local count
        count=$(grep -v "^#" "$hosts_exclude" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
        printf "%-35s | %-10s\n" "zapret-hosts-user-exclude.txt" "$count"
    fi

    # Auto-downloaded lists
    local hosts_main="${ipset_dir}/zapret-hosts.txt.gz"
    if [ -f "$hosts_main" ]; then
        printf "%-35s | %-10s\n" "zapret-hosts.txt.gz (downloaded)" "есть"
    elif [ -f "${ipset_dir}/zapret-hosts.txt" ]; then
        local count
        count=$(wc -l < "${ipset_dir}/zapret-hosts.txt" 2>/dev/null || echo "0")
        printf "%-35s | %-10s\n" "zapret-hosts.txt (downloaded)" "$count"
    fi

    # Auto-discovered hosts
    local hosts_auto="${ipset_dir}/zapret-hosts-auto.txt"
    if [ -f "$hosts_auto" ]; then
        local count
        count=$(wc -l < "$hosts_auto" 2>/dev/null || echo "0")
        printf "%-35s | %-10s\n" "zapret-hosts-auto.txt (auto)" "$count"
    fi

    print_separator
}

# Показать активную конфигурацию обработки трафика
show_active_processing() {
    print_header "Активная обработка трафика"

    print_info "Режим: autohostlist (самообучение + списки)"
    print_info "GETLIST: get_refilter_domains.sh"
    print_info "Профили: 3 (TCP + QUIC + Discord UDP)"

    print_separator

    printf "%-25s: %s\n" "TCP стратегия" "#$(get_current_strategy)"
    printf "%-25s: %s\n" "QUIC стратегия" "#$(get_current_quic_strategy)"
    printf "%-25s: %s\n" "Discord UDP" "фиксированная"

    print_separator

    # Исключения
    local hosts_exclude="${HOSTS_USER_EXCLUDE:-${IPSET_DIR:-${ZAPRET2_DIR}/ipset}/zapret-hosts-user-exclude.txt}"
    if [ -f "$hosts_exclude" ]; then
        local count
        count=$(grep -v "^#" "$hosts_exclude" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
        printf "Исключения: %s доменов\n" "$count"
    fi

    print_separator
}

# Добавить домен в zapret-hosts-user.txt
add_custom_domain() {
    local domain=$1

    if [ -z "$domain" ]; then
        print_error "Укажите домен для добавления"
        return 1
    fi

    local hosts_user="${HOSTS_USER:-${IPSET_DIR:-${ZAPRET2_DIR}/ipset}/zapret-hosts-user.txt}"

    # Создать файл если не существует
    if [ ! -f "$hosts_user" ]; then
        mkdir -p "$(dirname "$hosts_user")"
        touch "$hosts_user"
    fi

    # Проверить, не существует ли уже
    if grep -qx "$domain" "$hosts_user" 2>/dev/null; then
        print_warning "Домен уже в списке: $domain"
        return 0
    fi

    # Добавить домен
    echo "$domain" >> "$hosts_user"
    print_success "Добавлен домен: $domain"

    return 0
}

# Удалить домен из zapret-hosts-user.txt
remove_custom_domain() {
    local domain=$1
    local hosts_user="${HOSTS_USER:-${IPSET_DIR:-${ZAPRET2_DIR}/ipset}/zapret-hosts-user.txt}"

    if [ -z "$domain" ]; then
        print_error "Укажите домен для удаления"
        return 1
    fi

    if [ ! -f "$hosts_user" ]; then
        print_error "Файл zapret-hosts-user.txt не найден"
        return 1
    fi

    # Удалить домен
    if grep -qx "$domain" "$hosts_user"; then
        grep -vx "$domain" "$hosts_user" > "${hosts_user}.tmp"
        mv "${hosts_user}.tmp" "$hosts_user"
        print_success "Удален домен: $domain"
    else
        print_warning "Домен не найден в списке: $domain"
    fi

    return 0
}

# Показать zapret-hosts-user.txt
show_custom_domains() {
    local hosts_user="${HOSTS_USER:-${IPSET_DIR:-${ZAPRET2_DIR}/ipset}/zapret-hosts-user.txt}"

    print_header "Пользовательские домены (seed)"

    if [ ! -f "$hosts_user" ]; then
        print_info "Список пустой (файл не создан)"
        return 0
    fi

    local count
    count=$(grep -v "^#" "$hosts_user" | grep -v "^$" | wc -l 2>/dev/null || echo "0")

    if [ "$count" -eq 0 ]; then
        print_info "Список пустой"
    else
        print_info "Всего доменов: $count"
        print_separator
        grep -v "^#" "$hosts_user" | grep -v "^$"
        print_separator
    fi

    return 0
}

# Очистить пользовательские домены из zapret-hosts-user.txt
clear_custom_domains() {
    local hosts_user="${HOSTS_USER:-${IPSET_DIR:-${ZAPRET2_DIR}/ipset}/zapret-hosts-user.txt}"

    if [ ! -f "$hosts_user" ]; then
        print_info "Список уже пустой"
        return 0
    fi

    printf "Очистить список пользовательских доменов? [y/N]: "
    read -r answer </dev/tty

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            > "$hosts_user"
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

    # Удалить старый файл QUIC стратегий по категориям (больше не используется)
    local quic_category_conf="${CONFIG_DIR}/quic_category_strategies.conf"
    if [ -f "$quic_category_conf" ]; then
        rm -f "$quic_category_conf"
    fi

    # Создать директорию ipset и seed-файлы
    seed_standard_lists

    # Создать директорию для списков если не существует
    mkdir -p "$LISTS_DIR" 2>/dev/null

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
    print_separator

    # Списки доменов (ipset)
    local ipset_dir="${IPSET_DIR:-${ZAPRET2_DIR}/ipset}"
    if [ -d "$ipset_dir" ]; then
        print_info "Списки доменов (ipset):"
        for list in zapret-hosts-user.txt zapret-hosts-user-exclude.txt zapret-hosts-auto.txt; do
            if [ -f "${ipset_dir}/${list}" ]; then
                local count
                count=$(grep -v "^#" "${ipset_dir}/${list}" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
                printf "  %-35s: %s\n" "$list" "$count"
            fi
        done
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

            # Пересоздать seed-списки
            seed_standard_lists
            print_info "Списки доменов пересозданы"

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
