#!/bin/sh
# lib/config_official.sh - Генерация официального config файла для zapret2
# Адаптировано для z2k с multi-profile стратегиями

# ==============================================================================
# ГЕНЕРАЦИЯ NFQWS2_OPT ИЗ СТРАТЕГИЙ Z2K
# ==============================================================================

generate_nfqws2_opt_from_strategies() {
    # Генерирует NFQWS2_OPT для config файла на основе текущих стратегий

    local config_dir="/opt/etc/zapret2"
    local extra_strats_dir="/opt/zapret2/extra_strats"
    local lists_dir="/opt/zapret2/lists"

    # Загрузить текущие стратегии из категорий
    local youtube_tcp_tcp=""
    local youtube_gv_tcp=""
    local rkn_tcp=""
    local quic_udp=""
    local quic_rkn_udp=""
    local discord_tcp=""
    local discord_udp=""
    local custom_tcp=""

    # Прочитать стратегии из файлов категорий
    if [ -f "${extra_strats_dir}/TCP/YT/Strategy.txt" ]; then
        youtube_tcp_tcp=$(cat "${extra_strats_dir}/TCP/YT/Strategy.txt")
    fi

    if [ -f "${extra_strats_dir}/TCP/YT_GV/Strategy.txt" ]; then
        youtube_gv_tcp=$(cat "${extra_strats_dir}/TCP/YT_GV/Strategy.txt")
    fi

    if [ -f "${extra_strats_dir}/TCP/RKN/Strategy.txt" ]; then
        rkn_tcp=$(cat "${extra_strats_dir}/TCP/RKN/Strategy.txt")
    fi

    if [ -f "${extra_strats_dir}/UDP/YT/Strategy.txt" ]; then
        quic_udp=$(cat "${extra_strats_dir}/UDP/YT/Strategy.txt")
    fi

    if [ -f "${extra_strats_dir}/UDP/RUTRACKER/Strategy.txt" ]; then
        quic_rkn_udp=$(cat "${extra_strats_dir}/UDP/RUTRACKER/Strategy.txt")
    fi

    # Discord TCP: derived from RKN strategy (same strategies, different header)
    # Like z2r: no --filter-l7=tls, circular_locked:key=4, payload=discord_ip_discovery
    if [ -n "$rkn_tcp" ]; then
        discord_tcp=$(echo "$rkn_tcp" | sed \
            -e 's/ --filter-l7=tls//' \
            -e 's/--lua-desync=circular:fails/--lua-desync=circular_locked:key=4:fails/' \
            -e 's/--payload=tls_client_hello /--payload=tls_client_hello,discord_ip_discovery /')
    else
        # Fallback if RKN strategy not loaded
        discord_tcp="--filter-tcp=443 --payload=tls_client_hello,discord_ip_discovery --lua-desync=fake:blob=fake_default_tls:repeats=6"
    fi

    # Discord UDP: 22-strategy autocircular with circular_locked (key=6, allow_nohost=1 for STUN)
    # STUN packets have no hostname, allow_nohost=1 enables processing without hostlist match
    # Uses diverse blobs (0x00..., quic_google, quic5) and out_range values for strategy rotation
    discord_udp="--filter-udp=50000-50099,1400,3478-3481,5349,19294-19344 --filter-l7=discord,stun --in-range=-d100 --out-range=-d100 --payload=quic_initial,discord_ip_discovery --lua-desync=circular_locked:key=6:allow_nohost=1 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2:out_range=-d10:strategy=1 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=3:out_range=-d3:strategy=2 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=4:out_range=-n5:strategy=3 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2:ip_autottl=-2,3-20:out_range=-d10:strategy=4 --lua-desync=fake:blob=quic_google:repeats=2:out_range=-d10:strategy=5 --lua-desync=fake:blob=quic_google:repeats=3:out_range=-d3:strategy=6 --lua-desync=fake:blob=quic_google:repeats=4:out_range=-n5:strategy=7 --lua-desync=fake:blob=quic_google:repeats=2:ip_autottl=-2,3-20:out_range=-d10:strategy=8 --lua-desync=fake:blob=quic5:repeats=2:out_range=-d10:strategy=9 --lua-desync=fake:blob=quic5:repeats=3:out_range=-d3:strategy=10 --lua-desync=fake:blob=quic5:repeats=4:out_range=-n5:strategy=11 --lua-desync=fake:blob=quic5:repeats=2:ip_autottl=-2,3-20:out_range=-d10:strategy=12 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=6:out_range=-d100:strategy=13 --lua-desync=fake:blob=quic_google:repeats=6:out_range=-d100:strategy=14 --lua-desync=fake:blob=quic5:repeats=6:out_range=-d100:strategy=15 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=3:ip_autottl=-1,3-20:out_range=-n4:strategy=16 --lua-desync=fake:blob=quic_google:repeats=4:ip_autottl=-1,3-20:out_range=-n4:strategy=17 --lua-desync=fake:blob=quic5:repeats=4:ip_autottl=-1,3-20:out_range=-n2:strategy=18 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=8:ip_autottl=-2,3-20:out_range=-d2:strategy=19 --lua-desync=fake:blob=quic_google:repeats=6:ip_autottl=-2,3-20:out_range=-d2:strategy=20 --lua-desync=fake:blob=quic5:repeats=6:ip_autottl=-2,3-20:out_range=-n2:strategy=21 --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2:out_range=-d100:strategy=22"

    # Дефолтная стратегия если не загружена
    local default_strategy="--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6"

    # Использовать дефолт если стратегия пустая
    [ -z "$youtube_tcp_tcp" ] && youtube_tcp_tcp="$default_strategy"
    [ -z "$youtube_gv_tcp" ] && youtube_gv_tcp="$default_strategy"
    [ -z "$rkn_tcp" ] && rkn_tcp="$default_strategy"
    [ -z "$quic_udp" ] && quic_udp="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"
    [ -z "$quic_rkn_udp" ] && quic_rkn_udp="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"
    custom_tcp="$default_strategy"

    # Генерировать NFQWS2_OPT в формате официального config
    # ������������ NFQWS2_OPT � ������� ������������ config
    local nfqws2_opt_lines=""

    # Helper: �������� ������ ���� hostlist ���������� � �� ������
    add_hostlist_line() {
        local list_path="$1"
        shift
        if [ -s "$list_path" ]; then
            nfqws2_opt_lines="$nfqws2_opt_lines$*\\n"
        else
            echo "WARN: hostlist file missing or empty: $list_path (skip profile)" 1>&2
        fi
    }

    # RKN TCP (with Discord hostlist-exclude to avoid overlap with Discord TCP profile)
    local rkn_exclude="--hostlist-exclude=${lists_dir}/whitelist.txt"
    [ -s "${extra_strats_dir}/TCP_Discord.txt" ] && rkn_exclude="$rkn_exclude --hostlist-exclude=${extra_strats_dir}/TCP_Discord.txt"
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "$rkn_exclude --hostlist=${extra_strats_dir}/TCP/RKN/List.txt $rkn_tcp <HOSTLIST> --new"

    # YouTube TCP
    add_hostlist_line "${extra_strats_dir}/TCP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/YT/List.txt $youtube_tcp_tcp <HOSTLIST> --new"

    # YouTube GV (domains list �������)
    nfqws2_opt_lines="$nfqws2_opt_lines--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist-domains=googlevideo.com $youtube_gv_tcp <HOSTLIST> --new\\n"

    # QUIC YT
    add_hostlist_line "${extra_strats_dir}/UDP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/UDP/YT/List.txt $quic_udp <HOSTLIST_NOAUTO> --new"

    # QUIC RUTRACKER (disabled)
    : # disabled by default

    # Discord TCP (same strategies as RKN but with key=4, no --filter-l7=tls, discord_ip_discovery)
    # Uses TCP_Discord.txt — same file as RKN's hostlist-exclude (like z2r)
    add_hostlist_line "${extra_strats_dir}/TCP_Discord.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP_Discord.txt $discord_tcp <HOSTLIST> --new"

    # Discord UDP (no hostlist - STUN has no hostname, uses filter-l7=discord,stun + allow_nohost)
    nfqws2_opt_lines="$nfqws2_opt_lines$discord_udp --new\\n"

    # Custom TCP
    add_hostlist_line "${lists_dir}/custom.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${lists_dir}/custom.txt $custom_tcp <HOSTLIST>"

    local nfqws2_opt_value
    nfqws2_opt_value=$(printf "%b" "$nfqws2_opt_lines" | sed '/^$/d')
    cat <<NFQWS2_OPT
NFQWS2_OPT="
$nfqws2_opt_value
"
NFQWS2_OPT
}

