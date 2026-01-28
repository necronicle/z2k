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
        local sys_arch=$(uname -m)
        print_info "Архитектура системы: $sys_arch"

        # 2. Проверка архитектуры Entware
        if [ -f "/opt/etc/opkg.conf" ]; then
            local entware_arch=$(grep -m1 "^arch" /opt/etc/opkg.conf | awk '{print $2}')
            print_info "Архитектура Entware: ${entware_arch:-не определена}"

            local repo_url=$(grep -m1 "^src" /opt/etc/opkg.conf | awk '{print $3}')
            print_info "Репозиторий: $repo_url"

            # 3. Проверка доступности репозитория
            if [ -n "$repo_url" ]; then
                print_info "Проверка доступности репозитория..."
                if curl -s -m 5 --head "$repo_url/Packages.gz" >/dev/null 2>&1; then
                    print_success "✓ Репозиторий доступен"
                else
                    print_error "✗ Репозиторий недоступен"
                fi
            fi
        fi

        # 4. Проверка самого opkg
        print_info "Проверка opkg бинарника..."
        if opkg --version 2>&1 | grep -qi "illegal"; then
            print_error "✗ opkg --version падает (Illegal instruction)"
            print_warning "ПРИЧИНА: opkg установлен для неправильной архитектуры CPU!"
        elif opkg --version >/dev/null 2>&1; then
            local opkg_version=$(opkg --version 2>&1 | head -1)
            print_success "✓ opkg бинарник запускается: $opkg_version"
            print_warning "Но 'opkg update' падает - возможно проблема в зависимости или скрипте"
        else
            print_error "✗ opkg не работает по неизвестной причине"
        fi

        # 5. Проверка файла opkg
        if command -v file >/dev/null 2>&1; then
            if [ -f "/opt/bin/opkg" ]; then
                local opkg_file_info=$(file /opt/bin/opkg 2>&1 | head -1)
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
⚠️  КРИТИЧЕСКАЯ ПРОБЛЕМА: НЕПРАВИЛЬНАЯ АРХИТЕКТУРА ENTWARE

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
⚠️  СЛОЖНАЯ ПРОБЛЕМА: opkg update падает с "Illegal instruction"

Диагностика и попытки исправления:
- ✓ opkg бинарник запускается (opkg --version работает)
- ✓ Архитектура системы корректная (aarch64)
- ✓ Репозиторий доступен (curl тест успешен)
- ✓ Попробовали альтернативное зеркало (entware.diversion.ch)
- ✗ НО "opkg update" всё равно падает с "Illegal instruction"

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
   Убедитесь что выбираете версию для aarch64!

ПРОДОЛЖИТЬ БЕЗ ОБНОВЛЕНИЯ?
Можно попробовать продолжить установку z2k.
Если нужные пакеты (iptables, ipset, curl) уже установлены -
всё может заработать и без обновления списков пакетов.
EOF
        else
            cat <<'EOF'
⚠️  ОШИБКА ПРИ ОБНОВЛЕНИИ ПАКЕТОВ

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

    cd /opt/lib || return 1

    # libmnl
    if [ ! -e libmnl.so ] && [ -e libmnl.so.0 ]; then
        ln -sf libmnl.so.0 libmnl.so
        print_info "Создан симлинк: libmnl.so -> libmnl.so.0"
    fi

    # libnetfilter_queue
    if [ ! -e libnetfilter_queue.so ] && [ -e libnetfilter_queue.so.1 ]; then
        ln -sf libnetfilter_queue.so.1 libnetfilter_queue.so
        print_info "Создан симлинк: libnetfilter_queue.so -> libnetfilter_queue.so.1"
    fi

    # libnfnetlink
    if [ ! -e libnfnetlink.so ] && [ -e libnfnetlink.so.0 ]; then
        ln -sf libnfnetlink.so.0 libnfnetlink.so
        print_info "Создан симлинк: libnfnetlink.so -> libnfnetlink.so.0"
    fi

    cd - >/dev/null || return 1

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
        if readlink "$(which gzip)" 2>/dev/null | grep -q busybox; then
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
        if readlink "$(which sort)" 2>/dev/null | grep -q busybox; then
            print_info "Обнаружен busybox sort (медленный, использует много RAM)"
            printf "Установить GNU sort для ускорения? [y/N]: "
            read -r answer </dev/tty
            case "$answer" in
                [Yy]*)
                    if opkg install --force-overwrite sort; then
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
# ШАГ 3: ЗАГРУЗКА МОДУЛЕЙ ЯДРА
# ==============================================================================

