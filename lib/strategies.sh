#!/bin/sh
# lib/strategies.sh - Управление стратегиями zapret2
# Парсинг, тестирование, применение стратегий из strats_new2.txt
# QUIC/UDP стратегии берутся из quic_strats.ini

# ==============================================================================
# РАБОТА С ФАЙЛАМИ СТРАТЕГИЙ ПО КАТЕГОРИЯМ (CONFIG-DRIVEN АРХИТЕКТУРА)
# ==============================================================================

# Сохранить стратегию в файл категории
# $1 - категория (YT, YT_GV, RKN, RUTRACKER)
# $2 - протокол (TCP или UDP)
# $3 - параметры стратегии
save_strategy_to_category() {
    local category=$1
    local protocol=$2
    local params=$3

    if [ -z "$category" ] || [ -z "$protocol" ] || [ -z "$params" ]; then
        print_error "save_strategy_to_category: некорректные параметры"
        return 1
    fi

    local strategy_file="${ZAPRET2_DIR:-/opt/zapret2}/extra_strats/${protocol}/${category}/Strategy.txt"

    # Создать директорию если не существует
    mkdir -p "$(dirname "$strategy_file")" || {
        print_error "Не удалось создать директорию для стратегии $category/$protocol"
        return 1
    }

    # Сохранить параметры
    echo "$params" > "$strategy_file" || {
        print_error "Не удалось сохранить стратегию в $strategy_file"
        return 1
    }

    return 0
}

