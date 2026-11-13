#!/bin/sh
# Execute init functions: legacy flag cannot disable DNS observation.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/utils.sh" 2>/dev/null
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
for fn in z2k_gvsub_enabled z2k_gvsub_dns_rule z2k_gvsub_fw_start; do
 awk -v f="$fn" '$0==f"()"{p=1} p{print} p&&/^}/{exit}' "$ROOT/files/S99zapret2.new" >> "$tmp/functions"
done
. "$tmp/functions"
printf '#!/bin/sh\necho gvsub\n' > "$tmp/bin"; chmod +x "$tmp/bin"
Z2K_GVSUB_BIN="$tmp/bin"; FWTYPE=iptables
for old in 0 1; do
 for reply in 0 1; do
  for provider in 0 1; do
   Z2K_GV_SUBST=$old; Z2K_GV_SERVER_REPLY2=$reply; Z2K_PROVIDER_CACHE=$provider
   expected=off; [ "$reply" = 1 ] && expected=on
   actual=off; z2k_gvsub_enabled && actual=on
   [ "$actual" = "$expected" ] || { echo "FAIL old=$old reply=$reply provider=$provider got=$actual"; exit 1; }
  done
 done
done
Z2K_GVSUB_QUEUE=210
iptablesw(){ echo "$*"; case "$*" in *" -D "*) return 1;; esac; }
gvt=$(z2k_gvsub_dns_rule iptablesw -I gvt1)
case "$gvt" in *--icase*) ;; *) echo "FAIL case-sensitive DNS interception";exit 1;; esac
case "$gvt" in *'--hex-string |046776743103636f6d00|'*'--queue-bypass'*) ;; *) echo "FAIL gvt1 DNS rule: $gvt";exit 1;; esac
Z2K_GV_SERVER_REPLY2=1; Z2K_GVSUB_PID="$tmp/missing"; DISABLE_IPV6=0
ip6tablesw(){ echo "$*"; case "$*" in *" -D "*) return 1;; esac; }
z2k_insmod_fw(){ :; }
z2k_gvsub_fw_stop(){ :; }
z2k_gvsub_legacy_purge(){ :; }
calls=$(z2k_gvsub_fw_start)
case "$calls" in *'-t nat -N '*|*'-t mangle -N Z2K_GVSUB'*|*'-j DNAT'*) echo 'FAIL DNAT scaffolding created';exit 1;; esac
echo 'PASS Play DNS lifecycle, retired flag, no DNAT scaffolding'
