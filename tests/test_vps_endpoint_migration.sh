#!/bin/sh
# Exact stock endpoints move; custom/reseller settings and secrets survive.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
sed -n '/^migrate_vps_endpoints() {/,/^}/p' "$ROOT/lib/install.sh" > "$SB/function.sh"
. "$SB/function.sh"
cat > "$SB/config" <<'CFG'
Z2K_RELAY_URL="wss://213.176.74.63.nip.io/ws"
Z2K_WARP_VPS_PROXY='http://z2kwarp:z2kW4rpR3g2026@213.176.74.63:8119'
Z2K_VPS_GH_IP=213.176.74.63
Z2K_OPKG_VPS="213.176.74.63"
Z2K_RELAY_SECRET="keep-private"
CFG
chmod 600 "$SB/config"
migrate_vps_endpoints "$SB/config"
if grep -q '213.176.74.63' "$SB/config"; then echo '[FAIL] old defaults survived'; exit 1; fi
grep -q '^Z2K_RELAY_URL="wss://85.192.60.175.nip.io/ws"$' "$SB/config"
grep -q '^Z2K_RELAY_SECRET="keep-private"$' "$SB/config"
cp "$SB/config" "$SB/once"
migrate_vps_endpoints "$SB/config"
cmp "$SB/once" "$SB/config"
cat > "$SB/custom" <<'CFG'
Z2K_RELAY_URL="wss://relay.reseller.example/ws"
Z2K_WARP_VPS_PROXY="http://custom:secret@213.176.74.63:8119"
Z2K_VPS_GH_IP="203.0.113.8"
Z2K_OPKG_VPS=""
# Z2K_RELAY_URL="wss://213.176.74.63.nip.io/ws"
OTHER="213.176.74.63"
CFG
cp "$SB/custom" "$SB/before"
migrate_vps_endpoints "$SB/custom"
cmp "$SB/before" "$SB/custom"
migrate_vps_endpoints "$SB/missing"
# Resolve defaults exercise actual init/helper assignments without starting services.
for input in '' 'http://z2kwarp:z2kW4rpR3g2026@213.176.74.63:8119' 'http://custom.example:8119'; do
    _proxy=$input
    eval "$(sed -n '/^export Z2K_WARP_VPS_PROXY=/,/^esac/p' "$ROOT/files/init.d/S51z2k-warp")"
    case "$input" in
      http://custom.example:8119) [ "$Z2K_WARP_VPS_PROXY" = "$input" ] ;;
      *) [ "$Z2K_WARP_VPS_PROXY" = 'http://z2kwarp:z2kW4rpR3g2026@85.192.60.175:8119' ] ;;
    esac
 done
printf '[PASS] stock endpoint migration, custom preservation, idempotency, WARP runtime defaults\n'

# Execute the uninstall relay-pin block with a mock ndmc: both stock IPs removed.
ndmc() {
    case "$2" in
        "show running-config") printf 'ip host g.whatsapp.net 213.176.74.63\nip host g.whatsapp.net 85.192.60.175\n' ;;
        *) printf '%s\n' "$2" >> "$SB/ndmc.log" ;;
    esac
}
export SB
sed -n '/^# z2k:shared:remove_our_ip_hosts:begin/,/^# z2k:shared:remove_our_ip_hosts:end/p' "$ROOT/lib/install.sh" > "$SB/unpin.sh"
. "$SB/unpin.sh"
_z2k_remove_our_ip_hosts
grep -q '^no ip host g.whatsapp.net 213.176.74.63$' "$SB/ndmc.log"
grep -q '^no ip host g.whatsapp.net 85.192.60.175$' "$SB/ndmc.log"
printf '[PASS] uninstall removes old and new stock relay pins\n'