# Создать дефолтные файлы стратегий при установке
# Вызывается из step_create_config_and_init()
# Номера боевых пулов в манифесте strats_new2.txt: YouTube TCP, YouTube GV, RKN.
#
# ОДНО МЕСТО НА ВЕСЬ ПРОДУКТ. Их читает и первичная материализация при установке
# (create_default_strategy_files), и повторное применение из меню
# (apply_autocircular_strategies). Пока номера жили в двух местах, разъехаться
# они могли молча — и человек получил бы конфиг, собранный из одного пула, при
# меню, показывающем другой.
default_pool_numbers() {
    Z2K_POOL_YT=2
    Z2K_POOL_GV=3
    Z2K_POOL_RKN=1
}
create_default_strategy_files() {
    local extra_strats_dir="${ZAPRET2_DIR:-/opt/zapret2}/extra_strats"

    print_info "Создание дефолтных файлов стратегий..."

    # Создать директории
    mkdir -p "$extra_strats_dir/TCP/YT"
    mkdir -p "$extra_strats_dir/TCP/YT_GV"
    mkdir -p "$extra_strats_dir/TCP/RKN"
    mkdir -p "$extra_strats_dir/UDP/YT"

    # СРАЗУ БОЕВЫЕ ПУЛЫ, А НЕ ЗАГЛУШКИ.
    #
    # Раньше здесь писались временные строки: для TCP — один фейк без circular
    # вообще, для UDP — четырёхкилобайтная копия QUIC-пула прямо в этом файле.
    # Из них тут же собирался NFQWS2_OPT (install.sh: create_official_config
    # идёт следующим шагом), и только в самом конце установки
    # apply_autocircular_strategies перетирал всё боевыми пулами и генерил
    # конфиг во второй раз. То есть конфиг собирался дважды, первый раз — из
    # стратегии без ротации; обрыв установки между этими шагами оставлял
    # человека с рабочим сервисом и одним фейком вместо пула.
    #
    # Берём то же самое и оттуда же, откуда возьмёт apply: strategies.conf и
    # quic_strategies.conf, разобранные из манифестов strats_new2.txt и
    # quic_strats.ini (lib/config.sh: create_base_config кладёт их в CONFIG_DIR
    # раньше по ходу установки). Поздний apply становится идемпотентным —
    # пишет ровно то, что уже лежит.
    local yt gv rkn quic p_yt p_gv p_rkn p_quic
    default_pool_numbers; yt=$Z2K_POOL_YT; gv=$Z2K_POOL_GV; rkn=$Z2K_POOL_RKN
    quic=$(get_quic_strategy_num_by_name "yt_quic_autocircular" 2>/dev/null)
    [ -n "$quic" ] || quic=2

    p_yt=$(get_strategy "$yt" 2>/dev/null)
    p_gv=$(get_strategy "$gv" 2>/dev/null)
    p_rkn=$(get_strategy "$rkn" 2>/dev/null)
    p_quic=$(get_quic_strategy "$quic" 2>/dev/null)

    # ДЕГРАДИРУЕМ ПОШТУЧНО, А НЕ СКОПОМ.
    #
    # Раньше здесь стояло `if [ -n "$p_yt" ] && [ -n "$p_gv" ] && ... ; then`:
    # один непрочитавшийся манифест ронял ВСЕ ЧЕТЫРЕ пула в аварийный дефолт.
    # То есть порча одного файла стоила обхода на всех категориях сразу, и
    # происходило это молча — чтения идут с 2>/dev/null.
    local degraded=0

    # НЕТ АВАРИЙНОГО НАБОРА — НЕ ПОВОД РОНЯТЬ УСТАНОВКУ.
    #
    # Сами наборы живут в lib/utils.sh (почему — см. комментарий там). Если
    # strategies.sh подключили без utils.sh, подстановка $(z2k_emergency_*)
    # даёт ПУСТУЮ строку, save_strategy_to_category отвергает её fail-closed
    # (:19-22), и `|| return 1` доходит до шага 10 (lib/install.sh:3269) —
    # z2k_restore_old_tree откатывает установку целиком из-за неподключённой
    # библиотеки. Поэтому файл в этом случае не пишем вовсе: пустой пул
    # подхватит _z2k_pool_default генератора конфига (lib/config_official.sh),
    # у него свой ротирующий запасной набор.
    local emerg=1
    if ! command -v z2k_emergency_tcp_pool >/dev/null 2>&1 ||
       ! command -v z2k_emergency_quic_pool >/dev/null 2>&1; then
        emerg=0
        print_warning "Аварийные наборы недоступны (utils.sh не подключён) — непрочитавшиеся пулы оставлены генератору конфига"
    fi

    if [ -n "$p_yt" ]; then
        save_strategy_to_category "YT" "TCP" "$(build_tls_profile_params "$p_yt")" || return 1
    else
        print_warning "Пул YouTube TCP (#$yt) не прочитался — аварийный набор с ротацией"
        if [ "$emerg" = "1" ]; then
            save_strategy_to_category "YT" "TCP" "$(z2k_emergency_tcp_pool yt_tcp)" || return 1
        fi
        degraded=$((degraded + 1))
    fi

    if [ -n "$p_gv" ]; then
        save_strategy_to_category "YT_GV" "TCP" "$(build_tls_profile_params "$p_gv")" || return 1
    else
        print_warning "Пул googlevideo (#$gv) не прочитался — аварийный набор с ротацией"
        if [ "$emerg" = "1" ]; then
            save_strategy_to_category "YT_GV" "TCP" "$(z2k_emergency_tcp_pool gv_tcp)" || return 1
        fi
        degraded=$((degraded + 1))
    fi

    if [ -n "$p_rkn" ]; then
        save_strategy_to_category "RKN" "TCP" "$(build_tls_profile_params "$p_rkn")" || return 1
    else
        print_warning "Пул РКН (#$rkn) не прочитался — аварийный набор с ротацией"
        if [ "$emerg" = "1" ]; then
            save_strategy_to_category "RKN" "TCP" "$(z2k_emergency_tcp_pool rkn_tcp)" || return 1
        fi
        degraded=$((degraded + 1))
    fi

    if [ -n "$p_quic" ]; then
        save_strategy_to_category "YT" "UDP" "$(build_quic_profile_params "$p_quic")" || return 1
        # Зафиксировать выбор QUIC-пула, иначе get_current_quic_profile_params
        # у позднего apply вернёт другой номер и файл будет переписан зря.
        set_current_quic_strategy "$quic"
    else
        print_warning "Пул QUIC (#$quic) не прочитался — аварийный набор с ротацией"
        if [ "$emerg" = "1" ]; then
            save_strategy_to_category "YT" "UDP" "$(z2k_emergency_quic_pool)" || return 1
        fi
        degraded=$((degraded + 1))
    fi

    if [ "$degraded" -eq 0 ]; then
        print_success "Стратегии материализованы из манифестов (YT #$yt, GV #$gv, RKN #$rkn, QUIC #$quic)"
    else
        print_warning "Стратегии материализованы, но $degraded из 4 пулов — аварийные"
    fi
    return 0
}