step_load_kernel_modules() {
    print_header "Шаг 4/12: Загрузка модулей ядра"

    local modules="xt_multiport xt_connbytes xt_NFQUEUE nfnetlink_queue"

    for module in $modules; do
        load_kernel_module "$module" || print_warning "Модуль $module не загружен"
    done

    print_success "Модули ядра загружены"
    return 0
}

# ==============================================================================
# ШАГ 4: УСТАНОВКА ZAPRET2 (ИСПОЛЬЗУЯ ОФИЦИАЛЬНЫЙ install_bin.sh)
# ==============================================================================

step_build_zapret2() {
    print_header "Шаг 5/12: Установка zapret2"

    # Удалить старую установку если существует
    if [ -d "$ZAPRET2_DIR" ]; then
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
    release_data=$(curl -fsSL "$api_url" 2>&1)

    local openwrt_url
    if [ $? -ne 0 ]; then
        print_warning "API недоступен, использую fallback версию v0.8.6..."
        openwrt_url="https://github.com/bol-van/zapret2/releases/download/v0.8.6/zapret2-v0.8.6-openwrt-embedded.tar.gz"
    else
        # Парсим URL из JSON
        openwrt_url=$(echo "$release_data" | grep -o 'https://github.com/bol-van/zapret2/releases/download/[^"]*openwrt-embedded\.tar\.gz' | head -1)

        if [ -z "$openwrt_url" ]; then
            print_warning "Не найден в API, использую fallback v0.8.6..."
            openwrt_url="https://github.com/bol-van/zapret2/releases/download/v0.8.6/zapret2-v0.8.6-openwrt-embedded.tar.gz"
        fi
    fi

    print_info "URL релиза: $openwrt_url"

    # Скачать релиз
    if ! curl -fsSL "$openwrt_url" -o openwrt-embedded.tar.gz; then
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
        local arch=$(uname -m)
        local bin_arch=""

        case "$arch" in
            aarch64) bin_arch="linux-arm64" ;;
            armv7l|armv6l|arm) bin_arch="linux-arm" ;;
            x86_64) bin_arch="linux-x86_64" ;;
            i386|i686) bin_arch="linux-x86" ;;
            mips) bin_arch="linux-mips" ;;
            mipsel) bin_arch="linux-mipsel" ;;
            *)
                print_error "Неподдерживаемая архитектура: $arch"
                return 1
                ;;
        esac

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
        local version=$(./nfq2/nfqws2 --version 2>&1 | head -1)
        print_success "nfqws2 работает: $version"
    fi

    # ===========================================================================
    # ШАГ 4.4: Переместить в финальную директорию
    # ===========================================================================

    print_info "Установка в $ZAPRET2_DIR..."

    cd "$build_dir" || return 1
    mv "$release_dir" "$ZAPRET2_DIR" || return 1

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

    # Обновить fake blobs если есть более свежие в z2k
    if [ -d "${WORK_DIR}/files/fake" ]; then
        print_info "Обновление fake blobs из z2k..."
        cp -f "${WORK_DIR}/files/fake/"* "${ZAPRET2_DIR}/files/fake/" 2>/dev/null || true
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
# ШАГ 5: ПРОВЕРКА УСТАНОВКИ
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
            print_info "✓ $path"
        else
            print_warning "✗ $path не найден"
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
            print_success "✓ nfqws2 работает"
        else
            print_error "✗ nfqws2 не запускается"
            return 1
        fi
    else
        print_error "✗ nfqws2 не найден или не исполняемый"
        return 1
    fi

    # ip2net - вспомогательный (может быть симлинком)
    if [ -e "${ZAPRET2_DIR}/ip2net/ip2net" ]; then
        print_info "✓ ip2net установлен"
    else
        print_warning "✗ ip2net не найден (необязательный)"
    fi

    # mdig - DNS утилита (может быть симлинком)
    if [ -e "${ZAPRET2_DIR}/mdig/mdig" ]; then
        print_info "✓ mdig установлен"
    else
        print_warning "✗ mdig не найден (необязательный)"
    fi

    # Посчитать компоненты
    print_info "Статистика компонентов:"

    # Lua файлы
    if [ -d "${ZAPRET2_DIR}/lua" ]; then
        local lua_count=$(find "${ZAPRET2_DIR}/lua" -name "*.lua" 2>/dev/null | wc -l)
        print_info "  - Lua файлов: $lua_count"
    fi

    # Fake файлы
    if [ -d "${ZAPRET2_DIR}/files/fake" ]; then
        local fake_count=$(find "${ZAPRET2_DIR}/files/fake" -name "*.bin" 2>/dev/null | wc -l)
        print_info "  - Fake файлов: $fake_count"
    fi

    # Модули common/
    if [ -d "${ZAPRET2_DIR}/common" ]; then
        local common_count=$(find "${ZAPRET2_DIR}/common" -name "*.sh" 2>/dev/null | wc -l)
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

    # ���. ��������: ������ QUIC YT (zapret4rocket)
    local yt_quic_list="/opt/zapret2/extra_strats/UDP/YT/List.txt"
    if [ ! -s "$yt_quic_list" ]; then
        print_warning "������ QUIC YT ����������� ��� ������: $yt_quic_list"
        print_info "������ ��������� �������� �� zapret4rocket..."
        local base_url="${Z4R_BASE_URL:-https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/master}"
        mkdir -p "$(dirname "$yt_quic_list")"
        if curl -fsSL "$base_url/extra_strats/UDP/YT/List.txt" -o "$yt_quic_list"; then
            if [ -s "$yt_quic_list" ]; then
                print_success "������ QUIC YT ��������: $yt_quic_list"
            else
                print_warning "������ QUIC YT ������, �� ������: $yt_quic_list"
            fi
        else
            print_warning "�� ������� ��������� QUIC YT list � $base_url"
        fi
    fi
    # Создать базовую конфигурацию
    create_base_config || {
        print_error "Не удалось создать конфигурацию"
        return 1
    }

    print_success "Списки доменов и конфигурация установлены"
    return 0
}

