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
|   z2k - Zapret2 для Keenetic (ALPHA)            |
+===================================================+


MENU

        # Показать текущий статус
        printf "\n"
        printf " Состояние: %s\n" "$(is_zapret2_installed && echo 'Установлен' || echo 'Не установлен')"

        if is_zapret2_installed; then
            printf " Сервис: %s\n" "$(get_service_status)"
            printf " TCP стратегия: #%s\n" "$(get_current_strategy)"
            printf " QUIC стратегия: #%s\n" "$(get_current_quic_strategy)"
        fi

        cat <<'MENU'

[1] Установить/Переустановить zapret2
[2] Выбрать стратегию по номеру
[3] Автотест стратегий
[4] Управление сервисом
[5] Просмотр текущих стратегий
[6] Обновить списки доменов
[7] Настройка Discord
[8] Резервная копия/Восстановление
[9] Удалить zapret2
[A] Режим ALL TCP-443 (без хостлистов)
[C] Конструктор circular (автоперебор)
[Q] Настройки QUIC
[W] Whitelist (исключения)
[0] Выход

MENU

        printf "Выберите опцию [0-9,A,C,Q,W]: "

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
            c|C)
                menu_circular_builder
                ;;
            q|Q)
                menu_quic_settings
                ;;
            w|W)
                menu_whitelist
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
    print_header "[2] Выбор стратегии"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        print_info "Сначала выполните установку (опция 1)"
        pause
        return
    fi

    local total_count
    total_count=$(get_strategies_count)
    local current_tcp
    current_tcp=$(get_current_strategy)

    print_info "Всего TCP стратегий: $total_count"
    printf "  Текущая TCP: #%s\n" "$current_tcp"
    printf "  Текущая QUIC: #%s\n" "$(get_current_quic_strategy)"
    print_separator

    cat <<'SUBMENU'

[1] Выбрать TCP стратегию (для всех доменов)
[2] Выбрать QUIC стратегию (YouTube UDP)
[3] Применить autocircular (рекомендуется)
[B] Назад

SUBMENU
    printf "Ваш выбор: "
    read_input category_choice

    case "$category_choice" in
        1)
            # TCP стратегия
            menu_select_single_strategy "TCP" "$current_tcp" "$total_count"
            if [ $? -eq 0 ] && [ -n "$SELECTED_STRATEGY" ]; then
                local new_strategy="$SELECTED_STRATEGY"
                print_separator
                print_info "Применяю стратегию #$new_strategy..."
                apply_strategy_simple "$new_strategy"
                print_separator
                test_category_availability "TCP" "youtube.com"
                print_separator

                printf "Оставить эту стратегию? [Y/n]: "
                read_input apply_confirm
                case "$apply_confirm" in
                    [Nn]|[Nn][Oo])
                        print_info "Откатываю к стратегии #$current_tcp..."
                        apply_strategy_simple "$current_tcp"
                        print_success "Откат выполнен"
                        ;;
                    *)
                        print_success "Стратегия #$new_strategy применена"
                        ;;
                esac
            fi
            pause
            return
            ;;
        2)
            # QUIC
            menu_select_quic_strategy
            return
            ;;
        3)
            # Autocircular
            apply_autocircular_strategies
            pause
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
        print_info "Рекомендация: запустите автотест [3] для поиска рабочей стратегии"
    fi
}

# Глобальная переменная для передачи выбранной стратегии
SELECTED_STRATEGY=""

# Вспомогательная функция: выбор стратегии для одной категории
menu_select_single_strategy() {
    local category_name=$1
    local current_strategy=$2
    local total_count=$3

    # Сброс глобальной переменной
    SELECTED_STRATEGY=""

    printf "\n"
    print_info "Выбор стратегии для: $category_name"
    printf "Текущая стратегия: #%s\n\n" "$current_strategy"

    while true; do
        printf "Введите номер стратегии [1-%s] или Enter для отмены: " "$total_count"
        read_input new_strategy

        # Отмена
        if [ -z "$new_strategy" ]; then
            print_info "Отменено"
            return 1
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

        # Сохраняем в глобальную переменную
        SELECTED_STRATEGY="$new_strategy"
        return 0
    done
}

