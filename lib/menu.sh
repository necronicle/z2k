#!/bin/sh
# lib/menu.sh - Интерактивное меню управления z2k
# 9 опций для полного управления zapret2

# ==============================================================================
# ВСПОМОГАТЕЛЬНАЯ ФУНКЦИЯ ДЛЯ ЧТЕНИЯ ВВОДА
# ==============================================================================

# Читать ввод пользователя (работает даже когда stdin перенаправлен через pipe)
read_input() {
    read -r "$@" </dev/tty
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

show_main_menu() {
    while true; do
        clear_screen

        cat <<'MENU'
+===================================================+
|          z2k - Zapret2 для Keenetic               |
+===================================================+


MENU

        # Показать текущий статус
        printf "\n"
        printf " Состояние: %s\n" "$(is_zapret2_installed && echo 'Установлен' || echo 'Не установлен')"

        if is_zapret2_installed; then
            printf " Сервис: %s\n" "$(get_service_status)"

            # Проверить режим стратегий
            if [ -f "$CATEGORY_STRATEGIES_CONF" ]; then
                local count
                count=$(grep -c ":" "$CATEGORY_STRATEGIES_CONF" 2>/dev/null || echo 0)
                printf " Стратегии: %s категорий\n" "$count"
            else
                printf " Текущая стратегия: #%s\n" "$(get_current_strategy)"
            fi

            # Проверить режим ALL TCP-443
            local all_tcp443_conf="${CONFIG_DIR}/all_tcp443.conf"
            if [ -f "$all_tcp443_conf" ]; then
                . "$all_tcp443_conf"
                if [ "$ENABLED" = "1" ]; then
                    printf " Режим Austerusj: Включен (без хостлистов)\n"
                fi
            fi

            # Показать статус RST-фильтра и silent fallback
            local rst_config_file="${ZAPRET2_DIR}/config"
            if [ -f "$rst_config_file" ]; then
                local DROP_DPI_RST=0
                eval "$(grep '^DROP_DPI_RST=' "$rst_config_file")"
                if [ "$DROP_DPI_RST" = "1" ]; then
                    printf " RST-фильтр: Включен (пассивный DPI)\n"
                fi
                local RKN_SILENT_FALLBACK=0
                eval "$(grep '^RKN_SILENT_FALLBACK=' "$rst_config_file")"
                if [ "$RKN_SILENT_FALLBACK" = "1" ]; then
                    printf " Silent fallback РКН: Включен\n"
                fi
            fi

        fi

        cat <<'MENU'

[1] Установить/Переустановить zapret2
[2] Управление сервисом
[3] Обновить списки доменов
[4] Резервная копия/Восстановление
[5] Удалить zapret2
[A] Режим без хостлистов (для Austerusj)
[W] Whitelist (исключения)
[R] RST-фильтр (пассивный DPI)
[F] Silent fallback для РКН (осторожно, возможны поломки)
[T] Telegram MTProxy (тестовая функция)
[S] Скрипты custom.d
[0] Выход

MENU

        printf "Выберите опцию [0-5,A,R,F,T,W,S]: "
        read_input choice

        case "$choice" in
            1)
                menu_install
                ;;
            2)
                menu_service_control
                ;;
            3)
                menu_update_lists
                ;;
            4)
                menu_backup_restore
                ;;
            5)
                menu_uninstall
                ;;
            a|A)
                menu_all_tcp443
                ;;
            r|R)
                menu_rst_filter
                ;;
            f|F)
                menu_rkn_silent_fallback
                ;;
            t|T)
                menu_telegram_mtproxy
                ;;
            w|W)
                menu_whitelist
                ;;
            s|S)
                menu_custom_scripts
                ;;
            0)
                print_info "Выход из меню"
                return 0
                ;;
            *)
                print_error "Неверный выбор: $choice"
                pause
                ;;
        esac
    done
}

# ==============================================================================
# ПОДМЕНЮ: УСТАНОВКА
# ==============================================================================

menu_install() {
    clear_screen
    print_header "[1] Установка/Переустановка zapret2"

    if is_zapret2_installed; then
        print_warning "zapret2 уже установлен"
        printf "\nПереустановить? [y/N]: "
        read_input answer

        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                run_full_install
                ;;
            *)
                print_info "Установка отменена"
                ;;
        esac
    else
        run_full_install
    fi

    pause
}

# ==============================================================================
# ПОДМЕНЮ: ВЫБОР СТРАТЕГИИ
# ==============================================================================