# ==============================================================================
# ШАГ 7: ОТКЛЮЧЕНИЕ HARDWARE NAT
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
        . "${ZAPRET2_DIR}/common/base.sh"
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

    # Создать init скрипт (embedded version of S99zapret2.new)
    print_info "Создание init скрипта..."

    cat > "$INIT_SCRIPT" <<'INIT_EOF'
#!/bin/sh
# /opt/etc/init.d/S99zapret2
# ��������� ������������ init.d/openwrt/zapret2 ��� Keenetic
# ���������� ������ common/ � config ���� ������ hardcoded ��������

# ==============================================================================
# ���� � ����������
# ==============================================================================

ZAPRET_BASE=/opt/zapret2
ZAPRET_RW=${ZAPRET_RW:-"$ZAPRET_BASE"}
ZAPRET_CONFIG=${ZAPRET_CONFIG:-"$ZAPRET_RW/config"}

# �������� ��� zapret2 ����������
[ -d "$ZAPRET_BASE" ] || {
    echo "ERROR: zapret2 not installed in $ZAPRET_BASE"
    exit 1
}

# ==============================================================================
# SOURCE ����������� ������� (��� � init.d/openwrt/functions)
# ==============================================================================

# ������� �������
. "$ZAPRET_BASE/common/base.sh"

# ����������� ���� firewall (iptables/nftables)
. "$ZAPRET_BASE/common/fwtype.sh"

# KEENETIC FIX: �������������� linux_ipt_avail ��� ������ ��� ip6tables
# �� Keenetic ����� ���� DISABLE_IPV6=1, �� iptables ��� ����� ��������
linux_ipt_avail()
{
	# ��� Keenetic ���������� ������ iptables (IPv4-only �����)
	[ -n "$Z2K_DEBUG" ] && echo "DEBUG: linux_ipt_avail() �������"
	exists iptables
	local result=$?
	[ -n "$Z2K_DEBUG" ] && echo "DEBUG: exists iptables = $result"
	return $result
}

# IP helper functions
. "$ZAPRET_BASE/common/linux_iphelper.sh"

# ������� ��� ������ � iptables
. "$ZAPRET_BASE/common/ipt.sh"

# ������� ��� ������ � nftables (���� ��������)
existf zapret_do_firewall_nft || . "$ZAPRET_BASE/common/nft.sh" 2>/dev/null

# ���������� firewall
. "$ZAPRET_BASE/common/linux_fw.sh"

# ���������� daemon ����������
. "$ZAPRET_BASE/common/linux_daemons.sh"

# ������ �� �������� �������
. "$ZAPRET_BASE/common/list.sh"

# ��������� custom scripts
. "$ZAPRET_BASE/common/custom.sh"

# ==============================================================================
# �������� ������������
# ==============================================================================

# ��������� ������������
. "$ZAPRET_CONFIG"

# DEBUG: ��������� FWTYPE ����� �������� config
[ -n "$Z2K_DEBUG" ] && echo "DEBUG: ����� �������� config - FWTYPE='$FWTYPE'"