# Вспомогательная функция: выбор стратегии QUIC (UDP 443)
menu_select_quic_strategy() {
    clear_screen
    print_header "QUIC стратегия (UDP 443)"

    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    local total_quic
    total_quic=$(get_quic_strategies_count)
    if [ "$total_quic" -lt 1 ]; then
        print_error "QUIC стратегии не найдены"
        pause
        return
    fi

    local current_quic
    current_quic=$(get_current_quic_strategy)

    printf "\n"
    print_info "Всего QUIC стратегий: $total_quic"
    printf "Текущая YouTube QUIC стратегия: #%s\n\n" "$current_quic"

    printf "Введите номер QUIC стратегии [1-%s] или Enter для отмены: " "$total_quic"
    read_input new_strategy

    if [ -z "$new_strategy" ]; then
        print_info "Отменено"
        pause
        return
    fi

    if ! echo "$new_strategy" | grep -qE '^[0-9]+$'; then
        print_error "Неверный формат номера"
        pause
        return
    fi

    if [ "$new_strategy" -lt 1 ] || [ "$new_strategy" -gt "$total_quic" ]; then
        print_error "Номер вне диапазона"
        pause
        return
    fi

    if ! quic_strategy_exists "$new_strategy"; then
        print_error "QUIC стратегия #$new_strategy не найдена"
        pause
        return
    fi

    local name
    local desc
    local params
    name=$(get_quic_strategy_name "$new_strategy")
    desc=$(get_quic_strategy_desc "$new_strategy")
    params=$(get_quic_strategy "$new_strategy")

    print_info "Выбрана QUIC стратегия #$new_strategy (${name})"
    [ -n "$desc" ] && printf "  %s\n" "$desc"
    printf "  %s\n\n" "$params"

    printf "Применить эту QUIC стратегию? [Y/n]: "
    read_input apply_confirm
    case "$apply_confirm" in
        [Nn]|[Nn][Oo])
            print_info "Отменено"
            ;;
        *)
            set_current_quic_strategy "$new_strategy"
            # Обновить config и перезапустить
            . "${LIB_DIR}/config_official.sh"
            update_nfqws2_opt_in_config "${ZAPRET2_DIR}/config"
            local init_script="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
            [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1
            print_success "QUIC стратегия применена"
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

    local total_count
    total_count=$(get_strategies_count)
    if [ "$total_count" -lt 1 ]; then
        total_count="?"
    fi

    printf "Режимы тестирования:\n\n"
    printf "[1] Быстрый тест (топ стратегий, ~2-3 мин)\n"
    printf "[2] Диапазон (укажите вручную)\n"
    printf "[3] Все стратегии (только HTTPS, %s шт, ~15 мин)\n" "$total_count"
    printf "[4] QUIC тест (UDP 443, ~5-10 мин)\n"
    printf "[B] Назад\n\n"

    printf "Выберите режим: "
    read_input test_mode

    case "$test_mode" in
        1)
            clear_screen
            auto_test_top20
            ;;
        2)
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
        3)
            clear_screen
            print_warning "Это займет около 15 минут!"
            if confirm "Продолжить?" "N"; then
                local total_count
                total_count=$(get_strategies_count)
                if [ "$total_count" -lt 1 ]; then
                    print_error "Стратегии не найдены"
                    pause
                    return
                fi
                test_strategy_range 1 "$total_count"
            fi
            ;;
        4)
            clear_screen
            auto_test_quic
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
[5] Состояние circular (SIGUSR2)
[6] Conntrack пул (SIGUSR1)
[7] Логи nfqws2
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
        5)
            show_circular_state
            ;;
        6)
            show_conntrack_pool
            ;;
        7)
            show_nfqws2_logs
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

    local current
    current=$(get_current_strategy)

    if [ "$current" = "не задана" ] || [ -z "$current" ]; then
        print_warning "TCP стратегия не выбрана"
        print_info "Используется стратегия по умолчанию"
    else
        print_info "TCP стратегия: #$current"
        print_separator

        local params
        params=$(get_strategy "$current")
        local type
        type=$(get_strategy_type "$current")

        printf "Тип: %s\n\n" "$type"
        printf "Параметры:\n%s\n" "$params"
        print_separator
    fi

    # QUIC стратегия
    local current_quic
    current_quic=$(get_current_quic_strategy)
    if [ -n "$current_quic" ] && [ "$current_quic" != "не задана" ]; then
        local quic_name quic_params
        quic_name=$(get_quic_strategy_name "$current_quic" 2>/dev/null)
        quic_params=$(get_quic_strategy "$current_quic" 2>/dev/null)
        printf "\nQUIC стратегия: #%s (%s)\n" "$current_quic" "$quic_name"
        printf "Параметры:\n%s\n" "$quic_params"
        print_separator
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
    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    while true; do
        clear_screen
        print_header "[6] Управление списками доменов"

        # Показать текущие списки
        show_domain_lists_stats

        cat <<'SUBMENU'