menu_select_strategy() {
    clear_screen
    print_header "[2] Выбор стратегии по категориям"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        print_info "Сначала выполните установку (опция 1)"
        pause
        return
    fi

    local total_count
    total_count=$(get_strategies_count)
    # Прочитать текущие стратегии
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

    print_separator
    print_info "Текущие стратегии (autocircular):"
    printf "  YouTube TCP: #%s\n" "$current_yt_tcp"
    printf "  YouTube GV:  #%s\n" "$current_yt_gv"
    printf "  RKN:         #%s\n" "$current_rkn"
    printf "  QUIC YouTube: #%s\n" "$(get_current_quic_strategy)"
    print_separator

    # Подменю выбора категории
    cat <<'SUBMENU'

Выберите категорию для применения стратегии:
[1] YouTube TCP (youtube.com)   -> стратегия #2
[2] YouTube GV (googlevideo CDN) -> стратегия #3
[3] RKN (заблокированные сайты) -> стратегия #1
[4] QUIC (UDP 443)
[B] Назад

SUBMENU
    printf "Ваш выбор: "
    read_input category_choice

    case "$category_choice" in
        1)
            # YouTube TCP — фиксированная стратегия #2
            local new_strategy=2
            print_separator
            print_info "Применяю autocircular стратегию #$new_strategy для YouTube TCP..."
            apply_category_strategies_v2 "$new_strategy" "$current_yt_gv" "$current_rkn"
            print_separator
            test_category_availability "YouTube TCP" "youtube.com"
            print_separator

            printf "Сохранить? [Y/n]: "
            read_input apply_confirm
            case "$apply_confirm" in
                [Nn]|[Nn][Oo])
                    print_info "Откатываю..."
                    apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn"
                    print_success "Откат выполнен"
                    ;;
                *)
                    save_category_strategies "$new_strategy" "$current_yt_gv" "$current_rkn"
                    print_success "Стратегия YouTube TCP сохранена!"
                    ;;
            esac
            return
            ;;
        2)
            # YouTube GV — фиксированная стратегия #3
            local new_strategy=3
            print_separator
            print_info "Применяю autocircular стратегию #$new_strategy для YouTube GV..."
            apply_category_strategies_v2 "$current_yt_tcp" "$new_strategy" "$current_rkn"
            print_separator
            local gv_domain
            gv_domain=$(generate_gv_domain)
            test_category_availability "YouTube GV" "$gv_domain"
            print_separator

            printf "Сохранить? [Y/n]: "
            read_input apply_confirm
            case "$apply_confirm" in
                [Nn]|[Nn][Oo])
                    print_info "Откатываю..."
                    apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn"
                    print_success "Откат выполнен"
                    ;;
                *)
                    save_category_strategies "$current_yt_tcp" "$new_strategy" "$current_rkn"
                    print_success "Стратегия YouTube GV сохранена!"
                    ;;
            esac
            return
            ;;
        3)
            # RKN — фиксированная стратегия #1
            local new_strategy=1
            print_separator
            print_info "Применяю autocircular стратегию #$new_strategy для RKN..."
            apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$new_strategy"
            print_separator
            test_category_availability_rkn
            print_separator

            printf "Сохранить? [Y/n]: "
            read_input apply_confirm
            case "$apply_confirm" in
                [Nn]|[Nn][Oo])
                    print_info "Откатываю..."
                    apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn"
                    print_success "Откат выполнен"
                    ;;
                *)
                    save_category_strategies "$current_yt_tcp" "$current_yt_gv" "$new_strategy"
                    print_success "Стратегия RKN сохранена!"
                    ;;
            esac
            return
            ;;
        4)
            # QUIC (UDP 443)
            menu_quic_settings
            return
            ;;
        [Bb])
            return
            ;;
        *)
            print_error "Неверный выбор"
            pause
            return
            ;;
    esac
}

# Вспомогательная функция: проверка доступности категории
test_category_availability() {
    local category_name=$1
    local test_domain=$2

    print_info "Проверка доступности: $category_name ($test_domain)..."

    # Подождать 2 секунды для применения правил
    sleep 2

    # Запустить тест
    if test_strategy_tls "$test_domain" 5; then
        print_success "[OK] $category_name доступен! Стратегия работает."
    else
        print_error "[FAIL] $category_name недоступен. Попробуйте другую стратегию."
        print_info "Стратегии переключаются автоматически через autocircular."
    fi
}

# Вспомогательная функция: проверка доступности RKN (3 домена)
test_category_availability_rkn() {
    local test_domains="meduza.io facebook.com rutracker.org"
    local success_count=0

    print_info "Проверка доступности: RKN (meduza.io, facebook.com, rutracker.org)..."

    sleep 2

    for domain in $test_domains; do
        if test_strategy_tls "$domain" 5; then
            success_count=$((success_count + 1))
        fi
    done

    if [ "$success_count" -ge 2 ]; then
        print_success "[OK] RKN доступен! Стратегия работает. (${success_count}/3)"
    else
        print_error "[FAIL] RKN недоступен. Попробуйте другую стратегию. (${success_count}/3)"
        print_info "Стратегии переключаются автоматически через autocircular."
    fi
}

