#!/bin/sh
# lib/discord.sh - Конфигурация Discord voice/video
# Точная копия подхода zapret4rocket (z4r) с расширенными UDP портами

# ==============================================================================
# КОНСТАНТЫ DISCORD
# ==============================================================================

# Расширенные UDP порты для Discord voice/video (как в z4r)
DISCORD_UDP_PORTS="443,50000:50099,1400,3478:3481,5349"

# Домены Discord (будут загружены из discord.txt)
DISCORD_DOMAINS="
discord.com
discord.gg
discordapp.com
discordapp.io
discordapp.net
discord.media
discordcdn.com
discordstatus.com
discord-attachments-uploads-prd.storage.googleapis.com
"

# ==============================================================================
# НАСТРОЙКА DISCORD VOICE/VIDEO
# ==============================================================================

configure_discord_voice() {
    print_header "Настройка Discord: голос и видео"

    # Проверить установку
    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        return 1
    fi

    # Проверить наличие списка Discord доменов
    if [ ! -f "${LISTS_DIR}/discord.txt" ]; then
        print_warning "Список discord.txt не найден"
        print_info "Загружаю список доменов..."
        download_domain_lists || {
            print_error "Не удалось загрузить списки"
            return 1
        }
    fi

    print_separator
    print_info "Discord использует:"
    print_info "  - TCP 443 для текстовых чатов"
    print_info "  - UDP 443, 50000-50099 для голоса/видео"
    print_info "  - UDP 1400, 3478-3481, 5349 для WebRTC"
    print_separator

    # Получить текущую стратегию
    local current_strategy
    current_strategy=$(get_current_strategy)

    if [ "$current_strategy" = "не задана" ] || [ -z "$current_strategy" ]; then
        print_warning "Текущая стратегия не задана"
        printf "\nВыберите стратегию для Discord (рекомендуется из TOP-20).\n"
        printf "Введите номер стратегии: "
        read -r strategy_num </dev/tty
    else
        printf "\nТекущая стратегия: #%s\n" "$current_strategy"
        printf "Использовать её для Discord? [Y/n]: "
        read -r answer </dev/tty

        case "$answer" in
            [Nn]|[Nn][Oo])
                printf "Введите номер новой стратегии: "
                read -r strategy_num </dev/tty
                ;;
            *)
                strategy_num=$current_strategy
                ;;
        esac
    fi

    # Проверить стратегию
    if ! strategy_exists "$strategy_num"; then
        print_error "Стратегия #$strategy_num не найдена"
        return 1
    fi

    # Получить параметры TCP стратегии
    local tcp_params
    tcp_params=$(get_strategy "$strategy_num")

    if [ -z "$tcp_params" ]; then
        print_error "Не удалось получить параметры стратегии"
        return 1
    fi

    print_info "Применяю стратегию #$strategy_num для Discord..."
    print_separator
    printf "TCP параметры:\n%s\n" "$tcp_params"
    print_separator

    # Сгенерировать Discord multi-profile конфигурацию
    generate_discord_profile "$tcp_params"

    print_success "Discord настроен!"
    print_separator
    print_info "Конфигурация:"
    print_info "  - TCP (текст): стратегия #$strategy_num"
    print_info "  - UDP (голос/видео): расширенные порты"
    print_info "  - Список доменов: ${LISTS_DIR}/discord.txt"
    print_separator

    return 0
}

# ==============================================================================
# ГЕНЕРАЦИЯ DISCORD ПРОФИЛЯ
# ==============================================================================

generate_discord_profile() {
    local tcp_params=$1

    # Создать временный файл с Discord профилем
    local discord_profile_file="/tmp/discord_profile.conf"

    cat > "$discord_profile_file" <<DISCORD_PROFILE
# Discord TCP Profile (текстовые чаты)
--filter-tcp=443
--hostlist=${LISTS_DIR}/discord.txt
$tcp_params

--new

# Discord UDP Profile (голос/видео)
--filter-udp=${DISCORD_UDP_PORTS}
--hostlist=${LISTS_DIR}/discord.txt
--filter-l7=discord,stun
--payload=stun,discord_ip_discovery
--out-range=-n10
--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2
DISCORD_PROFILE

    # Инжектировать в init скрипт
    inject_discord_to_init "$discord_profile_file"

    # Удалить временный файл
    rm -f "$discord_profile_file"
}

# ==============================================================================
# ИНЖЕКЦИЯ DISCORD КОНФИГУРАЦИИ В INIT СКРИПТ
# ==============================================================================

