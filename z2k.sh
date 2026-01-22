#!/bin/sh
# z2k.sh - Bootstrap скрипт для z2k v2.0
# Модульный установщик zapret2 для роутеров Keenetic
# https://github.com/necronicle/z2k

set -e

# ==============================================================================
# КОНСТАНТЫ
# ==============================================================================

Z2K_VERSION="2.0.0"
WORK_DIR="/tmp/z2k"
LIB_DIR="${WORK_DIR}/lib"
GITHUB_RAW="https://raw.githubusercontent.com/necronicle/z2k/test"

# Список модулей для загрузки
MODULES="utils install strategies config menu discord"

# ==============================================================================
# ВСТРОЕННЫЕ FALLBACK ФУНКЦИИ
# ==============================================================================
# Минимальные функции для работы до загрузки модулей

print_info() {
    printf "[i] %s\n" "$1"
}

print_success() {
    printf "[✓] %s\n" "$1"
}

print_error() {
    printf "[✗] %s\n" "$1" >&2
}

die() {
    print_error "$1"
    [ -n "$2" ] && exit "$2" || exit 1
}

clear_screen() {
    if [ -t 1 ]; then
        clear 2>/dev/null || printf "\033c"
    fi
}

print_header() {
    printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "  %s\n" "$1"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
}

print_separator() {
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
}

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

# ==============================================================================
# ПРОВЕРКИ ОКРУЖЕНИЯ
# ==============================================================================

check_environment() {
    print_info "Проверка окружения..."

    # Проверка Entware
    if [ ! -d "/opt" ] || [ ! -x "/opt/bin/opkg" ]; then
        die "Entware не установлен! Установите Entware перед запуском z2k."
    fi

    # Проверка curl
    if ! command -v curl >/dev/null 2>&1; then
        print_info "curl не найден, устанавливаю..."
        /opt/bin/opkg update || die "Не удалось обновить opkg"
        /opt/bin/opkg install curl || die "Не удалось установить curl"
    fi

    # Проверка архитектуры
    local arch
    arch=$(uname -m)
    if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then
        print_info "ВНИМАНИЕ: z2k разработан для ARM64 Keenetic"
        print_info "Ваша архитектура: $arch"
        printf "Продолжить? [y/N]: "
        read -r answer </dev/tty
        [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "Отменено пользователем" 0
    fi

    print_success "Окружение проверено"
}

# ==============================================================================
# ЗАГРУЗКА МОДУЛЕЙ
# ==============================================================================

download_modules() {
    print_info "Загрузка модулей z2k..."

    # Создать директории
    mkdir -p "$LIB_DIR" || die "Не удалось создать $LIB_DIR"

    # Скачать каждый модуль
    for module in $MODULES; do
        local url="${GITHUB_RAW}/lib/${module}.sh"
        local output="${LIB_DIR}/${module}.sh"

        print_info "Загрузка lib/${module}.sh..."

        if curl -fsSL "$url" -o "$output"; then
            print_success "Загружен: ${module}.sh"
        else
            die "Ошибка загрузки модуля: ${module}.sh"
        fi
    done

    print_success "Все модули загружены"
}

source_modules() {
    print_info "Загрузка модулей в память..."

    for module in $MODULES; do
        local module_file="${LIB_DIR}/${module}.sh"

        if [ -f "$module_file" ]; then
            . "$module_file" || die "Ошибка загрузки модуля: ${module}.sh"
        else
            die "Модуль не найден: ${module}.sh"
        fi
    done

    print_success "Модули загружены"
}

# ==============================================================================
# ЗАГРУЗКА СТРАТЕГИЙ
# ==============================================================================

download_strategies_source() {
    print_info "Загрузка файла стратегий (strats_new.txt)..."

    local url="${GITHUB_RAW}/strats_new.txt"
    local output="${WORK_DIR}/strats_new.txt"

    if curl -fsSL "$url" -o "$output"; then
        local lines
        lines=$(wc -l < "$output")
        print_success "Загружено: strats_new.txt ($lines строк)"
    else
        die "Ошибка загрузки strats_new.txt"
    fi
}

download_tools() {
    print_info "Загрузка tools (blockcheck2-rutracker.sh)..."

    local tools_dir="${WORK_DIR}/tools"
    local url="${GITHUB_RAW}/blockcheck2-rutracker.sh"
    local output="${tools_dir}/blockcheck2-rutracker.sh"

    mkdir -p "$tools_dir" || die "Не удалось создать $tools_dir"

    if curl -fsSL "$url" -o "$output"; then
        chmod +x "$output" || true
        print_success "Загружено: tools/blockcheck2-rutracker.sh"
    else
        die "Ошибка загрузки blockcheck2-rutracker.sh"
    fi
}

generate_strategies_database() {
    print_info "Генерация базы стратегий (strategies.conf)..."

    # Эта функция определена в lib/strategies.sh
    if command -v generate_strategies_conf >/dev/null 2>&1; then
        generate_strategies_conf "${WORK_DIR}/strats_new.txt" "${WORK_DIR}/strategies.conf" || \
            die "Ошибка генерации strategies.conf"

        local count
        count=$(wc -l < "${WORK_DIR}/strategies.conf" | tr -d ' ')
        print_success "Сгенерировано стратегий: $count"
    else
        die "Функция generate_strategies_conf не найдена"
    fi
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ BOOTSTRAP
# ==============================================================================

show_welcome() {
    clear_screen

    cat <<'EOF'
╔═══════════════════════════════════════════════════╗
║   z2k - Zapret2 для Keenetic (PRE-ALPHA)        ║
║                   Версия 2.0.0                    ║
╚═══════════════════════════════════════════════════╝

  ⚠️  ВНИМАНИЕ: Проект в активной разработке!
  ⚠️  Это пре-альфа версия - НЕ используйте в production!

  GitHub: https://github.com/necronicle/z2k

EOF

    print_info "Инициализация..."
}

check_installation_status() {
    if is_zapret2_installed; then
        print_info "zapret2 уже установлен"
        print_info "Статус сервиса: $(get_service_status)"
        print_info "Текущая стратегия: #$(get_current_strategy)"
        return 0
    else
        print_info "zapret2 не установлен"
        return 1
    fi
}

prompt_install_or_menu() {
    printf "\n"

    if is_zapret2_installed; then
        print_info "Открываю меню управления..."
        sleep 1
        show_main_menu
    else
        print_info "zapret2 не установлен — запускаю установку..."
        run_full_install
    fi
}


# ==============================================================================
# ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ==============================================================================

handle_arguments() {
    local command=$1

    case "$command" in
        install|i)
            print_info "Запуск установки zapret2..."
            run_full_install
            print_info "Открываю меню управления..."
            sleep 1
            show_main_menu
            ;;
        menu|m)
            print_info "Открытие меню..."
            show_main_menu
            ;;
        uninstall|remove)
            print_info "Удаление zapret2..."
            uninstall_zapret2
            ;;
        status|s)
            show_system_info
            ;;
        update|u)
            print_info "Обновление z2k..."
            update_z2k
            ;;
        version|v)
            echo "z2k v${Z2K_VERSION}"
            echo "zapret2: $(get_nfqws2_version)"
            ;;
        help|h|-h|--help)
            show_help
            ;;
        "")
            # Без аргументов - показать welcome и предложить установку
            prompt_install_or_menu
            ;;
        *)
            print_error "Неизвестная команда: $command"
            show_help
            exit 1
            ;;
    esac
}

