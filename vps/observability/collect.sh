#!/bin/sh
# vps/observability/collect.sh — снять сигналы узла.
#
# Не графики, а сигналы: каждая строка отвечает на вопрос «надо ли вмешиваться».
# Считается ПО ОКНУ, а не по счётчику с момента загрузки: счётчик с аптаймом в
# полгода ничего не говорит о сейчас. Именно на этом уже обожглись — 1118
# отброшенных SYN выглядели тревожно, пока не выяснилось, что это 0.016% за всю
# жизнь машины.
#
# Использование:
#   sh vps/observability/collect.sh          — окно 60 с
#   sh vps/observability/collect.sh 300      — окно 5 мин
set -e
WIN="${1:-60}"
HOST="${Z2K_VPS_HOST:-213.176.74.63}"
KEY="${Z2K_VPS_KEY:-$HOME/.ssh/z2k_vps_ed25519}"

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$KEY" "root@$HOST" "WIN=$WIN bash -s" <<'REMOTE'
set -e
get() { nstat -az 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }
snap() {
    printf '%s %s %s %s %s\n' \
        "$(get TcpExtTCPReqQFullDrop)" "$(get TcpExtListenOverflows)" \
        "$(get TcpExtSyncookiesSent)" "$(get TcpActiveOpens)" "$(get TcpPassiveOpens)"
}
a=$(snap); t0=$(date +%s); sleep "$WIN"; b=$(snap); t1=$(date +%s); d=$((t1-t0))

set -- $a; a1=$1 a2=$2 a3=$3 a4=$4 a5=$5
set -- $b; b1=$1 b2=$2 b3=$3 b4=$4 b5=$5

echo "=== окно ${d} с, $(date '+%Y-%m-%d %H:%M:%S')"
printf 'подключений принято      %s (%.1f/с)\n' "$((b5-a5))" "$(echo "$((b5-a5)) $d" | awk '{print $1/$2}')"
printf 'подключений исходящих    %s (%.1f/с)\n' "$((b4-a4))" "$(echo "$((b4-a4)) $d" | awk '{print $1/$2}')"

# Три сигнала отказа. Ноль — норма; любое ненулевое значение объясняется.
printf 'SYN потеряно             %s%s\n' "$((b1-a1))" \
    "$([ $((b1-a1)) -gt 0 ] && echo '   <-- очередь рукопожатий переполнялась')"
printf 'очередь приёма перепол.  %s%s\n' "$((b2-a2))" \
    "$([ $((b2-a2)) -gt 0 ] && echo '   <-- приложение не успевает accept(), это уже не ядро')"
printf 'syncookies выдано        %s%s\n' "$((b3-a3))" \
    "$([ $((b3-a3)) -gt 0 ] && echo '   <-- всплеск был, но пережит: предохранитель сработал')"

echo
echo "--- соединения"
printf 'на :443            %s\n' "$(ss -tn state established '( sport = :443 )' | wc -l)"
printf 'у релея            %s\n' "$(ss -tn state established '( sport = :8080 )' | wc -l)"
printf 'полуоткрытых       %s   (много при неотвеченных SYN — признак сканера)\n' "$(ss -tn state syn-recv | wc -l)"

echo
echo "--- ресурсы"
printf 'load               %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
printf 'память             %s\n' "$(free -m | awk '/^Mem:/{printf "%d из %d МБ", $3, $2}')"
for s in z2k-vps-relay caddy nginx; do
    p=$(pgrep -f "$s" | head -1)
    [ -n "$p" ] && printf '%-18s RSS %s МБ\n' "$s" "$(( $(awk '/VmRSS/{print $2}' /proc/$p/status) / 1024 ))"
done
printf 'приём по ядрам     %s\n' "$(awk '{printf "cpu%d=%d ", NR-1, strtonum("0x"$1)}' /proc/net/softnet_stat)"

echo
echo "--- перезапуски служб (не должно расти само)"
for s in nginx caddy z2k-relay z2k-stats-collector; do
    printf '%-22s %s\n' "$s" "$(systemctl show "$s" -p NRestarts --value 2>/dev/null)"
done
REMOTE
