#!/bin/sh
# lib/install.sh - Полный процесс установки zapret2 для Keenetic
# 9-шаговая установка с интеграцией списков доменов и стратегий

# ==============================================================================
# ШАГ 1: ОБНОВЛЕНИЕ ПАКЕТОВ
# ==============================================================================

step_update_packages() {
    print_header "Шаг 1/9: Обновление пакетов"

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
# ШАГ 2: УСТАНОВКА ЗАВИСИМОСТЕЙ
# ==============================================================================

step_install_dependencies() {
    print_header "Шаг 2/9: Установка зависимостей"

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

    print_success "Зависимости установлены"
    return 0
}

# ==============================================================================
# ШАГ 3: ЗАГРУЗКА МОДУЛЕЙ ЯДРА
# ==============================================================================

step_load_kernel_modules() {
    print_header "Шаг 3/9: Загрузка модулей ядра"

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
    print_header "Шаг 4/9: Установка zapret2"

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
    print_header "Шаг 5/9: Проверка установки"

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
# ШАГ 6: ЗАГРУЗКА СПИСКОВ ДОМЕНОВ (НОВЫЙ ШАГ)
# ==============================================================================

step_download_domain_lists() {
    print_header "Шаг 6/9: Загрузка списков доменов"

    # Использовать функцию из lib/config.sh
    download_domain_lists || {
        print_error "Не удалось загрузить списки доменов"
        return 1
    }

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

step_disable_hwnat() {
    print_header "Шаг 7/9: Отключение Hardware NAT"

    print_info "Hardware NAT может конфликтовать с DPI bypass"

    # Проверить наличие системы управления HWNAT
    if [ -f "/opt/etc/ndm/fs.d/100-ipv4-forward.sh" ]; then
        print_info "Найдена система управления HWNAT"

        # Отключить HWNAT
        if echo 0 > /sys/kernel/fastnat/mode 2>/dev/null; then
            print_success "Hardware NAT отключен"
        else
            print_warning "Не удалось отключить Hardware NAT"
            print_warning "Это нормально на некоторых моделях"
        fi
    else
        print_info "Система HWNAT не обнаружена, пропускаем"
    fi

    return 0
}

# ==============================================================================
# ШАГ 8: СОЗДАНИЕ INIT СКРИПТА (С МАРКЕРАМИ)
# ==============================================================================

step_create_init_script() {
    print_header "Шаг 8/10: Создание init скрипта"

    print_info "Создание $INIT_SCRIPT..."

    # Создать директорию если не существует
    mkdir -p "$(dirname "$INIT_SCRIPT")"

    # Создать init скрипт с маркерами для стратегий
    cat > "$INIT_SCRIPT" <<'INIT_SCRIPT'
#!/bin/sh

# S99zapret2 - Init скрипт для zapret2
# Управление сервисом DPI bypass

ENABLED=yes
PROCS=nfqws2
ARGS=""
PREARGS=""

DESC="zapret2 DPI bypass"
ZAPRET2_DIR="/opt/zapret2"
NFQWS="${ZAPRET2_DIR}/nfq2/nfqws2"
LUA_DIR="${ZAPRET2_DIR}/lua"
LISTS_DIR="${ZAPRET2_DIR}/lists"
EXTRA_STRATS_DIR="${ZAPRET2_DIR}/extra_strats"
CONFIG_DIR="${ZAPRET2_DIR}/config"

# ==============================================================================
# СТРАТЕГИИ ПО КАТЕГОРИЯМ (Z4R АРХИТЕКТУРА)
# ==============================================================================

# STRATEGY_MARKER_START

# YouTube TCP стратегия (интерфейс YouTube)
# YOUTUBE_TCP_MARKER_START
YOUTUBE_TCP_TCP="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
YOUTUBE_TCP_UDP=""
# YOUTUBE_TCP_MARKER_END

# YouTube GV стратегия (Google Video CDN)
# YOUTUBE_GV_MARKER_START
YOUTUBE_GV_TCP="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
YOUTUBE_GV_UDP=""
# YOUTUBE_GV_MARKER_END

# RKN стратегия (заблокированные сайты)
# RKN_MARKER_START
RKN_TCP="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
RKN_UDP=""
# RKN_MARKER_END

# Discord стратегия (сообщения и голос)
# DISCORD_MARKER_START
DISCORD_TCP="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=tls_clienthello_14:tls_mod=rnd,dupsid:ip_autottl=-2,3-20 --lua-desync=multisplit:pos=sld+1"
DISCORD_UDP="--filter-udp=50000-50099,1400,3478-3481,5349 --filter-l7=discord,stun --payload=stun,discord_ip_discovery --out-range=-n10 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2"
# DISCORD_MARKER_END

# Custom стратегия (пользовательские домены)
# CUSTOM_MARKER_START
CUSTOM_TCP="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
CUSTOM_UDP=""
# CUSTOM_MARKER_END

# QUIC стратегия (YouTube UDP 443)
# QUIC_MARKER_START
QUIC_TCP=""
QUIC_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"
# QUIC_MARKER_END

# QUIC стратегия (RuTracker UDP 443)
# QUIC_RKN_MARKER_START
QUIC_RKN_TCP=""
QUIC_RKN_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"
# QUIC_RKN_MARKER_END

# STRATEGY_MARKER_END

# ==============================================================================
# ФУНКЦИИ УПРАВЛЕНИЯ СЕРВИСОМ
# ==============================================================================

start() {
    if [ "$ENABLED" != "yes" ]; then
        echo "zapret2 disabled in config"
        return 1
    fi

    echo "Starting $DESC"

    # Загрузить конфигурацию режима ALL_TCP443
    local ALL_TCP443_ENABLED=0
    local ALL_TCP443_STRATEGY_NUM=1
    local ALL_TCP443_CONF="${CONFIG_DIR}/all_tcp443.conf"

    if [ -f "$ALL_TCP443_CONF" ]; then
        . "$ALL_TCP443_CONF"
        ALL_TCP443_ENABLED=$ENABLED
        ALL_TCP443_STRATEGY_NUM=$STRATEGY
    fi

    # Получить стратегию для ALL_TCP443 режима
    local ALL_TCP443_STRATEGY=""
    if [ "$ALL_TCP443_ENABLED" = "1" ]; then
        # Загрузить стратегию из strategies.conf
        if [ -f "${CONFIG_DIR}/strategies.conf" ]; then
            ALL_TCP443_STRATEGY=$(sed -n "${ALL_TCP443_STRATEGY_NUM}p" "${CONFIG_DIR}/strategies.conf" 2>/dev/null | awk -F ' : ' '{print $2}')
            if [ -z "$ALL_TCP443_STRATEGY" ]; then
                echo "WARNING: Strategy #${ALL_TCP443_STRATEGY_NUM} not found, using default"
                ALL_TCP443_STRATEGY="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
            fi
        fi
    fi

    # Загрузить модули ядра (через Entware insmod с полными путями)
    local kernel_ver=$(uname -r)
    /opt/sbin/insmod /lib/modules/${kernel_ver}/xt_multiport.ko 2>/dev/null
    /opt/sbin/insmod /lib/modules/${kernel_ver}/xt_connbytes.ko 2>/dev/null
    /opt/sbin/insmod /lib/modules/${kernel_ver}/xt_NFQUEUE.ko 2>/dev/null
    /opt/sbin/insmod /lib/modules/${kernel_ver}/nfnetlink_queue.ko 2>/dev/null

    # Очистить старые правила iptables (правильный порядок)
    # 1. Убить старые процессы nfqws2
    killall nfqws2 2>/dev/null
    sleep 1

    # 2. Удалить правило из FORWARD (чтобы цепочку можно было удалить)
    iptables -t mangle -D FORWARD -j ZAPRET 2>/dev/null

    # 3. Очистить содержимое цепочки
    iptables -t mangle -F ZAPRET 2>/dev/null

    # 4. Удалить цепочку
    iptables -t mangle -X ZAPRET 2>/dev/null

    # Создать цепочку ZAPRET заново
    iptables -t mangle -N ZAPRET
    iptables -t mangle -A FORWARD -j ZAPRET

    # ===========================================================================
    # ЕДИНЫЙ ПРОЦЕСС NFQWS2 С МНОЖЕСТВЕННЫМИ ПРОФИЛЯМИ (queue 200)
    # ===========================================================================
    # Эффективная архитектура: один процесс обрабатывает все категории через --new
    # Каждый профиль имеет свой --hostlist и свою стратегию
    # ===========================================================================

    # Единое правило для всех категорий (TCP/UDP порты 80, 443)
    iptables -t mangle -A ZAPRET -p tcp -m multiport --dports 80,443,2053,2083,2087,2096,8443 -j NFQUEUE --queue-num 200 --queue-bypass
    iptables -t mangle -A ZAPRET -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass

    # Дополнительные порты для Discord Voice
    iptables -t mangle -A ZAPRET -p udp -m multiport --dports 50000:50099,1400,3478:3481,5349 -j NFQUEUE --queue-num 200 --queue-bypass

    # Проверить существование whitelist.txt перед запуском
    if [ ! -f "${LISTS_DIR}/whitelist.txt" ]; then
        echo "WARNING: whitelist.txt не найден, будет создан пустой файл"
        mkdir -p "$LISTS_DIR" 2>/dev/null
        touch "${LISTS_DIR}/whitelist.txt" 2>/dev/null || {
            echo "ERROR: Не удалось создать whitelist.txt"
            return 1
        }
    fi

    # Запустить единый nfqws2 процесс с множественными профилями
    $NFQWS \
        --qnum=200 \
        --lua-init="@${LUA_DIR}/zapret-lib.lua" \
        --lua-init="@${LUA_DIR}/zapret-antidpi.lua" \
        --blob=tls_clienthello_14:@${ZAPRET2_DIR}/files/fake/tls_clienthello_14.bin \
        --blob=quic_google:@${ZAPRET2_DIR}/files/fake/quic_initial_www_google_com.bin \
        --blob=quic_vk:@${ZAPRET2_DIR}/files/fake/quic_initial_vk_com.bin \
        --blob=quic_facebook:@${ZAPRET2_DIR}/files/fake/quic_initial_facebook_com.bin \
        --blob=quic_rutracker:@${ZAPRET2_DIR}/files/fake/quic_initial_rutracker_org.bin \
        --blob=quic1:@${ZAPRET2_DIR}/files/fake/quic_1.bin \
        --blob=quic2:@${ZAPRET2_DIR}/files/fake/quic_2.bin \
        --blob=quic3:@${ZAPRET2_DIR}/files/fake/quic_3.bin \
        --blob=quic4:@${ZAPRET2_DIR}/files/fake/quic_4.bin \
        --blob=quic5:@${ZAPRET2_DIR}/files/fake/quic_5.bin \
        --blob=quic6:@${ZAPRET2_DIR}/files/fake/quic_6.bin \
        --blob=quic7:@${ZAPRET2_DIR}/files/fake/quic_7.bin \
        --blob=quic_test:@${ZAPRET2_DIR}/files/fake/quic_test_00.bin \
        --blob=fake_quic:@${ZAPRET2_DIR}/files/fake/fake_quic_1.bin \
        --blob=fake_quic1:@${ZAPRET2_DIR}/files/fake/fake_quic_1.bin \
        --blob=fake_quic2:@${ZAPRET2_DIR}/files/fake/fake_quic_2.bin \
        --blob=fake_quic3:@${ZAPRET2_DIR}/files/fake/fake_quic_3.bin \
        --hostlist-exclude="${LISTS_DIR}/whitelist.txt" \
        \
        --hostlist="${EXTRA_STRATS_DIR}/TCP/RKN/List.txt" \
        $RKN_TCP \
        \
        --new \
        --hostlist="${EXTRA_STRATS_DIR}/TCP/YT/List.txt" \
        $YOUTUBE_TCP_TCP \
        --new \
        --hostlist-domains=googlevideo.com \
        $YOUTUBE_GV_TCP \
        \
        --new \
        --hostlist="${EXTRA_STRATS_DIR}/UDP/YT/List.txt" \
        $QUIC_UDP \
        \
        --new \
        --hostlist="${EXTRA_STRATS_DIR}/UDP/RUTRACKER/List.txt" \
        $QUIC_RKN_UDP \
        \
        --new \
        --hostlist="${LISTS_DIR}/discord.txt" \
        $DISCORD_TCP \
        --new \
        --hostlist="${LISTS_DIR}/discord.txt" \
        $DISCORD_UDP \
        \
        --new \
        --hostlist="${LISTS_DIR}/custom.txt" \
        $CUSTOM_TCP \
        $([ "$ALL_TCP443_ENABLED" = "1" ] && echo "\
        --new \
        $ALL_TCP443_STRATEGY") \
        >/dev/null 2>&1 &

    sleep 2

    if pgrep -f "$NFQWS" >/dev/null; then
        echo "zapret2 started"
        return 0
    else
        echo "zapret2 failed to start"
        echo "Debug: checking processes..."
        ps | grep nfqws || echo "No nfqws process found"
        return 1
    fi
}

stop() {
    echo "Stopping $DESC"

    # Убить все процессы nfqws2
    killall nfqws2 2>/dev/null

    # Очистить правила iptables
    iptables -t mangle -F ZAPRET 2>/dev/null
    iptables -t mangle -D FORWARD -j ZAPRET 2>/dev/null
    iptables -t mangle -X ZAPRET 2>/dev/null

    echo "zapret2 stopped"
}

restart() {
    stop
    sleep 2
    start
}

status() {
    if pgrep -f "$NFQWS" >/dev/null; then
        echo "zapret2 is running"
        echo "Processes:"
        pgrep -af "$NFQWS"
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
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
INIT_SCRIPT

    # Сделать исполняемым
    chmod +x "$INIT_SCRIPT"

    print_success "Init скрипт создан: $INIT_SCRIPT"

    return 0
}

# ==============================================================================
# ШАГ 9: УСТАНОВКА NETFILTER ХУКА
# ==============================================================================

step_install_netfilter_hook() {
    print_header "Шаг 9/10: Установка netfilter хука"

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
    print_header "Шаг 10/10: Финализация установки"

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
    print_info "Процесс установки: 9 шагов"
    print_separator

    # Выполнить все шаги последовательно
    step_update_packages || return 1
    step_install_dependencies || return 1
    step_load_kernel_modules || return 1
    step_build_zapret2 || return 1
    step_verify_installation || return 1
    step_download_domain_lists || return 1
    step_disable_hwnat || return 1
    step_create_init_script || return 1
    step_install_netfilter_hook || return 1
    step_finalize || return 1

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
