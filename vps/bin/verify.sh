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

# ОЧЕРЕДЬ ПРИЁМА. Проверяется тремя вопросами, потому что ломается она тремя
# разными способами, и первый из них однажды уже стоил людям установки.
#
# Поле 31.08.2026: TCPReqQFullDrop = 1118 при ListenOverflows = 0. Переполнялась
# SYN-очередь, SYN-ы выбрасывались молча, человек видел «000, 0 байт, 30 секунд»
# и винил GitHub. Причина — не плохое число, а ОТСУТСТВУЮЩЕЕ: у `listen` не было
# `backlog=`, nginx взял умолчание 511, и системный somaxconn 8192 не значил
# ничего, потому что длина берётся как min(backlog, somaxconn) в момент listen().
#
# Значение чинит сегодняшний день, проверка — завтрашний: любой НОВЫЙ listen,
# добавленный без backlog=, вернёт ту же поломку.
printf '\n=== очередь приёма\n'

# 1. Статически: в конфиге репозитория у каждого listen должен быть backlog.
#    Ловится ДО раскатки, на любом новом слушателе.
noback=$(awk '/^[[:space:]]*listen[[:space:]]/ && !/backlog=/ && !/unix:/ { gsub(/^[ \t]+|;$/,""); print "                 " $0 }' \
    "$ROOT/config/nginx.conf" 2>/dev/null)
if [ -n "$noback" ]; then
    printf '  БЕЗ BACKLOG  в config/nginx.conf есть listen без backlog= — очередь будет 511:\n'
    printf '%s\n' "$noback"
    drift=$((drift+1))
else
    printf '  задан        у всех listen в конфиге репозитория есть backlog=\n'
fi

# 2. По факту: унаследованный при reload сокет мог не подхватить правку, и
#    тогда в конфиге всё верно, а в ядре по-прежнему 511.
#
#    Сверяем ПОПОРТОВО с тем, что запрошено в конфиге, а не с общим порогом.
#    Общий порог кричал на tinyproxy (:8119, очередь 1024) — у него MaxClients
#    50, больше пятидесяти клиентов не бывает по построению, и тысяча в очереди
#    ему избыточна в двадцать раз. Проверка, которая ругается на исправную
#    машину, перестаёт читаться, и настоящую поломку в ней уже не замечают.
want_ports=$(awk '/^[[:space:]]*listen[[:space:]]/ && /backlog=/ {
        port = ""; back = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^backlog=/) { back = substr($i, 9); sub(/;$/, "", back) }
        }
        if (match($0, /listen[[:space:]]+[^;]*/)) {
            spec = substr($0, RSTART + 7, RLENGTH - 7)
            gsub(/^[ \t]+/, "", spec)
            n = split(spec, a, /[[:space:]]+/)
            addr = a[1]
            sub(/^\[::\]:/, "", addr); sub(/^[0-9.]+:/, "", addr)
            port = addr
        }
        if (port ~ /^[0-9]+$/ && back != "") print port, back
    }' "$ROOT/config/nginx.conf" 2>/dev/null | sort -u)
live_q=$($SSH "ss -lntH 2>/dev/null" | awk '{ p = $4; sub(/^.*:/, "", p); print p, $3 }' | sort -u)
mismatch=""
printf '%s\n' "$want_ports" | while IFS=' ' read -r port want; do
    [ -n "$port" ] || continue
    got=$(printf '%s\n' "$live_q" | awk -v p="$port" '$1 == p {print $2; exit}')
    [ -n "$got" ] || continue
    [ "$got" -ge "$want" ] && continue
    printf '                 порт %s: в конфиге backlog=%s, в ядре %s\n' "$port" "$want" "$got"
done > /tmp/z2k-verify-q.$$
mismatch=$(cat /tmp/z2k-verify-q.$$); rm -f /tmp/z2k-verify-q.$$
if [ -n "$mismatch" ]; then
    printf '  НЕ ПОДХВАЧЕН backlog из конфига не доехал до ядра (нужен рестарт, не reload):\n'
    printf '%s\n' "$mismatch"
    drift=$((drift+1))
else
    printf '  применена    у слушателей nginx очередь не меньше запрошенной в конфиге\n'
fi

