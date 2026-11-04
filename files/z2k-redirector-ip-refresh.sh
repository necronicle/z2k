#!/bin/sh
# DNS candidates only: no video proxy and no reachability probe. Short probes
# rejected addresses that worked for the user's actual client (2026-11-04).
export PATH="${Z2K_STUB_PATH:+$Z2K_STUB_PATH:}/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin"
ZD="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG="${CONFIG_FILE:-$ZD/config}"
# Only start the introducing patch after the old updater has committed its
# successful health check. No DNS or package writes during rollback.
if [ "${1:-}" = --after-update ]; then
    [ "$#" = 3 ] && [ -n "$2" ] || exit 1
    attempts=0
    while [ "$(cat "$3" 2>/dev/null)" != "$2" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 60 ] || exit 0
        sleep 5
    done
fi
HOST=redirector.googlevideo.com
read_setting() { awk -F= -v key="$1" '$1==key {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG" 2>/dev/null; }
[ "$(read_setting Z2K_REDIRECTOR_DNS)" != 0 ] || exit 0
command -v ndmc >/dev/null 2>&1 || exit 0
command -v openssl >/dev/null 2>&1 || exit 1
[ -s "$ZD/lists/google-ranges.txt" ] || exit 1
# Entware supplies flock as a small separate package. Introducing patches
# provision it here too; a failed install leaves existing DNS records intact.
if ! command -v flock >/dev/null 2>&1; then
    opkg install flock >/dev/null 2>&1 || exit 1
    command -v flock >/dev/null 2>&1 || exit 1
fi
umask 077
# Never unlink the kernel lockfile: waiters must share the same inode.
exec 9> "$ZD/.redirector-refresh.flock" || exit 1
flock -n 9 || exit 0
LOCK=$(mktemp -d "$ZD/.redirector-refresh.XXXXXX") || exit 1
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 1' HUP INT TERM
SECRET=$(read_setting Z2K_RESOLVE_SECRET)
[ -n "$SECRET" ] || SECRET='57745177a4b883471a4ddc6124a1df6fec77e790729e074ed34dc434f7cdb6f2'
body='{"hosts":["redirector.googlevideo.com"]}'
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$SECRET" -hex 2>/dev/null | awk '{print $NF}')
[ "${#sig}" = 64 ] || exit 1
response=$(curl -fsS --max-time 15 --max-filesize 16384 \
    --resolve 85.192.60.175.nip.io:443:85.192.60.175 \
    -H 'Content-Type: application/json' -H "X-Z2K-Auth: $sig" \
    --data "$body" https://85.192.60.175.nip.io/resolve) || exit 1
# Accept exactly the expected flat JSON shape and bounded canonical IPv4s.
# The server is authenticated by TLS; the shipped Google ranges additionally
# prevent an unexpected answer from redirecting this hostname outside Google.
printf '%s' "$response" | awk '
 { for(i=1;i<=length($0);i++) { c=substr($0,i,1); if(c=="\"") quoted=!quoted; else if(quoted && c~/[[:space:]]/)bad=1 }
   if(quoted)bad=1 }
 END {exit bad}' || exit 1
printf '%s' "$response" | tr -d ' \t\r\n' | awk -v rf="$ZD/lists/google-ranges.txt" '
 function ipnum(s, a,i,n) {
  if(split(s,a,".")!=4)return -1
  n=0
  for(i=1;i<=4;i++) {
   if(a[i]!~/^[0-9]+$/ || a[i]>255 || (length(a[i])>1 && substr(a[i],1,1)=="0"))return -1
   n=n*256+a[i]
  }
  return n
 }
 BEGIN {
  while((getline line < rf)>0) {
   if(line~/^#/ || line=="")continue
   split(line,p,"/"); v=ipnum(p[1]); bits=p[2]+0
   if(v<0 || bits<1 || bits>32)exit 1
   net[++count]=v; span[count]=2^(32-bits)
  }
  close(rf)
  if(!count)exit 1
 }
 {
  if($0!~/^\{"results":\{"redirector\.googlevideo\.com":\[.*\]\}\}$/)exit 1
  sub(/^\{"results":\{"redirector\.googlevideo\.com":\[/,"")
  sub(/\]\}\}$/,"")
  n=split($0,items,","); if(n<1 || n>32)exit 1
  for(i=1;i<=n;i++) {
   if(items[i]!~/^"[0-9.]+"$/)exit 1
   ip=substr(items[i],2,length(items[i])-2); v=ipnum(ip); if(v<0)exit 1
   valid=0
   for(j=1;j<=count;j++)if(int(v/span[j])==int(net[j]/span[j]))valid=1
   if(!valid)exit 1
   if(!seen[ip]++)print ip
  }
 }' > "$LOCK/new" || exit 1
[ -s "$LOCK/new" ] || exit 1
records() {
    LD_LIBRARY_PATH="" ndmc -c 'show running-config' > "$LOCK/config" || return 1
    awk -v h="$HOST" '$1=="ip" && $2=="host" && $3==h {print $4}' "$LOCK/config"
}
records > "$LOCK/old" || exit 1
sort -u "$LOCK/old" > "$LOCK/old-sorted"
sort -u "$LOCK/new" > "$LOCK/new-sorted"
cmp -s "$LOCK/old-sorted" "$LOCK/new-sorted" && exit 0
rollback() {
    # Re-add old records first; remove only additions made by this attempt.
    while read -r ip; do LD_LIBRARY_PATH="" ndmc -c "ip host $HOST $ip" >/dev/null 2>&1 || true; done < "$LOCK/old"
    while read -r ip; do
        grep -Fxq "$ip" "$LOCK/old" || LD_LIBRARY_PATH="" ndmc -c "no ip host $HOST $ip" >/dev/null 2>&1 || true
    done < "$LOCK/new"
    LD_LIBRARY_PATH="" ndmc -c 'system configuration save' >/dev/null 2>&1 || true
}
trap 'rollback; exit 1' HUP INT TERM
# Add first: a capacity failure cannot leave the previous hostname empty.
while read -r ip; do
    grep -Fxq "$ip" "$LOCK/old" && continue
    if ! LD_LIBRARY_PATH="" ndmc -c "ip host $HOST $ip" >/dev/null 2>&1; then rollback; exit 1; fi
done < "$LOCK/new"
records > "$LOCK/current" || { rollback; exit 1; }
while read -r ip; do
    grep -Fxq "$ip" "$LOCK/current" || { rollback; exit 1; }
done < "$LOCK/new"
while read -r ip; do
    grep -Fxq "$ip" "$LOCK/new" && continue
    if ! LD_LIBRARY_PATH="" ndmc -c "no ip host $HOST $ip" >/dev/null 2>&1; then rollback; exit 1; fi
done < "$LOCK/old"
records > "$LOCK/current" || { rollback; exit 1; }
sort -u "$LOCK/current" > "$LOCK/current-sorted"
cmp -s "$LOCK/current-sorted" "$LOCK/new-sorted" || { rollback; exit 1; }
LD_LIBRARY_PATH="" ndmc -c 'system configuration save' >/dev/null 2>&1 || { rollback; exit 1; }
printf 'redirector DNS updated: %s addresses\n' "$(wc -l < "$LOCK/new" | tr -d ' ')"
