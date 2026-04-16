#!/bin/sh
# z2k.sh - Bootstrap скрипт для z2k v2.0
# Модульный установщик zapret2 для роутеров Keenetic
# https://github.com/necronicle/z2k

set -e

# ==============================================================================
# КОНСТАНТЫ
# ==============================================================================

Z2K_VERSION="2.0.1"
WORK_DIR="/tmp/z2k"
LIB_DIR="${WORK_DIR}/lib"
# Default branch URL — matches the branch this z2k.sh was fetched from.
# On merge to master this line is updated to master. Overridable via
# GITHUB_RAW env var for cross-branch testing.
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}"

# Экспортировать переменные для использования в функциях
export WORK_DIR
export LIB_DIR
export GITHUB_RAW

# Список модулей для загрузки
MODULES="utils system_init install strategies config config_official webpanel menu"

# ==============================================================================
# ВСТРОЕННЫЕ FALLBACK ФУНКЦИИ
# ==============================================================================
# Минимальные функции для работы до загрузки модулей

print_info() {
    printf "[i] %s\n" "$1"
}

print_success() {
    printf "[[OK]] %s\n" "$1"
}

print_error() {
    printf "[[FAIL]] %s\n" "$1" >&2
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
                print_info "Введите y/n"
                ;;
        esac
    done
}

# ==============================================================================
# ПРОВЕРКИ ОКРУЖЕНИЯ
# ==============================================================================

z2k_detect_entware_arch() {
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

# ВНИМАНИЕ: эта функция дублирует map_arch_to_bin_arch из utils.sh
# Дубликат необходим т.к. вызывается до загрузки модулей.
# При изменении — синхронизировать с lib/utils.sh:map_arch_to_bin_arch()
z2k_map_arch_to_bin_arch() {
    case "$1" in
        aarch64|arm64|*aarch64*|*arm64*) echo "linux-arm64" ;;
        armv7l|armv6l|arm|*armv7*|*armv6*|arm*) echo "linux-arm" ;;
        x86_64|amd64|*x86_64*|*amd64*) echo "linux-x86_64" ;;
        i386|i486|i586|i686|x86) echo "linux-x86" ;;
        *mipsel64*|*mips64el*) echo "linux-mipsel" ;;
        *mips64*) echo "linux-mips64" ;;
        *mipsel*) echo "linux-mipsel" ;;
        *mips*) echo "linux-mips" ;;
        *lexra*) echo "linux-lexra" ;;
        *ppc*) echo "linux-ppc" ;;
        *riscv64*) echo "linux-riscv64" ;;
        *) return 1 ;;
    esac
}

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
    local arch entware_arch bin_arch
    entware_arch=$(z2k_detect_entware_arch)
    arch="${entware_arch:-$(uname -m)}"
    # uname -m returns "mips" for both mips and mipsel — detect endianness from ELF
    if [ "$arch" = "mips" ]; then
        local _ebin=""
        for _f in /opt/bin/opkg /opt/bin/busybox; do [ -f "$_f" ] && _ebin="$_f" && break; done
        if [ -n "$_ebin" ]; then
            local _byte
            _byte=$(dd if="$_ebin" bs=1 skip=5 count=1 2>/dev/null)
            [ "$_byte" = "$(printf '\x01')" ] && arch="mipsel"
        fi
    fi
    bin_arch=$(z2k_map_arch_to_bin_arch "$arch" 2>/dev/null || true)
    [ -n "$bin_arch" ] && print_info "Detected architecture: $arch -> $bin_arch"

    if [ -z "$bin_arch" ]; then
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

        if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
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
    print_info "Загрузка файла стратегий (strats_new2.txt)..."

    local url="${GITHUB_RAW}/strats_new2.txt"
    local output="${WORK_DIR}/strats_new2.txt"

    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        local lines
        lines=$(wc -l < "$output")
        print_success "Загружено: strats_new2.txt ($lines строк)"
    else
        die "Ошибка загрузки strats_new2.txt"
    fi

    print_info "Загрузка QUIC стратегий (quic_strats.ini)..."
    local quic_url="${GITHUB_RAW}/quic_strats.ini"
    local quic_output="${WORK_DIR}/quic_strats.ini"

    if curl -fsSL --connect-timeout 10 --max-time 120 "$quic_url" -o "$quic_output"; then
        local lines
        lines=$(wc -l < "$quic_output")
        print_success "Загружено: quic_strats.ini ($lines строк)"
    else
        die "Ошибка загрузки quic_strats.ini"
    fi
}

