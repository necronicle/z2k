#!/bin/sh
# Keenetic NDM netfilter hook для автоматического восстановления правил zapret2
# Устанавливается в: /opt/etc/ndm/netfilter.d/000-zapret2.sh
#
# Этот скрипт вызывается системой Keenetic при изменениях в netfilter (iptables).
# Когда происходит переподключение к интернету, изменение настроек сети или
# другие события - правила iptables сбрасываются, и этот хук восстанавливает их.

# Переменные окружения от NDM:
# $table - имя таблицы iptables (filter, nat, mangle, raw)
# $type - тип события (add, del, etc)

INIT_SCRIPT="/opt/etc/init.d/S99zapret2"

# Обрабатываем только изменения в таблице mangle
# (zapret2 использует mangle таблицу для NFQUEUE)
[ "$table" != "mangle" ] && exit 0

# Проверить что init скрипт существует
[ ! -f "$INIT_SCRIPT" ] && exit 0

# Проверить что zapret2 включен
if ! grep -q "^ENABLED=yes" "$INIT_SCRIPT" 2>/dev/null; then
    exit 0
fi

# Логирование (опционально, раскомментируйте для отладки)
# logger -t zapret2-hook "Netfilter hook triggered: table=$table, type=$type"

# Небольшая задержка для стабильности
sleep 2

# Перезапустить правила zapret2
"$INIT_SCRIPT" restart >/dev/null 2>&1 &

exit 0
