#!/bin/sh
# lib/menu.sh - Интерактивное меню управления z2k
# 9 опций для полного управления zapret2
# shellcheck disable=SC2154  # Variables assigned via read_input function

# ==============================================================================
# ВСПОМОГАТЕЛЬНАЯ ФУНКЦИЯ ДЛЯ ЧТЕНИЯ ВВОДА
# ==============================================================================

# Читать ввод пользователя (работает даже когда stdin перенаправлен через pipe)
# Убирает управляющие байты, но НЕ трогает кириллицу — см. ниже.
read_input() {
    local _z2k_var="$1"
    local _z2k_raw=""
    read -r _z2k_raw </dev/tty
    # УБИРАЕМ ТОЛЬКО УПРАВЛЯЮЩИЕ БАЙТЫ, А НЕ ВСЁ НЕ-ASCII.
    #
    # Раньше здесь стоял `LC_ALL=C sed 's/[^[:print:]]//g'` с комментарием, что
    # так вычищается «мусор от смены раскладки». Под LC_ALL=C непечатным
    # считается любой байт со старшим битом, то есть ВСЯ кириллица целиком:
    # «Домашние устройства» превращалось в пустую строку, «дом-сеть» — в «-».
    #
    # Цена была не косметическая. В menu_policy_access ниже (правка имени
    # политики) специально снят фильтр [A-Za-z0-9_-], сохранены пробелы внутри
    # имени и сделан подсчёт длины в СИМВОЛАХ вместо байтов — всё ради того,
    # чтобы политика могла называться «Домашние устройства», как её называет сам
    # Keenetic и как её принимает вебпанель. Эта работа была мертва: read_input
    # стирал имя за две строки до неё, и человек видел «Имя политики сохранено:
    # (пусто)», а фильтр политики после этого молча переставал совпадать.
    #
    # Пункты меню разбираются через `case` с веткой `*)`, поэтому кириллица,
    # набранная по ошибке при неснятой раскладке, и так приводит к переспросу —
    # ровно к тому же, к чему приводило её вычищение в пустую строку. Ничего,
    # кроме управляющих байтов, вырезать не нужно.
    _z2k_raw=$(printf '%s' "$_z2k_raw" \
        | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
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
|  SupWgeneral, Alexey, Jet_sk_ya, Suharik39,       |
|  ZyaK<-, Алексей Стрельцов, Diman86RUS, Alex,     |
|  GRM, Dez, hoaxx, Mansurchick,                    |
|  Dkarloff - SEO отец, KIBERPANK, olmer2002,       |
|  TiaMax, Denis, Mega Man, TheGreatYogo,           |
|  logistik77                                       |
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
                # Без отсечения комментариев счётчик всегда врал: шапка файла
                # содержит "# Format: CATEGORY:STRATEGY_NUM" и "# Updated: <дата>",
                # обе с двоеточием, поэтому к трём реальным категориям молча
                # прибавлялось 2 и в меню светилось «5 категорий».
                count=$(grep -cE "^[^#]+:" "$CATEGORY_STRATEGIES_CONF" 2>/dev/null || echo 0)
                printf " Стратегии: %s категорий\n" "$count"
            else
                printf " Текущая стратегия: #%s\n" "$(get_current_strategy)"
            fi

            local rst_config_file="${ZAPRET2_DIR}/config"
            if [ -f "$rst_config_file" ]; then
                local Z2K_DYNAMIC_TTL
                Z2K_DYNAMIC_TTL=$(safe_config_read "Z2K_DYNAMIC_TTL" "$rst_config_file" "1")
                if [ "$Z2K_DYNAMIC_TTL" = "0" ]; then
                    printf " Динамический TTL: Выключен (мобильный оператор)\n"
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
[U] Проверить обновления z2k
[W] Исключения — домены
[E] Игровой режим WARP (Cloudflare-туннель для игр, заблоченных по IP)
[T] Telegram прокси
[S] Скрипты custom.d
[P] Веб-панель (дубль меню в браузере)
[D] Диагностика (сводка для траблшутинга)
[I] Статические IP Instagram — убрать / вернуть (обход DNS-отравления)
[Y] Diagnose domain (4-стадийная проба + рекомендация)
[M] Динамический TTL (для мобильных операторов)
[A] Политика доступа Keenetic (фильтр по NDM policy)
[C] Сбор статистики стратегий (анонимно)
[H] Аппаратный offload: per-flow исключение (нативная ротация на Keenetic)
[L] Автохостлист (движок сам находит заблокированные домены)
[0] Выход

MENU

        printf "Выберите опцию [0-5,U,R,F,E,T,W,S,P,D,I,Y,M,A,C,H,L]: "
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
            u|U)
                menu_check_updates
                ;;
            e|E)
                menu_game_warp
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
            i|I)
                menu_instagram_dns
                ;;
            y|Y)
                menu_diagnose_domain
                ;;
            m|M)
                menu_dynamic_ttl
                ;;
            a|A)
                menu_policy_access
                ;;
            c|C)
                menu_stats
                ;;
            h|H)
                menu_ppe
                ;;

            l|L)
                menu_autohostlist
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

