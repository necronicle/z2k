#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export TG_EXCLUDE_FILE="$TMP/exclude" IPSET_LOG="$TMP/ipset.log"
printf '192.0.2.1 # user entry\n' > "$TG_EXCLUDE_FILE"
cat > "$TMP/bin/ipset" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$IPSET_LOG"
SH
chmod +x "$TMP/bin/ipset"
PATH="$TMP/bin:$PATH"; export PATH
eval "$(sed -n '/^exclude_owned_relays() {/,/^}/p' "$ROOT/files/init.d/S98tg-tunnel")"
exclude_owned_relays
exclude_owned_relays
grep -qFx '192.0.2.1 # user entry' "$TG_EXCLUDE_FILE"
for ip in 85.192.60.175 45.146.90.136; do
 [ "$(grep -cFx "$ip" "$TG_EXCLUDE_FILE")" = 1 ]
 grep -qFx "add nozapret $ip -exist" "$IPSET_LOG"
done
sed -n '/^start() {/,/^}/p' "$ROOT/files/init.d/S98tg-tunnel" | grep -q 'exclude_owned_relays || return 1'
echo 'PASS: owned relay exclusions persist, reseed and preserve user entries'