# custom_strategies.d удалён. Дроп-ин никогда не работал: функция
# загрузки не вызывалась ниоткуда, каталог только создавался при установке и не
# читался ни разу, а генератор конфига берёт четыре захардкоженных пути
# (config_official.sh: TCP/YT, TCP/YT_GV, TCP/RKN, UDP/YT) — произвольная
# категория из .conf в NFQWS2_OPT попасть не могла в принципе. README при этом
# пять месяцев учил класть туда файлы и перезапускать сервис, так что человек
# оставался уверен, что его стратегия работает. Живой механизм — свои строки на
# пул в lists/custom-strategies/<pool>.txt, они читаются при каждой пересборке
# конфига и проверяются движком перед применением (webpanel/cgi/actions.sh).

# ==============================================================================
# ПАРСИНГ STRATS.TXT → STRATEGIES.CONF
# ==============================================================================

# Генерация strategies.conf из strats_new2.txt
# Формат входа: curl_test_http[s] ipv4 rutracker.org : nfqws2 <параметры>
# Формат выхода: [NUMBER]|[TYPE]|[PARAMETERS]
generate_strategies_conf() {
    local input_file=$1
    local output_file=$2

    if [ ! -f "$input_file" ]; then
        print_error "Файл не найден: $input_file"
        return 1
    fi

    print_info "Парсинг $input_file..."

    # Создать заголовок
    cat > "$output_file" <<'EOF'
# Zapret2 Strategies Database
# Сгенерировано из blockcheck2 output
# Формат: [NUMBER]|[TYPE]|[PARAMETERS]
EOF

    local num=1
    local https_count=0

    # Строки-заголовки/комментарии/пустые отсеиваются в самом цикле ниже
    # (grep на ^#, пустую строку и обязательный ' : nfqws2'), поэтому НЕ
    # режем первую строку через tail — иначе реальная стратегия на строке 1
    # молча терялась бы.
    # ВАЖНО: разделитель " : " (пробел-двоеточие-пробел), а НЕ ":", т.к. параметры содержат двоеточия!
    while read -r line; do
        # Пропустить пустые строки
        # Normalize CRLF
        line=$(printf '%s' "$line" | sed 's/\r$//')

        # Skip empty lines and comments
        echo "$line" | grep -q '^[[:space:]]*$' && continue
        echo "$line" | grep -q '^[[:space:]]*#' && continue

        # Accept only real strategy lines
        echo "$line" | grep -q ' : nfqws2\([[:space:]]\|$\)' || continue

        # Разделить по " : " используя awk
        local test_cmd
        test_cmd=$(echo "$line" | awk -F ' : ' '{print $1}')
        local nfqws_params
        nfqws_params=$(echo "$line" | awk -F ' : ' '{print $2}')

        local type="https"
        https_count=$((https_count + 1))

        # Извлечь nfqws2 параметры (удалить " nfqws2 " в начале)
        local params
        params=$(echo "$nfqws_params" | sed 's/^ *nfqws2 *//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # Пропустить если параметры пустые
        [ -z "$params" ] && continue

        # Записать в strategies.conf
        echo "${num}|${type}|${params}" >> "$output_file"

        num=$((num + 1))
    done < "$input_file"

    # Подсчет и валидация
    local total_count
    total_count=$(grep -c '^[0-9]' "$output_file" 2>/dev/null | tr -d '[:space:]')
    total_count=${total_count:-0}

    if [ "$total_count" -eq 0 ] 2>/dev/null || [ -z "$total_count" ]; then
        print_error "Стратегии не найдены в $input_file (проверьте формат файла)"
        return 1
    fi

    print_success "Сгенерировано стратегий: $total_count"

    return 0
}

# ==============================================================================
# РАБОТА СО СТРАТЕГИЯМИ
# ==============================================================================

# Получить стратегию по номеру
get_strategy() {
    local num=$1
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        print_error "Файл стратегий не найден: $conf"
        return 1
    fi

    grep "^${num}|" "$conf" | cut -d'|' -f3
}

# Получить QUIC стратегию по номеру
get_quic_strategy() {
    local num=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        print_error "Файл QUIC стратегий не найден: $conf"
        return 1
    fi

    grep "^${num}|" "$conf" | cut -d'|' -f3
}

# Получить общее количество QUIC стратегий
get_quic_strategies_count() {
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ ! -f "$conf" ]; then
        echo "0"
        return
    fi

    grep -c '^[0-9]' "$conf" 2>/dev/null || echo "0"
}