# ==============================================================================
# ПОДМЕНЮ: АВТОТЕСТ
# ==============================================================================

menu_rutracker_blockcheck() {
    clear_screen
    print_header "[3] HTTP blockcheck (fast-torrent.ru)"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    print_info "Запуск blockcheck для fast-torrent.ru (HTTP, порт 80)"
    print_info "Поиск рабочей стратегии обхода HTTP DPI redirect"
    if confirm "Продолжить?" "Y"; then
        run_blockcheck_http "fast-torrent.ru"
    fi

    pause
}

# ==============================================================================
# ПОДМЕНЮ: УПРАВЛЕНИЕ СЕРВИСОМ
# ==============================================================================

menu_service_control() {
    clear_screen
    print_header "[4] Управление сервисом"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    cat <<'SUBMENU'
[1] Запустить сервис
[2] Остановить сервис
[3] Перезапустить сервис
[4] Статус сервиса
[B] Назад

SUBMENU

    printf "Выберите действие: "
    read_input action

    case "$action" in
        1)
            print_info "Запуск сервиса..."
            "$INIT_SCRIPT" start
            ;;
        2)
            print_info "Остановка сервиса..."
            "$INIT_SCRIPT" stop
            ;;
        3)
            print_info "Перезапуск сервиса..."
            "$INIT_SCRIPT" restart
            ;;
        4)
            "$INIT_SCRIPT" status
            ;;
        [Bb])
            return
            ;;
        *)
            print_error "Неверный выбор"
            ;;
    esac

    pause
}

# ==============================================================================
# ПОДМЕНЮ: ОБНОВЛЕНИЕ СПИСКОВ
# ==============================================================================

menu_update_lists() {
    clear_screen
    print_header "[6] Обновление списков доменов"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    # Показать текущие списки
    show_domain_lists_stats

    printf "\nОбновить списки доменов? [Y/n]: "
    read_input answer

    case "$answer" in
        [Nn]|[Nn][Oo])
            print_info "Отменено"
            ;;
        *)
            update_domain_lists
            ;;
    esac

    pause
}

# ==============================================================================
# ПОДМЕНЮ: BACKUP/RESTORE
# ==============================================================================

menu_backup_restore() {
    while true; do
        clear_screen
        print_header "[4] Резервная копия/Восстановление"

        if ! is_zapret2_installed; then
            print_error "zapret2 не установлен"
            pause
            return
        fi

        cat <<'SUBMENU'
[1] Создать резервную копию
[2] Восстановить из резервной копии
[3] Сбросить конфигурацию
[B] Назад

SUBMENU

        printf "Выберите действие: "
        read_input action

        case "$action" in
            1)
                backup_config
                ;;
            2)
                restore_config
                ;;
            3)
                print_warning "Это сбросит всю конфигурацию к значениям по умолчанию!"
                confirm "Вы уверены?" "N" || { pause; continue; }
                reset_config
                ;;
            [Bb])
                return
                ;;
            *)
                print_error "Неверный выбор"
                ;;
        esac

        pause
    done
}

# ==============================================================================
# ПОДМЕНЮ: УДАЛЕНИЕ
# ==============================================================================

menu_uninstall() {
    clear_screen
    print_header "[9] Удаление zapret2"

    if ! is_zapret2_installed; then
        print_info "zapret2 не установлен"
        pause
        return
    fi

    uninstall_zapret2

    pause
}

# ==============================================================================
# ПОДМЕНЮ: РЕЖИМ БЕЗ ХОСТЛИСТОВ (ДЛЯ AUSTERUS)
# ==============================================================================