inject_discord_to_init() {
    local profile_file=$1
    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    if [ ! -f "$init_script" ]; then
        print_error "Init скрипт не найден: $init_script"
        return 1
    fi

    if [ ! -f "$profile_file" ]; then
        print_error "Файл профиля не найден: $profile_file"
        return 1
    fi

    # Создать backup
    backup_file "$init_script" || {
        print_error "Не удалось создать backup"
        return 1
    }

    # Прочитать профиль
    local discord_config
    discord_config=$(cat "$profile_file")

    # Модифицировать init скрипт
    # 1. Включить Discord (DISCORD_ENABLED=1)
    # 2. Установить TCP и UDP параметры между маркерами

    awk -v config="$discord_config" '
        BEGIN {
            in_discord_marker=0
            discord_marker_found=0
            split(config, lines, "\n")

            # Извлечь TCP и UDP части из config
            tcp_part=""
            udp_part=""
            in_new=0

            for (i in lines) {
                line = lines[i]
                if (line ~ /^--new/) {
                    in_new=1
                    continue
                }
                if (!in_new && line !~ /^#/ && line != "") {
                    if (tcp_part != "") tcp_part = tcp_part " "
                    tcp_part = tcp_part line
                }
                if (in_new && line !~ /^#/ && line != "") {
                    if (udp_part != "") udp_part = udp_part " "
                    udp_part = udp_part line
                }
            }
        }

        # Включить Discord
        /^DISCORD_ENABLED=/ {
            print "DISCORD_ENABLED=1"
            next
        }

        # Заменить между маркерами
        /DISCORD_MARKER_START/ {
            print
            print "DISCORD_TCP=\"" tcp_part "\""
            print "DISCORD_UDP=\"" udp_part "\""
            in_discord_marker=1
            discord_marker_found=1
            next
        }

        /DISCORD_MARKER_END/ {
            in_discord_marker=0
            print
            next
        }

        !in_discord_marker { print }

        END {
            if (!discord_marker_found) {
                print "ERROR: DISCORD_MARKER not found" > "/dev/stderr"
                exit 1
            }
        }
    ' "$init_script" > "${init_script}.tmp"

    # Проверить успех
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

    # Перезапустить сервис
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    sleep 2

    if is_zapret2_running; then
        print_success "Сервис перезапущен с Discord конфигурацией"

        # Проверить что запущены 2 процесса nfqws2
        local process_count
        process_count=$(pgrep -c -f "nfqws2")

        if [ "$process_count" -ge 2 ]; then
            print_success "Запущено процессов nfqws2: $process_count (основной + Discord)"
        else
            print_warning "Запущено процессов: $process_count (ожидалось 2)"
            print_info "Проверьте статус: $init_script status"
        fi
    else
        print_error "Сервис не запустился"
        print_info "Восстанавливаю предыдущую конфигурацию..."
        restore_backup "$init_script"
        "$init_script" restart >/dev/null 2>&1
        return 1
    fi

    return 0
}

# ==============================================================================
# ОТКЛЮЧЕНИЕ DISCORD КОНФИГУРАЦИИ
# ==============================================================================

disable_discord() {
    print_header "Отключение Discord конфигурации"

    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    if [ ! -f "$init_script" ]; then
        print_error "Init скрипт не найден"
        return 1
    fi

    # Создать backup
    backup_file "$init_script"

    # Отключить Discord (DISCORD_ENABLED=0)
    awk '
        /^DISCORD_ENABLED=/ {
            print "DISCORD_ENABLED=0"
            next
        }
        { print }
    ' "$init_script" > "${init_script}.tmp"

    mv "${init_script}.tmp" "$init_script"
    chmod +x "$init_script"

    # Перезапустить
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    if is_zapret2_running; then
        print_success "Discord конфигурация отключена"
    else
        print_error "Ошибка перезапуска сервиса"
        return 1
    fi

    return 0
}

# ==============================================================================
# СТАТУС DISCORD КОНФИГУРАЦИИ
# ==============================================================================

discord_status() {
    print_header "Статус Discord конфигурации"

    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    if [ ! -f "$init_script" ]; then
        print_error "Init скрипт не найден"
        return 1
    fi

    # Проверить DISCORD_ENABLED
    local discord_enabled
    discord_enabled=$(grep "^DISCORD_ENABLED=" "$init_script" | cut -d'=' -f2)

    if [ "$discord_enabled" = "1" ]; then
        print_success "Discord конфигурация: ВКЛЮЧЕНА"

        # Показать UDP порты
        print_info "UDP порты: $DISCORD_UDP_PORTS"

        # Показать параметры
        print_separator
        grep "^DISCORD_TCP=" "$init_script" | cut -d'"' -f2
        print_separator

        # Проверить процессы
        local process_count
        process_count=$(pgrep -c -f "nfqws2")
        print_info "Процессов nfqws2: $process_count"
    else
        print_info "Discord конфигурация: ОТКЛЮЧЕНА"
    fi

    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