# Проверить существование QUIC стратегии
quic_strategy_exists() {
    local num=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    [ -f "$conf" ] && grep -q "^${num}|" "$conf"
}

# Получить номер QUIC стратегии по имени секции (из quic_strategies.conf)
get_quic_strategy_num_by_name() {
    local name=$1
    local conf="${QUIC_STRATEGIES_CONF:-${CONFIG_DIR}/quic_strategies.conf}"

    if [ -z "$name" ] || [ ! -f "$conf" ]; then
        return 1
    fi

    grep "|${name}|" "$conf" | head -n 1 | cut -d'|' -f1
}

# Получить текущую QUIC стратегию
get_current_quic_strategy() {
    local conf="${QUIC_STRATEGY_FILE:-${CONFIG_DIR}/quic_strategy.conf}"
    if [ -f "$conf" ]; then
        . "$conf"
        [ -n "$QUIC_STRATEGY" ] && echo "$QUIC_STRATEGY" && return 0
    fi
    echo "1"
}

# Сохранить текущую QUIC стратегию
set_current_quic_strategy() {
    local num=$1
    local conf="${QUIC_STRATEGY_FILE:-${CONFIG_DIR}/quic_strategy.conf}"
    echo "QUIC_STRATEGY=$num" > "$conf"
}

# Построить параметры QUIC профиля из стратегии
build_quic_profile_params() {
    local params=$1
    echo "--filter-udp=443 --filter-l7=quic ${params}"
}

# Получить параметры текущей QUIC стратегии
get_current_quic_profile_params() {
    local quic_strategy
    quic_strategy=$(get_current_quic_strategy)
    local quic_params
    quic_params=$(get_quic_strategy "$quic_strategy" 2>/dev/null)

    if [ -z "$quic_params" ]; then
        # ТОТ ЖЕ АВАРИЙНЫЙ ПУЛ, ЧТО КЛАДЁТ УСТАНОВКА.
        #
        # Здесь стоял одиночный fake:blob=fake_default_quic:repeats=6 — без
        # ротации и без key=yt_quic. При непрочитанном манифесте установка
        # честно клала аварийный пул с ротацией, а поздний apply в КОНЦЕ той же
        # установки перетирал его этой статикой: пул терял запасные слоты, а
        # состояние ротации уезжало в чужую ячейку (ключ по умолчанию).
        #
        # Набор уже полный (--filter-udp/--filter-l7 внутри), поэтому мимо
        # build_quic_profile_params: иначе фильтры задвоились бы и файл
        # разъехался бы с тем, что записала установка.
        command -v z2k_emergency_quic_pool >/dev/null 2>&1 || return 1
        z2k_emergency_quic_pool
        return 0
    fi

    build_quic_profile_params "$quic_params"
}

