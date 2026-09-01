#!/bin/sh
# lib/config.sh - Управление конфигурацией и списками доменов
# Скачивание, обновление и управление списками для zapret2

# ==============================================================================
# УПРАВЛЕНИЕ СПИСКАМИ ДОМЕНОВ
# ==============================================================================

# Пометить только что уложенный шипнутый список как ФОЛЛБЕК.
#
# z2k-geosite.sh перед заменой списка проверяет, не усох ли новый более чем на
# 20%, и класс сравниваемого хранит в файле-маркере `<цель>.asset` рядом с целью.
# Маркер он пишет ТОЛЬКО после успешного применения, а при его отсутствии
# включает сторож (условие `[ -z "$prev_asset" ]` стоит в enforce-ветке, не в
# пропускающей). Установка клала бандл без маркера — и дальше:
#
#   апстримный ru-blocked.txt (74739 строк) против бандла (125451) = 59% < 80%
#   -> «список НЕ трогаем», return 1, маркер не пишется, состояние не меняется
#
# То есть замок захлопывался навсегда: свежий список не вставал НИ РАЗУ ни на
# одном роутере с памятью меньше 900 МБ (там выбирается малый ru-blocked.txt), и
# весь парк сидел на снимке из бандла. Снаружи это выглядело как безобидная
# строка «[geosite] fetch summary: 4 ok, 1 failed» — единственный след.
#
# Сравнение бандла с апстримом некорректно по своей природе: это разные
# источники, а не усадка одного и того же. Помечаем происхождение явно, и
# geosite видит смену источника, пропускает сторож один раз и кладёт апстрим.
# После этого маркер становится апстримным, и сторож работает как задуман —
# защищая от настоящей усадки внутри одного источника.
z2k_mark_shipped_fallback() {
    [ -s "$1" ] || return 0
    printf '%s\n' "shipped-fallback" > "${1}.asset" 2>/dev/null || true
    return 0
}

