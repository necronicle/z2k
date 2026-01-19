#!/bin/sh
# lib/install.sh - Полный процесс установки zapret2 для Keenetic
# 9-шаговая установка с интеграцией списков доменов и стратегий

# ==============================================================================
# ШАГ 1: ОБНОВЛЕНИЕ ПАКЕТОВ
# ==============================================================================

step_update_packages() {
    print_header "Шаг 1/9: Обновление пакетов"

    print_info "Обновление списка пакетов Entware..."

    # Попытка обновления с перехватом ошибок
    if opkg update 2>&1; then
        print_success "Список пакетов обновлен"
        return 0
    else
        local exit_code=$?
        print_error "Не удалось обновить список пакетов (код: $exit_code)"

        # Проверка на "Illegal instruction"
        if [ "$exit_code" -eq 132 ] || opkg --version 2>&1 | grep -qi "Illegal"; then
            print_error "Обнаружена ошибка 'Illegal instruction'"
            print_separator
            cat <<'EOF'
⚠️  ПРОБЛЕМА С ENTWARE:

Ваш Entware установлен неправильно или поврежден.
Это НЕ проблема z2k - это проблема окружения роутера.

Возможные причины:
1. Entware установлен для неправильной архитектуры процессора
2. Поврежденные бинарники в /opt/bin/
3. Несовместимая версия Entware для вашей модели роутера

РЕКОМЕНДАЦИИ:
1. Переустановите Entware заново:
   https://help.keenetic.com/hc/ru/articles/360021888880

2. Убедитесь что выбрана правильная архитектура для вашего роутера

3. После переустановки Entware запустите z2k снова

ПРОДОЛЖИТЬ БЕЗ ОБНОВЛЕНИЯ? (не рекомендуется)
Установка может продолжиться, но пакеты могут быть устаревшими.
EOF
            printf "\nПродолжить без opkg update? [y/N]: "
            read -r answer </dev/tty

            case "$answer" in
                [Yy]|[Yy][Ee][Ss])
                    print_warning "Продолжаем без обновления пакетов..."
                    return 0
                    ;;
                *)
                    print_info "Установка прервана"
                    print_info "Исправьте проблему с Entware и запустите снова"
                    return 1
                    ;;
            esac
        else
            print_warning "Продолжаем установку без обновления..."
            return 0
        fi
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
# ШАГ 4: СБОРКА ZAPRET2
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

    # Скачать zapret2 master.zip (для lua, files, docs)
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
    unzip -q master.zip || return 1

    # Переместить в /opt/zapret2
    print_info "Установка в $ZAPRET2_DIR..."
    mv zapret2-master "$ZAPRET2_DIR" || return 1

    # Определить архитектуру
    local arch
    arch=$(uname -m)

    print_info "Определена архитектура: $arch"

    # Скачать OpenWrt embedded через GitHub API (с редиректом)
    print_info "Загрузка zapret2 OpenWrt embedded..."

    # GitHub API автоматически редиректит на последнюю версию
    local api_url="https://api.github.com/repos/bol-van/zapret2/releases/latest"

    # Получаем JSON и парсим URL для openwrt-embedded
    print_info "Получение информации о релизе..."

    local release_data
    release_data=$(curl -fsSL "$api_url" 2>&1)

    if [ $? -ne 0 ]; then
        print_warning "API недоступен, пробую прямую ссылку на v0.8.3..."
        # Fallback на известную версию
        local openwrt_url="https://github.com/bol-van/zapret2/releases/download/v0.8.3/zapret2-v0.8.3-openwrt-embedded.tar.gz"
    else
        # Ищем URL в JSON
        local openwrt_url
        openwrt_url=$(echo "$release_data" | grep -o 'https://github.com/bol-van/zapret2/releases/download/[^"]*openwrt-embedded\.tar\.gz' | head -1)

        if [ -z "$openwrt_url" ]; then
            print_warning "Не найден в API, пробую прямую ссылку на v0.8.3..."
            openwrt_url="https://github.com/bol-van/zapret2/releases/download/v0.8.3/zapret2-v0.8.3-openwrt-embedded.tar.gz"
        fi
    fi

    print_info "URL: $openwrt_url"

    if curl -fsSL "$openwrt_url" -o openwrt-embedded.tar.gz; then
        print_success "OpenWrt embedded загружен"

        # Распаковать и найти бинарник
        print_info "Извлечение nfqws2..."

        # Проверить размер архива
        echo "DEBUG: Размер архива:"
        ls -lh openwrt-embedded.tar.gz

        # Временная директория для распаковки
        echo "DEBUG: Создание директории openwrt_binaries"
        mkdir -p openwrt_binaries

        # Попытка распаковки
        echo "DEBUG: Попытка распаковки..."
        tar -xzf openwrt-embedded.tar.gz -C openwrt_binaries
        local tar_result=$?
        echo "DEBUG: tar exit code = $tar_result"

        if [ $tar_result -ne 0 ]; then
            print_error "Ошибка распаковки архива (код $tar_result)"
            return 1
        fi

        print_success "Архив распакован"

        # DEBUG: Показать структуру архива
        echo "DEBUG: Содержимое openwrt_binaries/:"
        ls -la openwrt_binaries/ 2>&1 | head -20
        echo "DEBUG: ---"

        echo "DEBUG: Все файлы (рекурсивно):"
        ls -lR openwrt_binaries/ 2>&1 | head -50
        echo "DEBUG: ---"

        echo "DEBUG: Поиск nfqws:"
        find openwrt_binaries -name "*nfqws*" -type f 2>&1
        echo "DEBUG: Поиск завершён"

        # Найти исполняемый файл nfqws2 для правильной архитектуры
        local binary_found=0
        local binary_path=""

        # Определить правильную директорию в зависимости от архитектуры
        # Структура архива: zapret2-v0.8.3/binaries/linux-XXX/nfqws2
        case "$arch" in
            aarch64)
                # ARM64 - искать в linux-arm64
                binary_path=$(find openwrt_binaries -path "*/binaries/linux-arm64/nfqws2" 2>/dev/null | head -1)
                ;;
            armv7l|armv6l|arm)
                # ARM 32bit - искать в linux-arm
                binary_path=$(find openwrt_binaries -path "*/binaries/linux-arm/nfqws2" 2>/dev/null | head -1)
                ;;
            mips)
                # MIPS big-endian
                binary_path=$(find openwrt_binaries -path "*/binaries/linux-mips/nfqws2" 2>/dev/null | head -1)
                ;;
            mipsel)
                # MIPS little-endian
                binary_path=$(find openwrt_binaries -path "*/binaries/linux-mipsel/nfqws2" 2>/dev/null | head -1)
                ;;
            x86_64)
                # x86_64
                binary_path=$(find openwrt_binaries -path "*/binaries/linux-x86_64/nfqws2" 2>/dev/null | head -1)
                ;;
            i386|i686)
                # x86 32bit
                binary_path=$(find openwrt_binaries -path "*/binaries/linux-x86/nfqws2" 2>/dev/null | head -1)
                ;;
            *)
                print_warning "Неизвестная архитектура: $arch"
                binary_path=""
                ;;
        esac

        echo "DEBUG: Выбран бинарник: $binary_path"

        if [ -n "$binary_path" ] && [ -f "$binary_path" ]; then
            cp "$binary_path" "${ZAPRET2_DIR}/nfq2/nfqws2"
            binary_found=1
            print_success "Найден и скопирован: $binary_path"
        else
            binary_found=0
        fi

        # Очистка
        rm -rf openwrt_binaries openwrt-embedded.tar.gz

        if [ $binary_found -eq 0 ]; then
            print_error "nfqws2 не найден в OpenWrt embedded архиве"
            return 1
        fi
    else
        print_error "Не удалось загрузить zapret2 OpenWrt embedded"
        return 1
    fi

    # Сделать исполняемым
    chmod +x "${ZAPRET2_DIR}/nfq2/nfqws2" || return 1

    # Проверить бинарник
    if [ -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]; then
        print_success "nfqws2 готов: ${ZAPRET2_DIR}/nfq2/nfqws2"
    else
        print_error "nfqws2 не найден после установки"
        return 1
    fi

    # Очистка build директории
    cd / || return 1
    rm -rf "$build_dir"

    print_success "zapret2 установлен"
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
# СТРАТЕГИИ ПО КАТЕГОРИЯМ (Z4R АРХИТЕКТУРА)
# ==============================================================================

