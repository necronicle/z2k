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
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh | sh
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
            /opt/etc/init.d/S98tg-tunnel; do
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
            /opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97tg-mtproxy; do
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
            /opt/etc/ndm/netfilter.d/*z2k-tg*; do
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
for proc_name in nfqws2 nfqws tg-mtproxy-client; do
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
for proc_name in nfqws2 nfqws tg-mtproxy-client; do
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
for cidr in $TG_CIDRS; do
    for chain in PREROUTING OUTPUT; do
        while iptables -t nat -C "$chain" -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -t nat -D "$chain" -d "$cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
            tg_rules_removed=$((tg_rules_removed + 1))
        done
    done
done
if [ "$tg_rules_removed" -gt 0 ]; then
    log_info "  Снято NAT правил Telegram: $tg_rules_removed"
else
    log_skip "Правил REDIRECT :1443 не найдено"
fi

# ==========================================
# 5b. Cron-записи Telegram-туннеля
# ==========================================

if command -v crontab >/dev/null 2>&1; then
    for pat in "tg-tunnel-watchdog" "S97tg-mtproxy"; do
        if crontab -l 2>/dev/null | grep -q "$pat"; then
            crontab -l 2>/dev/null | grep -v "$pat" | crontab - 2>/dev/null \
                && log_info "  Удалена cron-запись: $pat"
        fi
    done
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
              /tmp/tg-tunnel.log /tmp/tg-tunnel-watchdog.state \
              /var/run/tg-tunnel.pid; do
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
            /opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97tg-mtproxy; do
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
echo "  curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh | sh"
echo "============================================"
echo ""
