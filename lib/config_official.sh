#!/bin/sh
# lib/config_official.sh - Генерация официального config файла для zapret2
# Адаптировано для z2k с multi-profile стратегиями

# ==============================================================================
# ГЕНЕРАЦИЯ NFQWS2_OPT ИЗ СТРАТЕГИЙ Z2K
# ==============================================================================

generate_nfqws2_opt_from_strategies() {
    # Генерирует NFQWS2_OPT для config файла на основе текущих стратегий

    # Pre-utils-safe path resolution. Original design hardcoded all three
    # in case the function got called before utils.sh sourced; we now derive
    # extra_strats_dir/lists_dir from ZAPRET2_DIR with the same /opt/zapret2
    # fallback (parameter-expansion is evaluated lazily, so this stays a
    # no-op in production where ZAPRET2_DIR is either unset or already set
    # to /opt/zapret2 by utils.sh). Tests can mock these by exporting
    # ZAPRET2_DIR before invocation. config_dir stays absolute because
    # /opt/etc/zapret2 has no canonical env-var counterpart and only gates
    # the Austerus path which is independently tested.
    local config_dir="/opt/etc/zapret2"
    local extra_strats_dir="${ZAPRET2_DIR:-/opt/zapret2}/extra_strats"
    local lists_dir="${ZAPRET2_DIR:-/opt/zapret2}/lists"

    # Режим Austerusj: простые стратегии без хостлистов, из Zapret1.
    # Если включен — генерируем минимальный конфиг и выходим.
    local austerus_conf="${config_dir}/all_tcp443.conf"
    if [ -f "$austerus_conf" ]; then
        local ENABLED
        ENABLED=$(safe_config_read "ENABLED" "$austerus_conf" "0")
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
    local game_udp=""

    # Variant-A refactor feature flags. Each phase's emit block is guarded by
    # the corresponding flag so individual phases can be toggled at runtime
    # via /opt/zapret2/config without a push. Default "1" (enabled).
    # Remove these flags entirely once all phases are soaked on production.
    local Z2K_REFACTOR_PHASE1 Z2K_REFACTOR_PHASE2 Z2K_REFACTOR_PHASE3
    Z2K_REFACTOR_PHASE1=$(safe_config_read "Z2K_REFACTOR_PHASE1" "/opt/zapret2/config" "1")
    Z2K_REFACTOR_PHASE2=$(safe_config_read "Z2K_REFACTOR_PHASE2" "/opt/zapret2/config" "1")
    # Phase 3 (YT+GV merge into google_tls) — DEFAULT OFF as of 2026-04-26.
    # Field reports на enhanced (Сергей #2191, others) показали падение
    # YouTube performance после merge; раздельные yt + googlevideo
    # профили работают надёжнее. Pre-merge legacy code path (else
    # branch ниже) теперь default. Юзеры могут опционально включить
    # merge через `Z2K_REFACTOR_PHASE3=1` в config — оставлено для
    # тестирования / возможного rollforward.
    Z2K_REFACTOR_PHASE3=$(safe_config_read "Z2K_REFACTOR_PHASE3" "/opt/zapret2/config" "0")
    # Phase 4 (cdn_tls) удалён 2026-04-27 — отдельный CF/OVH/Hetzner/DO
    # профиль перехватывал non-RKN CF трафик и применял свой набор стратегий
    # слабее проверенного 47-стратегий rkn_tcp rotator'а. CF возвращается
    # под rkn_tcp как было до Variant A refactor'а.

    # Z2K_USE_MID_STREAM_DETECTOR (default 1, per Mark 2026-05-02 policy):
    # bundle flag for the
    # rkn_tcp mid-stream stall detector wiring. Off: rkn_tcp keeps
    # its master-compatible layout (--in-range=-s5556 +
    # failure_detector=z2k_tls_stalled), which is what the field
    # currently runs. On: bumps rkn_tcp to --in-range=-s20000 AND
    # switches its failure_detector to z2k_mid_stream_stall (the
    # byte-window v3 state machine landed in 14984c3). Both knobs
    # belong to the same rotation behavior — flipping one without
    # the other produces a half-state (lua sees more body but the
    # active detector still ignores it, or the byte-window detector
    # is wired but blind because its observation cap is still 5.5K).
    # Tests assert the two move together.
    local Z2K_USE_MID_STREAM_DETECTOR
    Z2K_USE_MID_STREAM_DETECTOR=$(safe_config_read "Z2K_USE_MID_STREAM_DETECTOR" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")

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
    # 2026-04-30: strategies 1-4 fake-blob migrated quic_google → quic_dbankcloud.
    # Field consensus: TSPU фингерпринтит google-QUIC clienthello, dbankcloud blob
    # обходит надёжнее. Strategies 5-6 оставлены на fake_default_quic / quic5 для
    # разнообразия fingerprint'ов в circular_locked rotator'е.
    discord_udp="--filter-udp=50000-50099,1400,3478-3481,5349,19294-19344 --filter-l7=discord,stun --in-range=-d100 --out-range=-d100 --payload=quic_initial,discord_ip_discovery --lua-desync=circular_locked:key=6:allow_nohost=1 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=6:strategy=1 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=4:strategy=2 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=8:strategy=3 --lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=6:ip_autottl=-2,3-20:strategy=4 --lua-desync=fake:payload=all:blob=fake_default_quic:repeats=6:strategy=5 --lua-desync=fake:payload=all:blob=quic5:repeats=6:strategy=6"

    # Дефолтная стратегия если не загружена
    local default_strategy="--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello --out-range=-s34228 --lua-desync=fake:blob=fake_default_tls:repeats=6"

    # Использовать дефолт если стратегия пустая
    [ -z "$youtube_tcp" ] && youtube_tcp="$default_strategy"
    [ -z "$youtube_gv_tcp" ] && youtube_gv_tcp="$default_strategy"
    [ -z "$rkn_tcp" ] && rkn_tcp="$default_strategy"

    # Game UDP strategy: custom z2k_game_udp Lua handler (rather than built-in
    # fake, which drops repeats=N for UDP payloads). 6 variants rotated by
    # circular with fails=1 and a 60s observation window. Positive
    # --ipset=game_ips.txt on the profile constrains the rotator to the
    # listed game-server IPs so Discord/Steam noise does not burn the fails
    # counter. Hardcoded inline — no external Strategy.txt to sync.
    #
    # NOTE: a flowseal-style udplen+fake chain with narrower port range was
    # tested 2026-04-16 and broke a Dom.ru user's connection to the listed
    # game servers (client-side error code 2). Reverted to the proven master
    # profile. The flowseal variant may help Rostelecom PC users specifically —
    # revisit as opt-in when Evgeniy can test.
    # out_range was previously set per-strategy here (-n2/-n3/-n4) but that
    # key is not part of any Lua function's arg vocabulary — it's only a
    # C-side in-profile filter (--out-range). Those inline values were
    # dead ever since the profile's --out-range=a was applied. Moved to
    # --out-range=-n4 on the profile itself (below) — real cutoff at last.
    # Extended 2026-04 rotator for the merged game_udp profile. Axes of
    # variation (inspiration from Smart-Zapret-Launcher gaming_1..gaming_8
    # + our existing quic_udp rotator primitives):
    #
    # - blob: quic_google (default Google QUIC ClientHello decoy) and
    #   quic_ozon_ru (secondary decoy, SZL gaming_8 trick — if DPI
    #   fingerprints per-SNI on fake QUIC, having two SNIs forces it
    #   to allow both or block both known-good services).
    # - ip_autottl=N,1-64: values 2,3,4,5 (previously only 2,4). Adaptive
    #   TTL — delta from measured egress. SZL uses all four.
    # - ip_ttl=N (hard TTL): new primitive, not auto. Packet dies at
    #   hop N regardless of actual path. Values 3,4 from SZL gaming_7.
    # - repeats: 8 (gentle), 10/12 (aggressive), 14 (max) kept from
    #   original rotator.
    # - Cross-family: udplen (payload size tamper) and send+ipfrag
    #   (IP fragmentation) — same primitives already in production
    #   inside quic_udp rotator. Circular supports mixed actions per
    #   zapret-auto.lua:312-385 verification.
    #
    # Strategy ordering: aggressive first (1-11), gentle last (12) so
    # non-game AWS flows caught by aws_oracle ipset in hybrid mode
    # cycle through aggressive, fail, advance, and finally pin on the
    # gentle strategy=12 — preserving the pre-Phase-2 catchall
    # behavior for non-game traffic without a separate profile.
    #
    # fails=2 + nld=2: per-SLD pinning with 1 retry window, same as
    # Phase 2 merge.
    # strategy=12 — denisv7 Roblox recipe (ntc.party 21161 #159): negative
    # autottl (-2, range 3-20) makes fakes die BEFORE reaching destination
    # but AFTER the DPI has latched — useful when DPI sits on a transit
    # router rather than at ISP edge. payload=unknown instead of =all is
    # more precise for binary game protocols (excludes categorized known
    # types that are already handled by dedicated handlers).
    # Inserted before the gentle fallback so aggressive-first ordering
    # is preserved; gentle renumbered from 12 to 13.
    game_udp="--lua-desync=circular:fails=2:time=60:udp_in=1:udp_out=4:key=game_udp:nld=2 --lua-desync=z2k_game_udp:strategy=1:payload=all:dir=out:blob=quic_google:repeats=10:ip_autottl=2,1-64 --lua-desync=z2k_game_udp:strategy=2:payload=all:dir=out:blob=quic_google:repeats=12:ip_autottl=3,1-64 --lua-desync=z2k_game_udp:strategy=3:payload=all:dir=out:blob=quic_google:repeats=12:ip_autottl=4,1-64 --lua-desync=z2k_game_udp:strategy=4:payload=all:dir=out:blob=quic_google:repeats=10:ip_autottl=5,1-64 --lua-desync=z2k_game_udp:strategy=5:payload=all:dir=out:blob=quic_ozon_ru:repeats=10:ip_autottl=2,1-64 --lua-desync=z2k_game_udp:strategy=6:payload=all:dir=out:blob=quic_ozon_ru:repeats=12:ip_autottl=4,1-64 --lua-desync=z2k_game_udp:strategy=7:payload=all:dir=out:blob=quic_google:repeats=10:ip_ttl=3 --lua-desync=z2k_game_udp:strategy=8:payload=all:dir=out:blob=quic_google:repeats=10:ip_ttl=4 --lua-desync=z2k_game_udp:strategy=9:payload=all:dir=out:blob=quic_google:repeats=14:ip_autottl=2,1-64 --lua-desync=udplen:payload=all:dir=out:increment=8:pattern=0xFEA82025:strategy=10 --lua-desync=send:payload=all:dir=out:ipfrag=z2k_ipfrag3_tiny:ipfrag_pos_udp=8:ipfrag_pos2=32:ipfrag_overlap12=8:ipfrag_overlap23=8:ipfrag_disorder:ipfrag_next2=255:strategy=11 --lua-desync=z2k_game_udp:strategy=12:payload=unknown:dir=out:blob=quic_google:repeats=4:ip_autottl=-2,3-20 --lua-desync=z2k_game_udp:strategy=13:payload=all:dir=out:blob=quic_google:repeats=8:ip_autottl=4,1-64"

    # Game TCP TLS rotator (GAME_PROFILE=flowseal only) — 6 representative
    # recipes lifted from flowseal 1.9.8 .bat files, translated to nfqws2
    # lua-desync DSL. circular/fails=2/time=60 + per-SLD pinning (nld=2)
    # is the same observability shape as rkn_tcp/yt_tcp; on TLS flows
    # the success/failure detectors actually have signal to converge on
    # (vs binary game TCP, which is why the static non-TLS arm has no
    # rotator).
    #
    # success_detector=z2k_success_no_reset matches yt_tcp pattern —
    # game-TLS auth/control flows are HTTPS-only, no HTTP redirect path
    # to police; a missing RST after handshake = success.
    # failure_detector=z2k_tls_alert_fatal catches TLS fatal alerts
    # which is the only clean fail signal on a TLS-only flow.
    # inseq=18000 is added by the ensure_circular_tcp_inseq pass below,
    # same as rkn_tcp/yt_tcp.
    #
    # Recipe sources:
    #   strategy=1 — general default (multisplit + seqovl=568 + 4pda)
    #   strategy=2 — ALT2 (multisplit + seqovl=652 + pos=2 + google)
    #   strategy=3 — ALT (fake,fakedsplit + ts + multi-blob)
    #   strategy=4 — ALT3 (fake,hostfakesplit + ya.ru SNI/host + ts)
    #   strategy=5 — ALT7 (syndata)
    #   strategy=6 — ALT8 (fake + badseq=2)
    # :badseq:badseq_increment=2: alias on strategy=6 is rewritten to
    # tcp_seq=2:tcp_ack=-66000 by expand_badseq_aliases() pass below.
    game_tls_tcp="--lua-desync=circular:fails=2:time=60:key=game_tls:nld=2:failure_detector=z2k_tls_alert_fatal:success_detector=z2k_success_no_reset:no_http_redirect --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to:strategy=1 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=2:seqovl=652:seqovl_pattern=tls_clienthello_www_google_com:strategy=2 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=stun:repeats=6:tcp_ts=-1000:strategy=3 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=6:tcp_ts=-1000:strategy=3 --lua-desync=fakedsplit:payload=tls_client_hello:dir=out:pos=1:strategy=3 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:tls_mod=rnd,dupsid,sni=ya.ru:tcp_ts=-1000:strategy=4 --lua-desync=hostfakesplit:payload=tls_client_hello:dir=out:host=ya.ru:tcp_ts=-1000:strategy=4 --lua-desync=syndata:payload=tls_client_hello:dir=out:blob=syn_packet:strategy=5 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:badseq:badseq_increment=2:strategy=6"

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
    game_udp=$(ensure_circular_nld2 "$game_udp")
    game_tls_tcp=$(ensure_circular_nld2 "$game_tls_tcp")

    # Override the default `inseq=4096` on TCP TLS circulars so the
    # standard success_detector does NOT fire prematurely before the
    # community-confirmed TSPU "16KB byte-gate" RST window
    # (typically observed at 12-18KB into the incoming stream — see
    # ntc.party 22516 / Habr 1009560). Source for the threshold
    # mechanic: zapret-auto.lua:236 — incoming `seq > arg.inseq`
    # triggers `standard_success_detector` → `crec.nocheck = true`,
    # at which point a later RST in the same flow is invisible to
    # any failure detector (zapret-auto.lua:261). With inseq=18000
    # success only fires after we've cleared the realistic gate
    # window; if the gate hits at 12-17K we still see the RST as a
    # failure and rotate.
    #
    # Limitation acknowledged: gates above ~18KB are NOT closed by
    # this. Reports of 24-32KB variants exist; those would need a
    # higher inseq, but raising it further also delays legitimate
    # success on small handshakes/payloads.
    #
    # Applied only to TCP TLS profiles (rkn_tcp, yt_tcp, gv_tcp).
    # UDP profiles (quic_udp, game_udp) use udp_in/udp_out instead
    # of inseq and are left untouched.
    ensure_circular_tcp_inseq() {
        local input="$1"
        local target="${2:-18000}"
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
                            inseq=*) ;;
                            *) rest="${rest:+$rest:}$part" ;;
                        esac
                    done
                    IFS="$old_ifs"
                    if [ -n "$rest" ]; then
                        token="--lua-desync=circular:${rest}:inseq=${target}"
                    else
                        token="--lua-desync=circular:inseq=${target}"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        IFS="$old_ifs"
        printf '%s' "$out"
    }

    youtube_tcp=$(ensure_circular_tcp_inseq "$youtube_tcp" 18000)
    youtube_gv_tcp=$(ensure_circular_tcp_inseq "$youtube_gv_tcp" 18000)
    # rkn_tcp inseq=26000 (Phase 1.2) — покрывает верхнюю границу TLS-stall'а
    # 14-25 KB по треду ntc.party 22516 #1, #3. yt/gv/game остаются на 18000:
    # их типичный first-burst меньше, риск не достичь inseq на легитимных
    # коротких потоках перевешивает.
    rkn_tcp=$(ensure_circular_tcp_inseq "$rkn_tcp" 26000)
    game_tls_tcp=$(ensure_circular_tcp_inseq "$game_tls_tcp" 18000)

    # ensure_circular_arg_set: append `<arg>=<value>` (or bare `<arg>` flag)
    # to every circular token in $input that doesn't already carry that arg.
    # Generic helper used to wire success_detector= / no_http_redirect /
    # failure_detector= etc. on TLS profiles. Idempotent for both forms:
    # repeated runs of create_official_config don't pile up duplicates.
    ensure_circular_arg_set() {
        local input="$1"
        local arg_name="$2"
        local arg_value="$3"  # may be empty for flag-style args
        local out=""
        local token=""
        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    case "$token" in
                        # value-form already present
                        *":${arg_name}="*) ;;
                        # flag-form already present in middle (followed by another arg)
                        *":${arg_name}:"*) ;;
                        # flag-form already present at end of token
                        *":${arg_name}") ;;
                        *)
                            if [ -n "$arg_value" ]; then
                                token="${token}:${arg_name}=${arg_value}"
                            else
                                token="${token}:${arg_name}"
                            fi
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    # Wire HTTP-aware success_detector for profiles whose flows can carry
    # HTTP responses subject to false-pin race (large 4xx body crossing
    # seq>inseq=18000 → standard success → nocheck → strategy pinned).
    # See z2k-detectors.lua: z2k_http_success_positive_only.
    #
    # http_rkn handled separately at line ~1100 (its profile string is
    # built inline, not from Strategy.txt). yt_tcp keeps its existing
    # z2k_success_no_reset (now made HTTP-neutral-aware in commit 4).
    rkn_tcp=$(ensure_circular_arg_set "$rkn_tcp" "success_detector" "z2k_http_success_positive_only")
    youtube_gv_tcp=$(ensure_circular_arg_set "$youtube_gv_tcp" "success_detector" "z2k_http_success_positive_only")

    # Wire HTTP-aware failure_detector for yt_tcp / gv_tcp.
    #
    # CRITICAL coverage gap if missing: with no_http_redirect set below,
    # standard_failure_detector's 302/307 cross-SLD branch is disabled
    # (zapret-auto.lua:182). For rkn_tcp the classifier check is reachable
    # via ensure_rkn_failure_detector below (which sets z2k_tls_stalled,
    # whose chain inherits z2k_tls_alert_fatal → z2k_http_classifier_check).
    # yt_tcp / gv_tcp had NO custom failure_detector — без этого assignment'а
    # 302 на lawfilter.* / warn.beeline.ru на yt_tcp не дошёл бы ни до
    # standard's redirect branch, ни до нашего classifier. Net regression.
    #
    # z2k_tls_alert_fatal is the minimum classifier-aware chain. yt_tcp
    # may benefit from z2k_tls_stalled later — это отдельное upgrade
    # решение; здесь восстанавливаем redirect-coverage инвариант,
    # утерянный с добавлением no_http_redirect.
    youtube_tcp=$(ensure_circular_arg_set "$youtube_tcp" "failure_detector" "z2k_silent_drop_detector")
    youtube_gv_tcp=$(ensure_circular_arg_set "$youtube_gv_tcp" "failure_detector" "z2k_silent_drop_detector")

    # Wire no_http_redirect on all TCP TLS profiles. This disables
    # standard_failure_detector's built-in 302/307 cross-SLD redirect
    # branch (zapret-auto.lua:182) — necessary because our v3.6
    # classifier downgrades cross-SLD-no-marker redirects from hard
    # fail to neutral (legit oauth/shortlink case). Without this flag,
    # standard would still hard-fail 302/307 cross-SLD before our
    # classifier ever runs.
    rkn_tcp=$(ensure_circular_arg_set "$rkn_tcp" "no_http_redirect" "")
    youtube_tcp=$(ensure_circular_arg_set "$youtube_tcp" "no_http_redirect" "")
    youtube_gv_tcp=$(ensure_circular_arg_set "$youtube_gv_tcp" "no_http_redirect" "")

    # Phase 6A: auto-inject fool=z2k_dynamic_ttl into every
    # --lua-desync=fake:*  (and fakedsplit/fakeddisorder/hostfakesplit) that
    # doesn't already pin an explicit TTL via ip_ttl=/ip6_ttl=/ip_autottl=/
    # ip6_autottl=/fool=. The z2k_dynamic_ttl fool hook (files/lua/z2k-fooling-ext.lua)
    # clamps the fake packet TTL to real_egress_ttl-1, making fakes look
    # identical to real client packets from a ТСПУ fingerprint standpoint.
    # Explicit TTL setters are respected — the override is opt-out on a
    # per-strategy basis by adding any of the above args to a strategy.
    #
    # Applied only to TCP profiles (rkn_tcp, yt_tcp, gv_tcp). UDP profiles
    # (quic, discord, game) don't use the fake/fakedsplit family the same
    # way and have their own tuning.
    inject_z2k_dynamic_ttl() {
        local input="$1"
        local token=""
        local out=""
        local skip=""
        for token in $input; do
            case "$token" in
                --lua-desync=fake:*|\
                --lua-desync=fakedsplit:*|\
                --lua-desync=fakeddisorder:*|\
                --lua-desync=hostfakesplit:*)
                    # Check if the token already pins TTL in any form.
                    skip=""
                    case "$token" in
                        *:ip_ttl=*|*:ip6_ttl=*|*:ip_autottl=*|*:ip6_autottl=*|*:fool=*) skip="1" ;;
                    esac
                    if [ -z "$skip" ]; then
                        token="${token}:fool=z2k_dynamic_ttl"
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    rkn_tcp=$(inject_z2k_dynamic_ttl "$rkn_tcp")
    youtube_tcp=$(inject_z2k_dynamic_ttl "$youtube_tcp")
    youtube_gv_tcp=$(inject_z2k_dynamic_ttl "$youtube_gv_tcp")

    # Phase 8: auto-inject z2k JA3 fingerprint breakers (grease, alpn,
    # psk, keyshare) into every --lua-desync=fake:... token that already
    # carries a tls_mod= list. We only extend existing tls_mod arguments;
    # strategies without tls_mod are left alone (they are either non-TLS
    # or intentionally avoid any ClientHello munging). Idempotent — if
    # z2k_grease/etc are already present, the token passes through
    # unchanged so repeated runs of create_official_config don't stack
    # duplicates.
    #
    # Depends on the fork nfqws2 build >= v0.9.4.7-z2k-r3 which
    # introduces the z2k_tls_mod.c dispatcher and the z2k_* mode names.
    # If an older upstream binary is running, parsing these tokens will
    # fail at nfqws2 startup.
    # $2 — `1` means also append `padencap` (Phase 1.4 Z2K_PADENCAP=1
    # default 1 = padencap включён всегда). При =0 padencap не добавляется.
    inject_z2k_tls_mods() {
        local input="$1"
        local with_padencap="${2:-0}"
        local token=""
        local out=""
        # r2 (2026-05-03): z2k_alpn / psk / keyshare после dup-skip fix'а
        # silently skipped на современных blob'ах (где соответствующие
        # extensions уже есть). Добавлены 4 редко-присутствующих
        # extensions для real JA3 distortion: earlydata / pha / sct /
        # delegcred. Требуется fork v0.9.5.2-z2k-r2+.
        local extra="z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare,z2k_earlydata,z2k_pha,z2k_sct,z2k_delegcred"
        if [ "$with_padencap" = "1" ]; then
            extra="${extra},padencap"
        fi
        for token in $input; do
            case "$token" in
                *:tls_mod=*)
                    case "$token" in
                        *z2k_grease*|*z2k_alpn*|*z2k_psk*|*z2k_keyshare*|*z2k_earlydata*|*z2k_pha*|*z2k_sct*|*z2k_delegcred*)
                            # Already extended once. If padencap requested
                            # but missing on this token, splice it in.
                            if [ "$with_padencap" = "1" ]; then
                                case "$token" in
                                    *padencap*) : ;;
                                    *)
                                        token=$(printf '%s' "$token" | sed 's|:tls_mod=\([^:]*\)|:tls_mod=\1,padencap|')
                                        ;;
                                esac
                            fi
                            ;;
                        *)
                            # Append z2k modes (and optionally padencap) to
                            # the tls_mod list. tls_mod= is comma-separated;
                            # we insert right after the existing value by
                            # rewriting the first `:tls_mod=VALUE` chunk so
                            # the new modes sit adjacent to upstream modes.
                            # Sed is enough because the value cannot
                            # contain a ':' (would terminate the token).
                            token=$(printf '%s' "$token" | sed "s|:tls_mod=\([^:]*\)|:tls_mod=\1,${extra}|")
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    # 2026-05-03: auto-injection z2k_grease/alpn/psk/keyshare/earlydata/
    # pha/sct/delegcred/padencap отключена. Field-проверка показала net
    # negative: на 7+/8 хостов наши TLS-extension'ы либо ломали handshake
    # (r0 — duplicate ALPN/PSK/key_share без skip-check), либо после r2
    # fix давали слабый JA3 distortion который autocircular не выбирал
    # (простой multisplit пробивает чище). На cloudflare.com fix r2 заработал,
    # но это починка бага r0, не реальный wins. Большинство хостов
    # pin'ятся на не-fake strategies (multisplit/hostfakesplit) у которых
    # tls_mod= вообще нет, инъекция к ним не применяется.
    #
    # Функции `inject_z2k_tls_mods` оставлены в файле и tokens z2k_*
    # доступны через --lua-desync=fake:tls_mod=...,z2k_grease,... — если
    # юзер хочет вручную в strats. Auto-инъекция отключена. Включить
    # обратно: вернуть три строки `inject_z2k_tls_mods` ниже.
    #
    # Z2K_PADENCAP / Z2K_INJECT_TLS_MODS флаги остаются для возможного
    # opt-in возврата, но default — НЕ инжектить ничего.
    local Z2K_INJECT_TLS_MODS
    Z2K_INJECT_TLS_MODS=$(safe_config_read "Z2K_INJECT_TLS_MODS" "${ZAPRET2_DIR:-/opt/zapret2}/config" "0")
    if [ "$Z2K_INJECT_TLS_MODS" = "1" ]; then
        local Z2K_PADENCAP
        Z2K_PADENCAP=$(safe_config_read "Z2K_PADENCAP" "${ZAPRET2_DIR:-/opt/zapret2}/config" "1")
        rkn_tcp=$(inject_z2k_tls_mods "$rkn_tcp" "$Z2K_PADENCAP")
        youtube_tcp=$(inject_z2k_tls_mods "$youtube_tcp")
        youtube_gv_tcp=$(inject_z2k_tls_mods "$youtube_gv_tcp")
    fi

    # Phase 6C: tcp_ts rotation across select rkn_tcp strategy slots.
    #
    # Background: ntc.party #826 + thread #812 (Feanor1397, 2026-04-12) и
    # последующие field-сигналы показывают, что значение `tcp_ts=-1000` на
    # части ТСПУ перестало проходить с ~2026-04-20 — fake packet режется,
    # пользователь видит 16KB cap (window_update инжект до handshake clearance).
    # На других ТСПУ -1000 продолжает работать.
    #
    # Стратегия: НЕ заменяем все вхождения `tcp_ts=-1000` (это поломает
    # провайдеров где -1000 живой). Вместо этого ротируем небольшое число
    # slot'ов на альтернативные значения, чтобы circular ротатор rkn_tcp
    # имел хотя бы одну живую ветвь на новом ТСПУ. Остальные слоты
    # остаются с -1000 для обратной совместимости.
    #
    # 2026-05-01 expansion (Phase 6C v2): после field-кейса где
    # autocircular зацепился за strategy=37 (tcp_ts=-1000:hostfakesplit) и
    # CSS-стримы дохли селективно (только HTML root пробивался) — расширили
    # ротацию с 4 до 10 слотов. Значения взяты из реально-рабочих field-
    # рецептов: Feanor1397 #812 (-43210), Decavoid #729 (-100000, -500000).
    # Архитектурный фикс через `cond=cond_tcp_has_ts` (bol-van #660-661 +
    # SeamniZ #815 `tcp_ts_up`) — отдельный PR (B-tier).
    #
    # Slot selection rationale (10 slots ≈ 50% от ~17 слотов с -1000):
    #   slot=11 — early-mid: fake+stun + fake+tls_clienthello_www_google_com
    #   slot=15 — mid:       fake+sni=ya.ru fallback
    #   slot=18 — mid:       fake+sni=fonts.google.com
    #   slot=23 — mid-late:  hostfakesplit:host=ozon.ru:tcp_md5
    #   slot=24 — mid:       fake+stun + fake+tls_clienthello_4pda_to
    #   slot=28 — mid-late:  fake+stun + fake+tls_max_ru
    #   slot=30 — late:      fake+stun:badsum + fake+tls_max_ru:msn.com
    #   slot=35 — late:      fake+tls_clienthello_4pda_to (fallback)
    #   slot=37 — late:      hostfakesplit:host=ozon.ru:badsum (the one that
    #                        bit Mark's browser today — pinned by autocircular,
    #                        broke CSS streams; was unrotated before this commit)
    #   slot=42 — late:      fake+fake_default_tls:badsum:tcp_seq=2
    #
    # Идемпотентно: повторный запуск над уже мутированной строкой просто
    # не находит `tcp_ts=-1000` в этих слотах и проходит no-op.
    #
    # Только rkn_tcp — yt_tcp/gv_tcp используют tcp_ts реже и для разных
    # целей; их ротация оставлена на отдельный анализ.
    rotate_rkn_tcp_ts_slots() {
        local input="$1"
        local out=""
        local token=""
        local strategy_id=""
        local new_ts=""
        for token in $input; do
            case "$token" in
                *:tcp_ts=-1000:*|*:tcp_ts=-1000)
                    strategy_id=$(printf '%s' "$token" | sed -n 's/.*:strategy=\([0-9][0-9]*\).*/\1/p')
                    case "$strategy_id" in
                        # Original 10 slots — sliding +6 после вставки 6 white-
                        # rescue strategies (positions 4,5,6,10,11,12 в rkn arm).
                        # Все исходные strategy=7..48 сдвинулись на +6, slot IDs
                        # отслеживают физические tcp_ts=-1000 токены.
                        11) new_ts="-43210"  ;;
                        15) new_ts="-100000" ;;
                        18) new_ts="-500000" ;;
                        23) new_ts="-43210"  ;;
                        24) new_ts="-7777"   ;;
                        28) new_ts="-10000"  ;;
                        30) new_ts="-7777"   ;;
                        35) new_ts="-43210"  ;;
                        37) new_ts="-100000" ;;
                        42) new_ts="-10000"  ;;
                        # New rotated slots (Phase 1.3, теперь после +6 сдвига).
                        # tcp_ts=-1000 частично сгорел с 2026-04-20 — нестандартные
                        # ts для variability fingerprint'а.
                        25) new_ts="-43210"  ;;
                        26) new_ts="-10000"  ;;
                        38) new_ts="-7777"   ;;
                        40) new_ts="-100000" ;;
                        *)  new_ts=""        ;;
                    esac
                    if [ -n "$new_ts" ]; then
                        token=$(printf '%s' "$token" | sed -e "s/:tcp_ts=-1000:/:tcp_ts=${new_ts}:/g" -e "s/:tcp_ts=-1000\$/:tcp_ts=${new_ts}/")
                    fi
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    rkn_tcp=$(rotate_rkn_tcp_ts_slots "$rkn_tcp")

    # Phase 14: bol-van badseq alias expansion.
    #
    # Upstream bol-van/zapret has `--dpi-desync-fooling=badseq` with
    # integer defaults -10000 for tcp_seq and -66000 for tcp_ack (the
    # -66000 value is specifically chosen to drift past Linux conntrack's
    # window-scaled tolerance introduced in 2.6.18; see GoodbyeDPI
    # fakepackets.c:218 for the reference). The flag, when set, just
    # does `th_seq += increment` and `th_ack += ack_increment` inside
    # fill_tcphdr() on fake/decoy packets only, never on real data.
    #
    # Our zapret2 fork dropped FOOL_BADSEQ from C-side fooling bits
    # (the whole fooling machinery was rewritten to Lua standard-fooling),
    # so tokens like `:badseq:badseq_increment=N:badseq_ack_increment=M:`
    # written in the spirit of bol-van get silently ignored by the Lua
    # argument parser — they're dead noise in 8 of our rkn_tcp strategies
    # and 6 yt/gv variants. The functional equivalent in our code is
    # `tcp_seq=N:tcp_ack=M` inside standard fooling, which does land in
    # apply_fooling() → reconstructed fake packet, matching bol-van's
    # fill_tcphdr() behavior bit-for-bit.
    #
    # This preprocessor transparently rewrites the bol-van syntax into
    # our tcp_seq/tcp_ack syntax:
    #   `:badseq:`                        → `:tcp_seq=-10000:tcp_ack=-66000:`
    #   `:badseq_increment=N:`            → `:tcp_seq=N:tcp_ack=-66000:`
    #   `:badseq_increment=N:badseq_ack_increment=M:` → `:tcp_seq=N:tcp_ack=M:`
    #
    # Existing explicit `tcp_seq=` / `tcp_ack=` on the same token win
    # (we never override an explicit user setting). The badseq tokens
    # themselves are dropped from the output so there's no residual
    # dead syntax in NFQWS2_OPT. Applied to fake-family tokens (fake,
    # fakedsplit, fakeddisorder, hostfakesplit, rst, rstack, syndata,
    # synack) — strictly mirroring bol-van's "fake/decoy only" invariant.
    expand_badseq_aliases() {
        local input="$1"
        local token=""
        local out=""
        for token in $input; do
            case "$token" in
                --lua-desync=fake:*|\
                --lua-desync=fakedsplit:*|\
                --lua-desync=fakeddisorder:*|\
                --lua-desync=hostfakesplit:*|\
                --lua-desync=rst:*|\
                --lua-desync=rstack:*|\
                --lua-desync=syndata:*|\
                --lua-desync=synack:*)
                    case "$token" in
                        # The literal `:` chars in `*:badseq:*` act as
                        # left+right word boundaries — tokens like
                        # `:fakebadseq:` or `:badseq_extra:` cannot match
                        # (the second `:` would require `badseq` followed
                        # by `:`). The other two patterns target
                        # `:badseq_increment=<N>:` / `:badseq_ack_increment=<N>:`
                        # explicitly, with no ambiguity.
                        *:badseq:*|*:badseq_increment=*|*:badseq_ack_increment=*)
                            token=$(printf '%s' "$token" | awk '
                                BEGIN { FS = ":"; OFS = ":"; DEF_SEQ = -10000; DEF_ACK = -66000 }
                                {
                                    has = 0
                                    seq_set = 0; seq_val = DEF_SEQ
                                    ack_set = 0; ack_val = DEF_ACK
                                    ex_seq = 0; ex_ack = 0
                                    out = ""
                                    for (i = 1; i <= NF; i++) {
                                        p = $i
                                        if (p == "badseq") { has = 1; continue }
                                        if (index(p, "badseq_increment=") == 1) {
                                            has = 1; seq_set = 1
                                            seq_val = substr(p, length("badseq_increment=") + 1)
                                            continue
                                        }
                                        if (index(p, "badseq_ack_increment=") == 1) {
                                            has = 1; ack_set = 1
                                            ack_val = substr(p, length("badseq_ack_increment=") + 1)
                                            continue
                                        }
                                        if (index(p, "tcp_seq=") == 1) ex_seq = 1
                                        if (index(p, "tcp_ack=") == 1) ex_ack = 1
                                        out = (out == "" ? p : out ":" p)
                                    }
                                    if (has) {
                                        if (!ex_seq) out = out ":tcp_seq=" seq_val
                                        if (!ex_ack) out = out ":tcp_ack=" ack_val
                                    }
                                    print out
                                }
                            ')
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    rkn_tcp=$(expand_badseq_aliases "$rkn_tcp")
    youtube_tcp=$(expand_badseq_aliases "$youtube_tcp")
    youtube_gv_tcp=$(expand_badseq_aliases "$youtube_gv_tcp")
    game_tls_tcp=$(expand_badseq_aliases "$game_tls_tcp")

    # Phase 14b: strip dead :out_range=*: / :in_range=*: tokens from
    # inside --lua-desync=... args.
    #
    # These live as CLI-level in-profile filters (--out-range / --in-range
    # per docs/manual.en.md:696, nfqws.c:2147-2148), NOT as per-strategy
    # Lua args. When someone writes `:out_range=-n2:` inside a lua-desync
    # token (a common mistake copied from bol-van syntax where
    # --dpi-desync-cutoff=n2 lives on the command line), the Lua arg
    # parser happily stores it in desync.arg.out_range and no Lua
    # function ever reads it — silent no-op. blockcheck-generated
    # Strategy.txt files from older z2k versions are full of these
    # tokens, and they clutter the generated NFQWS2_OPT without
    # doing anything. This preprocessor scrubs them.
    #
    # Applied to every strategy string that might have been hand-edited
    # or imported from older Strategy.txt blockcheck output.
    strip_dead_range_args() {
        local input="$1"
        local token=""
        local out=""
        for token in $input; do
            case "$token" in
                --lua-desync=*)
                    case "$token" in
                        *:out_range=*|*:in_range=*)
                            token=$(printf '%s' "$token" | awk '
                                BEGIN { FS = ":"; OFS = ":" }
                                {
                                    out = ""
                                    for (i = 1; i <= NF; i++) {
                                        p = $i
                                        if (index(p, "out_range=") == 1) continue
                                        if (index(p, "in_range=") == 1) continue
                                        out = (out == "" ? p : out ":" p)
                                    }
                                    print out
                                }
                            ')
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    rkn_tcp=$(strip_dead_range_args "$rkn_tcp")
    youtube_tcp=$(strip_dead_range_args "$youtube_tcp")
    youtube_gv_tcp=$(strip_dead_range_args "$youtube_gv_tcp")
    quic_udp=$(strip_dead_range_args "$quic_udp")

    # z2k-classify generator dynamic-strategy slot.
    # Appends --lua-desync=z2k_dynamic_strategy:strategy=(maxN+1) to
    # rkn_tcp so the classify generator can probe candidate strategies
    # without modifying strats_new2.txt or restarting nfqws2: pin
    # (profile_key, host) → slot in state.tsv, write params to
    # /tmp/z2k-classify-dynparams, and the next TLS handshake to that
    # host runs through the handler.
    #
    # MUST be sequential (last+1) — count_strategies() in
    # zapret-auto.lua errors on gaps in strategy=N numbering
    # ("strategies must start from 1 and increment").
    #
    # Only rkn_tcp gets the handler for now. youtube_tcp / youtube_gv_tcp
    # are merged into google_tls in Phase 3 with strategy renumbering;
    # appending the handler before merge would create a gap after
    # rebase. Adding handler support for google_tls comes in
    # a follow-up that injects after the merge step.
    z2k_dynamic_max_strategy() {
        printf '%s' "$1" | grep -oE ':strategy=[0-9]+' \
            | sed 's/^:strategy=//' | sort -n | tail -1
    }
    local rkn_tcp_max rkn_tcp_slot
    rkn_tcp_max=$(z2k_dynamic_max_strategy "$rkn_tcp")
    [ -z "$rkn_tcp_max" ] && rkn_tcp_max=0
    rkn_tcp_slot=$((rkn_tcp_max + 1))
    rkn_tcp="$rkn_tcp --lua-desync=z2k_dynamic_strategy:strategy=$rkn_tcp_slot"

    # Slot id lookup file for the inject helper (bash-grep'able).
    {
        printf '# auto-generated by config_official.sh — handler slot ids\n'
        printf 'rkn_tcp=%s\n' "$rkn_tcp_slot"
    } > "${ZAPRET2_DIR:-/opt/zapret2}/dynamic-slots.conf" 2>/dev/null || true

    discord_udp=$(strip_dead_range_args "$discord_udp")
    game_udp=$(strip_dead_range_args "$game_udp")

    # Phase 3 helper: rebase every `:strategy=N` inside a strategy string
    # by a fixed offset. Used to shift GV strategies (1..22) to (23..44)
    # so they don't collide with youtube_tcp's 1..22 when the two
    # profiles are merged into google_tls. Not applied unconditionally —
    # only invoked inside the Phase 3 emit guard.
    rebase_strategy_ids() {
        local input="$1"
        local offset="$2"
        # Consume $0 by moving past each rewritten `:strategy=N` — naïve
        # `while match` loops forever because the new (N+off) value is
        # itself a :strategy=[0-9]+ match at the same position.
        printf '%s' "$input" | awk -v off="$offset" '
            {
                result = ""
                # Match :strategy=<int> with optional leading whitespace
                # and optional sign so future Strategy.txt formats
                # (negative IDs, indented keys) survive a rebase.
                while (match($0, /:strategy=[[:space:]]*-?[0-9]+/)) {
                    result = result substr($0, 1, RSTART - 1)
                    raw = substr($0, RSTART + 10, RLENGTH - 10)
                    gsub(/[[:space:]]/, "", raw)
                    sid = (raw + 0) + off
                    result = result ":strategy=" sid
                    $0 = substr($0, RSTART + RLENGTH)
                }
                result = result $0
                print result
            }'
    }

    # Phase 7: convert fixed `repeats=N` on fake-family actions to the
    # range syntax `repeats=max(1,N-2)-(N+2)`. The z2k-range-rand.lua
    # wrapper picks a sticky random integer per flow from this range,
    # breaking per-flow DPI fingerprints that hash on fake-packet count.
    # Midpoint matches the original value, so average behaviour is
    # unchanged and there's no performance hit.
    #
    # Idempotency: awk регексп `^repeats=[0-9]+$` строго точечный —
    # part'ы вида `repeats=N-M` (уже диапазон) не матчатся, проходят
    # через awk без изменений. Этот же регексп служит фильтром на
    # пользовательские хитрости вроде `repeats=4-8` — мы их не трогаем.
    #
    # 2026-05-01 fix: убран outer glob `case "$token" in *:repeats=*-*) : ;;`
    # — он давал false-positive на любом токене где после `:repeats=N`
    # встречался `-` (например `tcp_ts=-1000`, `tcp_seq=-66000`,
    # `ip_autottl=-2,3-20`). Из-за этого 39 fake-токенов с tcp_ts
    # никогда не получали randomization — TSPU видела предсказуемый
    # repeat count для fingerprint'а. awk внутри сам корректно
    # идемпотентен на per-part уровне, outer глоб был избыточен и багован.
    inject_z2k_range_rand() {
        local input="$1"
        local token=""
        local out=""
        for token in $input; do
            case "$token" in
                --lua-desync=fake:*|\
                --lua-desync=fakedsplit:*|\
                --lua-desync=fakeddisorder:*|\
                --lua-desync=hostfakesplit:*|\
                --lua-desync=syndata:*)
                    case "$token" in
                        *:repeats=*)
                            token=$(printf '%s' "$token" | awk '
                                {
                                    n = split($0, parts, ":")
                                    for (i = 1; i <= n; i++) {
                                        if (parts[i] ~ /^repeats=[0-9]+$/) {
                                            v = substr(parts[i], 9) + 0
                                            lo = (v - 2 < 1) ? 1 : v - 2
                                            hi = v + 2
                                            parts[i] = "repeats=" lo "-" hi
                                        }
                                    }
                                    out = parts[1]
                                    for (i = 2; i <= n; i++) out = out ":" parts[i]
                                    print out
                                }
                            ')
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    rkn_tcp=$(inject_z2k_range_rand "$rkn_tcp")
    youtube_tcp=$(inject_z2k_range_rand "$youtube_tcp")
    youtube_gv_tcp=$(inject_z2k_range_rand "$youtube_gv_tcp")

    # NOTE: rkn_tcp default failure_detector is z2k_tls_stalled
    # (set in ensure_rkn_failure_detector() below, applied AFTER injectors
    # run). См. там же подробности про revert mid_stream_stall → tls_stalled
    # 2026-04-30 после code-review.

    # Let YouTube TLS circular operate exactly as in the upstream manual.
    # For LG webOS the orchestrator must see incoming packets on the circular
    # stage itself (`--in-range=-sN`), while actual desync instances must
    # still stay limited by `--payload=tls_client_hello...`.
    #
    # This requires moving the top-level `--payload=` after circular and
    # closing the incoming window right after circular with `--in-range=x`.
    # Keeping payload before circular makes YouTube TCP/GV fail detection too
    # blind and prevents real sequential rotation on TV clients.
    #
    # $2 is the byte cap for the inserted `--in-range=-sN`; default 5556
    # matches the master-compatible layout. rkn_tcp passes 20000 when the
    # mid-stream-detector bundle flag is on, so its lua failure_detector
    # can observe the [8K, 18K] CF stall window.
    ensure_youtube_tls_circular_manual_layout() {
        local input="$1"
        local in_range_bytes="${2:-5556}"
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

        printf '%s --in-range=-s%s %s --in-range=x %s%s%s' \
            "$before_circular" \
            "$in_range_bytes" \
            "$circular_token" \
            "$saved_payload" \
            "${after_circular:+ }" \
            "$after_circular"
    }

    # YouTube TCP on LG webOS often fails as a silent TCP blackhole:
    # repeated ClientHello attempts with no visible response_state/success_state.
    # Manual payload reordering alone is not sufficient in that mode.
    #
    # Conservative TCP failure path:
    # - expose incoming packets to circular via --in-range=-sN
    # - expose empty packets / retrans context via --payload=tls_client_hello,empty
    # - keep desync strategy instances restricted to the original TLS payload
    # - prevent successes from other devices on the same domain from resetting
    #   failure counters via success_detector=z2k_success_no_reset
    #
    # Used by youtube_tcp (default) and by rkn_tcp's RKN_SILENT_FALLBACK=1
    # path. The two share the same conservative shape; the rkn_tcp silent
    # path passes the bundle's byte cap (20000 when
    # Z2K_USE_MID_STREAM_DETECTOR=1) instead of the youtube default so
    # the byte-window detector isn't silently blinded past 5.5K when
    # both flags are on.
    #
    # $2 is the byte cap for the inserted `--in-range=-sN`; default 5556
    # matches the master-compatible layout that youtube_tcp keeps.
    ensure_youtube_tls_failure_detection() {
        local input="$1"
        local in_range_bytes="${2:-5556}"
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
                    out="${out:+$out }--in-range=-s${in_range_bytes}"
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

    # RKN: failure_detector — z2k_tls_stalled by default, overridable
    # to z2k_mid_stream_stall through Z2K_USE_MID_STREAM_DETECTOR=1.
    #
    # 2026-04-30 the default was reverted from mid_stream_stall to
    # tls_stalled because the original mid_stream_stall implementation
    # had four architectural problems that combined into a worse-than-
    # nothing detector — see commit fdc7145 for the full diagnosis.
    # 14984c3 (2026-05-01) landed a v3 redesign of z2k_mid_stream_stall:
    # per-flow byte tracking via desync.track.lua_state, multi-
    # candidate map per nld=2 key, FIN/RST closure handling, active-
    # retry gate via ch_gap. Tests in tests/test_mid_stream_stall.lua
    # codify the contract.
    #
    # The bundle flag Z2K_USE_MID_STREAM_DETECTOR ties together the
    # two knobs that have to move as a pair: failure_detector swap AND
    # the --in-range=-s5556 → -s20000 widening below. Default 0 keeps
    # the proven master-compatible runtime; set to 1 in
    # /opt/zapret2/config to opt into the redesigned detector.
    # Rollback is "set the flag back to 0, regenerate config, restart".
    #
    # z2k_tls_stalled (when flag=0) catches "CH sent, no SH" — visible
    # in the first ~1KB so s5556 gate doesn't blind it. Inherits
    # z2k_tls_alert_fatal so retrans / RST / HTTP redirect / TLS fatal
    # alert remain covered.
    ensure_rkn_failure_detector() {
        local input="$1"
        local detector_name="${2:-z2k_tls_stalled}"
        local out=""
        local token=""

        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    case "$token" in
                        *failure_detector=*) ;;
                        *) token="${token}:failure_detector=${detector_name}" ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done

        printf '%s' "$out"
    }

    # rkn_tcp primary failure_detector — z2k_silent_drop_detector (2026-05-03).
    # Внутри chain делегирует ко всем TLS detectors: mid_stream_stall (TLS
    # byte-window), tls_stalled (CH-without-SH), tls_alert_fatal (alert/HTTP
    # classifier). Z2K_USE_MID_STREAM_DETECTOR=1 продолжает регулировать
    # --in-range byte cap (s5556 → s20000), но primary detector один и тот же.
    local rkn_in_range_bytes="5556"
    if [ "$Z2K_USE_MID_STREAM_DETECTOR" = "1" ]; then
        rkn_in_range_bytes="20000"
    fi
    rkn_tcp=$(ensure_rkn_failure_detector "$rkn_tcp" "z2k_silent_drop_detector")

    # Silent fallback для RKN — включается через меню (флаг-файл).
    # failure_detection включает в себя manual_layout (--in-range + payload),
    # поэтому они взаимоисключающие, не накладываются.
    local rkn_silent_conf="${ZAPRET2_DIR:-/opt/zapret2}/config"
    local RKN_SILENT_FALLBACK
    RKN_SILENT_FALLBACK=$(safe_config_read "RKN_SILENT_FALLBACK" "$rkn_silent_conf" "0")
    local rkn_silent_flag="${extra_strats_dir}/cache/autocircular/rkn_silent_fallback.flag"
    if [ "$RKN_SILENT_FALLBACK" = "1" ]; then
        rkn_tcp=$(ensure_youtube_tls_failure_detection "$rkn_tcp" "$rkn_in_range_bytes")
        touch "$rkn_silent_flag" 2>/dev/null
    else
        rkn_tcp=$(ensure_youtube_tls_circular_manual_layout "$rkn_tcp" "$rkn_in_range_bytes")
        rm -f "$rkn_silent_flag" 2>/dev/null
    fi

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

    # Game mode flag — evaluated once, used by game UDP profile below.
    # New flag GAME_MODE_ENABLED with backwards-compat fallback to the
    # legacy ROBLOX_UDP_BYPASS so routers running older z2k (that wrote
    # only the legacy name) continue to flip correctly after update.
    local game_conf="${ZAPRET2_DIR:-/opt/zapret2}/config"
    local GAME_MODE_ENABLED
    GAME_MODE_ENABLED=$(safe_config_read "GAME_MODE_ENABLED" "$game_conf" "")
    if [ -z "$GAME_MODE_ENABLED" ]; then
        GAME_MODE_ENABLED=$(safe_config_read "ROBLOX_UDP_BYPASS" "$game_conf" "0")
    fi
    # GAME_MODE_STYLE — safe|hybrid|aggressive. Default "safe" for backwards
    # compatibility (pre-hybrid routers keep their existing ipset +
    # circular-rotator behavior when this flag isn't in config yet).
    #   safe       — positive --ipset=game_ips.txt + 6-strategy rotator.
    #                Only IPs listed in game_ips.txt pass the profile, so
    #                the rotator never burns fails on Discord/Steam noise.
    #   hybrid     — same ipset profile first, PLUS a UDP catchall on
    #                1024-65535 (no ipset). Picks up cloud-hosted game
    #                flows on IPs NOT in game_ips.txt (no-SNI sessions
    #                on arbitrary high UDP ports).
    #                Caveat: the UDP catchall perturbs the first 4
    #                packets of unrelated UDP flows on 1024-65535 —
    #                risks: Discord P2P voice/video, WebRTC calls
    #                (Meet/Zoom/Teams peer mode), BitTorrent DHT.
    #                Discord server-routed voice (ports 50000-50099,
    #                3478-3481, 5349, 19294-19344) is caught by the
    #                earlier Discord UDP profile and is unaffected.
    #                TCP is NOT touched by the catchall — see note in
    #                the profile block below (2026-04-24 regression fix).
    #   aggressive — only the UDP catchall, no ipset profile at all.
    #                Same UDP caveats as hybrid, and game_ips.txt-listed
    #                titles also lose their dedicated rotator.
    local GAME_MODE_STYLE
    GAME_MODE_STYLE=$(safe_config_read "GAME_MODE_STYLE" "$game_conf" "")
    case "$GAME_MODE_STYLE" in
        safe|hybrid) ;;
        aggressive)
            # Phase 2 merge: aggressive deprecated — aliased to hybrid when
            # Phase 2 is active. aggressive was "catchall-only without
            # positive ipset", which the merge collapses: the hybrid ipset
            # now includes aws_oracle, and the gentle catchall strategy
            # is just strategy=7 in the merged rotator. Pre-Phase-2 rollback
            # path still honors legacy aggressive semantics.
            [ "$Z2K_REFACTOR_PHASE2" = "1" ] && GAME_MODE_STYLE="hybrid"
            ;;
        *) GAME_MODE_STYLE="safe" ;;
    esac

    # GAME_PROFILE — selects between flowseal-mirrored single-strategy arm
    # (default, post-2026-04-30) and the legacy 13-strategy z2k rotator
    # (rollback path). Default "flowseal" because the legacy path empirically
    # only works on Roblox; flowseal 1.9.8 single-strategy is field-proven
    # across the broader game catalog (Apex/Tarkov/Darktide/etc).
    #   flowseal — one fake:dbankcloud:repeats=12:cutoff=n2 UDP arm scoped
    #              by flowseal_game_ips.txt (~31K CIDR aggregate).
    #              GAME_MODE_STYLE/Z2K_REFACTOR_PHASE2 ignored.
    #   legacy   — preserves existing safe/hybrid/aggressive ladder with
    #              Phase 2 merge or pre-Phase-2 two-profile layout.
    local GAME_PROFILE
    GAME_PROFILE=$(safe_config_read "GAME_PROFILE" "$game_conf" "")
    case "$GAME_PROFILE" in
        flowseal|legacy) ;;
        *) GAME_PROFILE="flowseal" ;;
    esac

    # RKN TCP (include Discord hostlist into RKN profile)
    local rkn_hostlists="--hostlist=${extra_strats_dir}/TCP/RKN/List.txt"
    [ -s "${extra_strats_dir}/TCP_Discord.txt" ] && rkn_hostlists="$rkn_hostlists --hostlist=${extra_strats_dir}/TCP_Discord.txt"
    # Shipped extras curated on top of runetfreedom RKN — domains users
    # reported missing (fast-torrent.ru etc). Refreshed on every install.
    [ -s "${lists_dir}/extra-domains.txt" ] && rkn_hostlists="$rkn_hostlists --hostlist=${lists_dir}/extra-domains.txt"
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt $rkn_hostlists $rkn_tcp --new"

    # cdn_tls профиль удалён 2026-04-27. Был добавлен в Variant A refactor
    # (b7f7ae6) для перехвата non-RKN CF/OVH/Hetzner/DO трафика, но на field
    # ломал то что и так работало через rkn_tcp (47-стратегий rotator
    # из Strategy.txt пробивал CF лучше чем 8 curated cdn_tls strategies).
    # CF возвращается под rkn_tcp как было до Variant A.

    # Phase 3 merge: YouTube + googlevideo collapsed to a single google_tls
    # profile. Hostlist triggers OR — hostlist=YT/List.txt ∪ hostlist-domains=
    # googlevideo.com (confirmed by hostlist.c:262-281). Circular pins per-SLD
    # thanks to nld=2, so youtube.com and googlevideo.com maintain independent
    # strategy picks even though they share the key=google_tls state.
    # GV strategies renumbered 23..44 to avoid collision with YT's 1..22.
    # Pre-Phase-3 else path keeps the legacy two-profile layout for rollback.
    if [ "$Z2K_REFACTOR_PHASE3" = "1" ]; then
        local youtube_gv_rebased
        youtube_gv_rebased=$(rebase_strategy_ids "$youtube_gv_tcp" 22)
        # Extract ONLY non-circular --lua-desync=* tokens from GV.
        # Global options (--filter-tcp, --filter-l7, --payload, --out-range,
        # --in-range) are dropped — youtube_tcp's own globals govern the
        # merged profile. Keeping GV globals would emit duplicate flags
        # (e.g. --filter-tcp=443 after --filter-tcp=443,2053,...) which
        # nfqws2 silently reinterprets as "last wins", shrinking the
        # effective port coverage of the merged profile.
        local gv_strategies_only=""
        local _tok
        for _tok in $youtube_gv_rebased; do
            case "$_tok" in
                --lua-desync=circular:*) ;;
                --lua-desync=*) gv_strategies_only="${gv_strategies_only:+$gv_strategies_only }$_tok" ;;
                *) ;;
            esac
        done
        local merged_google_tls
        merged_google_tls=$(printf '%s' "$youtube_tcp" | sed 's/key=yt_tcp/key=google_tls/')
        merged_google_tls="$merged_google_tls $gv_strategies_only"
        add_hostlist_line "${extra_strats_dir}/TCP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/YT/List.txt --hostlist-domains=googlevideo.com $merged_google_tls --new"
    else
        # YouTube TCP
        add_hostlist_line "${extra_strats_dir}/TCP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/YT/List.txt $youtube_tcp --new"
        # YouTube GV (список доменов статичен)
        nfqws2_opt_lines="$nfqws2_opt_lines--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist-domains=googlevideo.com $youtube_gv_tcp --new\\n"
    fi

    # QUIC YT
    add_hostlist_line "${extra_strats_dir}/UDP/YT/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/UDP/YT/List.txt $quic_udp --new"

    # Discord TCP: currently disabled for autocircular profile set.
    if [ -n "$discord_tcp_block" ]; then
        add_hostlist_line "${extra_strats_dir}/TCP_Discord.txt" "$discord_tcp_block"
    fi

    # Discord UDP (no hostlist - STUN has no hostname, uses filter-l7=discord,stun + allow_nohost)
    nfqws2_opt_lines="$nfqws2_opt_lines$discord_udp --new\\n"

    # webrtc_bypass — passthrough for non-Discord STUN flows (WebRTC P2P in
    # browsers, Discord peer-to-peer voice/video, BitTorrent DHT-adjacent).
    # A profile with --filter-l7=stun and no --lua-desync= short-circuits at
    # desync.c:900 (VERDICT_PASS), so matched packets exit unmodified.
    #
    # Ordering: AFTER discord_udp (so Discord's server-routed STUN on the
    # official port ranges still goes through Discord's dedicated rotator),
    # BEFORE game_udp (so P2P STUN on arbitrary high ports isn't perturbed
    # by the game ipset's fake shot).
    #
    # --out-range=-n4 keeps Lua short-circuit consistent with game_udp even
    # though this profile has no Lua strategies — marginal safety against a
    # future edit accidentally adding one.
    if [ "$Z2K_REFACTOR_PHASE1" = "1" ]; then
        nfqws2_opt_lines="$nfqws2_opt_lines--filter-udp=1024-65535 --filter-l7=stun --in-range=a --out-range=-n4 --new\\n"
    fi

    # === Game TCP arms (GAME_PROFILE=flowseal only) ===
    # nfqws2 is first-match-wins per packet, so RKN/YT/GV/Discord-control
    # TCP profiles above already catch web traffic on standard ports.
    # The carve-out below excludes 80/443/2053/2083/2087/2096/2408/8443
    # so even raw IP-match cannot pull web flows into game arms:
    #   80/443    — RKN/YT/GV TLS/HTTP
    #   2053/2083/2087/2096 — Cloudflare Spectrum alt-HTTPS
    #   2408      — Cloudflare Warp (engage.cloudflareclient.com control)
    #   8443      — Discord media TCP
    #
    # Hostlist-exclude placement differs per arm — see desync.c:248-251:
    # PROFILE_HOSTLISTS_EMPTY (params.h:109) tests BOTH include AND
    # exclude lists, and a non-empty hostlist with hostname=NULL causes
    # dp_match() to return false BEFORE the ipset check fires.
    #   • TLS rotator arm — flows carry SNI, hostname is resolvable,
    #     so --hostlist-exclude=whitelist/YT/RKN works as defense-in-
    #     depth against ECH-bearing or alt-port web flows.
    #   • non-TLS static arm — binary TCP has NO hostname → ANY
    #     hostlist-exclude makes the arm uniformly non-matching for
    #     its actual target. Defenses there are filter-l7=unknown +
    #     ipset + port carve-out (see comment above the emission line
    #     below).
    #
    # Two emitted arms (first-match-wins, TLS rotator before static):
    # 1. TCP TLS rotator (step 5): filter-l7=tls + circular over 6
    #    flowseal-derived recipes. Layout mirrors YT/GV pattern — circular
    #    BEFORE the --payload= gate so detectors see incoming RST/alerts/
    #    server hello/HTTP replies (--payload= is sticky and applies to
    #    every following --lua-desync= per nfqws.c:2955; without the
    #    split, circular's failure_detector + inseq=18000 are blind).
    # 2. TCP non-TLS static (step 4): payload=all + multisplit recipe
    #    mirroring flowseal 1.9.8 default. No circular — binary game TCP
    #    has no observable success/fail signal that a rotator could use.
    if [ "$GAME_PROFILE" = "flowseal" ] && [ "$GAME_MODE_ENABLED" = "1" ] && [ -s "${lists_dir}/flowseal_game_ips.txt" ]; then
        # Full carve-out per "Game arms must never include 80/443/8443/
        # 2053/2083/2087/2096" invariant; 2408 preserved from UDP arm.
        local game_tcp_ports="1024-2052,2054-2082,2084-2086,2088-2095,2097-2407,2409-8442,8444-65535"
        local game_tcp_ipset_excl=""
        [ -f "${lists_dir}/ipset-exclude.txt" ] && game_tcp_ipset_excl="--ipset-exclude=${lists_dir}/ipset-exclude.txt "

        # TLS rotator hostlist-excludes — SAFE here (vs the static arm
        # below) because filter-l7=tls + payload=tls_client_hello means
        # nfqws extracts SNI before dp_match() runs the hostlist gate at
        # desync.c:248-251. Excludes shield Discord control / Riot login
        # / EOS auth / etc. that resolve into RKN/YT/whitelist domains
        # but happen to land on game-port + game-ipset by coincidence.
        local game_tls_hostlist_excl="--hostlist-exclude=${lists_dir}/whitelist.txt"
        [ -s "${extra_strats_dir}/TCP/YT/List.txt" ] && \
            game_tls_hostlist_excl="$game_tls_hostlist_excl --hostlist-exclude=${extra_strats_dir}/TCP/YT/List.txt"
        [ -s "${extra_strats_dir}/TCP/RKN/List.txt" ] && \
            game_tls_hostlist_excl="$game_tls_hostlist_excl --hostlist-exclude=${extra_strats_dir}/TCP/RKN/List.txt"
        # TLS rotator — first match for game-port TLS handshakes. nfqws2
        # ordering is per-line first-match-wins, so this MUST emit before
        # the non-TLS static arm below; binary game TCP cleanly falls
        # through to that arm via filter-l7=tls miss.
        #
        # YT/GV-style layout — circular BEFORE --payload= gate so
        # detectors see incoming RST/alerts/server-hello/http_reply
        # packets (which is what failure_detector / success_detector /
        # inseq=18000 actually need). Per nfqws.c:2955, --payload= is
        # sticky: it applies to every following --lua-desync= until
        # --new resets it. Putting --payload=tls_client_hello between
        # circular and strategies leaves circular at default (all
        # payload types) and gates only the strategies to the outgoing
        # ClientHello. --in-range=-s5556 / --in-range=x mirrors the
        # ensure_youtube_tls_circular_manual_layout transform applied
        # to yt_tcp/gv_tcp at L800-815 — circular sees incoming up to
        # ServerHello region, strategies don't.
        local game_tls_circular="${game_tls_tcp%% *}"
        local game_tls_strategies="${game_tls_tcp#* }"
        nfqws2_opt_lines="$nfqws2_opt_lines--filter-tcp=${game_tcp_ports} --filter-l7=tls --ipset=${lists_dir}/flowseal_game_ips.txt ${game_tcp_ipset_excl}${game_tls_hostlist_excl} --out-range=-n3 --in-range=-s5556 ${game_tls_circular} --in-range=x --payload=tls_client_hello ${game_tls_strategies} --new\\n"

        # NO hostlist-exclude on this arm — see desync.c:248-251:
        #   bHostlistsEmpty = PROFILE_HOSTLISTS_EMPTY(dp);
        #   if (!dp->hostlist_auto && !hostname && !bHostlistsEmpty)
        #       return false;
        # PROFILE_HOSTLISTS_EMPTY checks BOTH include AND exclude lists
        # (params.h:109). Binary game TCP has no hostname (no SNI to
        # extract) → if any hostlist-exclude is set, dp_match() bails
        # before ipset check, killing the arm for its actual target.
        # Defense-in-depth shifts to: filter-l7=unknown (rejects TLS even
        # with ECH — nfqws TLS probe matches handshake header, not SNI),
        # ipset positive scope, ipset-exclude, port carve-out.
        # The TLS rotator in step 5 CAN safely use hostlist-exclude
        # because TLS flows carry SNI.
        # --filter-l7=unknown scopes this arm to traffic the nfqws2 L7
        # classifier could not identify (= binary game TCP). nfqws2
        # sets l7proto via per-packet probes in desync.c:33 BEFORE the
        # filter-l7 check at desync.c:240, so a TLS ClientHello on
        # the first data segment is correctly classified L7_TLS at
        # filter check and excluded. SYN/ACK (no payload) keep
        # l7proto=L7_UNKNOWN; multisplit on a payload-less segment
        # is a no-op.
        # Non-TLS static — multisplit:seqovl=568:pos=1 with tls_clienthello_4pda_to
        # seqovl pattern (blob already registered in S99zapret2.new:537).
        local flowseal_game_tcp_static="--lua-desync=multisplit:payload=all:dir=out:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to"
        nfqws2_opt_lines="$nfqws2_opt_lines--filter-tcp=${game_tcp_ports} --filter-l7=unknown --ipset=${lists_dir}/flowseal_game_ips.txt ${game_tcp_ipset_excl}--in-range=a --out-range=-n3 --payload=all $flowseal_game_tcp_static --new\\n"
    fi

    # Game Filter UDP — custom protocols, unknown payloads. Uses a positive
    # --ipset=game_ips.txt match so the strategy rotator fires ONLY on
    # listed game-server IPs, not on random Discord/Steam/BitTorrent UDP
    # that would otherwise exhaust the circular rotator's fails counter.
    #
    # Strategies live in extra_strats/UDP/GAMES/Strategy.txt (built-in fallback
    # is hardcoded above in case the file is missing). The z2k_game_udp Lua
    # handler (files/lua/z2k-modern-core.lua) is used instead of built-in
    # `fake` because upstream fake() drops `repeats=N` for UDP payloads; our
    # handler threads desync_opts through rawsend_dissect_ipfrag so repeats
    # is actually applied. Blob alias `quic_google` → quic_initial_www_google_com.bin.
    #
    # Gated by GAME_MODE_ENABLED (new) with backwards-compat fallback to
    # ROBLOX_UDP_BYPASS (old) — evaluated above. GAME_PROFILE selects which
    # implementation handles the gating positive.
    if [ "$GAME_PROFILE" = "flowseal" ]; then
        # Flowseal 1.9.8 single-strategy UDP arm:
        #   fake + repeats=12 + cutoff=n2 + payload=all + dbankcloud blob,
        #   scoped positive by flowseal_game_ips.txt (~31K CIDR aggregate
        #   refreshed daily by z2k-update-lists.sh).
        # z2k_game_udp Lua handler is used in place of built-in fake because
        # built-in fake silently drops repeats=N for UDP payloads (would
        # collapse to 1 fake instead of the field-validated 12).
        # Port range 1024-2407,2409-65535 keeps Warp 2408 carve-out and
        # excludes 80/443 (no UDP web on those — DNS/QUIC have dedicated
        # earlier profiles). cutoff=n2 limits desync to first 2 pkts of
        # each flow, matching flowseal exactly and keeping LAN/non-game
        # collateral negligible.
        if [ "$GAME_MODE_ENABLED" = "1" ] && [ -s "${lists_dir}/flowseal_game_ips.txt" ]; then
            local ipset_excl="${lists_dir}/ipset-exclude.txt"
            local game_ipset_excl_opt=""
            [ -f "$ipset_excl" ] && game_ipset_excl_opt="--ipset-exclude=${ipset_excl} "
            local flowseal_game_udp="--lua-desync=z2k_game_udp:strategy=1:payload=all:dir=out:blob=quic_dbankcloud:repeats=12"
            nfqws2_opt_lines="$nfqws2_opt_lines--filter-udp=1024-2407,2409-65535 --ipset=${lists_dir}/flowseal_game_ips.txt ${game_ipset_excl_opt}--in-range=a --out-range=-n2 --payload=all $flowseal_game_udp --new\\n"
        fi
    else
        # Legacy path (GAME_PROFILE=legacy) — preserved for rollback.
        # Phase 2 merge: game_udp + game_catchall_udp collapsed to one profile
        # with multi-ipset OR trigger. Safe = game_ips only, hybrid = +aws_oracle.
        # Pre-Phase-2 path (else branch below) keeps the legacy two-profile
        # layout for rollback.
        if [ "$Z2K_REFACTOR_PHASE2" = "1" ]; then
            if [ "$GAME_MODE_ENABLED" = "1" ] && [ -s "${lists_dir}/game_ips.txt" ]; then
                local ipset_excl="${lists_dir}/ipset-exclude.txt"
                local game_ipset_excl_opt=""
                [ -f "$ipset_excl" ] && game_ipset_excl_opt="--ipset-exclude=${ipset_excl} "
                # In hybrid mode, broaden the trigger with AWS/Oracle ranges
                # (populated by z2k-update-lists.sh Phase 5 fetcher). The
                # merged rotator's strategy=7 (gentle) pins on non-game AWS
                # flows after strategies 1-6 fail — replacing the old fixed
                # catchall behavior without a separate profile.
                local game_ipsets="--ipset=${lists_dir}/game_ips.txt"
                if [ "$GAME_MODE_STYLE" != "safe" ] && [ -s "${lists_dir}/aws_oracle_ips.txt" ]; then
                    game_ipsets="$game_ipsets --ipset=${lists_dir}/aws_oracle_ips.txt"
                fi
                # Warp 2408 carve-out preserved (ntc.party 17013 #568).
                # --out-range=-n4 cuts Lua pipeline after first 4 pkts.
                nfqws2_opt_lines="$nfqws2_opt_lines--filter-udp=1024-2407,2409-65535 $game_ipsets ${game_ipset_excl_opt}--in-range=a --out-range=-n4 --payload=all $game_udp --new\\n"
            fi
        elif [ "$GAME_MODE_ENABLED" = "1" ] && [ "$GAME_MODE_STYLE" != "aggressive" ] && [ -s "${lists_dir}/game_ips.txt" ]; then
            # Pre-Phase-2 legacy path: game_udp ipset profile.
            local ipset_excl="${lists_dir}/ipset-exclude.txt"
            local game_ipset_excl_opt=""
            [ -f "$ipset_excl" ] && game_ipset_excl_opt="--ipset-exclude=${ipset_excl} "
            # --out-range=-n4: apply the game_udp Lua chain only to the first
            # 4 outgoing packets of each UDP flow. Circular needs a handful of
            # early packets to pick + pin a strategy, z2k_game_udp's
            # replay_first() gate fires once anyway — beyond the 4th packet
            # the Lua layer is pure overhead, so we short-circuit in C. Was
            # previously --out-range=a (no limit) because the per-strategy
            # out_range=-nN tokens were silently dropped by the Lua parser.
            nfqws2_opt_lines="$nfqws2_opt_lines--filter-udp=1024-65535 --ipset=${lists_dir}/game_ips.txt ${game_ipset_excl_opt}--in-range=a --out-range=-n4 --payload=all $game_udp --new\\n"
        fi
    fi

    # Game catchall (hybrid/aggressive) — winws-style broad-sweep.
    # One fixed strategy per protocol (no rotator with fails=1; the rotator
    # would be exhausted within seconds by Discord/Steam/BitTorrent UDP
    # noise, which is exactly why the ipset profile above has to be
    # positive-filtered). The catchall targets cloud-hosted game flows
    # that land on arbitrary high ports with no usable hostname — and
    # relies on cutoff=n4 to only perturb the first 4 packets of each
    # flow so legitimate non-game traffic is barely affected.
    #
    # Known collateral risks (watch these when triaging new reports):
    #   • Discord peer-to-peer voice/video (Settings → Voice & Video →
    #     "Use peer-to-peer") — P2P mode opens UDP on random high ports
    #     outside the Discord profile's 50000-50099/3478-3481/5349/
    #     19294-19344 whitelist, so those flows do hit the catchall and
    #     the first-4-packet fake can break ICE handshake. Server-routed
    #     Discord voice is unaffected.
    #   • WebRTC in browsers (Google Meet / Zoom / Teams) when doing
    #     direct peer calls — same class of issue.
    #   • BitTorrent DHT / uTP traffic on 1024-65535.
    #
    # UDP-only design (2026-04-24 regression fix after Andrey report):
    # a TCP catchall on 1024-65535 also fires on the router's OUTPUT
    # chain, where LAN-bound responses from the router itself go — so
    # the router's own web UI and the z2k webpanel became unreachable
    # for any LAN client that ended up with an ephemeral source port in
    # 1024-65535 (most Linux clients). Removed TCP catchall entirely.
    # UDP catchall still covers the winws.exe gaming_N.conf (non-
    # _ultimate) layout, which is what Andrey's working Windows config
    # actually uses — the _ultimate TCP arm was our over-reach.
    #
    # Flags chosen to match winws.exe gaming_5 (non-ultimate):
    #   --lua-desync=fake   = --dpi-desync=fake
    #   payload=all         ≈ --dpi-desync-any-protocol=1 (process all L7)
    #   blob=quic_google    = --dpi-desync-fake-unknown-udp=<quic init>
    #   ip_autottl=4,1-64   = --dpi-desync-autottl=4
    #   out_range=-n4       = --dpi-desync-cutoff=n4
    #   repeats=8           = --dpi-desync-repeats=8
    #
    # UDP uses the z2k_game_udp Lua handler (not built-in fake) because
    # built-in fake still drops repeats=N on UDP payloads.
    #
    # Phase 2 merge makes this block dead — catchall behavior is absorbed
    # into the merged game_udp rotator (strategy=7) above. Block retained
    # as pre-Phase-2 rollback path, guarded by the negated flag.
    if [ "$GAME_PROFILE" != "flowseal" ] && [ "$Z2K_REFACTOR_PHASE2" != "1" ] && [ "$GAME_MODE_ENABLED" = "1" ] && [ "$GAME_MODE_STYLE" != "safe" ]; then
        # out_range moved to the profile itself (--out-range=-n4 below),
        # the inline value was dead (see game_udp comment above).
        local game_catchall_udp="--lua-desync=z2k_game_udp:strategy=1:payload=all:dir=out:blob=quic_google:repeats=8:ip_autottl=4,1-64"
        # Port 2408 excluded — Cloudflare Warp (AmneziaWG) control-plane endpoint
        # engage.cloudflareclient.com:2408 is the only port that still works for
        # Warp from RU (ntc.party 17013 #560), and any QUIC/fake shot at its
        # handshake packets kills the tunnel (ntc.party 17013 #568). Warp does
        # not use 2408 for anything else, so losing catchall coverage on that
        # single port is a safe tradeoff.
        # --out-range=-n4: same first-4-packets cutoff as the ipset
        # profile above. For the catchall this matters more — we're
        # looking at every UDP flow on 1024-65535, so limiting Lua
        # evaluation to the opening handshake is a big CPU win.
        nfqws2_opt_lines="$nfqws2_opt_lines--filter-udp=1024-2407,2409-65535 --in-range=a --out-range=-n4 --payload=all $game_catchall_udp --new\\n"
    fi

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
    local rkn_http_extras=""
    [ -s "${lists_dir}/extra-domains.txt" ] && rkn_http_extras=" --hostlist=${lists_dir}/extra-domains.txt"
    # http_rkn failure_detector — chain через z2k_silent_drop_detector
    # (default ON 2026-05-03). silent_drop проверяет packet-count: 4+
    # outgoing data + ≤1 incoming = ТСПУ silent drop, который
    # content-based detectors не ловят (нет TLS alert / нет mid-stream
    # bytes — данных вообще нет). Если silent-drop не сработал, цепочка
    # делегирует к z2k_http_mid_stream_stall (byte-window 14-25KB,
    # ntc.party 22516) затем z2k_tls_alert_fatal (HTTP classifier +
    # TLS handshake stall). При Z2K_USE_MID_STREAM_DETECTOR=0 chain
    # пропускает mid_stream звено, остаётся silent_drop → tls_alert.
    local http_rkn_failure_detector="z2k_silent_drop_detector"
    # http_rkn (port 80 HTTP profile). v3.6 commit 4 wiring:
    #   - success_detector=z2k_http_success_positive_only
    #     (default standard would fire success on seq>inseq even for
    #     4xx replies, pinning broken strategies)
    #   - no_http_redirect (off-loads 302/307 redirect branch from
    #     standard_failure_detector — our z2k_tls_alert_fatal chain
    #     drives all redirect classification through z2k_classify_http_reply)
    # http_rkn payload filter:
    #   http_req  — outgoing GET/POST (что строит модифицирующая стратегия)
    #   empty     — TCP control packets без payload (SYN/ACK сами по себе
    #                 проходят через standard_failure_detector RST-чек)
    #   http_reply — ИНКОМИНГ HTTP-ответ от сервера. Без этого профиль
    #                 фильтрует replies на entry, и detector chain никогда
    #                 не видит l7=http_reply → z2k_classify_http_reply
    #                 (commits 3-4 v3.6) становится dead code на всех
    #                 plain HTTP flows. Field-test 2026-04-30 показал 0
    #                 http_reply events за весь soak — добавили http_reply
    #                 чтобы классификатор реально видел ответы. Strategies
    #                 (multisplit/syndata/fake/etc) внутри scope-нуты на
    #                 payload=http_req, так что они не сработают на
    #                 incoming replies — только detectors классифицируют.
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "--filter-tcp=80 --hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/RKN/List.txt${rkn_http_extras} --in-range=-s5556 --payload=http_req,empty,http_reply --lua-desync=circular:fails=2:time=60:reset:key=http_rkn:nld=2:failure_detector=${http_rkn_failure_detector}:success_detector=z2k_http_success_positive_only:no_http_redirect --lua-desync=http_methodeol:payload=http_req:dir=out:strategy=1 --lua-desync=syndata:payload=http_req:dir=out:strategy=2 --lua-desync=multisplit:payload=http_req:dir=out:strategy=2 --lua-desync=hostfakesplit:payload=http_req:dir=out:ip_ttl=2:repeats=1:strategy=3 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=4 --lua-desync=fakedsplit:payload=http_req:dir=out:pos=method+2:badsum:strategy=5 --lua-desync=fake:payload=http_req:dir=out:blob=0x0E0E0F0E:tcp_md5:strategy=6 --lua-desync=multisplit:payload=http_req:dir=out:pos=host+1:seqovl=2:strategy=6 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=7 --lua-desync=multisplit:payload=http_req:dir=out:pos=method+2:strategy=7 --lua-desync=z2k_http_methodeol_safe:payload=http_req:dir=out:strategy=8 --lua-desync=z2k_http_xpadding:payload=http_req:dir=out:strategy=9 --lua-desync=z2k_http_inject_safe_header:payload=http_req:dir=out:strategy=10 --lua-desync=z2k_http_simple_bypass:payload=http_req:dir=out:strategy=11 --lua-desync=z2k_http_lf_prefix:payload=http_req:dir=out:strategy=12 --lua-desync=z2k_http_space_prefix:payload=http_req:dir=out:strategy=13 --lua-desync=z2k_http_tab_prefix:payload=http_req:dir=out:strategy=14 --lua-desync=z2k_http_multi_crlf:payload=http_req:dir=out:strategy=15 --lua-desync=z2k_http_mixed_prefix:payload=http_req:dir=out:strategy=16 --lua-desync=z2k_http_garbage_prefix:payload=http_req:dir=out:strategy=17 --lua-desync=z2k_http_hostmod:payload=http_req:dir=out:strategy=18 --lua-desync=z2k_http_method_obfuscate:payload=http_req:dir=out:strategy=19 --lua-desync=z2k_http_version_downgrade:payload=http_req:dir=out:strategy=20 --lua-desync=z2k_http_oob_prefix:payload=http_req:dir=out:strategy=21 --lua-desync=z2k_http_absolute_url:payload=http_req:dir=out:strategy=22 --lua-desync=z2k_http_absolute_uri_v2:payload=http_req:dir=out:strategy=23 --lua-desync=z2k_http_methodeol_v2:payload=http_req:dir=out:strategy=24 --lua-desync=z2k_http_methodeol_hostcase:payload=http_req:dir=out:strategy=25 --lua-desync=z2k_http_pipeline_fake:payload=http_req:dir=out:strategy=26 --lua-desync=z2k_http_pipeline_fake_v2:payload=http_req:dir=out:strategy=27 --lua-desync=z2k_http_fake_continuation:payload=http_req:dir=out:strategy=28 --lua-desync=z2k_http_fake_xhost:payload=http_req:dir=out:strategy=29 --lua-desync=z2k_http_header_shuffle:payload=http_req:dir=out:strategy=30 --lua-desync=z2k_http_host_bytesplit:payload=http_req:dir=out:strategy=31 --lua-desync=z2k_http_seqovl_host:payload=http_req:dir=out:strategy=32 --lua-desync=z2k_http_triple_seqovl:payload=http_req:dir=out:strategy=33 --lua-desync=z2k_http_mgts_combo:payload=http_req:dir=out:strategy=34 --lua-desync=z2k_http_combo_bypass:payload=http_req:dir=out:strategy=35 --lua-desync=z2k_http_super_decoy:payload=http_req:dir=out:strategy=36 --lua-desync=z2k_http_multidisorder:payload=http_req:dir=out:strategy=37 --lua-desync=z2k_http_ipfrag:payload=http_req:dir=out:strategy=38 --lua-desync=z2k_http_syndata:payload=http_req:dir=out:strategy=39 --lua-desync=z2k_http_aggressive:payload=http_req:dir=out:strategy=40 --in-range=x --new"


    local nfqws2_opt_value
    nfqws2_opt_value=$(printf "%b" "$nfqws2_opt_lines" | sed '/^$/d')
    # Each profile-line ends with --new (separator before the next profile).
    # The very last --new has no profile after it — nfqws2 parses it as an
    # empty trailing profile (no filter, no hostlist, no desync). Strip it.
    nfqws2_opt_value=$(printf '%s' "$nfqws2_opt_value" | sed '$ s/[[:space:]]*--new[[:space:]]*$//')
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
    local nfqws2_opt_section
    nfqws2_opt_section=$(generate_nfqws2_opt_from_strategies)

    # =========================================================================
    # ВАЛИДАЦИЯ NFQWS2 ОПЦИЙ (ВАЖНО)
    # =========================================================================
    print_info "Валидация сгенерированных опций nfqws2..."

    # Извлечь NFQWS2_OPT из сгенерированной секции (многострочный heredoc между кавычками)
    local nfqws2_opt_value
    nfqws2_opt_value=$(echo "$nfqws2_opt_section" | sed -n '/^NFQWS2_OPT="/,/^"$/{ /^NFQWS2_OPT="/d; /^"$/d; p; }')

    # Загрузить модули для dry_run_nfqws()
    if [ -f "/opt/zapret2/common/base.sh" ]; then
        . "/opt/zapret2/common/base.sh"
    fi

    if [ -f "/opt/zapret2/common/linux_daemons.sh" ]; then
        . "/opt/zapret2/common/linux_daemons.sh"

        # Установить временно NFQWS2_OPT для проверки
        export NFQWS2_OPT="$nfqws2_opt_value"
        export NFQWS2="/opt/zapret2/nfq2/nfqws2"

        # Проверить опции (dry_run может ложно падать если lua/blob файлы
        # ещё не установлены — это нормально при первой установке)
        if command -v dry_run_nfqws >/dev/null 2>&1; then
            if dry_run_nfqws 2>/dev/null; then
                print_success "Опции nfqws2 валидны (dry-run OK)"
            else
                print_info "dry-run nfqws2 не прошёл (нормально при установке — lua/blob файлы подключатся при запуске)"
            fi
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

    # Сохранить пользовательские настройки из существующего конфига
    local saved_DROP_DPI_RST="0"
    local saved_RST_FILTER="0"
    local saved_RKN_SILENT_FALLBACK="0"
    local saved_ROBLOX_UDP_BYPASS="0"
    local saved_GAME_MODE_ENABLED=""
    local saved_GAME_MODE_STYLE=""
    local saved_TG_PROXY_USER_DISABLED="0"
    local saved_Z2K_USE_MID_STREAM_DETECTOR="1"
    local saved_Z2K_PADENCAP="1"
    local saved_Z2K_INJECT_TLS_MODS="0"
    if [ -f "$config_file" ]; then
        saved_DROP_DPI_RST=$(safe_config_read "DROP_DPI_RST" "$config_file" "0")
        saved_RST_FILTER=$(safe_config_read "RST_FILTER" "$config_file" "0")
        saved_RKN_SILENT_FALLBACK=$(safe_config_read "RKN_SILENT_FALLBACK" "$config_file" "0")
        saved_ROBLOX_UDP_BYPASS=$(safe_config_read "ROBLOX_UDP_BYPASS" "$config_file" "0")
        saved_GAME_MODE_ENABLED=$(safe_config_read "GAME_MODE_ENABLED" "$config_file" "")
        saved_GAME_MODE_STYLE=$(safe_config_read "GAME_MODE_STYLE" "$config_file" "")
        saved_TG_PROXY_USER_DISABLED=$(safe_config_read "TG_PROXY_USER_DISABLED" "$config_file" "0")
        # Z2K_USE_MID_STREAM_DETECTOR / Z2K_PADENCAP — default ON (per Mark
        # 2026-05-02 policy: все нововведения по умолчанию включены). Если
        # старый config не содержит ключ, считаем "1" — фичу хочется
        # включить даже на routers где конфиг был сгенерирован до её
        # появления. Юзер может выставить =0 explicitly чтобы откатиться.
        saved_Z2K_USE_MID_STREAM_DETECTOR=$(safe_config_read "Z2K_USE_MID_STREAM_DETECTOR" "$config_file" "1")
        saved_Z2K_PADENCAP=$(safe_config_read "Z2K_PADENCAP" "$config_file" "1")
        saved_Z2K_INJECT_TLS_MODS=$(safe_config_read "Z2K_INJECT_TLS_MODS" "$config_file" "0")
    fi

    # NFQWS2_TCP_PKT_IN bundle: at flag=0 keep the master-compatible 10
    # (handshake-only visibility for lua failure_detector); at flag=1 bump
    # to 30 so lua can observe the [8K, 18K] CF stall window AND so
    # success_detector=z2k_http_success_positive_only's inseq=18000 gate
    # is reachable on long TLS flows. Below 30 the bundle is structurally
    # half-state — failure_detector wired but blind. Above 30 the marginal
    # gain (more byte coverage past 30KB) doesn't justify the per-flow
    # NFQUEUE pressure on embedded routers.
    local nfqws2_tcp_pkt_in="10"
    if [ "$saved_Z2K_USE_MID_STREAM_DETECTOR" = "1" ]; then
        nfqws2_tcp_pkt_in="30"
    fi
    # Backwards compat: if the new flag isn't set yet on this router,
    # inherit the legacy ROBLOX_UDP_BYPASS value so a single create_official_config
    # pass transparently migrates old configs to the new variable.
    [ -z "$saved_GAME_MODE_ENABLED" ] && saved_GAME_MODE_ENABLED="$saved_ROBLOX_UDP_BYPASS"
    # GAME_MODE_STYLE default = safe (= pre-hybrid behavior) when missing.
    case "$saved_GAME_MODE_STYLE" in
        safe|hybrid|aggressive) ;;
        *) saved_GAME_MODE_STYLE="safe" ;;
    esac

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

