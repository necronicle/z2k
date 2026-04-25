#!/bin/sh
# lib/menu.sh - Интерактивное меню управления z2k
# 9 опций для полного управления zapret2
# shellcheck disable=SC2154  # Variables assigned via read_input function

# ==============================================================================
# ВСПОМОГАТЕЛЬНАЯ ФУНКЦИЯ ДЛЯ ЧТЕНИЯ ВВОДА
# ==============================================================================

# Читать ввод пользователя (работает даже когда stdin перенаправлен через pipe)
# Очищает мусор от backspace/смены раскладки — оставляет последний введённый символ
read_input() {
    local _z2k_var="$1"
    local _z2k_raw=""
    read -r _z2k_raw </dev/tty
    # Удалить \r, backspace (\b), DEL (\177), а также любые не-ASCII байты (мусор от раскладки)
    _z2k_raw=$(printf '%s' "$_z2k_raw" | tr -d "$(printf '\r\b\177')" | LC_ALL=C sed 's/[^[:print:]]//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
    eval "${_z2k_var}=\${_z2k_raw}"
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
+---------------------------------------------------+
|  Огромная благодарность спонсорам проекта:        |
|  - SupWgeneral                                    |
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
                local ENABLED
                ENABLED=$(safe_config_read "ENABLED" "$all_tcp443_conf" "0")
                if [ "$ENABLED" = "1" ]; then
                    printf " Режим Austerusj: Включен (без хостлистов)\n"
                fi
            fi

            # Показать статус RST-фильтра
            local rst_config_file="${ZAPRET2_DIR}/config"
            if [ -f "$rst_config_file" ]; then
                local DROP_DPI_RST
                DROP_DPI_RST=$(safe_config_read "DROP_DPI_RST" "$rst_config_file" "0")
                if [ "$DROP_DPI_RST" = "1" ]; then
                    printf " RST-фильтр: Включен (пассивный DPI)\n"
                fi
            fi

            # Показать статус веб-панели (если функция загружена)
            if command -v webpanel_is_installed >/dev/null 2>&1 && webpanel_is_installed; then
                if webpanel_is_running; then
                    printf " Веб-панель: работает (%s)\n" "$(webpanel_url)"
                else
                    printf " Веб-панель: установлена, остановлена\n"
                fi
            fi
        fi

        cat <<'MENU'

[1] Установить/Переустановить zapret2
[2] Управление сервисом
[3] Обновить списки доменов
[4] Резервная копия/Восстановление
[5] Удалить zapret2
[W] Whitelist (исключения)
[R] RST-фильтр (пассивный DPI)
[G] Игровой режим (safe/hybrid/aggressive)
[T] Telegram прокси
[S] Скрипты custom.d
[P] Веб-панель (дубль меню в браузере)
[D] Диагностика (сводка для траблшутинга)
[X] Active probe (подбор стратегии под конкретный домен)
[C] Classify (определить тип DPI-блока + найти стратегию, ~5-30с)
[I] Убрать статические IP Instagram (обход DNS-отравления)
[0] Выход

MENU

        printf "Выберите опцию [0-5,R,G,T,W,S,P,D,X,C,I]: "
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
            r|R)
                menu_rst_filter
                ;;
            g|G)
                menu_roblox_bypass
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
            p|P)
                menu_webpanel
                ;;
            d|D)
                menu_diag
                ;;
            x|X)
                menu_probe
                ;;
            c|C)
                menu_classify
                ;;
            i|I)
                menu_instagram_dns_clear
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

menu_diag() {
    clear_screen
    print_header "[D] Диагностика"

    local diag="${ZAPRET2_DIR}/z2k-diag.sh"

    if [ ! -f "$diag" ]; then
        print_error "Скрипт диагностики не найден: $diag"
        print_info "Переустановите z2k или обновите tools"
        pause
        return
    fi

    sh "$diag"
    printf "\n"
    print_info "Сводка готова. Скопируй вывод выше и пришли в чат проекта при необходимости."
    pause
}

