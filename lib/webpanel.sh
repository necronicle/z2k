#!/bin/sh
# lib/webpanel.sh — menu entry for z2k webpanel install/uninstall/control.
# Sourced from lib/menu.sh.

WEBPANEL_DIR="/opt/zapret2/webpanel"
WEBPANEL_INIT="/opt/etc/init.d/S96z2k-webpanel"
WEBPANEL_PORT_FILE="$WEBPANEL_DIR/port"
WEBPANEL_BIND_FILE="$WEBPANEL_DIR/bind"
WEBPANEL_PIDFILE="/var/run/z2k-webpanel.pid"

# Source dir for webpanel assets — depends on where z2k.sh placed them.
# At runtime z2k bootstraps into /tmp/z2k/, so this is where webpanel/ lives.
webpanel_source_dir() {
    # Каталог мало найти — в нём должен быть установщик.
    #
    # z2k.sh создаёт /tmp/z2k/webpanel через mkdir ДО загрузки, а каждую
    # неудачную загрузку лишь предупреждает («опциональный компонент») и идёт
    # дальше. Поэтому пустой каталог — штатный исход сорванной сети, и проверка
    # `[ -d ]` его принимала: меню печатало «Запуск установщика из
    # /tmp/z2k/webpanel» и падало без внятной причины.
    for d in /tmp/z2k/webpanel /opt/zapret2/webpanel-src; do
        [ -f "$d/install.sh" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

webpanel_is_installed() {
    [ -x "$WEBPANEL_INIT" ] && [ -d "$WEBPANEL_DIR" ]
}

# Хоть какой-то след установки, в т.ч. частичной. Оборванный install мог
# оставить init без каталога (или наоборот): webpanel_is_installed для
# такого состояния false, и меню отказывалось удалять осиротевший init,
# который падает на каждом буте. Путь удаления гейтится этой проверкой.
webpanel_any_installed() {
    [ -e "$WEBPANEL_INIT" ] || [ -d "$WEBPANEL_DIR" ] || [ -d /opt/zapret2/www ]
}

webpanel_is_running() {
    [ -f "$WEBPANEL_PIDFILE" ] && kill -0 "$(cat "$WEBPANEL_PIDFILE" 2>/dev/null)" 2>/dev/null
}

webpanel_url() {
    local port="8088"
    [ -r "$WEBPANEL_PORT_FILE" ] && port=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null | tr -dc '0-9')
    [ -z "$port" ] && port=8088
    local ip=""
    # Записанный install.sh bind — единственный адрес, где панель реально
    # слушает. Повторная автодетекция здесь выдавала другой сегмент:
    # установка с --bind 192.168.5.1 (второй бридж) → меню печатало
    # http://192.168.1.1:8088/, где никто не слушает. 0.0.0.0 = слушаем
    # всюду, для URL детектим LAN IP как раньше.
    if [ -r "$WEBPANEL_BIND_FILE" ]; then
        ip=$(cat "$WEBPANEL_BIND_FILE" 2>/dev/null | tr -dc '0-9.')
        [ "$ip" = "0.0.0.0" ] && ip=""
    fi
    # Pick the real LAN IP. Two-pass: bridge interfaces (br*) first,
    # then any. Within each pass: 192.168.* → 172.16-31.* → 10.*.
    # History: 2026-04-15 (Владислав, Rostelecom) we promoted 192.168 over
    # 10.* to skip provider 10.4.x.x interconnect. 2026-04-18 (Эд) we added
    # bridge-first to skip routers with eth*.* in 192.168 range too.
    local pattern ifprefix
    if [ -z "$ip" ]; then
        for ifprefix in 'br' ''; do
            for pattern in \
                '192\.168\.' \
                '172\.(1[6-9]|2[0-9]|3[01])\.' \
                '10\.' ; do
                ip=$(ip -4 addr show 2>/dev/null \
                    | awk -v p="$pattern" -v ifp="$ifprefix" '
                        /^[0-9]+: / {
                            match($2, /^[^:@]+/)
                            iface = substr($2, RSTART, RLENGTH)
                            ok = (ifp == "" || index(iface, ifp) == 1)
                            next
                        }
                        ok && $0 ~ ("inet " p) {
                            split($2, a, "/")
                            print a[1]
                            exit
                        }
                    ')
                [ -n "$ip" ] && break 2
            done
        done
    fi
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
[5] Изменить адрес и порт
[B] Назад

SUBMENU

    printf "Выберите опцию [1-5,B]: "
    read_input wp_choice

    # Обработчики могут вернуть ненулевой код (например «веб-панель не
    # установлена» при [3]/[4], или ошибка установки). Под глобальным `set -e`
    # (z2k.sh) этот код всплыл бы вверх и молча закрыл всё меню — это и был баг:
    # [P]→[4] «Показать URL» без установленной вебморды роняло меню. `|| true`
    # гасит код возврата обработчика, меню остаётся живым.
    case "$wp_choice" in
        1) webpanel_do_install       || true ;;
        2) webpanel_do_uninstall     || true ;;
        3) webpanel_do_restart       || true ;;
        4) webpanel_show_credentials || true ;;
        5) webpanel_change_address   || true ;;
        b|B) return 0 ;;
        *) print_error "Неверный выбор: $wp_choice"; pause ;;
    esac
}