menu_diagnose_domain() {
    clear_screen
    print_header "[Y] Diagnose domain / z2k-detect"

    local z2k_detect="/opt/sbin/z2k-detect"
    local cfg=/opt/zapret2/config
    local pidfile=/var/run/z2k-detect.pid

    if [ ! -x "$z2k_detect" ]; then
        print_error "z2k-detect не установлен: $z2k_detect"
        print_info "Переустановите z2k (опция [1])"
        pause
        return
    fi

    # Daemon status + Z2K_DISCOVER flag — operator's at-a-glance summary.
    local flag="1"
    if [ -f "$cfg" ]; then
        local _v
        _v=$(grep -E "^Z2K_DISCOVER=" "$cfg" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '" ')
        [ -n "$_v" ] && flag="$_v"
    fi
    local running="нет"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
        running="да (PID $(cat "$pidfile"))"
    fi
    printf "Автодетекция:   %s\n" "$flag"
    printf "Демон запущен:  %s\n" "$running"
    print_separator
    print_info "[D] Проверить домен"
    print_info "[T] Переключить автодетекцию (текущее: $flag)"
    print_info "[Enter] Выход"
    printf "> "
    local action
    read_input action

    case "$action" in
        t|T)
            local new_flag
            if [ "$flag" = "1" ]; then new_flag="0"; else new_flag="1"; fi
            touch "$cfg" 2>/dev/null
            set_flag Z2K_DISCOVER "$new_flag" "$cfg"
            print_success "Автодетекция: $new_flag"
            if [ -x /opt/etc/init.d/S98z2k-detect ]; then
                /opt/etc/init.d/S98z2k-detect restart >/dev/null 2>&1 || true
            fi
            pause
            return
            ;;
        d|D|"")
            ;;
        *)
            print_error "Неверный выбор"
            pause
            return
            ;;
    esac

    if [ -z "$action" ]; then return; fi

    print_info "Введите домен для проверки (например, vk.com):"
    printf "> "
    local domain
    read_input domain
    if [ -z "$domain" ]; then
        print_info "Пусто, выход"
        pause
        return
    fi

    # Sanitise: only DNS-safe chars allowed; пресекаем shell-injection
    # на случай если кто-то наберёт `; rm -rf /` в качестве домена.
    case "$domain" in
        *[!a-zA-Z0-9.-]*)
            print_error "Недопустимые символы в домене"
            pause
            return
            ;;
    esac

    print_separator
    "$z2k_detect" probe "$domain"
    print_separator
    # No --apply prompt — CLI pinning would race with daemon's in-memory
    # store (двойной writer на один TSV). Если по выводу видно HOT и юзер
    # хочет добавить вручную — есть webpanel «Доп. домены» или прямое
    # редактирование /opt/zapret2/lists/extra-domains.txt, путь без race'а.
    pause
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

# menu_probe() / menu_classify() removed in r-15 (Phase 1 cleanup of the
# detection stack). z2k-probe.sh + z2k-classify were
# never wired into the live circular pipeline — purely manual debug
# tools that produced non-actionable verdicts. Replaced by the new
# server_active_reject taxonomy in z2k-detectors.lua and (Phase 3) by
# the z2k-detect daemon doing live reactive discovery.

# ==============================================================================
# ПОДМЕНЮ: INSTAGRAM DNS (убрать / вернуть)
# ==============================================================================
#
# Статические записи `ip host` для Instagram / cdninstagram, которые install.sh
# прошивает в Keenetic как быстрый обход провайдерского DNS-отравления.
# Пункт двусторонний:
#   - записи ЕСТЬ  → предложить УБРАТЬ (Meta ротирует IP, костыль протухает —
#                    снять, чтобы трафик пошёл по обычному DNS + z2k DPI-bypass);
#   - записей НЕТ → предложить ВЕРНУТЬ (прошить базовый набор через общую
#                    z2k_instagram_dns_add_fallback из install.sh + подтянуть
#                    свежие IP через z2k-insta-ip-refresh.sh, если резолвер
#                    доступен). Возврат нужен, если убрали зря и инсту опять
#                    режет на DNS-уровне.
menu_instagram_dns() {
    clear_screen
    print_header "[I] Статические IP Instagram"

    if ! command -v ndmc >/dev/null 2>&1; then
        print_error "ndmc не найден — это не Keenetic, функция не применима"
        pause
        return
    fi

    # Собрать текущие записи. Формат вывода show running-config:
    #   ip host <domain> <ipv4>
    local ig_entries
    ig_entries=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
        | awk '/^ip host/ && ($3 ~ /(^|\.)instagram\.com$/ || $3 ~ /(^|\.)cdninstagram\.com$/) {print}')

    if [ -n "$ig_entries" ]; then
        # ---------- Записи ЕСТЬ → УБРАТЬ ----------
        local count
        count=$(printf '%s\n' "$ig_entries" | wc -l | tr -d ' ')

        print_separator
        print_info "Статические IP прошиты. Записей: $count"
        print_separator
        printf '%s\n' "$ig_entries"
        print_separator
        print_warning "Эти записи были прошиты как обход DNS-отравления."
        print_warning "После удаления резолв пойдёт через провайдерский DNS"
        print_warning "(или через DoH, если настроен). Если у провайдера активный"
        print_warning "DNS-блок Instagram — без этих записей и без DoH инста не откроется."
        echo

        if ! confirm "Убрать все $count записей?" "N"; then
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
            if LD_LIBRARY_PATH= ndmc -c "no $line" >/dev/null 2>&1; then
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
            # Решение юзера — в конфиг: обновление и рефреш записи не вернут (issue #39).
            set_flag "Z2K_INSTA_DNS" "0" "${ZAPRET2_DIR}/config" 2>/dev/null
            if LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1; then
                print_success "Убрано: $removed (конфиг сохранён; обновления их не вернут)"
            else
                print_warning "Убрано: $removed, но save конфига не прошёл"
                print_warning "Запусти вручную: LD_LIBRARY_PATH= ndmc -c \"system configuration save\""
            fi
        fi
        if [ "$failed" -gt 0 ]; then
            print_warning "Не удалось убрать: $failed"
        fi
    else
        # ---------- Записей НЕТ → ВЕРНУТЬ ----------
        print_info "Статических записей Instagram сейчас нет."
        print_warning "Если у провайдера активный DNS-блок Instagram и нет DoH —"
        print_warning "инста может не открываться. Возврат прошьёт базовый набор"
        print_warning "и подтянет свежие IP с резолвера (если доступен)."
        echo

        if ! confirm "Вернуть статические IP Instagram?" "N"; then
            print_info "Отмена"
            pause
            return
        fi

        print_info "Прошиваю базовый набор записей..."
        set_flag "Z2K_INSTA_DNS" "1" "${ZAPRET2_DIR}/config" 2>/dev/null
        # Общая функция из install.sh (один источник истины для 7 записей).
        if ! z2k_instagram_dns_add_fallback; then
            print_error "Не удалось прошить записи (ndmc недоступен)"
            pause
            return
        fi

        # Подтянуть свежие IP через live-резолв (best-effort; нужен доступ к VPS).
        # После прошивки записи есть → refresh-скрипт не сработает на «юзер очистил».
        if [ -f "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" ]; then
            print_info "Обновляю на свежие IP (live-резолв)..."
            sh "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" >/dev/null 2>&1 || true
        fi

        # Перечитать и показать итог.
        local now_entries now_count
        now_entries=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
            | awk '/^ip host/ && ($3 ~ /(^|\.)instagram\.com$/ || $3 ~ /(^|\.)cdninstagram\.com$/) {print}')
        if [ -n "$now_entries" ]; then
            now_count=$(printf '%s\n' "$now_entries" | wc -l | tr -d ' ')
            print_separator
            printf '%s\n' "$now_entries"
            print_separator
            print_success "Возвращено записей: $now_count (конфиг сохранён)"
        else
            print_warning "Записи не появились — проверь, что ndmc работает."
        fi
    fi

    pause
}