menu_probe() {
    clear_screen
    print_header "[X] Active probe — подбор стратегии под конкретный домен"

    local probe="${ZAPRET2_DIR}/z2k-probe.sh"
    if [ ! -f "$probe" ]; then
        print_error "Скрипт active probe не найден: $probe"
        print_info "Переустановите z2k или обновите tools"
        pause
        return
    fi

    print_info "Прогоняет все стратегии из rkn_tcp через целевой домен,"
    print_info "пинит каждую в state.tsv и меряет throughput на 100 KB curl."
    print_info "Основной сервис не останавливается — только один домен"
    print_info "временно использует конкретную стратегию на время итерации."
    print_separator
    printf "Домен для probe (например www.cloudflare.com): "
    read_input probe_host
    if [ -z "$probe_host" ]; then
        print_warning "Пустой домен, отмена"
        pause
        return
    fi

    printf "Автоматически применить лучшую стратегию в state.tsv? [y/N]: "
    read_input apply_ans
    local apply_flag=""
    case "$apply_ans" in
        y|Y|yes|YES) apply_flag="--apply" ;;
    esac

    print_info "Запуск probe (займёт ~2-3 минуты)..."
    print_separator
    sh "$probe" "$probe_host" $apply_flag
    print_separator
    print_info "Probe завершён. Если --apply был выбран — лучшая стратегия"
    print_info "теперь пинится в state.tsv для $probe_host."
    pause
}

menu_classify() {
    clear_screen
    print_header "[C] Classify — определить тип DPI-блока для домена"

    local classify="${ZAPRET2_DIR}/z2k-classify"
    if [ ! -x "$classify" ]; then
        print_error "z2k-classify не установлен: $classify"
        print_info "Возможно rolling release ещё не создан в репо или install"
        print_info "не докачал бинарь. Попробуйте переустановить z2k."
        pause
        return
    fi

    print_info "Быстрая (~5-30 сек) альтернатива active probe:"
    print_info "  1. Делает 8-симптомную диагностику домена"
    print_info "  2. Классифицирует тип блока (rkn_rst / tspu_16kb / aws_no_ts / ...)"
    print_info "  3. С --apply прогоняет шаблон стратегий ТОЛЬКО подходящих"
    print_info "     для этого типа блока (5-9 вместо 47 в active probe)"
    print_info "  4. Пинит победителя в state.tsv"
    print_separator
    printf "Домен для classify (например linkedin.com): "
    read_input cls_host
    if [ -z "$cls_host" ]; then
        print_warning "Пустой домен, отмена"
        pause
        return
    fi

    printf "Автоматически найти и пинить рабочую стратегию (--apply)? [Y/n]: "
    read_input cls_apply_ans
    local cls_apply_flag="--apply"
    case "$cls_apply_ans" in
        n|N|no|NO) cls_apply_flag="" ;;
    esac

    print_separator
    "$classify" "$cls_host" $cls_apply_flag
    print_separator
    pause
}