menu_all_tcp443() {
    clear_screen
    print_header "Режим без хостлистов (для Austerusj)"

    local conf_file="${CONFIG_DIR}/all_tcp443.conf"

    if [ ! -f "$conf_file" ]; then
        print_error "Файл конфигурации не найден: $conf_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    . "$conf_file"
    local current_enabled=$ENABLED

    print_separator

    print_info "Статус: $([ "$current_enabled" = "1" ] && echo 'Включен' || echo 'Выключен')"

    print_separator

    cat <<'SUBMENU'

Простые стратегии из Zapret1, без хостлистов и автоциркуляра.
Применяются ко ВСЕМУ трафику на портах 80/443 (TCP+UDP).

Стратегии:
  HTTP  (TCP 80):  fake(zero_256, ttl=0, badsum+badseq) + multisplit
  TLS   (TCP 443): 2x fake(zero_256+google_hello, ttl=0, badsum+badseq) + multidisorder
  QUIC  (UDP 443): fake(zero_256, ttl=0)

При включении заменяет ВСЕ профили z2k (YT/RKN/Discord/HTTP).
При выключении возвращаются стандартные автоциркуляры z2k.

[1] Включить
[2] Выключить
[B] Назад

SUBMENU

    printf "Выберите опцию [1-2,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            sed -i "s/^ENABLED=.*/ENABLED=1/" "$conf_file"
            print_success "Режим Austerusj включен"
            print_info "Пересоздание конфига..."
            create_official_config "/opt/zapret2/config"

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            else
                print_warning "Сервис не запущен. Запустите через [4] Управление сервисом"
            fi

            pause
            ;;

        2)
            if [ "$current_enabled" != "1" ]; then
                print_info "Режим уже выключен"
                pause
                return 0
            fi

            sed -i "s/^ENABLED=.*/ENABLED=0/" "$conf_file"
            print_success "Режим Austerusj выключен, возврат к автоциркулярам z2k"
            print_info "Пересоздание конфига..."
            create_official_config "/opt/zapret2/config"

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi

            pause
            ;;

        b|B)
            return 0
            ;;

        *)
            print_error "Неверный выбор: $sub_choice"
            pause
            ;;
    esac
}

# ==============================================================================
# ПОДМЕНЮ: RST-ФИЛЬТР (ПАССИВНЫЙ DPI)
# ==============================================================================

menu_rst_filter() {
    clear_screen
    print_header "RST-фильтр (пассивный DPI)"

    local config_file="${ZAPRET2_DIR}/config"

    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local DROP_DPI_RST=0
    eval "$(grep '^DROP_DPI_RST=' "$config_file")"

    print_separator
    print_info "Статус: $([ "$DROP_DPI_RST" = "1" ] && echo 'Включен' || echo 'Выключен')"
    print_separator

    cat <<'SUBMENU'

ТСПУ (DPI провайдера) отправляет поддельные TCP RST пакеты
раньше реального ответа сервера, чтобы разорвать соединение.
Признак: IP Identification 0x0000-0x000F (в реальных пакетах
это поле случайное).

RST-фильтр блокирует такие пакеты через iptables raw/PREROUTING.
Это помогает если сайты разрываются сразу после TLS handshake.

Требуется модуль xt_u32 (есть в Keenetic с Entware).

[1] Включить
[2] Выключить
[B] Назад

SUBMENU

    printf "Выберите опцию [1-2,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            if grep -q '^DROP_DPI_RST=' "$config_file"; then
                sed -i 's/^DROP_DPI_RST=.*/DROP_DPI_RST=1/' "$config_file"
            else
                echo "DROP_DPI_RST=1" >> "$config_file"
            fi
            print_success "RST-фильтр включен"

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен с RST-фильтром"
            else
                print_warning "Сервис не запущен. Запустите через [4] Управление сервисом"
            fi

            pause
            ;;

        2)
            if [ "$DROP_DPI_RST" != "1" ]; then
                print_info "Фильтр уже выключен"
                pause
                return 0
            fi

            sed -i 's/^DROP_DPI_RST=.*/DROP_DPI_RST=0/' "$config_file"
            print_success "RST-фильтр выключен"

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi

            pause
            ;;

        b|B)
            return 0
            ;;

        *)
            print_error "Неверный выбор: $sub_choice"
            pause
            ;;
    esac
}

# ==============================================================================
# ПОДМЕНЮ: СКРИПТЫ CUSTOM.D
# ==============================================================================

menu_custom_scripts() {
    clear_screen
    print_header "Скрипты custom.d"

    local zapret_config="/opt/zapret2/config"

    if [ ! -f "$zapret_config" ]; then
        print_error "Файл конфигурации не найден: $zapret_config"
        pause
        return 1
    fi

    # Прочитать текущее значение
    local current_value
    current_value=$(grep "^DISABLE_CUSTOM=" "$zapret_config" 2>/dev/null | cut -d= -f2)
    [ -z "$current_value" ] && current_value="1"

    print_separator

    if [ "$current_value" = "1" ]; then
        print_success "Скрипты custom.d: ОТКЛЮЧЕНЫ (рекомендуется)"
    else
        print_warning "Скрипты custom.d: ВКЛЮЧЕНЫ"
    fi

    print_separator

    cat <<'INFO'

Скрипты custom.d (50-stun4all, 50-discord-media) запускают
дополнительные демоны nfqws2 для обхода Discord voice/video.

ВНИМАНИЕ: Discord voice/video уже обрабатывается основными
стратегиями (профиль 6 — Discord UDP). Включение скриптов
создаст дублирующие демоны и может вызвать конфликты.

Включайте только если основные стратегии не помогают с Discord.

[1] Включить скрипты custom.d
[2] Отключить скрипты custom.d (рекомендуется)
[B] Назад

INFO

    printf "Выберите опцию [1-2,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            sed -i 's/^DISABLE_CUSTOM=.*/DISABLE_CUSTOM=0/' "$zapret_config"
            print_warning "Скрипты custom.d ВКЛЮЧЕНЫ"

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi

            pause
            ;;
        2)
            sed -i 's/^DISABLE_CUSTOM=.*/DISABLE_CUSTOM=1/' "$zapret_config"
            print_success "Скрипты custom.d ОТКЛЮЧЕНЫ"

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi

            pause
            ;;
        b|B)
            return 0
            ;;
        *)
            print_error "Неверный выбор: $sub_choice"
            pause
            ;;
    esac
}

