#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/custom.d"
for script in 50-stun4all 50-discord-media 60-user; do
 printf 'zapret_custom_daemons() { echo "%s:$1"; }\n' "$script" > "$tmp/custom.d/$script"
done
existf() { command -v "$1" >/dev/null; }
dir_is_not_empty() { return 0; }
CUSTOM_DIR=$tmp
DISABLE_CUSTOM=0
eval "$(sed -n '/^custom_runner()$/,/^}/p' "$ROOT/files/S99zapret2.new")"
Z2K_CATEGORY_DISCORD_VOICE=0
out=$(custom_runner zapret_custom_daemons 1)
[ "$out" = '60-user:1' ]
Z2K_CATEGORY_DISCORD_VOICE=1
out=$(custom_runner zapret_custom_daemons 0)
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ]
echo '[PASS] category gates bundled STUN helpers and preserves user scripts'
