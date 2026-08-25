#!/bin/sh
# Z2K_STUB_PATH — только для тестов: каталог со стабами iptables/ipset/uname
# встаёт перед системным PATH. В проде переменной нет.
export PATH="${Z2K_STUB_PATH:+$Z2K_STUB_PATH:}/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin"

# /opt/etc/ndm/netfilter.d/93-z2k-warp.sh
#
# NDM пересобирает таблицы netfilter на каждом регене (WAN-флап, hotplug,
# смена политики, ребут) и сносит все не свои правила. Для WARP это три
# вещи, и все — наши, потому что интерфейс z2ktunN в NDM не зарегистрирован
# (NDM принимает только тип OpkgTun, см. спек):
#   mangle PREROUTING  — MARK по ipset'ам z2k_warp (dst) и z2k_warp_src (src);
#   mangle FORWARD     — MSS-clamp на z2ktunN;
#   filter FORWARD     — ACCEPT на z2ktunN (политика NDM — DROP на чужие интерфейсы);
#   nat    POSTROUTING — MASQUERADE на z2ktunN.
# Маршрут (`ip rule` / table 989) реген не трогает.
#
# Только пока режим включён: иначе реген воскресил бы маршрутизацию выключенной
# функции. Имя интерфейса — из device.json (его выбирает движок один раз).

# shellcheck disable=SC2154 # type/table приходят из окружения NDM
[ "$type" = "ip6tables" ] && exit 0

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"
DEVICE_JSON="${DEVICE_JSON:-/opt/etc/z2k-warp/device.json}"
WARP_MARK="${WARP_MARK:-0x989}"

[ "$(grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '" ')" = "1" ] || exit 0

iface=$(sed -n 's/.*"iface"[[:space:]]*:[[:space:]]*"\(z2ktun[0-9]*\)".*/\1/p' "$DEVICE_JSON" 2>/dev/null | head -1)
[ -n "$iface" ] || exit 0

# -w обязателен: без него вставка, гоняющаяся с churn'ом NDM, молча падает с EBUSY.
ipt() { iptables -w "$@" 2>/dev/null || iptables "$@" 2>/dev/null; }

# shellcheck disable=SC2154
case "$table" in
    mangle)
        # Только PREROUTING (трафик LAN-клиентов). НЕ OUTPUT: собственный пакет
        # роутера, ушедший в TUN, ломает reply-path и глушит его же доступ к
        # Cloudflare/GitHub. Форма --set-xmark с маской: --set-mark затирает
        # весь mark-word, включая метки Keenetic.
        for set in "z2k_warp dst" "z2k_warp_src src"; do
            name=${set%% *}
            ipset list -n "$name" >/dev/null 2>&1 || continue
            # shellcheck disable=SC2086 # $set — два аргумента, разбиение намеренно
            ipt -t mangle -C PREROUTING -m set --match-set $set -j MARK --set-xmark "$WARP_MARK/$WARP_MARK" \
                || ipt -t mangle -A PREROUTING -m set --match-set $set -j MARK --set-xmark "$WARP_MARK/$WARP_MARK"
        done
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
        ipt -t filter -C FORWARD -o "$iface" -j ACCEPT \
            || ipt -t filter -A FORWARD -o "$iface" -j ACCEPT
        ;;
esac
exit 0
