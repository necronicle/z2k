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
    local cf_tcp=""
    local quic_udp=""
    local quic_custom_udp=""
    local quic_cf_udp=""
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

    if [ -f "${extra_strats_dir}/TCP/CF/Strategy.txt" ]; then
        cf_tcp=$(cat "${extra_strats_dir}/TCP/CF/Strategy.txt")
    fi

    # YouTube QUIC autocircular modern (12 strategies, z2k morph prioritized).
    # key=yt_quic ensures stable persistence key; nld=2 reduces churn on CDN subdomains.
    quic_udp="--filter-udp=443 --filter-l7=quic --in-range=a --out-range=a --payload=all --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=yt_quic:nld=2 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:noise=2:pad_min=12:pad_max=72:strategy=1 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:profile=2:noise=2:pad_min=8:pad_max=64:ipfrag_pos_udp=16:ipfrag_pos2=56:ipfrag_overlap12=16:ipfrag_overlap23=8:strategy=2 --lua-desync=z2k_timing_morph:payload=quic_initial:dir=out:packets=2:chance=85:fakes=2:pad_min=12:pad_max=72:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:ip_autottl=-2,3-20:strategy=3 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=3 --lua-desync=drop:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=4:ip_autottl=-2,3-20:strategy=4 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=4 --lua-desync=drop:strategy=4 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_rutracker:repeats=6:strategy=5 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=5 --lua-desync=drop:strategy=5 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=6:ip_autottl=-2,3-20:strategy=6 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=6:payload=all:ip_autottl=-2,3-20:strategy=7 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=16:strategy=7 --lua-desync=drop:strategy=7 --lua-desync=udplen:payload=quic_initial:dir=out:increment=4:strategy=8 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=8 --lua-desync=udplen:payload=quic_initial:dir=out:increment=8:pattern=0xFEA82025:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=0x00000000000000000000000000000000:repeats=2:payload=all:strategy=10 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=8:strategy=10 --lua-desync=drop:strategy=10 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=11:ip_autottl=-2,3-20:strategy=11 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=24:strategy=11 --lua-desync=drop:strategy=11 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=3:strategy=12"

    # QUIC Custom autocircular modern (12 strategies, same core as YouTube QUIC).
    quic_custom_udp="--filter-udp=443 --filter-l7=quic --in-range=a --out-range=a --payload=all --lua-desync=circular:fails=3:time=60:udp_in=1:udp_out=4:key=custom_quic:nld=2 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:noise=2:pad_min=12:pad_max=72:strategy=1 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:profile=2:noise=2:pad_min=8:pad_max=64:ipfrag_pos_udp=16:ipfrag_pos2=56:ipfrag_overlap12=16:ipfrag_overlap23=8:strategy=2 --lua-desync=z2k_timing_morph:payload=quic_initial:dir=out:packets=2:chance=85:fakes=2:pad_min=12:pad_max=72:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=3:ip_autottl=-2,3-20:strategy=3 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=3 --lua-desync=drop:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=4:ip_autottl=-2,3-20:strategy=4 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=4 --lua-desync=drop:strategy=4 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_rutracker:repeats=6:strategy=5 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=5 --lua-desync=drop:strategy=5 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=6:ip_autottl=-2,3-20:strategy=6 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=6:payload=all:ip_autottl=-2,3-20:strategy=7 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=16:strategy=7 --lua-desync=drop:strategy=7 --lua-desync=udplen:payload=quic_initial:dir=out:increment=4:strategy=8 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=8 --lua-desync=udplen:payload=quic_initial:dir=out:increment=8:pattern=0xFEA82025:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=0x00000000000000000000000000000000:repeats=2:payload=all:strategy=10 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=8:strategy=10 --lua-desync=drop:strategy=10 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=11:ip_autottl=-2,3-20:strategy=11 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=24:strategy=11 --lua-desync=drop:strategy=11 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=3:strategy=12"

    # Cloudflare QUIC autocircular modern (12 strategies, profile-2 prioritized).
    quic_cf_udp="--filter-udp=443 --filter-l7=quic --in-range=a --out-range=a --payload=all --lua-desync=circular:fails=3:retrans=3:time=60:udp_in=1:udp_out=4:key=cf_quic:nld=2 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:profile=2:noise=2:pad_min=8:pad_max=64:ipfrag_pos_udp=16:ipfrag_pos2=56:ipfrag_overlap12=16:ipfrag_overlap23=8:strategy=1 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:noise=2:pad_min=12:pad_max=72:strategy=2 --lua-desync=z2k_timing_morph:payload=quic_initial:dir=out:packets=2:chance=85:fakes=2:pad_min=12:pad_max=72:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_google:repeats=3:ip_autottl=-2,3-20:strategy=3 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=3 --lua-desync=drop:strategy=3 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_google:repeats=6:payload=all:ip_autottl=-2,3-20:strategy=4 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=4 --lua-desync=drop:strategy=4 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=4:payload=all:ip_autottl=-2,3-20:strategy=5 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=5 --lua-desync=drop:strategy=5 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_google:repeats=10:payload=all:ip_autottl=-2,3-20:strategy=6 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=11:payload=all:strategy=7 --lua-desync=udplen:payload=quic_initial:dir=out:increment=4:strategy=8 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=8 --lua-desync=udplen:payload=quic_initial:dir=out:increment=8:pattern=0xFEA82025:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic5:repeats=2:strategy=9 --lua-desync=fake:payload=quic_initial:dir=out:blob=0x00000000000000000000000000000000:repeats=2:payload=all:strategy=10 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=8:strategy=10 --lua-desync=drop:strategy=10 --lua-desync=fake:payload=quic_initial:dir=out:blob=quic_google:repeats=11:strategy=11 --lua-desync=fake:payload=quic_initial:dir=out:blob=fake_default_quic:repeats=3:strategy=12"

    # Discord TCP autocircular modern (12 strategies, circular_locked:key=4).
    local discord_tcp_block
    discord_tcp_block=$(cat <<EOF
--hostlist-exclude=${lists_dir}/whitelist.txt --filter-tcp=80,443,2053,2083,2087,2096,8443 --hostlist=${extra_strats_dir}/TCP_Discord.txt --payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello --out-range=-s34228 --in-range=-s32768 --lua-desync=circular_locked:key=4 --in-range=x --payload=tls_client_hello,discord_ip_discovery --lua-desync=wssize:wsize=1:scale=6:strategy=1 --payload=tls_client_hello --lua-desync=multidisorder:pos=sniext+1:strategy=1 --payload=tls_client_hello --lua-desync=multidisorder:pos=sniext+4:strategy=2 --lua-desync=z2k_timing_morph:payload=tls_client_hello:dir=out:packets=2:chance=65:fakes=1:pad_min=8:pad_max=40:strategy=3 --lua-desync=z2k_tls_fp_pack_v2:payload=tls_client_hello:dir=out:cs_keep_head=3:groups_keep_head=1:alpn_chance=50:strategy=3 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_max_ru:repeats=5:badsum:tls_mod=rnd,rndsni,padencap:strategy=3 --lua-desync=z2k_tcpoverlap3:payload=tls_client_hello:dir=out:packets=2:pos1=2:pos2=midsld:ov12=8:ov23=8:order=2,3,1:strategy=4 --lua-desync=z2k_tls_extshuffle:payload=tls_client_hello:dir=out:strategy=4 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_max_ru:repeats=4:badsum:tls_mod=rnd,rndsni,padencap:strategy=4 --lua-desync=z2k_tls_extshuffle:payload=tls_client_hello:dir=out:strategy=5 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_max_ru:repeats=6:badsum:tls_mod=rnd,rndsni,padencap:strategy=5 --lua-desync=fakeddisorder:payload=tls_client_hello:dir=out:pos=2,midsld:strategy=5 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_max_ru:repeats=6:badsum:tls_mod=rnd,dupsid:strategy=6 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=2:strategy=6 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=2:seqovl=16:seqovl_pattern=tls_max_ru:strategy=7 --lua-desync=multidisorder:payload=tls_client_hello:dir=out:pos=2,midsld:seqovl=midsld-1:seqovl_pattern=tls_max_ru:strategy=7 --lua-desync=stopif:iff=cond_tcp_has_ts:neg=1:strategy=8 --lua-desync=hostfakesplit:payload=tls_client_hello:dir=out:tcp_ack=-66000:tcp_ts_up:strategy=8 --lua-desync=hostfakesplit:payload=tls_client_hello:dir=out:tcp_md5:ip_autottl=-1,3-20:strategy=9 --lua-desync=multisplit:payload=tls_client_hello:dir=out:blob=fake_default_tls:tcp_seq=-3000:pos=2:nodrop:strategy=10 --lua-desync=fakedsplit:payload=tls_client_hello:dir=out:pos=midsld:tcp_seq=-3000:strategy=10 --lua-desync=syndata:payload=tls_client_hello:dir=out:blob=tls_max_ru:ipfrag_pos_tcp=32:strategy=11 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,sniext+1:strategy=11 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_max_ru:repeats=8:badsum:tls_mod=rnd,dupsid:ip_autottl=-2,3-20:strategy=12 --new
EOF
)

    # Discord UDP autocircular modern (12 strategies, circular_locked:key=6 + allow_nohost for STUN).
    discord_udp="--filter-udp=50000-50099,1400,3478-3481,5349,19294-19344 --filter-l7=discord,stun --in-range=-d100 --out-range=-d100 --payload=quic_initial,discord_ip_discovery --lua-desync=circular_locked:key=6:allow_nohost=1 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:noise=2:pad_min=8:pad_max=56:strategy=1 --lua-desync=z2k_timing_morph:payload=quic_initial:dir=out:packets=2:chance=80:fakes=2:pad_min=8:pad_max=64:strategy=2 --lua-desync=fake:payload=all:blob=0x00000000000000000000000000000000:repeats=2:out_range=-d10:strategy=2 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=2 --lua-desync=drop:strategy=2 --lua-desync=z2k_quic_morph_v2:payload=quic_initial:dir=out:packets=2:profile=2:noise=2:pad_min=8:pad_max=64:ipfrag_pos_udp=16:ipfrag_pos2=56:ipfrag_overlap12=16:ipfrag_overlap23=8:strategy=3 --lua-desync=fake:payload=all:blob=quic_google:repeats=3:ip_autottl=-2,3-20:out_range=-d3:strategy=4 --lua-desync=fake:payload=all:blob=quic5:repeats=4:ip_autottl=-2,3-20:out_range=-n5:strategy=5 --lua-desync=fake:payload=all:blob=fake_default_quic:repeats=6:ip_autottl=-2,3-20:out_range=-d100:strategy=6 --lua-desync=fake:payload=all:blob=quic5:repeats=6:ip_autottl=-2,3-20:out_range=-n2:strategy=7 --lua-desync=send:payload=quic_initial:dir=out:ipfrag=z2k_ipfrag3:ipfrag_pos_udp=16:ipfrag_pos2=48:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=8 --lua-desync=drop:strategy=8 --lua-desync=udplen:payload=quic_initial:dir=out:increment=4:strategy=9 --lua-desync=fake:payload=all:blob=quic5:repeats=2:strategy=9 --lua-desync=udplen:payload=quic_initial:dir=out:increment=8:pattern=0xFEA82025:strategy=10 --lua-desync=fake:payload=all:blob=quic5:repeats=2:strategy=10 --lua-desync=fake:payload=all:blob=0x00000000000000000000000000000000:repeats=2:strategy=11 --lua-desync=send:payload=quic_initial:dir=out:ipfrag:ipfrag_pos_udp=8:strategy=11 --lua-desync=drop:strategy=11 --lua-desync=fake:payload=all:blob=fake_default_quic:repeats=3:strategy=12"

    # Дефолтная стратегия если не загружена
    local default_strategy="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello --out-range=-s34228 --lua-desync=fake:blob=fake_default_tls:repeats=6"

    # Использовать дефолт если стратегия пустая
    [ -z "$youtube_tcp_tcp" ] && youtube_tcp_tcp="$default_strategy"
    [ -z "$youtube_gv_tcp" ] && youtube_gv_tcp="$default_strategy"
    [ -z "$rkn_tcp" ] && rkn_tcp="$default_strategy"
    [ -z "$cf_tcp" ] && cf_tcp="$rkn_tcp"
    [ -z "$quic_cf_udp" ] && quic_cf_udp="$quic_custom_udp"
    [ -z "$quic_custom_udp" ] && quic_custom_udp="--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6"
    custom_tcp="$default_strategy"

    # Cloudflare runs in a dedicated, more aggressive circular profile.
    # Keep strategy actions as-is, only normalize circular control arguments.
    normalize_cf_circular() {
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
                            fails=*|retrans=*|time=*|key=*|nld=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    token="--lua-desync=circular:fails=3:retrans=3:time=60:key=cf_tcp:nld=2:failure_detector=z2k_tls_alert_fatal"
                    [ -n "$rest" ] && token="$token:$rest"
                    ;;
            esac
            out="${out:+$out }$token"
        done

        IFS="$old_ifs"
        printf '%s' "$out"
    }
    cf_tcp=$(normalize_cf_circular "$cf_tcp")

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

    youtube_tcp_tcp=$(ensure_circular_nld2 "$youtube_tcp_tcp")
    youtube_gv_tcp=$(ensure_circular_nld2 "$youtube_gv_tcp")
    rkn_tcp=$(ensure_circular_nld2 "$rkn_tcp")
    quic_udp=$(ensure_circular_nld2 "$quic_udp")

    # Ensure all circular profiles use our enhanced failure detector.
    # It keeps standard behavior but additionally treats inbound fatal TLS alerts as failures.
    ensure_circular_failure_detector() {
        local input="$1"
        local out=""
        local token=""

        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    case "$token" in
                        *failure_detector=*) ;;
                        *) token="${token}:failure_detector=z2k_tls_alert_fatal" ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done

        printf '%s' "$out"
    }

    youtube_tcp_tcp=$(ensure_circular_failure_detector "$youtube_tcp_tcp")
    youtube_gv_tcp=$(ensure_circular_failure_detector "$youtube_gv_tcp")
    rkn_tcp=$(ensure_circular_failure_detector "$rkn_tcp")
    cf_tcp=$(ensure_circular_failure_detector "$cf_tcp")
    quic_udp=$(ensure_circular_failure_detector "$quic_udp")
    quic_custom_udp=$(ensure_circular_failure_detector "$quic_custom_udp")
    quic_cf_udp=$(ensure_circular_failure_detector "$quic_cf_udp")

    # Ensure circular sees TCP RST/FIN packets without payload (payload_type=empty),
    # otherwise early connection aborts can be invisible to failure detectors.
    # Only the --payload= token that is active for --lua-desync=circular:* is modified.
    ensure_circular_payload_empty() {
        local input="$1"
        local out=""
        local token=""
        local pending_payload=""
        local buf=""

        for token in $input; do
            case "$token" in
                --payload=*)
                    if [ -n "$pending_payload" ]; then
                        out="${out:+$out }$pending_payload"
                        [ -n "$buf" ] && out="${out:+$out }$buf"
                    fi
                    pending_payload="$token"
                    buf=""
                    ;;
                --lua-desync=circular:*)
                    if [ -n "$pending_payload" ]; then
                        case "$pending_payload" in
                            --payload=all) ;;
                            *empty*) ;;
                            *) pending_payload="${pending_payload},empty" ;;
                        esac
                        out="${out:+$out }$pending_payload"
                        [ -n "$buf" ] && out="${out:+$out }$buf"
                        pending_payload=""
                        buf=""
                    fi
                    out="${out:+$out }$token"
                    ;;
                *)
                    if [ -n "$pending_payload" ]; then
                        buf="${buf:+$buf }$token"
                    else
                        out="${out:+$out }$token"
                    fi
                    ;;
            esac
        done

        if [ -n "$pending_payload" ]; then
            out="${out:+$out }$pending_payload"
            [ -n "$buf" ] && out="${out:+$out }$buf"
        fi

        printf '%s' "$out"
    }

    youtube_tcp_tcp=$(ensure_circular_payload_empty "$youtube_tcp_tcp")
    youtube_gv_tcp=$(ensure_circular_payload_empty "$youtube_gv_tcp")
    rkn_tcp=$(ensure_circular_payload_empty "$rkn_tcp")
    cf_tcp=$(ensure_circular_payload_empty "$cf_tcp")

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

    # RKN TCP (with Discord hostlist-exclude)
    local rkn_exclude="--hostlist-exclude=${lists_dir}/whitelist.txt"
    [ -s "${extra_strats_dir}/TCP_Discord.txt" ] && rkn_exclude="$rkn_exclude --hostlist-exclude=${extra_strats_dir}/TCP_Discord.txt"
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "$rkn_exclude --hostlist=${extra_strats_dir}/TCP/RKN/List.txt $rkn_tcp --new"

    # YouTube TCP
    add_hostlist_line "${extra_strats_dir}/TCP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/YT/List.txt $youtube_tcp_tcp --new"

    # YouTube GV (domains list �������)
    nfqws2_opt_lines="$nfqws2_opt_lines--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist-domains=googlevideo.com $youtube_gv_tcp --new\\n"

    # QUIC YT
    add_hostlist_line "${extra_strats_dir}/UDP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/UDP/YT/List.txt $quic_udp --new"

    # Discord TCP: self-contained z2r block (hostlist, strategies, --new all included)
    add_hostlist_line "${extra_strats_dir}/TCP_Discord.txt" "$discord_tcp_block"

    # Discord UDP (no hostlist - STUN has no hostname, uses filter-l7=discord,stun + allow_nohost)
    nfqws2_opt_lines="$nfqws2_opt_lines$discord_udp --new\\n"

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
# Order: CF TCP → RKN TCP → YouTube TCP → YouTube GV → QUIC YT → QUIC Cloudflare → QUIC Custom → Discord TCP → Discord UDP → Custom
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
