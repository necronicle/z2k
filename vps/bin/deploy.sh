#!/bin/sh
# vps/bin/deploy.sh — раскатка конфигурации узла из репозитория.
#
# Правила, из-за которых этот скрипт вообще существует:
#
# 1. Никогда не затирать вслепую. Если живой файл разошёлся с репозиторием,
#    сначала разбираются, чья версия верна. Год правок руками на машине уже
#    один раз развёл копии на 47 строк.
# 2. Никогда не перезапускать то, что держит соединения. `systemctl restart
#    nginx` рвёт около 1800 туннелей, релей — около 3500. Скрипт умеет только
#    reload; всё, что требует полного перезапуска, он НАЗЫВАЕТ и оставляет
#    человеку на окно.
# 3. Проверять после, а не до. Правка `listen` может молча не примениться на
#    унаследованном сокете, а `sysctl` из нашего файла — быть перекрыт
#    /etc/sysctl.conf, который применяется последним. Поэтому после раскатки
#    сверяется ФАКТ.
#
# Использование:
#   sh vps/bin/deploy.sh            — показать, что изменится (ничего не трогает)
#   sh vps/bin/deploy.sh --apply    — раскатать
set -e

APPLY=0
[ "$1" = "--apply" ] && { APPLY=1; shift; }
HOST="${1:-${Z2K_VPS_HOST:-213.176.74.63}}"
KEY="${Z2K_VPS_KEY:-$HOME/.ssh/z2k_vps_ed25519}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 -i $KEY root@$HOST"
SCP="scp -o StrictHostKeyChecking=no -i $KEY"
MASK='s/(--secret|--secret-prev|--resolve-secret|--admin-token)=[^ "]*/\1=<СЕКРЕТ>/g'

# Файлы с секретами не раскатываются: в репозитории они лежат с маской
# <СЕКРЕТ>, и раскатка подставила бы эту маску вместо настоящего ключа.
# Они существуют в репозитории ради сверки структуры, а не ради установки.
# 10-require-per-install.conf ссылается на секреты через env:, значений в нём
# нет — он раскатывается обычным порядком.
SECRET_BEARING=""

PAIRS="
config/nginx.conf:/etc/nginx/nginx.conf:nginx
config/sysctl.d/99-z2k-relay.conf:/etc/sysctl.d/99-z2k-relay.conf:sysctl
config/sysctl.d/99-z2k-tcp.conf:/etc/sysctl.d/99-z2k-tcp.conf:sysctl
config/systemd/z2k-net-tuning.service:/etc/systemd/system/z2k-net-tuning.service:systemd
bin/net-tuning.sh:/opt/z2k-vps/bin/net-tuning.sh:script
config/systemd/z2k-relay.service.d/10-require-per-install.conf:/etc/systemd/system/z2k-relay.service.d/10-require-per-install.conf:systemd
config/journald.conf.d/z2k.conf:/etc/systemd/journald.conf.d/z2k.conf:journald
config/systemd/z2k-asn-update.service:/etc/systemd/system/z2k-asn-update.service:systemd
config/systemd/z2k-asn-update.timer:/etc/systemd/system/z2k-asn-update.timer:timer
config/systemd/z2k-alert.service:/etc/systemd/system/z2k-alert.service:systemd
config/systemd/z2k-alert.timer:/etc/systemd/system/z2k-alert.timer:timer
observability/asn-update.sh:/opt/z2k-vps/observability/asn-update.sh:script
observability/alert.sh:/opt/z2k-vps/observability/alert.sh:script
config/systemd/z2k-relay@.service:/etc/systemd/system/z2k-relay@.service:systemd
config/z2k/relay-a.env:/etc/z2k/relay-a.env:env
config/z2k/relay-b.env:/etc/z2k/relay-b.env:env
bin/relay-switch.sh:/opt/z2k-vps/bin/relay-switch.sh:script
bin/acme-import-from-caddy.sh:/opt/z2k-vps/bin/acme-import-from-caddy.sh:script
config/nginx-http-z2k.conf:/etc/nginx/z2k-http/z2k.conf:nginx
"

[ "$APPLY" = 1 ] || printf 'РЕЖИМ ПРОСМОТРА. Ничего не меняется. Для раскатки: --apply\n\n'