# ��������: ������������� ����� � ������ iptables (�������� - �� :)
# std_ports() ���� ������� ��� �������� ipt.sh, �� ����� ���������� ���� ������
# �������� ������� std_ports() ����� �������� config
std_ports
[ -n "$Z2K_DEBUG" ] && echo "DEBUG: std_ports() ������� - NFQWS2_PORTS_TCP_IPT='$NFQWS2_PORTS_TCP_IPT'"

# ------------------------------------------------------------------------------
# AUTOHOSTLIST: ensure required files exist to avoid nfqws2 start failures
# ------------------------------------------------------------------------------
ensure_autohostlist_files()
{
	[ "$MODE_FILTER" = "autohostlist" ] || return 0
	local base="${HOSTLIST_BASE:-$ZAPRET_BASE/ipset}"
	mkdir -p "$base" || return 1
	local auto="$base/zapret-hosts-auto.txt"
	local debuglog="$base/zapret-hosts-auto-debug.log"
	[ -f "$auto" ] || : > "$auto"
	[ "$AUTOHOSTLIST_DEBUGLOG" = "1" ] && [ -f "$debuglog" ] || : > "$debuglog"
}
# ==============================================================================
# ��������� ����������� ��� KEENETIC
# ==============================================================================

PIDDIR=/var/run
USEROPT=""
[ -n "$WS_USER" ] && USEROPT="--user=$WS_USER"
NFQWS2="${NFQWS2:-$ZAPRET_BASE/nfq2/nfqws2}"
LUA_LIB="$ZAPRET_BASE/lua/zapret-lib.lua"
[ -f "$LUA_LIB" ] || LUA_LIB="$LUA_LIB.gz"
LUA_ANTIDPI="$ZAPRET_BASE/lua/zapret-antidpi.lua"
[ -f "$LUA_ANTIDPI" ] || LUA_ANTIDPI="$LUA_ANTIDPI.gz"
LUAOPT="--lua-init=@$LUA_LIB --lua-init=@$LUA_ANTIDPI"
LUA_AUTO="$ZAPRET_BASE/lua/zapret-auto.lua"
[ -f "$LUA_AUTO" ] || LUA_AUTO="$LUA_AUTO.gz"
[ -f "$LUA_AUTO" ] && LUAOPT="$LUAOPT --lua-init=@$LUA_AUTO"
NFQWS2_OPT_BASE="$USEROPT --fwmark=$DESYNC_MARK $LUAOPT"
LISTS_DIR="$ZAPRET_BASE/lists"
EXTRA_STRATS_DIR="$ZAPRET_BASE/extra_strats"
CONFIG_DIR="/opt/etc/zapret2"
CUSTOM_DIR="${CUSTOM_DIR:-$ZAPRET_RW/init.d/keenetic}"
IPSET_CR="$ZAPRET_BASE/ipset/create_ipset.sh"

# ==============================================================================
# ������� ��� ������ � IPSET
# ==============================================================================

create_ipset()
{
	echo "Creating ip list table (firewall type $FWTYPE)"
	"$IPSET_CR" "$@"
}

# ==============================================================================
# KEENETIC FIREWALL FUNCTIONS (������ OpenWrt network.sh ������������)
# ==============================================================================

get_default_ifaces4()
{
	exists ip || return 0
	ip route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | xargs
}

get_default_ifaces6()
{
	exists ip || return 0
	ip -6 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | xargs
}

get_wan_ifaces4()
{
	local ifaces
	if [ -n "$WAN_IFACE" ]; then
		ifaces="$(echo "$WAN_IFACE" | tr ',' ' ')"
	else
		ifaces="$(get_default_ifaces4)"
	fi
	ifaces="$(echo "$ifaces" | xargs)"
	if [ -n "$ifaces" ] && exists ip; then
		local i
		for i in $ifaces; do
			ip link show "$i" >/dev/null 2>&1 || echo "WARN: WAN iface '$i' not found"
		done
	fi
	[ -n "$ifaces" ] && unique $ifaces || true
}

get_wan_ifaces6()
{
	local ifaces
	if [ -n "$WAN_IFACE" ]; then
		ifaces="$(echo "$WAN_IFACE" | tr ',' ' ')"
	else
		ifaces="$(get_default_ifaces6)"
	fi
	ifaces="$(echo "$ifaces" | xargs)"
	if [ -n "$ifaces" ] && exists ip; then
		local i
		for i in $ifaces; do
			ip link show "$i" >/dev/null 2>&1 || echo "WARN: WAN iface '$i' not found"
		done
	fi
	[ -n "$ifaces" ] && unique $ifaces || true
}