[1] Обновить списки (скачать Re:filter)
[2] Просмотреть пользовательские домены
[3] Добавить домен
[4] Удалить домен
[5] Пересоздать seed-списки
[B] Назад

SUBMENU
        printf "Выберите опцию [1-5,B]: "
        read_input sub_choice

        case "$sub_choice" in
            1)
                print_info "Загрузка списков доменов..."
                run_getlist
                print_separator
                show_domain_lists_stats
                pause
                ;;
            2)
                show_custom_domains
                pause
                ;;
            3)
                printf "Введите домен (например: example.com): "
                read_input new_domain
                if [ -n "$new_domain" ]; then
                    add_custom_domain "$new_domain"
                else
                    print_info "Отменено"
                fi
                pause
                ;;
            4)
                printf "Введите домен для удаления: "
                read_input del_domain
                if [ -n "$del_domain" ]; then
                    remove_custom_domain "$del_domain"
                else
                    print_info "Отменено"
                fi
                pause
                ;;
            5)
                print_warning "Это пересоздаст seed-списки (пользовательские домены сохранятся)"
                printf "Продолжить? [y/N]: "
                read_input confirm
                case "$confirm" in
                    [Yy])
                        seed_standard_lists
                        print_success "Seed-списки пересозданы"
                        ;;
                    *)
                        print_info "Отменено"
                        ;;
                esac
                pause
                ;;
            b|B)
                return
                ;;
            *)
                print_error "Неверный выбор: $sub_choice"
                pause
                ;;
        esac
    done
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

    local whitelist_file="${HOSTS_USER_EXCLUDE:-${IPSET_DIR}/zapret-hosts-user-exclude.txt}"

    # Проверить существование файла
    if [ ! -f "$whitelist_file" ]; then
        print_warning "Файл whitelist не найден: $whitelist_file"
        print_info "Создаю файл..."

        # Создать директорию если не существует
        if ! mkdir -p "$(dirname "$whitelist_file")" 2>/dev/null; then
            print_error "Не удалось создать директорию: $(dirname "$whitelist_file")"
            print_info "Проверьте права доступа"
            pause
            return 1
        fi

        # Создать базовый whitelist
        cat > "$whitelist_file" <<'EOF'
# Whitelist - домены исключенные из обработки zapret2
# Критичные государственные сервисы РФ

# Госуслуги (ЕСИА)
gosuslugi.ru
esia.gosuslugi.ru
lk.gosuslugi.ru

# Налоговая служба
nalog.gov.ru
lkfl2.nalog.ru

# Пенсионный фонд
pfr.gov.ru
es.pfr.gov.ru

# Другие важные госсервисы
mos.ru
pgu.mos.ru
EOF

        if [ ! -f "$whitelist_file" ]; then
            print_error "Не удалось создать файл whitelist"
            print_info "Проверьте права доступа"
            pause
            return 1
        fi

        print_success "Файл whitelist создан: $whitelist_file"
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

            # Удалить домен (экранируем точки для sed regex)
            local escaped_domain
            escaped_domain=$(printf '%s' "$del_domain" | sed 's/\./\\./g')
            sed -i "/^${escaped_domain}$/d" "$whitelist_file"
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

    # Обновить config и перезапустить
    . "${LIB_DIR}/config_official.sh"
    update_nfqws2_opt_in_config "${ZAPRET2_DIR}/config"
    local init_script="${Z2K_INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
    [ -f "$init_script" ] && "$init_script" restart >/dev/null 2>&1
    print_success "YouTube QUIC стратегия #$new_strategy применена"
    pause
}


# ==============================================================================
# ПОДМЕНЮ: КОНСТРУКТОР CIRCULAR
# ==============================================================================

