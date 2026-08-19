#!/bin/sh
# z2k_cleanup.sh — полная зачистка zapret / zapret2 / nfqws / nfqws2
# Для экстренных случаев: зависшие процессы, остатки после удаления и т.д.
#
# ВНИМАНИЕ: Этот скрипт удаляет ВСЁ связанное с zapret и zapret2:
#   - Процессы nfqws / nfqws2 (kill -9)
#   - Init-скрипты S99zapret / S99zapret2
#   - Netfilter хуки
#   - Iptables цепочки и правила zapret/zapret2
#   - Директории /opt/zapret и /opt/zapret2 (ПОЛНОСТЬЮ)
#   - Временные файлы
#   - Telegram-туннель: tg-mtproxy-client, S98tg-tunnel, NDM redirect hook,
#     watchdog + cron-запись, iptables NAT REDIRECT на :1443, /opt/sbin бинарник
#   - Вспомогательный туннель S97z2k-http-tunnel + его NDM hook
#
# Использование:
#   sh -c 'tmp=/tmp/z2k_cleanup.sh; rm -f "$tmp"; for url in "https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh" "https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/z2k_cleanup.sh" "https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh"; do echo "[i] Пробую: $url" >&2; if curl -fsSL --connect-timeout 10 --max-time 180 "$url" -o "$tmp"; then exec sh "$tmp"; fi; done; echo "[FAIL] Не удалось скачать z2k_cleanup.sh ни с одного зеркала" >&2; exit 1'
#   или
#   sh z2k_cleanup.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { printf "${GREEN}[+]${NC} %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[X]${NC} %s\n" "$1"; }
log_skip()  { printf "    %s\n" "$1"; }

echo ""
echo "============================================"
echo "  z2k_cleanup — полная зачистка zapret(2)"
echo "============================================"
echo ""
log_warn "ВНИМАНИЕ: Будут удалены ВСЕ файлы zapret и zapret2!"
log_warn "Директории /opt/zapret и /opt/zapret2 будут удалены полностью."
echo ""

# ==========================================
# 1. Остановка init-скриптов (мягкая попытка)
# ==========================================

log_info "Попытка мягкой остановки через init-скрипты..."

for init in /opt/etc/init.d/S99zapret2 /opt/etc/init.d/S99zapret \
            /opt/etc/init.d/S97z2k-http-tunnel \
            /opt/etc/init.d/S96z2k-rt-proxy \
            /opt/etc/init.d/S51z2k-warp \
            /opt/etc/init.d/S95z2k-tpws \
            /opt/etc/init.d/S98tg-tunnel \
            /opt/etc/init.d/S99z2k-scheduler; do
    if [ -x "$init" ]; then
        log_info "Останавливаю: $init stop"
        "$init" stop 2>/dev/null || log_warn "  $init stop вернул ошибку (не критично)"
    fi
done

# ==========================================
# 2. Удаление init-скриптов
# ==========================================

log_info "Удаление init-скриптов..."

for init in /opt/etc/init.d/S99zapret2 /opt/etc/init.d/S99zapret \
            /opt/etc/init.d/S99nfqws   /opt/etc/init.d/S99nfqws2 \
            /opt/etc/init.d/S97z2k-http-tunnel \
            /opt/etc/init.d/S96z2k-rt-proxy \
            /opt/etc/init.d/S51z2k-warp \
            /opt/etc/init.d/S95z2k-tpws \
            /opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97tg-mtproxy \
            /opt/etc/init.d/S99z2k-scheduler; do
    if [ -f "$init" ]; then
        rm -f "$init"
        log_info "  Удалён: $init"
    fi
done

# ==========================================
# 3. Удаление netfilter хуков
# ==========================================

log_info "Удаление netfilter хуков..."

