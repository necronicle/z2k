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
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/master/z2k_cleanup.sh | sh
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

for init in /opt/etc/init.d/S99zapret2 /opt/etc/init.d/S99zapret; do
    if [ -x "$init" ]; then
        log_info "Останавливаю: $init stop"
        "$init" stop 2>/dev/null || log_warn "  $init stop вернул ошибку (не критично)"
    fi
done

# ==========================================
# 2. Убийство всех процессов nfqws / nfqws2
# ==========================================

log_info "Поиск и завершение процессов nfqws / nfqws2..."

killed=0
for proc_name in nfqws2 nfqws; do
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
for proc_name in nfqws2 nfqws; do
    ps_pids=$(ps w 2>/dev/null | grep "[n]fq" | grep "$proc_name" | awk '{print $1}' || true)
    if [ -n "$ps_pids" ]; then
        for pid in $ps_pids; do
            log_warn "  Убиваю $proc_name (PID $pid, найден через ps)"
            kill -9 "$pid" 2>/dev/null || true
            killed=$((killed + 1))
        done
    fi
done

if [ "$killed" -eq 0 ]; then
    log_skip "Запущенных процессов nfqws/nfqws2 не найдено"
else
    log_info "Завершено процессов: $killed"
fi

# ==========================================
# 3. Очистка iptables правил и цепочек
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
# 4. Удаление init-скриптов
# ==========================================

log_info "Удаление init-скриптов..."

for init in /opt/etc/init.d/S99zapret2 /opt/etc/init.d/S99zapret \
            /opt/etc/init.d/S99nfqws   /opt/etc/init.d/S99nfqws2; do
    if [ -f "$init" ]; then
        rm -f "$init"
        log_info "  Удалён: $init"
    fi
done

# ==========================================
# 5. Удаление netfilter хуков
# ==========================================

log_info "Удаление netfilter хуков..."

for hook in /opt/etc/ndm/netfilter.d/000-zapret2.sh \
            /opt/etc/ndm/netfilter.d/000-zapret.sh \
            /opt/etc/ndm/netfilter.d/*zapret*; do
    if [ -f "$hook" ]; then
        rm -f "$hook"
        log_info "  Удалён: $hook"
    fi
done

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

# ==========================================
# 7. Очистка временных файлов
# ==========================================

log_info "Очистка временных файлов..."

for tmpdir in /tmp/z2k /tmp/zapret /tmp/zapret2 /tmp/blockcheck*; do
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
remaining=$(ps w 2>/dev/null | grep -c "[n]fqws" || echo 0)
if [ "$remaining" -gt 0 ]; then
    log_error "Остались запущенные процессы nfqws! Проверьте: ps | grep nfqws"
else
    log_info "Процессы nfqws/nfqws2: не найдены"
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
for init in /opt/etc/init.d/S99zapret /opt/etc/init.d/S99zapret2; do
    if [ -f "$init" ]; then
        log_error "Init-скрипт всё ещё существует: $init"
    fi
done

echo ""
echo "============================================"
log_info "Зачистка завершена."
log_info "Для переустановки z2k:"
echo "  curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/master/z2k.sh | sh"
echo "============================================"
echo ""