# Скачать списки доменов из zapret4rocket
download_domain_lists() {
    print_header "Загрузка списков доменов"
    print_info "Источник: локальные snapshot-списки из ${ZAPRET2_DIR}/files/lists"

    # Создать структуру директорий
    local yt_tcp_dir="${ZAPRET2_DIR}/extra_strats/TCP/YT"
    local yt_gv_tcp_dir="${ZAPRET2_DIR}/extra_strats/TCP/YT_GV"
    local rkn_tcp_dir="${ZAPRET2_DIR}/extra_strats/TCP/RKN"
    local yt_udp_dir="${ZAPRET2_DIR}/extra_strats/UDP/YT"
    local snapshot_dir="${ZAPRET2_DIR}/files/lists"

    mkdir -p "$yt_tcp_dir" "$yt_gv_tcp_dir" "$rkn_tcp_dir" "$yt_udp_dir" "$LISTS_DIR" || {
        print_error "Не удалось создать директории"
        return 1
    }

    # 1. YouTube TCP - скопировать из локального snapshot
    print_info "Загрузка YouTube TCP list (local snapshot)..."
    if [ -s "${snapshot_dir}/extra_strats/TCP/YT/List.txt" ]; then
        cp -f "${snapshot_dir}/extra_strats/TCP/YT/List.txt" "${yt_tcp_dir}/List.txt"
        z2k_mark_shipped_fallback "${yt_tcp_dir}/List.txt"
        local count
        count=$(wc -l < "${yt_tcp_dir}/List.txt" 2>/dev/null || echo "0")
        print_success "YouTube TCP: $count доменов"
    else
        print_error "Отсутствует snapshot: ${snapshot_dir}/extra_strats/TCP/YT/List.txt"
    fi

    # 2. YouTube GV - dedicated hostlist (apex googlevideo.com покрывает все
    # поддомены: rr1-rr9, manifest, *.googlevideo.com). Раньше был жёстко
    # прибит inline через --hostlist-domains в config_official.sh — теперь
    # выделен в файл для расширяемости и чистого разделения с yt_tcp.
    print_info "Загрузка YouTube GV list (local snapshot)..."
    if [ -s "${snapshot_dir}/extra_strats/TCP/YT_GV/List.txt" ]; then
        cp -f "${snapshot_dir}/extra_strats/TCP/YT_GV/List.txt" "${yt_gv_tcp_dir}/List.txt"
        local count
        count=$(wc -l < "${yt_gv_tcp_dir}/List.txt" 2>/dev/null || echo "0")
        print_success "YouTube GV: $count доменов"
    else
        print_error "Отсутствует snapshot: ${snapshot_dir}/extra_strats/TCP/YT_GV/List.txt"
    fi

    # 3. RKN - скопировать из локального snapshot
    print_info "Загрузка RKN list (local snapshot)..."
    if [ -s "${snapshot_dir}/extra_strats/TCP/RKN/List.txt" ]; then
        cp -f "${snapshot_dir}/extra_strats/TCP/RKN/List.txt" "${rkn_tcp_dir}/List.txt"
        z2k_mark_shipped_fallback "${rkn_tcp_dir}/List.txt"
        local count
        count=$(wc -l < "${rkn_tcp_dir}/List.txt" 2>/dev/null || echo "0")
        print_success "RKN: $count доменов"
    else
        print_error "Отсутствует snapshot: ${snapshot_dir}/extra_strats/TCP/RKN/List.txt"
    fi

    # 4. QUIC YouTube - скопировать из локального snapshot
    print_info "Загрузка QUIC YouTube list (local snapshot)..."
    if [ -s "${snapshot_dir}/extra_strats/UDP/YT/List.txt" ]; then
        cp -f "${snapshot_dir}/extra_strats/UDP/YT/List.txt" "${yt_udp_dir}/List.txt"
        z2k_mark_shipped_fallback "${yt_udp_dir}/List.txt"
        local count
        count=$(wc -l < "${yt_udp_dir}/List.txt" 2>/dev/null || echo "0")
        print_success "QUIC YouTube: $count доменов"
    else
        print_warning "Отсутствует snapshot: ${snapshot_dir}/extra_strats/UDP/YT/List.txt"
    fi

    # 6.1. Discord TCP hostlist (for --hostlist-exclude in RKN profile)
    print_info "Загрузка Discord TCP hostlist (local snapshot)..."
    local discord_tcp_dir="${ZAPRET2_DIR}/extra_strats"
    mkdir -p "$discord_tcp_dir"
    if [ -s "${snapshot_dir}/extra_strats/TCP/RKN/Discord.txt" ]; then
        cp -f "${snapshot_dir}/extra_strats/TCP/RKN/Discord.txt" "${discord_tcp_dir}/TCP_Discord.txt"
        z2k_mark_shipped_fallback "${discord_tcp_dir}/TCP_Discord.txt"
        local count
        count=$(wc -l < "${discord_tcp_dir}/TCP_Discord.txt" 2>/dev/null || echo "0")
        print_success "Discord TCP hostlist: $count доменов"
    else
        # Fallback: create from main discord list
        if [ -s "${LISTS_DIR}/discord.txt" ]; then
            cp "${LISTS_DIR}/discord.txt" "${discord_tcp_dir}/TCP_Discord.txt"
            print_warning "Использован fallback: discord.txt -> TCP_Discord.txt"
        else
            print_warning "Не удалось загрузить Discord TCP hostlist"
        fi
    fi

    # 7. Custom - создать пустой файл для пользовательских доменов
    if [ ! -f "${LISTS_DIR}/custom.txt" ]; then
        touch "${LISTS_DIR}/custom.txt"
        print_info "Создан custom.txt для пользовательских доменов"
    fi
    # Seed Instagram domains into custom.txt (QUIC/HTTP3 apps often need UDP/443 bypass).
    # Hostlists match subdomains automatically; wildcards (*) are not supported.
    local custom_list="${LISTS_DIR}/custom.txt"
    for domain in \
        instagram.com \
        cdninstagram.com \
        graph.instagram.com \
        api.instagram.com \
        i.instagram.com \
        static.cdninstagram.com \
        ig.me \
        igcdn.com \
        instagram-engineering.com \
        instagram-press.com \
        instagramstatic-a.akamaihd.net \
        instagr.am \
    ; do
        grep -qxF "$domain" "$custom_list" 2>/dev/null || echo "$domain" >> "$custom_list"
    done

    print_separator
    print_success "Списки доменов загружены"

    return 0
}

