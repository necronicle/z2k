#!/bin/sh
# Delivered to this live NDM directory by the release install_map.
# Z2K_STUB_PATH — только для тестов: каталог со стабами iptables/ipset/uname
# встаёт перед системным PATH. В проде переменной нет.
export PATH="${Z2K_STUB_PATH:+$Z2K_STUB_PATH:}/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin"

# /opt/etc/ndm/netfilter.d/93-z2k-warp.sh
#
# NDM пересобирает таблицы netfilter на каждом регене (WAN-флап, hotplug,
# смена политики, ребут) и сносит все не свои правила. Для WARP это три
# вещи (в iptables и, при IPv6 у аккаунта, в ip6tables), и все — наши, потому что интерфейс z2ktunN в NDM не зарегистрирован
# (NDM принимает только тип OpkgTun, см. спек):
#   mangle PREROUTING  — MARK по ipset'ам z2k_warp (dst) и z2k_warp_src (src);
#   mangle FORWARD     — MSS-clamp на z2ktunN;
#   filter FORWARD     — узкие ACCEPT до раннего REJECT Keenetic;
#   nat    POSTROUTING — MASQUERADE на z2ktunN.
# Маршрут (`ip rule` / table 989) реген не трогает.
#
# Только пока режим включён: иначе реген воскресил бы маршрутизацию выключенной
# функции. Имя интерфейса — из device.json (его выбирает движок один раз).

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"
DEVICE_JSON="${DEVICE_JSON:-/opt/etc/z2k-warp/device.json}"
WARP_MARK="${WARP_MARK:-0x989}"
SYS_CLASS_NET="${SYS_CLASS_NET:-/sys/class/net}"

[ "$(grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '" ')" = "1" ] || exit 0

iface=$(sed -n 's/.*"iface"[[:space:]]*:[[:space:]]*"\(z2ktun[0-9]*\)".*/\1/p' "$DEVICE_JSON" 2>/dev/null | head -1)
[ -n "$iface" ] || exit 0

# -w обязателен: без него вставка, гоняющаяся с churn'ом NDM, молча падает с EBUSY.
# shellcheck disable=SC2154 # type/table приходят из окружения NDM
if [ "$type" = "ip6tables" ]; then
    ipt() { ip6tables -w "$@" 2>/dev/null || ip6tables "$@" 2>/dev/null; }
else
    ipt() { iptables -w "$@" 2>/dev/null || iptables "$@" 2>/dev/null; }
fi

# Ответы DNS — в очередь наблюдателя warpd, в обоих семействах: устройства с
# IPv6 спрашивают DNS роутера по IPv6, и A-записи тоже. warpd отпускает ответ,
# когда его адреса уже в наборах (см. z2k-warp.sh, WARP_DNS_QUEUE); ядро без
# NFQUEUE — копия NFLOG. Вставка перед ранним ESTABLISHED/RELATED ACCEPT NDM:
# в конце цепочки большинство пересланных ответов не видно.
DNS_QUEUE="NFQUEUE --queue-num 189 --queue-bypass"
DNS_COPY="NFLOG --nflog-group 189 --nflog-range 4096"
dns_capture() {
    wdtt_ifaces=$(sh "${WARP_SCRIPT:-$ZAPRET2_DIR/z2k-warp.sh}" wdtt-ifaces) || return 1
    for out in br+ nwg+ $wdtt_ifaces; do
        for ch in OUTPUT FORWARD; do
            for proto in udp tcp; do
                m="-o $out -p $proto --sport 53"
                [ "$ch" = FORWARD ] && m="$m -m conntrack --ctstate ESTABLISHED"
                # shellcheck disable=SC2086 # fixed generated rule arguments
                if ipt -t filter -C "$ch" $m -j $DNS_QUEUE || ipt -t filter -I "$ch" $m -j $DNS_QUEUE; then
                    # Не больше 8 копий: неверный ответ -C не должен вешать хук.
                    i=0
                    while [ "$i" -lt 8 ] && ipt -t filter -C "$ch" $m -j $DNS_COPY; do
                        ipt -t filter -D "$ch" $m -j $DNS_COPY || break
                        i=$((i + 1))
                    done
                else
                    ipt -t filter -C "$ch" $m -j $DNS_COPY || ipt -t filter -I "$ch" $m -j $DNS_COPY
                fi
            done
        done
    done
}

# IPv6: у аккаунта WARP есть адрес /128 (addr_v6), туннель возит IPv6 через
# NAT66. Те же вещи, что в IPv4, своим ip6tables; MSS — по MTU туннеля минус
# 40 байт IPv6 и 20 TCP (движок: MTU-60). Без адреса IPv6 — только ответы DNS.
addr6=$(sed -n 's/.*"addr_v6"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F:]*\)".*/\1/p' "$DEVICE_JSON" 2>/dev/null | head -1)
if [ "$type" = "ip6tables" ]; then
    # shellcheck disable=SC2154
    case "$table" in
        filter)
            dns_capture || exit 1
            [ -n "$addr6" ] || exit 0
            ipt -t filter -C FORWARD -o "$iface" -m mark --mark "$WARP_MARK/$WARP_MARK" -j ACCEPT \
                || ipt -t filter -I FORWARD 1 -o "$iface" -m mark --mark "$WARP_MARK/$WARP_MARK" -j ACCEPT
            ipt -t filter -C FORWARD -i "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
                || ipt -t filter -I FORWARD 1 -i "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            ;;
        mangle)
            [ -n "$addr6" ] || exit 0
            WARP_DEVICE="$DEVICE_JSON" sh "${WARP_SCRIPT:-$ZAPRET2_DIR/z2k-warp.sh}" policy-sync || exit 1
            ipt -t mangle -C FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu \
                || ipt -t mangle -A FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
            ipt -t mangle -C FORWARD -i "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 \
                || ipt -t mangle -A FORWARD -i "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
            ;;
        nat)
            [ -n "$addr6" ] || exit 0
            ipt -t nat -C POSTROUTING -o "$iface" -j MASQUERADE \
                || ipt -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
            ;;
    esac
    exit 0
