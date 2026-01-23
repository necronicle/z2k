#!/bin/sh
# lib/config.sh - Управление конфигурацией и списками доменов
# Скачивание, обновление и управление списками для zapret2

# ==============================================================================
# УПРАВЛЕНИЕ СПИСКАМИ ДОМЕНОВ
# ==============================================================================

# Скачать списки доменов из zapret4rocket (z4r)
download_domain_lists() {
    print_header "Загрузка списков доменов"

    # Создать директорию для списков
    mkdir -p "$LISTS_DIR" || {
        print_error "Не удалось создать директорию: $LISTS_DIR"
        return 1
    }

    print_info "Источник: zapret4rocket (master branch)"

    # Списки для загрузки (Z4R структура)
    # Формат: source|target или special|url|target
    # ВАЖНО: разделитель "|", а НЕ ":", т.к. URL содержат двоеточия!
    local lists="
russia-discord.txt|discord.txt
russia-youtube.txt|youtube.txt
special|${Z4R_RKN_URL}|rkn.txt
"

    local success=0
    local failed=0

    echo "$lists" | while IFS='|' read -r source target extra; do
        [ -z "$source" ] && continue

        local url
        local output
        local display_name

        # Специальная обработка для файлов с custom URL
        if [ "$source" = "special" ]; then
            url="$target"
            output="${LISTS_DIR}/${extra}"
            display_name="RKN List"
        else
            url="${Z4R_LISTS_URL}/${source}"
            output="${LISTS_DIR}/${target}"
            display_name="${source}"
        fi

        print_info "Загрузка ${display_name}..."

        if curl -fsSL "$url" -o "$output"; then
            local count
            count=$(wc -l < "$output" 2>/dev/null || echo "0")
            print_success "$(basename "$output"): $count доменов"
            success=$((success + 1))
        else
            print_error "Ошибка загрузки: ${display_name}"
            failed=$((failed + 1))
        fi
    done

    # Создать пустой custom.txt если не существует
    if [ ! -f "${LISTS_DIR}/custom.txt" ]; then
        touch "${LISTS_DIR}/custom.txt"
        print_info "Создан custom.txt для пользовательских доменов"
    fi

    # Списки для QUIC YouTube (zapret4rocket структура)
    local yt_quic_dir="${ZAPRET2_DIR}/extra_strats/UDP/YT"
    local yt_quic_list="${yt_quic_dir}/List.txt"
    mkdir -p "$yt_quic_dir" || {
        print_warning "Не удалось создать каталог QUIC YT: $yt_quic_dir"
    }

    print_info "Загрузка списка QUIC YT..."
    if curl -fsSL "$Z4R_UDP_YT_LIST_URL" -o "$yt_quic_list"; then
        local yt_count
        yt_count=$(wc -l < "$yt_quic_list" 2>/dev/null || echo "0")
        print_success "List.txt: $yt_count доменов"
    else
        print_warning "Не удалось загрузить список QUIC YT"
    fi

    # Создать пустые файлы 1..8 (совместимость с zapret4rocket)
    for num in 1 2 3 4 5 6 7 8; do
        if [ ! -f "${yt_quic_dir}/${num}.txt" ]; then
            : > "${yt_quic_dir}/${num}.txt"
        fi
    done

    # Список для QUIC RuTracker (локальный)
    local rt_quic_dir="${ZAPRET2_DIR}/extra_strats/UDP/RUTRACKER"
    local rt_quic_list="${rt_quic_dir}/List.txt"
    mkdir -p "$rt_quic_dir" || {
        print_warning "Не удалось создать каталог QUIC RuTracker: $rt_quic_dir"
    }

    cat > "$rt_quic_list" <<'EOF'
rutracker.org
www.rutracker.org
static.rutracker.cc
fastpic.org
t-ru.org
www.t-ru.org
cloudflare-ech.com
cloudflare-dns.com
EOF

    # Дополнить RKN список критически важными доменами
    # RuTracker требует static.rutracker.cc для статики (картинки, CSS)
    # Cloudflare домены нужны для сайтов за CDN (rutracker, многие заблокированные сайты)
    # Источник: https://github.com/Flowseal/zapret-discord-youtube/blob/main/lists/list-general.txt
    if [ -f "${LISTS_DIR}/rkn.txt" ]; then
        local rkn_additions="
static.rutracker.cc
static.t-ru.org
cloudflare.com
cloudflare.net
cloudflare-dns.com
cloudflare-ech.com
cloudflareaccess.com
cloudflareapps.com
cloudflarebolt.com
cloudflareclient.com
cloudflareinsights.com
cloudflareok.com
cloudflarecp.com
cloudflarepartners.com
cloudflareportal.com
cloudflarepreview.com
cloudflareresolve.com
cloudflaressl.com
cloudflarestatus.com
cloudflarestorage.com
cloudflarestream.com
cloudflaretest.com
cloudfront.net
one.one.one.one
1.1.1.1
warp.plus
"
        local added=0
        echo "$rkn_additions" | while read -r domain; do
            [ -z "$domain" ] && continue
            if ! grep -qFx "$domain" "${LISTS_DIR}/rkn.txt" 2>/dev/null; then
                echo "$domain" >> "${LISTS_DIR}/rkn.txt"
                added=$((added + 1))
            fi
        done

        if [ "$added" -gt 0 ]; then
            print_info "Добавлено $added критически важных доменов (RuTracker, Cloudflare)"
        fi

        # Удалить дубликаты и пустые строки, сохраняя порядок
        if awk 'NF { sub(/\r$/, ""); if (!seen[$0]++) print }' "${LISTS_DIR}/rkn.txt" \
            > "${LISTS_DIR}/rkn.txt.tmp" 2>/dev/null; then
            mv "${LISTS_DIR}/rkn.txt.tmp" "${LISTS_DIR}/rkn.txt"
        else
            rm -f "${LISTS_DIR}/rkn.txt.tmp"
        fi
    fi


    # Дополнить Discord список важными доменами
    if [ -f "${LISTS_DIR}/discord.txt" ]; then
        local discord_additions="
ntc.party
"
        local added=0
        echo "$discord_additions" | while read -r domain; do
            [ -z "$domain" ] && continue
            if ! grep -qFx "$domain" "${LISTS_DIR}/discord.txt" 2>/dev/null; then
                echo "$domain" >> "${LISTS_DIR}/discord.txt"
                added=$((added + 1))
            fi
        done

        if [ "$added" -gt 0 ]; then
            print_info "Добавлено $added дополнительных доменов для Discord"
        fi
    fi

    print_separator
    print_success "Списки доменов загружены"

    return 0
}

