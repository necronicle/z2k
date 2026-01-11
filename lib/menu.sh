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
║          z2k - Zapret2 для Keenetic              ║
╚═══════════════════════════════════════════════════╝
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
    print_header "[2] Выбор стратегии"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        print_info "Сначала выполните установку (опция 1)"
        pause
        return
    fi

    local total_count
    total_count=$(get_strategies_count)

    # Проверить режим категорий
    local target_category=""
    if [ -f "$CATEGORY_STRATEGIES_CONF" ]; then
        cat <<'SUBMENU'

Выберите категорию:
[1] YouTube
[2] Discord
[3] Custom/RKN
[A] Все категории (одна стратегия)
[B] Назад

SUBMENU
        printf "Ваш выбор: "
        read_input cat_choice

        case "$cat_choice" in
            1) target_category="youtube" ;;
            2) target_category="discord" ;;
            3) target_category="custom" ;;
            [Aa]) target_category="all" ;;
            [Bb]) return ;;
            *)
                print_error "Неверный выбор"
                pause
                return
                ;;
        esac
    fi

    printf "\nВсего доступно стратегий: %s\n\n" "$total_count"
    printf "Введите номер стратегии (1-%s): " "$total_count"
    read_input strategy_num

    # Проверить что это число
    if ! echo "$strategy_num" | grep -qE '^[0-9]+$'; then
        print_error "Неверный формат номера"
        pause
        return
    fi

    # Проверить диапазон
    if [ "$strategy_num" -lt 1 ] || [ "$strategy_num" -gt "$total_count" ]; then
        print_error "Номер вне диапазона: $strategy_num"
        pause
        return
    fi

    # Проверить существование
    if ! strategy_exists "$strategy_num"; then
        print_error "Стратегия #$strategy_num не найдена"
        pause
        return
    fi

    # Показать параметры
    print_separator
    print_info "Стратегия #$strategy_num:"
    local params
    params=$(get_strategy "$strategy_num")
    echo "$params"
    print_separator

    printf "\nПрименить эту стратегию? [Y/n]: "
    read_input answer

    case "$answer" in
        [Nn]|[Nn][Oo])
            print_info "Отменено"
            ;;
        *)
            if [ -n "$target_category" ] && [ "$target_category" != "all" ]; then
                # Обновить стратегию для конкретной категории
                print_info "Применение стратегии #$strategy_num для категории $target_category..."

                # Обновить запись в category_strategies.conf
                local temp_file="/tmp/category_strategies.tmp"
                while IFS=':' read -r cat strat score; do
                    if [ "$cat" = "$target_category" ]; then
                        echo "$cat:$strategy_num:5"
                    else
                        echo "$cat:$strat:$score"
                    fi
                done < "$CATEGORY_STRATEGIES_CONF" > "$temp_file"
                mv "$temp_file" "$CATEGORY_STRATEGIES_CONF"

                # Применить все стратегии заново
                local all_strategies
                all_strategies=$(awk -F: '{printf "%s:%s:%s ", $1, $2, $3}' "$CATEGORY_STRATEGIES_CONF")
                apply_category_strategies "$all_strategies"
            else
                # Старый режим или "все категории"
                apply_strategy_safe "$strategy_num"
            fi
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

[1] TOP-20 по категориям (рекомендуется, ~5 мин)
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
            print_info "Автотест по категориям (YouTube, Discord, Custom)"
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
