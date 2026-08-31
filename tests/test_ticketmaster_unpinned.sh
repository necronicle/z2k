#!/bin/sh
# tests/test_ticketmaster_unpinned.sh — записи ticketmaster не ставятся и
# снимаются у тех, кому их уже поставили.
#
# Повод: просьба пользователей 31.08.2026. Пиннинг занимал 22 записи
# статического DNS из 256, что есть у Keenetic, — ради одного сайта. Люди
# упирались в лимит и теряли записи, нужные им самим.
#
# Проверяется поведение: чистка обязана снимать эти записи (раньше они были в
# исключении) и обязана НЕ трогать WhatsApp, у которого релей остаётся.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/state"

cat > "$SB/bin/ndmc" <<'NDMC'
#!/bin/sh
case "$2" in
  "show running-config")
    echo 'ip host www.ticketmaster.com 213.176.74.63'
    echo 'ip host checkout.ticketmaster.com 213.176.74.63'
    echo 'ip host s1.ticketm.net 213.176.74.63'
    echo 'ip host prismic-images.tmol.io 213.176.74.63'
    echo 'ip host g.whatsapp.net 213.176.74.63'
    echo 'ip host mmg.whatsapp.net 213.176.74.63'
    echo 'ip host example.org 9.9.9.9'
    ;;
  "system configuration save") ;;
  *) echo "$2" >> "$NDMC_LOG" ;;
esac
exit 0
NDMC
chmod +x "$SB/bin/ndmc"
: > "$SB/log"

( cd "$SB" && PATH="$SB/bin:$PATH" NDMC_LOG="$SB/log" ZAPRET2_DIR="$SB" \
    sh -c ". $DIR/lib/utils.sh >/dev/null 2>&1; cleanup_legacy_ip_hosts" >/dev/null 2>&1 )

miss=""
for h in www.ticketmaster.com checkout.ticketmaster.com s1.ticketm.net prismic-images.tmol.io; do
    grep -q "^no ip host $h " "$SB/log" || miss="$miss $h"
done
[ -z "$miss" ] && ok "записи ticketmaster сняты" || bad "не сняты:$miss"

if grep -qE '^no ip host (g|mmg)\.whatsapp\.net ' "$SB/log"; then
    bad "снят релей WhatsApp — он должен остаться"
else
    ok "релей WhatsApp не тронут"
fi
grep -q '^no ip host example.org ' "$SB/log" \
    && bad "снята чужая запись" || ok "чужие записи не тронуты"

# И установщик больше не прописывает их заново — иначе чистка и установка
# будут бесконечно спорить друг с другом.
if grep -q 'local relay_hosts=.*ticketmaster' "$DIR/lib/install.sh"; then
    bad "установщик всё ещё пиннит ticketmaster — записи вернутся"
else
    ok "установщик ticketmaster больше не пиннит"
fi
grep -q 'relay_unpin=.*www.ticketmaster.com' "$DIR/lib/install.sh" \
    && ok "установщик снимает старые записи ticketmaster" \
    || bad "установщик не снимает уже поставленные записи"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