# TCP ports to process (will be filtered by --filter-tcp in NFQWS2_OPT).
# Base only: HTTP/HTTPS + Cloudflare alternates. game_mode hybrid/aggressive
# used to append 1024-65535 here to feed a catch-all TCP profile, but that
# profile also matched the router's OUTPUT replies to LAN clients and
# broke the web UI — removed 2026-04-24.
NFQWS2_PORTS_TCP="80,443,2053,2083,2087,2096,8443"

# UDP ports to process (will be filtered by --filter-udp in NFQWS2_OPT)
NFQWS2_PORTS_UDP="443,50000-50099,1400,3478-3481,5349,19294-19344${saved_GAME_MODE_ENABLED:+$([ "$saved_GAME_MODE_ENABLED" = "1" ] && echo ',1024-65535')}"

# Packet direction filters (connbytes)
# NOTE: These are packet counts, NOT ranges
# PKT_OUT=20 means "first 20 packets" (connbytes 1:20)
# Official zapret2 defaults: TCP_PKT_OUT=20, UDP_PKT_OUT=5
NFQWS2_TCP_PKT_OUT="20"
NFQWS2_TCP_PKT_IN="${nfqws2_tcp_pkt_in}"
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

# Compress large lists
GZIP_LISTS=1

# Number of parallel threads for domain resolves
MDIG_THREADS=30