fi

# shellcheck disable=SC2154
case "$table" in
    mangle)
        # Use exactly the live policy: destination AND selected source,
        # including DNS rules. Never resurrect pre-86.5 whole-device marks.
        WARP_DEVICE="$DEVICE_JSON" sh "${WARP_SCRIPT:-$ZAPRET2_DIR/z2k-warp.sh}" policy-sync || exit 1
        # MSS ЗАЖИМАЕМ В ОБЕ СТОРОНЫ, и второе правило не зеркально первому.
        #
        # Замер на роутере владельца 2026-08-25, живой трафик телефона:
        #   SYN     клиент -> в туннель  : mss 1240  (140 из 140 — зажат)
        #   SYN-ACK сервер -> из туннеля : mss 1460  (140 из 140 — НЕ зажат)
        # Клиенту разрешалось слать в туннель с MTU 1280 сегменты по 1460:
        # скачивание шло, а всё, что он ОТПРАВЛЯЕТ крупнее 1240 байт,
        # обрывалось. В поле — «карты не грузятся, hh падает».
        #
        # Зеркальное правило не годится: SYN-ACK уходит через мост с MTU 1500,
        # и clamp-mss-to-pmtu дал бы там те же 1460. Нужен явный set-mss по MTU
        # туннеля: 1280 - 20 (IP) - 20 (TCP). Прошивка для своего ppp0 ставит
        # зажим в обе стороны — мы делали в одну.
        #
        # Число здесь ДОЛЖНО совпадать с engine.MTU-40 в движке; за этим следит
        # tests/test_warp_mss_both_ways.sh.
        ipt -t mangle -C FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu \
            || ipt -t mangle -A FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        ipt -t mangle -C FORWARD -i "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 \
            || ipt -t mangle -A FORWARD -i "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
        ;;
    nat)
        ipt -t nat -C POSTROUTING -o "$iface" -j MASQUERADE \
            || ipt -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
        ;;
    filter)
        dns_capture || exit 1
        # У некоторых Keenetic CONNNDMMARK REJECT стоит ДО штатного
        # ESTABLISHED ACCEPT. Без этих правил SYN-ACK виден в TUN, но не
        # возвращается клиенту. Исходящий поток обязан иметь нашу метку;
        # из TUN пропускаем только ответ существующего соединения.
        ipt -t filter -C FORWARD -o "$iface" -m mark --mark "$WARP_MARK/$WARP_MARK" -j ACCEPT \
            || ipt -t filter -I FORWARD 1 -o "$iface" -m mark --mark "$WARP_MARK/$WARP_MARK" -j ACCEPT
        ipt -t filter -C FORWARD -i "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
            || ipt -t filter -I FORWARD 1 -i "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ;;
esac
exit 0
