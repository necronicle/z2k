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

# env-overridable (NDM не задаёт эти переменные → прод берёт дефолты; тесты подменяют).
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
ZAPRET_CONFIG="${ZAPRET_CONFIG:-/opt/zapret2/config}"

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

# --- Storm guard: lock + debounce (GitHub issue #18) -----------------------
# Keenetic дёргает этот hook ДЕСЯТКИ раз за секунду при переподключении / смене
# NAT / пересборке политик. Старый `restart_fw &` (fire-and-forget) плодил 80+
# параллельных restart_fw → load avg 44+, ndm 100% CPU, и при WireGuard в
# default route — лавину `ip link show nwg0` в D-state. Коалесцируем всплеск:
# debounce-окно + mkdir-mutex, чтобы restart_fw шёл максимум ОДИН за раз.
LOCK_DIR="${LOCK_DIR:-/tmp/zapret2-restart-fw.lock}"
LAST_RUN="${LAST_RUN:-/tmp/zapret2-restart-fw.last}"
MIN_INTERVAL="${MIN_INTERVAL:-15}"   # с — коалесцируем всплеск NDM-событий
HOOK_SETTLE="${HOOK_SETTLE:-2}"      # с — дать NDM достроить таблицы (тест ускоряет)

now="$(date +%s 2>/dev/null || echo 0)"

# Debounce: restart_fw в пределах MIN_INTERVAL уже покрыл это событие.
if [ "$now" -gt 0 ] 2>/dev/null && [ -f "$LAST_RUN" ]; then
    last="$(cat "$LAST_RUN" 2>/dev/null || echo 0)"
    [ "$last" -gt 0 ] 2>/dev/null && [ $((now - last)) -lt "$MIN_INTERVAL" ] && exit 0
fi

# Stale-lock guard: упавший restart_fw не должен навсегда заклинить пере-применение.
if [ -d "$LOCK_DIR" ]; then
    lock_ts="$(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0)"
    [ "$now" -gt 0 ] && [ "$lock_ts" -gt 0 ] && [ $((now - lock_ts)) -gt 60 ] && \
        rmdir "$LOCK_DIR" 2>/dev/null
fi

# Mutex: атомарный mkdir. Если занят — пересборка уже идёт, её результат покрывает нас.
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
[ "$now" -gt 0 ] && echo "$now" > "$LAST_RUN" 2>/dev/null   # пометить сразу → всплеск debounce'ится

# Тяжёлую пересборку — в фон (hook у NDM синхронный, должен вернуться быстро);
# lock гарантирует ровно одну за раз. sleep — дать NDM достроить таблицы.
# restart_fw пересоздаёт только NFQUEUE правила в mangle, демоны (nfqws2) живут.
{
    sleep "$HOOK_SETTLE"
    "$INIT_SCRIPT" restart_fw >/dev/null 2>&1
    rmdir "$LOCK_DIR" 2>/dev/null
} &

exit 0