# ==============================================================================
# ПОДМЕНЮ: INSTAGRAM DNS CLEAR
# ==============================================================================
#
# Снять статические записи `ip host` для Instagram / cdninstagram, которые
# install.sh прошивает в Keenetic как быстрый обход провайдерского DNS-
# отравления. Записи через месяц-другой протухают (Meta ротирует IP), и
# тогда ручная очистка — единственный простой способ снять костыль,
# чтобы трафик пошёл по обычному DNS + z2k DPI-bypass.
menu_instagram_dns_clear() {
    clear_screen
    print_header "[I] Убрать статические IP Instagram"

    if ! command -v ndmc >/dev/null 2>&1; then
        print_error "ndmc не найден — это не Keenetic, функция не применима"
        pause
        return
    fi

    # Собрать текущие записи. Формат вывода show running-config:
    #   ip host <domain> <ipv4>
    local ig_entries
    ig_entries=$(ndmc -c "show running-config" 2>/dev/null \
        | awk '/^ip host/ && ($3 ~ /(^|\.)instagram\.com$/ || $3 ~ /(^|\.)cdninstagram\.com$/) {print}')

    if [ -z "$ig_entries" ]; then
        print_info "Записей ip host для instagram / cdninstagram нет."
        print_info "Чистить нечего."
        pause
        return
    fi

    local count
    count=$(printf '%s\n' "$ig_entries" | wc -l | tr -d ' ')

    print_separator
    print_info "Найдено записей: $count"
    print_separator
    printf '%s\n' "$ig_entries"
    print_separator
    print_warning "Эти записи были прошиты при установке z2k как обход"
    print_warning "DNS-отравления. После удаления резолв пойдёт через"
    print_warning "провайдерский DNS (или через DoH, если настроен)."
    print_warning "Если у провайдера активный DNS-блок Instagram — без"
    print_warning "этих записей и без DoH инста открываться не будет."
    echo

    if ! confirm "Удалить все $count записей?" "N"; then
        print_info "Отмена"
        pause
        return
    fi

    local removed=0 failed=0
    # Пройти построчно. Каждая строка = "ip host <domain> <ip>".
    # В ndmc удаление — "no ip host <domain> <ip>" с теми же аргументами.
    local IFS_orig="$IFS"
    IFS='
'
    for line in $ig_entries; do
        IFS="$IFS_orig"
        if ndmc -c "no $line" >/dev/null 2>&1; then
            removed=$((removed + 1))
            print_info "  removed: $line"
        else
            failed=$((failed + 1))
            print_warning "  FAIL:    $line"
        fi
        IFS='
'
    done
    IFS="$IFS_orig"

    if [ "$removed" -gt 0 ]; then
        if ndmc -c "system configuration save" >/dev/null 2>&1; then
            print_success "Удалено: $removed (конфиг сохранён)"
        else
            print_warning "Удалено: $removed, но save конфига не прошёл"
            print_warning "Запусти вручную: ndmc -c \"system configuration save\""
        fi
    fi
    if [ "$failed" -gt 0 ]; then
        print_warning "Не удалось удалить: $failed"
    fi

    pause
}

# NOTE: menu_geosite() was removed in Phase 12. Geosite lists are
# now pulled unconditionally from runetfreedom/russia-blocked-geosite
# at install time and via cron (z2k-update-lists.sh → z2k-geosite.sh
# fetch). No user toggle — always on. Manual override for power users
# is env var Z2K_GEOSITE_RKN_RAM_THRESHOLD_MB when running the script.

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
    print_info "Поиск рабочей стратегии для HTTP DPI redirect"
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

    local DROP_DPI_RST
    DROP_DPI_RST=$(safe_config_read "DROP_DPI_RST" "$config_file" "0")

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
дополнительные демоны nfqws2 для Discord voice/video.

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

# ==============================================================================
# ПОДМЕНЮ: ИГРОВОЙ РЕЖИМ
# ==============================================================================

menu_roblox_bypass() {
    clear_screen
    print_header "Игровой режим"

    local config_file="${ZAPRET2_DIR}/config"

    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local ROBLOX_UDP_BYPASS GAME_MODE_STYLE_CUR
    ROBLOX_UDP_BYPASS=$(safe_config_read "ROBLOX_UDP_BYPASS" "$config_file" "0")
    GAME_MODE_STYLE_CUR=$(safe_config_read "GAME_MODE_STYLE" "$config_file" "safe")
    case "$GAME_MODE_STYLE_CUR" in
        safe|hybrid|aggressive) ;;
        *) GAME_MODE_STYLE_CUR="safe" ;;
    esac

    local status_line
    if [ "$ROBLOX_UDP_BYPASS" = "1" ]; then
        status_line="Включен — режим: $GAME_MODE_STYLE_CUR"
    else
        status_line="Выключен"
    fi

    print_separator
    print_info "Статус: $status_line"
    print_separator

    cat <<'SUBMENU'

UDP+TCP игровой bypass. Три режима:

  safe       — позитивный ipset (game_ips.txt) + автоциркуляр
               (6 стратегий). Работает только на указанных в списке
               IP, шум Discord/Steam ротатор не трогает.
               Рекомендуется всем, кому нужны только игры из списка.

  hybrid     — safe + catchall UDP 1024-65535 одной фиксированной
               стратегией (fake + autottl=4, cutoff=n4, repeats=8).
               Подхватывает игровые UDP-потоки на IP ВНЕ списка
               (облачные игры без SNI, сессии на произвольных портах).
               ⚠ Может ломать UDP-трафик на высоких портах:
                 • Discord peer-to-peer голос/видео (в настройках
                   Discord выключить "Use peer-to-peer" — чинит).
                 • WebRTC-звонки в браузере (Meet/Zoom/Teams) в P2P.
                 • BitTorrent DHT/uTP.
               Серверный Discord voice (порты 50000-50099 и т.д.)
               не затрагивается — его ловит отдельный профиль раньше.
               TCP не трогается — web-морды/обычный HTTPS безопасны.

  aggressive — только UDP catchall, без ipset-профиля. Максимум
               покрытия, но игры из game_ips.txt теряют персональный
               ротатор и идут по общей стратегии вместе со всем
               остальным. Те же UDP-риски, что и у hybrid.

