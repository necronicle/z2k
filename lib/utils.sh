#!/bin/sh
# lib/utils.sh - Утилиты, проверки и константы для z2k
# Часть z2k v2.0 - Модульный установщик zapret2 для Keenetic

# ==============================================================================
# КОНСТАНТЫ
# ==============================================================================

# Версия z2k
Z2K_VERSION="2.0.1"

# Пути установки
ZAPRET2_DIR="/opt/zapret2"
CONFIG_DIR="/opt/etc/zapret2"
CATEGORY_STRATEGIES_CONF="${CONFIG_DIR}/category_strategies.conf"
LISTS_DIR="${ZAPRET2_DIR}/lists"

# Z2K-специфичная переменная для init скрипта (не конфликтует с zapret2)
Z2K_INIT_SCRIPT="/opt/etc/init.d/S99zapret2"

# Обратная совместимость (может перезаписываться модулями zapret2)
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"

# Экспортировать для использования в функциях
export ZAPRET2_DIR
export CONFIG_DIR
export LISTS_DIR
export Z2K_INIT_SCRIPT
export INIT_SCRIPT

# Рабочая директория
WORK_DIR="/tmp/z2k"
LIB_DIR="${WORK_DIR}/lib"

# GitHub URLs
GITHUB_RAW="https://raw.githubusercontent.com/necronicle/z2k/master"
Z4R_BASE_URL="https://raw.githubusercontent.com/IndeecFOX/zapret4rocket/master"
Z4R_LISTS_URL="${Z4R_BASE_URL}/lists"
Z2R_BASE_URL="https://raw.githubusercontent.com/AloofLibra/zapret4rocket/z2r"

# Файлы конфигурации
STRATEGIES_CONF="${CONFIG_DIR}/strategies.conf"
CURRENT_STRATEGY_FILE="${CONFIG_DIR}/current_strategy"
QUIC_STRATEGIES_CONF="${CONFIG_DIR}/quic_strategies.conf"
QUIC_STRATEGY_FILE="${CONFIG_DIR}/quic_strategy.conf"
RUTRACKER_QUIC_STRATEGY_FILE="${CONFIG_DIR}/rutracker_quic_strategy.conf"

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
# z2k_fetch — загрузка файла с GitHub через цепочку зеркал.
# ==============================================================================
#
# Дублирует функцию из z2k.sh для модулей/скриптов, которые source'ят
# lib/utils.sh напрямую (обход ломается у части ISP на raw.github —
# jsdelivr/gh-proxy/DNS override покрывают все известные сценарии блока).
#
# Слои (пробуем по порядку, первый успех возвращает 0):
#   1. raw.githubusercontent.com
#   2. cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>  (edge TTL 12ч)
#   3. gh-proxy.com/<raw-url>                             (без кеша)
#   4. (Keenetic) nslookup 8.8.8.8 → ndmc "ip host" → ретрай 1+2.
z2k_fetch() {
    local src="$1"
    local dest="$2"
    local url

    case "$src" in
        http://*|https://*) url="$src" ;;
        /*) url="${GITHUB_RAW}${src}" ;;
        *)  url="${GITHUB_RAW}/${src}" ;;
    esac

    local jsdelivr="" gh_proxy=""
    case "$url" in
        https://raw.githubusercontent.com/*)
            local _rest="${url#https://raw.githubusercontent.com/}"
            local _owner="${_rest%%/*}";  _rest="${_rest#*/}"
            local _repo="${_rest%%/*}";   _rest="${_rest#*/}"
            local _branch="${_rest%%/*}"; _rest="${_rest#*/}"
            jsdelivr="https://cdn.jsdelivr.net/gh/${_owner}/${_repo}@${_branch}/${_rest}"
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
        https://github.com/*/releases/download/*)
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
    esac

    if curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$url" 2>/dev/null; then
        return 0
    fi
    rm -f "$dest"
    if [ -n "$jsdelivr" ] && \
       curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$jsdelivr" 2>/dev/null; then
        return 0
    fi
    rm -f "$dest"
    if [ -n "$gh_proxy" ] && \
       curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$gh_proxy" 2>/dev/null; then
        return 0
    fi
    rm -f "$dest"

    if command -v ndmc >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
        local resolved_any=0 host ip
        for host in raw.githubusercontent.com cdn.jsdelivr.net gh-proxy.com api.github.com \
                    github.com objects.githubusercontent.com release-assets.githubusercontent.com; do
            ip=$(nslookup "$host" 8.8.8.8 2>/dev/null \
                 | awk '/^Name:/ {s=1; next} s && /^Address [0-9]+: [0-9]+\./ {print $3; exit}')
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "8.8.8.8" ]; then
                ndmc -c "ip host $host $ip" >/dev/null 2>&1 && resolved_any=1
            fi
        done
        if [ "$resolved_any" = "1" ]; then
            sleep 1
            if curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$url" 2>/dev/null; then
                return 0
            fi
            rm -f "$dest"
            if [ -n "$jsdelivr" ] && \
               curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$jsdelivr" 2>/dev/null; then
                return 0
            fi
            rm -f "$dest"
            if [ -n "$gh_proxy" ] && \
               curl -fsSL --connect-timeout 10 --max-time 180 -o "$dest" "$gh_proxy" 2>/dev/null; then
                return 0
            fi
            rm -f "$dest"
        fi
    fi

    return 1
}

