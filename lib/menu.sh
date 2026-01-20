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
[0] Выход

MENU

        printf "Выберите опцию [0-9]: "
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

    print_info "Всего доступно стратегий: $total_count"
    print_separator

    # Интерактивный выбор стратегий по категориям (как в автотесте)
    print_info "Выберите стратегии для каждой категории:"
    printf "\n"

    # YouTube TCP
    local yt_tcp_strategy
    while true; do
        printf "YouTube TCP (youtube.com) [1-%s]: " "$total_count"
        read_input yt_tcp_strategy

        # Проверки
        if ! echo "$yt_tcp_strategy" | grep -qE '^[0-9]+$'; then
            print_error "Неверный формат номера"
            continue
        fi

        if [ "$yt_tcp_strategy" -lt 1 ] || [ "$yt_tcp_strategy" -gt "$total_count" ]; then
            print_error "Номер вне диапазона"
            continue
        fi

        if ! strategy_exists "$yt_tcp_strategy"; then
            print_error "Стратегия #$yt_tcp_strategy не найдена"
            continue
        fi

        # Показать параметры
        local params
        params=$(get_strategy "$yt_tcp_strategy")
        print_info "Выбрана: $params"
        break
    done

    printf "\n"

    # YouTube GV
    local yt_gv_strategy
    while true; do
        printf "YouTube GV (googlevideo CDN) [1-%s, Enter=использовать %s]: " "$total_count" "$yt_tcp_strategy"
        read_input yt_gv_strategy

        # Если пусто, использовать как для YouTube TCP
        if [ -z "$yt_gv_strategy" ]; then
            yt_gv_strategy="$yt_tcp_strategy"
            print_info "Используется та же стратегия: #$yt_gv_strategy"
            break
        fi

        # Проверки
        if ! echo "$yt_gv_strategy" | grep -qE '^[0-9]+$'; then
            print_error "Неверный формат номера"
            continue
        fi

        if [ "$yt_gv_strategy" -lt 1 ] || [ "$yt_gv_strategy" -gt "$total_count" ]; then
            print_error "Номер вне диапазона"
            continue
        fi

        if ! strategy_exists "$yt_gv_strategy"; then
            print_error "Стратегия #$yt_gv_strategy не найдена"
            continue
        fi

        # Показать параметры
        local params
        params=$(get_strategy "$yt_gv_strategy")
        print_info "Выбрана: $params"
        break
    done

    printf "\n"

    # RKN
    local rkn_strategy
    while true; do
        printf "RKN (заблокированные сайты) [1-%s, Enter=использовать %s]: " "$total_count" "$yt_tcp_strategy"
        read_input rkn_strategy

        # Если пусто, использовать как для YouTube TCP
        if [ -z "$rkn_strategy" ]; then
            rkn_strategy="$yt_tcp_strategy"
            print_info "Используется та же стратегия: #$rkn_strategy"
            break
        fi

        # Проверки
        if ! echo "$rkn_strategy" | grep -qE '^[0-9]+$'; then
            print_error "Неверный формат номера"
            continue
        fi

        if [ "$rkn_strategy" -lt 1 ] || [ "$rkn_strategy" -gt "$total_count" ]; then
            print_error "Номер вне диапазона"
            continue
        fi

        if ! strategy_exists "$rkn_strategy"; then
            print_error "Стратегия #$rkn_strategy не найдена"
            continue
        fi

        # Показать параметры
        local params
        params=$(get_strategy "$rkn_strategy")
        print_info "Выбрана: $params"
        break
    done

    # Итоговая таблица
    printf "\n"
    print_separator
    print_info "Итоговый выбор:"
    printf "%-20s | %s\n" "Категория" "Стратегия"
    print_separator
    printf "%-20s | #%s\n" "YouTube TCP" "$yt_tcp_strategy"
    printf "%-20s | #%s\n" "YouTube GV" "$yt_gv_strategy"
    printf "%-20s | #%s\n" "RKN" "$rkn_strategy"
    print_separator

    printf "\nПрименить выбранные стратегии? [Y/n]: "
    read_input answer

    case "$answer" in
        [Nn]|[Nn][Oo])
            print_info "Отменено"
            ;;
        *)
            print_info "Применение стратегий..."
            apply_category_strategies_v2 "$yt_tcp_strategy" "$yt_gv_strategy" "$rkn_strategy"
            print_success "Стратегии применены!"
            ;;
    esac

    pause
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
[4] Все стратегии (только HTTPS, 119 шт, ~10 мин)
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
            print_warning "Это займет около 10 минут!"
            if confirm "Продолжить?" "N"; then
                test_strategy_range 1 119
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
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