# NOTE: menu_geosite() was removed in Phase 12. Geosite lists are
# now pulled unconditionally from runetfreedom/russia-blocked-geosite
# at install time and via cron (z2k-update-lists.sh → z2k-geosite.sh
# fetch). No user toggle — always on. Manual override for power users
# is env var Z2K_GEOSITE_RKN_ASSET when running the script (по умолчанию
# берётся короткий ru-blocked.txt; полный ru-blocked-all стоит +157 МБ RSS
# в nfqws2 и запрашивается только явно).

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

# ==============================================================================
# ПОДМЕНЮ: АВТОТЕСТ
# ==============================================================================

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

    # Persist the user's explicit on/off intent in ENABLED so a manual stop
    # survives config regen, auto-update reinstall and reboot (the init start()
    # gate in S99zapret2.new reads ENABLED; config_official now preserves it).
    # ONLY the user-facing start/stop/restart below call this — internal /
    # automatic restarts must leave ENABLED untouched so they honor it.
    _persist_enabled() {
        [ -f "${ZAPRET2_DIR}/config" ] || return 0
        set_flag ENABLED "$1" "${ZAPRET2_DIR}/config"
    }

    printf "Выберите действие: "
    read_input action

    case "$action" in
        1)
            print_info "Запуск сервиса..."
            _persist_enabled 1
            "$INIT_SCRIPT" start
            ;;
        2)
            print_info "Остановка сервиса..."
            _persist_enabled 0
            "$INIT_SCRIPT" stop
            ;;
        3)
            print_info "Перезапуск сервиса..."
            _persist_enabled 1
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
# ПОДМЕНЮ: ПРОВЕРКА ОБНОВЛЕНИЙ Z2K (АВТО-АПДЕЙТ)
# ==============================================================================

menu_check_updates() {
    clear_screen
    print_header "Проверка обновлений z2k"

    if ! is_zapret2_installed; then
        print_info "zapret2 не установлен"
        pause
        return
    fi

    # Source the auto-update module from its installed location;
    # fall back to WORK_DIR copy during initial install.
    if [ -f "${ZAPRET2_DIR}/lib/auto_update.sh" ]; then
        . "${ZAPRET2_DIR}/lib/auto_update.sh"
    elif [ -f "${WORK_DIR:-/tmp/z2k}/lib/auto_update.sh" ]; then
        . "${WORK_DIR:-/tmp/z2k}/lib/auto_update.sh"
    else
        print_error "Модуль auto_update не найден"
        pause
        return 1
    fi

    # Branch gate — only z2k-enhanced participates
    local branch_file="${ZAPRET2_DIR}/.z2k-branch"
    local branch="unknown"
    [ -f "$branch_file" ] && branch=$(cat "$branch_file" 2>/dev/null)
    if [ "$branch" != "z2k-enhanced" ]; then
        print_warning "Авто-обновление работает только на ветке z2k-enhanced."
        print_info "Текущая ветка: ${branch}"
        pause
        return 0
    fi

    au_run_check
    local check_rc=$?

    if [ "$check_rc" -ne 0 ]; then
        pause
        return $check_rc
    fi

    # Decide if update is available — by re-reading manifest already cached
    # in $Z2K_AU_TMP_DIR by au_run_check.
    local installed=""
    [ -f "$Z2K_AU_INSTALLED_TAG_FILE" ] && installed=$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)
    local current=""
    if [ -f "${Z2K_AU_TMP_DIR}/UPDATES.json" ]; then
        current=$(au_manifest_current "${Z2K_AU_TMP_DIR}/UPDATES.json")
    fi

    if [ -n "$current" ] && [ "$current" != "$installed" ] && [ -n "$installed" ]; then
        printf "\n"
        if confirm "Применить обновление сейчас (без ожидания ночного запуска)?" "N"; then
            print_info "Запуск обновления..."
            # ОБНОВЛЕНИЕ ОБЯЗАНО ПЕРЕЖИТЬ ОБРЫВ SSH, и это не предосторожность.
            #
            # Панель запускает apply под `trap '' HUP` — там рядом стоит замер:
            # без него задача умирает на середине, ровно на переезде дерева
            # /opt/zapret2, и роутер остаётся с переименованным каталогом. В
            # терминале защиты не было вовсе: au_run_apply шёл прямо в переднем
            # плане сессии, то есть в её группе процессов. Обновление само
            # перезапускает сервис и обновляет бинарники — SSH при этом рвётся
            # (см. штормы restart_fw), — и весь процесс получал SIGHUP.
            #
            # Снаружи это выглядит как «обновиться не смог»: файлы разложены,
            # отметка версии не записана. Следующий запуск видит «нужно
            # обновить файлов: 0» и заново гоняет шаги, а человек — что ничего
            # не происходит.
            #
            # Игнорирование сигнала наследуется через exec, поэтому защищено
            # всё дерево процессов, а не только subshell. Вывод остаётся на
            # терминале, пока тот жив; au_log пишет и в файл журнала, и в
            # stderr под `|| true`, так что мёртвый tty ничего не роняет.
            # ERREXIT СНИМАЕМ НА ВРЕМЯ ОБНОВЛЕНИЯ, И ЭТО КОРЕНЬ, А НЕ ЗАПЛАТА.
            #
            # Код обновления писался и проверялся как отдельный скрипт:
            # z2k-auto-update.sh идёт без `set -e`, ненулевые коды там —
            # рабочий материал, их ловят и разбирают. Сорснутый в z2k.sh, тот
            # же код попадает под чужие правила: любая команда с ненулевым
            # кодом убивает оболочку молча. Отсюда и разница «в панели
            # обновляется, в терминале нет» — панель запускает скрипт отдельным
            # процессом.
            #
            # Здесь мы даём обновлению те же правила, при которых оно работает
            # у панели, и возвращаем errexit сразу после.
            local apply_rc=0
            set +e
            ( trap '' HUP; Z2K_AU_NO_JITTER=1 au_run_apply )
            apply_rc=$?
            set -e
            if [ "$apply_rc" -eq 0 ]; then
                print_success "Обновление применено."
            else
                print_error "Обновление не удалось (rc=$apply_rc), см. /opt/var/log/z2k-auto-update.log"
            fi
        else
            print_info "Хорошо, авто-обновление пройдёт ночью (~02:00 + jitter)."
        fi
    fi

    pause
    return 0
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
            # Stop FIRST, while DISABLE_CUSTOM is still 0, so the firewall unapply
            # (custom_runner zapret_custom_firewall 0) removes the custom.d NFQUEUE
            # rules (qnum 65300/65301). custom_runner early-returns once
            # DISABLE_CUSTOM=1, so flipping the flag first would orphan those rules
            # in POSTROUTING and keep them shadowing the main profiles (Discord
            # voice stayed broken even after disabling). Then flip + start.
            local _customd_was_running=0
            is_zapret2_running && _customd_was_running=1
            if [ "$_customd_was_running" = "1" ]; then
                print_info "Остановка сервиса (чистый teardown custom.d)..."
                "$INIT_SCRIPT" stop
            fi
            sed -i 's/^DISABLE_CUSTOM=.*/DISABLE_CUSTOM=1/' "$zapret_config"
            print_success "Скрипты custom.d ОТКЛЮЧЕНЫ"
            if [ "$_customd_was_running" = "1" ]; then
                print_info "Запуск сервиса..."
                "$INIT_SCRIPT" start
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
# ПОДМЕНЮ: ПОЛИТИКА ДОСТУПА KEENETIC (фильтр трафика по NDM ip policy)
# ==============================================================================

