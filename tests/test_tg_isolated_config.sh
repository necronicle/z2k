#!/bin/sh
# Exercise the actual supervisor option block with new/old binaries and bad config.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
awk '/# Optional session limit; dedicated/{copy=1} copy{print} copy && /esac/{exit}' "$ROOT/files/init.d/S98tg-tunnel" | sed "s|/opt/zapret2/config|$TMP/config|g" > "$TMP/block"
printf '%s\n' '#!/bin/sh' 'echo "  -relay-sessions int" >&2' 'exit 0' > "$TMP/new"
printf '%s\n' '#!/bin/sh' 'echo "old flags" >&2' 'exit 0' > "$TMP/old"
chmod +x "$TMP/new" "$TMP/old"
check() {
    printf '%s\n' "$1" > "$TMP/config"
    result=$(BIN="$TMP/$2" BLOCK="$TMP/block" sh -c 'TUNNEL_FLAGS="--existing"; . "$BLOCK" >/dev/null; printf "%s" "$TUNNEL_FLAGS"')
    [ "$result" = "$3" ] || { echo "FAIL: $1 ($2): $result"; exit 1; }
}
check 'TG_RELAY_SESSIONS="8"' new '--existing --relay-sessions=8'
check 'TG_RELAY_SESSIONS=16' new '--existing --relay-sessions=16'
check 'TG_RELAY_SESSIONS=0' new '--existing'
check 'TG_RELAY_SESSIONS=8' old '--existing'
check 'TG_RELAY_SESSIONS=64' new '--existing --relay-sessions=64'
check 'TG_RELAY_SESSIONS=65' new '--existing --relay-sessions=65'
check 'TG_RELAY_SESSIONS=1024' new '--existing --relay-sessions=1024'
check 'TG_RELAY_SESSIONS=1025' new '--existing'
check 'TG_RELAY_SESSIONS=8 --tunnel-url=bad' new '--existing'
check '' new '--existing'
echo 'PASS: isolated config, limits, invalid input and old binary compatibility'