download_fake_blobs() {
    print_info "Загрузка fake blobs (TLS + QUIC)..."

    local fake_dir="${WORK_DIR}/files/fake"
    mkdir -p "$fake_dir" || die "Не удалось создать $fake_dir"

    local files="
tls_clienthello_max_ru.bin
tls_clienthello_sberbank_ru.bin
tls_clienthello_14.bin
tls_clienthello_www_google_com.bin
tls_clienthello_www_onetrust_com.bin
tls_clienthello_activated.bin
tls_clienthello_4pda_to.bin
tls_clienthello_vk_com.bin
tls_clienthello_gosuslugi_ru.bin
t2.bin
syn_packet.bin
stun.bin
http_iana_org.bin
quic_initial_www_google_com.bin
quic_initial_google_com.bin
quic_initial_rutracker_org.bin
quic_1.bin
quic_4.bin
quic_5.bin
quic_6.bin
quic_test_00.bin
zero_256.bin
"

    while read -r file; do
        [ -z "$file" ] && continue
        local url="${GITHUB_RAW}/files/fake/${file}"
        local output="${fake_dir}/${file}"
        if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
            print_success "Загружено: files/fake/${file}"
        else
            die "Ошибка загрузки files/fake/${file}"
        fi
    done <<EOF
$files
EOF
}

