#!/bin/sh
# tests/test_warp_script.sh — z2k-warp.sh как тонкая обвязка над z2k-warpd.
#
# Скрипт больше не регистрирует, не пробует и не лечит туннель — это делает
# движок. Контракт, который держат тесты:
#   install  — бинарь на место + register; ничего не запускает;
#   enable   — флаг=1, ipset'ы, S51 start, ждёт ready, маршрут; rc 0/2/1;
#   disable  — маршрут снять, S51 stop, флаг=0;
#   remove   — disable + бинарь удалён, device.json остаётся;
#   selfheal — маршрут ставится/снимается по status.json;
#   status   — одна строка key=value;
#   migrate  — разовая зачистка usque.
# Всё через стабы в $SB/bin (Z2K_STUB_PATH). POSIX sh.
TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/z2k/lists/warp/games" "$SB/etc" "$SB/sbin" "$SB/tmp"
cp "$SCRIPT_DIR/files/z2k-warp.sh" "$SB/z2k/z2k-warp.sh"

# --- стабы ---
# iptables с памятью: -A добавляет правило в ipt.rules, -D убирает, -C проверяет.
cat > "$SB/bin/iptables" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/ipt.log"
rule=\$(echo "\$*" | sed 's/ -[ACD] / /')
case "\$*" in
    *" -C "*) grep -qxF -- "\$rule" "$SB/ipt.rules" 2>/dev/null; exit \$? ;;
    *" -A "*) echo "\$rule" >> "$SB/ipt.rules" ;;
    *" -D "*) grep -vxF -- "\$rule" "$SB/ipt.rules" > "$SB/ipt.rules.n" 2>/dev/null; mv -f "$SB/ipt.rules.n" "$SB/ipt.rules" ;;
esac
exit 0
EOF
cat > "$SB/bin/ip" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/ip.log"
case "\$*" in
    "rule show"*) cat "$SB/rules" 2>/dev/null ;;
    "rule add"*) echo "\$*" >> "$SB/rules" ;;
    "rule del"*) : > "$SB/rules" ;;
    "neigh show"*) cat "$SB/neigh" 2>/dev/null ;;
esac
exit 0
EOF
cat > "$SB/bin/ipset" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/ipset.log"
case "\$1" in
    restore) cat >> "$SB/ipset.log" ;;
    list) case "\$*" in *z2k_warp*|*nozapret*) echo "Members:"; exit 0 ;; esac; exit 1 ;;
esac
exit 0
EOF
cat > "$SB/bin/z2k-warpd-stub" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/warpd.log"
case "\$1" in
    register) [ -f "$SB/reg.fail" ] && { echo "register_blocked boom" >&2; exit 1; }; echo '{"id":"dev"}' > "$SB/etc/device.json"; exit 0 ;;
    version) echo "z2k-warpd test" ;;
esac
exit 0
EOF
cat > "$SB/bin/S51" <<EOF
#!/bin/sh
echo "\$1" >> "$SB/s51.log"
case "\$1" in
    start) touch "$SB/s51.running" ;;
    stop)  rm -f "$SB/s51.running" ;;
    status) [ -f "$SB/s51.running" ] ;;
