#!/bin/sh
# lib/utils.sh - Утилиты, проверки и константы для z2k
# Часть z2k v2.0 - Модульный установщик zapret2 для Keenetic

# ==============================================================================
# КОНСТАНТЫ
# ==============================================================================

# Версия z2k
Z2K_VERSION="2.0.0"

# Пути установки
ZAPRET2_DIR="/opt/zapret2"
CONFIG_DIR="/opt/etc/zapret2"
LISTS_DIR="${ZAPRET2_DIR}/lists"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"

# Рабочая директория
WORK_DIR="/tmp/z2k"
LIB_DIR="${WORK_DIR}/lib"

# GitHub URLs
GITHUB_RAW="https://raw.githubusercontent.com/necronicle/z2k/test"
Z4R_LISTS_URL="https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/master/lists"
Z4R_RKN_URL="https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/master/extra_strats/TCP/RKN/List.txt"

# Файлы конфигурации
STRATEGIES_CONF="${CONFIG_DIR}/strategies.conf"
HTTP_STRATEGIES_CONF="${CONFIG_DIR}/http_strategies.conf"
CURRENT_STRATEGY_FILE="${CONFIG_DIR}/current_strategy"
QUIC_STRATEGIES_CONF="${CONFIG_DIR}/quic_strategies.conf"
QUIC_STRATEGY_FILE="${CONFIG_DIR}/quic_strategy.conf"

# Цвета для вывода (если терминал поддерживает)
if [ -t 1 ]; then
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[1;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_RESET='\033[0m'
else
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_RESET=''
fi

# ==============================================================================
# ФУНКЦИИ ВЫВОДА
# ==============================================================================

print_success() {
    printf "${COLOR_GREEN}[✓]${COLOR_RESET} %s\n" "$1"
}

print_error() {
    printf "${COLOR_RED}[✗]${COLOR_RESET} %s\n" "$1" >&2
}

print_warning() {
    printf "${COLOR_YELLOW}[!]${COLOR_RESET} %s\n" "$1"
}

print_info() {
    printf "${COLOR_BLUE}[i]${COLOR_RESET} %s\n" "$1"
}

print_header() {
    printf "\n${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
    printf "${COLOR_BLUE}  %s${COLOR_RESET}\n" "$1"
    printf "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n\n"
}

print_separator() {
    printf "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
}

# ==============================================================================
# ПРОВЕРКИ СИСТЕМЫ
# ==============================================================================

# Проверка наличия Entware
check_entware() {
    if [ ! -d "/opt" ] || [ ! -x "/opt/bin/opkg" ]; then
        print_error "Entware не установлен!"
        print_info "Установите Entware перед запуском z2k"
        print_info "Инструкция: https://help.keenetic.com/hc/ru/articles/360021888880"
        return 1
    fi
    return 0
}

# Проверка прав root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Требуются права root для установки"
        print_info "Запустите: sudo sh z2k.sh"
        return 1
    fi
    return 0
}

# Получить архитектуру системы
get_arch() {
    uname -m
}

# Проверка архитектуры (только ARM64 для Keenetic)
check_arch() {
    local arch
    arch=$(get_arch)

    case "$arch" in
        aarch64|arm64)
            return 0
            ;;
        *)
            print_warning "Архитектура $arch не протестирована"
            print_warning "z2k предназначен для ARM64 Keenetic роутеров"
            printf "Продолжить? [y/N]: "
            read -r answer </dev/tty
            [ "$answer" = "y" ] || return 1
            ;;
    esac
    return 0
}

# Проверка свободного места на диске
check_disk_space() {
    local required_mb=50
    local available_mb

    # Получить свободное место в /opt (в MB)
    available_mb=$(df -m /opt 2>/dev/null | awk 'NR==2 {print $4}')

    if [ -z "$available_mb" ]; then
        print_warning "Не удалось определить свободное место"
        return 0
    fi

    if [ "$available_mb" -lt "$required_mb" ]; then
        print_error "Недостаточно места в /opt"
        print_info "Требуется: ${required_mb}MB, доступно: ${available_mb}MB"
        return 1
    fi

    return 0
}

# Проверка наличия curl
check_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        print_error "curl не установлен"
        print_info "Установка curl..."
        opkg update && opkg install curl || return 1
    fi
    return 0
}

# Проверка наличия необходимых утилит
check_required_tools() {
    local missing_tools=""

    for tool in awk sed grep; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools="$missing_tools $tool"
        fi
    done

    if [ -n "$missing_tools" ]; then
        print_error "Отсутствуют утилиты:$missing_tools"
        return 1
    fi

    return 0
}

# Проверка, установлен ли zapret2
is_zapret2_installed() {
    [ -d "$ZAPRET2_DIR" ] && [ -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]
}

# Проверка, запущен ли сервис zapret2
is_zapret2_running() {
    if [ -f "$INIT_SCRIPT" ]; then
        pgrep -f "nfqws2" >/dev/null 2>&1
    else
        return 1
    fi
}

# Получить статус сервиса
get_service_status() {
    if is_zapret2_running; then
        echo "Активен"
    elif is_zapret2_installed; then
        echo "Остановлен"
    else
        echo "Не установлен"
    fi
}

# Получить текущую стратегию
get_current_strategy() {
    if [ -f "$CURRENT_STRATEGY_FILE" ]; then
        . "$CURRENT_STRATEGY_FILE"
        echo "$CURRENT_STRATEGY"
    else
        echo "не задана"
    fi
}

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

