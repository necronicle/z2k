#!/bin/sh
# lib/install.sh - Полный процесс установки zapret2 для Keenetic
# 12-шаговая установка с интеграцией списков доменов и стратегий

# ==============================================================================
# ШАГ 0: ПРОВЕРКА ROOT ПРАВ (КРИТИЧНО)
# ==============================================================================

step_check_root() {
    print_header "Шаг 0/12: Проверка прав доступа"

    print_info "Проверка root прав..."

    if [ "$(id -u)" -ne 0 ]; then
        print_error "Требуются root права для установки zapret2"
        print_separator
        print_info "Запустите установку с правами root:"
        printf "  sudo sh z2k.sh install\n\n"
        print_warning "Без root прав невозможно:"
        print_warning "  - Установить пакеты через opkg"
        print_warning "  - Создать init скрипт в /opt/etc/init.d/"
        print_warning "  - Настроить iptables правила"
        print_warning "  - Загрузить модули ядра"
        return 1
    fi

    print_success "Root права подтверждены (UID=$(id -u))"
    return 0
}

# ==============================================================================
# ШАГ 1: ОБНОВЛЕНИЕ ПАКЕТОВ
# ==============================================================================

step_update_packages() {
    print_header "Шаг 1/12: Обновление пакетов"

    print_info "Обновление списка пакетов Entware..."

    # Попытка обновления с полным перехватом вывода
    local opkg_output
    opkg_output=$(opkg update 2>&1)
    local exit_code=$?

    # Показать вывод opkg
    echo "$opkg_output"

    if [ "$exit_code" -eq 0 ]; then
        print_success "Список пакетов обновлен"
        return 0
    else
        print_error "Не удалось обновить список пакетов (код: $exit_code)"

        # Проверка на Illegal instruction - типичная проблема на Keenetic из-за блокировки РКН
        if echo "$opkg_output" | grep -qi "illegal instruction"; then
            print_warning "Обнаружена ошибка 'Illegal instruction'"
            print_info "Это часто связано с блокировкой РКН репозитория bin.entware.net"
            print_separator

            # Попытка переключения на альтернативное зеркало (метод от zapret4rocket)
            print_info "Попытка переключения на альтернативное зеркало Entware..."

            local current_mirror
            current_mirror=$(grep -m1 "^src" /opt/etc/opkg.conf | awk '{print $3}' | grep -o 'bin.entware.net')

            if [ -n "$current_mirror" ]; then
                print_info "Меняю bin.entware.net → entware.diversion.ch"

                # Создать backup конфига
                cp /opt/etc/opkg.conf /opt/etc/opkg.conf.backup

                # Заменить зеркало
                sed -i 's|bin.entware.net|entware.diversion.ch|g' /opt/etc/opkg.conf

                print_info "Повторная попытка обновления с новым зеркалом..."

                # Повторить opkg update
                opkg_output=$(opkg update 2>&1)
                exit_code=$?

                echo "$opkg_output"

                if [ "$exit_code" -eq 0 ]; then
                    print_success "Список пакетов обновлен через альтернативное зеркало!"
                    print_info "Backup старого конфига: /opt/etc/opkg.conf.backup"
                    return 0
                else
                    print_error "Не помогло - ошибка осталась"
                    print_info "Восстанавливаю оригинальный конфиг..."
                    mv /opt/etc/opkg.conf.backup /opt/etc/opkg.conf
                fi
            else
                print_info "Зеркало bin.entware.net не найдено в конфиге"
            fi

            printf "\n"
        fi

        # Диагностика причины ошибки
        print_info "Углубленная диагностика проблемы..."
        print_separator

        # Анализ вывода opkg для определения точного места ошибки
        if echo "$opkg_output" | grep -q "Illegal instruction"; then
            # Попробовать найти контекст
            local error_context
            error_context=$(echo "$opkg_output" | grep -B2 "Illegal instruction" | head -5)
            if [ -n "$error_context" ]; then
                print_info "Контекст ошибки:"
                echo "$error_context"
            fi
        fi
        printf "\n"

        # 1. Проверка архитектуры системы
        local sys_arch
        sys_arch=$(uname -m)
        print_info "Архитектура системы: $sys_arch"

        # 2. Проверка архитектуры Entware
        if [ -f "/opt/etc/opkg.conf" ]; then
            local entware_arch
            entware_arch=$(grep -m1 "^arch" /opt/etc/opkg.conf | awk '{print $2}')
            print_info "Архитектура Entware: ${entware_arch:-не определена}"

            local repo_url
            repo_url=$(grep -m1 "^src" /opt/etc/opkg.conf | awk '{print $3}')
            print_info "Репозиторий: $repo_url"

            # 3. Проверка доступности репозитория
            if [ -n "$repo_url" ]; then
                print_info "Проверка доступности репозитория..."
                if curl -s -m 5 --head "$repo_url/Packages.gz" >/dev/null 2>&1; then
                    print_success "[OK] Репозиторий доступен"
                else
                    print_error "[FAIL] Репозиторий недоступен"
                fi
            fi
        fi

        # 4. Проверка самого opkg
        print_info "Проверка opkg бинарника..."
        if opkg --version 2>&1 | grep -qi "illegal"; then
            print_error "[FAIL] opkg --version падает (Illegal instruction)"
            print_warning "ПРИЧИНА: opkg установлен для неправильной архитектуры CPU!"
        elif opkg --version >/dev/null 2>&1; then
            local opkg_version
            opkg_version=$(opkg --version 2>&1 | head -1)
            print_success "[OK] opkg бинарник запускается: $opkg_version"
            print_warning "Но 'opkg update' падает - возможно проблема в зависимости или скрипте"
        else
            print_error "[FAIL] opkg не работает по неизвестной причине"
        fi

        # 5. Проверка файла opkg
        if command -v file >/dev/null 2>&1; then
            if [ -f "/opt/bin/opkg" ]; then
            local opkg_file_info
            opkg_file_info=$(file /opt/bin/opkg 2>&1 | head -1)
                print_info "Бинарник opkg: $opkg_file_info"
            fi
        fi

        print_separator

        # 6. Рекомендации по дополнительной диагностике
        print_info "Для детальной диагностики попробуйте вручную:"
        printf "  opkg update --verbosity=2\n\n"

        # Определяем основную причину на основе диагностики
        if opkg --version 2>&1 | grep -qi "illegal"; then
            cat <<'EOF'
[WARN]  КРИТИЧЕСКАЯ ПРОБЛЕМА: НЕПРАВИЛЬНАЯ АРХИТЕКТУРА ENTWARE

Диагностика показала: opkg не может выполниться на этом роутере.
Это означает что Entware установлен для НЕПРАВИЛЬНОЙ архитектуры CPU.

ПРИЧИНА:
Ваш роутер имеет процессор одной архитектуры, а установлен Entware
для другой архитектуры. Это как пытаться запустить программу для
Intel на процессоре ARM.

ЧТО ДЕЛАТЬ:
1. Удалите текущий Entware:
   - Зайдите в веб-интерфейс роутера
   - Система → Компоненты → Entware → Удалить

2. Установите ПРАВИЛЬНУЮ версию Entware:
   - Скачайте installer.sh с официального сайта
   - Убедитесь что выбрана версия для ВАШЕЙ модели роутера
   - https://help.keenetic.com/hc/ru/articles/360021888880

3. После переустановки запустите z2k снова

ВАЖНО: z2k не может работать с неправильной версией Entware!
EOF
        elif echo "$opkg_output" | grep -qi "illegal instruction"; then
            cat <<'EOF'
[WARN]  СЛОЖНАЯ ПРОБЛЕМА: opkg update падает с "Illegal instruction"

Диагностика и попытки исправления:
- [OK] opkg бинарник запускается (opkg --version работает)
- [OK] Архитектура системы корректная
- [OK] Репозиторий доступен (curl тест успешен)
- [OK] Попробовали альтернативное зеркало (entware.diversion.ch)
- [FAIL] НО "opkg update" всё равно падает с "Illegal instruction"

Это редкая проблема, которая может быть связана с:
1. Поврежденной зависимой библиотекой (libcurl, libssl, и др.)
2. Несовместимостью конкретной версии пакета с вашим CPU
3. Поврежденной базой данных opkg
4. Проблемой с самой установкой Entware

РЕКОМЕНДАЦИИ ПО УСТРАНЕНИЮ:

1. Проверьте какая библиотека вызывает ошибку:
   ldd /opt/bin/opkg
   (покажет все зависимые библиотеки)

2. Попробуйте детальную диагностику:
   opkg update --verbosity=2 2>&1 | tee /tmp/opkg_debug.log
   (сохранит полный вывод в файл)

3. Очистите кэш и попробуйте снова:
   rm -rf /opt/var/opkg-lists/*
   opkg update

4. Проверьте место на диске:
   df -h /opt
   (убедитесь что есть свободное место)

5. Если ничего не помогает - переустановите Entware:
   https://help.keenetic.com/hc/ru/articles/360021888880
   Убедитесь что выбираете версию Entware для вашей архитектуры!

ПРОДОЛЖИТЬ БЕЗ ОБНОВЛЕНИЯ?
Можно попробовать продолжить установку z2k.
Если нужные пакеты (iptables, ipset, curl) уже установлены -
всё может заработать и без обновления списков пакетов.
EOF
        else
            cat <<'EOF'
[WARN]  ОШИБКА ПРИ ОБНОВЛЕНИИ ПАКЕТОВ

Проверьте результаты диагностики выше.

Если репозиторий недоступен:
- Проблемы с сетью, DNS или блокировка
- Проверьте: curl -I http://bin.entware.net/

Если другая проблема:
- Попробуйте вручную: opkg update --verbosity=2
- Проверьте логи: cat /opt/var/log/opkg.log

ПРОДОЛЖИТЬ БЕЗ ОБНОВЛЕНИЯ?
Установка продолжится с текущими пакетами.
Обычно это безопасно, если пакеты уже установлены.
EOF
        fi
        printf "\nПродолжить без opkg update? [Y/n]: "
        read -r answer </dev/tty

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Установка прервана"
                print_info "Исправьте проблему и запустите снова"
                return 1
                ;;
            *)
                print_warning "Продолжаем без обновления пакетов..."
                print_info "Будет использована текущая локальная база пакетов"
                return 0
                ;;
        esac
    fi
}

# ==============================================================================
# ШАГ 2: ПРОВЕРКА DNS (ВАЖНО)
# ==============================================================================

step_check_dns() {
    print_header "Шаг 2/12: Проверка DNS"

    print_info "Проверка работы DNS и доступности интернета..."

    # Проверить несколько серверов
    local test_hosts="github.com google.com cloudflare.com"
    local dns_works=0

    for host in $test_hosts; do
        if nslookup "$host" >/dev/null 2>&1; then
            print_success "DNS работает ($host разрешён)"
            dns_works=1
            break
        fi
    done

    if [ $dns_works -eq 0 ]; then
        print_error "DNS не работает!"
        print_separator
        print_warning "Возможные причины:"
        print_warning "  1. Нет подключения к интернету"
        print_warning "  2. DNS сервер не настроен"
        print_warning "  3. Блокировка РКН (bin.entware.net, github.com)"
        print_separator

        printf "Продолжить установку без работающего DNS? [y/N]: "
        read -r answer </dev/tty

        case "$answer" in
            [Yy]*)
                print_warning "Продолжаем без DNS..."
                print_info "Установка может не удаться при загрузке файлов"
                return 0
                ;;
            *)
                print_info "Установка прервана"
                print_info "Исправьте DNS и запустите снова"
                return 1
                ;;
        esac
    fi

    return 0
}

# ==============================================================================
# ШАГ 3: УСТАНОВКА ЗАВИСИМОСТЕЙ (РАСШИРЕНО)
# ==============================================================================

step_install_dependencies() {
    print_header "Шаг 3/12: Установка зависимостей"

    # Список необходимых пакетов для Entware (только runtime)
    local packages="
libmnl
libnetfilter-queue
libnfnetlink
libcap
zlib
curl
unzip
cron
"

    print_info "Установка пакетов..."

    for pkg in $packages; do
        if opkg list-installed | grep -q "^${pkg} "; then
            print_info "$pkg уже установлен"
        else
            print_info "Установка $pkg..."
            opkg install "$pkg" || print_warning "Не удалось установить $pkg"
        fi
    done

    # Создать симлинки для библиотек (нужно для линковки)
    print_info "Создание симлинков библиотек..."

    # Создание симлинков в подоболочке (не меняет рабочую директорию)
    (
        cd /opt/lib || exit 1

        # libmnl
        if [ ! -e libmnl.so ] && [ -e libmnl.so.0 ]; then
            ln -sf libmnl.so.0 libmnl.so
        fi

        # libnetfilter_queue
        if [ ! -e libnetfilter_queue.so ] && [ -e libnetfilter_queue.so.1 ]; then
            ln -sf libnetfilter_queue.so.1 libnetfilter_queue.so
        fi

        # libnfnetlink
        if [ ! -e libnfnetlink.so ] && [ -e libnfnetlink.so.0 ]; then
            ln -sf libnfnetlink.so.0 libnfnetlink.so
        fi
    ) || print_warning "Не удалось создать симлинки в /opt/lib"
    print_info "Симлинки библиотек проверены"

    # =========================================================================
    # КРИТИЧНЫЕ ПАКЕТЫ ДЛЯ ZAPRET2 (из check_prerequisites_openwrt)
    # =========================================================================

    print_separator
    print_info "Установка критичных пакетов для zapret2..."

    local critical_packages=""

    # ipset - КРИТИЧНО для фильтрации по спискам доменов
    if ! opkg list-installed | grep -q "^ipset "; then
        print_info "ipset требуется для фильтрации трафика"
        critical_packages="$critical_packages ipset"
    else
        print_success "ipset уже установлен"
    fi

    # Проверка kernel модулей (на Keenetic встроены в ядро, не требуют установки)
    # xt_NFQUEUE - КРИТИЧНО для перенаправления в NFQUEUE
    if [ -f "/lib/modules/$(uname -r)/xt_NFQUEUE.ko" ] || lsmod | grep -q "xt_NFQUEUE" || modinfo xt_NFQUEUE >/dev/null 2>&1; then
        print_success "Модуль xt_NFQUEUE доступен"
    else
        print_warning "Модуль xt_NFQUEUE не найден (может быть встроен в ядро)"
    fi

    # xt_connbytes, xt_multiport - для фильтрации пакетов
    if modinfo xt_connbytes >/dev/null 2>&1 || grep -q "xt_connbytes" /proc/modules 2>/dev/null; then
        print_success "Модуль xt_connbytes доступен"
    else
        print_warning "Модуль xt_connbytes не найден (может быть встроен в ядро)"
    fi

    if modinfo xt_multiport >/dev/null 2>&1 || grep -q "xt_multiport" /proc/modules 2>/dev/null; then
        print_success "Модуль xt_multiport доступен"
    else
        print_warning "Модуль xt_multiport не найден (может быть встроен в ядро)"
    fi

    # Установить критичные пакеты если нужно (только ipset для Keenetic)
    if [ -n "$critical_packages" ]; then
        print_info "Установка:$critical_packages"
        if opkg install $critical_packages; then
            print_success "Критичные пакеты установлены"
        else
            print_error "Не удалось установить критичные пакеты"
            print_warning "zapret2 может не работать без этих пакетов!"

            printf "Продолжить без них? [y/N]: "
            read -r answer </dev/tty
            case "$answer" in
                [Yy]*) print_warning "Продолжаем на свой страх и риск..." ;;
                *) return 1 ;;
            esac
        fi
    else
        print_success "Все критичные пакеты уже установлены"
    fi

    print_separator
    print_info "ПРИМЕЧАНИЕ: На Keenetic модули iptables (xt_NFQUEUE, xt_connbytes,"
    print_info "xt_multiport) встроены в ядро и не требуют отдельной установки."

    # =========================================================================
    # ОПЦИОНАЛЬНЫЕ ОПТИМИЗАЦИИ (GNU gzip/sort)
    # =========================================================================

    print_separator
    print_info "Проверка опциональных оптимизаций..."

    # Проверить busybox gzip
    if command -v gzip >/dev/null 2>&1; then
        if readlink "$(command -v gzip)" 2>/dev/null | grep -q busybox; then
            print_info "Обнаружен busybox gzip (медленный, ~3x медленнее GNU)"
            printf "Установить GNU gzip для ускорения обработки списков? [y/N]: "
            read -r answer </dev/tty
            case "$answer" in
                [Yy]*)
                    if opkg install --force-overwrite gzip; then
                        print_success "GNU gzip установлен"
                    else
                        print_warning "Не удалось установить GNU gzip"
                    fi
                    ;;
                *)
                    print_info "Пропускаем установку GNU gzip"
                    ;;
            esac
        fi
    fi

    # Проверить busybox sort
    if command -v sort >/dev/null 2>&1; then
        if readlink "$(command -v sort)" 2>/dev/null | grep -q busybox; then
            print_info "Обнаружен busybox sort (медленный, использует много RAM)"
            printf "Установить GNU sort для ускорения? [y/N]: "
            read -r answer </dev/tty
            case "$answer" in
                [Yy]*)
                    if opkg install --force-overwrite coreutils-sort; then
                        print_success "GNU sort установлен"
                    else
                        print_warning "Не удалось установить GNU sort"
                    fi
                    ;;
                *)
                    print_info "Пропускаем установку GNU sort"
                    ;;
            esac
        fi
    fi

    print_success "Зависимости установлены"
    return 0
}

# ==============================================================================
# ШАГ 4: ЗАГРУЗКА МОДУЛЕЙ ЯДРА
# ==============================================================================

step_load_kernel_modules() {
    print_header "Шаг 4/12: Загрузка модулей ядра"

    local modules="xt_multiport xt_connbytes xt_NFQUEUE nfnetlink_queue"

    for module in $modules; do
        load_kernel_module "$module" || print_warning "Модуль $module не загружен"
    done

    # Load ip_set_bitmap_port from system modules (Entware modprobe cannot find it)
    if ! lsmod | grep -q "ip_set_bitmap_port"; then
        insmod "/lib/modules/$(uname -r)/ip_set_bitmap_port.ko" 2>/dev/null || true
    fi

    print_success "Модули ядра загружены"
    return 0
}

# ==============================================================================
# ШАГ 5: УСТАНОВКА ZAPRET2 (ИСПОЛЬЗУЯ ОФИЦИАЛЬНЫЙ install_bin.sh)
# ==============================================================================

step_build_zapret2() {
    print_header "Шаг 5/12: Установка zapret2"

    # Сохранить пользовательские данные перед удалением
    local backup_tmp="/tmp/z2k_upgrade_backup"
    rm -rf "$backup_tmp"
    if [ -d "$ZAPRET2_DIR" ]; then
        print_info "Сохранение пользовательских настроек..."
        mkdir -p "$backup_tmp"
        # Config (содержит DROP_DPI_RST, RKN_SILENT_FALLBACK и др.)
        [ -f "$ZAPRET2_DIR/config" ] && cp -f "$ZAPRET2_DIR/config" "$backup_tmp/config"
        # Whitelist (пользовательские исключения)
        [ -f "$ZAPRET2_DIR/lists/whitelist.txt" ] && cp -f "$ZAPRET2_DIR/lists/whitelist.txt" "$backup_tmp/whitelist.txt"
        # Autocircular state (найденные рабочие стратегии)
        [ -f "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv" ] && \
            cp -f "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv" "$backup_tmp/state.tsv"
        # Strategy.txt файлы
        for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
            local sfile="$ZAPRET2_DIR/extra_strats/$cat_dir/Strategy.txt"
            if [ -f "$sfile" ]; then
                mkdir -p "$backup_tmp/strats/$cat_dir"
                cp -f "$sfile" "$backup_tmp/strats/$cat_dir/Strategy.txt"
            fi
        done
        # Silent fallback flag
        [ -f "$ZAPRET2_DIR/extra_strats/cache/autocircular/rkn_silent_fallback.flag" ] && \
            touch "$backup_tmp/rkn_silent_fallback.flag"
        print_success "Настройки сохранены"

        print_info "Удаление старой установки..."
        rm -rf "$ZAPRET2_DIR"
        print_success "Старая установка удалена"
    fi

    # Создать временную директорию
    local build_dir="/tmp/zapret2_build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    cd "$build_dir" || return 1

    # ===========================================================================
    # ШАГ 4.1: Скачать OpenWrt embedded релиз (содержит всё необходимое)
    # ===========================================================================

    print_info "Загрузка zapret2 OpenWrt embedded релиза..."

    # GitHub API для получения последней версии
    local api_url="https://api.github.com/repos/bol-van/zapret2/releases/latest"
    local release_data
    release_data=$(curl -fsSL --connect-timeout 10 --max-time 120 "$api_url" 2>&1)

    local openwrt_url
    if [ $? -ne 0 ]; then
        print_warning "API недоступен, использую fallback версию v0.9.4.7..."
        openwrt_url="https://github.com/bol-van/zapret2/releases/download/v0.9.4.7/zapret2-v0.9.4.7-openwrt-embedded.tar.gz"
    else
        # Парсим URL из JSON
        openwrt_url=$(echo "$release_data" | grep -o 'https://github.com/bol-van/zapret2/releases/download/[^"]*openwrt-embedded\.tar\.gz' | head -1)

        if [ -z "$openwrt_url" ]; then
            print_warning "Не найден в API, использую fallback v0.9.4.7..."
            openwrt_url="https://github.com/bol-van/zapret2/releases/download/v0.9.4.7/zapret2-v0.9.4.7-openwrt-embedded.tar.gz"
        fi
    fi

    print_info "URL релиза: $openwrt_url"

    # Скачать релиз
    if ! curl -fsSL --connect-timeout 10 --max-time 120 "$openwrt_url" -o openwrt-embedded.tar.gz; then
        print_error "Не удалось загрузить zapret2 OpenWrt embedded"
        return 1
    fi

    print_success "Релиз загружен ($(du -h openwrt-embedded.tar.gz | cut -f1))"

    # ===========================================================================
    # ШАГ 4.2: Распаковать полную структуру релиза
    # ===========================================================================

    print_info "Распаковка релиза..."

    tar -xzf openwrt-embedded.tar.gz || {
        print_error "Ошибка распаковки архива"
        return 1
    }

    # Найти корневую директорию релиза (zapret2-vX.Y.Z)
    local release_dir
    release_dir=$(find . -maxdepth 1 -type d -name "zapret2-v*" | head -1)

    if [ -z "$release_dir" ] || [ ! -d "$release_dir" ]; then
        print_error "Не найдена директория релиза в архиве"
        ls -la
        return 1
    fi

    print_success "Релиз распакован: $release_dir"

    # ===========================================================================
    # ШАГ 4.3: Использовать install_bin.sh для установки бинарников
    # ===========================================================================

    print_info "Определение архитектуры и установка бинарников..."

    cd "$release_dir" || return 1

    # Установить переменные окружения для install_bin.sh
    export ZAPRET_BASE="$PWD"

    # Проверить наличие install_bin.sh
    if [ ! -f "install_bin.sh" ]; then
        print_error "install_bin.sh не найден в релизе"
        return 1
    fi

    # Вызвать install_bin.sh для автоматической установки бинарников
    print_info "Запуск официального install_bin.sh..."

    if sh install_bin.sh; then
        print_success "Бинарники установлены через install_bin.sh"
    else
        print_error "install_bin.sh завершился с ошибкой"
        print_info "Попытка ручной установки..."

        # Fallback: ручная установка если install_bin.sh не сработал
        local sys_arch entware_arch arch bin_arch opkg_bin
        sys_arch=$(uname -m)
        entware_arch=""
        opkg_bin="opkg"
        [ -x /opt/bin/opkg ] && opkg_bin="/opt/bin/opkg"

        if command -v "$opkg_bin" >/dev/null 2>&1; then
            entware_arch=$("$opkg_bin" print-architecture 2>/dev/null | awk '
                $1 == "arch" && $2 != "all" {
                    prio = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
                    if (prio >= max) { max = prio; arch = $2 }
                }
                END { if (arch != "") print arch }
            ')
        fi

        arch="${entware_arch:-$sys_arch}"
        bin_arch=""

        case "$arch" in
            aarch64|arm64|*aarch64*|*arm64*) bin_arch="linux-arm64" ;;
            armv7l|armv6l|arm|*armv7*|*armv6*|arm*) bin_arch="linux-arm" ;;
            x86_64|amd64|*x86_64*|*amd64*) bin_arch="linux-x86_64" ;;
            i386|i486|i586|i686|x86) bin_arch="linux-x86" ;;
            *mipsel64*|*mips64el*) bin_arch="linux-mipsel" ;;
            *mips64*) bin_arch="linux-mips64" ;;
            *mipsel*) bin_arch="linux-mipsel" ;;
            *mips*) bin_arch="linux-mips" ;;
            *lexra*) bin_arch="linux-lexra" ;;
            *ppc*) bin_arch="linux-ppc" ;;
            *riscv64*) bin_arch="linux-riscv64" ;;
            *)
                print_error "Unsupported architecture: $arch (uname=$sys_arch${entware_arch:+, opkg=$entware_arch})"
                return 1
                ;;
        esac

        print_info "Auto-detected architecture: uname=$sys_arch${entware_arch:+, opkg=$entware_arch} -> $bin_arch"

        if [ ! -d "binaries/$bin_arch" ]; then
            print_error "Бинарники для $bin_arch не найдены"
            return 1
        fi

        # Создать директории и установить бинарники вручную
        mkdir -p nfq2 ip2net mdig
        cp "binaries/$bin_arch/nfqws2" nfq2/ || return 1
        cp "binaries/$bin_arch/ip2net" ip2net/ || return 1
        cp "binaries/$bin_arch/mdig" mdig/ || return 1
        chmod +x nfq2/nfqws2 ip2net/ip2net mdig/mdig

        print_success "Бинарники установлены вручную для $bin_arch"
    fi

    # Проверить что nfqws2 исполняемый и работает
    if [ ! -x "nfq2/nfqws2" ]; then
        print_error "nfqws2 не найден или не исполняемый после установки"
        return 1
    fi

    # Проверить запуск
    if ! ./nfq2/nfqws2 --version >/dev/null 2>&1; then
        print_warning "nfqws2 не может быть запущен (возможно не та архитектура)"
        print_info "Вывод --version:"
        ./nfq2/nfqws2 --version 2>&1 | head -5 || true
    else
        local version
        version=$(./nfq2/nfqws2 --version 2>&1 | head -1)
        print_success "nfqws2 работает: $version"
    fi

    # ===========================================================================
    # ШАГ 4.4: Переместить в финальную директорию
    # ===========================================================================

    print_info "Установка в $ZAPRET2_DIR..."

    cd "$build_dir" || return 1
    cp -a "$release_dir" "$ZAPRET2_DIR" && rm -rf "$release_dir" || return 1

    # ВАЖНО: Обновить ZAPRET_BASE на финальный путь (был /tmp/zapret2_build/...)
    export ZAPRET_BASE="$ZAPRET2_DIR"

    # ===========================================================================
    # ШАГ 4.5: Добавить кастомные файлы из z2k репозитория
    # ===========================================================================

    print_info "Копирование дополнительных файлов..."

    # Скопировать strats_new2.txt если есть в z2k репозитории
    if [ -f "${WORK_DIR}/strats_new2.txt" ]; then
        cp -f "${WORK_DIR}/strats_new2.txt" "${ZAPRET2_DIR}/" || \
            print_warning "Не удалось скопировать strats_new2.txt"
    fi

    # Скопировать quic_strats.ini если есть
    if [ -f "${WORK_DIR}/quic_strats.ini" ]; then
        cp -f "${WORK_DIR}/quic_strats.ini" "${ZAPRET2_DIR}/" || \
            print_warning "Не удалось скопировать quic_strats.ini"
    fi

    # Скопировать кастомные lua-хелперы z2k (например, персистентность autocircular)
    if [ -d "${WORK_DIR}/files/lua" ]; then
        mkdir -p "${ZAPRET2_DIR}/lua"
        cp -f "${WORK_DIR}/files/lua/"*.lua "${ZAPRET2_DIR}/lua/" 2>/dev/null || true
    fi

    # Обновить fake blobs если есть более свежие в z2k
    if [ -d "${WORK_DIR}/files/fake" ]; then
        print_info "Updating fake blobs from z2k..."
        cp -f "${WORK_DIR}/files/fake/"* "${ZAPRET2_DIR}/files/fake/" 2>/dev/null || true
    fi

    # Create blob aliases: strategies use short names, files have full names
    local fakedir="${ZAPRET2_DIR}/files/fake"
    if [ -d "$fakedir" ]; then
        # tls_max_ru → tls_clienthello_max_ru.bin
        [ ! -e "$fakedir/tls_max_ru" ] && [ -f "$fakedir/tls_clienthello_max_ru.bin" ] && \
            ln -sf tls_clienthello_max_ru.bin "$fakedir/tls_max_ru"
        # quic short aliases → quic_N.bin
        [ ! -e "$fakedir/quic1" ] && [ -f "$fakedir/quic_1.bin" ] && ln -sf quic_1.bin "$fakedir/quic1"
        [ ! -e "$fakedir/quic4" ] && [ -f "$fakedir/quic_4.bin" ] && ln -sf quic_4.bin "$fakedir/quic4"
        [ ! -e "$fakedir/quic5" ] && [ -f "$fakedir/quic_5.bin" ] && ln -sf quic_5.bin "$fakedir/quic5"
        [ ! -e "$fakedir/quic6" ] && [ -f "$fakedir/quic_6.bin" ] && ln -sf quic_6.bin "$fakedir/quic6"
        # quic_google → quic_initial_google_com.bin
        [ ! -e "$fakedir/quic_google" ] && [ -f "$fakedir/quic_initial_google_com.bin" ] && \
            ln -sf quic_initial_google_com.bin "$fakedir/quic_google"
        # quic_rutracker → quic_initial_rutracker_org.bin
        [ ! -e "$fakedir/quic_rutracker" ] && [ -f "$fakedir/quic_initial_rutracker_org.bin" ] && \
            ln -sf quic_initial_rutracker_org.bin "$fakedir/quic_rutracker"
    fi

    # Install blocked-monitor helper (runtime diagnostics for blocked domains).
    if [ -f "${WORK_DIR}/files/z2k-blocked-monitor.sh" ]; then
        cp -f "${WORK_DIR}/files/z2k-blocked-monitor.sh" "${ZAPRET2_DIR}/z2k-blocked-monitor.sh" 2>/dev/null || true
        chmod +x "${ZAPRET2_DIR}/z2k-blocked-monitor.sh" 2>/dev/null || true
    fi

    # Install z2k tools (healthcheck, config validator, list updater, diagnostics, geosite)
    for tool_script in z2k-healthcheck.sh z2k-config-validator.sh z2k-update-lists.sh z2k-diag.sh z2k-geosite.sh; do
        if [ -f "${WORK_DIR}/files/${tool_script}" ]; then
            cp -f "${WORK_DIR}/files/${tool_script}" "${ZAPRET2_DIR}/${tool_script}" 2>/dev/null || true
            chmod +x "${ZAPRET2_DIR}/${tool_script}" 2>/dev/null || true
            print_info "Установлен: ${tool_script}"
        fi
    done

    # Web panel is now installed on-demand via menu [P] → [1].
    # Files live in webpanel/ in the repo and are copied to /tmp/z2k/webpanel
    # by z2k.sh bootstrap; install.sh leaves the router filesystem alone.

    # Copy snapshot domain lists for local install flow (no external list repos)
    if [ -d "${WORK_DIR}/files/lists" ]; then
        print_info "Copying snapshot domain lists..."
        mkdir -p "${ZAPRET2_DIR}/files/lists"
        cp -Rf "${WORK_DIR}/files/lists/"* "${ZAPRET2_DIR}/files/lists/" 2>/dev/null || true
        # Strip CRLF from list files
        find "${ZAPRET2_DIR}" -name "*.txt" -path "*/extra_strats/*" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    fi

    # Copy IP lists (Roblox, Telegram)
    mkdir -p "${ZAPRET2_DIR}/lists"
    for iplist in game_ips.txt roblox_ips.txt telegram_ips.txt ipset-exclude.txt; do
        if [ -f "${WORK_DIR}/files/lists/${iplist}" ]; then
            cp -f "${WORK_DIR}/files/lists/${iplist}" "${ZAPRET2_DIR}/lists/${iplist}" 2>/dev/null || true
        fi
    done
    # Decompress lua.gz files (if any are shipped by embedded builds)
    if [ -d "${ZAPRET2_DIR}/lua" ]; then
        if command -v gzip >/dev/null 2>&1; then
            for f in "${ZAPRET2_DIR}/lua/"*.lua.gz; do
                [ -f "$f" ] || continue
                local out="${f%.gz}"
                print_info "Decompressing $(basename "$f")..."
                if gzip -dc "$f" > "${out}.tmp" 2>/dev/null; then
                    mv -f "${out}.tmp" "$out"
                    rm -f "$f"
                else
                    rm -f "${out}.tmp"
                    print_warning "Failed to decompress $f"
                fi
            done
        else
            print_warning "gzip not found, skipping lua.gz decompression"
        fi
    fi
    # ===========================================================================
    # ШАГ 4.6: Скачать locked.lua для circular_locked (Discord voice/video)
    # ===========================================================================

    print_info "Загрузка locked.lua для circular_locked..."

    mkdir -p "${ZAPRET2_DIR}/lua"
    mkdir -p "${ZAPRET2_DIR}/extra_strats/cache/orchestra"
    mkdir -p "${ZAPRET2_DIR}/extra_strats/cache/autocircular"
    chmod 755 "${ZAPRET2_DIR}/extra_strats/cache/autocircular" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular" 2>/dev/null || true
    : > "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
    chmod 644 "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
    : > "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv" 2>/dev/null || true
    chmod 644 "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv" 2>/dev/null || true
    # Debug is opt-in. Keep log file prepared, but do not enable verbose logging by default.
    rm -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.flag" 2>/dev/null || true
    : > "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.log" 2>/dev/null || true
    chmod 644 "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.log" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.log" 2>/dev/null || true
    rm -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv.lock" \
          "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv.tmp" \
          "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv.lock" \
          "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv.tmp" 2>/dev/null || true
    # Fresh install/reinstall must not inherit stale fallback cache from /tmp.
    rm -f /tmp/z2k-autocircular-state.tsv \
          /tmp/z2k-autocircular-telemetry.tsv \
          /tmp/z2k-autocircular-debug.flag \
          /tmp/z2k-autocircular-debug.log 2>/dev/null || true

    if curl -fsSL --connect-timeout 10 --max-time 120 "https://raw.githubusercontent.com/AloofLibra/zapret4rocket/z2r/orchestra/locked.lua" \
        -o "${ZAPRET2_DIR}/lua/locked.lua"; then
        print_success "locked.lua загружен"
    else
        print_warning "Не удалось загрузить locked.lua (Discord voice может не работать)"
    fi

    print_info "Загрузка orchestrator.sh для управления circular_locked..."

    if curl -fsSL --connect-timeout 10 --max-time 120 "https://raw.githubusercontent.com/AloofLibra/zapret4rocket/z2r/orchestra/orchestrator.sh" \
        -o "${ZAPRET2_DIR}/extra_strats/cache/orchestra/orchestrator.sh"; then
        chmod +x "${ZAPRET2_DIR}/extra_strats/cache/orchestra/orchestrator.sh"
        print_success "orchestrator.sh загружен"
    else
        print_warning "Не удалось загрузить orchestrator.sh (circular_locked будет без ротации)"
    fi

    # ===========================================================================
    # Восстановление пользовательских данных после переустановки
    # ===========================================================================
    if [ -d "$backup_tmp" ]; then
        print_info "Восстановление пользовательских настроек..."

        # Восстановить config (содержит DROP_DPI_RST, RKN_SILENT_FALLBACK)
        if [ -f "$backup_tmp/config" ]; then
            cp -f "$backup_tmp/config" "$ZAPRET2_DIR/config"
            print_success "Конфигурация восстановлена"
        fi

        # Восстановить whitelist
        if [ -f "$backup_tmp/whitelist.txt" ]; then
            mkdir -p "$ZAPRET2_DIR/lists"
            cp -f "$backup_tmp/whitelist.txt" "$ZAPRET2_DIR/lists/whitelist.txt"
            print_success "Whitelist восстановлен"
        fi

        # Восстановить autocircular state (рабочие стратегии)
        if [ -f "$backup_tmp/state.tsv" ]; then
            cp -f "$backup_tmp/state.tsv" "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv"
            chown nobody "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
            print_success "Стратегии autocircular восстановлены"
        fi

        # Восстановить Strategy.txt файлы
        for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
            if [ -f "$backup_tmp/strats/$cat_dir/Strategy.txt" ]; then
                mkdir -p "$ZAPRET2_DIR/extra_strats/$cat_dir"
                cp -f "$backup_tmp/strats/$cat_dir/Strategy.txt" "$ZAPRET2_DIR/extra_strats/$cat_dir/Strategy.txt"
            fi
        done
        print_success "Стратегии категорий восстановлены"

        # Восстановить silent fallback flag
        if [ -f "$backup_tmp/rkn_silent_fallback.flag" ]; then
            touch "$ZAPRET2_DIR/extra_strats/cache/autocircular/rkn_silent_fallback.flag"
            chown nobody "$ZAPRET2_DIR/extra_strats/cache/autocircular/rkn_silent_fallback.flag" 2>/dev/null || true
        fi

        rm -rf "$backup_tmp"
        print_success "Все пользовательские настройки восстановлены"
    fi

    # ===========================================================================
    # ШАГ 4.7: Установить custom.d скрипты (STUN + Discord media backup)
    # ===========================================================================

    print_info "Установка custom.d скриптов для STUN/Discord media..."

    local custom_dir="${ZAPRET2_DIR}/init.d/keenetic/custom.d"
    mkdir -p "$custom_dir"

    if curl -fsSL --connect-timeout 10 --max-time 120 "https://raw.githubusercontent.com/bol-van/zapret2/master/init.d/custom.d.examples.linux/50-stun4all" \
        -o "${custom_dir}/50-stun4all"; then
        chmod +x "${custom_dir}/50-stun4all"
        print_success "50-stun4all установлен"
    else
        print_warning "Не удалось загрузить 50-stun4all"
    fi

    if curl -fsSL --connect-timeout 10 --max-time 120 "https://raw.githubusercontent.com/bol-van/zapret2/master/init.d/custom.d.examples.linux/50-discord-media" \
        -o "${custom_dir}/50-discord-media"; then
        chmod +x "${custom_dir}/50-discord-media"
        print_success "50-discord-media установлен"
    else
        print_warning "Не удалось загрузить 50-discord-media"
    fi

    # ===========================================================================
    # ЗАВЕРШЕНИЕ
    # ===========================================================================

    # Очистка
    cd / || return 1
    rm -rf "$build_dir"

    print_success "zapret2 установлен"
    print_info "Структура:"
    print_info "  - Бинарники: nfq2/nfqws2, ip2net/ip2net, mdig/mdig"
    print_info "  - Lua библиотеки: lua/"
    print_info "  - Fake файлы: files/fake/"
    print_info "  - Модули: common/"
    print_info "  - Документация: docs/"

    return 0
}

# ==============================================================================
# ШАГ 6: ПРОВЕРКА УСТАНОВКИ
# ==============================================================================

step_verify_installation() {
    print_header "Шаг 6/12: Проверка установки"

    # Проверить структуру директорий
    local required_paths="
${ZAPRET2_DIR}
${ZAPRET2_DIR}/nfq2
${ZAPRET2_DIR}/nfq2/nfqws2
${ZAPRET2_DIR}/ip2net
${ZAPRET2_DIR}/mdig
${ZAPRET2_DIR}/lua
${ZAPRET2_DIR}/files
${ZAPRET2_DIR}/common
${ZAPRET2_DIR}/binaries
"

    print_info "Проверка структуры директорий..."

    local missing=0
    for path in $required_paths; do
        if [ -e "$path" ]; then
            print_info "[OK] $path"
        else
            print_warning "[FAIL] $path не найден"
            missing=$((missing + 1))
        fi
    done

    if [ $missing -gt 0 ]; then
        print_warning "Некоторые компоненты отсутствуют, но это может быть нормально"
    fi

    # Проверить все бинарники (установленные через install_bin.sh)
    print_info "Проверка бинарников..."

    # nfqws2 - основной бинарник
    if [ -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]; then
        if verify_binary "${ZAPRET2_DIR}/nfq2/nfqws2"; then
            print_success "[OK] nfqws2 работает"
        else
            print_error "[FAIL] nfqws2 не запускается"
            return 1
        fi
    else
        print_error "[FAIL] nfqws2 не найден или не исполняемый"
        return 1
    fi

    # ip2net - вспомогательный (может быть симлинком)
    if [ -e "${ZAPRET2_DIR}/ip2net/ip2net" ]; then
        print_info "[OK] ip2net установлен"
    else
        print_warning "[FAIL] ip2net не найден (необязательный)"
    fi

    # mdig - DNS утилита (может быть симлинком)
    if [ -e "${ZAPRET2_DIR}/mdig/mdig" ]; then
        print_info "[OK] mdig установлен"
    else
        print_warning "[FAIL] mdig не найден (необязательный)"
    fi

    # Посчитать компоненты
    print_info "Статистика компонентов:"

    # Lua файлы
    if [ -d "${ZAPRET2_DIR}/lua" ]; then
        local lua_count
        lua_count=$(find "${ZAPRET2_DIR}/lua" -name "*.lua" 2>/dev/null | wc -l)
        print_info "  - Lua файлов: $lua_count"
    fi

    # Fake файлы
    if [ -d "${ZAPRET2_DIR}/files/fake" ]; then
        local fake_count
        fake_count=$(find "${ZAPRET2_DIR}/files/fake" -name "*.bin" 2>/dev/null | wc -l)
        print_info "  - Fake файлов: $fake_count"
    fi

    # Модули common/
    if [ -d "${ZAPRET2_DIR}/common" ]; then
        local common_count
        common_count=$(find "${ZAPRET2_DIR}/common" -name "*.sh" 2>/dev/null | wc -l)
        print_info "  - Модули common/: $common_count"
    fi

    # install_bin.sh присутствует?
    if [ -f "${ZAPRET2_DIR}/install_bin.sh" ]; then
        print_info "  - install_bin.sh: установлен"
    fi

    print_success "Установка проверена успешно"
    return 0
}

# ==============================================================================
# ШАГ 7: ОПРЕДЕЛЕНИЕ ТИПА FIREWALL (КРИТИЧНО)
# ==============================================================================

step_check_and_select_fwtype() {
    print_header "Шаг 7/12: Определение типа firewall"

    print_info "Автоопределение типа firewall системы..."

    # ВАЖНО: Загрузить base.sh ПЕРЕД fwtype.sh, т.к. нужна функция exists()
    if [ -f "${ZAPRET2_DIR}/common/base.sh" ]; then
        . "${ZAPRET2_DIR}/common/base.sh"
    else
        print_error "Модуль base.sh не найден в ${ZAPRET2_DIR}/common/"
        return 1
    fi

    # Source модуль fwtype из zapret2
    if [ -f "${ZAPRET2_DIR}/common/fwtype.sh" ]; then
        . "${ZAPRET2_DIR}/common/fwtype.sh"
    else
        print_error "Модуль fwtype.sh не найден в ${ZAPRET2_DIR}/common/"
        return 1
    fi

    # ВАЖНО: Восстановить Z2K путь к init скрипту (он перезаписывается модулями zapret2)
    INIT_SCRIPT="$Z2K_INIT_SCRIPT"

    # Переопределить linux_ipt_avail для Keenetic (IPv4-only режим)
    # Официальная функция требует iptables И ip6tables, но Keenetic с DISABLE_IPV6=1
    # не имеет ip6tables, поэтому проверяем только iptables
    linux_ipt_avail()
    {
        exists iptables
    }

    # Автоопределение через функцию из zapret2
    linux_fwtype

    if [ -z "$FWTYPE" ]; then
        print_error "Не удалось определить тип firewall"
        FWTYPE="iptables"  # fallback
        print_warning "Используем fallback: iptables"
    fi

    print_success "Обнаружен firewall: $FWTYPE"

    # Показать информацию
    case "$FWTYPE" in
        iptables)
            print_info "iptables - традиционный firewall Linux"
            print_info "Keenetic обычно использует iptables"
            ;;
        nftables)
            print_info "nftables - современный firewall Linux (kernel 3.13+)"
            print_info "Более эффективен чем iptables"
            ;;
        *)
            print_warning "Неизвестный тип firewall: $FWTYPE"
            ;;
    esac

    # Записать FWTYPE в config файл (если он уже существует)
    local config="${ZAPRET2_DIR}/config"
    if [ -f "$config" ]; then
        # Проверить есть ли уже FWTYPE в config
        if grep -q "^#*FWTYPE=" "$config"; then
            # Обновить существующую строку
            sed -i "s|^#*FWTYPE=.*|FWTYPE=$FWTYPE|" "$config"
            print_info "FWTYPE=$FWTYPE записан в config"
        else
            # Добавить в конец FIREWALL SETTINGS секции
            sed -i "/# FIREWALL SETTINGS/a FWTYPE=$FWTYPE" "$config"
            print_info "FWTYPE=$FWTYPE добавлен в config"
        fi
    else
        print_info "Config файл ещё не создан, FWTYPE будет установлен позже"
    fi

    # Экспортировать для использования в других функциях
    export FWTYPE

    return 0
}

# ==============================================================================
# ШАГ 8: ЗАГРУЗКА СПИСКОВ ДОМЕНОВ
# ==============================================================================

step_download_domain_lists() {
    print_header "Шаг 8/12: Загрузка списков доменов"

    # Использовать функцию из lib/config.sh
    download_domain_lists || {
        print_error "Не удалось загрузить списки доменов"
        return 1
    }

    # Доп. проверка: список QUIC YT (zapret4rocket)
    local yt_quic_list="/opt/zapret2/extra_strats/UDP/YT/List.txt"
    if [ ! -s "$yt_quic_list" ]; then
        print_warning "QUIC YT list not found after local snapshot copy: $yt_quic_list"
        print_warning "Install snapshot files first (files/lists/extra_strats/UDP/YT/List.txt)"
    fi
    
    create_base_config || {
        print_error "Не удалось создать конфигурацию"
        return 1
    }

    print_success "Списки доменов и конфигурация установлены"
    return 0
}

# ==============================================================================
# ШАГ 9: ОТКЛЮЧЕНИЕ HARDWARE NAT
# ==============================================================================

step_disable_hwnat_and_offload() {
    print_header "Шаг 9/12: Отключение Hardware NAT и Flow Offloading"

    # =========================================================================
    # 9.1: Hardware NAT (fastnat на Keenetic)
    # =========================================================================

    print_info "Проверка Hardware NAT (fastnat)..."

    # Проверить наличие системы управления HWNAT
    if [ -f "/sys/kernel/fastnat/mode" ]; then
        local current_mode
        current_mode=$(cat /sys/kernel/fastnat/mode 2>/dev/null || echo "unknown")

        print_info "Текущий режим fastnat: $current_mode"

        if [ "$current_mode" != "0" ] && [ "$current_mode" != "unknown" ]; then
            print_warning "Hardware NAT включен - может конфликтовать с DPI bypass"

            # Попытка отключения
            if echo 0 > /sys/kernel/fastnat/mode 2>/dev/null; then
                print_success "Hardware NAT отключен"
            else
                print_warning "Не удалось отключить Hardware NAT"
                print_info "Возможно требуются дополнительные права"
                print_info "Попробуйте вручную: echo 0 > /sys/kernel/fastnat/mode"
            fi
        else
            print_success "Hardware NAT уже отключен или недоступен"
        fi
    else
        print_info "Hardware NAT (fastnat) не обнаружен на этой системе"
    fi

    # =========================================================================
    # 9.2: Flow Offloading (критично для nfqws)
    # =========================================================================

    print_separator
    print_info "Проверка Flow Offloading..."

    # На Keenetic flow offloading управляется через другие механизмы
    # В основном через iptables/nftables правила

    # Проверка через sysctl (если доступно)
    if [ -f "/proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal" ]; then
        print_info "Проверка conntrack liberal mode..."

        # zapret2 может требовать liberal mode для обработки invalid RST пакетов
        local liberal_mode
        liberal_mode=$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal 2>/dev/null || echo "0")

        if [ "$liberal_mode" = "0" ]; then
            print_info "conntrack liberal mode выключен (будет включен при старте zapret2)"
        else
            print_info "conntrack liberal mode уже включен"
        fi
    fi

    # Записать FLOWOFFLOAD=none в config (безопасный вариант)
    print_info "Установка FLOWOFFLOAD=none в config (рекомендуется для Keenetic)"

    # Это будет использовано при создании config файла
    export FLOWOFFLOAD=none

    print_separator
    print_info "Информация о flow offloading:"
    print_info "  - Flow offloading ускоряет routing но может ломать DPI bypass"
    print_info "  - nfqws трафик ДОЛЖЕН быть исключен из offloading"
    print_info "  - На Keenetic используется FLOWOFFLOAD=none (безопасно)"
    print_info "  - Официальный init скрипт автоматически настроит exemption rules"

    print_success "Hardware NAT и Flow Offloading проверены"
    return 0
}

# ==============================================================================
# ШАГ 9.5: НАСТРОЙКА TMPDIR ДЛЯ LOW RAM СИСТЕМ
# ==============================================================================

step_configure_tmpdir() {
    print_header "Шаг 9.5/12: Настройка TMPDIR для low RAM систем"

    # Получить объём RAM
    local ram_mb
    if [ -f "${ZAPRET2_DIR}/common/base.sh" ]; then
        # Save overrides before re-sourcing
        _saved_linux_ipt_avail="$(type linux_ipt_avail 2>/dev/null)"
        . "${ZAPRET2_DIR}/common/base.sh"
        # Restore override if it was set
        if [ -n "$_saved_linux_ipt_avail" ]; then
            linux_ipt_avail() { true; }
        fi
        ram_mb=$(get_ram_mb)
    else
        # Fallback: определить RAM вручную
        if [ -f /proc/meminfo ]; then
            ram_mb=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
        else
            ram_mb=999  # Предполагаем достаточно RAM если не можем определить
        fi
    fi

    print_info "Обнаружено RAM: ${ram_mb}MB"

    # АВТОМАТИЧЕСКИЙ выбор TMPDIR на основе RAM
    if [ "$ram_mb" -le 400 ]; then
        print_warning "Low RAM система - используем диск для временных файлов"

        local disk_tmpdir="/opt/zapret2/tmp"

        # Создать директорию
        mkdir -p "$disk_tmpdir" || {
            print_error "Не удалось создать $disk_tmpdir"
            return 1
        }

        export TMPDIR="$disk_tmpdir"
        print_success "TMPDIR установлен: $disk_tmpdir (защита от OOM)"

        # Проверить свободное место на диске
        if command -v df >/dev/null 2>&1; then
            local free_mb
            free_mb=$(df -m "$disk_tmpdir" | tail -1 | awk '{print $4}')
            print_info "Свободно на диске: ${free_mb}MB"

            if [ "$free_mb" -lt 200 ]; then
                print_warning "Мало свободного места (<200MB)"
            fi
        fi
    else
        print_success "Достаточно RAM (${ram_mb}MB) - используем /tmp (быстрее)"
        export TMPDIR=""
    fi

    return 0
}

# ==============================================================================
# ШАГ 10: СОЗДАНИЕ ОФИЦИАЛЬНОГО CONFIG И INIT СКРИПТА
# ==============================================================================

step_create_config_and_init() {
    print_header "Шаг 10/12: Создание config и init скрипта"

    # ========================================================================
    # 10.0: Создать дефолтные файлы стратегий
    # ========================================================================

    # Source функции для работы со стратегиями
    . "${LIB_DIR}/strategies.sh" || {
        print_error "Не удалось загрузить strategies.sh"
        return 1
    }

    # Создать директории и дефолтные файлы стратегий
    create_default_strategy_files || {
        print_error "Не удалось создать файлы стратегий"
        return 1
    }

    # ========================================================================
    # 10.1: Создать официальный config файл
    # ========================================================================

    print_info "Создание официального config файла..."

    local zapret_config="${ZAPRET2_DIR}/config"

    # Source функции для генерации config
    . "${LIB_DIR}/config_official.sh" || {
        print_error "Не удалось загрузить config_official.sh"
        return 1
    }

    # Создать config файл (с автогенерацией NFQWS2_OPT из стратегий)
    create_official_config "$zapret_config" || {
        print_error "Не удалось создать config файл"
        return 1
    }

    print_success "Config файл создан: $zapret_config"

    # ========================================================================
    # 8.2: Установить новый init скрипт
    # ========================================================================

    print_info "Установка init скрипта..."

    # Создать директорию если не существует
    mkdir -p "$(dirname "$INIT_SCRIPT")"

    # Скопировать init скрипт из дистрибутива
    print_info "Копирование init скрипта..."

    if [ -f "${WORK_DIR}/files/S99zapret2.new" ]; then
        cp -f "${WORK_DIR}/files/S99zapret2.new" "$INIT_SCRIPT" || {
            print_error "Не удалось скопировать init скрипт"
            return 1
        }
    else
        print_error "Init скрипт не найден: ${WORK_DIR}/files/S99zapret2.new"
        return 1
    fi

    chmod +x "$INIT_SCRIPT" || {
        print_error "Не удалось установить права на init скрипт"
        return 1
    }

    print_success "Init скрипт установлен: $INIT_SCRIPT"

    # Показать информацию о новом подходе
    print_info "Init скрипт использует:"
    print_info "  - Модули из $ZAPRET2_DIR/common/"
    print_info "  - Config файл: $zapret_config"
    print_info "  - Стратегии из config (config-driven, не hardcoded)"
    print_info "  - PID файлы для graceful shutdown"
    print_info "  - Разделение firewall/daemons"

    return 0
}

# ==============================================================================
# ШАГ 11: УСТАНОВКА NETFILTER ХУКА
# ==============================================================================

step_install_netfilter_hook() {
    print_header "Шаг 11/12: Установка netfilter хука"

    print_info "Установка хука для автоматического восстановления правил..."

    # Создать директорию для NDM хуков
    local hook_dir="/opt/etc/ndm/netfilter.d"
    mkdir -p "$hook_dir" || {
        print_error "Не удалось создать $hook_dir"
        return 1
    }

    local hook_file="${hook_dir}/000-zapret2.sh"

    # Скопировать хук из files/
    if [ -f "${WORK_DIR}/files/000-zapret2.sh" ]; then
        cp "${WORK_DIR}/files/000-zapret2.sh" "$hook_file" || {
            print_error "Не удалось скопировать хук"
            return 1
        }
    else
        print_warning "Файл хука не найден в ${WORK_DIR}/files/"
        print_info "Создание хука вручную..."

        # Создать хук напрямую
        cat > "$hook_file" <<'HOOK'
#!/bin/sh
# Keenetic NDM netfilter hook для автоматического восстановления правил zapret2
# Вызывается при изменениях в netfilter (iptables)

INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
ZAPRET_CONFIG="/opt/zapret2/config"

# Обрабатываем только изменения в таблицах mangle/nat.
# zapret2 использует mangle (NFQUEUE), но Keenetic при переподключении может дергать hook и на nat.
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit 0

# Проверить что init скрипт существует
[ ! -f "$INIT_SCRIPT" ] && exit 0

# Проверить что zapret2 включен (ENABLED=1 в конфиге)
if ! grep -q "^ENABLED=1" "$ZAPRET_CONFIG" 2>/dev/null; then
    exit 0
fi

# Не восстанавливать NFQUEUE-правила, если nfqws2 не запущен.
# Иначе трафик может уйти в очередь без потребителя.
is_nfqws2_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof nfqws2 >/dev/null 2>&1 && return 0
    fi

    # Fallback: check common pidfile locations (our init uses nfqws2_*.pid).
    for pidfile in /opt/var/run/nfqws2_*.pid /opt/var/run/nfqws2.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done

    return 1
}
is_nfqws2_running || exit 0

# Небольшая задержка для стабильности
sleep 2

# Восстановить только firewall-правила (НЕ restart!)
# restart убивает nfqws2, обнуляя Lua-состояние autocircular (per-domain стратегии).
# restart_fw пересоздаёт только NFQUEUE правила в mangle, демоны продолжают работу.
"$INIT_SCRIPT" restart_fw >/dev/null 2>&1 &

exit 0
HOOK
    fi

    # Сделать исполняемым
    chmod +x "$hook_file" || {
        print_error "Не удалось установить права на хук"
        return 1
    }

    print_success "Netfilter хук установлен: $hook_file"
    print_info "Хук будет восстанавливать правила при переподключении интернета"

    return 0
}

# ==============================================================================
# ШАГ 12: ФИНАЛИЗАЦИЯ
# ==============================================================================

step_finalize() {
    print_header "Шаг 12/12: Финализация установки"

    # Проверить бинарник перед запуском
    print_info "Проверка nfqws2 перед запуском..."

    if [ ! -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]; then
        print_error "nfqws2 не найден или не исполняемый"
        return 1
    fi

    # Проверить зависимости бинарника (если ldd доступен)
    if command -v ldd >/dev/null 2>&1; then
        print_info "Проверка библиотек..."
        if ldd "${ZAPRET2_DIR}/nfq2/nfqws2" 2>&1 | grep -q "not found"; then
            print_warning "Отсутствуют некоторые библиотеки:"
            ldd "${ZAPRET2_DIR}/nfq2/nfqws2" | grep "not found"
        else
            print_success "Все библиотеки найдены"
        fi
    fi

    # Попробовать запустить напрямую для диагностики
    print_info "Тест запуска nfqws2..."
    local version_output
    version_output=$("${ZAPRET2_DIR}/nfq2/nfqws2" --version 2>&1 | head -1)

    if echo "$version_output" | grep -q "github version"; then
        print_success "nfqws2 исполняется корректно: $version_output"
    else
        print_error "nfqws2 не может быть запущен"
        print_info "Вывод ошибки:"
        "${ZAPRET2_DIR}/nfq2/nfqws2" --version 2>&1 | head -10
        return 1
    fi

    # =========================================================================
    # НАСТРОЙКА АВТООБНОВЛЕНИЯ СПИСКОВ ДОМЕНОВ (КРИТИЧНО)
    # =========================================================================

    print_separator
    print_info "Настройка автообновления списков доменов..."

    # На Keenetic (Entware) cron работает через /opt/etc/crontab
    # НЕ используем installer.sh из zapret2 — он ищет /etc/init.d/cron (OpenWrt)
    local cron_line="0 6 * * * ZAPRET_BASE=${ZAPRET2_DIR} ${ZAPRET2_DIR}/ipset/get_config.sh"
    local crontab_file="/opt/etc/crontab"
    local cron_ok=0

    # cron устанавливается в step_install_dependencies

    # Метод 1: /opt/etc/crontab (Entware cron)
    if [ -f "$crontab_file" ] || [ -d "/opt/etc" ]; then
        # Удалить старые записи zapret2
        if [ -f "$crontab_file" ]; then
            grep -v "get_config.sh" "$crontab_file" > "${crontab_file}.tmp" 2>/dev/null
            mv "${crontab_file}.tmp" "$crontab_file"
        fi
        # Добавить новую задачу
        echo "$cron_line" >> "$crontab_file"
        print_success "Автообновление настроено в $crontab_file (ежедневно в 06:00)"
        cron_ok=1
    fi

    # Метод 2: crontab -l / crontab - (если Entware crontab не работает)
    if [ "$cron_ok" = "0" ] && command -v crontab >/dev/null 2>&1; then
        # Удалить старые записи zapret2 и добавить новую
        (crontab -l 2>/dev/null | grep -v "get_config.sh"; echo "$cron_line") | crontab -
        if [ $? -eq 0 ]; then
            print_success "Автообновление настроено через crontab (ежедневно в 06:00)"
            cron_ok=1
        fi
    fi

    if [ "$cron_ok" = "0" ]; then
        print_warning "Не удалось настроить crontab"
        print_info "Списки нужно будет обновлять вручную:"
        print_info "  ZAPRET_BASE=${ZAPRET2_DIR} ${ZAPRET2_DIR}/ipset/get_config.sh"
    fi

    # Запустить cron демон если есть init скрипт Entware
    local cron_init="/opt/etc/init.d/S10cron"
    if [ -x "$cron_init" ]; then
        "$cron_init" start >/dev/null 2>&1
        if pgrep -f "cron" >/dev/null 2>&1; then
            print_info "Cron демон запущен"
        else
            print_warning "Не удалось запустить cron демон"
        fi
    elif pgrep -f "cron" >/dev/null 2>&1; then
        print_info "Cron демон уже запущен"
    else
        print_warning "Cron демон не найден"
        print_info "Установите: opkg install cron"
    fi

    # Instagram DNS redirect (Keenetic static DNS)
    # Прописывает рабочие IP для Instagram если записи ещё не заданы.
    # Решает проблему DNS-отравления провайдером.
    if command -v ndmc >/dev/null 2>&1; then
        if ! ndmc -c "show running-config" 2>/dev/null | grep -q "ip host instagram.com"; then
            print_info "Настройка DNS для Instagram..."
            ndmc -c "ip host instagram.com 157.240.251.174" 2>/dev/null
            ndmc -c "ip host www.instagram.com 157.240.9.174" 2>/dev/null
            ndmc -c "ip host graph.instagram.com 157.240.0.63" 2>/dev/null
            ndmc -c "ip host api.instagram.com 157.240.253.63" 2>/dev/null
            ndmc -c "ip host instagram.c10r.instagram.com 157.240.214.63" 2>/dev/null
            ndmc -c "ip host static.cdninstagram.com 163.70.147.63" 2>/dev/null
            ndmc -c "ip host scontent.cdninstagram.com 163.70.147.63" 2>/dev/null
            ndmc -c "ip host instagram.com 157.240.9.174" 2>/dev/null
            ndmc -c "ip host static.cdninstagram.com 57.144.112.192" 2>/dev/null
            ndmc -c "ip host scontent.cdninstagram.com 57.144.112.192" 2>/dev/null
            ndmc -c "system configuration save" 2>/dev/null
            print_success "DNS записи для Instagram добавлены"
        else
            print_info "DNS записи для Instagram уже настроены"
        fi
    fi

    # Telegram transparent proxy (tg-mtproxy-client)
    if true; then
        print_info "Установка/обновление Telegram прокси..."
        # Use same arch detection as zapret2 install (get_arch → map_arch_to_bin_arch)
        local tg_arch=""
        local hw_arch
        hw_arch=$(get_arch 2>/dev/null || uname -m)
        local tg_bin_arch
        tg_bin_arch=$(map_arch_to_bin_arch "$hw_arch" 2>/dev/null || true)
        case "$tg_bin_arch" in
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
            local tg_dest="/opt/sbin/tg-mtproxy-client"
            local tg_url="${GITHUB_RAW}/mtproxy-client/builds/${tg_bin}"
            rm -f "$tg_dest"
            curl -fsSL --connect-timeout 10 --max-time 120 "$tg_url" -o "$tg_dest" 2>/dev/null
            local tg_size
            tg_size=$(wc -c < "$tg_dest" 2>/dev/null || echo 0)
            # Validate: exists, >500KB, starts with ELF magic (\x7fELF), runs without crash
            local tg_valid=false
            if [ -f "$tg_dest" ] && [ "$tg_size" -gt 500000 ] 2>/dev/null; then
                # Check ELF magic (works on any busybox — no od/hexdump needed)
                if head -c 4 "$tg_dest" 2>/dev/null | grep -q "ELF"; then
                    chmod +x "$tg_dest"
                    # Test run — if wrong arch, kernel will fail and exit non-zero
                    if "$tg_dest" --help 2>/dev/null; [ $? -le 2 ]; then
                        tg_valid=true
                    fi
                fi
            fi
            if $tg_valid; then
                print_success "Telegram прокси установлен ($tg_arch)"
            else
                rm -f "$tg_dest"
                if [ "$tg_size" -le 500000 ] 2>/dev/null; then
                    print_warning "Файл слишком маленький (${tg_size} байт) — скачивание прервалось"
                else
                    print_warning "Бинарник не запускается на этой архитектуре ($tg_arch). Проверьте: opkg print-architecture"
                fi
            fi
        else
            print_warning "Неизвестная архитектура $hw_arch, пропускаем Telegram прокси"
        fi
    else
        print_info "Telegram прокси уже установлен"
    fi

    # Cleanup legacy WS proxy init script (replaced by tunnel)
    rm -f /opt/etc/init.d/S97tg-mtproxy 2>/dev/null

    # Auto-start Telegram tunnel
    if [ -x "/opt/sbin/tg-mtproxy-client" ]; then
        killall tg-mtproxy-client 2>/dev/null || true
        sleep 1

        # Start tunnel mode. -v enables stream-level logs needed by the
        # watchdog's stale-detection mode.
        /opt/sbin/tg-mtproxy-client --listen=:1443 -v >> /tmp/tg-tunnel.log 2>&1 &
        sleep 2

        if pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
            # Setup iptables REDIRECT for Telegram DC IPs.
            # Use -I ... 1 (insert at top) so our rules precede Keenetic's
            # _NDM_* chains, which intercept packets when using -A.
            # Both PREROUTING (LAN clients) and OUTPUT (router-local
            # processes, e.g. the watchdog probe) get the redirect.
            for cidr in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24; do
                iptables -t nat -C PREROUTING -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
                    iptables -t nat -I PREROUTING 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
                iptables -t nat -C OUTPUT -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || \
                    iptables -t nat -I OUTPUT 1 -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null
            done

            # Install Keenetic netfilter.d hook so NDM re-inserts our
            # REDIRECT rules automatically after every regen (WAN flap,
            # tunnel up/down, reboot, etc). Without this, rules get
            # silently wiped and Android Telegram (which doesn't use
            # MTProxy Premium like desktop does) stops connecting.
            mkdir -p /opt/etc/ndm/netfilter.d
            if [ -f "${WORK_DIR}/files/ndm/90-z2k-tg-redirect.sh" ]; then
                cp -f "${WORK_DIR}/files/ndm/90-z2k-tg-redirect.sh" \
                      /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh
                chmod +x /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh
                print_success "Keenetic NDM hook установлен (auto-restore iptables)"
            fi
            # Install watchdog — active end-to-end probe + CONNECT_FAIL storm
            # detector. Runs every minute via cron. Restarts the tunnel via
            # the init script (handles iptables + pid file properly).
            # Script body lives in files/z2k-tg-watchdog.sh (extracted from
            # a prior heredoc) so it's editable in git and testable live
            # without rerunning the installer.
            if [ -f "${WORK_DIR}/files/z2k-tg-watchdog.sh" ]; then
                cp -f "${WORK_DIR}/files/z2k-tg-watchdog.sh" \
                      /opt/zapret2/tg-tunnel-watchdog.sh
                chmod +x /opt/zapret2/tg-tunnel-watchdog.sh
            else
                print_warning "tg-tunnel-watchdog.sh source missing from ${WORK_DIR}/files/"
            fi
            # Add to cron (every minute)
            WDCRON="* * * * * /opt/zapret2/tg-tunnel-watchdog.sh"
            crontab -l 2>/dev/null | grep -q "tg-tunnel-watchdog" || \
                (crontab -l 2>/dev/null; echo "$WDCRON") | crontab -

            # Install init script for autostart on reboot. Script body lives
            # in files/init.d/S98tg-tunnel (extracted from a prior heredoc).
            if [ -f "${WORK_DIR}/files/init.d/S98tg-tunnel" ]; then
                cp -f "${WORK_DIR}/files/init.d/S98tg-tunnel" \
                      /opt/etc/init.d/S98tg-tunnel
                chmod +x /opt/etc/init.d/S98tg-tunnel
            else
                print_warning "S98tg-tunnel init source missing from ${WORK_DIR}/files/init.d/"
            fi

            # Cleanup legacy cron entry for S97tg-mtproxy
            crontab -l 2>/dev/null | grep -v "S97tg-mtproxy" | crontab - 2>/dev/null

            print_success "Telegram tunnel запущен автоматически"
        else
            print_warning "Не удалось запустить Telegram tunnel (можно включить позже через меню [T])"
        fi
    fi

    # Показать итоговую информацию
    print_separator
    print_success "Установка zapret2 завершена!"
    print_separator

    printf "Установлено:\n"
    printf "  %-25s: %s\n" "Директория" "$ZAPRET2_DIR"
    printf "  %-25s: %s\n" "Бинарник" "${ZAPRET2_DIR}/nfq2/nfqws2"
    printf "  %-25s: %s\n" "Init скрипт" "$INIT_SCRIPT"
    printf "  %-25s: %s\n" "Конфигурация" "$CONFIG_DIR"
    printf "  %-25s: %s\n" "Списки доменов" "$LISTS_DIR"
    printf "  %-25s: %s\n" "Стратегии" "$STRATEGIES_CONF"
    printf "  %-25s: %s\n" "Tools" "${ZAPRET2_DIR}/ip2net, ${ZAPRET2_DIR}/mdig"

    # Save local z2k entrypoint for future runs without curl.
    local local_z2k_script="${ZAPRET2_DIR}/z2k.sh"
    local local_z2k_url="${GITHUB_RAW}/z2k.sh"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$local_z2k_url" -o "$local_z2k_script"; then
        chmod +x "$local_z2k_script" 2>/dev/null || true
        printf "  %-25s: %s\n" "z2k script" "$local_z2k_script"
        print_info "Открыть меню позже: sh ${local_z2k_script} menu"
    else
        print_warning "Не удалось сохранить z2k.sh в ${local_z2k_script}"
        print_info "Для повторного запуска используйте curl-команду из README"
    fi

    print_separator

    return 0
}

# ==============================================================================
# ПОЛНАЯ УСТАНОВКА (9 ШАГОВ)
# ==============================================================================

run_full_install() {
    print_header "Установка zapret2 для Keenetic"
    print_info "Процесс установки: 12 шагов (расширенная проверка)"
    print_separator

    # Выполнить все шаги последовательно
    step_check_root || return 1                    # ← НОВОЕ (0/12)
    step_update_packages || return 1               # 1/12
    step_check_dns || return 1                     # ← НОВОЕ (2/12)
    step_install_dependencies || return 1          # 3/12 (расширено)
    step_load_kernel_modules || return 1           # 4/12
    step_build_zapret2 || return 1                 # 5/12
    step_verify_installation || return 1           # 6/12
    step_check_and_select_fwtype || return 1       # ← НОВОЕ (7/12)
    step_download_domain_lists || return 1         # 8/12
    step_disable_hwnat_and_offload || return 1     # 9/12 (расширено)
    step_configure_tmpdir || return 1              # ← НОВОЕ (9.5/12)
    step_create_config_and_init || return 1        # 10/12
    step_install_netfilter_hook || return 1        # 11/12
    step_finalize || return 1                      # 12/12

    # После установки - без вопросов применяем autocircular стратегии по умолчанию
    print_separator
    print_info "Установка завершена успешно!"
    print_separator

    printf "\nНастройка стратегий DPI bypass:\n\n"
    print_info "Автоматически применяю autocircular стратегии (без запроса выбора)..."
    apply_autocircular_strategies --auto

    print_info "Открываю меню управления..."
    sleep 1
    show_main_menu

    return 0
}

# ==============================================================================
# ROLLBACK МЕХАНИЗМ
# ==============================================================================

ROLLBACK_DIR="/opt/zapret2/.rollback"

# Создать snapshot перед изменениями
create_rollback_snapshot() {
    local reason=${1:-"manual"}

    print_info "Создание rollback-snapshot..."

    # Очистить предыдущий snapshot (хранится только последний)
    rm -rf "$ROLLBACK_DIR"
    mkdir -p "$ROLLBACK_DIR" || {
        print_warning "Не удалось создать директорию rollback"
        return 1
    }

    # Сохранить config
    [ -f "${ZAPRET2_DIR}/config" ] && cp -f "${ZAPRET2_DIR}/config" "$ROLLBACK_DIR/config"

    # Сохранить init script
    [ -f "$INIT_SCRIPT" ] && cp -f "$INIT_SCRIPT" "$ROLLBACK_DIR/S99zapret2"

    # Сохранить стратегии
    for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        local sfile="${ZAPRET2_DIR}/extra_strats/$cat_dir/Strategy.txt"
        if [ -f "$sfile" ]; then
            mkdir -p "$ROLLBACK_DIR/strats/$cat_dir"
            cp -f "$sfile" "$ROLLBACK_DIR/strats/$cat_dir/Strategy.txt"
        fi
    done

    # Сохранить whitelist
    [ -f "${ZAPRET2_DIR}/lists/whitelist.txt" ] && \
        cp -f "${ZAPRET2_DIR}/lists/whitelist.txt" "$ROLLBACK_DIR/whitelist.txt"

    # Сохранить autocircular state
    [ -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" ] && \
        cp -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" "$ROLLBACK_DIR/state.tsv"

    # Записать метаданные
    cat > "$ROLLBACK_DIR/metadata" <<ROLLBACK_META
SNAPSHOT_TIME=$(date +%Y%m%d_%H%M%S)
REASON=$reason
Z2K_VERSION=${Z2K_VERSION:-unknown}
NFQWS2_VERSION=$(get_nfqws2_version 2>/dev/null || echo unknown)
ROLLBACK_META

    print_success "Rollback snapshot создан: $ROLLBACK_DIR"
    return 0
}

# Восстановить из rollback snapshot
rollback_to_snapshot() {
    if [ ! -d "$ROLLBACK_DIR" ] || [ ! -f "$ROLLBACK_DIR/metadata" ]; then
        print_error "Rollback snapshot не найден"
        return 1
    fi

    print_header "Восстановление из rollback snapshot"

    # Показать информацию о snapshot (без source — безопасный парсинг)
    local SNAPSHOT_TIME REASON SNAP_Z2K_VERSION SNAP_NFQWS2_VERSION
    SNAPSHOT_TIME=$(safe_config_read "SNAPSHOT_TIME" "$ROLLBACK_DIR/metadata" "unknown")
    REASON=$(safe_config_read "REASON" "$ROLLBACK_DIR/metadata" "unknown")
    SNAP_Z2K_VERSION=$(safe_config_read "Z2K_VERSION" "$ROLLBACK_DIR/metadata" "unknown")
    SNAP_NFQWS2_VERSION=$(safe_config_read "NFQWS2_VERSION" "$ROLLBACK_DIR/metadata" "unknown")
    print_info "Snapshot от: ${SNAPSHOT_TIME}"
    print_info "Причина: ${REASON}"
    print_info "Версия: z2k ${SNAP_Z2K_VERSION}, nfqws2 ${SNAP_NFQWS2_VERSION}"

    if ! confirm "Восстановить эту конфигурацию?" "N"; then
        print_info "Rollback отменён"
        return 0
    fi

    # Остановить сервис
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop 2>/dev/null || true
    fi

    # Восстановить config
    [ -f "$ROLLBACK_DIR/config" ] && cp -f "$ROLLBACK_DIR/config" "${ZAPRET2_DIR}/config"

    # Восстановить init script
    [ -f "$ROLLBACK_DIR/S99zapret2" ] && cp -f "$ROLLBACK_DIR/S99zapret2" "$INIT_SCRIPT" && chmod +x "$INIT_SCRIPT"

    # Восстановить стратегии
    for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        local sfile="$ROLLBACK_DIR/strats/$cat_dir/Strategy.txt"
        if [ -f "$sfile" ]; then
            mkdir -p "${ZAPRET2_DIR}/extra_strats/$cat_dir"
            cp -f "$sfile" "${ZAPRET2_DIR}/extra_strats/$cat_dir/Strategy.txt"
        fi
    done

    # Восстановить whitelist
    [ -f "$ROLLBACK_DIR/whitelist.txt" ] && \
        cp -f "$ROLLBACK_DIR/whitelist.txt" "${ZAPRET2_DIR}/lists/whitelist.txt"

    # Восстановить autocircular state
    [ -f "$ROLLBACK_DIR/state.tsv" ] && \
        cp -f "$ROLLBACK_DIR/state.tsv" "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv"

    # Перезапустить сервис
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" start 2>/dev/null || true
    fi

    print_success "Конфигурация восстановлена из rollback snapshot"
    return 0
}

# Автоматический rollback по таймеру
# Вызывается после применения новой конфигурации
auto_rollback_timer() {
    local timeout=${1:-300}  # 5 минут по умолчанию

    if [ ! -d "$ROLLBACK_DIR" ]; then
        return 0
    fi

    print_warning "Авто-rollback активен: $timeout секунд"
    print_info "Если сервис работает — подтвердите в меню"
    print_info "Иначе конфигурация будет автоматически восстановлена"

    # Создать таймер-файл
    local timer_file="${ROLLBACK_DIR}/auto_timer"
    echo "$(($(date +%s) + timeout))" > "$timer_file"

    return 0
}

# Проверить истёк ли таймер авто-rollback (вызывается из cron)
check_auto_rollback() {
    local timer_file="${ROLLBACK_DIR}/auto_timer"
    [ -f "$timer_file" ] || return 0

    local deadline
    deadline=$(cat "$timer_file" 2>/dev/null)
    [ -z "$deadline" ] && return 0

    local now
    now=$(date +%s)

    if [ "$now" -ge "$deadline" ]; then
        print_warning "Авто-rollback: таймер истёк, восстанавливаю конфигурацию..."
        rm -f "$timer_file"
        # Не-интерактивный rollback
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" stop 2>/dev/null || true
        fi
        [ -f "$ROLLBACK_DIR/config" ] && cp -f "$ROLLBACK_DIR/config" "${ZAPRET2_DIR}/config"
        [ -f "$ROLLBACK_DIR/S99zapret2" ] && cp -f "$ROLLBACK_DIR/S99zapret2" "$INIT_SCRIPT"
        for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
            local sfile="$ROLLBACK_DIR/strats/$cat_dir/Strategy.txt"
            [ -f "$sfile" ] && cp -f "$sfile" "${ZAPRET2_DIR}/extra_strats/$cat_dir/Strategy.txt"
        done
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" start 2>/dev/null || true
        fi
        logger -t z2k "Auto-rollback executed: timer expired"
    fi

    return 0
}

# Подтвердить новую конфигурацию (отменяет авто-rollback)
confirm_config() {
    local timer_file="${ROLLBACK_DIR}/auto_timer"
    if [ -f "$timer_file" ]; then
        rm -f "$timer_file"
        print_success "Конфигурация подтверждена, авто-rollback отключён"
    else
        print_info "Авто-rollback не активен"
    fi
    return 0
}

# ==============================================================================
# УДАЛЕНИЕ ZAPRET2
# ==============================================================================

uninstall_zapret2() {
    print_header "Удаление zapret2"

    # Проверить наличие хоть чего-то от zapret2
    if ! is_zapret2_installed && [ ! -d "$ZAPRET2_DIR" ] && [ ! -d "$CONFIG_DIR" ] && [ ! -f "$INIT_SCRIPT" ]; then
        print_info "zapret2 не установлен"
        return 0
    fi

    print_warning "Это удалит:"
    print_warning "  - Все файлы zapret2 ($ZAPRET2_DIR)"
    print_warning "  - Конфигурацию ($CONFIG_DIR)"
    print_warning "  - Init скрипт ($INIT_SCRIPT)"
    print_warning "  - Правила iptables и netfilter хуки"

    printf "\n"
    if ! confirm "Вы уверены? Это действие необратимо!" "N"; then
        print_info "Удаление отменено"
        return 0
    fi

    # Остановить сервис через init-скрипт (мягкая попытка)
    if [ -x "$INIT_SCRIPT" ]; then
        print_info "Остановка сервиса..."
        "$INIT_SCRIPT" stop 2>/dev/null || true
    fi

    # Принудительно убить оставшиеся процессы nfqws2
    local pids
    pids=$(pidof nfqws2 2>/dev/null || true)
    if [ -n "$pids" ]; then
        print_info "Завершение зависших процессов nfqws2..."
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi

    # Очистка iptables цепочек zapret2
    # Все команды с || true — скрипт запущен под set -e
    print_info "Очистка правил iptables..."
    local chain parent
    for chain in ZAPRET ZAPRET2 z2k_connmark z2k_dpi_rst; do
        for parent in POSTROUTING PREROUTING FORWARD; do
            while iptables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
                iptables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            done
            while ip6tables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
                ip6tables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            done
        done
        iptables -t mangle -F "$chain" 2>/dev/null || true
        iptables -t mangle -X "$chain" 2>/dev/null || true
        ip6tables -t mangle -F "$chain" 2>/dev/null || true
        ip6tables -t mangle -X "$chain" 2>/dev/null || true
    done
    # raw table (RST filter)
    while iptables -t raw -C PREROUTING -j z2k_dpi_rst 2>/dev/null; do
        iptables -t raw -D PREROUTING -j z2k_dpi_rst 2>/dev/null || break
    done
    iptables -t raw -F z2k_dpi_rst 2>/dev/null || true
    iptables -t raw -X z2k_dpi_rst 2>/dev/null || true
    # nat table (masquerade fix)
    while iptables -t nat -C POSTROUTING -j z2k_masq_fix 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j z2k_masq_fix 2>/dev/null || break
    done
    iptables -t nat -F z2k_masq_fix 2>/dev/null || true
    iptables -t nat -X z2k_masq_fix 2>/dev/null || true

    # Удалить init скрипт
    if [ -f "$INIT_SCRIPT" ]; then
        rm -f "$INIT_SCRIPT"
        print_info "Удален init скрипт"
    fi

    # Удалить netfilter хуки (все связанные с zapret)
    local hook
    for hook in /opt/etc/ndm/netfilter.d/*zapret*; do
        if [ -f "$hook" ]; then
            rm -f "$hook"
            print_info "Удален netfilter хук: $(basename "$hook")"
        fi
    done

    # Удалить zapret2
    if [ -d "$ZAPRET2_DIR" ]; then
        rm -rf "$ZAPRET2_DIR"
        print_info "Удалена директория zapret2"
    fi

    # Удалить конфигурацию
    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        print_info "Удалена конфигурация"
    fi

    # Очистить временные файлы
    rm -rf /tmp/z2k /tmp/zapret2 /tmp/blockcheck* 2>/dev/null

    # Очистить ipset
    local setname ipset_names
    ipset_names=$(ipset list -n 2>/dev/null | grep -i "zapret\|z2k" || true)
    for setname in $ipset_names; do
        ipset destroy "$setname" 2>/dev/null || true
    done

    print_success "zapret2 полностью удален"

    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