[1] Safe (только из списка)
[2] Hybrid (список + облачные)
[3] Aggressive (только catchall)
[0] Выключить
[B] Назад

SUBMENU

    printf "Выберите опцию [0-3,B]: "
    read_input sub_choice

    _set_game_style() {
        local new_style="$1"
        if grep -q '^GAME_MODE_ENABLED=' "$config_file"; then
            sed -i 's/^GAME_MODE_ENABLED=.*/GAME_MODE_ENABLED=1/' "$config_file"
        else
            echo "GAME_MODE_ENABLED=1" >> "$config_file"
        fi
        if grep -q '^ROBLOX_UDP_BYPASS=' "$config_file"; then
            sed -i 's/^ROBLOX_UDP_BYPASS=.*/ROBLOX_UDP_BYPASS=1/' "$config_file"
        else
            echo "ROBLOX_UDP_BYPASS=1" >> "$config_file"
        fi
        if grep -q '^GAME_MODE_STYLE=' "$config_file"; then
            sed -i "s/^GAME_MODE_STYLE=.*/GAME_MODE_STYLE=${new_style}/" "$config_file"
        else
            echo "GAME_MODE_STYLE=${new_style}" >> "$config_file"
        fi
        # Port lists are fully regenerated by create_official_config below
        # (NFQWS2_PORTS_TCP/UDP include 1024-65535 automatically based on
        # saved_GAME_MODE_STYLE), so no sed surgery on them here.
    }

    _disable_game_mode() {
        sed -i 's/^GAME_MODE_ENABLED=.*/GAME_MODE_ENABLED=0/' "$config_file"
        sed -i 's/^ROBLOX_UDP_BYPASS=.*/ROBLOX_UDP_BYPASS=0/' "$config_file"
        # Keep GAME_MODE_STYLE as-is so re-enabling remembers last choice.
    }

    local need_regen=0
    case "$sub_choice" in
        1)
            _set_game_style "safe"
            print_success "Игровой режим: safe"
            need_regen=1
            ;;
        2)
            _set_game_style "hybrid"
            print_success "Игровой режим: hybrid (+UDP catchall для облачных игр)"
            print_warning "Может задеть UDP на высоких портах: Discord P2P / WebRTC / BitTorrent"
            need_regen=1
            ;;
        3)
            _set_game_style "aggressive"
            print_warning "Игровой режим: aggressive (игры из списка теряют личный ротатор)"
            print_warning "Те же UDP-риски, что у hybrid (Discord P2P, WebRTC, BitTorrent)"
            need_regen=1
            ;;
        0)
            if [ "$ROBLOX_UDP_BYPASS" != "1" ]; then
                print_info "Игровой режим уже выключен"
                pause
                return 0
            fi
            _disable_game_mode
            print_success "Игровой режим выключен"
            need_regen=1
            ;;
        [Bb])
            return 0
            ;;

        *)
            print_error "Неверный выбор"
            pause
            return 0
            ;;
    esac

    if [ "$need_regen" = "1" ]; then
        print_info "Пересоздание конфига..."
        create_official_config "/opt/zapret2/config"

        if is_zapret2_running; then
            print_info "Перезапуск сервиса..."
            "$INIT_SCRIPT" restart
            print_success "Сервис перезапущен"
        else
            print_warning "Сервис не запущен. Запустите через [2] Управление сервисом"
        fi
        pause
    fi
}

# ==============================================================================
# ПОДМЕНЮ: TELEGRAM MTPROXY
# ==============================================================================

