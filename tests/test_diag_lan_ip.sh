#!/bin/sh
# tests/test_diag_lan_ip.sh — «LAN IP» в диагностике это адрес домашней сети.
#
# ЗАЧЕМ. Жалоба из поля 2026-08-25: у человека IPoE, провайдер выдал роутеру
# СЕРЫЙ адрес, и в отчёте стояло «LAN IP: 192.168.100.10» — адрес WAN под
# именем LAN. Настоящий адрес домашней сети был другой.
#
# Прежний отбор брал ПЕРВЫЙ адрес из 10/8, 172.16/12 или 192.168/16, полагая,
# что приватный бывает только у LAN. На IPoE это неверно, и интерфейс аплинка
# стоит в списке раньше моста.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM
mkdir -p "$SB/bin"

# Подставной `ip`: отдаёт то, что описывает конкретный случай.
mk_ip() {
    cat > "$SB/bin/ip" <<STUB
#!/bin/sh
case "\$*" in
    *"route get"*) printf '%s\n' "$2" ;;
    *"addr show"*) cat <<'ADDR'
$1
ADDR
        ;;
esac
STUB
    chmod +x "$SB/bin/ip"
}

lan_ip() { PATH="$SB/bin:$PATH" sh -c "$(sed -n '/^get_lan_ip/,/^}/p' "$ROOT/files/z2k-diag.sh"); get_lan_ip"; }

# --- Случай из поля: IPoE, WAN с серым адресом идёт первым -------------------
mk_ip '2: eth3: <BROADCAST> mtu 1500
    inet 192.168.100.10/24 brd 192.168.100.255 scope global eth3
3: br0: <BROADCAST> mtu 1500
    inet 192.168.10.1/24 brd 192.168.10.255 scope global br0' \
'1.1.1.1 dev eth3  src 192.168.100.10 '
assert_eq "серый WAN не выдаётся за LAN" "192.168.10.1" "$(lan_ip)"

# --- Обычный случай: публичный WAN ------------------------------------------
mk_ip '3: br0: <BROADCAST> mtu 1500
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0
4: br1: <BROADCAST> mtu 1500
    inet 10.1.30.1/24 brd 10.1.30.255 scope global br1' \
'1.1.1.1 dev ppp0  src 88.87.93.11 '
assert_eq "при публичном WAN берём мост" "192.168.1.1" "$(lan_ip)"

# --- Туннель WARP не должен побеждать мост ----------------------------------
mk_ip '5: z2ktun0: <POINTOPOINT> mtu 1280
    inet 172.16.0.2/32 scope global z2ktun0
6: br0: <BROADCAST> mtu 1500
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br0' \
'1.1.1.1 dev ppp0  src 88.87.93.11 '
assert_eq "туннель не выдаётся за домашнюю сеть" "192.168.1.1" "$(lan_ip)"

# --- Домашней сети не нашлось: не врём, а говорим прямо ----------------------
mk_ip '2: eth3: <BROADCAST> mtu 1500
    inet 192.168.100.10/24 brd 192.168.100.255 scope global eth3' \
'1.1.1.1 dev eth3  src 192.168.100.10 '
if lan_ip | grep -q 'домашней сети не нашлось'; then
    ok "без домашней сети сказано прямо, а не «LAN»"
else
    no "без домашней сети сказано прямо" "оговорка" "$(lan_ip)"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