menu_rkn_silent_fallback() {
    clear_screen
    print_header "Silent fallback для РКН (осторожно!)"

    local config_file="${ZAPRET2_DIR}/config"

    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local RKN_SILENT_FALLBACK=0
    eval "$(grep '^RKN_SILENT_FALLBACK=' "$config_file")"

    print_separator
    print_info "Статус: $([ "$RKN_SILENT_FALLBACK" = "1" ] && echo 'Включен' || echo 'Выключен')"
    print_separator

    cat <<'SUBMENU'

Детектор «тихих чёрных дыр» для РКН-списков.

Когда DPI молча блокирует соединение (не отвечая RST/alert),
circular не может определить, что стратегия не работает.
Silent fallback считает повторные ClientHello без ответа
за failure и принудительно ротирует стратегию.

По умолчанию включено только для YouTube. Включение для РКН
может вызвать ложные срабатывания на медленных сайтах — circular
будет ротировать стратегию когда сайт просто долго отвечает.

[1] Включить  (возможны поломки на медленных сайтах!)
[2] Выключить
[B] Назад

SUBMENU

    printf "Выберите опцию [1-2,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            if grep -q '^RKN_SILENT_FALLBACK=' "$config_file"; then
                sed -i 's/^RKN_SILENT_FALLBACK=.*/RKN_SILENT_FALLBACK=1/' "$config_file"
            else
                echo "RKN_SILENT_FALLBACK=1" >> "$config_file"
            fi
            print_success "Silent fallback для РКН включен"

            # Создать/удалить флаг-файл для Lua
            local flag_dir="${ZAPRET2_DIR}/extra_strats/cache/autocircular"
            touch "${flag_dir}/rkn_silent_fallback.flag" 2>/dev/null

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен с silent fallback для РКН"
            else
                print_warning "Сервис не запущен. Запустите через [2] Управление сервисом"
            fi

            pause
            ;;

        2)
            if [ "$RKN_SILENT_FALLBACK" != "1" ]; then
                print_info "Silent fallback уже выключен"
                pause
                return 0
            fi

            sed -i 's/^RKN_SILENT_FALLBACK=.*/RKN_SILENT_FALLBACK=0/' "$config_file"
            # Удалить флаг-файл
            rm -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/rkn_silent_fallback.flag" 2>/dev/null
            print_success "Silent fallback для РКН выключен"

            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi

            pause
            ;;

        b|B)
            return 0
            ;;

        *)
            print_error "Неверный выбор: $sub_choice"
            pause
            ;;
    esac
}

# ==============================================================================
# ПОДМЕНЮ: TELEGRAM MTPROXY
# ==============================================================================

