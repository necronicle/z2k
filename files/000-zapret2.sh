#!/bin/sh
# Keenetic NDM netfilter hook для автоматического восстановления правил zapret2
# Устанавливается в: /opt/etc/ndm/netfilter.d/000-zapret2.sh
#
# Этот скрипт вызывается системой Keenetic при изменениях в netfilter (iptables).
# Когда происходит переподключение к интернету, изменение настроек сети или
# другие события - правила iptables сбрасываются, и этот хук восстанавливает их.

# Переменные окружения от NDM:
# $table - имя таблицы iptables (filter, nat, mangle, raw)
# $type  - `iptables` или `ip6tables`

INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
ZAPRET_CONFIG="/opt/zapret2/config"

# Обрабатываем только изменения в таблицах mangle/nat.
# zapret2 использует mangle (NFQUEUE), но Keenetic при переподключении может дергать hook и на nat.
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit 0

# Проверить что init скрипт существует
[ ! -f "$INIT_SCRIPT" ] && exit 0

# Проверить что zapret2 включен (ENABLED=1 в конфиге)
if ! grep -q "^ENABLED=1" "$ZAPRET_CONFIG" 2>/dev/null; then
    exit 0
fi

# Не восстанавливать NFQUEUE-правила, если nfqws2 не запущен.
# Иначе трафик может уйти в очередь без потребителя.
is_nfqws2_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof nfqws2 >/dev/null 2>&1 && return 0
    fi

    # Fallback: check common pidfile locations (our init uses nfqws2_*.pid).
    for pidfile in /var/run/nfqws2_*.pid /var/run/nfqws2.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done

    return 1
}
is_nfqws2_running || exit 0

# Логирование (опционально, раскомментируйте для отладки)
# logger -t zapret2-hook "Netfilter hook triggered: table=$table, type=$type"

# Небольшая задержка для стабильности
sleep 2

# Восстановить только firewall-правила (НЕ restart!)
# restart убивает nfqws2, обнуляя Lua-состояние autocircular (per-domain стратегии).
# restart_fw пересоздаёт только NFQUEUE правила в mangle, демоны продолжают работу.
"$INIT_SCRIPT" restart_fw >/dev/null 2>&1 &

exit 0
