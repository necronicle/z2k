#!/bin/sh
# Деплой релея без разрыва (спека §3.6): поднять спящий экземпляр, убедиться,
# что он отвечает, остановить работающий (drain: RETRY_AFTER v2-клиентам,
# до 120 с). Порт слушают оба через reuseport, окна без слушателя нет.
#   relay-switch.sh [--dry-run]
# SYSTEMCTL и CURL подменяются в тестах.
set -eu
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
CURL="${CURL:-curl}"
active=""
idle=""
for i in a b; do
    if $SYSTEMCTL is-active --quiet "z2k-relay@$i"; then active="$active $i"; else idle="$idle $i"; fi
done
active=$(echo $active)
idle=$(echo $idle)
case "$active" in
    "a b") echo "оба экземпляра активны — сначала остановите один" >&2; exit 2 ;;
    "") next=a ;;
    *) next=$(echo $idle | cut -d" " -f1) ;;
esac
port=9098
[ "$next" = b ] && port=9097
if [ "${1:-}" = "--dry-run" ]; then
    echo "поднял бы z2k-relay@$next, остановил бы ${active:-ничего}"
    exit 0
fi
$SYSTEMCTL start "z2k-relay@$next"
i=0
until $CURL -fsS --max-time 2 "http://127.0.0.1:$port/metrics" 2>/dev/null | grep -q '^relay_build_info'; do
    i=$((i+1))
    if [ $i -ge 30 ]; then
        echo "z2k-relay@$next не отвечает — останавливаю его, ${active:-старый} не трогаю" >&2
        $SYSTEMCTL stop "z2k-relay@$next"
        exit 1
    fi
    sleep 1
done
echo "z2k-relay@$next отвечает: $($CURL -fsS --max-time 2 "http://127.0.0.1:$port/metrics" | grep '^relay_build_info')"
for old in $active; do
    echo "останавливаю z2k-relay@$old (drain)"
    $SYSTEMCTL stop "z2k-relay@$old"
done
# Одиночный юнит прежней схемы: после первого переключения он больше не нужен.
if $SYSTEMCTL is-active --quiet z2k-relay.service; then
    echo "останавливаю прежний z2k-relay.service (drain)"
    $SYSTEMCTL disable --now z2k-relay.service
fi
echo "готово: активен z2k-relay@$next"