for hook in /opt/etc/ndm/netfilter.d/000-zapret2.sh \
            /opt/etc/ndm/netfilter.d/000-zapret.sh \
            /opt/etc/ndm/netfilter.d/*zapret* \
            /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-tg* \
            /opt/etc/ndm/netfilter.d/91-z2k-http-tunnel-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-http* \
            /opt/etc/ndm/netfilter.d/92-z2k-rt-proxy-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-rt* \
            /opt/etc/ndm/netfilter.d/93-z2k-tpws-redirect.sh \
            /opt/etc/ndm/netfilter.d/*z2k-tpws* \
            /opt/etc/ndm/netfilter.d/94-z2k-ppe-deoffload.sh \
            /opt/etc/ndm/netfilter.d/*z2k-ppe*; do
    if [ -f "$hook" ]; then
        rm -f "$hook"
        log_info "  Удалён: $hook"
    fi
done

# ==========================================
# 4. Убийство всех процессов nfqws / nfqws2
# ==========================================

log_info "Поиск и завершение процессов nfqws / nfqws2..."

killed=0
for proc_name in nfqws2 nfqws tg-mtproxy-client z2k-rt-proxy z2k-usque; do
    pids=$(pidof "$proc_name" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            log_warn "  Убиваю $proc_name (PID $pid)"
            kill -9 "$pid" 2>/dev/null || true
            killed=$((killed + 1))
        done
    fi
done

# Дополнительный поиск через ps (на случай если pidof не нашёл)
for proc_name in nfqws2 nfqws tg-mtproxy-client z2k-rt-proxy z2k-usque; do
    ps_pids=$(ps w 2>/dev/null | awk -v name="$proc_name" '$0 ~ "/"name"( |$)" || $0 ~ " "name"( |$)" {print $1}' || true)
    if [ -n "$ps_pids" ]; then
        for pid in $ps_pids; do
            log_warn "  Убиваю $proc_name (PID $pid, найден через ps)"
            kill -9 "$pid" 2>/dev/null || true
            killed=$((killed + 1))
        done
    fi
done

if [ "$killed" -eq 0 ]; then
    log_skip "Запущенных процессов nfqws/nfqws2/tg-mtproxy-client не найдено"
else
    log_info "Завершено процессов: $killed"
fi

# ==========================================
# 5. Очистка iptables правил и цепочек
# ==========================================

log_info "Очистка iptables правил zapret/zapret2..."

# Список известных цепочек zapret/zapret2
chains_mangle="ZAPRET ZAPRET2 z2k_connmark"
chains_nat="z2k_masq_fix zapret2_nat"
chains_raw="z2k_dpi_rst"

# Удаление из mangle
for chain in $chains_mangle; do
    # Удалить ссылки из стандартных цепочек
    for parent in POSTROUTING PREROUTING FORWARD; do
        while iptables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
            iptables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            log_info "  Удалена ссылка mangle/$parent -> $chain"
        done
        while ip6tables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
            ip6tables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            log_info "  Удалена ссылка mangle/$parent -> $chain (IPv6)"
        done
    done
    # Flush и удаление самой цепочки
    iptables -t mangle -F "$chain" 2>/dev/null && log_info "  Очищена mangle/$chain"
    iptables -t mangle -X "$chain" 2>/dev/null && log_info "  Удалена mangle/$chain"
    ip6tables -t mangle -F "$chain" 2>/dev/null && log_info "  Очищена mangle/$chain (IPv6)"
    ip6tables -t mangle -X "$chain" 2>/dev/null && log_info "  Удалена mangle/$chain (IPv6)"
done

# Удаление из nat
for chain in $chains_nat; do
    while iptables -t nat -C POSTROUTING -j "$chain" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$chain" 2>/dev/null || break
    done
    iptables -t nat -F "$chain" 2>/dev/null && log_info "  Очищена nat/$chain"
    iptables -t nat -X "$chain" 2>/dev/null && log_info "  Удалена nat/$chain"
done

# Удаление из raw
for chain in $chains_raw; do
    while iptables -t raw -C PREROUTING -j "$chain" 2>/dev/null; do
        iptables -t raw -D PREROUTING -j "$chain" 2>/dev/null || break
    done
    iptables -t raw -F "$chain" 2>/dev/null && log_info "  Очищена raw/$chain"
    iptables -t raw -X "$chain" 2>/dev/null && log_info "  Удалена raw/$chain"
done

# Поиск и удаление любых оставшихся правил с упоминанием nfqws/zapret
for table in mangle nat raw filter; do
    # Ищем правила с nfqueue (nfqws использует NFQUEUE target)
    rule_nums=$(iptables -t "$table" -L POSTROUTING --line-numbers -n 2>/dev/null \
        | grep -i "NFQUEUE\|zapret\|nfqws\|z2k" | awk '{print $1}' | sort -rn || true)
    for num in $rule_nums; do
        iptables -t "$table" -D POSTROUTING "$num" 2>/dev/null && \
            log_info "  Удалено правило POSTROUTING #$num из $table"
    done
done

# ==========================================
# 5a. Telegram-туннель: NAT REDIRECT правила
# ==========================================
#
# Меню [T] / install вставляет REDIRECT на :1443 для 10 Telegram DC CIDRs
# в PREROUTING и OUTPUT (nat). NDM hook может продублировать их, поэтому
# удаляем в цикле пока -C находит совпадение.

log_info "Удаление iptables NAT REDIRECT правил Telegram-туннеля (:1443)..."

TG_CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
tg_rules_removed=0
# Current ipset-based rules (z2k_tg_dc match-set → :1443) — 2 rules.
for chain in PREROUTING OUTPUT; do
    while iptables -w -t nat -C "$chain" -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443 2>/dev/null; do
        iptables -w -t nat -D "$chain" -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443 2>/dev/null || break
        tg_rules_removed=$((tg_rules_removed + 1))
    done
done
# Legacy per-CIDR rules (pre-ipset builds) — keep removing for back-compat.
for cidr in $TG_CIDRS; do
    for chain in PREROUTING OUTPUT; do
        while iptables -w -t nat -C "$chain" -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -w -t nat -D "$chain" -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
            tg_rules_removed=$((tg_rules_removed + 1))
        done
    done
done
# Destroy the ipset itself — NDM doesn't touch ipsets, so it would linger.
if ipset destroy z2k_tg_dc 2>/dev/null; then
    log_info "  Удалён ipset z2k_tg_dc"
fi
if [ "$tg_rules_removed" -gt 0 ]; then
    log_info "  Снято NAT правил Telegram: $tg_rules_removed"
else
    log_skip "Правил REDIRECT :1443 не найдено"
fi

# ==========================================
# 5a-tpws. tpws youtube-слой: NAT REDIRECT (:1446) + mangle mark + ipset
# ==========================================

log_info "Удаление iptables правил tpws-слоя (:1446)..."
tpws_rules_removed=0
while iptables -w -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446 2>/dev/null; do
    iptables -w -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446 2>/dev/null || break
    tpws_rules_removed=$((tpws_rules_removed + 1))
done
while iptables -w -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null; do
    iptables -w -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null || break
    tpws_rules_removed=$((tpws_rules_removed + 1))
done
if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -w -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446 2>/dev/null; do
        ip6tables -w -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446 2>/dev/null || break
        tpws_rules_removed=$((tpws_rules_removed + 1))
    done
    while ip6tables -w -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null; do
        ip6tables -w -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null || break
        tpws_rules_removed=$((tpws_rules_removed + 1))
    done
fi
# Destroy ipsets (NDM doesn't touch them; rules dropped above so not "in use").
ipset destroy z2k_tpws 2>/dev/null && log_info "  Удалён ipset z2k_tpws"
ipset destroy z2k_tpws6 2>/dev/null && log_info "  Удалён ipset z2k_tpws6"
rm -rf /opt/zapret2/tpws /opt/zapret2/z2k-tpws.sh /opt/zapret2/z2k-tpws-watchdog.sh \
       /opt/zapret2/lists/youtube_ips.txt /opt/zapret2/lists/youtube_ips6.txt \
       /var/run/z2k-tpws.pid 2>/dev/null
killall -9 tpws 2>/dev/null || true
if [ "$tpws_rules_removed" -gt 0 ]; then
    log_info "  Снято правил tpws: $tpws_rules_removed"
else
    log_skip "Правил tpws :1446 не найдено"
fi

# ==========================================
# 5b-ppe. Per-flow PPE de-offload: mangle FORWARD/PREROUTING -j PPE (connskip)
# ==========================================

log_info "Удаление iptables правил per-flow PPE de-offload..."
ppe_rules_removed=0
ppe_args="-p tcp -m multiport --dports 80,443,2053,2083,2087,2096,8443 -m connskip --connskip 30 -j PPE"
for ppe_c in FORWARD PREROUTING; do
    while iptables -w -t mangle -C "$ppe_c" $ppe_args 2>/dev/null; do
        iptables -w -t mangle -D "$ppe_c" $ppe_args 2>/dev/null || break
        ppe_rules_removed=$((ppe_rules_removed + 1))
    done
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -w -t mangle -C "$ppe_c" $ppe_args 2>/dev/null; do
            ip6tables -w -t mangle -D "$ppe_c" $ppe_args 2>/dev/null || break
            ppe_rules_removed=$((ppe_rules_removed + 1))
        done
    fi
done
rm -f /opt/zapret2/z2k-ppe-deoffload.sh 2>/dev/null
if [ "$ppe_rules_removed" -gt 0 ]; then
    log_info "  Снято правил PPE de-offload: $ppe_rules_removed"
else
    log_skip "Правил PPE de-offload не найдено"
fi

# ==========================================
# 5a-bis. Вспомогательный HTTP-туннель: NAT REDIRECT правила (:1444)
# ==========================================

log_info "Удаление iptables NAT REDIRECT правил вспомогательного туннеля (:1444)..."

HTTP_CIDRS="168.119.95.238/32"
http_rules_removed=0
for cidr in $HTTP_CIDRS; do
    for chain in PREROUTING OUTPUT; do
        while iptables -t nat -C "$chain" -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null; do
            iptables -t nat -D "$chain" -d "$cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null || break
            http_rules_removed=$((http_rules_removed + 1))
        done
    done
    conntrack -D -d "${cidr%/*}" 2>/dev/null || true
done
if [ "$http_rules_removed" -gt 0 ]; then
    log_info "  Снято NAT правил :1444: $http_rules_removed"
else
    log_skip "Правил REDIRECT :1444 не найдено"
fi

# ==========================================
# 5a-rt. RuTracker-прокси (:1445) — правила, DNS-пины, бинарь
# ==========================================
# Этой секции не было вовсе, хотя соседние (:1443, :1444, :1446) есть. Последствие
# хуже, чем просто мусор: DOMAINS рутрекера прибиты в конфиге роутера к sentinel
# 10.171.171.171, а слушателя на :1445 после зачистки нет — рутрекер остаётся
# мёртвым НАВСЕГДА, и по коробке не видно почему. Скрипт запускают именно тогда,
# когда что-то сломалось, так что он обязан не добавлять поломку.

log_info "Удаление правил и DNS-пинов RuTracker-прокси (:1445)..."

RTP_SENTINEL="10.171.171.171"
rtp_rules_removed=0
for chain in PREROUTING OUTPUT; do
    while iptables -w -t nat -C "$chain" -d "$RTP_SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null; do
        iptables -w -t nat -D "$chain" -d "$RTP_SENTINEL" -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null || break
        rtp_rules_removed=$((rtp_rules_removed + 1))
    done
done
# PPE de-offload на sentinel ставится отдельно от REDIRECT — снимаем и его.
while iptables -w -t mangle -C PREROUTING -d "$RTP_SENTINEL" -p tcp --dport 443 -j PPE 2>/dev/null; do
    iptables -w -t mangle -D PREROUTING -d "$RTP_SENTINEL" -p tcp --dport 443 -j PPE 2>/dev/null || break
    rtp_rules_removed=$((rtp_rules_removed + 1))
done
conntrack -D -d "$RTP_SENTINEL" 2>/dev/null || true
if [ "$rtp_rules_removed" -gt 0 ]; then
    log_info "  Снято правил :1445/sentinel: $rtp_rules_removed"
else
    log_skip "Правил RuTracker-прокси не найдено"
fi

# DNS-пины. LD_LIBRARY_PATH= обязателен: с Entware-путями ndmc грузит несовместимый
# OpenSSL и падает `Cli::Main: failed to initialize` — проверено на KeenOS 5.01.C.1.0-0,
# и именно так этот класс отказа однажды уже оставил пины висеть.
if command -v ndmc >/dev/null 2>&1; then
    rtp_pins_removed=0
    for _d in rutracker.org www.rutracker.org rutracker.cc static.rutracker.cc \
              api.rutracker.cc rep.rutracker.cc rutracker.wiki; do
        if LD_LIBRARY_PATH= ndmc -c "no ip host $_d $RTP_SENTINEL" >/dev/null 2>&1; then
            rtp_pins_removed=$((rtp_pins_removed + 1))
        fi
    done
    LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
    if [ "$rtp_pins_removed" -gt 0 ]; then
        log_info "  Снято DNS-пинов rutracker: $rtp_pins_removed"
    else
        log_skip "DNS-пинов rutracker не найдено"
    fi
fi

# ------------------------------------------------------------------
# DNS-пины остальных доменов: Instagram, WhatsApp, 4pda.
#
# ЗАЧЕМ. Выше снимаются только rutracker-пины, перечисленные руками. Всё
# остальное оставалось висеть НАВСЕГДА: человек снёс z2k, а роутер продолжает
# резолвить instagram.com и 4pda.to в адреса, которые мы туда прошили. Через
# недели-месяцы адреса протухают, и у него ломается то, что без z2k работало бы
# нормально — причём причину найти неоткуда. Плюс у Keenetic потолок 256
# статических записей, и его уже однажды съели пинами Discord.
#
# СПИСОК ДОМЕНОВ НЕ ДУБЛИРУЕМ. Он берётся из HOSTS в самом
# z2k-insta-ip-refresh.sh — то есть оттуда же, откуда берётся при установке.
# Иначе каждый новый домен надо не забыть внести во ВТОРОЕ место, а этот класс
# ошибок у нас уже случался: 4pda добавили 19.08 и в удаление он не попал бы.
# Скрипт на этот момент ещё на диске — /opt/zapret2 сносится ниже.
#
# Строку из running-config подставляем в `no <строка>` целиком: у ndmc удаление
# принимает те же аргументы, что и добавление, а IP в записи может быть любым
# (их переписывает ежедневное обновление).
if command -v ndmc >/dev/null 2>&1; then
    _refresh_sh="${ZAPRET2_DIR:-/opt/zapret2}/z2k-insta-ip-refresh.sh"
    _pin_hosts=""
    if [ -r "$_refresh_sh" ]; then
        _pin_hosts=$(sed -n 's/^HOSTS="\(.*\)"$/\1/p' "$_refresh_sh" | head -1)
    fi
    # Запасной список — на случай, когда скрипта уже нет (частичная установка,
    # ручное удаление файлов). Лучше снять по памяти, чем не снять вовсе.
    [ -n "$_pin_hosts" ] || _pin_hosts="instagram.com www.instagram.com graph.instagram.com api.instagram.com instagram.c10r.instagram.com static.cdninstagram.com scontent.cdninstagram.com web.whatsapp.com www.whatsapp.com scontent.whatsapp.net graph.whatsapp.com v.whatsapp.com 4pda.to www.4pda.to s.4pda.to"

    _pin_removed=0
    _running=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null)
    for _h in $_pin_hosts; do
        # Точное совпадение по имени: подстрока зацепила бы чужие домены.
        _lines=$(printf '%s\n' "$_running" | awk -v h="$_h" '$1=="ip" && $2=="host" && $3==h {print}')
        [ -n "$_lines" ] || continue
        _IFS_save="$IFS"
        IFS='
'
        for _line in $_lines; do
            IFS="$_IFS_save"
            if LD_LIBRARY_PATH= ndmc -c "no $_line" >/dev/null 2>&1; then
                _pin_removed=$((_pin_removed + 1))
            fi
            IFS='
'
        done
        IFS="$_IFS_save"
    done
    if [ "$_pin_removed" -gt 0 ]; then
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
        log_info "  Снято DNS-пинов Instagram/WhatsApp/4pda: $_pin_removed"
    else
        log_skip "DNS-пинов Instagram/WhatsApp/4pda не найдено"
    fi
fi

# Бинарь и его init-скрипт (директории /opt/zapret2 сносятся ниже, но /opt/sbin — нет).
for _f in /opt/sbin/z2k-rt-proxy /opt/sbin/z2k-rt-proxy.z2kbak; do
    [ -f "$_f" ] && rm -f "$_f" && log_info "  Удалён $_f"
done

# ==========================================
# 5b. Cron-записи z2k и восстановление cron-демона
# ==========================================

# Strip every cron entry z2k ever installed (current + legacy paths).
if command -v crontab >/dev/null 2>&1; then
    for pat in "tg-tunnel-watchdog" "S97tg-mtproxy" \
               "z2k-auto-update" "z2k-update-lists" "z2k-classify-drift" \
               "z2k-nightly-probe" "ipset/get_config" "z2k-scheduler"; do
        if crontab -l 2>/dev/null | grep -q "$pat"; then
            crontab -l 2>/dev/null | grep -v "$pat" | crontab - 2>/dev/null \
                && log_info "  Удалена cron-запись: $pat"
        fi
    done
fi

# Strip our entries from /opt/etc/crontab too (legacy install method).
if [ -f /opt/etc/crontab ]; then
    if grep -qE "get_config\.sh|z2k-update-lists\.sh|z2k-auto-update\.sh|z2k-classify-drift\.sh|z2k-nightly-probe\.sh|tg-tunnel-watchdog|z2k-scheduler" /opt/etc/crontab 2>/dev/null; then
        grep -vE "get_config\.sh|z2k-update-lists\.sh|z2k-auto-update\.sh|z2k-classify-drift\.sh|z2k-nightly-probe\.sh|tg-tunnel-watchdog|z2k-scheduler" \
            /opt/etc/crontab > /opt/etc/crontab.tmp 2>/dev/null \
            && mv /opt/etc/crontab.tmp /opt/etc/crontab \
            && log_info "  Очищены z2k записи из /opt/etc/crontab"
    fi
fi

# Re-enable Vixie cron's init script — z2k disabled it during install
# (chmod -x). Cron itself is not ours to remove; restore it so the user
# has it available for unrelated needs.
if [ -f /opt/etc/init.d/S10cron ] && [ ! -x /opt/etc/init.d/S10cron ]; then
    chmod +x /opt/etc/init.d/S10cron 2>/dev/null \
        && log_info "  Восстановлен autostart cron-демона (/opt/etc/init.d/S10cron +x)"
fi

# ==========================================
# 6. Удаление директорий
# ==========================================

log_info "Удаление директорий zapret/zapret2..."

for dir in /opt/zapret2 /opt/zapret; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        log_info "  Удалена: $dir"
    else
        log_skip "$dir не найдена (уже удалена)"
    fi
done

# Бинарник Telegram-туннеля живёт вне /opt/zapret2 — убираем отдельно.
if [ -f /opt/sbin/tg-mtproxy-client ]; then
    rm -f /opt/sbin/tg-mtproxy-client
    log_info "  Удалён бинарник: /opt/sbin/tg-mtproxy-client"
fi

# ==========================================
# 7. Очистка временных файлов
# ==========================================

log_info "Очистка временных файлов..."

for tmpdir in /tmp/z2k /tmp/zapret /tmp/zapret2 /tmp/blockcheck* \
              /tmp/z2k-log/tg-tunnel.log /tmp/tg-tunnel-watchdog.state \
              /var/run/tg-tunnel.pid \
              /tmp/z2k-log/z2k-http-tunnel.log /var/run/z2k-http-tunnel.pid \
              /tmp/z2k-log/z2k-rt-proxy.log /var/run/z2k-rt-proxy.pid \
              /var/run/z2k-warp.pid \
              /tmp/z2k-log/z2k-insta-refresh.log /tmp/z2k-log/z2k-insta-refresh.log.old \
              /var/run/z2k-scheduler.pid /opt/var/log/z2k-scheduler.log \
              /opt/var/log/z2k-classify.log \
              /opt/var/log/z2k-classify-drift.log \
              /opt/var/log/z2k-classify-history.tsv; do
    if [ -e "$tmpdir" ]; then
        rm -rf "$tmpdir"
        log_info "  Удалён: $tmpdir"
    fi
done

# ==========================================
# 8. Очистка ipset (если остались)
# ==========================================

log_info "Очистка ipset..."

for setname in zapret zapret2 z2k; do
    if ipset list "$setname" >/dev/null 2>&1; then
        ipset destroy "$setname" 2>/dev/null && log_info "  Удалён ipset: $setname"
    fi
done

# Поиск ipset с zapret в имени
ipset_list=$(ipset list -n 2>/dev/null | grep -i "zapret\|z2k" || true)
for setname in $ipset_list; do
    ipset destroy "$setname" 2>/dev/null && log_info "  Удалён ipset: $setname"
done

# ==========================================
# 9. Финальная проверка
# ==========================================

echo ""
log_info "=== Финальная проверка ==="

# Проверка процессов
remaining=$(ps w 2>/dev/null | awk '$0 ~ "/nfqws[2]?( |$)" || $0 ~ " nfqws[2]?( |$)"' | wc -l)
if [ "$remaining" -gt 0 ]; then
    log_error "Остались запущенные процессы nfqws! Проверьте: ps | grep nfqws"
else
    log_info "Процессы nfqws/nfqws2: не найдены"
fi

if pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
    log_error "Остался запущенный tg-mtproxy-client! Проверьте: ps | grep tg-mtproxy"
else
    log_info "Процесс tg-mtproxy-client: не найден"
fi

# Проверка директорий
for dir in /opt/zapret /opt/zapret2; do
    if [ -d "$dir" ]; then
        log_error "Директория всё ещё существует: $dir"
    else
        log_info "Директория удалена: $dir"
    fi
done

# Проверка init-скриптов
for init in /opt/etc/init.d/S99zapret /opt/etc/init.d/S99zapret2 \
            /opt/etc/init.d/S97z2k-http-tunnel \
            /opt/etc/init.d/S96z2k-rt-proxy \
            /opt/etc/init.d/S51z2k-warp \
            /opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97tg-mtproxy \
            /opt/etc/init.d/S99z2k-scheduler; do
    if [ -f "$init" ]; then
        log_error "Init-скрипт всё ещё существует: $init"
    fi
done

# Проверка Telegram-бинарника
if [ -f /opt/sbin/tg-mtproxy-client ]; then
    log_error "Бинарник всё ещё существует: /opt/sbin/tg-mtproxy-client"
fi

echo ""
echo "============================================"
log_info "Зачистка завершена."
log_info "Для переустановки z2k:"
echo "  sh -c 'tmp=/tmp/z2k.sh; rm -f \"\$tmp\"; for url in \"https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh\" \"https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/z2k.sh\" \"https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh\"; do echo \"[i] Пробую: \$url\" >&2; if curl -fsSL --connect-timeout 10 --max-time 180 \"\$url\" -o \"\$tmp\"; then exec sh \"\$tmp\"; fi; done; echo \"[FAIL] Не удалось скачать z2k.sh ни с одного зеркала\" >&2; exit 1'"
echo "============================================"
echo ""