# ==============================================================================
# ФУНКЦИИ ВЫВОДА
# ==============================================================================

print_success() {
    printf "${COLOR_GREEN}[[OK]]${COLOR_RESET} %s\n" "$1"
}

print_error() {
    printf "${COLOR_RED}[[FAIL]]${COLOR_RESET} %s\n" "$1" >&2
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

# Получить архитектуру Entware (предпочтительно для выбора бинарников)
get_entware_arch() {
    local opkg_bin="opkg"
    [ -x /opt/bin/opkg ] && opkg_bin="/opt/bin/opkg"
    command -v "$opkg_bin" >/dev/null 2>&1 || return 1

    "$opkg_bin" print-architecture 2>/dev/null | awk '
        $1 == "arch" && $2 != "all" {
            prio = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
            if (prio >= max) { max = prio; arch = $2 }
        }
        END { if (arch != "") print arch }
    '
}

map_arch_to_bin_arch() {
    case "$1" in
        aarch64|arm64|*aarch64*|*arm64*) echo "linux-arm64" ;;
        armv7l|armv6l|arm|*armv7*|*armv6*|arm*) echo "linux-arm" ;;
        x86_64|amd64|*x86_64*|*amd64*) echo "linux-x86_64" ;;
        i386|i486|i586|i686|x86) echo "linux-x86" ;;
        *mipsel64*|*mips64el*|*mips64le*) echo "linux-mips64el" ;;
        *mips64*) echo "linux-mips64" ;;
        *mipsel*) echo "linux-mipsel" ;;
        *mips*) echo "linux-mips" ;;
        *lexra*) echo "linux-lexra" ;;
        *ppc*) echo "linux-ppc" ;;
        *riscv64*) echo "linux-riscv64" ;;
        *) return 1 ;;
    esac
}

# Detect endianness from ELF header of a binary
detect_endianness() {
    local bin=""
    for f in /opt/bin/opkg /opt/bin/busybox /opt/sbin/nfqws2; do
        [ -f "$f" ] && bin="$f" && break
    done
    [ -z "$bin" ] && return 1
    # ELF EI_DATA is byte 6 (offset 5): \x01=LE, \x02=BE
    # dd + comparison works on any busybox
    local byte
    byte=$(dd if="$bin" bs=1 skip=5 count=1 2>/dev/null)
    case "$byte" in
        "$(printf '\x01')") echo "le" ;;
        "$(printf '\x02')") echo "be" ;;
        *) return 1 ;;
    esac
}

# Получить архитектуру системы (с приоритетом Entware)
get_arch() {
    local entware_arch
    entware_arch=$(get_entware_arch)
    if [ -n "$entware_arch" ]; then
        echo "$entware_arch"
        return
    fi

    local arch
    arch=$(uname -m)

    # uname -m returns "mips" for both mips and mipsel — detect endianness from ELF
    if [ "$arch" = "mips" ]; then
        local endian
        endian=$(detect_endianness)
        if [ "$endian" = "le" ]; then
            echo "mipsel"
            return
        fi
    fi

    echo "$arch"
}

# Проверка архитектуры
check_arch() {
    local arch
    arch=$(get_arch)

    if map_arch_to_bin_arch "$arch" >/dev/null 2>&1; then
        return 0
    fi

    print_warning "Архитектура $arch не поддерживается автоопределением"
    printf "Продолжить? [y/N]: "
    read -r answer </dev/tty
    [ "$answer" = "y" ] || return 1
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
        safe_config_read "CURRENT_STRATEGY" "$CURRENT_STRATEGY_FILE" "не задана"
    else
        echo "не задана"
    fi
}

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