# ==============================================================================
# СОЗДАНИЕ ОФИЦИАЛЬНОГО CONFIG ФАЙЛА
# ==============================================================================

create_official_config() {
    # $1 - путь к config файлу (обычно /opt/zapret2/config)

    local config_file="${1:-/opt/zapret2/config}"

    print_info "Создание официального config файла: $config_file"

    # Создать директорию если не существует
    mkdir -p "$(dirname "$config_file")"

    # Генерировать NFQWS2_OPT
    local nfqws2_opt_section=$(generate_nfqws2_opt_from_strategies)

    # =========================================================================
    # ВАЛИДАЦИЯ NFQWS2 ОПЦИЙ (ВАЖНО)
    # =========================================================================
    print_info "Валидация сгенерированных опций nfqws2..."

    # Извлечь NFQWS2_OPT из сгенерированной секции
    local nfqws2_opt_value=$(echo "$nfqws2_opt_section" | grep "^NFQWS2_OPT=" | sed 's/^NFQWS2_OPT=//' | tr -d '"')

    # Загрузить модули для dry_run_nfqws()
    if [ -f "/opt/zapret2/common/base.sh" ]; then
        . "/opt/zapret2/common/base.sh"
    fi

    if [ -f "/opt/zapret2/common/linux_daemons.sh" ]; then
        . "/opt/zapret2/common/linux_daemons.sh"

        # Установить временно NFQWS2_OPT для проверки
        export NFQWS2_OPT="$nfqws2_opt_value"
        export NFQWS2="/opt/zapret2/nfq2/nfqws2"

        # Проверить опции
        if dry_run_nfqws 2>/dev/null; then
            print_success "Опции nfqws2 валидны"
        else
            print_warning "Некоторые опции nfqws2 могут быть некорректными"
            print_info "Продолжаем установку (init скрипт повторно проверит при запуске)"
        fi
    else
        print_info "Модули валидации не найдены, пропускаем проверку"
    fi

    z2k_have_cmd() { command -v "$1" >/dev/null 2>&1; }

    # Получить FWTYPE и FLOWOFFLOAD из окружения (если установлены)
    local fwtype_value="${FWTYPE:-iptables}"
    local flowoffload_value="${FLOWOFFLOAD:-none}"
    local tmpdir_value="${TMPDIR:-}"

    # ==============================================================================
    # IPv6 auto-detect (Keenetic)
    # ==============================================================================
    # Default behavior historically was DISABLE_IPV6=1 because many Keenetic builds
    # don't ship ip6tables. Here we enable IPv6 only if:
    # - IPv6 looks configured (default route or global address exists)
    # - and the firewall backend can actually handle IPv6 rules:
    #   - iptables => ip6tables must exist
    #   - nftables => nft must exist
    local disable_ipv6_value="${DISABLE_IPV6:-}"
    if [ -z "$disable_ipv6_value" ]; then
        disable_ipv6_value="1"
        local v6_ok="0"
        if z2k_have_cmd ip; then
            ip -6 route show default 2>/dev/null | grep -q . && v6_ok="1"
            if [ "$v6_ok" = "0" ]; then
                ip -6 addr show scope global 2>/dev/null | grep -q "inet6" && v6_ok="1"
            fi
        fi

        if [ "$v6_ok" = "1" ]; then
            if [ "$fwtype_value" = "nftables" ]; then
                if z2k_have_cmd nft; then
                    disable_ipv6_value="0"
                    print_info "IPv6 обнаружен, backend=nftables: включаем обработку IPv6 (DISABLE_IPV6=0)"
                else
                    print_info "IPv6 обнаружен, но nft не найден: оставляем IPv6 отключенным (DISABLE_IPV6=1)"
                fi
            else
                if z2k_have_cmd ip6tables; then
                    disable_ipv6_value="0"
                    print_info "IPv6 обнаружен, backend=iptables: включаем обработку IPv6 (DISABLE_IPV6=0)"
                else
                    print_info "IPv6 обнаружен, но ip6tables не найден: оставляем IPv6 отключенным (DISABLE_IPV6=1)"
                fi
            fi
        else
            print_info "IPv6 не обнаружен (нет default route/global addr): оставляем IPv6 отключенным (DISABLE_IPV6=1)"
        fi
    else
        print_info "DISABLE_IPV6 задан вручную: DISABLE_IPV6=$disable_ipv6_value"
    fi

    # Создать полный config файл
    cat > "$config_file" <<CONFIG
# zapret2 configuration for Keenetic
# Generated by z2k installer
# Based on official zapret2 config structure

# ==============================================================================
# BASIC SETTINGS
# ==============================================================================

# Enable zapret2 service
ENABLED=1

# Mode filter: none, ipset, hostlist, autohostlist
# For z2k we use hostlist mode with multi-profile filtering
MODE_FILTER=autohostlist

# Firewall type - AUTO-DETECTED by init script, DO NOT set manually
# Init script calls linux_fwtype() which detects iptables/nftables automatically
# If FWTYPE is set here, linux_fwtype() will skip detection!
#FWTYPE=iptables

# ==============================================================================
# NFQWS2 DAEMON SETTINGS
# ==============================================================================

# Enable nfqws2
NFQWS2_ENABLE=1

# TCP ports to process (will be filtered by --filter-tcp in NFQWS2_OPT)
NFQWS2_PORTS_TCP="80,443,2053,2083,2087,2096,8443"

# UDP ports to process (will be filtered by --filter-udp in NFQWS2_OPT)
NFQWS2_PORTS_UDP="443,50000:50099,1400,3478:3481,5349,19294:19344"

# Packet direction filters (connbytes)
# NOTE: These are packet counts, NOT ranges
# PKT_OUT=20 means "first 20 packets" (connbytes 1:20)
# Official zapret2 defaults: TCP_PKT_OUT=20, UDP_PKT_OUT=5
NFQWS2_TCP_PKT_OUT="20"
NFQWS2_TCP_PKT_IN=""
NFQWS2_UDP_PKT_OUT="5"
NFQWS2_UDP_PKT_IN=""

# ==============================================================================
# NFQWS2 OPTIONS (MULTI-PROFILE MODE)
# ==============================================================================
# This section is auto-generated from z2k strategy database
# Each --new separator creates independent profile with own filters and strategy
# Order: RKN TCP → YouTube TCP → YouTube GV → QUIC YT → QUIC RKN → Discord TCP → Discord UDP → Custom
# Placeholders: <HOSTLIST> and <HOSTLIST_NOAUTO> are expanded based on MODE_FILTER
# This enables standard hostlists and autohostlist like upstream zapret2
CONFIG

    # Добавить сгенерированный NFQWS2_OPT
    echo "$nfqws2_opt_section" >> "$config_file"

    # Добавить остальные настройки
    cat >> "$config_file" <<'CONFIG'

# ==============================================================================
# FIREWALL SETTINGS
# ==============================================================================

# Queue number for NFQUEUE
QNUM=200

# Firewall mark for desync prevention
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000

# Apply firewall rules in init script
INIT_APPLY_FW=1

# Flow offloading mode: none, software, hardware, donttouch
# Set during installation based on system detection
FLOWOFFLOAD=$flowoffload_value

# WAN interface override (space/comma separated). Empty = auto-detect
#WAN_IFACE=

# ==============================================================================
# SYSTEM SETTINGS
# ==============================================================================

# Temporary directory for downloads and processing
# Empty = use system default /tmp (tmpfs, in RAM)
# Set to disk path for low RAM systems (e.g., /opt/zapret2/tmp)
CONFIG
    # Добавить TMPDIR только если установлен
    if [ -n "$tmpdir_value" ]; then
        echo "TMPDIR=$tmpdir_value" >> "$config_file"
    else
        echo "#TMPDIR=/opt/zapret2/tmp" >> "$config_file"
    fi

    # Disable IPv6 processing (0=enabled, 1=disabled)
    # Auto-detected during install; can be overridden by setting DISABLE_IPV6 in environment/config.
    echo "" >> "$config_file"
    echo "# Disable IPv6 processing (0=enabled, 1=disabled)" >> "$config_file"
    echo "DISABLE_IPV6=$disable_ipv6_value" >> "$config_file"

    cat >> "$config_file" <<'CONFIG'

# ==============================================================================
# IPSET SETTINGS
# ==============================================================================

# Maximum elements in ipsets
SET_MAXELEM=522288

# ipset options
IPSET_OPT="hashsize 262144 maxelem $SET_MAXELEM"

# ip2net options
IP2NET_OPT4="--prefix-length=22-30 --v4-threshold=3/4"
IP2NET_OPT6="--prefix-length=56-64 --v6-threshold=5"

# ==============================================================================
# AUTOHOSTLIST SETTINGS
# ==============================================================================

AUTOHOSTLIST_INCOMING_MAXSEQ=4096
AUTOHOSTLIST_RETRANS_MAXSEQ=32768
AUTOHOSTLIST_RETRANS_RESET=1
AUTOHOSTLIST_RETRANS_THRESHOLD=3
AUTOHOSTLIST_FAIL_THRESHOLD=3
AUTOHOSTLIST_FAIL_TIME=60
AUTOHOSTLIST_UDP_IN=1
AUTOHOSTLIST_UDP_OUT=4
AUTOHOSTLIST_DEBUGLOG=0

# ==============================================================================
# CUSTOM SCRIPTS
# ==============================================================================

# Directory for custom scripts
CUSTOM_DIR="/opt/zapret2/init.d/keenetic"

# ==============================================================================
# MISCELLANEOUS
# ==============================================================================

# Temporary directory (if /tmp is too small)
#TMPDIR=/opt/zapret2/tmp

# User for zapret daemons (security hardening: drop privileges to nobody)
WS_USER=nobody

# Compress large lists
GZIP_LISTS=1

# Number of parallel threads for domain resolves
MDIG_THREADS=30

# EAI_AGAIN retries
MDIG_EAGAIN=10
MDIG_EAGAIN_DELAY=500
CONFIG

    print_success "Config файл создан: $config_file"
    return 0
}

