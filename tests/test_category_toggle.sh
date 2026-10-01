#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$ROOT/lib/utils.sh"
CONFIG_FILE=$tmp/config
ZAPRET2_DIR=$tmp
INIT_SCRIPT=$tmp/init
export CONFIG_FILE
printf 'ENABLED=1\nZ2K_CATEGORY_DISCORD_VOICE=1\n' > "$CONFIG_FILE"
cp "$CONFIG_FILE" "$tmp/original"
cat > "$INIT_SCRIPT" <<'INIT'
#!/bin/sh
printf '%s:' "$1" >> "$CONFIG_FILE.calls"
grep Z2K_CATEGORY_DISCORD_VOICE "$CONFIG_FILE" >> "$CONFIG_FILE.calls"
if [ "$1" = start ] && [ "${FAIL_NEW_START:-0}" = 1 ] && grep -q DISCORD_VOICE=0 "$CONFIG_FILE"; then exit 1; fi
INIT
chmod +x "$INIT_SCRIPT"
cat > "$tmp/z2k-config-validator.sh" <<'VALIDATOR'
exit "${VALIDATOR_RC:-0}"
VALIDATOR
eval "$(sed -n '/^toggle_category() {/,/^}/p' "$ROOT/webpanel/cgi/actions.sh")"
is_running() { [ "${RUNNING:-1}" = 1 ]; }
ensure_init_exec() { :; }
regenerate_config() { return "${GEN_RC:-0}"; }
toggle_category DISCORD_VOICE 0
[ "$(head -1 "$CONFIG_FILE.calls")" = 'stop:Z2K_CATEGORY_DISCORD_VOICE=1' ]
[ "$(tail -1 "$CONFIG_FILE.calls")" = 'start:Z2K_CATEGORY_DISCORD_VOICE=0' ]
cp "$tmp/original" "$CONFIG_FILE"
export VALIDATOR_RC=2
if toggle_category DISCORD_VOICE 0; then echo 'FAIL: invalid config accepted'; exit 1; fi
cmp "$tmp/original" "$CONFIG_FILE"
export VALIDATOR_RC=0
# Failed generation and failed new-service startup both restore the original.
for failure in generator startup; do
 cp "$tmp/original" "$CONFIG_FILE"
 : > "$CONFIG_FILE.calls"
 GEN_RC=0
 export FAIL_NEW_START=0
 if [ "$failure" = generator ]; then GEN_RC=1; else export FAIL_NEW_START=1; fi
 if toggle_category DISCORD_VOICE 0; then echo "FAIL: $failure accepted"; exit 1; fi
 cmp "$tmp/original" "$CONFIG_FILE"
 [ "$(tail -1 "$CONFIG_FILE.calls")" = 'start:Z2K_CATEGORY_DISCORD_VOICE=1' ]
done
GEN_RC=0
export FAIL_NEW_START=0 VALIDATOR_RC=1
toggle_category DISCORD_VOICE 0
export VALIDATOR_RC=0
RUNNING=0
rm "$CONFIG_FILE.calls"
toggle_category DISCORD_VOICE 0
[ ! -f "$CONFIG_FILE.calls" ]
if toggle_category UNKNOWN 0; then exit 1; fi
if toggle_category YOUTUBE invalid; then exit 1; fi
echo '[PASS] old-config teardown, validation rollback, stopped service, input validation'