# Безопасное чтение значения из config файла (без eval)
# Использование: val=$(safe_config_read "KEY" "/path/to/config")
safe_config_read() {
    local key=$1
    local file=$2
    local default=${3:-""}

    if [ ! -f "$file" ]; then
        echo "$default"
        return 0
    fi

    local raw
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -1)
    if [ -z "$raw" ]; then
        echo "$default"
        return 0
    fi

    # Извлечь значение после первого '=', удалить кавычки и пробелы
    local val
    val=$(printf '%s' "$raw" | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
    echo "$val"
}

# Скачать файл с проверкой
download_file() {
    local url=$1
    local output=$2
    local description=${3:-"Загрузка файла"}

    print_info "$description..."

    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: $output"
        return 0
    else
        print_error "Ошибка загрузки: $url"
        return 1
    fi
}

# Скачать файл с проверкой контрольной суммы (SHA256)
# Использование: download_file_verified URL OUTPUT EXPECTED_SHA256 [DESCRIPTION]
download_file_verified() {
    local url=$1
    local output=$2
    local expected_sha256=$3
    local description=${4:-"Загрузка файла"}

    print_info "$description..."

    if ! curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_error "Ошибка загрузки: $url"
        return 1
    fi

    # Если SHA256 не указан, пропустить проверку
    if [ -z "$expected_sha256" ] || [ "$expected_sha256" = "-" ]; then
        print_success "Загружено (без верификации): $output"
        return 0
    fi

    # Проверить контрольную сумму
    local actual_sha256
    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha256=$(sha256sum "$output" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        actual_sha256=$(openssl dgst -sha256 "$output" | awk '{print $NF}')
    else
        print_warning "sha256sum/openssl не найден, проверка пропущена"
        return 0
    fi

    if [ "$actual_sha256" != "$expected_sha256" ]; then
        print_error "ВНИМАНИЕ: контрольная сумма не совпадает!"
        print_error "  Ожидалось: $expected_sha256"
        print_error "  Получено:  $actual_sha256"
        print_error "Файл мог быть подменён (MITM-атака)!"
        rm -f "$output"
        return 1
    fi

    print_success "Загружено и верифицировано: $output"
    return 0
}

# Создать резервную копию файла
backup_file() {
    local file=$1
    local backup
    backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    local max_backups=5  # Хранить только последние 5 бэкапов

    if [ -f "$file" ]; then
        # Очистить старые бэкапы, оставив только последние (max_backups - 1)
        # -1 потому что сейчас создадим еще один
        # Удалить старые бэкапы напрямую (без subshell)
        ls -t "${file}.backup."* 2>/dev/null | tail -n +${max_backups} | xargs rm -f 2>/dev/null || true

        # Создать новый бэкап
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

# Очистить старые бэкапы для файла
cleanup_backups() {
    local file=$1
    local keep=${2:-5}  # По умолчанию хранить 5 последних

    local all_backups
    all_backups=$(ls -t "${file}.backup."* 2>/dev/null)

    if [ -z "$all_backups" ]; then
        print_info "Бэкапы не найдены для $file"
        return 0
    fi

    local total_count
    total_count=$(echo "$all_backups" | wc -l)

    if [ "$total_count" -le "$keep" ]; then
        print_info "Бэкапов: $total_count (в пределах нормы)"
        return 0
    fi

    # Удалить старые бэкапы напрямую (xargs — без subshell mutation)
    local deleted
    deleted=$(echo "$all_backups" | tail -n +$((keep + 1)) | xargs rm -f 2>/dev/null; echo "$all_backups" | tail -n +$((keep + 1)) | wc -l | tr -d ' ')

    print_success "Очищено бэкапов: ${deleted}, осталось: ${keep}"
    return 0
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

    if lsmod | grep -q "^${module} "; then
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
    local answer=""

    while true; do
        if [ "$default" = "Y" ]; then
            printf "%s [Y/n]: " "$prompt"
        else
            printf "%s [y/N]: " "$prompt"
        fi

        if ! read -r answer </dev/tty; then
            return 1
        fi

        answer=$(printf '%s' "$answer" | tr -d "$(printf '\r\b\177')" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        case "$answer" in
            "")
                [ "$default" = "Y" ] && return 0
                return 1
                ;;
            *[Yy]|*[Yy][Ee][Ss]|*[Дд]|*[Дд][Аа])
                return 0
                ;;
            *[Nn]|*[Nn][Oo]|*[Нн][Ее][Тт])
                return 1
                ;;
            *)
                print_warning "Введите y/n"
                ;;
        esac
    done
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