_policy_exists() {
    local name="$1"
    [ -z "$name" ] && return 1
    local ndmc_bin="ndmc"
    [ -x /bin/ndmc ] && ndmc_bin="/bin/ndmc"
    LD_LIBRARY_PATH= "$ndmc_bin" -c "show ip policy" 2>/dev/null | awk -v want="$(printf '%s' "$name" | tr 'A-Z' 'a-z')" '
        function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
        function unquote(s) { s=trim(s); if (s ~ /^".*"$/) { sub(/^"/, "", s); sub(/"$/, "", s) } return s }
        function strip_colon(s) { sub(/:+$/, "", s); return s }
        BEGIN { want = strip_colon(want); found = 0 }
        /description[ \t]*=/ {
            desc = $0
            sub(/.*description[ \t]*=[ \t]*/, "", desc)
            desc = strip_colon(tolower(unquote(desc)))
            if (desc == want) { found = 1; exit }
        }
        END { exit (found ? 0 : 1) }
    '
}

menu_policy_access() {
    clear_screen
    print_header "Политика доступа Keenetic"

    local config_file="${ZAPRET2_DIR}/config"
    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local POLICY_NAME POLICY_EXCLUDE
    POLICY_NAME=$(safe_config_read "POLICY_NAME" "$config_file" "nfqws")
    POLICY_EXCLUDE=$(safe_config_read "POLICY_EXCLUDE" "$config_file" "0")

    local status_line
    if [ -z "$POLICY_NAME" ]; then
        status_line="⚪ Поле пусто — фильтр выключен"
    elif _policy_exists "$POLICY_NAME"; then
        status_line="🟢 Политика «$POLICY_NAME» найдена в Keenetic"
    else
        status_line="🟡 Политика «$POLICY_NAME» не найдена — фильтр игнорируется"
    fi

    local mode_text
    if [ "$POLICY_EXCLUDE" = "1" ]; then
        mode_text="ВСЕ КРОМЕ устройств в политике"
    else
        mode_text="только устройства В политике (whitelist)"
    fi

    print_separator
    print_info "Имя:    $POLICY_NAME"
    print_info "Статус: $status_line"
    print_info "Режим:  $mode_text"
    print_separator

    cat <<'SUBMENU'

КАК СОЗДАТЬ ПОЛИТИКУ

  1. Откройте раздел приоритетов
     В админке Keenetic: Интернет → Приоритеты подключений.

  2. Создайте политику
     Вкладка «Конфигурация политик» → кнопка «+ Добавить политику».

  3. Задайте имя
     Имя должно точно совпадать с тем, что введено выше — по
     умолчанию «nfqws». Регистр учитывается.

  4. Выберите подключение
     В колонке «Подключение» оставьте галки на тех интерфейсах,
     которыми пользуются эти устройства (обычно ваше текущее
     подключение к интернету).

  5. Привяжите устройства
     Вкладка «Привязка устройств к профилям» → включите «Показать
     все объекты» → перетащите нужные устройства на созданную
     политику.

  6. Примените у нас
     Вернитесь сюда и через [2]/[3] выберите режим.

Нет раздела «Приоритеты подключений»?
  Установите компонент: Управление → Общие настройки → Изменить
  набор компонентов, найдите «Приоритеты подключений (PBR)» и
  установите. После перезагрузки роутера раздел появится в меню
  «Интернет».

[1] Изменить имя политики
[2] Применять только к устройствам В политике
[3] Применять ко всем КРОМЕ устройств политики
[B] Назад

SUBMENU

    printf "Выберите опцию [1-3,B]: "
    read_input sub_choice

    _policy_set_and_restart() {
        local key="$1" val="$2"
        set_flag "$key" "$val" "$config_file"
        if is_zapret2_running; then
            print_info "Перезапуск сервиса..."
            "$INIT_SCRIPT" restart
            print_success "Сервис перезапущен"
        fi
    }

    case "$sub_choice" in
        1)
            printf "Введите имя политики (1-32 символа, пусто = выключить): "
            read_input new_name
            # Убираем только перевод строки и CR. Пробелы ВНУТРИ имени оставляем:
            # политика в Keenetic вполне может называться «Домашние устройства».
            new_name=$(printf '%s' "$new_name" | tr -d '\r\n')
            # Ведущие/замыкающие пробелы срезаем — они невидимы и ломают сверку.
            new_name=$(printf '%s' "$new_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            # Фильтра [A-Za-z0-9_-] здесь больше НЕТ.
            #
            # Он отвергал кириллицу и пробел, тогда как вебпанель те же имена
            # принимает — там для этого сделан аккуратный подсчёт символов UTF-8.
            # Один и тот же параметр вёл себя по-разному в зависимости от того,
            # откуда его правят, и это ровно та цена, которую платят за две
            # реализации одной операции. Записывает теперь общая set_flag: она
            # кладёт небезопасное значение в одинарные кавычки, поэтому пробел и
            # кириллица больше не превращают конфиг в команду.
            #
            # Управляющие байты — единственное, что отвергаем: в имени политики
            # им делать нечего, а в конфиге они ломают построчный разбор.
            case "$new_name" in
                '') ;;
                *[[:cntrl:]]*) print_error "В имени недопустимы управляющие символы"; pause; return 1 ;;
            esac
            # Длина в СИМВОЛАХ, а не в байтах: ${#var} на ash/dash считает байты,
            # и кириллическое имя из 17 символов иначе объявляется длиннее 32.
            # Тот же расчёт, что в webpanel/cgi/api.sh — байты минус продолжения
            # UTF-8 (они имеют вид 10xxxxxx).
            if [ -n "$new_name" ]; then
                _nm_bytes=${#new_name}
                _nm_cont=$(printf '%s' "$new_name" | LC_ALL=C tr -dc '\200-\277' | wc -c | tr -d ' ')
                if [ "$((_nm_bytes - _nm_cont))" -gt 32 ]; then
                    print_error "Слишком длинное имя (>32 символов)"; pause; return 1
                fi
            fi
            _policy_set_and_restart "POLICY_NAME" "$new_name"
            print_success "Имя политики сохранено: ${new_name:-(пусто)}"
            pause
            ;;
        2)
            _policy_set_and_restart "POLICY_EXCLUDE" "0"
            print_success "Режим: только устройства В политике"
            pause
            ;;
        3)
            _policy_set_and_restart "POLICY_EXCLUDE" "1"
            print_success "Режим: все КРОМЕ устройств политики"
            pause
            ;;
        b|B|*)
            return 0
            ;;
    esac
}