# ==============================================================================
# ОБНОВЛЕНИЕ NFQWS2_OPT В СУЩЕСТВУЮЩЕМ CONFIG
# ==============================================================================

update_nfqws2_opt_in_config() {
    # Обновляет только секцию NFQWS2_OPT в существующем config файле
    # $1 - путь к config файлу

    local config_file="${1:-/opt/zapret2/config}"

    if [ ! -f "$config_file" ]; then
        print_error "Config файл не найден: $config_file"
        return 1
    fi

    print_info "Обновление NFQWS2_OPT в: $config_file"

    # Создать backup
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"

    # Генерировать новый NFQWS2_OPT
    local nfqws2_opt_section=$(generate_nfqws2_opt_from_strategies)

    # Создать временный файл
    local temp_file="${config_file}.tmp"

    # Удалить старый NFQWS2_OPT и добавить новый
    awk '
    /^NFQWS2_OPT=/ {
        in_nfqws_opt=1
        next
    }
    in_nfqws_opt && /^"$/ {
        in_nfqws_opt=0
        next
    }
    !in_nfqws_opt { print }
    ' "$config_file" > "$temp_file"

    # Добавить новый NFQWS2_OPT в конец файла (перед последней секцией)
    # Найти позицию для вставки (перед FIREWALL SETTINGS или в конец)
    if grep -q "# FIREWALL SETTINGS" "$temp_file"; then
        # Вставить перед FIREWALL SETTINGS
        awk -v opt="$nfqws2_opt_section" '
        /# FIREWALL SETTINGS/ {
            print opt
            print ""
        }
        { print }
        ' "$temp_file" > "${temp_file}.2"
        mv "${temp_file}.2" "$temp_file"
    else
        # Добавить в конец
        echo "" >> "$temp_file"
        echo "$nfqws2_opt_section" >> "$temp_file"
    fi

    # Заменить оригинальный файл
    mv "$temp_file" "$config_file"

    print_success "NFQWS2_OPT обновлён в config файле"
    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Функции доступны после source этого файла
