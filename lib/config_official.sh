#!/bin/sh
# lib/config_official.sh - Генерация официального config файла для zapret2
# Адаптировано для z2k с multi-profile стратегиями

# ==============================================================================
# ГЕНЕРАЦИЯ NFQWS2_OPT ИЗ СТРАТЕГИЙ Z2K
# ==============================================================================

generate_nfqws2_opt_from_strategies() {
    # Генерирует NFQWS2_OPT для config файла на основе текущих стратегий

    # Intentionally hardcoded: this function may be called before utils.sh sets
    # the global CONFIG_DIR / ZAPRET2_DIR / LISTS_DIR variables, so we use
    # local copies with known absolute paths.
    local config_dir="/opt/etc/zapret2"
    local extra_strats_dir="/opt/zapret2/extra_strats"
    local lists_dir="/opt/zapret2/lists"

    # Режим Austerusj: простые стратегии без хостлистов, из Zapret1.
    # Если включен — генерируем минимальный конфиг и выходим.
    local austerus_conf="${config_dir}/all_tcp443.conf"
    if [ -f "$austerus_conf" ]; then
        local ENABLED=0
        . "$austerus_conf"
        if [ "$ENABLED" = "1" ]; then
            cat <<'AUSTERUS_OPT'
NFQWS2_OPT="
--filter-tcp=80 --lua-desync=fake:payload=http_req:dir=out:blob=zero_256:badsum:badseq --lua-desync=multisplit:payload=http_req:dir=out --new
--filter-tcp=443 --out-range=-d4 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=zero_256:badsum:badseq --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:badsum:badseq:repeats=1:tls_mod=sni=www.google.com,rnd,dupsid --lua-desync=multidisorder:payload=tls_client_hello:dir=out:pos=method+2,midsld,5 --new
--filter-udp=443 --out-range=-d4 --lua-desync=fake:payload=quic_initial:dir=out:blob=zero_256:badsum:repeats=1
"
AUSTERUS_OPT
            return 0
        fi
    fi

    # Загрузить текущие стратегии из категорий
    local youtube_tcp=""
    local youtube_gv_tcp=""
    local rkn_tcp=""
    local quic_udp=""
    local discord_udp=""
    # Прочитать стратегии из файлов категорий
    if [ -f "${extra_strats_dir}/TCP/YT/Strategy.txt" ]; then
        youtube_tcp=$(cat "${extra_strats_dir}/TCP/YT/Strategy.txt")
    fi

    if [ -f "${extra_strats_dir}/TCP/YT_GV/Strategy.txt" ]; then
        youtube_gv_tcp=$(cat "${extra_strats_dir}/TCP/YT_GV/Strategy.txt")
    fi

    if [ -f "${extra_strats_dir}/TCP/RKN/Strategy.txt" ]; then
        rkn_tcp=$(cat "${extra_strats_dir}/TCP/RKN/Strategy.txt")
    fi

    # YouTube QUIC autocircular modern (12 strategies, z2k morph prioritized).
    # key=yt_quic ensures stable persistence key; nld=2 reduces churn on CDN subdomains.
    quic_udp="--filter-udp=443 --filter-l7=quic --in-range=a --out-range=a --payload=all --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=yt_quic:nld=2 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:noise=2:pad_min=12:pad_max=72:strategy=1 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:profile=2:noise=2:pad_min=8:pad_max=64:ipfrag_pos_udp=16:ipfrag_pos2=56:ipfrag_overlap12=16:ipfrag_overlap23=8:strategy=2 --lua-desync=z2k_timing_morph:payload=quic_initial:dir=out:packets=2:chance=85:fakes=2:pad_min=12:pad_max=72:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:ip_autottl=-2,3-20:strategy=3 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=3 --lua-desync=drop:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=4:ip_autottl=-2,3-20:strategy=4 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=4 --lua-desync=drop:strategy=4 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_rutracker:repeats=6:strategy=5 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=5 --lua-desync=drop:strategy=5 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=6:ip_autottl=-2,3-20:strategy=6 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=6:payload=all:ip_autottl=-2,3-20:strategy=7 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=16:strategy=7 --lua-desync=drop:strategy=7 --lua-desync=udplen:payload=quic_initial:dir=out:increment=4:strategy=8 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=8 --lua-desync=udplen:payload=quic_initial:dir=out:increment=8:pattern=0xFEA82025:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=0x00000000000000000000000000000000:repeats=2:payload=all:strategy=10 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=8:strategy=10 --lua-desync=drop:strategy=10 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=11:ip_autottl=-2,3-20:strategy=11 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=24:strategy=11 --lua-desync=drop:strategy=11 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=3:strategy=12"

    # If category strategy files exist, prefer them over hardcoded QUIC defaults.
    if [ -f "${extra_strats_dir}/UDP/YT/Strategy.txt" ]; then
        quic_udp=$(cat "${extra_strats_dir}/UDP/YT/Strategy.txt")
    fi
    # Discord TCP profiles from zapret4rocket are absent; disable dedicated TCP Discord profile.
    local discord_tcp_block=""

    # Discord UDP (zapret4rocket-based + z2k autocircular on same primitive family).
    discord_udp="--filter-udp=50000-50099,1400,3478-3481,5349,19294-19344 --filter-l7=discord,stun --in-range=-d100 --out-range=-d100 --payload=quic_initial,discord_ip_discovery --lua-desync=circular_locked:key=6:allow_nohost=1 --lua-desync=fake:payload=all:blob=quic_google:repeats=6:strategy=1 --lua-desync=fake:payload=all:blob=quic_google:repeats=4:strategy=2 --lua-desync=fake:payload=all:blob=quic_google:repeats=8:strategy=3 --lua-desync=fake:payload=all:blob=quic_google:repeats=6:ip_autottl=-2,3-20:strategy=4 --lua-desync=fake:payload=all:blob=fake_default_quic:repeats=6:strategy=5 --lua-desync=fake:payload=all:blob=quic5:repeats=6:strategy=6"

    # Дефолтная стратегия если не загружена
    local default_strategy="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello --out-range=-s34228 --lua-desync=fake:blob=fake_default_tls:repeats=6"

    # Использовать дефолт если стратегия пустая
    [ -z "$youtube_tcp" ] && youtube_tcp="$default_strategy"
    [ -z "$youtube_gv_tcp" ] && youtube_gv_tcp="$default_strategy"
    [ -z "$rkn_tcp" ] && rkn_tcp="$default_strategy"

    # Force domain-level memory for all autocircular profiles.
    # This prevents churn on frequently changing subdomains.
    ensure_circular_nld2() {
        local input="$1"
        local out=""
        local token=""
        local opts=""
        local part=""
        local rest=""
        local old_ifs="$IFS"

        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    opts="${token#--lua-desync=circular:}"
                    rest=""
                    IFS=':'
                    for part in $opts; do
                        case "$part" in
                            nld=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    if [ -n "$rest" ]; then
                        token="--lua-desync=circular:${rest}:nld=2"
                    else
                        token="--lua-desync=circular:nld=2"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done

        IFS="$old_ifs"
        printf '%s' "$out"
    }

    youtube_tcp=$(ensure_circular_nld2 "$youtube_tcp")
    youtube_gv_tcp=$(ensure_circular_nld2 "$youtube_gv_tcp")
    rkn_tcp=$(ensure_circular_nld2 "$rkn_tcp")
    quic_udp=$(ensure_circular_nld2 "$quic_udp")

    # Let YouTube TLS circular operate exactly as in the upstream manual.
    # For LG webOS the orchestrator must see incoming packets on the circular
    # stage itself (`--in-range=-s5556`), while actual desync instances must
    # still stay limited by `--payload=tls_client_hello...`.
    #
    # This requires moving the top-level `--payload=` after circular and
    # closing the incoming window right after circular with `--in-range=x`.
    # Keeping payload before circular makes YouTube TCP/GV fail detection too
    # blind and prevents real sequential rotation on TV clients.
    ensure_youtube_tls_circular_manual_layout() {
        local input="$1"
        local token=""
        local has_tls="0"
        local has_circular="0"
        local has_in_range=""
        local before_circular=""
        local circular_token=""
        local after_circular=""
        local saved_payload=""
        local phase="before"

        for token in $input; do
            case "$token" in
                --filter-l7=tls) has_tls="1" ;;
                --lua-desync=circular:*) has_circular="1" ;;
                --in-range=*) has_in_range="1" ;;
            esac
        done

        if [ "$has_tls" != "1" ] || [ "$has_circular" != "1" ]; then
            printf '%s' "$input"
            return 0
        fi

        # If a profile already has an explicit in-range, leave it alone.
        [ -n "$has_in_range" ] && {
            printf '%s' "$input"
            return 0
        }

        for token in $input; do
            case "$phase" in
                before)
                    case "$token" in
                        --payload=*)
                            saved_payload="$token"
                            ;;
                        --lua-desync=circular:*)
                            circular_token="$token"
                            phase="after"
                            ;;
                        *)
                            before_circular="${before_circular:+$before_circular }$token"
                            ;;
                    esac
                    ;;
                after)
                    after_circular="${after_circular:+$after_circular }$token"
                    ;;
            esac
        done

        [ -z "$circular_token" ] && {
            printf '%s' "$input"
            return 0
        }

        # Fallback for malformed legacy inputs with no payload token.
        [ -z "$saved_payload" ] && saved_payload="--payload=tls_client_hello"

        printf '%s --in-range=-s5556 %s --in-range=x %s%s%s' \
            "$before_circular" \
            "$circular_token" \
            "$saved_payload" \
            "${after_circular:+ }" \
            "$after_circular"
    }

    # YouTube TCP on LG webOS often fails as a silent TCP blackhole:
    # repeated ClientHello attempts with no visible response_state/success_state.
    # Manual payload reordering alone is not sufficient in that mode.
    #
    # Restore the older YouTube-only conservative TCP failure path:
    # - expose incoming packets to circular via --in-range=-s5556
    # - expose empty packets / retrans context via --payload=tls_client_hello,empty
    # - keep desync strategy instances restricted to the original TLS payload
    # - prevent successes from other devices on the same domain from resetting
    #   failure counters via success_detector=z2k_success_no_reset
    #
    # Scope is intentionally limited to youtube_tcp.
    ensure_youtube_tls_failure_detection() {
        local input="$1"
        local token=""
        local has_tls="0"
        local has_circular="0"
        local has_in_range=""
        local saved_payload=""
        local out=""
        local circular_seen="0"

        for token in $input; do
            case "$token" in
                --filter-l7=tls) has_tls="1" ;;
                --lua-desync=circular:*) has_circular="1" ;;
                --in-range=*) has_in_range="1" ;;
            esac
        done

        if [ "$has_tls" != "1" ] || [ "$has_circular" != "1" ]; then
            printf '%s' "$input"
            return 0
        fi

        # If a profile already has an explicit in-range, leave it alone.
        [ -n "$has_in_range" ] && {
            printf '%s' "$input"
            return 0
        }

        [ -z "$saved_payload" ] && saved_payload="--payload=tls_client_hello"

        for token in $input; do
            case "$token" in
                --payload=*)
                    saved_payload="$token"
                    token=$(printf '%s' "$token" | sed 's/^--payload=tls_client_hello$/--payload=tls_client_hello,empty/')
                    ;;
                --lua-desync=circular:*)
                    out="${out:+$out }--in-range=-s5556"
                    case "$token" in
                        *:success_detector=*) ;;
                        *) token="${token}:success_detector=z2k_success_no_reset" ;;
                    esac
                    circular_seen="1"
                    ;;
            esac

            if [ "$circular_seen" = "1" ]; then
                case "$token" in
                    --lua-desync=circular:*) ;;
                    --lua-desync=*)
                        out="${out:+$out }--in-range=x $saved_payload"
                        circular_seen="2"
                        ;;
                esac
            fi

            out="${out:+$out }$token"
        done

        printf '%s' "$out"
    }

    youtube_tcp=$(ensure_youtube_tls_failure_detection "$youtube_tcp")
    youtube_gv_tcp=$(ensure_youtube_tls_circular_manual_layout "$youtube_gv_tcp")




    # Генерировать NFQWS2_OPT в формате официального config
    local nfqws2_opt_lines=""

    # Helper: проверить наличие и непустоту hostlist-файлов
    add_hostlist_line() {
        local list_path="$1"
        shift
        if [ -s "$list_path" ]; then
            nfqws2_opt_lines="$nfqws2_opt_lines$*\\n"
        else
            echo "WARN: hostlist file missing or empty: $list_path (skip profile)" 1>&2
            print_warning "Hostlist missing or empty: $list_path — profile skipped"
        fi
    }

    # RKN TCP (include Discord hostlist into RKN profile)
    local rkn_hostlists="--hostlist=${extra_strats_dir}/TCP/RKN/List.txt"
    [ -s "${extra_strats_dir}/TCP_Discord.txt" ] && rkn_hostlists="$rkn_hostlists --hostlist=${extra_strats_dir}/TCP_Discord.txt"
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt $rkn_hostlists $rkn_tcp --new"

    # YouTube TCP
    add_hostlist_line "${extra_strats_dir}/TCP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/YT/List.txt $youtube_tcp --new"

    # YouTube GV (список доменов статичен)
    nfqws2_opt_lines="$nfqws2_opt_lines--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist-domains=googlevideo.com $youtube_gv_tcp --new\\n"

    # QUIC YT
    add_hostlist_line "${extra_strats_dir}/UDP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/UDP/YT/List.txt $quic_udp --new"

    # Discord TCP: currently disabled for autocircular profile set.
    if [ -n "$discord_tcp_block" ]; then
        add_hostlist_line "${extra_strats_dir}/TCP_Discord.txt" "$discord_tcp_block"
    fi

    # Discord UDP (no hostlist - STUN has no hostname, uses filter-l7=discord,stun + allow_nohost)
    nfqws2_opt_lines="$nfqws2_opt_lines$discord_udp --new\\n"

    # HTTP RKN (port 80): autocircular bypass of ISP DPI redirect (302 → block page).
    # 7 strategies from blockcheck2 results, ordered by simplicity.
    # standard_failure_detector detects HTTP 302 redirects natively.
    # --in-range=-s5556: let circular see HTTP response for failure detection.
    # Strategy 1: http_methodeol (simplest HTTP manipulation)
    # Strategy 2: syndata + multisplit
    # Strategy 3: hostfakesplit with TTL=2
    # Strategy 4: fake with badsum
    # Strategy 5: fakedsplit at method+2 with badsum
    # Strategy 6: z4r original (fake 0x0E + tcp_md5 + multisplit host+1)
    # Strategy 7: fake badsum + multisplit method+2
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "--filter-tcp=80 --hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/RKN/List.txt --in-range=-s5556 --payload=http_req,empty --lua-desync=circular:fails=2:time=60:reset:key=http_rkn:nld=2:failure_detector=z2k_tls_alert_fatal --lua-desync=http_methodeol:payload=http_req:dir=out:strategy=1 --lua-desync=syndata:payload=http_req:dir=out:strategy=2 --lua-desync=multisplit:payload=http_req:dir=out:strategy=2 --lua-desync=hostfakesplit:payload=http_req:dir=out:ip_ttl=2:repeats=1:strategy=3 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=4 --lua-desync=fakedsplit:payload=http_req:dir=out:pos=method+2:badsum:strategy=5 --lua-desync=fake:payload=http_req:dir=out:blob=0x0E0E0F0E:tcp_md5:strategy=6 --lua-desync=multisplit:payload=http_req:dir=out:pos=host+1:seqovl=2:strategy=6 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=7 --lua-desync=multisplit:payload=http_req:dir=out:pos=method+2:strategy=7 --in-range=x --new"


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

    # Извлечь NFQWS2_OPT из сгенерированной секции (многострочный heredoc между кавычками)
    local nfqws2_opt_value=$(echo "$nfqws2_opt_section" | sed -n '/^NFQWS2_OPT="/,/^"$/{ /^NFQWS2_OPT="/d; /^"$/d; p; }')

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
# z2k uses hostlist mode — domains are controlled via explicit hostlist files
MODE_FILTER=hostlist

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
NFQWS2_PORTS_UDP="443,50000-50099,1400,3478-3481,5349,19294-19344"