# YouTube TCP стратегия (интерфейс YouTube)
# YOUTUBE_TCP_MARKER_START
YOUTUBE_TCP_TCP="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
YOUTUBE_TCP_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
# YOUTUBE_TCP_MARKER_END

# YouTube GV стратегия (Google Video CDN)
# YOUTUBE_GV_MARKER_START
YOUTUBE_GV_TCP="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
YOUTUBE_GV_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
# YOUTUBE_GV_MARKER_END

# RKN стратегия (заблокированные сайты)
# RKN_MARKER_START
RKN_TCP="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
RKN_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
# RKN_MARKER_END

# Discord стратегия (сообщения и голос)
# DISCORD_MARKER_START
DISCORD_TCP="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
DISCORD_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
# DISCORD_MARKER_END

# Custom стратегия (пользовательские домены)
# CUSTOM_MARKER_START
CUSTOM_TCP="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"
CUSTOM_UDP="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=4"
# CUSTOM_MARKER_END

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
    # Process 1: YouTube (TCP + GV через --new) (queue 200)
    # ===========================================================================

    # TCP/UDP правила для YouTube
    iptables -t mangle -A ZAPRET -p tcp -m multiport --dports 80,443 -j NFQUEUE --queue-num 200 --queue-bypass
    iptables -t mangle -A ZAPRET -p udp --dport 443 -j NFQUEUE --queue-num 200 --queue-bypass

    # Запустить nfqws2 для YouTube (TCP и GV в одном процессе)
    $NFQWS \
        --qnum=200 \
        --lua-init="@${LUA_DIR}/zapret-lib.lua" \
        --lua-init="@${LUA_DIR}/zapret-antidpi.lua" \
        --hostlist="${LISTS_DIR}/youtube.txt" \
        $YOUTUBE_TCP_TCP \
        --new \
        $YOUTUBE_GV_TCP \
        --new \
        $YOUTUBE_TCP_UDP \
        >/dev/null 2>&1 &

    # ===========================================================================
    # Process 2: Discord (queue 201)
    # ===========================================================================

    # TCP/UDP правила для Discord (включая voice порты)
    iptables -t mangle -A ZAPRET -p tcp -m multiport --dports 80,443 -j NFQUEUE --queue-num 201 --queue-bypass
    iptables -t mangle -A ZAPRET -p udp --dport 443 -j NFQUEUE --queue-num 201 --queue-bypass
    iptables -t mangle -A ZAPRET -p udp -m multiport --dports 50000:50099,1400,3478:3481,5349 -j NFQUEUE --queue-num 201 --queue-bypass

    # Запустить nfqws2 для Discord
    $NFQWS \
        --qnum=201 \
        --lua-init="@${LUA_DIR}/zapret-lib.lua" \
        --lua-init="@${LUA_DIR}/zapret-antidpi.lua" \
        --hostlist="${LISTS_DIR}/discord.txt" \
        $DISCORD_TCP \
        --new \
        $DISCORD_UDP \
        >/dev/null 2>&1 &

    # ===========================================================================
    # Process 3: RKN (queue 202)
    # ===========================================================================

    # TCP/UDP правила для RKN
    iptables -t mangle -A ZAPRET -p tcp -m multiport --dports 80,443 -j NFQUEUE --queue-num 202 --queue-bypass
    iptables -t mangle -A ZAPRET -p udp --dport 443 -j NFQUEUE --queue-num 202 --queue-bypass

    # Запустить nfqws2 для RKN
    $NFQWS \
        --qnum=202 \
        --lua-init="@${LUA_DIR}/zapret-lib.lua" \
        --lua-init="@${LUA_DIR}/zapret-antidpi.lua" \
        --hostlist="${LISTS_DIR}/rkn.txt" \
        $RKN_TCP \
        --new \
        $RKN_UDP \
        >/dev/null 2>&1 &

    # ===========================================================================
    # Process 4: Custom (пользовательские домены) (queue 203)
    # ===========================================================================

    # TCP/UDP правила для Custom
    iptables -t mangle -A ZAPRET -p tcp -m multiport --dports 80,443 -j NFQUEUE --queue-num 203 --queue-bypass
    iptables -t mangle -A ZAPRET -p udp --dport 443 -j NFQUEUE --queue-num 203 --queue-bypass

    # Запустить nfqws2 для Custom
    $NFQWS \
        --qnum=203 \
        --lua-init="@${LUA_DIR}/zapret-lib.lua" \
        --lua-init="@${LUA_DIR}/zapret-antidpi.lua" \
        --hostlist="${LISTS_DIR}/custom.txt" \
        $CUSTOM_TCP \
        --new \
        $CUSTOM_UDP \
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
# ШАГ 9: ФИНАЛИЗАЦИЯ
# ==============================================================================

step_finalize() {
    print_header "Шаг 9/9: Финализация установки"

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

    # После установки - автоматически запустить автотест по категориям
    print_separator
    print_info "Установка завершена успешно!"
    print_info "Запуск автоматического подбора стратегий по категориям..."
    print_separator

    auto_test_categories --auto

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
