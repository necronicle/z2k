#!/bin/sh
# lib/install.sh - Полный процесс установки zapret2 для Keenetic
# 9-шаговая установка с интеграцией списков доменов и стратегий

# ==============================================================================
# ШАГ 1: ОБНОВЛЕНИЕ ПАКЕТОВ
# ==============================================================================

step_update_packages() {
    print_header "Шаг 1/9: Обновление пакетов"

    print_info "Обновление списка пакетов Entware..."

    if opkg update; then
        print_success "Список пакетов обновлен"
        return 0
    else
        print_error "Не удалось обновить список пакетов"
        return 1
    fi
}

# ==============================================================================
# ШАГ 2: УСТАНОВКА ЗАВИСИМОСТЕЙ
# ==============================================================================

step_install_dependencies() {
    print_header "Шаг 2/9: Установка зависимостей"

    # Список необходимых пакетов для Entware
    local packages="
gcc
make
libmnl
libnetfilter-queue
libnfnetlink
curl
unzip
lua
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
# ШАГ 4: СБОРКА ZAPRET2
# ==============================================================================

step_build_zapret2() {
    print_header "Шаг 4/9: Сборка zapret2"

    # Удалить старую установку если существует
    if [ -d "$ZAPRET2_DIR" ]; then
        print_warning "Найдена старая установка zapret2"
        printf "Удалить и установить заново? [Y/n]: "
        read -r answer

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Установка отменена"
                return 1
                ;;
            *)
                print_info "Удаление старой установки..."
                rm -rf "$ZAPRET2_DIR"
                print_success "Старая установка удалена"
                ;;
        esac
    fi

    # Создать временную директорию для сборки
    local build_dir="/tmp/zapret2_build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    cd "$build_dir" || return 1

    # Скачать zapret2 master.zip
    print_info "Загрузка zapret2 с GitHub..."

    local zapret2_url="https://github.com/bol-van/zapret2/archive/refs/heads/master.zip"

    if curl -fsSL "$zapret2_url" -o master.zip; then
        print_success "zapret2 загружен"
    else
        print_error "Не удалось загрузить zapret2"
        return 1
    fi

    # Распаковать
    print_info "Распаковка архива..."
    if command -v unzip >/dev/null 2>&1; then
        unzip -q master.zip || return 1
    else
        print_error "unzip не установлен"
        print_info "Установка unzip..."
        opkg install unzip || return 1
        unzip -q master.zip || return 1
    fi

    # Переместить в /opt/zapret2
    print_info "Установка в $ZAPRET2_DIR..."
    mv zapret2-master "$ZAPRET2_DIR" || return 1

    cd "$ZAPRET2_DIR/nfq2" || return 1

    # Патч для ARM64 (старые заголовки Entware)
    print_info "Применение ARM64 патча..."

    local sec_h="sec.h"

    if ! grep -q "AUDIT_ARCH_AARCH64" "$sec_h" 2>/dev/null; then
        # Вставить определения перед первым #endif
        awk '
            !inserted && /#endif/ {
                print "#define EM_AARCH64 183"
                print "#define __AUDIT_ARCH_64BIT 0x80000000"
                print "#define __AUDIT_ARCH_LE 0x40000000"
                print "#define AUDIT_ARCH_AARCH64 (EM_AARCH64|__AUDIT_ARCH_64BIT|__AUDIT_ARCH_LE)"
                print ""
                inserted=1
            }
            { print }
        ' "$sec_h" > "${sec_h}.patched"

        mv "${sec_h}.patched" "$sec_h"
        print_success "ARM64 патч применен"
    else
        print_info "ARM64 патч уже применен"
    fi

    # Компиляция nfqws2 с путями Entware
    print_info "Компиляция nfqws2..."

    # Entware использует /opt вместо /usr
    # Явно указываем пути к lua библиотекам
    if make LUA_JIT=0 LUA_VER=5.1 \
            LUA_CFLAGS="-I/opt/include" \
            LUA_LIB="-L/opt/lib -llua"; then
        print_success "nfqws2 собран успешно"
    else
        print_error "Ошибка компиляции nfqws2"
        return 1
    fi

    # Проверить бинарник
    if [ -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]; then
        print_success "nfqws2 готов: ${ZAPRET2_DIR}/nfq2/nfqws2"
    else
        print_error "nfqws2 не найден после сборки"
        return 1
    fi

    # Очистка build директории
    cd / || return 1
    rm -rf "$build_dir"

    print_success "zapret2 собран и установлен"
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
${ZAPRET2_DIR}/lua
${ZAPRET2_DIR}/files
${ZAPRET2_DIR}/docs
"

    print_info "Проверка структуры директорий..."

    for path in $required_paths; do
        if [ -e "$path" ]; then
            print_info "✓ $path"
        else
            print_error "✗ $path не найден"
            return 1
        fi
    done

    # Проверить бинарник
    print_info "Проверка nfqws2..."
    if verify_binary "${ZAPRET2_DIR}/nfq2/nfqws2"; then
        print_success "nfqws2 работает"
    else
        print_error "nfqws2 не работает"
        return 1
    fi

    # Посчитать Lua файлы
    local lua_count
    lua_count=$(find "${ZAPRET2_DIR}/lua" -name "*.lua" 2>/dev/null | wc -l)
    print_info "Lua файлов: $lua_count"

    # Посчитать fake файлы
    local fake_count
    fake_count=$(find "${ZAPRET2_DIR}/files/fake" -name "*.bin" 2>/dev/null | wc -l)
    print_info "Fake файлов: $fake_count"

    print_success "Установка проверена"
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
    print_header "Шаг 8/9: Создание init скрипта"

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