# Packet direction filters (connbytes)
# NOTE: These are packet counts, NOT ranges
# PKT_OUT=20 means "first 20 packets" (connbytes 1:20)
# Official zapret2 defaults: TCP_PKT_OUT=20, UDP_PKT_OUT=5
NFQWS2_TCP_PKT_OUT="20"
NFQWS2_TCP_PKT_IN="10"
NFQWS2_UDP_PKT_OUT="5"
NFQWS2_UDP_PKT_IN="3"

# ==============================================================================
# NFQWS2 OPTIONS (MULTI-PROFILE MODE)
# ==============================================================================
# This section is auto-generated from z2k strategy database
# Each --new separator creates independent profile with own filters and strategy
# Order: RKN TCP → YouTube TCP → YouTube GV → QUIC YT → Discord UDP → HTTP RKN → Catch-all TCP
# Profiles use explicit hostlists from z2k list files without placeholder expansion.
# This avoids mixing with global hostlists from MODE_FILTER.
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

# AUTOHOSTLIST SETTINGS отключены — используется режим hostlist с явными списками доменов

# ==============================================================================
# CUSTOM SCRIPTS
# ==============================================================================

# Directory for custom scripts
CUSTOM_DIR="/opt/zapret2/init.d/keenetic"

# Disable custom.d scripts (50-stun4all, 50-discord-media).
# Discord voice/video is handled by nfqws2 strategies (profile 6), no extra daemons needed.
DISABLE_CUSTOM=1

# ==============================================================================
# MISCELLANEOUS
# ==============================================================================

# Temporary directory (if /tmp is too small)
#TMPDIR=/opt/zapret2/tmp

# User for zapret daemons (security hardening: drop privileges to nobody)
WS_USER=nobody

# Passive DPI RST filter: drop injected TCP RST with IP ID 0x0-0xF
# Enable if your ISP uses TSPU that sends fake RST before real server reply
DROP_DPI_RST=0

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