# Получить общее количество стратегий
get_strategies_count() {
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    if [ ! -f "$conf" ]; then
        echo "0"
        return
    fi

    grep -c '^[0-9]' "$conf" 2>/dev/null || echo "0"
}

# Проверить существование стратегии
strategy_exists() {
    local num=$1
    local conf="${STRATEGIES_CONF:-${CONFIG_DIR}/strategies.conf}"

    [ -f "$conf" ] && grep -q "^${num}|" "$conf"
}

# Проверки наличия параметров в стратегии
params_has_filter_tcp() {
    case " $1 " in
        *" --filter-tcp="*) return 0 ;;
        *) return 1 ;;
    esac
}

params_has_filter_l7() {
    case " $1 " in
        *" --filter-l7="*) return 0 ;;
        *) return 1 ;;
    esac
}

params_has_payload() {
    case " $1 " in
        *" --payload="*) return 0 ;;
        *) return 1 ;;
    esac
}

build_tls_profile_params() {
    local params=$1
    local prefix=""
    local payload=""

    if ! params_has_filter_tcp "$params"; then
        prefix="--filter-tcp=443,2053,2083,2087,2096,8443"
    fi
    if ! params_has_filter_l7 "$params"; then
        prefix="${prefix} --filter-l7=tls"
    fi
    if ! params_has_payload "$params"; then
        # z2r-style dual payload: wide scope for range/failure detection,
        # narrow scope (tls_client_hello,http_req) for actual strategies
        payload="--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello"
    fi

    printf "%s %s %s" "$prefix" "$payload" "$params"
}

# ==============================================================================
# ПРИМЕНЕНИЕ СТРАТЕГИЙ К INIT СКРИПТУ
# ==============================================================================

# Генерация quic_strategies.conf из quic_strats.ini
# Формат входа: INI секции [name], desc=..., args=...
# Формат выхода: [NUMBER]|[NAME]|[ARGS]|[DESC]
generate_quic_strategies_conf() {
    local input_file=$1
    local output_file=$2

    if [ ! -f "$input_file" ]; then
        print_error "Файл не найден: $input_file"
        return 1
    fi

    print_info "Парсинг $input_file..."

    cat > "$output_file" <<'EOF'
# Zapret2 QUIC/UDP Strategies Database
# Сгенерировано из quic_strats.ini
# Формат: [NUMBER]|[NAME]|[ARGS]|[DESC]
EOF

    local num=1
    local name=""
    local desc=""
    local args=""

    while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed 's/\r$//')
        line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
            \[*\])
                if [ -n "$name" ] && [ -n "$args" ]; then
                    echo "${num}|${name}|${args}|${desc}" >> "$output_file"
                    num=$((num + 1))
                fi
                name=$(echo "$line" | sed 's/^\[\(.*\)\]$/\1/')
                desc=""
                args=""
                ;;
            desc=*)
                desc=${line#desc=}
                ;;
            args=*)
                args=${line#args=}
                ;;
        esac
    done < "$input_file"

    if [ -n "$name" ] && [ -n "$args" ]; then
        echo "${num}|${name}|${args}|${desc}" >> "$output_file"
    fi

    local total_count
    total_count=$(grep -c '^[0-9]' "$output_file" 2>/dev/null || echo "0")
    print_success "Сгенерировано QUIC стратегий: $total_count"

    return 0
}

# ==============================================================================
# АВТОТЕСТ ПО КАТЕГОРИЯМ (Z4R МЕТОД)
# ==============================================================================

# ==============================================================================
# АВТОТЕСТ ВСЕХ СТРАТЕГИЙ
# ==============================================================================

# ==============================================================================
# АВТОТЕСТ ПО КАТЕГОРИЯМ V2 (Z4R РЕФЕРЕНС)
# ==============================================================================

# ==============================================================================
# ТЕСТИРОВАНИЕ ДИАПАЗОНА СТРАТЕГИЙ
# ==============================================================================