menu_telegram_mtproxy() {
    local MTPROXY_BIN="/opt/sbin/tg-mtproxy-client"
    local MTPROXY_PID="/var/run/tg-mtproxy-client.pid"
    local MTPROXY_PORT="9443"

    while true; do
        clear_screen
        print_header "Telegram прокси (тестовая функция)"

        # Check status
        local running=false
        if [ -f "$MTPROXY_PID" ] && kill -0 "$(cat $MTPROXY_PID 2>/dev/null)" 2>/dev/null; then
            running=true
        elif pgrep -f tg-mtproxy-client >/dev/null 2>&1; then
            running=true
        fi

        print_separator
        if $running; then
            printf " Статус: Включен\n"
            printf " Telegram работает автоматически на всех устройствах\n"
        else
            printf " Статус: Выключен\n"
        fi
        print_separator

        cat <<'SUBMENU'

Обход блокировки Telegram через Cloudflare WebSocket.
Провайдер видит только HTTPS к Cloudflare CDN.
Настройка устройств не требуется — работает прозрачно.

[1] Включить
[2] Выключить
[B] Назад

SUBMENU

        printf "Выберите опцию [1-2,B]: "
        read_input sub_choice

        case "$sub_choice" in
            1)
                if ! [ -f "$MTPROXY_BIN" ]; then
                    print_warning "Бинарник не найден, скачиваю..."
                    local tg_arch=""
                    case "$(uname -m)" in
                        aarch64|arm64)  tg_arch="arm64" ;;
                        armv7*|armv6*)  tg_arch="arm" ;;
                        mipsel|mipsle)  tg_arch="mipsel" ;;
                        mips)           tg_arch="mips" ;;
                        x86_64|amd64)   tg_arch="amd64" ;;
                        i?86)           tg_arch="x86" ;;
                        *)              tg_arch="" ;;
                    esac
                    if [ -n "$tg_arch" ]; then
                        local tg_bin="tg-mtproxy-client-linux-${tg_arch}"
                        local tg_ok=false
                        for tg_url in \
                            "https://cdn.jsdelivr.net/gh/necronicle/z2k@master/mtproxy-client/builds/${tg_bin}" \
                            "https://raw.githubusercontent.com/necronicle/z2k/master/mtproxy-client/builds/${tg_bin}" \
                            "https://github.com/necronicle/z2k/releases/download/tg-mtproxy-v1.0/${tg_bin}"; do
                            curl -fsSL "$tg_url" -o "$MTPROXY_BIN" 2>/dev/null
                            if [ -f "$MTPROXY_BIN" ] && [ -s "$MTPROXY_BIN" ]; then
                                local tg_size=$(wc -c < "$MTPROXY_BIN" 2>/dev/null)
                                if [ "$tg_size" -gt 100000 ] 2>/dev/null; then
                                    tg_ok=true
                                    break
                                fi
                            fi
                        done
                        if $tg_ok; then
                            chmod +x "$MTPROXY_BIN"
                            print_success "Скачан для $tg_arch"
                        else
                            rm -f "$MTPROXY_BIN"
                            print_error "Не удалось скачать для $tg_arch"
                            pause
                            continue
                        fi
                    else
                        print_error "Неизвестная архитектура: $(uname -m)"
                        pause
                        continue
                    fi
                fi

                # Use init script for proper restart loop
                if [ -f "/opt/etc/init.d/S97tg-mtproxy" ]; then
                    chmod +x /opt/etc/init.d/S97tg-mtproxy 2>/dev/null
                    /opt/etc/init.d/S97tg-mtproxy restart
                else
                    # Fallback: download init script
                    curl -fsSL "https://raw.githubusercontent.com/necronicle/z2k/master/mtproxy-client/S97tg-mtproxy" \
                        -o /opt/etc/init.d/S97tg-mtproxy 2>/dev/null
                    chmod +x /opt/etc/init.d/S97tg-mtproxy 2>/dev/null
                    /opt/etc/init.d/S97tg-mtproxy start
                fi
                sleep 3

                if pgrep -f tg-mtproxy-client >/dev/null 2>&1; then
                    print_success "Telegram прокси включен"
                    print_info "Все устройства — Telegram работает автоматически"
                else
                    print_error "Не удалось запустить"
                    tail -5 /tmp/tg-mtproxy.log 2>/dev/null
                fi
                pause
                ;;

            2)
                /opt/etc/init.d/S97tg-mtproxy stop 2>/dev/null
                # Kill loop shell too
                if [ -f "$MTPROXY_PID" ]; then
                    kill "$(cat $MTPROXY_PID)" 2>/dev/null
                    rm -f "$MTPROXY_PID"
                fi
                killall tg-mtproxy-client 2>/dev/null
                # Disable autostart
                chmod -x /opt/etc/init.d/S97tg-mtproxy 2>/dev/null
                print_success "Telegram прокси выключен (автозапуск отключен)"
                pause
                ;;

            [Bb])
                return
                ;;

            *)
                print_error "Неверный выбор"
                pause
                ;;
        esac
    done
}

# ==============================================================================
# ПОДМЕНЮ: WHITELIST (ИСКЛЮЧЕНИЯ)
# ==============================================================================