# Обновить списки доменов
update_domain_lists() {
    print_header "Обновление списков доменов"

    # Fetch FRESH lists from runetfreedom geosite — the SAME network source the
    # installer uses (lib/install.sh step_download_domain_lists) and the nightly
    # scheduler (z2k-update-lists.sh). The previous code here called
    # download_domain_lists, which only COPIED the stale bundled snapshot
    # (files/lists/...) over the live network lists — reverting them to the
    # shipped fallback on every run (RKN 74751→125451, UDP/YT 178→12 — the same
    # delta regardless of anything). That is a downgrade, not an update, and was
    # the cause of the "странное изменение кол-ва доменов" on menu item 3.
    # geosite writes RKN/YT/UDP atomically and keeps the previous list if a
    # fetch fails — no snapshot downgrade.
    local geosite="${ZAPRET2_DIR}/z2k-geosite.sh"
    if [ -x "$geosite" ]; then
        print_info "Загрузка свежих списков (runetfreedom geosite)..."
        # КОД ВОЗВРАТА БЕРЁМ У geosite, А НЕ У sed.
        #
        # `cmd | sed ... || warn` проверяет статус ПОСЛЕДНЕГО звена конвейера,
        # то есть sed, который успешен всегда. Предупреждение «часть списков не
        # обновилась» не показывалось никогда, даже когда не обновилось ничего:
        # человек видел пустой отступленный вывод и считал, что списки свежие.
        # pipefail здесь недоступен — POSIX sh на роутере его не знает, поэтому
        # статус переносим через файл, сохраняя потоковый вывод (fetch долгий, и
        # ждать его молча неприятно).
        _gs_st="${TMPDIR:-/tmp}/z2k_geosite_rc.$$"
        { FORCE_REFETCH=1 sh "$geosite" fetch --force 2>&1; echo $? > "$_gs_st"; } | sed 's/^/  /'
        _gs_rc=$(cat "$_gs_st" 2>/dev/null)
        rm -f "$_gs_st"
        [ "${_gs_rc:-1}" = "0" ] || \
            print_warning "Часть списков не обновилась — прежние оставлены без изменений"
    else
        print_warning "z2k-geosite.sh не найден — копирую bundled-снапшот (fallback)"
        download_domain_lists
    fi

    # Показать статистику
    print_separator
    show_domain_lists_stats

    # Спросить о перезапуске сервиса
    if is_zapret2_running; then
        printf "\nПерезапустить сервис для применения изменений? [Y/n]: "
        read -r answer </dev/tty

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Сервис не перезапущен"
                print_info "Перезапустите вручную: /opt/etc/init.d/S99zapret2 restart"
                ;;
            *)
                print_info "Перезапуск сервиса..."
                "$INIT_SCRIPT" restart
                sleep 2
                if is_zapret2_running; then
                    print_success "Сервис перезапущен"
                else
                    print_error "Не удалось перезапустить сервис"
                fi
                ;;
        esac
    fi

    return 0
}

