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
╔═══════════════════════════════════════════════════╗
║   z2k - Zapret2 для Keenetic (PRE-ALPHA)        ║
╚═══════════════════════════════════════════════════╝

    ⚠️  Пре-альфа версия - в активной разработке!

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
                    printf " ALL TCP-443: Включен (стратегия #%s)\n" "$STRATEGY"
                fi
            fi
        fi

        cat <<'MENU'

[1] Установить/Переустановить zapret2
[2] Выбрать стратегию по номеру
[3] Автотест стратегий
[4] Управление сервисом
[5] Просмотр текущей стратегии
[6] Обновить списки доменов
[7] Настроить Discord (голос)
[8] Резервная копия/Восстановление
[9] Удалить zapret2
[A] Режим ALL TCP-443 (без хостлистов)
[W] Whitelist (исключения)
[0] Выход

MENU

        printf "Выберите опцию [0-9,A,W]: "
        read_input choice

        case "$choice" in
            1)
                menu_install
                ;;
            2)
                menu_select_strategy
                ;;
            3)
                menu_autotest
                ;;
            4)
                menu_service_control
                ;;
            5)
                menu_view_strategy
                ;;
            6)
                menu_update_lists
                ;;
            7)
                menu_discord
                ;;
            8)
                menu_backup_restore
                ;;
            9)
                menu_uninstall
                ;;
            a|A)
                menu_all_tcp443
                ;;
            w|W)
                menu_whitelist
                ;;
            0|q|Q)
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

    print_info "Всего доступно стратегий: $total_count"
    print_separator
    print_info "Текущие стратегии:"
    printf "  YouTube TCP: #%s\n" "$current_yt_tcp"
    printf "  YouTube GV:  #%s\n" "$current_yt_gv"
    printf "  RKN:         #%s\n" "$current_rkn"
    print_separator

    # Подменю выбора категории
    cat <<'SUBMENU'

Выберите категорию для изменения стратегии:
[1] YouTube TCP (youtube.com)
[2] YouTube GV (googlevideo CDN)
[3] RKN (заблокированные сайты)
[4] Все категории сразу
[B] Назад

SUBMENU
    printf "Ваш выбор: "
    read_input category_choice

    case "$category_choice" in
        1)
            # YouTube TCP
            menu_select_single_strategy "YouTube TCP" "$current_yt_tcp" "$total_count"
            local new_strategy=$?
            if [ "$new_strategy" -gt 0 ]; then
                apply_category_strategies_v2 "$new_strategy" "$current_yt_gv" "$current_rkn"
                print_success "Стратегия YouTube TCP обновлена!"
                print_separator
                test_category_availability "YouTube TCP" "youtube.com"
            fi
            ;;
        2)
            # YouTube GV
            menu_select_single_strategy "YouTube GV" "$current_yt_gv" "$total_count"
            local new_strategy=$?
            if [ "$new_strategy" -gt 0 ]; then
                apply_category_strategies_v2 "$current_yt_tcp" "$new_strategy" "$current_rkn"
                print_success "Стратегия YouTube GV обновлена!"
                print_separator
                test_category_availability "YouTube GV" "yt3.ggpht.com"
            fi
            ;;
        3)
            # RKN
            menu_select_single_strategy "RKN" "$current_rkn" "$total_count"
            local new_strategy=$?
            if [ "$new_strategy" -gt 0 ]; then
                apply_category_strategies_v2 "$current_yt_tcp" "$current_yt_gv" "$new_strategy"
                print_success "Стратегия RKN обновлена!"
                print_separator
                test_category_availability "RKN" "rutracker.org"
            fi
            ;;
        4)
            # Все категории
            menu_select_all_strategies "$total_count"
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

# Вспомогательная функция: проверка доступности категории
test_category_availability() {
    local category_name=$1
    local test_domain=$2

    print_info "Проверка доступности: $category_name ($test_domain)..."

    # Подождать 2 секунды для применения правил
    sleep 2

    # Запустить тест
    if test_strategy_tls "$test_domain" 5; then
        print_success "✓ $category_name доступен! Стратегия работает."
    else
        print_error "✗ $category_name недоступен. Попробуйте другую стратегию."
        print_info "Рекомендация: запустите автотест [3] для поиска рабочей стратегии"
    fi
}