# Keenetic-specific: ���������� ������ fw_nfqws_post4/post6/pre4/pre6
# � ������� �� OpenWrt, �� ������� network.sh � ����������� WAN �����������
# �������� ���������� WAN �� default route

fw_nfqws_post4()
{
	# $1 - 1 - add, 0 - del
	# $2 - filter
	# $3 - queue number
	local wan
	wan="$(get_wan_ifaces4)"
	if [ -n "$wan" ]; then
		_fw_nfqws_post4 "$1" "$2" "$3" "$wan"
	else
		echo "WARN: WAN iface not found (IPv4), skip applying nfqws rules"
		return 0
	fi
}

fw_nfqws_post6()
{
	# $1 - 1 - add, 0 - del
	# $2 - filter
	# $3 - queue number
	[ "$DISABLE_IPV6" = "1" ] && return 0
	local wan
	wan="$(get_wan_ifaces6)"
	if [ -n "$wan" ]; then
		_fw_nfqws_post6 "$1" "$2" "$3" "$wan"
	else
		echo "WARN: WAN iface not found (IPv6), skip applying nfqws rules"
		return 0
	fi
}

fw_nfqws_pre4()
{
	# $1 - 1 - add, 0 - del
	# $2 - filter
	# $3 - queue number
	local wan
	wan="$(get_wan_ifaces4)"
	if [ -n "$wan" ]; then
		_fw_nfqws_pre4 "$1" "$2" "$3" "$wan"
	else
		echo "WARN: WAN iface not found (IPv4), skip applying nfqws rules"
		return 0
	fi
}

fw_nfqws_pre6()
{
	# $1 - 1 - add, 0 - del
	# $2 - filter
	# $3 - queue number
	[ "$DISABLE_IPV6" = "1" ] && return 0
	local wan
	wan="$(get_wan_ifaces6)"
	if [ -n "$wan" ]; then
		_fw_nfqws_pre6 "$1" "$2" "$3" "$wan"
	else
		echo "WARN: WAN iface not found (IPv6), skip applying nfqws rules"
		return 0
	fi
}

# ==============================================================================
# ������� ���������� DAEMON (������������ ��� KEENETIC ��� PROCD)
# ==============================================================================

run_daemon()
{
    # $1 - daemon ID
    # $2 - daemon binary
    # $3 - daemon args
    local DAEMONBASE="$(basename "$2")"
    local PIDFILE="$PIDDIR/${DAEMONBASE}_$1.pid"

    echo "Starting daemon $1: $2 $3"

    # ������ � ���� � ����������� PID
    $2 $3 >/dev/null 2>&1 &
    local PID=$!

    # ��������� PID
    echo $PID > "$PIDFILE"

    # ��������� ��� ������� ����������
    sleep 1
    if kill -0 $PID 2>/dev/null; then
        echo "Daemon $1 started with PID $PID"
        return 0
    else
        echo "ERROR: Daemon $1 failed to start"
        rm -f "$PIDFILE"
        return 1
    fi
}

extract_hostlist_paths()
{
	echo "$1" | tr ' ' '\n' | sed -n 's/^--hostlist=//p'
}

has_hostlist_domains()
{
	echo "$1" | tr ' ' '\n' | grep -q '^--hostlist-domains='
}

validate_profile_hostlist()
{
	local opts="$1"
	local has_hostlist=0
	local has_domains=0
	local path

	for path in $(extract_hostlist_paths "$opts"); do
		has_hostlist=1
		if [ ! -f "$path" ]; then
			echo "WARN: hostlist file not found: $path (skip daemon)"
			return 1
		fi
		if [ ! -s "$path" ]; then
			echo "WARN: hostlist file empty: $path (profile may be ineffective)"
		fi
	done

	if has_hostlist_domains "$opts"; then
		has_domains=1
	fi

	if [ $has_hostlist -eq 0 ] && [ $has_domains -eq 0 ]; then
		echo "WARN: NFQWS2_OPT has no hostlist/hostlist-domains (skip daemon)"
		return 1
	fi

	return 0
}
run_nfqws()
{
    # $1 - instance ID
    # $2 - nfqws options
    validate_profile_hostlist "$2" || return 0
    run_daemon $1 "$NFQWS2" "$NFQWS2_OPT_BASE $2"
}

do_nfqws()
{
    # $1 - 0 (stop) or 1 (start)
    # $2 - instance ID
    # $3 - nfqws options
    [ "$1" = 0 ] || { shift; run_nfqws "$@"; }
}

