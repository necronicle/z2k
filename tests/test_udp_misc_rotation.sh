#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Execute the real broad-profile generator block with voice enabled and default
# settings. Full generator integration is covered by test_config_official.sh.
safe_config_read() { printf '1\n'; }
ZAPRET2_DIR=/unused
category_voice=1
nfqws2_opt_lines=
eval "$(awk '/^    local udp_misc_on /,/^    # Здесь стоял webrtc_bypass/ { if ($0 !~ /^    # Здесь стоял/) print }' lib/config_official.sh | sed '/^    local /d')"
export Z2K_TEST_UDP_MISC_PROFILE
Z2K_TEST_UDP_MISC_PROFILE=$(printf '%b' "$nfqws2_opt_lines")
# Read the same capture limits that the generated config uses.
eval "$(sed -n '/^Z2K_UDP_PKT_/p' lib/config_official.sh)"
export Z2K_UDP_PKT_IN Z2K_UDP_PKT_OUT
# Verify the real iptables helper still queues the bounded initial window.
eval "$(sed -n '1p' common/ipt.sh)"
eval "$(awk '/^ipt_first_packets\(\)/,/^}/' common/ipt.sh)"
[ "$Z2K_UDP_PKT_IN" = 8 ] && [ "$Z2K_UDP_PKT_OUT" = 8 ]
for limit in "$Z2K_UDP_PKT_IN" "$Z2K_UDP_PKT_OUT"; do
    [ "$(ipt_first_packets "$limit")" = "$ipt_connbytes 0:8" ]
done
"${LUA:-lua}" tests/test_udp_misc_rotation.lua