# ==============================================================================
# ПОДМЕНЮ: ДИНАМИЧЕСКИЙ TTL ДЛЯ FAKE-ПАКЕТОВ
# ==============================================================================

menu_dynamic_ttl() {
    clear_screen
    print_header "Динамический TTL (для мобильных операторов)"

    local config_file="${ZAPRET2_DIR}/config"

    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local Z2K_DYNAMIC_TTL
    Z2K_DYNAMIC_TTL=$(safe_config_read "Z2K_DYNAMIC_TTL" "$config_file" "1")

    print_separator
    print_info "Статус: $([ "$Z2K_DYNAMIC_TTL" = "0" ] && echo 'Выключен' || echo 'Включен (по умолчанию)')"
    print_separator

    cat <<'SUBMENU'

z2k автоматически инжектит fool=z2k_dynamic_ttl в каждую
fake-стратегию (rkn_tcp, yt_tcp, gv_tcp). Lua-hook ставит
fake-пакету TTL = (реальный egress TTL - 1), чтобы fake
выглядел как обычный клиентский пакет с точки зрения ТСПУ.

Когда выключать:
  Мобильные операторы с запретом раздачи (МТС, Билайн),
  где симка от телефона и на роутере включён NDM TTL-fix
  (`ip ttl-fix` через CLI). NDM всё равно перебивает TTL
  всех исходящих на фиксированное значение, наш inject в
  этой топологии избыточен и съедает CPU lua-вызовами на
  каждый fake. Полезно если speedtest показывает дикую
  деградацию пропускной способности при включённом z2k.

[1] Включить (по умолчанию)
[2] Выключить (для мобильных операторов / слабого CPU)
[B] Назад

SUBMENU

    printf "Выберите опцию [1-2,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            if grep -q '^Z2K_DYNAMIC_TTL=' "$config_file"; then
                sed -i 's/^Z2K_DYNAMIC_TTL=.*/Z2K_DYNAMIC_TTL=1/' "$config_file"
            else
                echo "Z2K_DYNAMIC_TTL=1" >> "$config_file"
            fi
            print_success "Динамический TTL включён"

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
            ;;

        2)
            if [ "$Z2K_DYNAMIC_TTL" = "0" ]; then
                print_info "Уже выключен"
                pause
                return 0
            fi

            if grep -q '^Z2K_DYNAMIC_TTL=' "$config_file"; then
                sed -i 's/^Z2K_DYNAMIC_TTL=.*/Z2K_DYNAMIC_TTL=0/' "$config_file"
            else
                echo "Z2K_DYNAMIC_TTL=0" >> "$config_file"
            fi
            print_success "Динамический TTL выключен"

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
# ПОДМЕНЮ: АППАРАТНЫЙ OFFLOAD — per-flow исключение (Keenetic MediaTek PPE)
# ==============================================================================
menu_autohostlist() {
    clear_screen
    print_header "Автохостлист"

    local config_file="${ZAPRET2_DIR}/config"

    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local Z2K_AUTOHOSTLIST _auto_file _auto_count
    Z2K_AUTOHOSTLIST=$(safe_config_read "Z2K_AUTOHOSTLIST" "$config_file" "0")
    _auto_file="${ZAPRET2_DIR}/ipset/zapret-hosts-auto.txt"
    _auto_count=$(grep -cvE '^[[:space:]]*(#|$)' "$_auto_file" 2>/dev/null || echo 0)

    print_separator
    print_info "Флаг: $([ "$Z2K_AUTOHOSTLIST" = "1" ] && echo 'Включён' || echo 'Выключен (по умолчанию)')   Найдено доменов: ${_auto_count:-0}"
    print_separator

    cat <<'SUBMENU'

Обычно z2k работает по спискам доменов: обходятся только те, что
в списках. Автохостлист меняет принцип — движок сам замечает, что
домен не открывается, и добавляет его в список. Найденное
переливается в RKN-список, так что подхватывается штатно.

Плюс: сайты, которых нет в списках, начинают работать без ручных
добавлений. Минус: движок судит по поведению соединения и иногда
ошибается — в список может попасть домен, который просто лежал
сам по себе.

Это смена режима фильтрации для ВСЕГО трафика, а не добавка,
поэтому по умолчанию выключено.

[1] Включить
[2] Выключить (по умолчанию)
[B] Назад

SUBMENU

    printf "Выберите опцию [1-2,B]: "
    read_input _ahl_choice

    case "$_ahl_choice" in
        1)
            if grep -q '^Z2K_AUTOHOSTLIST=' "$config_file"; then
                sed -i 's/^Z2K_AUTOHOSTLIST=.*/Z2K_AUTOHOSTLIST=1/' "$config_file"
            else
                echo "Z2K_AUTOHOSTLIST=1" >> "$config_file"
            fi
            print_success "Автохостлист включён"
            print_info "Пересоздание конфига (MODE_FILTER -> autohostlist)..."
            create_official_config "/opt/zapret2/config"
            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
            fi
            pause
            ;;
        2)
            if grep -q '^Z2K_AUTOHOSTLIST=' "$config_file"; then
                sed -i 's/^Z2K_AUTOHOSTLIST=.*/Z2K_AUTOHOSTLIST=0/' "$config_file"
            else
                echo "Z2K_AUTOHOSTLIST=0" >> "$config_file"
            fi
            print_success "Автохостлист выключен"
            print_info "Пересоздание конфига (MODE_FILTER -> hostlist)..."
            create_official_config "/opt/zapret2/config"
            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
            fi
            pause
            ;;
        b|B)
            return 0
            ;;
        *)
            print_error "Неверный выбор"
            pause
            ;;
    esac
    return 0
}