menu_whitelist() {
    clear_screen
    print_header "Whitelist - Исключения из обработки"

    local whitelist_file="${LISTS_DIR}/whitelist.txt"

    # Проверить существование файла
    if [ ! -f "$whitelist_file" ]; then
        print_warning "Файл whitelist не найден: $whitelist_file"
        print_info "Создаю файл..."

        # Создать директорию если не существует
        if ! mkdir -p "$LISTS_DIR" 2>/dev/null; then
            print_error "Не удалось создать директорию: $LISTS_DIR"
            print_info "Проверьте права доступа"
            pause
            return 1
        fi

        # Создать базовый whitelist
        cat > "$whitelist_file" <<'EOF'
# Whitelist - домены исключенные из обработки zapret2
# Сервисы, которые могут работать некорректно с DPI bypass

# === Госуслуги РФ ===
gosuslugi.ru
esia.gosuslugi.ru
lk.gosuslugi.ru
nalog.ru
nalog.gov.ru
lkfl2.nalog.ru
pfr.gov.ru
es.pfr.gov.ru
mos.ru
mos-gorsud.ru
gov.ru
sudrf.ru

# === Российские сервисы ===
vk.com
vkcdn.net
userapi.com
vk.ru
vkvideo.ru
rutube.ru
yandex.ru
ya.ru
kinopoisk.ru
okko.tv
avito.ru
beeline.ru
beeline.tv
ottai.com
ipstream.one
vkusvill.ru

# === Steam ===
s.team
steam.tv
steamcdn.com
steamchat.com
steam-chat.com
steamgames.com
steamserver.net
steamstatic.com
steampowered.com
steamcontent.com
steamcommunity.com
steambroadcast.com
steamdeckcdn.com
steamdeckusercontent.com
steamuserimages-a.akamaihd.net
steamcdn-a.akamaihd.net
steampipe.akamaized.net
steamcdn-a.akamaized.net
steamstatic.akamaized.net
steamcommunity.akamaized.net
steamcommunity-a.akamaihd.net
steamcloudsweden.blob.core.windows.net
valve.net
valvecdn.com
valvecontent.com
valvesoftware.com

# === Epic Games ===
epicgames.com
epicgames.dev
epicgamescdn.com
unrealengine.com
easyanticheat.net
eac-cdn.com
fortnite.com
fab.com
artstation.com

# === Ubisoft ===
ubi.com
ubisoft.com
ubisoftconnect.com

# === PlayStation / Sony ===
playstation.net
playstation.com
account.sony.com
psremoteplay.com
playstationcloud.com
sonyentertainmentnetwork.com

# === Twitch ===
twitch.tv
ttvnw.net
jtvnw.net
twitchcdn.net
ext-twitch.tv
twitchsvc.net
live-video.net
twitch-shadow.net

# === Riot Games / Valorant ===
riotgames.com
riotcdn.net
valorant.com
playvalorant.com
pvp.net
vivox.com
sd-rtn.com

# === HoYoverse (Genshin, HSR) ===
hoyoverse.com
hoyolab.com
hoyo.link
yuanshen.com
genshinimpact.com
zenlesszonezero.com

# === AliExpress ===
aliexpress.com
aliexpress.ru
aliexpress.us
alicdn.com
ae.com

# === TikTok ===
tiktok.com
tiktokcdn.com
tiktokv.com
muscdn.com
byteoversea.com
ibytedtos.com
ttwstatic.com

# === Samsung ===
samsungosp.com
samsungqbe.com
samsungcloudsolution.com

# === Стриминг ===
netflix.com
vsetop.org

# === Google API ===
ogs.google.com
gstatic.com

# === Мониторинг и CDN ===
datadoghq.com
okcdn.ru
api.mycdn.me

# === Keenetic (KeenDNS, облако, обновления) ===
keenetic.pro
keenetic.com
keenetic.io
keenetic.cloud
keenetic.link

# === Разработка ===
raw.githubusercontent.com
EOF

        if [ ! -f "$whitelist_file" ]; then
            print_error "Не удалось создать файл whitelist"
            print_info "Проверьте права доступа"
            pause
            return 1
        fi

        print_success "Файл whitelist создан: $whitelist_file"
    fi

    while true; do
    print_separator

    cat <<'INFO'

Whitelist содержит домены, которые ИСКЛЮЧЕНЫ из обработки zapret2.
Это полезно для критичных сервисов, которые могут сломаться
при применении DPI-обхода (госуслуги, банки, и т.д.)

По умолчанию в whitelist включены:
  - Госуслуги РФ (gosuslugi, nalog, pfr, mos, gov.ru...)
  - Российские сервисы (VK, Yandex, Rutube, Avito, Beeline...)
  - Steam, Epic Games, Ubisoft, PlayStation
  - Twitch, Riot/Valorant, HoYoverse, TikTok
  - AliExpress, Samsung, Netflix

[1] Просмотреть whitelist
[2] Редактировать whitelist (vi)
[3] Добавить домен
[4] Удалить домен
[B] Назад

INFO

    printf "Выберите опцию [1-4,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            # Просмотр
            clear_screen
            print_header "Текущий whitelist"
            print_separator
            cat "$whitelist_file"
            print_separator
            pause
            ;;

        2)
            # Редактирование в vi
            print_info "Открытие whitelist в редакторе..."
            vi "$whitelist_file"

            # Перезапуск сервиса
            if is_zapret2_running; then
                print_info "Перезапуск сервиса для применения изменений..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi
            pause
            ;;

        3)
            # Добавить домен
            printf "Введите домен для добавления (например: example.com): "
            read_input new_domain

            # Простая валидация домена
            if ! echo "$new_domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                print_error "Неверный формат домена: $new_domain"
                pause
                continue
            fi

            # Проверить дубликаты
            if grep -qxF "$new_domain" "$whitelist_file"; then
                print_warning "Домен $new_domain уже в whitelist"
                pause
                continue
            fi

            # Добавить домен
            echo "$new_domain" >> "$whitelist_file"
            print_success "Домен $new_domain добавлен в whitelist"
            print_separator

            # Перезапуск сервиса
            if is_zapret2_running; then
                print_info "Перезапуск сервиса для применения изменений..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi
            pause
            ;;

        4)
            # Удалить домен
            printf "Введите домен для удаления: "
            read_input del_domain

            # Проверить наличие
            if ! grep -qxF "$del_domain" "$whitelist_file"; then
                print_error "Домен $del_domain не найден в whitelist"
                pause
                continue
            fi

            # Удалить домен
            grep -vxF "$del_domain" "$whitelist_file" > "${whitelist_file}.tmp" && mv "${whitelist_file}.tmp" "$whitelist_file"
            print_success "Домен $del_domain удален из whitelist"
            print_separator

            # Перезапуск сервиса
            if is_zapret2_running; then
                print_info "Перезапуск сервиса для применения изменений..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi
            pause
            ;;

        b|B)
            return 0
            ;;

        *)
            print_error "Неверный выбор: $sub_choice"
            pause
            ;;
    esac
    done
}