# Показать статистику по спискам доменов
show_domain_lists_stats() {
    print_header "Статистика списков доменов"

    printf "%-30s | %-10s\n" "Список" "Доменов"
    print_separator

    # YouTube TCP
    local yt_tcp_list="${ZAPRET2_DIR}/extra_strats/TCP/YT/List.txt"
    if [ -f "$yt_tcp_list" ]; then
        local count
        count=$(wc -l < "$yt_tcp_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "YouTube TCP" "$count"
    fi

    # YouTube GV
    printf "%-30s | %-10s\n" "YouTube GV" "--hostlist-domains"

    # RKN
    local rkn_list="${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt"
    if [ -f "$rkn_list" ]; then
        local count
        count=$(wc -l < "$rkn_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "RKN" "$count"
    fi

    # QUIC YouTube
    local quic_yt_list="${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt"
    if [ -f "$quic_yt_list" ]; then
        local count
        count=$(wc -l < "$quic_yt_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "QUIC YouTube" "$count"
    fi

    # Custom
    local custom_list="${LISTS_DIR}/custom.txt"
    if [ -f "$custom_list" ]; then
        local count
        count=$(wc -l < "$custom_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s\n" "Custom" "$count"
    fi

    print_separator
}

# Показать какие списки обрабатываются и режим работы
show_active_processing() {
    print_header "Активная обработка трафика"

    # Показать режим работы
    print_info "Режим обработки трафика:"
    printf "\n"
    print_success "[OK] Режим по спискам доменов (нормальный)"
    printf "\n"

    # Показать активные списки
    print_info "Обрабатываемые списки доменов:"
    print_separator
    printf "%-30s | %-10s | %s\n" "Категория" "Доменов" "Статус"
    print_separator

    # RKN TCP
    local rkn_list="${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt"
    if [ -f "$rkn_list" ]; then
        local count
        count=$(wc -l < "$rkn_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "RKN (заблокированные)" "$count" "Активен"
    fi

    # YouTube TCP
    local yt_tcp_list="${ZAPRET2_DIR}/extra_strats/TCP/YT/List.txt"
    if [ -f "$yt_tcp_list" ]; then
        local count
        count=$(wc -l < "$yt_tcp_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "YouTube TCP" "$count" "Активен"
    fi

    # YouTube GV
    printf "%-30s | %-10s | %s\n" "YouTube GV (CDN)" "googlevideo.com" "Активен"

    # QUIC YouTube
    local quic_yt_list="${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt"
    if [ -f "$quic_yt_list" ]; then
        local count
        count=$(wc -l < "$quic_yt_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "QUIC YouTube (UDP 443)" "$count" "Активен"
    fi

    # Discord
    local discord_list="${LISTS_DIR}/discord.txt"
    if [ -f "$discord_list" ]; then
        local count
        count=$(wc -l < "$discord_list" 2>/dev/null || echo "0")
        printf "%-30s | %-10s | %s\n" "Discord (TCP+UDP)" "$count" "Активен"
    fi

    # Custom
    local custom_list="${LISTS_DIR}/custom.txt"
    if [ -f "$custom_list" ]; then
        local count
        count=$(wc -l < "$custom_list" 2>/dev/null || echo "0")
        local status="Пустой"
        if [ "$count" -gt 0 ]; then
            status="Активен"
        fi
        printf "%-30s | %-10s | %s\n" "Custom (пользовательские)" "$count" "$status"
    fi

    print_separator

    # Показать исключения
    print_info "Исключения (whitelist):"
    local whitelist="${LISTS_DIR}/whitelist.txt"
    if [ -f "$whitelist" ]; then
        local count
        count=$(grep -v "^#" "$whitelist" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
        printf "  %s доменов исключено из обработки\n" "$count"
        printf "  Файл: %s\n" "$whitelist"
    else
        printf "  Whitelist не найден\n"
    fi

    print_separator

    # Итого
    print_success "Режим работы: только списки доменов"
}

# ==============================================================================
# УПРАВЛЕНИЕ КОНФИГУРАЦИЕЙ
# ==============================================================================

# Создать базовую конфигурацию zapret2
create_base_config() {
    print_info "Создание базовой конфигурации..."

    mkdir -p "$CONFIG_DIR" || {
        print_error "Не удалось создать $CONFIG_DIR"
        return 1
    }

    # Копировать strategies.conf из рабочей директории
    if [ -f "${WORK_DIR}/strategies.conf" ]; then
        cp "${WORK_DIR}/strategies.conf" "$STRATEGIES_CONF" || {
            print_error "Не удалось скопировать strategies.conf"
            return 1
        }
        print_success "Создан файл стратегий: $STRATEGIES_CONF"
    fi

    # Копировать quic_strategies.conf из рабочей директории
    if [ -f "${WORK_DIR}/quic_strategies.conf" ]; then
        cp "${WORK_DIR}/quic_strategies.conf" "$QUIC_STRATEGIES_CONF" || {
            print_error "Не удалось скопировать quic_strategies.conf"
            return 1
        }
        print_success "Создан файл QUIC стратегий: $QUIC_STRATEGIES_CONF"
    fi

    # Создать файл для текущей стратегии
    touch "$CURRENT_STRATEGY_FILE"

    # Создать файл для текущей QUIC стратегии
    if [ ! -f "$QUIC_STRATEGY_FILE" ]; then
        echo "QUIC_STRATEGY=24" > "$QUIC_STRATEGY_FILE"
    fi

    # Создать файл для QUIC стратегии RuTracker
    if [ ! -f "$RUTRACKER_QUIC_STRATEGY_FILE" ]; then
        echo "RUTRACKER_QUIC_STRATEGY=43" > "$RUTRACKER_QUIC_STRATEGY_FILE"
    fi

    # Создать конфиг для включения/выключения QUIC RuTracker (по умолчанию выключено)
    local rutracker_quic_enabled_conf="${CONFIG_DIR}/rutracker_quic_enabled.conf"
    if [ ! -f "$rutracker_quic_enabled_conf" ]; then
        echo "RUTRACKER_QUIC_ENABLED=0" > "$rutracker_quic_enabled_conf"
        print_success "RuTracker QUIC по умолчанию выключен"
    fi

    # Удалить старый файл QUIC стратегий по категориям (больше не используется)
    local quic_category_conf="${CONFIG_DIR}/quic_category_strategies.conf"
    if [ -f "$quic_category_conf" ]; then
        rm -f "$quic_category_conf"
    fi

    # Создать директорию для списков если не существует
    if ! mkdir -p "$LISTS_DIR" 2>/dev/null; then
        print_error "Не удалось создать директорию: $LISTS_DIR"
        print_info "Проверьте права доступа"
        return 1
    fi

    # Проверить что директория действительно существует
    if [ ! -d "$LISTS_DIR" ]; then
        print_error "Директория не существует: $LISTS_DIR"
        return 1
    fi

    # Создать whitelist для исключения критичных сервисов
    local whitelist="${LISTS_DIR}/whitelist.txt"
    if [ ! -f "$whitelist" ]; then
        cat > "$whitelist" <<'EOF'
# Whitelist - домены исключенные из обработки zapret2
# Сервисы, которые могут работать некорректно с DPI bypass

# === Госуслуги РФ ===
gosuslugi.ru
esia.gosuslugi.ru
lk.gosuslugi.ru
nalog.ru
nalog.gov.ru
lkfl2.nalog.ru
pfr.gov.ru
es.pfr.gov.ru
mos.ru
mos-gorsud.ru
gov.ru
sudrf.ru

# === Российские сервисы ===
vk.com
vk.me
vkcdn.net
userapi.com
vk.ru
vkvideo.ru
ok.ru
mycdn.me
rutube.ru
yandex.ru
ya.ru
yandex.net
yandex.cloud
kinopoisk.ru
okko.tv
avito.ru
beeline.ru
beeline.tv
ottai.com
ipstream.one
vkusvill.ru
ozon.ru
ozone.ru
ozonusercontent.com
wildberries.ru
wb.ru
wbbasket.ru

# === Российские банки ===
sber.ru
sberbank.ru
vtb.ru
alfabank.ru
tbank.ru
gazprombank.ru
gpb.ru
psbank.ru
rosbank.ru
rshb.ru

# === Steam ===
s.team
steam.tv
steamcdn.com
steamchat.com
steam-chat.com
steamgames.com
steamserver.net
steamstatic.com
steampowered.com
steamcontent.com
steamcommunity.com
steambroadcast.com
steamdeckcdn.com
steamdeckusercontent.com
steamuserimages-a.akamaihd.net
steamcdn-a.akamaihd.net
steampipe.akamaized.net
steamcdn-a.akamaized.net
steamstatic.akamaized.net
steamcommunity.akamaized.net
steamcommunity-a.akamaihd.net
steamcloudsweden.blob.core.windows.net
valve.net
valvecdn.com
valvecontent.com
valvesoftware.com

# === Epic Games ===
epicgames.com
epicgames.dev
epicgamescdn.com
unrealengine.com
easyanticheat.net
eac-cdn.com
fortnite.com
fab.com
artstation.com

# === Ubisoft ===
ubi.com
ubisoft.com
ubisoftconnect.com

# === PlayStation / Sony ===
playstation.net
playstation.com
account.sony.com
psremoteplay.com
playstationcloud.com
sonyentertainmentnetwork.com

# === Nintendo (Switch: обновления, eShop-коннект, проверка сети) ===
# В списке РКН, но десинк ломает соединение — исключаем как остальные консоли.
nintendo.net
nintendowifi.net
nintendo.com
nintendo.co.jp

# === Twitch ===
twitch.tv
ttvnw.net
jtvnw.net
twitchcdn.net
ext-twitch.tv
twitchsvc.net
live-video.net
twitch-shadow.net

# === Riot Games / Valorant ===
riotgames.com
riotcdn.net
leagueoflegends.com
valorant.com
playvalorant.com
pvp.net
vivox.com
sd-rtn.com

# === HoYoverse (Genshin, HSR) ===
hoyoverse.com
hoyolab.com
hoyo.link
yuanshen.com
genshinimpact.com
zenlesszonezero.com

# === AliExpress ===
aliexpress.com
aliexpress.ru
aliexpress.us
alicdn.com
ae.com

# === TikTok ===
tiktok.com
tiktokcdn.com
tiktokv.com
muscdn.com
byteoversea.com
ibytedtos.com
ttwstatic.com

# === Samsung ===
samsungosp.com
samsungqbe.com
samsungcloudsolution.com

# === Стриминг ===
netflix.com
vsetop.org

# === Google API (не ломать поиск) ===
ogs.google.com
gstatic.com

# === Мониторинг и CDN ===
datadoghq.com
okcdn.ru
api.mycdn.me

# === Keenetic (KeenDNS, облако, обновления) ===
keenetic.pro
keenetic.com
keenetic.io
keenetic.cloud
keenetic.link
keenetic.net

# === Netcraze (KeenDNS под российским брендом, та же инфраструктура) ===
netcraze.pro
netcraze.com
netcraze.io
netcraze.cloud
netcraze.link

# === Разработка ===
raw.githubusercontent.com
marketplace.visualstudio.com

# === Oracle Cloud Infrastructure ===
customer-oci.com
EOF

        # Проверить что файл действительно создался
        if [ ! -f "$whitelist" ]; then
            print_error "Не удалось создать whitelist: $whitelist"
            print_info "Проверьте права доступа к директории"
            return 1
        fi

        print_success "Создан whitelist: $whitelist"
    else
        # Дозаписать keenetic домены если их нет (для существующих установок)
        if ! grep -q "keenetic.pro" "$whitelist" 2>/dev/null; then
            cat >> "$whitelist" <<'KEENETIC'

# === Keenetic (KeenDNS, облако, обновления) ===
keenetic.pro
keenetic.com
keenetic.io
keenetic.cloud
keenetic.link
KEENETIC
            print_info "Добавлены домены Keenetic в whitelist"
        fi

        # keenetic.net — отдельным сторожем, а не внутри блока выше.
        #
        # Пять доменов Keenetic лежали в белом списке с самого начала, а самый
        # ходовой — НЕТ: `my.keenetic.net` это адрес, по которому человек
        # заходит в морду своего роутера. Сторож блока выше проверяет
        # `keenetic.pro`, поэтому у всех, кто уже установлен, дозапись не
        # срабатывала бы вовсе: домены как бы есть.
        #
        # Запись без точки впереди покрывает и поддомены — так работает
        # hostlist движка, — то есть `my.keenetic.net` закрывается одной строкой.
        if ! grep -q "^keenetic\.net$" "$whitelist" 2>/dev/null; then
            printf 'keenetic.net\n' >> "$whitelist"
            print_info "Добавлен keenetic.net в whitelist (адрес морды роутера)"
        fi

        # Дозаписать netcraze (новый бренд KeenDNS в РФ, та же инфраструктура)
        if ! grep -q "^netcraze\.pro$" "$whitelist" 2>/dev/null; then
            cat >> "$whitelist" <<'NETCRAZE'

# === Netcraze (KeenDNS под российским брендом, та же инфраструктура) ===
netcraze.pro
netcraze.com
netcraze.io
netcraze.cloud
netcraze.link
NETCRAZE
            print_info "Добавлены домены Netcraze в whitelist"
        fi

        # Дозаписать Nintendo (в списке РКН, но десинк ломает соединение Switch —
        # обновления/eShop/проверку сети; исключаем как Steam/PS/Epic).
        if ! grep -q "^nintendo\.net$" "$whitelist" 2>/dev/null; then
            cat >> "$whitelist" <<'NINTENDO'

# === Nintendo (Switch: обновления, eShop-коннект, проверка сети) ===
nintendo.net
nintendowifi.net
nintendo.com
nintendo.co.jp
NINTENDO
            print_info "Добавлены домены Nintendo в whitelist"
        fi

        # Дозаписать банки и расширения для российских сервисов (flowseal 1.9.8 sync)
        if ! grep -q "^sber.ru$" "$whitelist" 2>/dev/null; then
            cat >> "$whitelist" <<'BANKS'

# === Российские банки ===
sber.ru
sberbank.ru
vtb.ru
alfabank.ru
tbank.ru
gazprombank.ru
gpb.ru
psbank.ru
rosbank.ru
rshb.ru
BANKS
            print_info "Добавлены домены российских банков в whitelist"
        fi

        if ! grep -q "^wildberries.ru$" "$whitelist" 2>/dev/null; then
            cat >> "$whitelist" <<'WB'

# === Wildberries ===
wildberries.ru
wb.ru
wbbasket.ru
WB
            print_info "Добавлены домены Wildberries в whitelist"
        fi

        if ! grep -q "^ok.ru$" "$whitelist" 2>/dev/null; then
            cat >> "$whitelist" <<'OKVK'

# === Доп. российские сервисы (OK/VK/Yandex) ===
ok.ru
mycdn.me
vk.me
yandex.net
OKVK
            print_info "Добавлены доп. домены OK/VK/Yandex в whitelist"
        fi

        if ! grep -q "^vkuseraudio.com$" "$whitelist" 2>/dev/null; then
            cat >> "$whitelist" <<'VKEXT'

# === VK сервисные/CDN-домены (фото-комменты, видео, аудио, формы) ===
mvk.com
vk.cc
vk.link
vk-cdn.net
vk-portal.net
vk-apps.com
vk-streaming.com
vkpay.com
vkpay.ru
vkuser.net
vkuseraudio.com
vkuseraudio.net
vkuservideo.com
vkuservideo.net
vkuserlive.com
vkuserlive.net
vkforms.com
vkforms.ru
vkmessenger.com
VKEXT
            print_info "Добавлены сервисные домены VK в whitelist"
        fi

        if ! grep -q "^leagueoflegends.com$" "$whitelist" 2>/dev/null; then
            printf '\nleagueoflegends.com\n' >> "$whitelist"
            print_info "Добавлен leagueoflegends.com в whitelist"
        fi

        if ! grep -q "^marketplace.visualstudio.com$" "$whitelist" 2>/dev/null; then
            printf 'marketplace.visualstudio.com\n' >> "$whitelist"
            print_info "Добавлен marketplace.visualstudio.com в whitelist"
        fi

        if ! grep -q "^customer-oci.com$" "$whitelist" 2>/dev/null; then
            printf '\n# === Oracle Cloud Infrastructure ===\ncustomer-oci.com\n' >> "$whitelist"
            print_info "Добавлен customer-oci.com в whitelist"
        fi
    fi

    print_success "Базовая конфигурация создана"
    return 0
}

# Сбросить конфигурацию к defaults
reset_config() {
    print_header "Сброс конфигурации"

    print_warning "Это удалит:"
    print_warning "  - Текущую стратегию"
    print_warning "  - Пользовательские домены (custom.txt)"
    print_warning "Списки discord/youtube НЕ будут удалены"

    printf "\nПродолжить сброс? [y/N]: "
    read -r answer </dev/tty

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            # Очистить текущую стратегию
            if [ -f "$CURRENT_STRATEGY_FILE" ]; then
                rm -f "$CURRENT_STRATEGY_FILE"
                print_info "Сброшена текущая стратегия"
            fi

            # Очистить custom.txt
            if [ -f "${LISTS_DIR}/custom.txt" ]; then
                : > "${LISTS_DIR}/custom.txt"
                print_info "Очищен список пользовательских доменов"
            fi

            print_success "Конфигурация сброшена"

            # Предложить перезапуск
            if is_zapret2_running; then
                printf "\nПерезапустить сервис? [Y/n]: "
                read -r restart_answer </dev/tty

                case "$restart_answer" in
                    [Nn]|[Nn][Oo])
                        print_info "Сервис не перезапущен"
                        ;;
                    *)
                        "$INIT_SCRIPT" restart
                        print_success "Сервис перезапущен"
                        ;;
                esac
            fi
            ;;
        *)
            print_info "Отменено"
            ;;
    esac

    return 0
}

# Создать backup конфигурации
backup_config() {
    local backup_dir="${CONFIG_DIR}/backups"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/config_backup_${timestamp}.tar.gz"

    print_header "Создание резервной копии"

    mkdir -p "$backup_dir" || {
        print_error "Не удалось создать директорию backup"
        return 1
    }

    print_info "Создание архива..."

    # Собрать список существующих файлов для бэкапа
    local file_list=""
    for f in \
        "${ZAPRET2_DIR}/config" \
        "${LISTS_DIR}/whitelist.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/YT/Strategy.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/YT_GV/Strategy.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/RKN/Strategy.txt" \
        "${ZAPRET2_DIR}/extra_strats/UDP/YT/Strategy.txt" \
        "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" \
    ; do
        [ -f "$f" ] && file_list="$file_list $f"
    done

    if [ -z "$file_list" ]; then
        print_error "Нет файлов для бэкапа"
        return 1
    fi

    # Создать tar.gz
    tar -czf "$backup_file" $file_list 2>/dev/null

    if [ -f "$backup_file" ]; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        print_success "Backup создан: $backup_file ($size)"
        return 0
    else
        print_error "Не удалось создать backup"
        return 1
    fi
}

# Восстановить конфигурацию из backup
restore_config() {
    local backup_dir="${CONFIG_DIR}/backups"

    print_header "Восстановление конфигурации"

    if [ ! -d "$backup_dir" ]; then
        print_error "Директория backups не найдена"
        return 1
    fi

    # Найти последний backup
    local latest_backup
    latest_backup=$(ls -t "${backup_dir}"/config_backup_*.tar.gz 2>/dev/null | head -n 1)

    if [ -z "$latest_backup" ]; then
        print_error "Резервные копии не найдены"
        return 1
    fi

    print_info "Последний backup: $latest_backup"
    printf "Восстановить? [y/N]: "
    read -r answer </dev/tty

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            print_info "Восстановление..."

            # Extract to a temp dir first, then move files to their correct locations.
            # The tar archive contains files from both $CONFIG_DIR and $LISTS_DIR,
            # but with different -C bases, so we cannot extract directly to one dir.
            local tmpdir="${CONFIG_DIR}/backups/.restore_tmp"
            rm -rf "$tmpdir"
            mkdir -p "$tmpdir"
            # Пробная распаковка: убеждаемся, что архив вообще целый, ДО того
            # как разворачивать его поверх живого конфига.
            if tar -xzf "$latest_backup" -C "$tmpdir" 2>/dev/null; then
                # Временную копию убираем СРАЗУ, а не после боевой распаковки:
                # она лежит на той же флешке и занимает ровно столько же места,
                # сколько предстоит записать. Держать её до конца означало
                # требовать двойного запаса там, где его чаще всего нет.
                rm -rf "$tmpdir"

                # Архив содержит абсолютные пути — извлекаем поверх /
                #
                # КОД ВОЗВРАТА ЗДЕСЬ ОБЯЗАТЕЛЕН. Раньше проверялась только
                # пробная распаковка выше, а боевая шла без проверки, и следом
                # безусловно печаталось «Конфигурация восстановлена». На флешке,
                # где место кончилось на середине, человек получал сообщение об
                # успехе поверх наполовину восстановленного дерева и тут же
                # соглашался перезапустить сервис на этой смеси.
                if ! tar -xzf "$latest_backup" -C / 2>/dev/null; then
                    print_error "Восстановление оборвалось на середине — конфигурация в смешанном состоянии"
                    print_info "Архив цел: $latest_backup. Проверьте свободное место (df -h /opt) и повторите."
                    return 1
                fi
                print_success "Конфигурация восстановлена"

                # Предложить перезапуск
                if is_zapret2_running; then
                    printf "Перезапустить сервис? [Y/n]: "
                    read -r restart_answer </dev/tty

                    case "$restart_answer" in
                        [Nn]|[Nn][Oo])
                            print_info "Сервис не перезапущен"
                            ;;
                        *)
                            "$INIT_SCRIPT" restart
                            print_success "Сервис перезапущен"
                            ;;
                    esac
                fi
            else
                # Пробная распаковка не прошла — архив битый. Временный каталог
                # убираем и здесь: это полная копия конфигурации, и оставлять её
                # на флешке после неудачи значит занимать место ровно тогда,
                # когда его вероятнее всего и не хватило.
                rm -rf "$tmpdir"
                print_error "Ошибка восстановления: архив повреждён или не читается"
                return 1
            fi
            ;;
        *)
            print_info "Отменено"
            ;;
    esac

    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