# Вспомогательная функция: выбор стратегии для одной категории
menu_select_single_strategy() {
    local category_name=$1
    local current_strategy=$2
    local total_count=$3

    printf "\n"
    print_info "Выбор стратегии для: $category_name"
    printf "Текущая стратегия: #%s\n\n" "$current_strategy"

    while true; do
        printf "Введите номер стратегии [1-%s] или Enter для отмены: " "$total_count"
        read_input new_strategy

        # Отмена
        if [ -z "$new_strategy" ]; then
            print_info "Отменено"
            return 0
        fi

        # Проверки
        if ! echo "$new_strategy" | grep -qE '^[0-9]+$'; then
            print_error "Неверный формат номера"
            continue
        fi

        if [ "$new_strategy" -lt 1 ] || [ "$new_strategy" -gt "$total_count" ]; then
            print_error "Номер вне диапазона"
            continue
        fi

        if ! strategy_exists "$new_strategy"; then
            print_error "Стратегия #$new_strategy не найдена"
            continue
        fi

        # Показать параметры
        local params
        params=$(get_strategy "$new_strategy")
        print_info "Выбрана стратегия #$new_strategy:"
        printf "  %s\n\n" "$params"

        printf "Применить эту стратегию? [Y/n]: "
        read_input confirm

        case "$confirm" in
            [Nn]|[Nn][Oo])
                print_info "Отменено"
                return 0
                ;;
            *)
                return "$new_strategy"
                ;;
        esac
    done
}

# Вспомогательная функция: выбор стратегий для всех категорий
menu_select_all_strategies() {
    local total_count=$1

    printf "\n"
    print_info "Выбор стратегий для всех категорий:"
    printf "\n"

    # YouTube TCP
    local yt_tcp_strategy
    while true; do
        printf "YouTube TCP [1-%s]: " "$total_count"
        read_input yt_tcp_strategy

        if ! echo "$yt_tcp_strategy" | grep -qE '^[0-9]+$'; then
            print_error "Неверный формат"
            continue
        fi

        if [ "$yt_tcp_strategy" -lt 1 ] || [ "$yt_tcp_strategy" -gt "$total_count" ]; then
            print_error "Номер вне диапазона"
            continue
        fi

        if ! strategy_exists "$yt_tcp_strategy"; then
            print_error "Стратегия не найдена"
            continue
        fi

        break
    done

    # YouTube GV
    local yt_gv_strategy
    while true; do
        printf "YouTube GV [1-%s, Enter=использовать %s]: " "$total_count" "$yt_tcp_strategy"
        read_input yt_gv_strategy

        if [ -z "$yt_gv_strategy" ]; then
            yt_gv_strategy="$yt_tcp_strategy"
            print_info "Используется: #$yt_gv_strategy"
            break
        fi

        if ! echo "$yt_gv_strategy" | grep -qE '^[0-9]+$'; then
            print_error "Неверный формат"
            continue
        fi

        if [ "$yt_gv_strategy" -lt 1 ] || [ "$yt_gv_strategy" -gt "$total_count" ]; then
            print_error "Номер вне диапазона"
            continue
        fi

        if ! strategy_exists "$yt_gv_strategy"; then
            print_error "Стратегия не найдена"
            continue
        fi

        break
    done

    # RKN
    local rkn_strategy
    while true; do
        printf "RKN [1-%s, Enter=использовать %s]: " "$total_count" "$yt_tcp_strategy"
        read_input rkn_strategy

        if [ -z "$rkn_strategy" ]; then
            rkn_strategy="$yt_tcp_strategy"
            print_info "Используется: #$rkn_strategy"
            break
        fi

        if ! echo "$rkn_strategy" | grep -qE '^[0-9]+$'; then
            print_error "Неверный формат"
            continue
        fi

        if [ "$rkn_strategy" -lt 1 ] || [ "$rkn_strategy" -gt "$total_count" ]; then
            print_error "Номер вне диапазона"
            continue
        fi

        if ! strategy_exists "$rkn_strategy"; then
            print_error "Стратегия не найдена"
            continue
        fi

        break
    done

    # Итоговая таблица
    printf "\n"
    print_separator
    printf "%-20s | %s\n" "Категория" "Стратегия"
    print_separator
    printf "%-20s | #%s\n" "YouTube TCP" "$yt_tcp_strategy"
    printf "%-20s | #%s\n" "YouTube GV" "$yt_gv_strategy"
    printf "%-20s | #%s\n" "RKN" "$rkn_strategy"
    print_separator

    printf "\nПрименить? [Y/n]: "
    read_input answer

    case "$answer" in
        [Nn]|[Nn][Oo])
            print_info "Отменено"
            ;;
        *)
            apply_category_strategies_v2 "$yt_tcp_strategy" "$yt_gv_strategy" "$rkn_strategy"
            print_success "Все стратегии применены!"
            print_separator

            # Автопроверка всех категорий
            print_info "Запуск проверки доступности..."
            print_separator
            test_category_availability "YouTube TCP" "youtube.com"
            print_separator
            test_category_availability "YouTube GV" "yt3.ggpht.com"
            print_separator
            test_category_availability "RKN" "rutracker.org"
            ;;
    esac
}