menu_ppe() {
    clear_screen
    print_header "Аппаратный offload: per-flow исключение"

    local config_file="${ZAPRET2_DIR}/config"

    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local Z2K_PPE_DEOFFLOAD _ppe_avail _ppe_rules
    Z2K_PPE_DEOFFLOAD=$(safe_config_read "Z2K_PPE_DEOFFLOAD" "$config_file" "1")
    _ppe_avail="нет (не Keenetic MediaTek)"
    grep -qx "PPE" /proc/net/ip_tables_targets 2>/dev/null && _ppe_avail="да (firmware PPE target)"
    _ppe_rules=$(iptables -t mangle -S 2>/dev/null | grep -c "connskip.*-j PPE")

    print_separator
    print_info "Флаг: $([ "$Z2K_PPE_DEOFFLOAD" = "0" ] && echo 'Выключен' || echo 'Включен (по умолчанию)')   Поддержка: $_ppe_avail   Активных правил: ${_ppe_rules:-0}"
    print_separator

    cat <<'SUBMENU'

На Keenetic (MediaTek) аппаратный ускоритель (PPE) уводит поток в
железо после первого пакета — и nfqws2 НЕ видит ретрансмиты
ClientHello, поэтому ротатор не может уйти со сломанной стратегии
для silent-drop блокировок (mailsuite, flibusta и т.п.).

Эта опция вешает родной firmware-таргет -j PPE на окно
рукопожатия bypass-портов: первые ~30 пакетов каждого соединения
остаются на CPU (nfqws2 их видит -> ротация работает), а основной
поток дальше снова идёт через аппаратное ускорение. Глобальное
ускорение НЕ выключается. В паре с этим circular переводится на
retrans=1 (иначе одинаковые CH-ретрансмиты не считаются провалом).

[1] Включить (по умолчанию)
[2] Выключить (вернуть retrans=2, снять правила — старое поведение)
[B] Назад

SUBMENU

    printf "Выберите опцию [1-2,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            if grep -q '^Z2K_PPE_DEOFFLOAD=' "$config_file"; then
                sed -i 's/^Z2K_PPE_DEOFFLOAD=.*/Z2K_PPE_DEOFFLOAD=1/' "$config_file"
            else
                echo "Z2K_PPE_DEOFFLOAD=1" >> "$config_file"
            fi
            print_success "Per-flow PPE de-offload включён"
            print_info "Пересоздание конфига (circular -> retrans=1)..."
            create_official_config "/opt/zapret2/config"
            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
            fi
            if [ -r /opt/zapret2/z2k-ppe-deoffload.sh ]; then
                ( . /opt/zapret2/z2k-ppe-deoffload.sh && z2k_ppe_ensure_rules ) >/dev/null 2>&1 \
                    && print_success "Правила de-offload применены" \
                    || print_warning "firmware PPE target недоступен — на этом роутере опция неактивна"
            fi
            pause
            ;;

        2)
            if grep -q '^Z2K_PPE_DEOFFLOAD=' "$config_file"; then
                sed -i 's/^Z2K_PPE_DEOFFLOAD=.*/Z2K_PPE_DEOFFLOAD=0/' "$config_file"
            else
                echo "Z2K_PPE_DEOFFLOAD=0" >> "$config_file"
            fi
            print_success "Per-flow PPE de-offload выключен"
            if [ -r /opt/zapret2/z2k-ppe-deoffload.sh ]; then
                ( . /opt/zapret2/z2k-ppe-deoffload.sh && z2k_ppe_remove_rules ) >/dev/null 2>&1 || true
            fi
            print_info "Пересоздание конфига (circular -> retrans=2)..."
            create_official_config "/opt/zapret2/config"
            if is_zapret2_running; then
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
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
# ПОДМЕНЮ: СБОР СТАТИСТИКИ СТРАТЕГИЙ (анонимно)
# ==============================================================================