menu_circular_builder() {
    if ! is_zapret2_installed; then
        print_error "zapret2 не установлен"
        pause
        return
    fi

    while true; do
        clear_screen
        print_header "[C] Конструктор circular (автоперебор стратегий)"

        cat <<'SUBMENU'

Circular оркестратор автоматически перебирает стратегии
при сбоях соединения (DPI-блокировке).

[1] Собрать circular вручную (выбор стратегий)
[2] Автосборка (тест + выбор рабочих)
[3] Параметры TCP circular (fails/time)
[4] Параметры QUIC circular (udp_in/udp_out)
[5] Вернуть стандартный autocircular
[6] Показать текущий circular
[B] Назад

SUBMENU
        printf "Ваш выбор: "
        read_input choice

        case "$choice" in
            1)
                menu_circular_pick_strategies
                ;;
            2)
                menu_circular_auto_build
                ;;
            3)
                menu_circular_params "tcp"
                ;;
            4)
                menu_circular_params "quic"
                ;;
            5)
                menu_circular_restore_default
                ;;
            6)
                menu_circular_show
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

# Выбор стратегий вручную для circular
menu_circular_pick_strategies() {
    clear_screen
    print_header "Сборка circular из стратегий"

    # Выбор типа: TCP или QUIC
    printf "\nТип стратегий:\n"
    printf "[1] TCP стратегии\n"
    printf "[2] QUIC стратегии\n"
    printf "[B] Назад\n\n"
    printf "Ваш выбор: "
    read_input type_choice

    case "$type_choice" in
        1) _menu_circular_pick_tcp ;;
        2) _menu_circular_pick_quic ;;
        [Bb]) return ;;
        *) print_error "Неверный выбор"; pause ;;
    esac
}

_menu_circular_pick_tcp() {
    local total_count
    total_count=$(get_strategies_count)
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    print_separator
    print_info "Доступные TCP стратегии (всего: $total_count):"
    printf "\n"

    # Показать стратегии постранично по 20
    local page=1 per_page=20 shown=0
    while IFS='|' read -r num type params name; do
        [ -z "$num" ] && continue
        shown=$((shown + 1))
        if [ $shown -gt $(( (page - 1) * per_page )) ] && [ $shown -le $((page * per_page)) ]; then
            local short_params
            short_params=$(printf "%s" "$params" | cut -c1-60)
            if [ -n "$name" ]; then
                printf "  #%-3s [%s] %s\n" "$num" "$name" "$short_params"
            else
                printf "  #%-3s %s\n" "$num" "$short_params"
            fi
        fi
    done < "$conf"

    if [ $total_count -gt $per_page ]; then
        printf "\n  (показаны 1-%s из %s, введите 'n' для следующей страницы)\n" "$per_page" "$total_count"
    fi

    # Ввод диапазона
    printf "\nВведите номера стратегий через запятую или диапазон\n"
    printf "Примеры: 1,3,5  или  1-10  или  1,3,5-10,15\n"
    printf "Или Enter для отмены: "
    read_input range_input

    [ -z "$range_input" ] && { print_info "Отменено"; pause; return; }

    local nums
    nums=$(parse_strategy_range "$range_input")
    if [ -z "$nums" ]; then
        print_error "Неверный формат диапазона: $range_input"
        pause
        return
    fi

    local count=0
    for _ in $nums; do count=$((count + 1)); done
    if [ "$count" -lt 2 ]; then
        print_error "Для circular нужно минимум 2 стратегии"
        pause
        return
    fi

    print_info "Выбрано стратегий: $count ($nums)"
    printf "\nПрименить TCP circular? [Y/n]: "
    read_input confirm
    case "$confirm" in
        [Nn]) print_info "Отменено" ;;
        *)
            apply_custom_circular "TCP" "$nums"
            print_success "TCP circular применён ($count стратегий)"
            ;;
    esac
    pause
}

_menu_circular_pick_quic() {
    local total_quic
    total_quic=$(get_quic_strategies_count)
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    print_separator
    print_info "Доступные QUIC стратегии (всего: $total_quic):"
    printf "\n"

    while IFS='|' read -r num name args desc; do
        [ -z "$num" ] && continue
        printf "  #%-3s [%s] %s\n" "$num" "$name" "${desc:-$args}" | cut -c1-78
    done < "$conf"

    printf "\nВведите номера стратегий (пример: 1,3,5-10) или Enter для отмены: "
    read_input range_input

    [ -z "$range_input" ] && { print_info "Отменено"; pause; return; }

    local nums
    nums=$(parse_strategy_range "$range_input")
    if [ -z "$nums" ]; then
        print_error "Неверный формат диапазона: $range_input"
        pause
        return
    fi

    local count=0
    for _ in $nums; do count=$((count + 1)); done
    if [ "$count" -lt 2 ]; then
        print_error "Для circular нужно минимум 2 стратегии"
        pause
        return
    fi

    print_info "Выбрано QUIC стратегий: $count ($nums)"
    printf "\nПрименить QUIC circular? [Y/n]: "
    read_input confirm
    case "$confirm" in
        [Nn]) print_info "Отменено" ;;
        *)
            apply_custom_quic_circular "$nums"
            print_success "QUIC circular применён ($count стратегий)"
            ;;
    esac
    pause
}