menu_telegram_mtproxy() {
    local MTPROXY_BIN="/opt/sbin/tg-mtproxy-client"

    while true; do
        clear_screen
        print_header "Telegram"

        local tunnel_running=false
        if pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
            tunnel_running=true
        fi

        print_separator
        printf " Статус: %s\n" "$($tunnel_running && echo 'Включен' || echo 'Выключен')"
        print_separator

        cat <<'SUBMENU'

Telegram для всех устройств в сети.
Настройка на устройствах не требуется.

[1] Включить
[2] Выключить
[B] Назад

SUBMENU

        printf "Выберите опцию [1-2,B]: "
        read_input sub_choice

        case "$sub_choice" in
            1)
                # Download binary if missing
                if ! [ -f "$MTPROXY_BIN" ]; then
                    print_info "Скачиваю бинарник..."
                    local tg_arch=""
                    local _hw_arch _tg_bin_arch
                    _hw_arch=$(get_arch 2>/dev/null || uname -m)
                    _tg_bin_arch=$(map_arch_to_bin_arch "$_hw_arch" 2>/dev/null || true)
                    case "$_tg_bin_arch" in
                        linux-arm64)  tg_arch="arm64" ;;
                        linux-arm)    tg_arch="arm" ;;
                        linux-mipsel)   tg_arch="mipsel" ;;
                        linux-mips64el) tg_arch="mips64el" ;;
                        linux-mips64)   tg_arch="mips" ;;
                        linux-mips)     tg_arch="mips" ;;
                        linux-x86_64) tg_arch="amd64" ;;
                        linux-x86)    tg_arch="x86" ;;
                        linux-riscv64) tg_arch="riscv64" ;;
                        linux-ppc)    tg_arch="ppc64" ;;
                    esac
                    if [ -n "$tg_arch" ]; then
                        local tg_bin="tg-mtproxy-client-linux-${tg_arch}"
                        local tg_url="${GITHUB_RAW}/mtproxy-client/builds/${tg_bin}"
                        rm -f "$MTPROXY_BIN"
                        z2k_fetch "$tg_url" "$MTPROXY_BIN"
                        local tg_size
                        tg_size=$(wc -c < "$MTPROXY_BIN" 2>/dev/null || echo 0)
                        if [ -f "$MTPROXY_BIN" ] && [ "$tg_size" -gt 500000 ] 2>/dev/null && head -c 4 "$MTPROXY_BIN" 2>/dev/null | grep -q "ELF"; then
                            chmod +x "$MTPROXY_BIN"
                            if "$MTPROXY_BIN" --help 2>/dev/null; [ $? -le 2 ]; then
                                print_success "Скачан и проверен ($tg_arch)"
                            else
                                rm -f "$MTPROXY_BIN"
                                print_error "Бинарник не запускается (неверная архитектура?)"
                                print_info "Проверьте: opkg print-architecture"
                                pause
                                continue
                            fi
                        else
                            rm -f "$MTPROXY_BIN"
                            print_error "Не удалось скачать бинарник (файл повреждён или CDN вернул ошибку)"
                            pause
                            continue
                        fi
                    else
                        print_error "Неизвестная архитектура: $(uname -m)"
                        pause
                        continue
                    fi
                fi

                # Stop any old processes
                killall tg-mtproxy-client 2>/dev/null || true
                sleep 1

                # Start tunnel
                "$MTPROXY_BIN" --listen=:1443 >> /tmp/tg-tunnel.log 2>&1 &
                sleep 2

                if pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
                    print_success "Tunnel запущен"
                    # Setup iptables
                    for cidr in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24; do
                        iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
                            iptables -t nat -A PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
                    done
                    print_success "Telegram работает для всех устройств"
                else
                    print_error "Не удалось запустить"
                    tail -5 /tmp/tg-tunnel.log 2>/dev/null
                    rm -f "$MTPROXY_BIN"
                    print_info "Бинарник удалён — нажмите [1] ещё раз для перескачивания"
                fi
                pause
                ;;

            2)
                # Stop tunnel + cleanup
                killall tg-mtproxy-client 2>/dev/null || true
                for cidr in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24; do
                    iptables -t nat -D PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || true
                done
                print_success "Telegram tunnel выключен"
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
при обработке (госуслуги, банки, и т.д.)

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
