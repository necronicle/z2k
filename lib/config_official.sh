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
    local Z2K_REFACTOR_PHASE1 Z2K_REFACTOR_PHASE2 Z2K_REFACTOR_PHASE3 Z2K_REFACTOR_PHASE4
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
    Z2K_REFACTOR_PHASE4=$(safe_config_read "Z2K_REFACTOR_PHASE4" "/opt/zapret2/config" "1")

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
    inject_z2k_tls_mods() {
        local input="$1"
        local token=""
        local out=""
        for token in $input; do
            case "$token" in
                *:tls_mod=*)
                    case "$token" in
                        *z2k_grease*|*z2k_alpn*|*z2k_psk*|*z2k_keyshare*)
                            : # already extended, leave as-is
                            ;;
                        *)
                            # Append z2k modes to the tls_mod list.
                            # tls_mod= is comma-separated; we insert
                            # right after the existing value by rewriting
                            # the first `:tls_mod=VALUE` chunk so the
                            # new modes sit adjacent to upstream modes.
                            # Sed is enough because the value cannot
                            # contain a ':' (would terminate the token).
                            token=$(printf '%s' "$token" | sed 's|:tls_mod=\([^:]*\)|:tls_mod=\1,z2k_grease,z2k_alpn,z2k_psk,z2k_keyshare|')
                            ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done
        printf '%s' "$out"
    }

    rkn_tcp=$(inject_z2k_tls_mods "$rkn_tcp")
    youtube_tcp=$(inject_z2k_tls_mods "$youtube_tcp")
    youtube_gv_tcp=$(inject_z2k_tls_mods "$youtube_gv_tcp")

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
    # rebase. Adding handler support for google_tls / cdn_tls comes in
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
                while (match($0, /:strategy=[0-9]+/)) {
                    result = result substr($0, 1, RSTART - 1)
                    sid = substr($0, RSTART + 10, RLENGTH - 10) + off
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
    # Idempotent: tokens that already have a hyphen inside repeats=
    # (user wrote the range manually, or we ran a previous pass) are
    # left alone. Non-fake action families are untouched — only
    # tokens starting with one of the whitelisted prefixes.
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
                        *:repeats=*-*) : ;; # already a range
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

    # NOTE: the z2k_mid_stream_stall detector replaces z2k_tls_stalled
    # as the rkn_tcp default failure detector — that switch lives in
    # ensure_rkn_failure_detector() below, not here, because the
    # detector arg is added to the circular token AFTER our injectors
    # run.

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

    # RKN: всегда добавляем failure_detector=z2k_mid_stream_stall.
    # Это superset z2k_tls_stalled, который в свою очередь superset
    # z2k_tls_alert_fatal — наследует все его сигналы (retrans,
    # incoming RST, HTTP DPI redirect, TLS fatal alert) плюс
    # timeout-based детект «ClientHello ушёл, ServerHello не пришёл»
    # плюс класс post-handshake mid-stream stall. Последний класс —
    # это ровно то что ловит Ростелекомовский Cloudflare-кейс, где
    # handshake проходит, сервер отдаёт ~10-14 KB, затем поток тихо
    # виснет и стандартные детекторы его не видят.
    #
    # Note: z2k_mid_stream_stall v2 (2026-04-18) добавляет active-retry
    # gating — срабатывает только когда пользователь настойчиво
    # пробует один и тот же хост (второй CH в пределах 60 с от
    # предыдущего). Без этого gating у нас был false-positive на
    # нормальной навигации «почитал страницу 40с, кликнул дальше»,
    # который тихо ротировал circular с рабочей стратегии. См.
    # files/lua/z2k-detectors.lua для деталей heuristic.
    ensure_rkn_failure_detector() {
        local input="$1"
        local out=""
        local token=""

        for token in $input; do
            case "$token" in
                --lua-desync=circular:*)
                    case "$token" in
                        *failure_detector=*) ;;
                        *) token="${token}:failure_detector=z2k_mid_stream_stall" ;;
                    esac
                    ;;
            esac
            out="${out:+$out }$token"
        done

        printf '%s' "$out"
    }

    rkn_tcp=$(ensure_rkn_failure_detector "$rkn_tcp")

    # Silent fallback для RKN — включается через меню (флаг-файл).
    # failure_detection включает в себя manual_layout (--in-range + payload),
    # поэтому они взаимоисключающие, не накладываются.
    local rkn_silent_conf="${ZAPRET2_DIR:-/opt/zapret2}/config"
    local RKN_SILENT_FALLBACK
    RKN_SILENT_FALLBACK=$(safe_config_read "RKN_SILENT_FALLBACK" "$rkn_silent_conf" "0")
    local rkn_silent_flag="${extra_strats_dir}/cache/autocircular/rkn_silent_fallback.flag"
    if [ "$RKN_SILENT_FALLBACK" = "1" ]; then
        rkn_tcp=$(ensure_youtube_tls_failure_detection "$rkn_tcp")
        touch "$rkn_silent_flag" 2>/dev/null
    else
        rkn_tcp=$(ensure_youtube_tls_circular_manual_layout "$rkn_tcp")
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

    # RKN TCP (include Discord hostlist into RKN profile)
    local rkn_hostlists="--hostlist=${extra_strats_dir}/TCP/RKN/List.txt"
    [ -s "${extra_strats_dir}/TCP_Discord.txt" ] && rkn_hostlists="$rkn_hostlists --hostlist=${extra_strats_dir}/TCP_Discord.txt"
    # Shipped extras curated on top of runetfreedom RKN — domains users
    # reported missing (fast-torrent.ru etc). Refreshed on every install.
    [ -s "${lists_dir}/extra-domains.txt" ] && rkn_hostlists="$rkn_hostlists --hostlist=${lists_dir}/extra-domains.txt"
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "--hostlist-exclude=${lists_dir}/whitelist.txt $rkn_hostlists $rkn_tcp --new"

    # Phase 4: cdn_tls — targets TSPU 16KB whitelist-SNI block on CF/OVH/
    # Hetzner/DO (ntc.party 17013). ipset=cdn_ips.txt seeded by
    # z2k-update-lists.sh (CF+OVH+Hetzner+DO ~1662 CIDR ≈ 80 KB RAM).
    # 5 curated strategies tuned for the TSPU whitelist-SNI bypass shape,
    # explicit tcp_ack=-66000 on fake (badseq primitive, ntc.party 17013).
    # Positioned AFTER rkn_tcp so RKN-listed sites on CF still go through
    # the proven 47-strategy RKN rotator, and only non-RKN CDN traffic
    # hits cdn_tls. Profile skipped if ipset file missing/empty.
    if [ "$Z2K_REFACTOR_PHASE4" = "1" ] && [ -s "${lists_dir}/cdn_ips.txt" ]; then
        # 2026-04 expansion: strategies 6-7 exercise rndsni / padencap
        # tls_mod primitives (confirmed in protocol.c:751-960). rndsni
        # replaces SNI with random string per-connection — useful when
        # TSPU enforces per-AS whitelist and our hardcoded whitelist SNI
        # doesn't match that AS's set. padencap inflates reasm_data via
        # TLS padding extension, breaking size-hash DPI classifiers.
        # strategy=8 — per-CDN-provider SNI dispatch via
        # z2k-cdn-dispatch.lua (ntc.party 17013 #851: per-AS whitelist
        # enforcement). luaexec sets desync.cdn_sni from dst-IP prefix
        # match (CF→www.google.com, OVH→4pda.to, Hetzner→max.ru,
        # DO→vk.com, fallback→www.google.com). fake then rewrites the
        # ClientHello SNI via tls_mod=sni=%cdn_sni substitution (handled
        # by tls_mod_shim in zapret-lib.lua:633). Same circular slot =
        # one dynamically-picked SNI per connection.
        local cdn_tls_strats="--lua-desync=circular:fails=2:time=60:key=cdn_tls:nld=2 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1,sniext+1:seqovl=1:strategy=1 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=2:tls_mod=rnd,dupsid,sni=www.google.com:tcp_seq=-10000:tcp_ack=-66000:strategy=2 --lua-desync=hostfakesplit:payload=tls_client_hello:dir=out:host=mail.ru:seqovl=1:badsum:strategy=3 --lua-desync=multidisorder:payload=tls_client_hello:dir=out:pos=method+2,midsld,5:strategy=4 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:repeats=6:ip_autottl=-2,3-20:strategy=5 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=2:tls_mod=rnd,dupsid,padencap,sni=www.google.com:tcp_ack=-66000:strategy=6 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=2:tls_mod=rndsni,dupsid:tcp_ack=-66000:strategy=7 --lua-desync=luaexec:code=pick_cdn_sni(desync):strategy=8 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=tls_clienthello_www_google_com:repeats=2:tls_mod=rnd,dupsid,sni=%cdn_sni:tcp_ack=-66000:strategy=8"
        nfqws2_opt_lines="$nfqws2_opt_lines--filter-tcp=443,2053,2083,2087,2096,8443 --filter-l7=tls --ipset=${lists_dir}/cdn_ips.txt --hostlist-exclude=${lists_dir}/whitelist.txt --payload=tls_client_hello $cdn_tls_strats --new\\n"
    fi

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
    # ROBLOX_UDP_BYPASS (old) — evaluated above.
    #
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
    if [ "$Z2K_REFACTOR_PHASE2" != "1" ] && [ "$GAME_MODE_ENABLED" = "1" ] && [ "$GAME_MODE_STYLE" != "safe" ]; then
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
    add_hostlist_line "${extra_strats_dir}/TCP/RKN/List.txt" "--filter-tcp=80 --hostlist-exclude=${lists_dir}/whitelist.txt --hostlist=${extra_strats_dir}/TCP/RKN/List.txt${rkn_http_extras} --in-range=-s5556 --payload=http_req,empty --lua-desync=circular:fails=2:time=60:reset:key=http_rkn:nld=2:failure_detector=z2k_tls_alert_fatal --lua-desync=http_methodeol:payload=http_req:dir=out:strategy=1 --lua-desync=syndata:payload=http_req:dir=out:strategy=2 --lua-desync=multisplit:payload=http_req:dir=out:strategy=2 --lua-desync=hostfakesplit:payload=http_req:dir=out:ip_ttl=2:repeats=1:strategy=3 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=4 --lua-desync=fakedsplit:payload=http_req:dir=out:pos=method+2:badsum:strategy=5 --lua-desync=fake:payload=http_req:dir=out:blob=0x0E0E0F0E:tcp_md5:strategy=6 --lua-desync=multisplit:payload=http_req:dir=out:pos=host+1:seqovl=2:strategy=6 --lua-desync=fake:payload=http_req:dir=out:blob=fake_default_http:badsum:repeats=1:strategy=7 --lua-desync=multisplit:payload=http_req:dir=out:pos=method+2:strategy=7 --in-range=x --new"


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
    local saved_RKN_SILENT_FALLBACK="0"
    local saved_ROBLOX_UDP_BYPASS="0"
    local saved_GAME_MODE_ENABLED=""
    local saved_GAME_MODE_STYLE=""
    if [ -f "$config_file" ]; then
        saved_DROP_DPI_RST=$(safe_config_read "DROP_DPI_RST" "$config_file" "0")
        saved_RKN_SILENT_FALLBACK=$(safe_config_read "RKN_SILENT_FALLBACK" "$config_file" "0")
        saved_ROBLOX_UDP_BYPASS=$(safe_config_read "ROBLOX_UDP_BYPASS" "$config_file" "0")
        saved_GAME_MODE_ENABLED=$(safe_config_read "GAME_MODE_ENABLED" "$config_file" "")
        saved_GAME_MODE_STYLE=$(safe_config_read "GAME_MODE_STYLE" "$config_file" "")
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