esac
EOF
chmod +x "$SB"/bin/*
printf 'GAME_WARP_ENABLED=0\n' > "$SB/z2k/config"
printf '{"iface":"z2ktun0","id":"dev","endpoint":{"v4":"8.6.112.0","h2":"162.159.198.2"}}\n' > "$SB/etc/device.json"
printf '1.2.3.0/24\n' > "$SB/z2k/lists/warp/my.txt"

W() { # запуск скрипта с окружением песочницы
    Z2K_STUB_PATH="$SB/bin" ZAPRET2_DIR="$SB/z2k" CONFIG_FILE="$SB/z2k/config" \
    WARP_BIN="$SB/sbin/z2k-warpd" WARP_INIT="$SB/bin/S51" WARP_DEVICE="$SB/etc/device.json" \
    WARP_STATUS="$SB/tmp/status.json" WARP_LISTS_DIR="$SB/z2k/lists/warp" WARP_READY_WAIT=1 \
    WARP_FETCH_STUB="$SB/bin/z2k-warpd-stub" \
    sh "$SB/z2k/z2k-warp.sh" "$@"
}
flag() { sed -n 's/^GAME_WARP_ENABLED=//p' "$SB/z2k/config" | tr -d '"'; }
ready() { printf '{"ready":%s,"transport":"wg","endpoint":"8.6.112.0:2408","iface":"z2ktun0","addr":"172.16.0.2","last_error":"%s","rx":1,"tx":1,"handshake_age":3}\n' "$1" "$2" > "$SB/tmp/status.json"; }
clearlogs() { rm -f "$SB"/*.log "$SB/rules"; }   # ipt.rules — состояние, не лог: не чистим

# ---------- install ----------
rc=0; W install >/dev/null 2>&1 || rc=$?
assert_eq "install: rc 0" "0" "$rc"
assert_eq "install: binary placed" "yes" "$([ -x "$SB/sbin/z2k-warpd" ] && echo yes || echo no)"
assert_eq "install: register called" "1" "$(grep -c '^register' "$SB/warpd.log")"
assert_eq "install: does not start the daemon" "0" "$(grep -c start "$SB/s51.log" 2>/dev/null || echo 0)"
touch "$SB/reg.fail"; rm -f "$SB/etc/device.json"
rc=0; out=$(W install 2>&1) || rc=$?
assert_eq "install: register failure → rc 1" "1" "$rc"
assert_eq "install: register failure reported with code" "yes" "$(printf '%s' "$out" | grep -q register_blocked && echo yes || echo no)"
rm -f "$SB/reg.fail"
printf '{"iface":"z2ktun0","id":"dev","endpoint":{"v4":"8.6.112.0","h2":"162.159.198.2"}}\n' > "$SB/etc/device.json"

# ---------- enable (ready) ----------
clearlogs; ready true ""
rc=0; W enable >/dev/null 2>&1 || rc=$?
assert_eq "enable ready: rc 0" "0" "$rc"
assert_eq "enable: flag set" "1" "$(flag)"
assert_eq "enable: S51 started" "1" "$(grep -c '^start' "$SB/s51.log")"
assert_eq "enable: ip rule pref 90 fwmark mask table 989" "1" "$(grep -c 'rule add pref 90 fwmark 0x989/0x989 table 989' "$SB/ip.log")"
assert_eq "enable: route default dev z2ktun0 table 989" "1" "$(grep -c 'route replace default dev z2ktun0 table 989' "$SB/ip.log")"
assert_eq "enable: MARK dst xmark" "1" "$(grep -c -- '-A PREROUTING -m set --match-set z2k_warp dst -j MARK --set-xmark 0x989/0x989' "$SB/ipt.log")"
assert_eq "enable: MARK src xmark" "1" "$(grep -c -- '-A PREROUTING -m set --match-set z2k_warp_src src -j MARK --set-xmark 0x989/0x989' "$SB/ipt.log")"
assert_eq "enable: ipset loaded from user list" "1" "$(grep -c 'add z2k_warp_new 1.2.3.0/24' "$SB/ipset.log")"
assert_eq "enable: MASQUE-эндпоинт НЕ исключается из десинка (измерено: без десинка туннель не несёт трафик)" "0" "$(grep -c 'nozapret' "$SB/ipset.log")"
assert_eq "enable: nothing in OUTPUT" "0" "$(grep -c ' OUTPUT ' "$SB/ipt.log")"

# ---------- enable (not ready) ----------
clearlogs; ready false no_endpoint; W disable >/dev/null 2>&1; clearlogs
rc=0; out=$(W enable 2>&1) || rc=$?
assert_eq "enable not-ready: rc 2" "2" "$rc"
assert_eq "enable not-ready: flag stays 1" "1" "$(flag)"
assert_eq "enable not-ready: reason code on stderr" "1" "$(printf '%s' "$out" | grep -c no_endpoint)"
assert_eq "enable not-ready: no MARK rules" "0" "$(grep -c -- '-A PREROUTING' "$SB/ipt.log" 2>/dev/null || echo 0)"

# ---------- enable (no binary) ----------
clearlogs; W disable >/dev/null 2>&1; clearlogs; mv "$SB/sbin/z2k-warpd" "$SB/sbin/z2k-warpd.off"
rc=0; W enable >/dev/null 2>&1 || rc=$?
assert_eq "enable no-binary: rc 1" "1" "$rc"
assert_eq "enable no-binary: flag reverted" "0" "$(flag)"
mv "$SB/sbin/z2k-warpd.off" "$SB/sbin/z2k-warpd"

# ---------- disable ----------
ready true ""; W enable >/dev/null 2>&1; clearlogs
W disable >/dev/null 2>&1
assert_eq "disable: S51 stop" "1" "$(grep -c '^stop' "$SB/s51.log")"
assert_eq "disable: flag 0" "0" "$(flag)"
assert_eq "disable: MARK xmark deleted" "1" "$(grep -c -- '-D PREROUTING -m set --match-set z2k_warp dst -j MARK --set-xmark' "$SB/ipt.log")"
assert_eq "disable: legacy --set-mark form checked too" "1" "$(grep -c -- '-C PREROUTING -m set --match-set z2k_warp dst -j MARK --set-mark 0x989' "$SB/ipt.log")"
assert_eq "disable: table 989 flushed" "1" "$(grep -c 'route flush table 989' "$SB/ip.log")"
assert_eq "disable: rule removed" "1" "$(grep -c 'rule del fwmark 0x989/0x989 table 989' "$SB/ip.log")"

# ---------- selfheal ----------
printf 'GAME_WARP_ENABLED=1\n' > "$SB/z2k/config"; touch "$SB/s51.running"; clearlogs
ready true ""; W selfheal >/dev/null 2>&1
assert_eq "selfheal ready: route asserted" "1" "$(grep -c 'route replace default dev z2ktun0 table 989' "$SB/ip.log")"
clearlogs; ready false no_endpoint; W selfheal >/dev/null 2>&1
assert_eq "selfheal dead: MARK removed (fail open)" "1" "$(grep -c -- '-D PREROUTING -m set --match-set z2k_warp dst' "$SB/ipt.log")"
clearlogs; rm -f "$SB/s51.running"; ready true ""; W selfheal >/dev/null 2>&1
assert_eq "selfheal: daemon down → started" "1" "$(grep -c '^start' "$SB/s51.log")"
printf 'GAME_WARP_ENABLED=0\n' > "$SB/z2k/config"; clearlogs; W selfheal >/dev/null 2>&1
assert_eq "selfheal: mode off → no-op" "0" "$(cat "$SB/ip.log" "$SB/s51.log" 2>/dev/null | wc -l | tr -d ' ')"

# ---------- status ----------
printf 'GAME_WARP_ENABLED=1\n' > "$SB/z2k/config"; ready true ""
st=$(W status 2>/dev/null)
assert_eq "status: installed/enabled/ready" "installed=1 enabled=1 ready=1" "$(printf '%s' "$st" | grep -o 'installed=[01] enabled=[01] ready=[01]')"
assert_eq "status: transport+endpoint" "transport=wg endpoint=8.6.112.0:2408" "$(printf '%s' "$st" | grep -o 'transport=[a-z0-9]* endpoint=[0-9.:]*')"
rm -f "$SB/tmp/status.json"
st=$(W status 2>/dev/null)
assert_eq "status: no status file → ready=0" "ready=0" "$(printf '%s' "$st" | grep -o 'ready=[01]')"

# ---------- remove ----------
ready true ""; W enable >/dev/null 2>&1; clearlogs
rc=0; W remove >/dev/null 2>&1 || rc=$?
assert_eq "remove: rc 0" "0" "$rc"
assert_eq "remove: binary gone" "no" "$([ -e "$SB/sbin/z2k-warpd" ] && echo yes || echo no)"
assert_eq "remove: device.json kept" "yes" "$([ -s "$SB/etc/device.json" ] && echo yes || echo no)"
assert_eq "remove: flag 0" "0" "$(flag)"
assert_eq "remove: S51 stopped" "1" "$(grep -c '^stop' "$SB/s51.log")"
assert_eq "remove: ipsets destroyed" "2" "$(grep -c '^destroy z2k_warp' "$SB/ipset.log")"

# ---------- migrate: зачистка usque — наше всегда, чужое никогда ----------
# Наши следы по имени (z2k-usque, session.conf в нашем каталоге, стампы)
# сносятся всегда; пакет usque-keenetic — только при уликах, что его принёс
# z2k (S51usque без +x: старый init снимал бит; или наши следы рядом). Чужой
# живой пакет (S51usque с +x, без наших следов) не трогаем. Маркера нет:
# улики уходят вместе с зачисткой, повторный прогон чужое не тронет.
cat > "$SB/bin/opkg" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/opkg.log"
case "\$1" in list-installed) [ -f "$SB/pkg.installed" ] && echo "usque-keenetic - 1.0" ;; remove) rm -f "$SB/pkg.installed" ;; esac
exit 0
EOF
chmod +x "$SB/bin/opkg"
MIG() {
    Z2K_STUB_PATH="$SB/bin" ZAPRET2_DIR="$SB/z2k" WARP_LISTS_DIR="$SB/z2k/lists/warp" WARP_DEVICE="$SB/etc/device.json" \
        WARP_LEGACY_BIN="$SB/sbin/z2k-usque" WARP_LEGACY_INIT="$SB/initd/S51usque" WARP_LEGACY_DIR="$SB/etc/z2k-warp-legacy" \
        WARP_PURGE_MARK="$SB/etc/z2k-warp-legacy/.usque-purged" \
        sh "$SB/z2k/z2k-warp.sh" migrate >/dev/null 2>&1
}
mkdir -p "$SB/etc/z2k-warp-legacy" "$SB/initd"

cat > "$SB/bin/ndmc" <<EOF
#!/bin/sh
echo "\$2" >> "$SB/ndmc.log"
EOF
chmod +x "$SB/bin/ndmc"
# (а) наследие z2k: бинарь, снятый нами бит на S51usque, session.conf, iface, стампы, пакет стоит
touch "$SB/sbin/z2k-usque" "$SB/initd/S51usque" "$SB/etc/z2k-warp-legacy/session.conf" "$SB/z2k/.z2k-warp-kick" "$SB/pkg.installed"
echo opkgtun1 > "$SB/etc/z2k-warp-legacy/iface"
chmod -x "$SB/initd/S51usque"; rm -f "$SB/opkg.log" "$SB/ndmc.log"
MIG
assert_eq "migrate(ours): NDM interface removed by our recorded name" "1" "$(grep -c '^no interface OpkgTun1$' "$SB/ndmc.log")"
assert_eq "migrate(ours): NDM config saved" "1" "$(grep -c '^system configuration save$' "$SB/ndmc.log")"
assert_eq "migrate(ours): iface record removed after NDM" "no" "$([ -e "$SB/etc/z2k-warp-legacy/iface" ] && echo yes || echo no)"
assert_eq "migrate(ours): usque binary removed" "no" "$([ -e "$SB/sbin/z2k-usque" ] && echo yes || echo no)"
assert_eq "migrate(ours): S51usque removed" "no" "$([ -e "$SB/initd/S51usque" ] && echo yes || echo no)"
assert_eq "migrate(ours): session.conf removed" "no" "$([ -e "$SB/etc/z2k-warp-legacy/session.conf" ] && echo yes || echo no)"
assert_eq "migrate(ours): kick stamp removed" "no" "$([ -e "$SB/z2k/.z2k-warp-kick" ] && echo yes || echo no)"
assert_eq "migrate(ours): package removed" "1" "$(grep -c '^remove usque-keenetic' "$SB/opkg.log")"
assert_eq "migrate(ours): device.json untouched" "yes" "$([ -s "$SB/etc/device.json" ] && echo yes || echo no)"
assert_eq "migrate(ours): user list untouched" "yes" "$([ -s "$SB/z2k/lists/warp/my.txt" ] && echo yes || echo no)"

# (б) после зачистки юзер ставит usque-keenetic сам (+x, наших следов нет) — не трогаем
touch "$SB/pkg.installed" "$SB/initd/S51usque"; chmod +x "$SB/initd/S51usque"; rm -f "$SB/opkg.log"
MIG
assert_eq "migrate(after purge): foreign package kept" "0" "$([ -f "$SB/opkg.log" ] && grep -c '^remove' "$SB/opkg.log" || echo 0)"
assert_eq "migrate(after purge): foreign S51usque kept" "yes" "$([ -e "$SB/initd/S51usque" ] && echo yes || echo no)"

# (в) то же на свежем роутере, где z2k никогда WARP не ставил; чужой OpkgTun не трогаем
rm -f "$SB/opkg.log" "$SB/ndmc.log"
MIG
assert_eq "migrate(foreign): no ndmc calls (foreign OpkgTun untouched)" "0" "$([ -f "$SB/ndmc.log" ] && wc -l < "$SB/ndmc.log" | tr -d ' ' || echo 0)"
assert_eq "migrate(foreign): package kept" "0" "$([ -f "$SB/opkg.log" ] && grep -c '^remove' "$SB/opkg.log" || echo 0)"
assert_eq "migrate(foreign): S51usque kept" "yes" "$([ -e "$SB/initd/S51usque" ] && echo yes || echo no)"

# (г) наши следы рядом с исполняемым S51usque (эпоха r-61.x, до нашего init) — улика, сносим
touch "$SB/etc/z2k-warp-legacy/session.conf"; rm -f "$SB/opkg.log"
MIG
assert_eq "migrate(r-61 era): package removed on our evidence" "1" "$(grep -c '^remove usque-keenetic' "$SB/opkg.log")"
assert_eq "migrate(r-61 era): evidence consumed" "no" "$([ -e "$SB/etc/z2k-warp-legacy/session.conf" ] && echo yes || echo no)"
# …и сразу следом юзер ставит пакет снова — улик больше нет, не трогаем
touch "$SB/pkg.installed" "$SB/initd/S51usque"; chmod +x "$SB/initd/S51usque"; rm -f "$SB/opkg.log"
MIG
assert_eq "migrate(re-added by user): package kept" "0" "$([ -f "$SB/opkg.log" ] && grep -c '^remove' "$SB/opkg.log" || echo 0)"

# (д) любой наш артефакт — улика, и потребляется за один прогон: стамп
# старого z2k-warp.sh пишется только когда z2k сам гонял usque.
touch "$SB/z2k/.z2k-warp-reg"; rm -f "$SB/opkg.log"
MIG
assert_eq "migrate(stamp): our stamp removed" "no" "$([ -e "$SB/z2k/.z2k-warp-reg" ] && echo yes || echo no)"
touch "$SB/sbin/z2k-usque"
MIG
assert_eq "migrate(after purge): z2k-usque binary still removed" "no" "$([ -e "$SB/sbin/z2k-usque" ] && echo yes || echo no)"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