# EAI_AGAIN retries
MDIG_EAGAIN=10
MDIG_EAGAIN_DELAY=500
CONFIG

    # Append settings that need variable expansion (heredoc with quotes doesn't expand)
    cat >> "$config_file" <<EOF

# Passive DPI RST filter: drop injected TCP RST with IP ID 0x0-0xF
DROP_DPI_RST=${saved_DROP_DPI_RST}

# z2k nfqws2 C-level RST filter. Default 0 matches master behavior.
# Enable only for ISPs where injected RSTs are confirmed and legitimate
# pre-payload RSTs are not being dropped.
# Values: 0, 1, aggressive, agg, aggro
RST_FILTER=${saved_RST_FILTER}

# Silent fallback for RKN
RKN_SILENT_FALLBACK=${saved_RKN_SILENT_FALLBACK}

# Game bypass (one toggle = two flags; legacy name kept for rollback safety)
GAME_MODE_ENABLED=${saved_GAME_MODE_ENABLED}
ROBLOX_UDP_BYPASS=${saved_ROBLOX_UDP_BYPASS}
# Game mode topology:
#   safe       — positive game_ips.txt ipset + circular rotator (default).
#   hybrid     — ipset profile first, plus UDP catchall on 1024-65535
#                (one fixed strategy). Picks up cloud-hosted games with
#                no usable SNI. May disturb Discord P2P / WebRTC /
#                BitTorrent on high UDP ports — first 4 packets per flow.
#                TCP is not touched by the catchall.
#   aggressive — UDP catchall only, no ipset. Same UDP risks as hybrid,
#                and listed games lose their dedicated rotator.
GAME_MODE_STYLE=${saved_GAME_MODE_STYLE}

