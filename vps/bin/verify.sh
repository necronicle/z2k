#!/bin/sh
# vps/bin/verify.sh — сверка живого узла с репозиторием.
#
# Зачем. Конфигурация узла год правилась руками прямо на машине: копия в
# репозитории разошлась с живой (31.08.2026 — 47 строк расхождения в nginx.conf
# и 1 в Caddyfile), и никто об этом не знал. Пока расхождение не видно, любая
# раскатка — лотерея: она либо затрёт чужую правку, либо не применит свою.
#
# Скрипт НИЧЕГО не меняет. Он отвечает на один вопрос: совпадает ли то, что
# работает, с тем, что записано. Запускать перед каждой правкой и после неё.
#
# Использование: sh vps/bin/verify.sh [хост]
set -e
HOST="${1:-${Z2K_VPS_HOST:-213.176.74.63}}"
KEY="${Z2K_VPS_KEY:-$HOME/.ssh/z2k_vps_ed25519}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 -i $KEY root@$HOST"

# путь_в_репозитории:путь_на_узле
#
# /etc/sysctl.conf здесь не случайно: он применяется ПОСЛЕ всего каталога
# sysctl.d и потому молча перекрывает наши файлы. Пока он не был под присмотром,
# выставленный нами syncookies=1 не действовал, и это было не видно ничем.
PAIRS="
config/nginx.conf:/etc/nginx/nginx.conf
config/Caddyfile:/etc/caddy/Caddyfile
config/sysctl.d/99-z2k-relay.conf:/etc/sysctl.d/99-z2k-relay.conf
config/sysctl.d/99-z2k-tcp.conf:/etc/sysctl.d/99-z2k-tcp.conf
config/sysctl.conf:/etc/sysctl.conf
config/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf
config/systemd/z2k-relay.service:/etc/systemd/system/z2k-relay.service
config/systemd/z2k-relay.service.d/10-require-per-install.conf:/etc/systemd/system/z2k-relay.service.d/10-require-per-install.conf
config/systemd/z2k-stats-collector.service:/etc/systemd/system/z2k-stats-collector.service
config/systemd/z2k-net-tuning.service:/etc/systemd/system/z2k-net-tuning.service
bin/net-tuning.sh:/opt/z2k-vps/bin/net-tuning.sh
"

# Секреты в репозитории заменены на <СЕКРЕТ>. Чтобы сверка при этом осталась
# осмысленной, ОДНА И ТА ЖЕ маска накладывается на обе стороны: сравнивается
# структура команды запуска, а не значения ключей. Сами ключи проверяются
# отдельно — тем, что их не должно быть видно в /proc/<pid>/cmdline.
MASK='s/(--secret|--secret-prev|--resolve-secret|--admin-token)=[^ "]*/\1=<СЕКРЕТ>/g; s/^(BasicAuth[[:space:]]+[^[:space:]]+[[:space:]]+).*$/\1<СЕКРЕТ>/'

drift=0
printf '=== файлы конфигурации\n'
for p in $PAIRS; do
    [ -z "$p" ] && continue
    local_f="$ROOT/${p%%:*}"; remote_f="${p##*:}"
    [ -f "$local_f" ] || { printf '  НЕТ В РЕПО   %s\n' "${p%%:*}"; drift=$((drift+1)); continue; }
    r=$($SSH "cat '$remote_f' 2>/dev/null" | sed -E "$MASK" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    l=$(sed -E "$MASK" "$local_f" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    if [ "$r" = "$l" ]; then
        printf '  совпадает    %s\n' "${p%%:*}"
    else
        printf '  РАСХОЖДЕНИЕ  %s\n' "${p%%:*}"
        drift=$((drift+1))
    fi
done

# Настройки ядра сверяем ПО ФАКТУ, а не по файлу: файл может лежать правильный,
# а значение — не применённое (не было `sysctl --system` после правки).
printf '\n=== настройки ядра: файл против факта\n'
for f in "$ROOT"/config/sysctl.d/*.conf; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        k=$(printf '%s' "$line" | cut -d= -f1 | tr -d ' ')
        v=$(printf '%s' "$line" | cut -d= -f2- | tr -d ' ')
        [ -n "$k" ] || continue
        live=$($SSH "sysctl -n $k 2>/dev/null" | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')
        want=$(printf '%s' "$v" | tr -s ' \t' ' ')
        if [ "$live" = "$want" ]; then
            printf '  применён     %s = %s\n' "$k" "$live"
        else
            printf '  НЕ ПРИМЕНЁН  %s: в файле %s, на машине %s\n' "$k" "$want" "$live"
            drift=$((drift+1))
        fi
    done < "$f"
done

# Очередь приёма — самый частый источник «настроил, но не применилось»: правка
# listen требует reload, а унаследованный сокет может её не подхватить.
printf '\n=== фактическая очередь приёма (Send-Q у слушателей)\n'
$SSH "ss -lntH 2>/dev/null | awk '{print \"  \" \$4 \" backlog \" \$3}'" | sort -u | head -12

# Приём пакетов: у vNIC одна аппаратная очередь, поэтому без RPS всё
# входящее обрабатывается одним ядром. Настройка живёт в sysfs и слетает
# при перезагрузке — проверяем факт, а не наличие юнита.
printf '\n=== разнос приёма по ядрам\n'
rps=$($SSH "cat /sys/class/net/\$(ip route show default | awk '/default/{print \$5; exit}')/queues/rx-0/rps_cpus 2>/dev/null")
ncpu=$($SSH "nproc")
want_mask=$(printf '%x' $(( (1 << ncpu) - 1 )))
if [ "$(printf '%s' "$rps" | tr -d ',0' )" = "" ] && [ "$want_mask" != "0" ]; then
    printf '  ВЫКЛЮЧЕН     rps_cpus=%s — приём идёт в один поток\n' "$rps"
    drift=$((drift+1))
else
    printf '  включён      rps_cpus=%s (ядер %s)\n' "$rps" "$ncpu"
fi

# Секреты не должны лежать в командной строке: её видит любой процесс.
printf '\n=== секреты в командной строке служб\n'
# Ссылка — не утечка. Релей принимает `env:ИМЯ` и `@/путь` и подставляет
# значение сам (vps-relay/secretsrc.go); в командной строке тогда остаётся
# только имя переменной. Ругаться надо на ЛИТЕРАЛ, иначе проверка кричит на
# правильно настроенную машину и её перестают читать.
leaks=$($SSH "tr '\\0' '\\n' < /proc/\$(pgrep -f z2k-vps-relay | head -1)/cmdline 2>/dev/null \
    | grep -E -- '^--(secret|secret-prev|resolve-secret|admin-token)=' \
    | grep -vE '=(env:|@)' | sed -E 's/=.*/=<ЗНАЧЕНИЕ>/'")
if [ -n "$leaks" ]; then
    printf '  ВИДНЫ        секреты значением в /proc/<pid>/cmdline:\n'
    printf '%s\n' "$leaks" | sed 's/^/                 /'
    drift=$((drift+1))
else
    printf '  чисто        секреты передаются ссылкой, значений в командной строке нет\n'
fi

printf '\n'
if [ "$drift" = 0 ]; then
    printf 'РАСХОЖДЕНИЙ НЕТ\n'
else
    printf 'РАСХОЖДЕНИЙ: %s — сперва решите, чья версия верна, потом правьте\n' "$drift"
fi
exit 0