# ==============================================================================
# ПОДМЕНЮ: АВТОТЕСТ
# ==============================================================================

menu_autotest() {
    clear_screen
    print_header "[3] Автотест стратегий"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    cat <<'SUBMENU'
Режимы тестирования:

[1] TOP-20 по категориям Z4R (YouTube TCP/GV + RKN, ~8-10 мин)
[2] TOP-20 общий (быстрый тест, ~2 мин)
[3] Диапазон (укажите вручную)
[4] Все стратегии (только HTTPS, 199 шт, ~15 мин)
[B] Назад

SUBMENU

    printf "Выберите режим: "
    read_input test_mode

    case "$test_mode" in
        1)
            clear_screen
            print_info "Автотест по категориям Z4R (YouTube TCP, YouTube GV, RKN)"
            if confirm "Начать тестирование?" "Y"; then
                auto_test_categories
            fi
            ;;
        2)
            clear_screen
            auto_test_top20
            ;;
        3)
            printf "\nНачало диапазона: "
            read_input start_range
            printf "Конец диапазона: "
            read_input end_range

            if [ -n "$start_range" ] && [ -n "$end_range" ]; then
                clear_screen
                test_strategy_range "$start_range" "$end_range"
            else
                print_error "Неверный диапазон"
            fi
            ;;
        4)
            clear_screen
            print_warning "Это займет около 15 минут!"
            if confirm "Продолжить?" "N"; then
                test_strategy_range 1 199
            fi
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
# ПОДМЕНЮ: ПРОСМОТР СТРАТЕГИИ
# ==============================================================================