# ==============================================================================
# ПОДМЕНЮ: УПРАВЛЕНИЕ QUIC
# ==============================================================================

menu_quic_settings() {
    clear_screen
    print_header "Настройки QUIC"

    printf "\nТекущие настройки:\n"
    printf "  YouTube QUIC: стратегия #%s\n" "$(get_current_quic_strategy)"

    cat <<'MENU'

[1] YouTube QUIC - выбрать стратегию
[B] Назад

MENU

    printf "Выберите опцию: "
    read_input choice

    case "$choice" in
        1)
            menu_select_quic_strategy_youtube
            ;;
        b|B)
            return 0
            ;;
        *)
            print_error "Неверный выбор: $choice"
            pause
            ;;
    esac
}

# Выбор QUIC стратегии для YouTube
menu_select_quic_strategy_youtube() {
    clear_screen
    print_header "YouTube QUIC - выбор стратегии"

    local total_quic
    total_quic=$(get_quic_strategies_count)

    if [ "$total_quic" -eq 0 ]; then
        print_error "QUIC стратегии не найдены"
        pause
        return 1
    fi

    local current_quic
    current_quic=$(get_current_quic_strategy)

    printf "\nВсего QUIC стратегий: %s\n" "$total_quic"
    printf "Текущая стратегия: #%s\n\n" "$current_quic"

    printf "Введите номер стратегии [1-%s] или Enter для отмены: " "$total_quic"
    read_input new_strategy

    if [ -z "$new_strategy" ]; then
        print_info "Отменено"
        pause
        return 0
    fi

    if ! echo "$new_strategy" | grep -qE '^[0-9]+$'; then
        print_error "Неверный формат"
        pause
        return 1
    fi

    if [ "$new_strategy" -lt 1 ] || [ "$new_strategy" -gt "$total_quic" ]; then
        print_error "Номер вне диапазона"
        pause
        return 1
    fi

    if ! quic_strategy_exists "$new_strategy"; then
        print_error "QUIC стратегия #$new_strategy не найдена"
        pause
        return 1
    fi

    set_current_quic_strategy "$new_strategy"

    # Получить текущие стратегии
    local config_file="${CONFIG_DIR}/category_strategies.conf"
    local current_yt_tcp=1
    local current_yt_gv=1
    local current_rkn=1

    if [ -f "$config_file" ]; then
        current_yt_tcp=$(grep "^youtube_tcp:" "$config_file" 2>/dev/null | cut -d':' -f2)
        current_yt_gv=$(grep "^youtube_gv:" "$config_file" 2>/dev/null | cut -d':' -f2)
        current_rkn=$(grep "^rkn:" "$config_file" 2>/dev/null | cut -d':' -f2)
        [ -z "$current_yt_tcp" ] && current_yt_tcp=1
        [ -z "$current_yt_gv" ] && current_yt_gv=1
        [ -z "$current_rkn" ] && current_rkn=1
    fi

    apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$current_rkn"
    print_success "YouTube QUIC стратегия #$new_strategy применена"
    pause
}


# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