menu_stats() {
    clear_screen
    print_header "Сбор статистики стратегий (анонимно)"

    local config_file="${ZAPRET2_DIR}/config"

    if [ ! -f "$config_file" ]; then
        print_error "Конфиг не найден: $config_file"
        print_info "Запустите установку сначала"
        pause
        return 1
    fi

    local Z2K_STATS
    Z2K_STATS=$(safe_config_read "Z2K_STATS" "$config_file" "1")

    # Экран открыт — значит человек видит, что именно уходит. Снимаем гейт
    # первой отправки: до этого момента аплоадер молчит (см.
    # files/z2k-stats-upload.sh). Ставим ДО показа текста, а не после выбора:
    # согласия мы не спрашиваем, телеметрия включена по умолчанию — мы лишь
    # обязаны показать, что она есть, прежде чем что-то уйдёт.
    if [ "$(safe_config_read "Z2K_STATS_ACK" "$config_file" "1")" = "0" ]; then
        set_flag Z2K_STATS_ACK 1 "$config_file" 2>/dev/null || true
    fi

    print_separator
    print_info "Статус: $([ "$Z2K_STATS" = "0" ] && echo 'Выключен' || echo 'Включён (по умолчанию)')"
    print_separator

    cat <<'SUBMENU'

Раз в сутки z2k отправляет на сервер проекта ОБЕЗЛИЧЕННЫЙ
срез ротации: какая стратегия сейчас активна в каждом пуле
(yt_quic, rkn_tcp, yt_tcp ...) и как долго держится. Сводная
по всем согласившимся помогает понять, какие стратегии реально
работают, и двигать лучшие в начало списка.

Что НЕ уходит с устройства НИКОГДА:
  - сайты/домены, которые вы открываете;
  - ваш IP, провайдер, регион;
  - любой идентификатор устройства (ни серийник, ни случайный).
Уходят только: имя пула, номер стратегии, время удержания.

Важно, честно: отправка идёт БЕЗ шифрования (обычный HTTP
на 213.176.74.63:8088). Содержимое обезличено для нас, но не
для того, кто видит ваш канал: провайдер и его DPI замечают
сам факт ежедневного запроса на этот адрес и названия
стратегий в нём. Для инструмента обхода блокировок это
заметнее, чем любое поле внутри. Не устраивает — выключите
пунктом [2], он работает сразу.

[1] Включить (по умолчанию)
[2] Выключить (отказаться от сбора)
[B] Назад

SUBMENU

    printf "Выберите опцию [1-2,B]: "
    read_input sub_choice

    case "$sub_choice" in
        1)
            if grep -q '^Z2K_STATS=' "$config_file"; then
                sed -i 's/^Z2K_STATS=.*/Z2K_STATS=1/' "$config_file"
            else
                echo "Z2K_STATS=1" >> "$config_file"
            fi
            # Out-of-band telemetry flag: read fresh by z2k-stats-upload.sh each
            # run, so no config regen / service restart is needed.
            print_success "Сбор статистики включён"
            pause
            ;;

        2)
            if grep -q '^Z2K_STATS=' "$config_file"; then
                sed -i 's/^Z2K_STATS=.*/Z2K_STATS=0/' "$config_file"
            else
                echo "Z2K_STATS=0" >> "$config_file"
            fi
            print_success "Сбор статистики выключен"
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
# ПОДМЕНЮ: ИГРОВОЙ РЕЖИМ WARP
# ==============================================================================
# Туннель Cloudflare WARP на нашем движке z2k-warpd (WireGuard → MASQUE-h2).
# Три действия, как в панели: Установить / Вкл-Выкл / Удалить — без намерения
# юзера на роутере нет ни движка, ни демона. Ортогонально десинку: движок —
# z2k-warp.sh, флаг GAME_WARP_ENABLED, без рестарта nfqws2.
menu_game_warp() {
    clear_screen
    print_header "Игровой режим (WARP)"
    local st installed cur
    st=$(sh "${ZAPRET2_DIR}/z2k-warp.sh" status 2>/dev/null)
    installed=$(printf '%s' "$st" | sed -n 's/.*installed=\([01]\).*/\1/p')
    cur=$(printf '%s' "$st" | sed -n 's/.*enabled=\([01]\).*/\1/p')
    echo "Заворачивает заблокированные по IP хостинги (игровые серверы, диапазоны"
    echo "Cloudflare/AWS из списка РКН) и выбранные устройства в туннель Cloudflare"
    echo "WARP. Пока режим включён, часть сайтов на этих хостингах тоже идёт через"
    echo "туннель и может быть медленнее. Держи выключенным вне игры."
    echo
    if [ "$installed" = "1" ]; then
        echo "Движок: установлен. Режим: $([ "$cur" = "1" ] && echo "ВКЛючён" || echo "выключен")"
        printf '  %s\n' "$st"
        echo
        echo "[1] Включить   [0] Выключить   [D] Удалить WARP   [B] Назад"
    else
        echo "Движок: не установлен (на роутере нет ни бинаря, ни демона)."
        echo
        echo "[I] Установить WARP (~7 МБ + регистрация у Cloudflare)   [B] Назад"
    fi
    printf "Выбор: "; read_input sub_choice
    case "$sub_choice" in
        [Ii])
            print_info "Скачиваю движок и регистрирую устройство..."
            if sh "${ZAPRET2_DIR}/z2k-warp.sh" install; then
                print_success "WARP установлен. Включи пунктом [1]"
            else
                print_error "Не установился — причина строкой выше"
            fi
            ;;
        1)
            [ "$installed" = "1" ] || { print_error "Сначала установи — пункт [I]"; pause; return 0; }
            print_info "Поднимаю туннель (до 2 минут)..."
            sh "${ZAPRET2_DIR}/z2k-warp.sh" enable; _warp_rc=$?
            # Тот же контракт, что у тумблера панели: 0 — ready, 2 — включено,
            # туннель поднимается (флаг остаётся), 1 — движка нет.
            if [ "$_warp_rc" = "0" ]; then
                print_success "WARP включён, туннель проверен"
            elif [ "$_warp_rc" = "2" ]; then
                print_warning "Режим включён, но туннель пока не поднялся — причина строкой выше; движок продолжает попытки в фоне"
            else
                print_error "WARP не установлен — режим оставлен выключенным"
            fi
            ;;
        0)
            sh "${ZAPRET2_DIR}/z2k-warp.sh" disable >/dev/null 2>&1
            print_success "WARP выключен"
            ;;
        [Dd])
            [ "$installed" = "1" ] || { print_error "Нечего удалять"; pause; return 0; }
            printf "Удалить движок WARP? Ключ устройства и списки сохранятся [y/N]: "; read_input _c
            case "$_c" in
                [Yy]) sh "${ZAPRET2_DIR}/z2k-warp.sh" remove >/dev/null 2>&1; print_success "WARP удалён" ;;
                *) print_info "Отмена" ;;
            esac
            ;;
        [Bb]) return 0 ;;
        *) print_error "Неверный выбор" ;;
    esac
    pause
}