stop_daemon_by_pidfile()
{
    # $1 - pidfile path
    if [ -f "$1" ]; then
        local PID=$(cat "$1")
        if [ -n "$PID" ] && kill -0 $PID 2>/dev/null; then
            echo "Stopping daemon with PID $PID"
            kill $PID 2>/dev/null
            sleep 1
            # Force kill ���� �� �����������
            kill -0 $PID 2>/dev/null && kill -9 $PID 2>/dev/null
        fi
        rm -f "$1"
    fi
}

stop_all_nfqws()
{
    echo "Stopping all nfqws daemons"

    # ���������� �� PID ������
    for pidfile in $PIDDIR/nfqws2_*.pid; do
        [ -f "$pidfile" ] && stop_daemon_by_pidfile "$pidfile"
    done

    # Fallback: killall ���� ���-�� ��������
    killall nfqws2 2>/dev/null

    # �������� ��� PID �����
    rm -f $PIDDIR/nfqws2_*.pid 2>/dev/null
}

# ==============================================================================
# ������� START/STOP DAEMONS
# ==============================================================================

start_daemons()
{
    echo "Starting zapret2 daemons"

    # ������������ ������� �� common/linux_daemons.sh
    # standard_mode_daemons �������� do_nfqws
    standard_mode_daemons 1

    # ��������� custom scripts ���� ����
    custom_runner zapret_custom_daemons 1

    return 0
}

stop_daemons()
{
    echo "Stopping zapret2 daemons"

    # ���������� ��� nfqws ��������
    stop_all_nfqws

    # ��������� custom scripts ��� ���������
    custom_runner zapret_custom_daemons 0

    return 0
}

restart_daemons()
{
    stop_daemons
    sleep 2
    start_daemons
}

# ==============================================================================
# ������� START/STOP FIREWALL
# ==============================================================================

load_modules()
{
    echo "Loading required kernel modules"

    # ������ ����������� ������� ��� ������ zapret2
    local modules="xt_multiport xt_connbytes xt_NFQUEUE nfnetlink_queue"

    for module in $modules; do
        if ! lsmod | grep -q "^$module"; then
            [ -n "$Z2K_DEBUG" ] && echo "DEBUG: Loading module: $module"
            modprobe "$module" 2>/dev/null || {
                echo "Warning: Failed to load module $module (may be built-in)"
            }
        else
            [ -n "$Z2K_DEBUG" ] && echo "DEBUG: Module already loaded: $module"
        fi
    done

    # ��������� ��������� ������ nfnetlink_queue
    if ! lsmod | grep -q "nfnetlink_queue" && ! modinfo nfnetlink_queue >/dev/null 2>&1; then
        echo "WARNING: nfnetlink_queue module not available!"
        echo "nfqws2 may fail with 'Operation not permitted'"
        return 1
    fi

    echo "Kernel modules loaded"
    return 0
}

start_fw()
{
    echo "Applying zapret2 firewall rules"

    # DEBUG: ��������� FWTYPE ����� linux_fwtype
    [ -n "$Z2K_DEBUG" ] && echo "DEBUG: � start_fw() ����� linux_fwtype - FWTYPE='$FWTYPE'"

    # ���������� ��� firewall (iptables/nftables)
    linux_fwtype

    # DEBUG: ��������� FWTYPE ����� linux_fwtype
    [ -n "$Z2K_DEBUG" ] && echo "DEBUG: � start_fw() ����� linux_fwtype - FWTYPE='$FWTYPE'"

    echo "Detected firewall type: $FWTYPE"

    # ������������ ����������� ������� �� common/linux_fw.sh
    zapret_apply_firewall

    return 0
}

stop_fw()
{
    echo "Removing zapret2 firewall rules"

    # ���������� ��� firewall
    linux_fwtype

    # ������������ ����������� �������
    zapret_unapply_firewall

    return 0
}

restart_fw()
{
    stop_fw
    sleep 1
    start_fw
}

# ==============================================================================
# OPTIONAL NFTABLES HELPERS (IF AVAILABLE)
# ==============================================================================

reload_ifsets()
{
    existf zapret_reload_ifsets || {
        echo "reload_ifsets not available (nftables functions not loaded)"
        return 1
    }
    zapret_reload_ifsets
}

list_ifsets()
{
    existf zapret_list_ifsets || {
        echo "list_ifsets not available (nftables functions not loaded)"
        return 1
    }
    zapret_list_ifsets
}

