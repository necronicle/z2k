#!/bin/sh
# lib/webpanel.sh — menu entry for z2k webpanel install/uninstall/control.
# Sourced from lib/menu.sh.

WEBPANEL_DIR="/opt/zapret2/webpanel"
WEBPANEL_INIT="/opt/etc/init.d/S96z2k-webpanel"
WEBPANEL_PORT_FILE="$WEBPANEL_DIR/port"
WEBPANEL_PIDFILE="/var/run/z2k-webpanel.pid"

# Source dir for webpanel assets — depends on where z2k.sh placed them.
# At runtime z2k bootstraps into /tmp/z2k/, so this is where webpanel/ lives.
webpanel_source_dir() {
    for d in /tmp/z2k/webpanel /opt/zapret2/webpanel-src; do
        [ -d "$d" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

webpanel_is_installed() {
    [ -x "$WEBPANEL_INIT" ] && [ -d "$WEBPANEL_DIR" ]
}

webpanel_is_running() {
    [ -f "$WEBPANEL_PIDFILE" ] && kill -0 "$(cat "$WEBPANEL_PIDFILE" 2>/dev/null)" 2>/dev/null
}

webpanel_url() {
    local port="8088"
    [ -r "$WEBPANEL_PORT_FILE" ] && port=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null | tr -dc '0-9')
    [ -z "$port" ] && port=8088
    local ip=""
    # Pick the real LAN IP. History: we used to take "first RFC1918 hit",
    # which on Rostelecom routers gave the 10.4.x.x provider-side interconnect
    # instead of the 192.168.1.1 bridge (Владислав's report 2026-04-15).
    # Priority: 192.168.* first (practically never used for ISP interconnect),
    # then 172.16-31.* (rare private net), then 10.* (last — most common
    # ISP interconnect/CGNAT). Within each band we take the first hit.
    for pattern in \
        '192\.168\.' \
        '172\.(1[6-9]|2[0-9]|3[01])\.' \
        '10\.' ; do
        ip=$(ip -4 addr show 2>/dev/null \
            | awk -v p="$pattern" '$0 ~ ("inet " p) {split($2,a,"/"); print a[1]; exit}')
        [ -n "$ip" ] && break
    done
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    fi
    [ -z "$ip" ] && ip="<router-ip>"
    printf 'http://%s:%s/' "$ip" "$port"
}

menu_webpanel() {
    clear_screen
    print_header "[P] Веб-панель"

    local installed="нет"
    local running="нет"
    webpanel_is_installed && installed="да"
    webpanel_is_running   && running="да"

    print_separator
    print_info "Установлена: $installed"
    print_info "Запущена:    $running"
    if webpanel_is_installed; then
        print_info "URL:         $(webpanel_url)"
        print_info "Доступ:      только в локальной сети, без пароля"
    fi
    print_separator

    cat <<'SUBMENU'

Веб-панель — дубль CLI меню в браузере: дашборд, toggle'ы режимов,
whitelist, логи. Ставится отдельно через меню, LAN-only, без авторизации.

[1] Установить / Переустановить
[2] Удалить
[3] Перезапустить
[4] Показать URL
[B] Назад

SUBMENU

    printf "Выберите опцию [1-4,B]: "
    read_input wp_choice

    case "$wp_choice" in
        1) webpanel_do_install  ;;
        2) webpanel_do_uninstall ;;
        3) webpanel_do_restart   ;;
        4) webpanel_show_credentials ;;
        b|B) return 0 ;;
        *) print_error "Неверный выбор: $wp_choice"; pause ;;
    esac
}

webpanel_do_install() {
    local src
    if ! src=$(webpanel_source_dir); then
        print_error "Исходники webpanel не найдены."
        print_info "Ожидалось: /tmp/z2k/webpanel/ (при запуске через z2k.sh)"
        pause
        return 1
    fi
    print_info "Запуск установщика из $src ..."
    sh "$src/install.sh" || {
        print_error "Установка не удалась"
        pause
        return 1
    }
    pause
}

webpanel_do_uninstall() {
    if ! webpanel_is_installed; then
        print_info "Веб-панель не установлена"
        pause
        return 0
    fi
    printf "Удалить веб-панель? [y/N]: "
    read_input confirm
    case "$confirm" in
        y|Y) ;;
        *) print_info "Отмена"; pause; return 0 ;;
    esac

    local src
    if src=$(webpanel_source_dir) && [ -f "$src/uninstall.sh" ]; then
        sh "$src/uninstall.sh" || {
            print_error "Удаление не удалось"
            pause
            return 1
        }
    else
        # Fallback: inline uninstall
        [ -x "$WEBPANEL_INIT" ] && "$WEBPANEL_INIT" stop 2>/dev/null
        pkill -f "lighttpd.*$WEBPANEL_DIR" 2>/dev/null || true
        rm -f "$WEBPANEL_INIT" "$WEBPANEL_PIDFILE" \
              /tmp/z2k-webpanel-error.log \
              /tmp/z2k-webpanel-startcheck.log
        rm -rf /opt/zapret2/www "$WEBPANEL_DIR"
        print_success "Веб-панель удалена"
    fi
    pause
}

webpanel_do_restart() {
    if ! webpanel_is_installed; then
        print_error "Веб-панель не установлена"
        pause
        return 1
    fi
    "$WEBPANEL_INIT" restart
    pause
}

webpanel_show_credentials() {
    if ! webpanel_is_installed; then
        print_error "Веб-панель не установлена"
        pause
        return 1
    fi
    print_info "URL:    $(webpanel_url)"
    print_info "Доступ: только в локальной сети, без пароля"
    pause
}