# [P]→[5] Изменить адрес и порт панели.
#
# ЗАЧЕМ ЭТО В ТЕРМИНАЛЕ, А НЕ В САМОЙ ПАНЕЛИ. Настройка меняет адрес, по
# которому панель отвечает. Ошибись в нём — и чинить будет уже нечем: страница,
# с которой правили, останется на старом адресе и не откроется. Терминал
# доступен в любом случае, поэтому единственная настройка, способная отрезать
# доступ к панели, живёт здесь.
#
# ЗАЧЕМ ВООБЩЕ. Адрес меняли правкой lighttpd.conf, а он генерируется из
# шаблона при каждой установке — правка стиралась каждым обновлением, и человек
# вписывал её заново изо дня в день. Установщик умеет и принимать адрес флагом,
# и переигрывать его при переустановке (маркер bind.explicit) — не хватало
# только способа задать, не набирая команду руками.
#
# Адрес не вводится строкой, а выбирается из тех, что роутер реально держит.
# Свободный ввод здесь — это ровно тот случай, когда опечатка оставляет человека
# без панели: lighttpd не встанет на чужой адрес и умрёт на старте.
# Адрес поднят на каком-то интерфейсе прямо сейчас? Тот же приём, что в
# установщике (webpanel/install.sh:_ip_present) — здесь он нужен только чтобы
# предупредить, решение остаётся за человеком.
_ip_present_local() {
    ip -4 addr show 2>/dev/null | grep -q "inet $1[/ ]"
}

