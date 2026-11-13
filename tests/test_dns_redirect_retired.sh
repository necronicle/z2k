#!/bin/sh
# tests/test_dns_redirect_retired.sh — «Защита DNS» убрана 07.11.2026, и генератор
# конфига снимает её остатки с роутера: хук NDM 89, библиотеку, оба правила
# REDIRECT :53, ipset z2k_lan4 и отметки сторожа.
#
# Патч удалённые файлы не убирает, а оставшийся хук возвращал бы правила после
# каждого регена NDM. Исполняется настоящая z2k_retire_dns_redirect из
# lib/config_official.sh; iptables и ipset подменены, дерево — во временном каталоге.
HERE=$(cd "$(dirname "$0")/.." && pwd)
GEN="$HERE/lib/config_official.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dnsretire.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

FN="$TMP/fn.sh"
awk '/^z2k_retire_dns_redirect\(\) \{/ {on=1} on {print} on && /^}/ {exit}' "$GEN" > "$FN"
grep -q '^z2k_retire_dns_redirect() {' "$FN" && ok "функция найдена в генераторе" || no "функция" found none

# Подменные iptables/ipset: число наших правил по протоколу лежит в файлах.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/iptables" <<'IPT'
#!/bin/sh
echo "$*" >> "$STATE/ipt.log"
case "$*" in *"--match-set z2k_lan4 src"*"REDIRECT --to-ports 53"*) ;; *) exit 1 ;; esac
for p in udp tcp; do case "$*" in *"-p $p "*) proto=$p ;; esac; done
n=$(cat "$STATE/$proto" 2>/dev/null || echo 0)
case "$*" in
    *" -C "*) [ "$n" -gt 0 ] ;;
    *" -D "*) [ "$n" -gt 0 ] || exit 1; echo $((n - 1)) > "$STATE/$proto" ;;
    *) exit 1 ;;
esac
IPT
cat > "$TMP/bin/ipset" <<'IPS'
#!/bin/sh
echo "$*" >> "$STATE/ipset.log"
# Real ipset returns 1 when a previous regen already removed the set.
[ ! -e "$STATE/set-gone" ] || exit 1
: > "$STATE/set-gone"
IPS
chmod +x "$TMP/bin/iptables" "$TMP/bin/ipset"

# Дерево роутера с остатками функции.
ROOT="$TMP/opt"; ZD="$ROOT/zapret2"; ST="$TMP/state"
mkdir -p "$ZD/files/ndm" "$ROOT/etc/ndm/netfilter.d" "$ST" "$TMP/run"
for f in "$ROOT/etc/ndm/netfilter.d/89-z2k-dns-redirect.sh" "$ZD/z2k-dns-redirect.sh" \
         "$ZD/files/z2k-dns-redirect.sh" "$ZD/files/ndm/89-z2k-dns-redirect.sh" \
         "$ROOT/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh"; do echo x > "$f"; done
: > "$TMP/run/z2k-dns-redirect.down"; echo "1 0" > "$TMP/run/z2k-dns-redirect.hc"
echo 2 > "$ST/udp"; echo 1 > "$ST/tcp"

run() { PATH="$TMP/bin:$PATH" STATE="$ST" ZAPRET2_DIR="$ZD" Z2K_DNS_STATE_DIR="$TMP/run" sh -eu -c ". \"$FN\"; z2k_retire_dns_redirect"; }
run; rc=$?
[ "$rc" = 0 ] && ok "возвращает 0" || no "код" 0 "$rc"
[ ! -e "$ROOT/etc/ndm/netfilter.d/89-z2k-dns-redirect.sh" ] && ok "хук NDM 89 удалён" || no "хук 89" absent present
[ ! -e "$ZD/z2k-dns-redirect.sh" ] && [ ! -e "$ZD/files/z2k-dns-redirect.sh" ] && [ ! -e "$ZD/files/ndm/89-z2k-dns-redirect.sh" ] \
    && ok "библиотека и копии удалены" || no "библиотека" absent present
[ -e "$ROOT/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh" ] && ok "чужой хук 90 не тронут" || no "хук 90" present absent
[ "$(cat "$ST/udp"):$(cat "$ST/tcp")" = "0:0" ] && ok "сняты все копии правил udp и tcp" || no "правила" 0:0 "$(cat "$ST/udp"):$(cat "$ST/tcp")"
grep -q '^destroy z2k_lan4$' "$ST/ipset.log" && ok "ipset z2k_lan4 удалён" || no "ipset" destroy "$(cat "$ST/ipset.log")"
[ ! -e "$TMP/run/z2k-dns-redirect.down" ] && [ ! -e "$TMP/run/z2k-dns-redirect.hc" ] && ok "отметки сторожа удалены" || no "отметки" absent present

# Повторный прогон под set -eu, как установщик: набора уже нет,
# но уборка должна дойти до отметок сторожа и вернуть успех.
: > "$TMP/run/z2k-dns-redirect.down"
: > "$TMP/run/z2k-dns-redirect.hc"
run; rc=$?
[ "$rc" = 0 ] && ok "повторный прогон под set -eu возвращает 0" || no "повтор set -eu" 0 "$rc"
[ ! -e "$TMP/run/z2k-dns-redirect.down" ] && [ ! -e "$TMP/run/z2k-dns-redirect.hc" ] && ok "отсутствующий ipset не прерывает уборку отметок" || no "отметки после отсутствующего ipset" absent present

# Без iptables и ipset (macOS, CI без прав) — тоже 0.
mkdir -p "$TMP/empty"
PATH="$TMP/empty:/usr/bin:/bin" ZAPRET2_DIR="$ZD" sh -c ". \"$FN\"; command -v iptables >/dev/null && exit 0; z2k_retire_dns_redirect"; rc=$?
[ "$rc" = 0 ] && ok "без iptables возвращает 0" || no "без iptables" 0 "$rc"

# Генератор её вызывает, а следов функции в продукте нет.
grep -q '^    z2k_retire_dns_redirect$' "$GEN" && ok "create_official_config зовёт уборку" || no "вызов" present absent
for f in files/S99zapret2.new files/z2k-scheduler.sh webpanel/cgi/api.sh webpanel/cgi/actions.sh webpanel/www/js/pages/toggles.js lib/install.sh z2k.sh lib/release_map.sh; do
    n=$(grep -c 'z2k-dns-redirect.sh\|toggle_dns_redirect\|dns_redirect\|Z2K_DNS_REDIRECT' "$HERE/$f")
    case "$f" in lib/install.sh) n=$(grep -v 'netfilter.d/89-z2k-dns-redirect.sh' "$HERE/$f" | grep -c 'z2k-dns-redirect.sh\|toggle_dns_redirect\|Z2K_DNS_REDIRECT') ;; esac
    [ "$n" = 0 ] && ok "$f: следов нет" || no "$f: следы" 0 "$n"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