download_init_script() {
    print_info "Загрузка вспомогательных файлов (init + lua helpers)..."

    local files_dir="${WORK_DIR}/files"
    mkdir -p "$files_dir" || die "Не удалось создать $files_dir"

    local url
    local output

    url="${GITHUB_RAW}/files/S99zapret2.new"
    output="${files_dir}/S99zapret2.new"

    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/S99zapret2.new"
    else
        die "Ошибка загрузки files/S99zapret2.new"
    fi

    url="${GITHUB_RAW}/files/000-zapret2.sh"
    output="${files_dir}/000-zapret2.sh"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/000-zapret2.sh"
    else
        die "Ошибка загрузки files/000-zapret2.sh"
    fi

    url="${GITHUB_RAW}/files/z2k-blocked-monitor.sh"
    output="${files_dir}/z2k-blocked-monitor.sh"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/z2k-blocked-monitor.sh"
    else
        die "Ошибка загрузки files/z2k-blocked-monitor.sh"
    fi

    # z2k tools (healthcheck, config validator, list updater, diagnostics, geosite, tg watchdog)
    for tool_name in z2k-healthcheck.sh z2k-config-validator.sh z2k-update-lists.sh z2k-fix-tg-iptables.sh z2k-diag.sh z2k-geosite.sh z2k-tg-watchdog.sh z2k-probe.sh; do
        url="${GITHUB_RAW}/files/${tool_name}"
        output="${files_dir}/${tool_name}"
        if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
            print_success "Загружено: files/${tool_name}"
        else
            print_warning "Не удалось загрузить files/${tool_name} (необязательный)"
        fi
    done

    # init scripts extracted from install.sh heredocs — tg-tunnel S98
    # autostart gets installed into /opt/etc/init.d/ later by lib/install.sh
    mkdir -p "${files_dir}/init.d"
    url="${GITHUB_RAW}/files/init.d/S98tg-tunnel"
    output="${files_dir}/init.d/S98tg-tunnel"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/init.d/S98tg-tunnel"
    else
        print_warning "Не удалось загрузить files/init.d/S98tg-tunnel (TG tunnel не будет автостартовать после ребута)"
    fi

    # Keenetic NDM netfilter.d hook for auto-restoring TG REDIRECT rules.
    mkdir -p "${files_dir}/ndm"
    url="${GITHUB_RAW}/files/ndm/90-z2k-tg-redirect.sh"
    output="${files_dir}/ndm/90-z2k-tg-redirect.sh"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/ndm/90-z2k-tg-redirect.sh"
    else
        print_warning "Не удалось загрузить ndm hook (iptables не будут авто-восстанавливаться)"
    fi

    # Web panel source tree — downloaded only if user installs via menu [P].
    # z2k.sh bootstraps files into /tmp/z2k/; install.sh copies from /tmp/z2k/webpanel.
    local webpanel_dir="${WORK_DIR}/webpanel"
    mkdir -p "$webpanel_dir/cgi" "$webpanel_dir/www" "$webpanel_dir/init.d"
    for wp_file in \
        install.sh uninstall.sh lighttpd.conf \
        init.d/S96z2k-webpanel \
        cgi/api.sh cgi/auth.sh cgi/actions.sh \
        www/index.html www/app.js www/style.css www/favicon.svg
    do
        url="${GITHUB_RAW}/webpanel/${wp_file}"
        output="${webpanel_dir}/${wp_file}"
        if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output" 2>/dev/null; then
            : # ok
        else
            print_warning "Не удалось загрузить webpanel/${wp_file} (опциональный компонент)"
        fi
    done

    # z2k Lua helpers (e.g., persistent autocircular strategy memory)
    local lua_dir="${files_dir}/lua"
    mkdir -p "$lua_dir" || die "Не удалось создать $lua_dir"

    # z2k-detectors.lua must be downloaded (and later loaded by nfqws2) BEFORE
    # z2k-autocircular.lua — the rotator resolves failure_detector= by global
    # name, and detectors live there after the Phase 4 module split.
    url="${GITHUB_RAW}/files/lua/z2k-detectors.lua"
    output="${lua_dir}/z2k-detectors.lua"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/lua/z2k-detectors.lua"
    else
        die "Ошибка загрузки files/lua/z2k-detectors.lua"
    fi

    # Phase 6: anti-ТСПУ fool extensions (z2k_dynamic_ttl and friends).
    # Strategies reference them by name via `fool=z2k_dynamic_ttl`, so the
    # file must be downloaded before strategies load — ordering mirrors
    # z2k-detectors.lua above.
    url="${GITHUB_RAW}/files/lua/z2k-fooling-ext.lua"
    output="${lua_dir}/z2k-fooling-ext.lua"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/lua/z2k-fooling-ext.lua"
    else
        die "Ошибка загрузки files/lua/z2k-fooling-ext.lua"
    fi

    # Phase 7: per-connection range randomisation for numeric strategy
    # args. Wraps fake/multisplit/fakedsplit/fakeddisorder/hostfakesplit
    # and resolves ranges like repeats=2-6 to sticky per-flow values.
    url="${GITHUB_RAW}/files/lua/z2k-range-rand.lua"
    output="${lua_dir}/z2k-range-rand.lua"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/lua/z2k-range-rand.lua"
    else
        die "Ошибка загрузки files/lua/z2k-range-rand.lua"
    fi

    url="${GITHUB_RAW}/files/lua/z2k-autocircular.lua"
    output="${lua_dir}/z2k-autocircular.lua"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/lua/z2k-autocircular.lua"
    else
        die "Ошибка загрузки files/lua/z2k-autocircular.lua"
    fi

    url="${GITHUB_RAW}/files/lua/z2k-modern-core.lua"
    output="${lua_dir}/z2k-modern-core.lua"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$output"; then
        print_success "Загружено: files/lua/z2k-modern-core.lua"
    else
        die "Ошибка загрузки files/lua/z2k-modern-core.lua"
    fi
    # Snapshot domain lists used by local install flow (no external list repos)
    local list_file
    local lists_dir="${files_dir}/lists"
    mkdir -p "$lists_dir" || die "Не удалось создать $lists_dir"

    local list_files="
extra_strats/TCP/YT/List.txt
extra_strats/TCP/RKN/List.txt
extra_strats/TCP/RKN/Discord.txt
extra_strats/UDP/YT/List.txt
game_ips.txt
roblox_ips.txt
"

    while read -r list_file; do
        [ -z "$list_file" ] && continue
        local list_url="${GITHUB_RAW}/files/lists/${list_file}"
        local list_out="${lists_dir}/${list_file}"
        mkdir -p "$(dirname "$list_out")"

        if curl -fsSL --connect-timeout 10 --max-time 120 "$list_url" -o "$list_out"; then
            print_success "Загружено: files/lists/${list_file}"
        else
            die "Ошибка загрузки files/lists/${list_file}"
        fi
    done <<EOF
$list_files
EOF
}