changed_nginx=0; changed_sysctl=0; changed_systemd=0; changed_journald=0; changed_timer=0; changed=0
for p in $PAIRS; do
    [ -z "$p" ] && continue
    rel="${p%%:*}"; rest="${p#*:}"; remote_f="${rest%%:*}"; kind="${rest##*:}"
    local_f="$ROOT/$rel"
    [ -f "$local_f" ] || { printf 'НЕТ В РЕПО   %s — пропускаю\n' "$rel"; continue; }

    case " $SECRET_BEARING " in
        *" $rel "*) printf 'только сверка %s (содержит секреты, не раскатывается)\n' "$rel"; continue ;;
    esac
    # Z2K_DEPLOY_SKIP — пути через пробел, которые в этот раз не раскатывать.
    # Нужно, когда файл обязан приехать ВМЕСТЕ с чем-то, чего deploy.sh не
    # возит: drop-in юнита с новыми флагами релея — только с новым бинарником.
    case " ${Z2K_DEPLOY_SKIP:-} " in
        *" $rel "*) printf 'пропуск      %s (Z2K_DEPLOY_SKIP)\n' "$rel"; continue ;;
    esac

    r=$($SSH "cat '$remote_f' 2>/dev/null" | sed -E "$MASK" | shasum -a 256 | cut -d' ' -f1)
    l=$(sed -E "$MASK" "$local_f" | shasum -a 256 | cut -d' ' -f1)
    [ "$r" = "$l" ] && { printf 'без изменений %s\n' "$rel"; continue; }

    changed=$((changed+1))
    printf 'ИЗМЕНИТСЯ    %s -> %s\n' "$rel" "$remote_f"
    [ "$APPLY" = 1 ] || continue

    $SSH "mkdir -p \"\$(dirname '$remote_f')\"; [ -f '$remote_f' ] && cp '$remote_f' '$remote_f.z2kbak' || true"
    $SCP "$local_f" "root@$HOST:$remote_f.new" >/dev/null
    $SSH "mv '$remote_f.new' '$remote_f'"
    case "$kind" in
        script) $SSH "chmod +x '$remote_f'" ;;
        env)    $SSH "chmod 600 '$remote_f'" ;;
    esac
    case "$kind" in
        nginx)  changed_nginx=1 ;;
        sysctl) changed_sysctl=1 ;;
        systemd) changed_systemd=1 ;;
        journald) changed_journald=1 ;;
        timer) changed_systemd=1; changed_timer=1 ;;
    esac
done

if [ "$APPLY" != 1 ]; then
    printf '\nфайлов к изменению: %s\n' "$changed"
    exit 0
fi

printf '\n=== применение\n'

if [ "$changed_nginx" = 1 ]; then
    if $SSH "nginx -t" 2>&1 | grep -q "test is successful"; then
        before=$($SSH "ss -tn state established '( sport = :443 )' | wc -l")
        $SSH "nginx -s reload"; sleep 3
        after=$($SSH "ss -tn state established '( sport = :443 )' | wc -l")
        printf '  nginx перезагружен, соединений на :443 было %s, стало %s\n' "$before" "$after"
    else
        printf '  NGINX НЕ ПРОШЁЛ ПРОВЕРКУ — возвращаю прежний файл\n'
        $SSH "cp /etc/nginx/nginx.conf.z2kbak /etc/nginx/nginx.conf"
        $SSH "nginx -t" 2>&1 | tail -3
        exit 1
    fi
fi

if [ "$changed_sysctl" = 1 ]; then
    $SSH "sysctl -q --system" && printf '  настройки ядра применены\n'
fi

if [ "$changed_systemd" = 1 ]; then
    $SSH "systemctl daemon-reload" && printf '  systemd перечитал юниты\n'
    $SSH "systemctl is-enabled z2k-net-tuning.service >/dev/null 2>&1" \
        || $SSH "systemctl enable --now z2k-net-tuning.service" >/dev/null 2>&1
    $SSH "systemctl restart z2k-net-tuning.service" && printf '  разнос приёма по ядрам переприменён\n'
fi

# Юнит релея перечитан, но НЕ перезапущен: новые флаги вступят в силу при
# следующем перезапуске релея, который делается только в окно (RUNBOOK).
if [ "$changed_journald" = 1 ]; then
    $SSH "systemctl restart systemd-journald" && printf '  journald перезапущен (потолок 256M)\n'
fi
if [ "$changed_timer" = 1 ]; then
    $SSH "systemctl enable --now z2k-asn-update.timer z2k-alert.timer" && printf '  таймеры включены\n'
fi

printf '\n=== сверка после раскатки\n'
sh "$ROOT/bin/verify.sh" "$HOST" | tail -20
