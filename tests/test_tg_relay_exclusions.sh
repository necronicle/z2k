#!/bin/sh
# Свои релеи: соединения САМОГО роутера с ними идут мимо обхода (метка движка в
# mangle OUTPUT), а соединения устройств сети к тому же адресу — через обход.
# С p-87.26 по p-88.2 релей исключался адресом в nozapret, и вместе с ним
# лишились обхода домены WhatsApp, которые роутер уводит на тот же адрес
# (15.11.2026: static/mmg.whatsapp.net через VPS висели до таймаута).
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export TG_EXCLUDE_FILE="$TMP/exclude" IPSET_LOG="$TMP/ipset.log" IPT_RULES="$TMP/ipt.rules" IPT_LOG="$TMP/ipt.log"
: > "$IPT_RULES"
cat > "$TMP/bin/ipset" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$IPSET_LOG"
SH
# iptables с памятью: -I/-A кладут правило, -D снимает, -C проверяет.
cat > "$TMP/bin/iptables" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$IPT_LOG"
rule=$(printf '%s\n' "$*" | sed -e 's/^-w //' -e 's/ -[ACDI] / /' -e 's/ OUTPUT 1 / OUTPUT /')
case " $* " in
    *" -C "*) grep -qxF -- "$rule" "$IPT_RULES"; exit $? ;;
    *" -I "*|*" -A "*) printf '%s\n' "$rule" >> "$IPT_RULES" ;;
    *" -D "*) grep -vxF -- "$rule" "$IPT_RULES" > "$IPT_RULES.n"; mv "$IPT_RULES.n" "$IPT_RULES" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/ipset" "$TMP/bin/iptables"
PATH="$TMP/bin:$PATH"; export PATH
fail() { echo "FAIL: $*"; exit 1; }

# shellcheck source=/dev/null
. "$ROOT/files/z2k-tg-redirect.sh"

# Прежняя форма: свои адреса в файле исключений (так их писал p-87.26) и в
# nozapret. Чужая строка обязана остаться.
printf '192.0.2.1 # user entry\n\n85.192.60.175\n\n45.146.90.136\n' > "$TG_EXCLUDE_FILE"
z2k_owned_relays_unexclude_legacy
grep -qFx '192.0.2.1 # user entry' "$TG_EXCLUDE_FILE" || fail "user entry lost"
for ip in 85.192.60.175 45.146.90.136; do
    ! grep -qFx "$ip" "$TG_EXCLUDE_FILE" || fail "$ip left in the exclusion file"
    grep -qFx "del nozapret $ip -exist" "$IPSET_LOG" || fail "$ip not removed from nozapret"
done

# Метка: ровно одно правило на релей, и только в mangle OUTPUT.
z2k_owned_relays_ensure
z2k_owned_relays_ensure
for ip in 85.192.60.175 45.146.90.136; do
    [ "$(grep -cxF -- "-t mangle OUTPUT -d $ip -j MARK --set-xmark 0x40000000/0x40000000" "$IPT_RULES")" = 1 ] \
        || fail "mark for $ip missing or duplicated"
done
! grep -q "FORWARD\|PREROUTING" "$IPT_RULES" || fail "LAN traffic must not be marked"
z2k_owned_relays_remove
[ ! -s "$IPT_RULES" ] || fail "marks left after removal: $(cat "$IPT_RULES")"

# Обвязка: S98 ставит при старте и снимает при остановке; хук NDM возвращает
# метку на пересборке mangle; адрес релея больше не пишется в исключения.
S98="$ROOT/files/init.d/S98tg-tunnel"
sed -n '/^start() {/,/^}/p' "$S98" | grep -q 'z2k_owned_relays_unexclude_legacy' || fail "S98 start does not migrate"
sed -n '/^start() {/,/^}/p' "$S98" | grep -q 'z2k_owned_relays_ensure' || fail "S98 start does not mark"
sed -n '/^stop() {/,/^}/p' "$S98" | grep -q 'z2k_owned_relays_remove' || fail "S98 stop does not unmark"
! grep -q 'nozapret' "$S98" || fail "S98 still excludes the relay by address"
HOOK="$ROOT/files/ndm/90-z2k-tg-redirect.sh"
grep -q 'case "$table" in nat|mangle)' "$HOOK" || fail "hook ignores mangle"
grep -q 'z2k_owned_relays_ensure' "$HOOK" || fail "hook does not restore the mark"
echo 'PASS: own relays bypass desync only for router traffic; legacy exclusions removed'
