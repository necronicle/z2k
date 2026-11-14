#!/bin/sh
# A malformed domain must never become a route; valid names must survive save.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
filter="$root/files/z2k-warp-list-filter.awk"
input='Example.COM
*.Example.COM
xn--e1afmkfd.xn--p1ai
1.2.3.4/24
# user note
*.com
a..b
https://a.com
010.1.2.3
::1'
got=$(printf '%s\n' "$input" | awk -v mode=save -f "$filter")
want='example.com
*.example.com
xn--e1afmkfd.xn--p1ai
1.2.3.4/24
# user note'
[ "$got" = "$want" ] || { printf 'save mismatch\n%s\n' "$got"; exit 1; }
got=$(printf '%s\n' "$input" | awk -v mode=domains -f "$filter")
want='example.com
*.example.com
xn--e1afmkfd.xn--p1ai'
[ "$got" = "$want" ] || { printf 'domains mismatch\n%s\n' "$got"; exit 1; }
got=$(printf '%s\n' "$input" | awk -v mode=ipset -f "$filter")
[ "$got" = '1.2.3.4/24' ] || { printf 'ipset mismatch\n%s\n' "$got"; exit 1; }
got=$(printf '%s\n' "$input" | awk -v mode=count -f "$filter")
[ "$got" = 'ip=1 domain=3 invalid=5' ] || { printf 'count mismatch\n%s\n' "$got"; exit 1; }
# IPv6: в маршруты — только интернет (2000::/3) без служебных диапазонов; в
# наборы IPv4 и IPv6 — каждый своим режимом.
input6='2606:4700::6810:B9F1
2a00:1450:4010::/48
2001:db8::1
2001:0:4136::1
2002:c000::1
3fff::1
fd00::1
fe80::1
::1
2606::4700::1
2606:4700::/129
1.2.3.4'
got=$(printf '%s\n' "$input6" | awk -v mode=ipset6 -f "$filter")
want='2606:4700::6810:b9f1
2a00:1450:4010::/48'
[ "$got" = "$want" ] || { printf 'ipset6 mismatch\n%s\n' "$got"; exit 1; }
got=$(printf '%s\n' "$input6" | awk -v mode=ipset -f "$filter")
[ "$got" = '1.2.3.4' ] || { printf 'ipset must stay IPv4-only\n%s\n' "$got"; exit 1; }
got=$(printf '%s\n' "$input6" | awk -v mode=count -f "$filter")
[ "$got" = 'ip=3 domain=0 invalid=9' ] || { printf 'count6 mismatch\n%s\n' "$got"; exit 1; }
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
export ZAPRET2_DIR="$sb/zapret2" WARP_LISTS_DIR="$sb/zapret2/lists/warp"
export WARP_DOMAINS="$sb/domains.v1" WARP_FILTER="$filter" Z2K_WARP_SOURCE_ONLY=1
mkdir -p "$WARP_LISTS_DIR"
: > "$WARP_LISTS_DIR/.legacy-aggregate-purged"
printf 'Example.COM\n*.example.com\n' > "$WARP_LISTS_DIR/a.txt"
printf 'off.example.com\n' > "$WARP_LISTS_DIR/b.txt"
printf 'b\n' > "$WARP_LISTS_DIR/.disabled"
. "$root/files/z2k-warp.sh"
warp_domains_load
got=$(cat "$WARP_DOMAINS")
want='v1
*.example.com
example.com'
[ "$got" = "$want" ] || { printf 'snapshot mismatch\n%s\n' "$got"; exit 1; }
WARP_FILTER="$sb/missing.awk"
if warp_domains_load; then printf 'missing filter accepted\n'; exit 1; fi
[ "$(cat "$WARP_DOMAINS")" = "$want" ] || { printf 'missing filter damaged live snapshot\n'; exit 1; }
WARP_FILTER="$filter"
awk 'BEGIN { for (i=0; i<4097; i++) printf "host%d.example.com\n", i }' > "$WARP_LISTS_DIR/a.txt"
warp_domains_load || { printf 'domain overflow disabled static WARP\n'; exit 1; }
[ "$(cat "$WARP_DOMAINS")" = 'v1' ] || { printf 'domain overflow kept stale routes\n'; exit 1; }
printf 'WARP domain filter passed\n'