# Автосборка circular из результатов тестирования
menu_circular_auto_build() {
    clear_screen
    print_header "Автосборка circular (тест стратегий)"

    local category="TCP"

    local total_count
    total_count=$(get_strategies_count)

    printf "\nДиапазон стратегий для тестирования [1-%s]\n" "$total_count"
    printf "Формат: 1-12 или 1,3,5-10 (по умолчанию: 1-12): "
    read_input range_input
    [ -z "$range_input" ] && range_input="1-12"

    printf "\nМинимальная оценка для включения (1-5, по умолчанию 3): "
    read_input min_score
    [ -z "$min_score" ] && min_score=3

    print_separator
    print_warning "Автосборка займёт время. Каждая стратегия тестируется ~5 сек."
    printf "Начать? [Y/n]: "
    read_input confirm
    case "$confirm" in
        [Nn]) print_info "Отменено"; pause; return ;;
    esac

    auto_build_circular "$category" "$range_input" "$min_score"
    pause
}

# Настройка параметров circular
menu_circular_params() {
    local mode=$1  # "tcp" или "quic"
    clear_screen

    load_circular_params

    if [ "$mode" = "quic" ]; then
        print_header "Параметры QUIC circular"
        printf "\nТекущие параметры:\n"
        printf "  fails   = %s  (сбоев до переключения)\n" "${CIRCULAR_FAILS:-2}"
        printf "  time    = %s  (окно времени, сек)\n" "${CIRCULAR_TIME:-60}"
        printf "  udp_in  = %s  (входящих пакетов до анализа)\n" "${CIRCULAR_UDP_IN:-1}"
        printf "  udp_out = %s  (исходящих пакетов до анализа)\n" "${CIRCULAR_UDP_OUT:-4}"
    else
        print_header "Параметры TCP circular"
        printf "\nТекущие параметры:\n"
        printf "  fails = %s  (сбоев до переключения стратегии)\n" "${CIRCULAR_FAILS:-2}"
        printf "  time  = %s  (окно времени в секундах)\n" "${CIRCULAR_TIME:-60}"
    fi

    print_separator
    printf "\nВведите новое значение fails (Enter = оставить %s): " "${CIRCULAR_FAILS:-2}"
    read_input new_fails
    [ -n "$new_fails" ] && CIRCULAR_FAILS="$new_fails"

    printf "Введите новое значение time (Enter = оставить %s): " "${CIRCULAR_TIME:-60}"
    read_input new_time
    [ -n "$new_time" ] && CIRCULAR_TIME="$new_time"

    if [ "$mode" = "quic" ]; then
        printf "Введите новое значение udp_in (Enter = оставить %s): " "${CIRCULAR_UDP_IN:-1}"
        read_input new_udp_in
        [ -n "$new_udp_in" ] && CIRCULAR_UDP_IN="$new_udp_in"

        printf "Введите новое значение udp_out (Enter = оставить %s): " "${CIRCULAR_UDP_OUT:-4}"
        read_input new_udp_out
        [ -n "$new_udp_out" ] && CIRCULAR_UDP_OUT="$new_udp_out"
    fi

    save_circular_params
    print_success "Параметры circular сохранены"
    printf "\nПримечание: параметры будут использованы при следующей сборке circular.\n"
    printf "Для применения пересоберите circular (опции 1 или 2).\n"
    pause
}

# Восстановить стандартный autocircular
menu_circular_restore_default() {
    clear_screen
    print_header "Восстановление стандартного autocircular"

    printf "\nЭто заменит текущие circular стратегии на стандартные\n"
    printf "autocircular из strats_new2.txt / quic_strats.ini.\n\n"
    printf "Продолжить? [Y/n]: "
    read_input confirm
    case "$confirm" in
        [Nn]) print_info "Отменено"; pause; return ;;
    esac

    apply_autocircular_strategies
    print_success "Стандартный autocircular восстановлен"
    pause
}

# Показать текущее состояние circular
menu_circular_show() {
    clear_screen
    show_circular_info
    pause
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