# Скачать файл с проверкой
download_file() {
    local url=$1
    local output=$2
    local description=${3:-"Загрузка файла"}

    print_info "$description..."

    if curl -fsSL "$url" -o "$output"; then
        print_success "Загружено: $output"
        return 0
    else
        print_error "Ошибка загрузки: $url"
        return 1
    fi
}

# Создать резервную копию файла
backup_file() {
    local file=$1
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"

    if [ -f "$file" ]; then
        cp "$file" "$backup" || return 1
        print_info "Резервная копия: $backup"
    fi
    return 0
}

# Восстановить из резервной копии
restore_backup() {
    local file=$1
    local backup

    # Найти последний backup
    backup=$(ls -t "${file}.backup."* 2>/dev/null | head -n 1)

    if [ -n "$backup" ] && [ -f "$backup" ]; then
        cp "$backup" "$file" || return 1
        print_success "Восстановлено из: $backup"
        return 0
    else
        print_error "Резервная копия не найдена"
        return 1
    fi
}

# Проверить бинарный файл
verify_binary() {
    local binary=$1

    if [ ! -f "$binary" ]; then
        print_error "Файл не найден: $binary"
        return 1
    fi

    if [ ! -x "$binary" ]; then
        print_error "Файл не исполняемый: $binary"
        return 1
    fi

    # Попробовать запустить с --version
    local version_output
    version_output=$("$binary" --version 2>&1 | head -1)

    if echo "$version_output" | grep -q "github version"; then
        return 0
    fi

    print_warning "Не удалось проверить бинарник: $binary"
    return 0
}

# Проверка загрузки модуля ядра
check_kernel_module() {
    local module=$1

    if lsmod | grep -q "^${module}"; then
        return 0
    else
        return 1
    fi
}

# Загрузка модуля ядра
load_kernel_module() {
    local module=$1

    if check_kernel_module "$module"; then
        print_info "Модуль $module уже загружен"
        return 0
    fi

    print_info "Загрузка модуля: $module"

    # На Keenetic нет системного modprobe, только Entware
    # Используем /opt/sbin/insmod с полным путём к .ko файлу
    local kernel_ver
    kernel_ver=$(uname -r)
    local module_path="/lib/modules/${kernel_ver}/${module}.ko"

    if [ ! -f "$module_path" ]; then
        print_error "Файл модуля не найден: $module_path"
        return 1
    fi

    if /opt/sbin/insmod "$module_path" 2>/dev/null; then
        print_success "Модуль $module загружен"
        return 0
    else
        print_error "Ошибка загрузки модуля: $module"
        return 1
    fi
}

# Проверить доступность URL
check_url_accessible() {
    local url=$1
    local timeout=${2:-5}

    if curl -s -m "$timeout" -I "$url" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Получить версию nfqws2
get_nfqws2_version() {
    local nfqws2="${ZAPRET2_DIR}/nfq2/nfqws2"

    if [ -x "$nfqws2" ]; then
        "$nfqws2" --help 2>&1 | head -n 1 | awk '{print $NF}' || echo "unknown"
    else
        echo "not installed"
    fi
}

# Показать информацию о системе
show_system_info() {
    print_header "Информация о системе"

    printf "%-20s: %s\n" "Архитектура" "$(get_arch)"
    printf "%-20s: %s\n" "Entware" "$([ -d /opt ] && echo 'установлен' || echo 'не установлен')"
    printf "%-20s: %s\n" "Свободное место" "$(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo 'unknown')"
    printf "%-20s: %s\n" "zapret2" "$(is_zapret2_installed && echo 'установлен' || echo 'не установлен')"
    printf "%-20s: %s\n" "nfqws2 версия" "$(get_nfqws2_version)"
    printf "%-20s: %s\n" "Сервис" "$(get_service_status)"
    printf "%-20s: %s\n" "Текущая стратегия" "#$(get_current_strategy)"

    print_separator
}

# Запрос подтверждения у пользователя
confirm() {
    local prompt=${1:-"Продолжить?"}
    local default=${2:-"Y"}

    if [ "$default" = "Y" ]; then
        printf "%s [Y/n]: " "$prompt"
    else
        printf "%s [y/N]: " "$prompt"
    fi

    read -r answer </dev/tty

    case "$answer" in
        [Yy]|[Yy][Ee][Ss]|"")
            [ "$default" = "Y" ] && return 0
            [ "$answer" != "" ] && return 0
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Пауза с сообщением
pause() {
    local message=${1:-"Нажмите Enter для продолжения..."}
    printf "%s" "$message"
    read -r _ </dev/tty
}

# Очистить экран (если в интерактивном режиме)
clear_screen() {
    if [ -t 1 ]; then
        clear
    fi
}

# ==============================================================================
# ИНИЦИАЛИЗАЦИЯ
# ==============================================================================

# Создать рабочую директорию
init_work_dir() {
    mkdir -p "$WORK_DIR" "$LIB_DIR" || {
        print_error "Не удалось создать $WORK_DIR"
        return 1
    }
    return 0
}

# Очистка рабочей директории
cleanup_work_dir() {
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
        print_info "Рабочая директория очищена"
    fi
}

# Обработчик ошибок
error_handler() {
    local exit_code=$1
    local line_no=$2

    print_error "Ошибка в строке $line_no (код: $exit_code)"
    cleanup_work_dir
    exit "$exit_code"
}

# Обработчик прерывания (Ctrl+C)
interrupt_handler() {
    printf "\n"
    print_warning "Прервано пользователем"
    cleanup_work_dir
    exit 130
}

# Установить обработчики сигналов
setup_signal_handlers() {
    trap 'interrupt_handler' INT TERM
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ (для использования в других модулях)
# ==============================================================================

# Все функции автоматически доступны после source этого файла