# Telegram tunnel: user-disable flag from menu/webpanel "Stop tunnel".
# Preserved across reinstall так что step_finalize autostart не воскрешал
# daemon, который юзер явно остановил.
TG_PROXY_USER_DISABLED=${saved_TG_PROXY_USER_DISABLED}

# Mid-stream stall detector bundle (default 1 per Mark 2026-05-02
# policy: все нововведения по умолчанию включены). At 1: rkn_tcp swaps
# failure_detector to z2k_mid_stream_stall, --in-range to -s20000, AND
# NFQWS2_TCP_PKT_IN bumps to 30 — all three move atomically. =0 для
# отката. Persisted here so a user-set value survives
# create_official_config regen.
Z2K_USE_MID_STREAM_DETECTOR=${saved_Z2K_USE_MID_STREAM_DETECTOR}

# TLS extension auto-injection master switch (default 0, 2026-05-03):
# выключено по дефолту после field-проверки — auto-injection
# z2k_grease/alpn/psk/keyshare/earlydata/pha/sct/delegcred/padencap к
# fake-стратегиям ломала handshake на cloudflare и большинстве хостов
# до r2 fix, после r2 даёт слабую JA3-distortion которой autocircular
# не выбирает. =1 для opt-in возврата автоинъекции (вместе с
# Z2K_PADENCAP=1 для управления padencap).
Z2K_INJECT_TLS_MODS=${saved_Z2K_INJECT_TLS_MODS}

# TLS padding extension flag — действует только когда
# Z2K_INJECT_TLS_MODS=1. Управляет добавлением padencap в дополнение
# к z2k_grease/alpn/psk/keyshare/earlydata/pha/sct/delegcred. =0 для
# отката padencap при включённой остальной инъекции.
Z2K_PADENCAP=${saved_Z2K_PADENCAP}

# Persist the branch URL that this install was booted from, so that
# z2k-update-lists.sh and other post-install tools (cron-driven) can
# continue pulling from the SAME branch instead of defaulting back to
# master. Set automatically from \$GITHUB_RAW at install time; edit by
# hand only if you know what you are doing.
Z2K_GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}"
EOF

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
    local nfqws2_opt_section
    nfqws2_opt_section=$(generate_nfqws2_opt_from_strategies)

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