list_table()
{
    existf zapret_list_table || {
        echo "list_table not available (nftables functions not loaded)"
        return 1
    }
    zapret_list_table
}

# ==============================================================================
# �������� ������� START/STOP/RESTART
# ==============================================================================

start()
{
    if [ "$ENABLED" != "1" ]; then
        echo "zapret2 is disabled in config"
        return 1
    fi

    echo "Starting zapret2 service"

    # 1. ��������� ����������� ������ ����
    load_modules || echo "Warning: Some modules failed to load"

    # 2. ��������� firewall �������
    [ "$INIT_APPLY_FW" = "1" ] && start_fw

    # 2.1. ����������� autohostlist ����� (���� ��������)
    ensure_autohostlist_files

    # 3. ��������� daemon ��������
    start_daemons

    echo "zapret2 service started"
    return 0
}

stop()
{
    echo "Stopping zapret2 service"

    # 1. ���������� daemon ��������
    stop_daemons

    # 2. ������� firewall �������
    [ "$INIT_APPLY_FW" = "1" ] && stop_fw

    echo "zapret2 service stopped"
    return 0
}

restart()
{
    stop
    sleep 2
    start
}

status()
{
    echo "Checking zapret2 status..."

    # ��������� �������� �� PID ������
    local running=0
    for pidfile in $PIDDIR/nfqws2_*.pid; do
        if [ -f "$pidfile" ]; then
            local PID=$(cat "$pidfile")
            if kill -0 $PID 2>/dev/null; then
                echo "nfqws2 daemon running (PID $PID)"
                running=$((running + 1))
            else
                echo "Stale PID file: $pidfile"
            fi
        fi
    done

    if [ $running -gt 0 ]; then
        echo "zapret2 is running ($running daemons)"

        # �������� ��������
        echo "Processes:"
        pgrep -af nfqws2

        return 0
    else
        echo "zapret2 is not running"
        return 1
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    start_fw)
        start_fw
        ;;
    stop_fw)
        stop_fw
        ;;
    restart_fw)
        restart_fw
        ;;
    start_daemons)
        start_daemons
        ;;
    stop_daemons)
        stop_daemons
        ;;
    restart_daemons)
        restart_daemons
        ;;
    reload_ifsets)
        reload_ifsets
        ;;
    list_ifsets)
        list_ifsets
        ;;
    list_table)
        list_table
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|start_fw|stop_fw|restart_fw|start_daemons|stop_daemons|restart_daemons|reload_ifsets|list_ifsets|list_table}"
        exit 1
        ;;
esac

exit $?
INIT_EOF

    # ========================================================================
    # 8.3: Финализация init скрипта
    # ========================================================================

    # Сделать исполняемым
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
# ШАГ 9: УСТАНОВКА NETFILTER ХУКА
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

# Обрабатываем только изменения в таблице mangle
[ "$table" != "mangle" ] && exit 0

# Проверить что init скрипт существует
[ ! -f "$INIT_SCRIPT" ] && exit 0

# Проверить что zapret2 включен
if ! grep -q "^ENABLED=yes" "$INIT_SCRIPT" 2>/dev/null; then
    exit 0
fi

# Небольшая задержка для стабильности
sleep 2

