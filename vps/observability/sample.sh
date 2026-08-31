#!/bin/sh
# vps/observability/sample.sh — поминутный срез узла в файл.
#
# ЗАЧЕМ. Всплески на узле мы видим только по счётчику с момента загрузки, а он
# отвечает «за полгода потеряно 1118 SYN» и ничего не говорит про КОГДА. Пока
# нет поминутного ряда, спор «наш флот вернулся разом» против «сканер с мёртвых
# адресов» неразрешим — а правки под эти две причины РАЗНЫЕ.
#
# Различает их форма кривой, а не сам факт потерь:
#   волна своих   — широкий горб, дропы идут ВМЕСТЕ с ростом принятых,
#                   полуоткрытых мало (рукопожатия достраиваются);
#   сканер        — узкий всплеск, полуоткрытых сотни при почти нулевом росте
#                   принятых (рукопожатия не достраиваются никогда).
#
# Стоимость: одна строка в минуту, четыре чтения из /proc. Файл ротируется по
# размеру, на диск не давит.
set -e
OUT="${1:-/var/log/z2k-vps-samples.tsv}"
MAX_KB="${Z2K_SAMPLE_MAX_KB:-4096}"

get() { nstat -az 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }

[ -s "$OUT" ] || printf 'время\tпринято/мин\tисходящих/мин\tSYN_потеряно\tочередь_перепол\tsyncookies\tполуоткрытых\tадресов_среди_них\tна_443\tтуннелей\n' > "$OUT"

p_acc=$(get TcpPassiveOpens); p_act=$(get TcpActiveOpens)
p_drop=$(get TcpExtTCPReqQFullDrop); p_ovf=$(get TcpExtListenOverflows); p_ck=$(get TcpExtSyncookiesSent)

while :; do
    sleep 60
    acc=$(get TcpPassiveOpens); act=$(get TcpActiveOpens)
    drop=$(get TcpExtTCPReqQFullDrop); ovf=$(get TcpExtListenOverflows); ck=$(get TcpExtSyncookiesSent)
    # Число УНИКАЛЬНЫХ адресов среди полуоткрытых — то, что отличает волну своих
    # от сканера без всякого гадания. 31.08.2026 всплеск в 1580 рукопожатий
    # пришлось разбирать по косвенному признаку (достроились они или нет),
    # потому что этой колонки не было.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%d %H:%M')" \
        "$((acc - p_acc))" "$((act - p_act))" \
        "$((drop - p_drop))" "$((ovf - p_ovf))" "$((ck - p_ck))" \
        "$(ss -tn state syn-recv 2>/dev/null | wc -l)" \
        "$(ss -tn state syn-recv 2>/dev/null | awk 'NR>1{split($4,a,\":\"); print a[1]}' | sort -u | wc -l)" \
        "$(ss -tn state established '( sport = :443 )' 2>/dev/null | wc -l)" \
        "$(ss -tn state established '( sport = :8443 )' 2>/dev/null | wc -l)" \
        >> "$OUT"
    p_acc=$acc; p_act=$act; p_drop=$drop; p_ovf=$ovf; p_ck=$ck
    # Ротация по размеру: ряд нужен свежий, архив за полгода никому не сдался.
    if [ "$(du -k "$OUT" 2>/dev/null | cut -f1)" -gt "$MAX_KB" ]; then
        tail -n 2000 "$OUT" > "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
    fi
done