# ==============================================================================
# СТРАТЕГИИ
# ==============================================================================

# STRATEGY_MARKER_START
# Стратегия будет инжектирована сюда автоматически
# По умолчанию: базовая fake стратегия
STRATEGY_TCP="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
STRATEGY_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
# STRATEGY_MARKER_END

# DISCORD_MARKER_START
# Discord-специфичная конфигурация (если включена)
DISCORD_ENABLED=0
DISCORD_TCP=""
DISCORD_UDP=""
# DISCORD_MARKER_END

# ==============================================================================
# ФУНКЦИИ УПРАВЛЕНИЯ СЕРВИСОМ
# ==============================================================================

start() {
    if [ "$ENABLED" != "yes" ]; then
        echo "zapret2 disabled in config"
        return 1
    fi

    echo "Starting $DESC"

    # Загрузить модули ядра
    modprobe xt_multiport 2>/dev/null
    modprobe xt_connbytes 2>/dev/null
    modprobe xt_NFQUEUE 2>/dev/null
    modprobe nfnetlink_queue 2>/dev/null

    # Очистить старые правила iptables
    iptables -t mangle -F ZAPRET 2>/dev/null
    iptables -t mangle -X ZAPRET 2>/dev/null

    # Создать цепочку ZAPRET
    iptables -t mangle -N ZAPRET
    iptables -t mangle -A FORWARD -j ZAPRET

    # Добавить правила для перенаправления в NFQUEUE
    # TCP правила
    iptables -t mangle -A ZAPRET -p tcp -m multiport --dports 80,443 -j NFQUEUE --queue-num 200 --queue-bypass

    # UDP правила (QUIC)
    iptables -t mangle -A ZAPRET -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass

    # Запустить основной nfqws2 процесс
    $NFQWS \
        --qnum=200 \
        --lua-init="@${LUA_DIR}/zapret-lib.lua" \
        --lua-init="@${LUA_DIR}/zapret-antidpi.lua" \
        --hostlist="${LISTS_DIR}/youtube.txt" \
        --hostlist="${LISTS_DIR}/discord.txt" \
        --hostlist="${LISTS_DIR}/custom.txt" \
        $STRATEGY_TCP \
        --new \
        $STRATEGY_UDP \
        >/dev/null 2>&1 &

    # Discord процесс (если включен)
    if [ "$DISCORD_ENABLED" = "1" ]; then
        # Дополнительные UDP порты для Discord voice
        iptables -t mangle -A ZAPRET -p udp -m multiport --dports 50000:50099,1400,3478:3481,5349 -j NFQUEUE --queue-num 201 --queue-bypass

        $NFQWS \
            --qnum=201 \
            --lua-init="@${LUA_DIR}/zapret-lib.lua" \
            --lua-init="@${LUA_DIR}/zapret-antidpi.lua" \
            --hostlist="${LISTS_DIR}/discord.txt" \
            $DISCORD_TCP \
            --new \
            $DISCORD_UDP \
            >/dev/null 2>&1 &
    fi

    sleep 1

    if pgrep -f "$NFQWS" >/dev/null; then
        echo "zapret2 started"
        return 0
    else
        echo "zapret2 failed to start"
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
# ШАГ 9: ФИНАЛИЗАЦИЯ
# ==============================================================================

step_finalize() {
    print_header "Шаг 9/9: Финализация установки"

    # Запустить сервис
    print_info "Запуск сервиса zapret2..."

    if "$INIT_SCRIPT" start; then
        print_success "Сервис zapret2 запущен"
    else
        print_error "Не удалось запустить сервис"
        return 1
    fi

    sleep 2

    # Проверить статус
    if is_zapret2_running; then
        print_success "zapret2 работает"
    else
        print_warning "Сервис запущен, но процесс не обнаружен"
        print_info "Проверьте логи: $INIT_SCRIPT status"
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
    step_finalize || return 1

    # После установки - запустить автотест TOP-20
    print_separator
    print_info "Установка завершена успешно!"
    print_info "Теперь нужно выбрать стратегию обхода"
    print_separator

    if confirm "Запустить автотест TOP-20 стратегий?" "Y"; then
        auto_test_top20
    else
        print_info "Автотест пропущен"
        print_info "Используйте меню для выбора стратегии: sh z2k.sh menu"
    fi

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

    printf "\nВы уверены? Введите 'yes' для подтверждения: "
    read -r answer

    if [ "$answer" != "yes" ]; then
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