# 3. По результату: копятся ли потери прямо сейчас. Это единственная проверка,
#    которая видит проблему у ЛЮДЕЙ, а не в настройках.
printf '  замер потерь за 20 секунд...\n'
counts=$($SSH "nstat -az 2>/dev/null | awk '/TcpExtTCPReqQFullDrop|TcpExtListenDrops|TcpExtListenOverflows|TcpPassiveOpens/{print \$1, \$2}' > /tmp/z2kq.a; \
    sleep 20; \
    nstat -az 2>/dev/null | awk '/TcpExtTCPReqQFullDrop|TcpExtListenDrops|TcpExtListenOverflows|TcpPassiveOpens/{print \$1, \$2}' > /tmp/z2kq.b; \
    join /tmp/z2kq.a /tmp/z2kq.b | awk '{print \$1, \$3-\$2}'; rm -f /tmp/z2kq.a /tmp/z2kq.b")
printf '%s\n' "$counts" | while IFS=' ' read -r k d; do
    [ -n "$k" ] || continue
    printf '                 %-28s +%s\n' "$k" "$d"
done
qfull=$(printf '%s\n' "$counts" | awk '/TCPReqQFullDrop/{print $2}')
ovf=$(printf '%s\n' "$counts" | awk '/ListenOverflows/{print $2}')
if [ "${qfull:-0}" -gt 0 ] || [ "${ovf:-0}" -gt 0 ]; then
    printf '  ТЕРЯЕМ SYN   очередь переполняется прямо сейчас — люди получают 30-секундное молчание\n'
    drift=$((drift+1))
else
    printf '  потерь нет   SYN-очередь не переполняется\n'
fi

# 4. Куки — последняя линия. С ними переполнение перестаёт быть смертельным:
#    ядро достраивает рукопожатие без места в очереди. Без них любой всплеск
#    снова превращается в молчание.
cookies=$($SSH "sysctl -n net.ipv4.tcp_syncookies 2>/dev/null")
if [ "$cookies" = "1" ] || [ "$cookies" = "2" ]; then
    printf '  куки        tcp_syncookies=%s — переполнение не приводит к потере\n' "$cookies"
else
    printf '  БЕЗ КУК      tcp_syncookies=%s — любое переполнение снова станет потерей SYN\n' "$cookies"
    drift=$((drift+1))
fi

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

# Релей двумя экземплярами (план 3 v2): ровно один активен, TLS-порт 8445
# слушает релей, сертификат лежит в кеше autocert.
printf '\n=== экземпляры релея и TLS\n'
act=$($SSH "for i in a b; do systemctl is-active --quiet z2k-relay@\$i && printf '%s ' \$i; done")
case "$(echo $act)" in
    a|b) printf '  один активен %s\n' "z2k-relay@$(echo $act)" ;;
    "") if $SSH "systemctl is-active --quiet z2k-relay.service"; then
            printf '  прежняя схема z2k-relay.service (до первого relay-switch.sh)\n'
        else
            printf '  НИКТО       ни один экземпляр релея не активен\n'; drift=$((drift+1))
        fi ;;
    *) printf '  ОБА          активны a и b — переключение не завершено\n'; drift=$((drift+1)) ;;
esac
if $SSH "ss -Hltnp 2>/dev/null | grep -q '127.0.0.1:8445.*z2k-vps-relay'"; then
    printf '  8445         слушает релей (TLS)\n'
else
    printf '  8445         релей не слушает — трафик имени идёт мимо (или ещё caddy)\n'
fi
if $SSH "test -s /var/lib/z2k-relay/acme/213.176.74.63.nip.io"; then
    printf '  сертификат   в кеше autocert: %s\n' "$($SSH "openssl x509 -in /var/lib/z2k-relay/acme/213.176.74.63.nip.io -noout -enddate 2>/dev/null")"
else
    printf '  сертификат   кеш autocert пуст — до релиза TLS-фронта импортировать из caddy\n'
fi

printf '\n'
if [ "$drift" = 0 ]; then
    printf 'РАСХОЖДЕНИЙ НЕТ\n'
else
    printf 'РАСХОЖДЕНИЙ: %s — сперва решите, чья версия верна, потом правьте\n' "$drift"
fi
exit 0