menu_view_strategy() {
    clear_screen
    print_header "[5] Текущие стратегии"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    # Проверить наличие файла с категориями
    if [ -f "$CATEGORY_STRATEGIES_CONF" ]; then
        print_info "Стратегии по категориям:"
        print_separator

        # Прочитать и показать стратегии для каждой категории
        while IFS=':' read -r category strategy score; do
            [ -z "$category" ] && continue

            local params
            params=$(get_strategy "$strategy" 2>/dev/null)
            local type
            type=$(get_strategy_type "$strategy" 2>/dev/null)

            printf "\n[%s]\n" "$(echo "$category" | tr '[:lower:]' '[:upper:]')"
            printf "  Стратегия: #%s (оценка: %s/5)\n" "$strategy" "$score"
            printf "  Тип: %s\n" "$type"
        done < "$CATEGORY_STRATEGIES_CONF"

        print_separator
    else
        # Старый режим - одна стратегия
        local current
        current=$(get_current_strategy)

        if [ "$current" = "не задана" ] || [ -z "$current" ]; then
            print_warning "Стратегия не выбрана"
            print_info "Используется стратегия по умолчанию из init скрипта"
        else
            print_info "Текущая стратегия: #$current"
            print_separator

            local params
            params=$(get_strategy "$current")
            local type
            type=$(get_strategy_type "$current")

            printf "Тип: %s\n\n" "$type"
            printf "Параметры:\n%s\n" "$params"
            print_separator
        fi
    fi

    # Показать статус сервиса
    printf "\nСтатус сервиса: %s\n" "$(get_service_status)"

    if is_zapret2_running; then
        printf "\nПроцессы nfqws2:\n"
        pgrep -af "nfqws2" 2>/dev/null || print_info "Процессы не найдены"
    fi

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

    printf "\nОбновить списки из zapret4rocket? [Y/n]: "
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
# ПОДМЕНЮ: DISCORD
# ==============================================================================

menu_discord() {
    clear_screen
    print_header "[7] Настройка Discord (голос/видео)"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    # Вызвать функцию из lib/discord.sh
    configure_discord_voice

    pause
}

# ==============================================================================
# ПОДМЕНЮ: BACKUP/RESTORE
# ==============================================================================

menu_backup_restore() {
    clear_screen
    print_header "[8] Резервная копия/Восстановление"

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
# ПОДМЕНЮ: РЕЖИМ ALL TCP-443 (БЕЗ ХОСТЛИСТОВ)
# ==============================================================================

menu_all_tcp443() {
    clear_screen
    print_header "Режим ALL TCP-443 (без хостлистов)"

    local conf_file="${CONFIG_DIR}/all_tcp443.conf"

    # Проверить существование конфига
    if [ ! -f "$conf_file" ]; then
        print_error "Файл конфигурации не найден: $conf_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    # Прочитать текущую конфигурацию
    . "$conf_file"
    local current_enabled=$ENABLED
    local current_strategy=$STRATEGY

    print_separator

    print_info "Текущая конфигурация:"
    printf "  Статус: %s\n" "$([ "$current_enabled" = "1" ] && echo 'Включен' || echo 'Выключен')"
    printf "  Стратегия: #%s\n" "$current_strategy"

    print_separator

    cat <<'SUBMENU'

ВНИМАНИЕ: Этот режим применяет стратегию ко ВСЕМУ трафику HTTPS (TCP-443)
без фильтрации по доменам из хостлистов!

Использование:
  - Для обхода блокировок ВСЕХ сайтов одной стратегией
  - Когда хостлисты не помогают
  - Для тестирования универсальных стратегий

Недостатки:
  - Может замедлить ВСЕ HTTPS соединения
  - Увеличивает нагрузку на роутер
  - Может вызвать проблемы с некоторыми сайтами

[1] Включить режим ALL TCP-443
[2] Выключить режим ALL TCP-443
[3] Изменить стратегию
[B] Назад

SUBMENU

    printf "Выберите опцию [1-3,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            # Включить режим
            print_info "Выбор стратегии для режима ALL TCP-443..."
            print_separator

            # Показать топ стратегий
            print_info "Рекомендуемые стратегии для режима ALL TCP-443:"
            printf "  #1  - multidisorder (базовая)\n"
            printf "  #7  - multidisorder:pos=1\n"
            printf "  #13 - multidisorder:pos=sniext+1\n"
            printf "  #67 - fakedsplit с ip_autottl (продвинутая)\n"
            print_separator

            printf "Введите номер стратегии [1-199] или Enter для #1: "
            read_input strategy_num

            # Валидация
            if [ -z "$strategy_num" ]; then
                strategy_num=1
            fi

            if ! echo "$strategy_num" | grep -qE '^[0-9]+$' || [ "$strategy_num" -lt 1 ] || [ "$strategy_num" -gt 199 ]; then
                print_error "Неверный номер стратегии: $strategy_num"
                pause
                return 1
            fi

            # Обновить конфиг
            sed -i "s/^ENABLED=.*/ENABLED=1/" "$conf_file"
            sed -i "s/^STRATEGY=.*/STRATEGY=$strategy_num/" "$conf_file"

            print_success "Режим ALL TCP-443 включен с стратегией #$strategy_num"
            print_separator

            # Перезапуск сервиса
            if is_zapret2_running; then
                print_info "Перезапуск сервиса для применения изменений..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            else
                print_warning "Сервис не запущен. Запустите через [4] Управление сервисом"
            fi

            pause
            ;;

        2)
            # Выключить режим
            if [ "$current_enabled" != "1" ]; then
                print_info "Режим ALL TCP-443 уже выключен"
                pause
                return 0
            fi

            sed -i "s/^ENABLED=.*/ENABLED=0/" "$conf_file"
            print_success "Режим ALL TCP-443 выключен"
            print_separator

            # Перезапуск сервиса
            if is_zapret2_running; then
                print_info "Перезапуск сервиса для применения изменений..."
                "$INIT_SCRIPT" restart
                print_success "Сервис перезапущен"
            fi

            pause
            ;;

        3)
            # Изменить стратегию
            if [ "$current_enabled" != "1" ]; then
                print_warning "Режим ALL TCP-443 выключен"
                print_info "Сначала включите режим через [1]"
                pause
                return 0
            fi

            printf "Текущая стратегия: #%s\n" "$current_strategy"
            print_separator
            printf "Введите новый номер стратегии [1-199]: "
            read_input new_strategy

            # Валидация
            if ! echo "$new_strategy" | grep -qE '^[0-9]+$' || [ "$new_strategy" -lt 1 ] || [ "$new_strategy" -gt 199 ]; then
                print_error "Неверный номер стратегии: $new_strategy"
                pause
                return 1
            fi

            sed -i "s/^STRATEGY=.*/STRATEGY=$new_strategy/" "$conf_file"
            print_success "Стратегия изменена на #$new_strategy"
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
        print_error "Файл whitelist не найден: $whitelist_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    print_separator

    cat <<'INFO'

Whitelist содержит домены, которые ИСКЛЮЧЕНЫ из обработки zapret2.
Это полезно для критичных сервисов, которые могут сломаться
при применении DPI-обхода (госуслуги, банки, и т.д.)

По умолчанию в whitelist включены:
  - gosuslugi.ru (Госуслуги, ЕСИА)
  - nalog.gov.ru (Налоговая служба)
  - pfr.gov.ru (Пенсионный фонд)
  - mos.ru (Москва)

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
                return 1
            fi

            # Проверить дубликаты
            if grep -qx "$new_domain" "$whitelist_file"; then
                print_warning "Домен $new_domain уже в whitelist"
                pause
                return 0
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
            if ! grep -qx "$del_domain" "$whitelist_file"; then
                print_error "Домен $del_domain не найден в whitelist"
                pause
                return 1
            fi

            # Удалить домен
            sed -i "/^${del_domain}$/d" "$whitelist_file"
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
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