# ==============================================================================
# АВТОТЕСТ QUIC СТРАТЕГИЙ
# ==============================================================================

# Получить текущие TCP параметры из init скрипта для секции
# ==============================================================================
# BLOCKCHECK MODERN (CUSTOM LISTS + CANDIDATE GENERATION)
# ==============================================================================

# ==============================================================================
# BLOCKCHECK HTTP (port 80)
# ==============================================================================

# Применить разные стратегии для YouTube TCP, YouTube GV, RKN (Z4R метод)
# Параметры: номера стратегий для каждой категории
# Purge a stale keepalive NFQUEUE rule + ipset that the engine's firewall
# teardown leaves behind. ipt.sh's ipt_do_nfqws_in_out early-returns on an
# empty port list (`[ -n "$3" ] || return` BEFORE the ipset destroy), so when
# we ship an empty NFQWS2_PORTS_UDP_KEEPALIVE the all-packets `zport_*_k` rule
# from a prior version survives a reboot-less reinstall and keeps routing the
# whole UDP flow through userspace nfqws2 (r-56.1: this re-broke Discord video
# streams → MIPS CPU saturation → ~5000ms ping). When keepalive is empty we
# remove the stale rule+ipset ourselves; the engine recreates them on start
# only when keepalive is non-empty, so this is a no-op in that case.
# iptables path (Keenetic) — nft systems use sets, not ipsets, and aren't a
# z2k target here.
purge_stale_keepalive_fw() {
    local cfg="${1:-${ZAPRET2_DIR:-/opt/zapret2}/config}"
    local ka
    ka=$(grep -E '^NFQWS2_PORTS_UDP_KEEPALIVE=' "$cfg" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[" ]//g')
    [ -n "$ka" ] && return 0   # legit keepalive configured — leave engine's rules alone

    local tbl ipset_k rule guard
    for tbl in iptables ip6tables; do
        command -v "$tbl" >/dev/null 2>&1 || continue
        for ipset_k in zport_udp_k zport_tcp_k; do
            guard=0
            while "$tbl" -t mangle -S POSTROUTING 2>/dev/null | grep -q "match-set ${ipset_k} "; do
                rule=$("$tbl" -t mangle -S POSTROUTING 2>/dev/null | grep -m1 "match-set ${ipset_k} " | sed 's/^-A /-D /')
                [ -n "$rule" ] || break
                # shellcheck disable=SC2086
                "$tbl" -t mangle $rule 2>/dev/null || break
                guard=$((guard + 1)); [ "$guard" -gt 20 ] && break
            done
        done
    done
    ipset destroy zport_udp_k 2>/dev/null || true
    ipset destroy zport_tcp_k 2>/dev/null || true
}

apply_category_strategies_v2() {
    local yt_tcp_strategy=$1
    local yt_gv_strategy=$2
    local rkn_strategy=$3

    local zapret_config="${ZAPRET2_DIR:-/opt/zapret2}/config"
    local init_script="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"

    print_info "Применение стратегий по категориям..."
    print_info "  YouTube TCP -> стратегия #$yt_tcp_strategy"
    print_info "  YouTube GV  -> стратегия #$yt_gv_strategy"
    print_info "  RKN         -> стратегия #$rkn_strategy"

    # ДЕГРАДИРОВАННЫЙ ДЕФОЛТ — ТОТ ЖЕ АВАРИЙНЫЙ ПУЛ, ЧТО У УСТАНОВКИ.
    #
    # Здесь на всех трёх категориях стоял одиночный
    # fake:blob=fake_default_tls:repeats=6 — без circular и без ключа ротации.
    # А зовут эту функцию в КОНЦЕ той же установки (lib/install.sh:4503,
    # apply_autocircular_strategies --auto), которая парой шагов раньше уже
    # положила при непрочитанном манифесте аварийный набор с ротацией
    # (create_default_strategy_files). Итог был такой: человеку печатали
    # «аварийный набор с ротацией», а на диск ложилась прежняя статика —
    # обещанная идемпотентность позднего apply держалась ровно на здоровом
    # пути и ломалась ровно там, где нужна.
    #
    # Аварийный набор пишется МИМО build_tls_profile_params: он уже полный
    # (фильтры и payload внутри), а прогон через профиль добавил бы ведущие
    # пробелы, и файл байт-в-байт разошёлся бы с записью установки.
    local emerg=1
    if ! command -v z2k_emergency_tcp_pool >/dev/null 2>&1; then
        emerg=0
        print_warning "Аварийные наборы недоступны (utils.sh не подключён) — ненайденные стратегии оставлены как есть"
    fi

    # Получить параметры для каждой стратегии
    local yt_tcp_params yt_gv_params rkn_params
    local yt_tcp_full="" yt_gv_full="" rkn_full=""

    yt_tcp_params=$(get_strategy "$yt_tcp_strategy")
    if [ -n "$yt_tcp_params" ]; then
        yt_tcp_full=$(build_tls_profile_params "$yt_tcp_params")
    else
        print_warning "Стратегия #$yt_tcp_strategy не найдена — аварийный набор с ротацией"
        [ "$emerg" = "1" ] && yt_tcp_full=$(z2k_emergency_tcp_pool yt_tcp)
    fi

    yt_gv_params=$(get_strategy "$yt_gv_strategy")
    if [ -n "$yt_gv_params" ]; then
        yt_gv_full=$(build_tls_profile_params "$yt_gv_params")
    else
        print_warning "Стратегия #$yt_gv_strategy не найдена — аварийный набор с ротацией"
        [ "$emerg" = "1" ] && yt_gv_full=$(z2k_emergency_tcp_pool gv_tcp)
    fi

    rkn_params=$(get_strategy "$rkn_strategy")
    if [ -n "$rkn_params" ]; then
        rkn_full=$(build_tls_profile_params "$rkn_params")
    else
        print_warning "Стратегия #$rkn_strategy не найдена — аварийный набор с ротацией"
        [ "$emerg" = "1" ] && rkn_full=$(z2k_emergency_tcp_pool rkn_tcp)
    fi

    # QUIC параметры (единый профиль). Свой аварийный набор — внутри
    # get_current_quic_profile_params.
    local udp_quic
    udp_quic=$(get_current_quic_profile_params)

    # Сохранить стратегии в файлы категорий (config-driven).
    # Пустое значение = аварийного набора нет вовсе; тогда файл НЕ трогаем
    # (save_strategy_to_category отвергает пустое fail-closed и уронил бы
    # установку) — прежний файл остаётся, а пустой пул подхватит
    # _z2k_pool_default генератора конфига.
    print_info "Сохранение стратегий в файлы категорий..."
    [ -n "$yt_tcp_full" ] && { save_strategy_to_category "YT" "TCP" "$yt_tcp_full" || return 1; }
    [ -n "$yt_gv_full" ] && { save_strategy_to_category "YT_GV" "TCP" "$yt_gv_full" || return 1; }
    [ -n "$rkn_full" ] && { save_strategy_to_category "RKN" "TCP" "$rkn_full" || return 1; }
    [ -n "$udp_quic" ] && { save_strategy_to_category "YT" "UDP" "$udp_quic" || return 1; }

    # Обновить config файл (NFQWS2_OPT секцию)
    print_info "Обновление config файла..."
    . "${LIB_DIR}/config_official.sh" || {
        print_error "Не удалось загрузить config_official.sh"
        return 1
    }

    update_nfqws2_opt_in_config "$zapret_config" || {
        print_error "Не удалось обновить config файл"
        return 1
    }

    # Сохранить выбранные стратегии в конфигурацию
    save_category_strategies "$yt_tcp_strategy" "$yt_gv_strategy" "$rkn_strategy"

    print_success "Стратегии применены"

    # Перезапустить сервис
    print_info "Перезапуск сервиса..."
    "$init_script" restart >/dev/null 2>&1

    # Чистим stale keepalive-правило, оставшееся от прежней версии (engine
    # teardown не удаляет его при пустом NFQWS2_PORTS_UDP_KEEPALIVE). Иначе
    # all-packets NFQUEUE на discord-порты переживает апгрейд → стрим 5000.
    purge_stale_keepalive_fw "$zapret_config"

    sleep 2

    if ! is_zapret2_running; then
        # Иногда nfqws2 стартует с задержкой
        sleep 2
    fi

    if is_zapret2_running; then
        print_success "Сервис перезапущен с новыми стратегиями"
        return 0
    else
        print_error "Сервис не запустился, проверьте логи"
        return 1
    fi
}

# Сохранить стратегии по категориям (YouTube TCP/GV/RKN)
save_category_strategies() {
    local yt_tcp_strategy=$1
    local yt_gv_strategy=$2
    local rkn_strategy=$3
    local config_file="${CONFIG_DIR}/category_strategies.conf"

    mkdir -p "$CONFIG_DIR" 2>/dev/null

    cat > "$config_file" <<EOF
# Category Strategies Configuration (Z4R format)
# Format: CATEGORY:STRATEGY_NUM
# Updated: $(date)

youtube_tcp:${yt_tcp_strategy}
youtube_gv:${yt_gv_strategy}
rkn:${rkn_strategy}
EOF
}

# ==============================================================================
# ПРИМЕНЕНИЕ ДЕФОЛТНЫХ СТРАТЕГИЙ
# ==============================================================================

# Применить autocircular стратегии (автоперебор внутри профиля)
apply_autocircular_strategies() {
    local auto_mode=0

    if [ "$1" = "--auto" ]; then
        auto_mode=1
    fi

    # Номера боевых пулов — из одного места (см. default_pool_numbers).
    local yt_tcp yt_gv rkn
    default_pool_numbers; yt_tcp=$Z2K_POOL_YT; yt_gv=$Z2K_POOL_GV; rkn=$Z2K_POOL_RKN
    local quic
    quic=$(get_quic_strategy_num_by_name "yt_quic_autocircular")
    [ -z "$quic" ] && quic=2

    print_header "Применение autocircular стратегий"
    print_info "Будут применены следующие стратегии:"
    print_info "  YouTube TCP: #$yt_tcp"
    print_info "  YouTube GV:  #$yt_gv"
    print_info "  RKN:         #$rkn"
    print_info "  YouTube QUIC: #$quic"
    printf "\n"

    if [ "$auto_mode" -eq 0 ]; then
        if ! confirm "Применить autocircular стратегии?"; then
            print_info "Отменено"
            return 0
        fi
    fi

    if ! strategy_exists "$yt_tcp"; then
        print_warning "Стратегия #$yt_tcp не найдена, используется #1"
        yt_tcp=1
    fi
    if ! strategy_exists "$yt_gv"; then
        print_warning "Стратегия #$yt_gv не найдена, используется #1"
        yt_gv=1
    fi
    if ! strategy_exists "$rkn"; then
        print_warning "Стратегия #$rkn не найдена, используется #1"
        rkn=1
    fi

    # Записать QUIC стратегию ДО рестарта (apply_category_strategies_v2 делает restart),
    # иначе QUIC-профиль отстаёт на один цикл.
    if quic_strategy_exists "$quic"; then
        set_current_quic_strategy "$quic"
    else
        print_warning "QUIC стратегия #$quic не найдена, оставляю текущую"
    fi

    # Пропускаем код возврата apply_category_strategies_v2 наружу: run_full_install
    # вызывает это ВНУТРИ транзакционного install-окна, поэтому фейл config-gen /
    # рестарта сервиса должен всплыть как ненулевой → z2k_restore_old_tree
    # откатит на прежнюю рабочую установку (Codex 2026-05-28). Единственный
    # вызывающий — run_full_install (--auto); раньше return 0 глушил фейл.
    apply_category_strategies_v2 "$yt_tcp" "$yt_gv" "$rkn"
}