show_help() {
    cat <<EOF
Использование: sh z2k.sh [команда]

Команды:
  install, i       Установить zapret2
  menu, m          Открыть интерактивное меню
  uninstall        Удалить zapret2
  status, s        Показать статус системы
  update, u        Обновить z2k до последней версии
  version, v       Показать версию
  help, h          Показать эту справку

Без аргументов:
  - Если zapret2 не установлен: предложит установку
  - Если zapret2 установлен: откроет меню

Примеры:
  curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/test/z2k.sh | sh
  sh z2k.sh install
  sh z2k.sh menu

EOF
}

# ==============================================================================
# ФУНКЦИЯ ОБНОВЛЕНИЯ Z2K
# ==============================================================================

update_z2k() {
    print_header "Обновление z2k"

    local latest_url="${GITHUB_RAW}/z2k.sh"
    local current_script
    current_script=$(readlink -f "$0")

    print_info "Текущая версия: $Z2K_VERSION"
    print_info "Загрузка последней версии..."

    # Скачать новую версию во временный файл
    local temp_file
    temp_file=$(mktemp)

    if curl -fsSL "$latest_url" -o "$temp_file"; then
        # Получить версию из нового файла
        local new_version
        new_version=$(grep '^Z2K_VERSION=' "$temp_file" | cut -d'"' -f2)

        if [ "$new_version" = "$Z2K_VERSION" ]; then
            print_success "У вас уже последняя версия: $Z2K_VERSION"
            rm -f "$temp_file"
            return 0
        fi

        print_info "Новая версия: $new_version"

        # Создать backup текущего скрипта
        if [ -f "$current_script" ]; then
            cp "$current_script" "${current_script}.backup" || {
                print_error "Не удалось создать backup"
                rm -f "$temp_file"
                return 1
            }
        fi

        # Заменить скрипт
        mv "$temp_file" "$current_script" && chmod +x "$current_script"

        print_success "z2k обновлен: $Z2K_VERSION → $new_version"
        print_info "Backup сохранен: ${current_script}.backup"

        print_info "Перезапустите z2k для применения изменений"

    else
        print_error "Не удалось загрузить обновление"
        rm -f "$temp_file"
        return 1
    fi
}

# ==============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# ==============================================================================

main() {
    # Показать приветствие
    show_welcome

    # Проверить окружение
    check_environment

    # Инициализировать рабочую директорию
    mkdir -p "$WORK_DIR" "$LIB_DIR"

    # Установить обработчики сигналов (будет переопределено после загрузки utils.sh)
    trap 'echo ""; print_error "Прервано пользователем"; rm -rf "$WORK_DIR"; exit 130' INT TERM

    # Скачать модули
    download_modules

    # Загрузить модули в память
    source_modules

    # Теперь доступны все функции из модулей
    # Переустановить обработчики сигналов с правильными функциями
    setup_signal_handlers

    # Инициализация (создание рабочей директории с проверками из utils.sh)
    init_work_dir || die "Ошибка инициализации"

    # Проверить права root (нужно для установки)
    if [ "$1" = "install" ] || [ "$1" = "i" ]; then
        check_root || die "Требуются права root для установки"
    fi

    # Скачать strats_new.txt
    download_strategies_source

    # Скачать tools
    download_tools

    # Сгенерировать strategies.conf
    generate_strategies_database

    # Обработать аргументы командной строки
    handle_arguments "$1"

    # Очистка при выходе (если не удаляется автоматически)
    # cleanup_work_dir
}

# ==============================================================================
# ЗАПУСК
# ==============================================================================

main "$@"