# Обновить списки доменов
update_domain_lists() {
    print_header "Обновление списков доменов"

    # Проверить существование директории
    if [ ! -d "$LISTS_DIR" ]; then
        print_error "Директория списков не найдена: $LISTS_DIR"
        print_info "Запустите установку сначала"
        return 1
    fi

    # Создать backup существующих списков
    print_info "Создание резервных копий..."
    for list in discord.txt youtube.txt rkn.txt; do
        if [ -f "${LISTS_DIR}/${list}" ]; then
            cp "${LISTS_DIR}/${list}" "${LISTS_DIR}/${list}.backup"
        fi
    done

    # Скачать обновленные списки
    download_domain_lists

    # Показать изменения
    print_separator
    print_info "Текущие списки доменов:"

    for list in discord.txt youtube.txt rkn.txt custom.txt; do
        if [ -f "${LISTS_DIR}/${list}" ]; then
            local count
            count=$(wc -l < "${LISTS_DIR}/${list}" 2>/dev/null || echo "0")
            printf "  %-20s: %s доменов\n" "$list" "$count"
        fi
    done

    print_separator

    # Спросить о перезапуске сервиса
    if is_zapret2_running; then
        printf "Перезапустить сервис для применения изменений? [Y/n]: "
        read -r answer </dev/tty </dev/tty

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

    if [ ! -d "$LISTS_DIR" ]; then
        print_error "Списки доменов не установлены"
        return 1
    fi

    printf "%-20s | %-10s | %s\n" "Список" "Доменов" "Путь"
    print_separator

    for list in discord.txt youtube.txt rkn.txt custom.txt; do
        local path="${LISTS_DIR}/${list}"
        if [ -f "$path" ]; then
            local count
            count=$(wc -l < "$path" 2>/dev/null || echo "0")
            printf "%-20s | %-10s | %s\n" "$list" "$count" "$path"
        else
            printf "%-20s | %-10s | %s\n" "$list" "не найден" "-"
        fi
    done

    print_separator
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
        echo "QUIC_STRATEGY=43" > "$QUIC_STRATEGY_FILE"
    fi

    # Создать файл для QUIC стратегии RuTracker
    if [ ! -f "$RUTRACKER_QUIC_STRATEGY_FILE" ]; then
        echo "RUTRACKER_QUIC_STRATEGY=43" > "$RUTRACKER_QUIC_STRATEGY_FILE"
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
# Критичные государственные сервисы РФ

# Госуслуги (ЕСИА)
gosuslugi.ru
esia.gosuslugi.ru
lk.gosuslugi.ru
static.gosuslugi.ru
beta.gosuslugi.ru
pos.gosuslugi.ru

# Налоговая служба
nalog.gov.ru
lkfl2.nalog.ru
lkul.nalog.ru
service.nalog.ru

# Пенсионный фонд
pfr.gov.ru
es.pfr.gov.ru
lkfr.pfr.gov.ru

# Другие важные госсервисы
mos.ru
pgu.mos.ru
uslugi.mosreg.ru
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