generate_strategies_database() {
    print_info "Генерация базы стратегий (strategies.conf)..."

    # Эта функция определена в lib/strategies.sh
    if command -v generate_strategies_conf >/dev/null 2>&1; then
        generate_strategies_conf "${WORK_DIR}/strats_new2.txt" "${WORK_DIR}/strategies.conf" || \
            die "Ошибка генерации strategies.conf"

        local count
        count=$(wc -l < "${WORK_DIR}/strategies.conf" | tr -d ' ')
        print_success "Сгенерировано стратегий: $count"
    else
        die "Функция generate_strategies_conf не найдена"
    fi

    print_info "Генерация базы QUIC стратегий (quic_strategies.conf)..."
    if command -v generate_quic_strategies_conf >/dev/null 2>&1; then
        generate_quic_strategies_conf "${WORK_DIR}/quic_strats.ini" "${WORK_DIR}/quic_strategies.conf" || \
            die "Ошибка генерации quic_strategies.conf"
    else
        die "Функция generate_quic_strategies_conf не найдена"
    fi
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ BOOTSTRAP
# ==============================================================================

show_welcome() {
    clear_screen

    cat <<EOF
+===================================================+
|          z2k - Zapret2 для Keenetic               |
|                   Версия $Z2K_VERSION                    |
+===================================================+

  GitHub: https://github.com/necronicle/z2k

EOF

    print_info "Инициализация..."
}

prompt_install_or_menu() {
    printf "\n"

    if is_zapret2_installed; then
        print_info "Открываю меню управления..."
        sleep 1
        show_main_menu
    else
        print_info "zapret2 не установлен - запускаю установку..."
        check_root || die "Требуются права root для установки"
        run_full_install
        print_info "Открываю меню управления..."
        sleep 1
        show_main_menu
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
        cleanup)
            print_info "Очистка старых бэкапов..."
            cleanup_backups "${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}" 5
            ;;
        check|info)
            print_info "Проверка активной конфигурации..."
            show_active_processing
            ;;
        rollback)
            print_info "Откат конфигурации..."
            rollback_to_snapshot
            ;;
        snapshot)
            print_info "Создание snapshot конфигурации..."
            create_rollback_snapshot "cli"
            ;;
        healthcheck|hc)
            if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/z2k-healthcheck.sh" ]; then
                sh "${ZAPRET2_DIR:-/opt/zapret2}/z2k-healthcheck.sh" --status
            else
                print_error "Скрипт healthcheck не найден"
            fi
            ;;
        validate)
            if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/z2k-config-validator.sh" ]; then
                sh "${ZAPRET2_DIR:-/opt/zapret2}/z2k-config-validator.sh"
            else
                print_error "Скрипт валидатора не найден"
            fi
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
  check, info      Показать какие списки обрабатываются
  update, u        Обновить z2k до последней версии
  cleanup          Очистить старые бэкапы (оставить 5 последних)
  rollback         Откатить конфигурацию к последнему snapshot
  snapshot         Создать snapshot текущей конфигурации
  healthcheck, hc  Проверить работоспособность DPI bypass
  validate         Валидация текущей конфигурации
  version, v       Показать версию
  help, h          Показать эту справку

Без аргументов:
  - Если zapret2 не установлен: предложит установку
  - Если zapret2 установлен: откроет меню