webpanel_change_address() {
    if ! webpanel_is_installed; then
        print_info "Веб-панель не установлена — сначала пункт [1]"
        pause
        return 0
    fi

    local wp_dir="/opt/zapret2/webpanel"
    local cur_bind cur_port
    cur_bind=$(sed -n 's/^[[:space:]]*server\.bind[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
               "$wp_dir/lighttpd.conf" 2>/dev/null | head -1)
    cur_port=$(sed -n 's/^[[:space:]]*server\.port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
               "$wp_dir/lighttpd.conf" 2>/dev/null | head -1)

    clear_screen
    print_header "Адрес и порт веб-панели"
    print_info "Сейчас: ${cur_bind:-?}:${cur_port:-?}"
    print_separator

    # Адреса роутера показываем ПОДСКАЗКОЙ, а не списком выбора. Выбор из
    # списка запрещал бы то, что человек как раз и хочет: вписать адрес,
    # которого сейчас на интерфейсах нет — поднимаемый позже VPN, второй мост,
    # адрес, который вот-вот появится. Ошибётся — вернётся сюда и введёт снова,
    # для того этот пункт и в терминале, а не в самой панели.
    local addrs
    addrs=$(ip -4 addr show 2>/dev/null \
            | sed -n 's|^[[:space:]]*inet \([0-9.]*\)/.*|\1|p' \
            | grep -v '^127\.' | sort -u | tr '\n' ' ')
    [ -n "$addrs" ] && print_info "Адреса роутера: $addrs"
    print_info "0.0.0.0 — все интерфейсы (см. предупреждение ниже)"
    printf "\n"

    printf "Адрес [Enter — оставить %s]: " "${cur_bind:-как есть}"
    read_input wp_new_bind
    local new_bind="${wp_new_bind:-$cur_bind}"

    # Проверяем ФОРМАТ, а не принадлежность. Формат — это защита от опечатки
    # вроде «192.168.1.» или случайно вставленного URL: такое значение уедет
    # в конфиг, lighttpd не стартует, и человек останется без панели, не поняв
    # почему. Принадлежность адреса роутеру — не наше дело: адрес может
    # появиться позже.
    _valid_ipv4() {
        local _s="$1" _o1 _o2 _o3 _o4 _rest
        case "$_s" in
            *[!0-9.]*|*..*|.*|*.) return 1 ;;
        esac
        IFS=. read -r _o1 _o2 _o3 _o4 _rest <<EOF
$_s
EOF
        [ -n "$_o4" ] && [ -z "$_rest" ] || return 1
        for _o in "$_o1" "$_o2" "$_o3" "$_o4"; do
            [ -n "$_o" ] || return 1
            [ "$_o" -le 255 ] 2>/dev/null || return 1
        done
        return 0
    }
    if ! _valid_ipv4 "$new_bind"; then
        print_error "Это не адрес IPv4: $new_bind"
        pause
        return 1
    fi

    printf "Порт [1-65535, Enter — оставить %s]: " "${cur_port:-8088}"
    read_input wp_port_choice
    local new_port="${wp_port_choice:-${cur_port:-8088}}"
    case "$new_port" in
        ""|*[!0-9]*) print_error "Порт — только цифры"; pause; return 1 ;;
    esac
    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        print_error "Порт вне диапазона: $new_port"
        pause
        return 1
    fi

    if [ "$new_bind" = "$cur_bind" ] && [ "$new_port" = "$cur_port" ]; then
        print_info "Ничего не изменилось"
        pause
        return 0
    fi

    print_separator
    print_warning "Панель переедет на http://${new_bind}:${new_port}/"
    if [ "$new_bind" = "0.0.0.0" ]; then
        print_warning "0.0.0.0 — это ВСЕ интерфейсы, включая провайдерский и гостевой."
        print_warning "У панели нет пароля, а её CGI работает от root."
    elif ! _ip_present_local "$new_bind"; then
        # Предупреждение, а НЕ запрет: адрес может появиться позже — VPN,
        # второй мост, интерфейс, который сейчас не поднят. Но чаще это всё-таки
        # опечатка, и сказать об этом надо до того, как панель не поднимется.
        print_warning "Сейчас такого адреса на роутере нет."
        print_warning "Если он не появится, панель не поднимется — вернитесь сюда и введите другой."
    fi
    printf "\n"
    if ! confirm "Применить?" "N"; then
        print_info "Отмена"
        pause
        return 0
    fi

    # Переустановка панели установщиком с флагами. Только этот путь оставляет
    # маркер bind.explicit, ради которого всё и затевалось: без него следующая
    # же переустановка вернула бы автоопределённый адрес.
    local src
    if ! src=$(webpanel_source_dir); then
        print_error "Исходники webpanel не найдены."
        print_info "Ожидалось: /tmp/z2k/webpanel/ (при запуске через z2k.sh)"
        pause
        return 1
    fi
    print_info "Переустанавливаю панель на ${new_bind}:${new_port} ..."
    if ! sh "$src/install.sh" --bind "$new_bind" --port "$new_port"; then
        print_error "Не удалось применить: панель осталась на прежнем адресе"
        pause
        return 1
    fi
    print_success "Готово: http://${new_bind}:${new_port}/"
    print_info "Адрес и порт переживут обновления — заданы явно."
    pause
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
    # Гейт по «любому следу», а не по полной установке — иначе осиротевший
    # init от оборванной установки не убрать через меню (см.
    # webpanel_any_installed).
    if ! webpanel_any_installed; then
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
        local d b
        [ -x "$WEBPANEL_INIT" ] && "$WEBPANEL_INIT" stop 2>/dev/null
        # init мог быть снесён оборванной установкой — supervisor/waiter
        # добиваем по cmdline, иначе они поднимут lighttpd после удаления.
        pkill -f "$WEBPANEL_INIT" 2>/dev/null || true
        pkill -f "lighttpd.*$WEBPANEL_DIR" 2>/dev/null || true
        rm -f "$WEBPANEL_INIT" "$WEBPANEL_PIDFILE" \
              /var/run/z2k-webpanel-sup.pid \
              /var/run/z2k-webpanel-wait.pid \
              /tmp/z2k-log/z2k-webpanel-error.log \
              /tmp/z2k-log/z2k-webpanel-startcheck.log
        rm -rf /opt/zapret2/www "$WEBPANEL_DIR"
        # Штатный S*lighttpd, отключённый нашим install.sh, возвращаем на
        # место — иначе он остаётся выключенным навсегда (uninstall.sh в
        # штатном пути удаления делает то же самое).
        for d in /opt/etc/init.d/.S*lighttpd.disabled-by-z2k; do
            [ -e "$d" ] || continue
            b="${d##*/}"
            b="${b#.}"
            b="${b%.disabled-by-z2k}"
            [ -e "${d%/*}/$b" ] || mv "$d" "${d%/*}/$b" 2>/dev/null || true
        done
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
