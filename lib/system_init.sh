#!/bin/sh
# lib/system_init.sh - Инициализация системных переменных для z2k
# Заменяет вызов check_system() из zapret2/common/installer.sh

# ==============================================================================
# ОПРЕДЕЛЕНИЕ ТИПА СИСТЕМЫ
# ==============================================================================

init_system_vars() {
    print_info "Определение типа системы..."

    # Определить OS
    UNAME=$(uname -s)

    # Определить подсистему
    SUBSYS=""

    # Для Linux определить тип init системы
    if [ "$UNAME" = "Linux" ]; then
        # Проверить systemd
        if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
            SYSTEM="systemd"
            SYSTEMCTL="systemctl"
            INIT="systemd"
        # Проверить OpenRC
        elif [ -f /sbin/openrc-run ] || [ -f /usr/sbin/openrc-run ]; then
            SYSTEM="openrc"
            INIT="openrc"
        # Проверить OpenWrt/Keenetic (procd)
        elif [ -f /etc/openwrt_release ] || [ -f /opt/etc/init.d/rc.func ]; then
            SYSTEM="openwrt"
            INIT="procd"
        # Generic Linux (SysV init или custom)
        else
            SYSTEM="linux"
            INIT="sysv"
        fi

        print_success "Система: $SYSTEM (init: $INIT)"

    elif [ "$UNAME" = "FreeBSD" ] || [ "$UNAME" = "OpenBSD" ]; then
        SYSTEM="bsd"
        INIT="rc"
        print_success "Система: BSD"

    elif [ "$UNAME" = "Darwin" ]; then
        SYSTEM="macos"
        INIT="launchd"
        print_success "Система: macOS"

    else
        print_warning "Неизвестная система: $UNAME"
        SYSTEM="unknown"
        INIT="unknown"
    fi

    # Экспортировать переменные для использования в других модулях
    export SYSTEM
    export SUBSYS
    export UNAME
    export INIT
    export SYSTEMCTL

    # Показать детали
    print_info "Переменные окружения:"
    print_info "  SYSTEM=$SYSTEM"
    print_info "  UNAME=$UNAME"
    print_info "  INIT=$INIT"
    [ -n "$SYSTEMCTL" ] && print_info "  SYSTEMCTL=$SYSTEMCTL"

    return 0
}

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

# Определить является ли система Keenetic
is_keenetic() {
    # Проверка наличия Keenetic-специфичных файлов
    [ -f /opt/etc/init.d/rc.func ] && return 0

    # Проверка на NDM (Keenetic firmware)
    [ -d /opt/etc/ndm ] && return 0

    return 1
}

# Получить версию Keenetic firmware (если доступно)
get_keenetic_version() {
    if [ -f /etc/os-release ]; then
        grep VERSION_ID /etc/os-release | cut -d'=' -f2 | tr -d '"'
    elif command -v ndmc >/dev/null 2>&1; then
        ndmc -c "show version" 2>/dev/null | grep "release:" | awk '{print $2}'
    else
        echo "unknown"
    fi
}

# ==============================================================================
# KEENETIC СПЕЦИФИЧНЫЕ ПРОВЕРКИ
# ==============================================================================

check_keenetic_specifics() {
    if is_keenetic; then
        print_info "Обнаружен роутер Keenetic"

        local fw_version
        fw_version=$(get_keenetic_version)
        [ "$fw_version" != "unknown" ] && print_info "Firmware версия: $fw_version"

        # Проверить наличие NDM hooks
        if [ -d /opt/etc/ndm ]; then
            print_info "NDM hooks доступны"
        fi

        # Проверить fastnat
        if [ -f /sys/kernel/fastnat/mode ]; then
            local fastnat_mode
            fastnat_mode=$(cat /sys/kernel/fastnat/mode 2>/dev/null || echo "unknown")
            print_info "Fastnat mode: $fastnat_mode"
        fi

        return 0
    fi

    return 1
}