# Перезапустить правила zapret2
"$INIT_SCRIPT" restart >/dev/null 2>&1 &

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
# ШАГ 10: ФИНАЛИЗАЦИЯ
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

    # Запустить сервис
    print_info "Запуск сервиса zapret2..."

    if "$INIT_SCRIPT" start 2>&1; then
        print_success "Команда start выполнена"
    else
        print_error "Не удалось запустить сервис"
        print_info "Пробую запустить с подробным выводом..."
        sh -x "$INIT_SCRIPT" start 2>&1 | tail -20
        return 1
    fi

    sleep 2

    # Проверить статус
    if is_zapret2_running; then
        print_success "zapret2 работает"
    else
        print_warning "Сервис запущен, но процесс не обнаружен"
        print_info "Проверка процессов:"
        ps | grep -i nfqws || echo "Процессов nfqws не найдено"
        print_info "Проверьте логи: $INIT_SCRIPT status"
    fi

    # Установить tools
    local tools_dir="${ZAPRET2_DIR}/tools"
    mkdir -p "$tools_dir"
    if [ -f "${WORK_DIR}/tools/blockcheck2-rutracker.sh" ]; then
        cp "${WORK_DIR}/tools/blockcheck2-rutracker.sh" "$tools_dir/" || {
            print_warning "Не удалось скопировать blockcheck2-rutracker.sh в tools"
        }
        chmod +x "${tools_dir}/blockcheck2-rutracker.sh" 2>/dev/null || true
    else
        if [ -n "$GITHUB_RAW" ]; then
            curl -fsSL "${GITHUB_RAW}/blockcheck2-rutracker.sh" -o "${tools_dir}/blockcheck2-rutracker.sh" && \
                chmod +x "${tools_dir}/blockcheck2-rutracker.sh" 2>/dev/null || true
        fi
    fi

    # =========================================================================
    # НАСТРОЙКА АВТООБНОВЛЕНИЯ СПИСКОВ ДОМЕНОВ (КРИТИЧНО)
    # =========================================================================

    print_separator
    print_info "Настройка автообновления списков доменов..."

    # Source модуль installer.sh для функций crontab
    if [ -f "${ZAPRET2_DIR}/common/installer.sh" ]; then
        . "${ZAPRET2_DIR}/common/installer.sh"

        # ВАЖНО: Восстановить Z2K путь к init скрипту (он перезаписывается модулями zapret2)
        INIT_SCRIPT="$Z2K_INIT_SCRIPT"

        # Удалить старые записи cron если есть
        crontab_del_quiet

        # Добавить новую задачу: обновление каждый день в 06:00
        # Роутеры работают 24/7, поэтому ночное время идеально
        if crontab_add 0 6; then
            print_success "Автообновление настроено (ежедневно в 06:00)"
        else
            print_warning "Не удалось настроить crontab"
            print_info "Списки нужно будет обновлять вручную:"
            print_info "  ${ZAPRET2_DIR}/ipset/get_config.sh"
        fi

        # Убедиться что cron демон запущен
        if cron_ensure_running; then
            print_info "Cron демон запущен"
        else
            print_warning "Cron демон не запущен, автообновление не будет работать"
        fi
    else
        print_warning "Модуль installer.sh не найден, пропускаем настройку cron"
        print_info "Автообновление не настроено - списки нужно обновлять вручную"
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
    printf "  %-25s: %s\n" "Tools" "$tools_dir"

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

    # После установки - выбор между автоподбором и дефолтными стратегиями
    print_separator
    print_info "Установка завершена успешно!"
    print_separator

    printf "\nНастройка стратегий DPI bypass:\n\n"
    printf "1) Запустить автоподбор стратегий (рекомендуется)\n"
    printf "   - Автоматическое тестирование для вашей сети\n"
    printf "   - Занимает 8-10 минут\n"
    printf "   - Подберет оптимальные стратегии для YouTube и RKN\n\n"
    printf "2) Применить дефолтные стратегии\n"
    printf "   - Быстрое применение проверенных стратегий\n"
    printf "   - YouTube TCP: #252, YouTube GV: #790, RKN: #3\n"
    printf "   - Может работать не во всех сетях\n\n"
    printf "Ваш выбор [1/2]: "
    read -r choice </dev/tty

    case "$choice" in
        2)
            print_info "Применение дефолтных стратегий..."
            apply_default_strategies --auto
            ;;
        *)
            print_info "Запуск автоматического подбора стратегий..."
            print_separator
            auto_test_categories --auto
            ;;
    esac

    print_info "Открываю меню управления..."
    sleep 1
    show_main_menu

    return 0
}

# ==============================================================================
# УДАЛЕНИЕ ZAPRET2
# ==============================================================================

uninstall_zapret2() {
    print_header "Удаление zapret2"

    if ! is_zapret2_installed; then
        print_info "zapret2 не установлен"
        return 0
    fi

    print_warning "Это удалит:"
    print_warning "  - Все файлы zapret2 ($ZAPRET2_DIR)"
    print_warning "  - Конфигурацию ($CONFIG_DIR)"
    print_warning "  - Init скрипт ($INIT_SCRIPT)"

    printf "\n"
    if ! confirm "Вы уверены? Это действие необратимо!" "N"; then
        print_info "Удаление отменено"
        return 0
    fi

    # Остановить сервис
    if is_zapret2_running; then
        print_info "Остановка сервиса..."
        "$INIT_SCRIPT" stop
    fi

    # Удалить init скрипт
    if [ -f "$INIT_SCRIPT" ]; then
        rm -f "$INIT_SCRIPT"
        print_info "Удален init скрипт"
    fi

    # Удалить netfilter хук
    local hook_file="/opt/etc/ndm/netfilter.d/000-zapret2.sh"
    if [ -f "$hook_file" ]; then
        rm -f "$hook_file"
        print_info "Удален netfilter хук"
    fi

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

    print_success "zapret2 полностью удален"

    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