Примеры:
  curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh | sh
  sh z2k.sh install
  sh z2k.sh menu
  sh z2k.sh check
  sh z2k.sh cleanup

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

    case "$current_script" in
        */sh|*/bash|*/ash|*/dash)
            print_error "Cannot self-update: script was run via pipe. Please download and run directly."
            return 1
            ;;
    esac

    print_info "Текущая версия: $Z2K_VERSION"
    print_info "Загрузка последней версии..."

    # Скачать новую версию во временный файл
    local temp_file
    temp_file=$(mktemp)

    if curl -fsSL --connect-timeout 10 --max-time 120 "$latest_url" -o "$temp_file"; then
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

        # Update Telegram tunnel binary
        if [ -x "/opt/sbin/tg-mtproxy-client" ]; then
            print_info "Обновление Telegram tunnel..."
            local tg_arch=""
            local _arch _earch _barch
            _earch=$(z2k_detect_entware_arch)
            _arch="${_earch:-$(uname -m)}"
            _barch=$(z2k_map_arch_to_bin_arch "$_arch" 2>/dev/null || true)
            case "$_barch" in
                linux-arm64)    tg_arch="arm64" ;;
                linux-arm)      tg_arch="arm" ;;
                linux-mipsel)   tg_arch="mipsel" ;;
                linux-mips64el) tg_arch="mips64el" ;;
                linux-mips64)   tg_arch="mips" ;;
                linux-mips)     tg_arch="mips" ;;
                linux-x86_64)   tg_arch="amd64" ;;
                linux-x86)      tg_arch="x86" ;;
                linux-riscv64)  tg_arch="riscv64" ;;
                linux-ppc)      tg_arch="ppc64" ;;
            esac
            if [ -n "$tg_arch" ]; then
                local tg_url="${GITHUB_RAW}/mtproxy-client/builds/tg-mtproxy-client-linux-${tg_arch}"
                local tg_tmp
                tg_tmp=$(mktemp)
                if curl -fsSL --connect-timeout 10 --max-time 120 "$tg_url" -o "$tg_tmp" && \
                   [ "$(wc -c < "$tg_tmp")" -gt 500000 ] && \
                   head -c 4 "$tg_tmp" 2>/dev/null | grep -q "ELF"; then
                    killall tg-mtproxy-client 2>/dev/null || true
                    sleep 1
                    cp "$tg_tmp" /opt/sbin/tg-mtproxy-client
                    chmod +x /opt/sbin/tg-mtproxy-client
                    /opt/sbin/tg-mtproxy-client --listen=:1443 >> /tmp/tg-tunnel.log 2>&1 &
                    sleep 2
                    if pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
                        print_success "Telegram tunnel обновлён и перезапущен"
                    else
                        print_warning "Telegram tunnel обновлён, но не запустился"
                    fi
                else
                    print_warning "Не удалось обновить Telegram tunnel"
                fi
                rm -f "$tg_tmp"
            fi
        fi

        # Update watchdog script
        if [ -f "/opt/zapret2/tg-tunnel-watchdog.sh" ]; then
            cat > /opt/zapret2/tg-tunnel-watchdog.sh << 'WDEOF'
#!/bin/sh
LOG="/tmp/tg-tunnel.log"
BIN="/opt/sbin/tg-mtproxy-client"
[ ! -f "$LOG" ] && exit 0
pgrep -f "tg-mtproxy-client" >/dev/null || exit 0
FAILS=$(tail -40 "$LOG" | grep -c "CONNECT_FAIL")
if [ "$FAILS" -ge 10 ]; then
    logger -t tg-watchdog "Detected $FAILS CONNECT_FAILs, restarting tunnel"
    killall -9 tg-mtproxy-client 2>/dev/null
    sleep 2
    $BIN --listen=:1443 >> "$LOG" 2>&1 &
    echo "$(date) watchdog: restarted ($FAILS fails)" >> "$LOG"
fi
WDEOF
            chmod +x /opt/zapret2/tg-tunnel-watchdog.sh
            print_success "Watchdog обновлён"
        fi

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
    # Early-exit for help/version — no downloads needed
    case "$1" in
        help|h|-h|--help)
            show_help
            exit 0
            ;;
        version|v|--version)
            echo "z2k v${Z2K_VERSION}"
            exit 0
            ;;
    esac

    # Показать приветствие
    show_welcome

    # Проверить окружение
    check_environment

    # Инициализировать рабочую директорию
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$LIB_DIR"

    # Установить обработчики сигналов (будет переопределено после загрузки utils.sh)
    # Также очищаем временные директории при любом выходе
    trap 'echo ""; print_error "Прервано пользователем"; rm -rf "$WORK_DIR" /tmp/zapret2_build; exit 130' INT TERM
    trap 'rm -rf /tmp/zapret2_build' EXIT

    # Скачать модули
    download_modules

    # Загрузить модули в память
    source_modules

    # Теперь доступны все функции из модулей
    # Переустановить обработчики сигналов с правильными функциями
    setup_signal_handlers

    # Инициализировать системные переменные (SYSTEM, UNAME, INIT)
    init_system_vars || die "Ошибка определения типа системы"

    # Инициализация (создание рабочей директории с проверками из utils.sh)
    init_work_dir || die "Ошибка инициализации"

    # Проверить права root (нужно для установки)
    if [ "$1" = "install" ] || [ "$1" = "i" ]; then
        check_root || die "Требуются права root для установки"
    fi

    # Скачать strats_new2.txt
    download_strategies_source

    # Скачать fake blobs
    download_fake_blobs

    # Скачать init скрипт
    download_init_script


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