# ==============================================================================
# ПОДМЕНЮ: TELEGRAM MTPROXY
# ==============================================================================

menu_telegram_mtproxy() {
    local MTPROXY_BIN="/opt/sbin/tg-mtproxy-client"

    while true; do
        clear_screen
        print_header "Telegram"

        # Cmdline filter '--listen=:1443' — иначе pgrep матчит S97 cdnbase
        # daemon (тот же бинарь tg-mtproxy-client на :1444). После disable
        # TG-туннеля S97 продолжает работать → false-positive «Включен».
        local tunnel_running=false
        if pgrep -f "tg-mtproxy-client .*--listen=:1443" >/dev/null 2>&1; then
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

                # Clear user-disabled flag before calling S98tg-tunnel; its
                # start path intentionally refuses to run while the flag is 1.
                if [ -f "${ZAPRET2_DIR}/config" ]; then
                    if grep -q '^TG_PROXY_USER_DISABLED=' "${ZAPRET2_DIR}/config"; then
                        sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=0/' "${ZAPRET2_DIR}/config"
                    fi
                fi

                # Start through init when available so boot/runtime behavior
                # stays identical and OUTPUT redirect rules are managed too.
                if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
                    /opt/etc/init.d/S98tg-tunnel restart >/dev/null 2>&1
                    # cdnbase (:1444) — тот же бинарник, включается вместе.
                    [ -x "/opt/etc/init.d/S97z2k-http-tunnel" ] && \
                        /opt/etc/init.d/S97z2k-http-tunnel restart >/dev/null 2>&1
                else
                    killall tg-mtproxy-client 2>/dev/null || true
                    sleep 1
                    # CWE-59: root-owned 0700 log dir
                    # CWE-59: /tmp/z2k-log должен быть чистым root-owned каталогом. symlink /
                    # не-каталог / чужой владелец = возможная подмена атакующим (с planted
                    # symlink'ами внутри) → снести и создать заново. busybox `stat -c` нет —
                    # владельца берём из `ls -ld`.
                    if [ -L /tmp/z2k-log ] || { [ -e /tmp/z2k-log ] && [ ! -d /tmp/z2k-log ]; } || \
                       { [ -d /tmp/z2k-log ] && [ "$(ls -ld /tmp/z2k-log 2>/dev/null | awk '{print $3}')" != root ]; }; then
                        rm -rf /tmp/z2k-log 2>/dev/null
                    fi
                    mkdir -p /tmp/z2k-log 2>/dev/null && chown root /tmp/z2k-log 2>/dev/null
                    chmod 700 /tmp/z2k-log 2>/dev/null
                    "$MTPROXY_BIN" --listen=:1443 --timeout=15m -v >> /tmp/z2k-log/tg-tunnel.log 2>&1 &
                fi
                sleep 2

                if pgrep -f "tg-mtproxy-client .*--listen=:1443" >/dev/null 2>&1; then
                    print_success "Tunnel запущен"
                    # Fallback path for installs that do not have S98 yet.
                    if ! [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
                        for cidr in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24; do
                            iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
                                iptables -t nat -I PREROUTING 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
                            iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
                                iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
                        done
                    fi
                    print_success "Telegram работает для всех устройств"
                else
                    print_error "Не удалось запустить"
                    tail -5 /tmp/z2k-log/tg-tunnel.log 2>/dev/null
                    rm -f "$MTPROXY_BIN"
                    print_info "Бинарник удалён — нажмите [1] ещё раз для перескачивания"
                fi
                pause
                ;;

            2)
                # Stop tunnel + cleanup. Set user-disabled marker BEFORE
                # killing the process so the watchdog (cron, every minute)
                # sees the flag and won't resurrect the daemon in 3 min.
                if [ -f "${ZAPRET2_DIR}/config" ]; then
                    if grep -q '^TG_PROXY_USER_DISABLED=' "${ZAPRET2_DIR}/config"; then
                        sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=1/' "${ZAPRET2_DIR}/config"
                    else
                        echo "TG_PROXY_USER_DISABLED=1" >> "${ZAPRET2_DIR}/config"
                    fi
                fi
                if [ -x "/opt/etc/init.d/S98tg-tunnel" ]; then
                    /opt/etc/init.d/S98tg-tunnel stop >/dev/null 2>&1
                    # И cdnbase (:1444), иначе процесс остаётся в памяти.
                    [ -x "/opt/etc/init.d/S97z2k-http-tunnel" ] && \
                        /opt/etc/init.d/S97z2k-http-tunnel stop >/dev/null 2>&1
                else
                    killall tg-mtproxy-client 2>/dev/null || true
                    for cidr in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24; do
                        while iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
                            iptables -t nat -D PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
                        done
                        while iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
                            iptables -t nat -D OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
                        done
                    done
                fi
                print_success "Telegram tunnel выключен (watchdog не будет восстанавливать)"
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
    print_header "Исключения по домену"

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

            # Удалить домен.
            #
            # `grep -v ... && mv` — не то, что нужно: grep выходит с единицей,
            # когда не осталось НИ ОДНОЙ строки, то есть при удалении последнего
            # домена mv не выполняется, файл остаётся прежним, а «удалён» всё
            # равно печатается. Смотрим на результат самого mv, а пустой вывод
            # grep считаем законным исходом (ровно так же это уже сделано в
            # webpanel/cgi/actions.sh: autohostlist_domains_delete).
            grep -vxF "$del_domain" "$whitelist_file" > "${whitelist_file}.tmp" 2>/dev/null
            if [ -f "${whitelist_file}.tmp" ] && mv "${whitelist_file}.tmp" "$whitelist_file"; then
                print_success "Домен $del_domain удален из whitelist"
            else
                rm -f "${whitelist_file}.tmp"
                print_error "Не удалось изменить whitelist — домен остался на месте"
                pause
                continue
            fi
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

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
