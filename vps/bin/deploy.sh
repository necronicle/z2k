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
SECRET_BEARING="config/systemd/z2k-relay.service config/systemd/z2k-relay.service.d/10-require-per-install.conf"

PAIRS="
config/nginx.conf:/etc/nginx/nginx.conf:nginx
config/Caddyfile:/etc/caddy/Caddyfile:caddy
config/sysctl.d/99-z2k-relay.conf:/etc/sysctl.d/99-z2k-relay.conf:sysctl
config/sysctl.d/99-z2k-tcp.conf:/etc/sysctl.d/99-z2k-tcp.conf:sysctl
config/systemd/z2k-net-tuning.service:/etc/systemd/system/z2k-net-tuning.service:systemd
bin/net-tuning.sh:/opt/z2k-vps/bin/net-tuning.sh:script
"

[ "$APPLY" = 1 ] || printf 'РЕЖИМ ПРОСМОТРА. Ничего не меняется. Для раскатки: --apply\n\n'

changed_nginx=0; changed_caddy=0; changed_sysctl=0; changed_systemd=0; changed=0
for p in $PAIRS; do
    [ -z "$p" ] && continue
    rel="${p%%:*}"; rest="${p#*:}"; remote_f="${rest%%:*}"; kind="${rest##*:}"
    local_f="$ROOT/$rel"
    [ -f "$local_f" ] || { printf 'НЕТ В РЕПО   %s — пропускаю\n' "$rel"; continue; }

    case " $SECRET_BEARING " in
        *" $rel "*) printf 'только сверка %s (содержит секреты, не раскатывается)\n' "$rel"; continue ;;
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
    esac
    case "$kind" in
        nginx)  changed_nginx=1 ;;
        caddy)  changed_caddy=1 ;;
        sysctl) changed_sysctl=1 ;;
        systemd) changed_systemd=1 ;;
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

if [ "$changed_caddy" = 1 ]; then
    if $SSH "caddy validate --config /etc/caddy/Caddyfile" >/dev/null 2>&1; then
        $SSH "systemctl reload caddy" && printf '  caddy перезагружен\n'
    else
        printf '  CADDY НЕ ПРОШЁЛ ПРОВЕРКУ — возвращаю прежний файл\n'
        $SSH "cp /etc/caddy/Caddyfile.z2kbak /etc/caddy/Caddyfile"
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

printf '\n=== сверка после раскатки\n'
sh "$ROOT/bin/verify.sh" "$HOST" | tail -20
