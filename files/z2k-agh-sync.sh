#!/bin/sh
# Synchronize only ledger-owned AGH rewrites. No API credentials or YAML comments.
# BusyBox nslookup BIG supports -port= (networking/nslookup.c); small builds
# fall back to a minimal TCP A query via nc, od and awk, already on Entware.
export PATH="${Z2K_STUB_PATH:+$Z2K_STUB_PATH:}/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin"
umask 077
ZAPRET2_DIR=${ZAPRET2_DIR:-/opt/zapret2}
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE=${Z2K_AGH_STATE_DIR:-$ZAPRET2_DIR/agh-sync}
WA_HOSTS="whatsapp.com whatsapp.net g.whatsapp.net static.whatsapp.net mmg.whatsapp.net pps.whatsapp.net dit.whatsapp.net v.whatsapp.net crashlogs.whatsapp.net"
MODE=${1:-sync}
mkdir -p "$STATE" || exit 1
# Single writer for refresh, explicit clear and uninstall.
own_lock=1
if [ -n "${Z2K_AGH_LOCK_PARENT:-}" ] && [ "$(cat "$STATE/lock/pid" 2>/dev/null)" = "$Z2K_AGH_LOCK_PARENT" ] && kill -0 "$Z2K_AGH_LOCK_PARENT" 2>/dev/null; then
    own_lock=0
else
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        oldpid=$(cat "$STATE/lock/pid" 2>/dev/null)
        case "$oldpid" in ''|*[!0-9]*) exit 1;; esac
        kill -0 "$oldpid" 2>/dev/null && exit 1
        rm -f "$STATE/lock/pid"
        rmdir "$STATE/lock" 2>/dev/null && mkdir "$STATE/lock" || exit 1
    fi
    printf '%s\n' "$$" > "$STATE/lock/pid"
fi
TMP=$(mktemp -d "$STATE/work.XXXXXX") || { [ "$own_lock" = 0 ] || rm -rf "$STATE/lock"; exit 1; }
was_running=0; stopped=0; installed=0; committed=0
matched=0; total=0; schema=unknown; endpoint=unknown
result() {
    {
        printf 'time=%s\nschema=%s\nmatch=%s/%s\nendpoint=%s\nresult=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S %z')" "$schema" "$matched" "$total" "$endpoint" "$1"
        printf 'conflicts=%s\n' "$(tr '\n' ' ' < "$TMP/conflicts" 2>/dev/null)"
    } > "$STATE/last-result.new" && mv -f "$STATE/last-result.new" "$STATE/last-result"
    logger -t z2k-agh-sync "$1; schema=$schema A=$matched/$total" 2>/dev/null || :
}
running() { pidof AdGuardHome >/dev/null 2>&1; }
start_service() { [ "$was_running" = 0 ] || "$init" start >> "$TMP/service.log" 2>&1; }
cleanup() {
    if [ "$committed" = 0 ] && [ "$installed" = 1 ]; then
        if running; then
            "$init" stop >> "$TMP/service.log" 2>&1 || return
            stopped=1
        fi
        cp -p "$TMP/original" "$yaml" 2>/dev/null || :
        cp "$TMP/owned" "$STATE/owned" 2>/dev/null || :
    fi
    if [ "$stopped" = 1 ] && ! running; then start_service || :; fi
    rm -rf "$TMP"
    [ "$own_lock" = 0 ] || rm -rf "$STATE/lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
: > "$TMP/conflicts"
: > "$TMP/owned"
if [ -d "$STATE/pending" ]; then
    result 'pending transaction; recovery files retained, manual recovery required'; exit 1
fi
# Uninstall can release ownership when AGH is no longer available.
release_without_edit() {
    schema=cleanup
    rm -f "$STATE/owned" "$STATE/config-path" || return 1
    result "$1; ownership released; YAML untouched"
}
# Discover the real process executable, config argument and working directory.
pid=$(pidof AdGuardHome 2>/dev/null | awk '{print $1}')
yaml=${Z2K_AGH_YAML:-}; bin=${Z2K_AGH_BIN:-}; init=${Z2K_AGH_INIT:-}; work=
if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    [ -n "$bin" ] || bin=$(readlink "/proc/$pid/exe")
    work=$(readlink "/proc/$pid/cwd")
    tr '\000' '\n' < "/proc/$pid/cmdline" > "$TMP/argv"
    prev=
    while IFS= read -r arg; do
        case "$prev" in -c|--config) [ -n "$yaml" ] || yaml=$arg;; -w|--work-dir) work=$arg;; esac
        case "$arg" in --config=*) [ -n "$yaml" ] || yaml=${arg#*=};; --work-dir=*) work=${arg#*=};; esac
        prev=$arg
    done < "$TMP/argv"
    [ -n "$yaml" ] || yaml=$work/AdGuardHome.yaml
fi
for f in /opt/etc/AdGuardHome.yaml /opt/etc/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml /opt/var/AdGuardHome/AdGuardHome.yaml /opt/share/AdGuardHome/AdGuardHome.yaml; do
    [ -n "$yaml" ] || { [ ! -f "$f" ] || yaml=$f; }
done
case "$yaml" in /*) ;; *) yaml=${work:-.}/$yaml;; esac
[ -n "$yaml" ] && [ -f "$yaml" ] || {
    if [ "$MODE" = remove ]; then release_without_edit 'AGH not found'; exit $?; fi
    result 'AGH not found'
    [ ! -s "$STATE/owned" ] || exit 1
    exit 0
}
# Resolve config identity; ledger never follows a switch to a different config.
yaml_dir=$(CDPATH= cd -- "$(dirname -- "$yaml")" && pwd) || exit 1
yaml=$yaml_dir/$(basename -- "$yaml")
[ -n "$work" ] || work=$yaml_dir
for f in /opt/bin/AdGuardHome /opt/sbin/AdGuardHome /opt/AdGuardHome/AdGuardHome /opt/share/AdGuardHome/AdGuardHome; do
    [ -n "$bin" ] || { [ ! -x "$f" ] || bin=$f; }
done
for f in /opt/etc/init.d/*[Aa]d[Gg]uard*; do
    [ -n "$init" ] || { [ ! -x "$f" ] || init=$f; }
done
if [ -f "$STATE/config-path" ]; then
    if [ "$(cat "$STATE/config-path")" != "$yaml" ]; then
        result 'config path changed; old ownership retained, manual cleanup required'; exit 1
    fi
    [ ! -f "$STATE/owned" ] || cp "$STATE/owned" "$TMP/owned"
fi
if [ "$MODE" = remove ] && [ ! -s "$TMP/owned" ]; then
    schema=cleanup; result 'no owned rewrites'; exit 0
fi
if running; then was_running=1; fi
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    if [ "$MODE" = remove ]; then release_without_edit 'AGH executable not found'; exit $?; fi
    result 'AGH executable not found'; exit 1
fi
if { [ "$was_running" = 1 ] || [ "$MODE" = remove ]; } && { [ -z "$init" ] || [ ! -x "$init" ]; }; then
    if [ "$MODE" = remove ]; then release_without_edit 'AGH init not found'; exit $?; fi
    result 'AGH init not found; refusing to stop'; exit 1
fi
: > "$TMP/desired"
if [ "$MODE" != remove ]; then
    hosts=$(awk -F'"' '/^HOSTS=/ {print $2; exit}' "$ZAPRET2_DIR/z2k-insta-ip-refresh.sh" 2>/dev/null)
    [ -n "$hosts" ] || { result 'refresher host list missing'; exit 1; }
    hosts="$hosts $WA_HOSTS"
    LD_LIBRARY_PATH= ndmc -c 'show running-config' > "$TMP/running" 2>/dev/null || { result 'ndmc failed'; exit 1; }
    awk -v hosts="$hosts" '
        function ipv4(ip, a,n,i) {n=split(ip,a,"."); if(n!=4)return 0; for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||a[i]>255)return 0; return 1}
        BEGIN {n=split(hosts,h," ");for(i=1;i<=n;i++)own[h[i]]=1}
        $1=="ip" && $2=="host" && ($3 in own) && ipv4($4) {print $3 "\t" $4}
    ' "$TMP/running" | sort -u > "$TMP/pins"
    # Only pinned names participate in the active comparison.
    hosts=$(awk '!seen[$1]++ {print $1}' "$TMP/pins")
    total=$(awk '!seen[$1]++ {n++} END {print n+0}' "$TMP/pins")
    if [ "$was_running" = 0 ]; then
        schema=stopped
        result 'AGH stopped by user; active probe unavailable, no changes'; exit 0
    fi
    # Read DNS bind_hosts/port only under dns:, never the HTTP bind port.
    awk '
        /^dns:/ {dns=1;next}
        /^[^ ]/ {dns=0}
        dns && /^[ ]+port:/ {print "port " $2}
        dns && /^[ ]+bind_hosts:/ {bind=1;next}
        bind && /^[ ]*-/ {s=$0;sub(/^[ ]*-[ ]*/,"",s);gsub(/["\047]/,"",s);print "host "s;next}
        bind {bind=0}
    ' "$yaml" > "$TMP/bind"
    port=$(awk '$1=="port"{print $2;exit}' "$TMP/bind")
    case "$port" in ''|*[!0-9]*) result 'unsupported DNS port'; exit 1;; esac
    netstat -lnptu > "$TMP/sockets" 2>/dev/null || { result 'listeners unavailable'; exit 1; }
    addr=
    for h in $(awk '$1=="host"{print $2}' "$TMP/bind"); do
        case "$h" in 0.0.0.0) h=127.0.0.1;; ::) h=::1;; esac
        if awk -v p="$port" -v h="$h" -v pid="$pid" '
            /AdGuardHome/ && (pid=="" || index($0,pid "/")) {
                s=$4; if(s==h ":" p || s=="["h"]:"p || s=="0.0.0.0:"p || s==":::"p || s=="[::]:"p) found=1
            } END {exit !found}' "$TMP/sockets"; then addr=$h; break; fi
    done
    [ -n "$addr" ] || { result 'AGH DNS listener not confirmed'; exit 1; }
    endpoint=$addr:$port
    tcp_query() {
        awk -v host="$1" 'BEGIN {
            for(i=1;i<128;i++) ord[sprintf("%c",i)]=i
            n=split(host,a,"."); len=18+length(host)
            printf "%c%c%c%c%c%c%c%c%c%c%c%c%c%c",int(len/256),len%256,231,42,1,0,0,1,0,0,0,0,0,0
            for(i=1;i<=n;i++){printf "%c",length(a[i]);for(j=1;j<=length(a[i]);j++)printf "%c",ord[substr(a[i],j,1)]}
            printf "%c%c%c%c%c",0,0,1,0,1
        }' | nc -w 3 "$addr" "$port" 2>/dev/null | od -v -b | awk '
            function u16(p){return b[p]*256+b[p+1]}
            function skip(p, loops) {
                while(p<=n && ++loops<256) {
                    if(b[p]==0)return p+1
                    if(b[p]>=192)return p+2
                    if(b[p]>63)return n+1
                    p+=b[p]+1
                } return n+1
            }
            {for(i=2;i<=NF;i++) {
                v=0; for(j=1;j<=length($i);j++) v=v*8+substr($i,j,1)
                b[++n]=v
            }}
            END {
                if(n<14 || u16(1)!=n-2 || b[3]!=231 || b[4]!=42 || b[5]<128 || int(b[5]/2)%2 || (b[6]%16!=0 && b[6]%16!=3))exit 1
                p=15; q=u16(7); an=u16(9)
                if(q!=1)exit 1
                p=skip(p)+4
                for(i=0;i<an;i++) {
                    p=skip(p); if(p+9>n)exit 1
                    t=u16(p);c=u16(p+2);l=u16(p+8);p+=10
                    if(p+l-1>n)exit 1
                    if(t==1 && c==1 && l==4) print b[p]"."b[p+1]"."b[p+2]"."b[p+3]
                    p+=l
                }
            }'
    }
    query() {
        # BIG nslookup parses -port= even though some help texts omit it.
        # A small/older applet rejects options, so use the TCP wire fallback.
        if busybox nslookup -port="$port" -type=A -timeout=2 -retry=1 "$1" "$addr" > "$TMP/answer" 2>/dev/null; then
            awk '
                /^Name:/ {answer=1;next}
                answer && /^Address([ ]+[0-9]+)?:/ {
                    for(i=2;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i
                }' "$TMP/answer" | sort -u
        else
            tcp_query "$1"
        fi
    }
    for h in $hosts; do
        if ! query "$h" > "$TMP/actual"; then
            result "AGH not responding for $h; no changes"; exit 1
        fi
        sort -u "$TMP/actual" > "$TMP/actual.sorted"
        awk -v h="$h" '$1==h {print $2}' "$TMP/pins" > "$TMP/expected"
        if [ -s "$TMP/expected" ] && cmp -s "$TMP/expected" "$TMP/actual.sorted"; then matched=$((matched+1)); fi
    done
    : > "$TMP/present-owned"
    : > "$TMP/empty"
    if ! awk -v ledger="$TMP/owned" -v desired="$TMP/empty" \
        -v newledger="$TMP/empty-ledger" -v conflictfile="$TMP/conflicts" \
        -v presentfile="$TMP/present-owned" -f "$SELF_DIR/z2k-agh-rewrites.awk" "$yaml" > "$TMP/without-owned"; then
        result 'unsupported rewrites YAML; no changes'; exit 1
    fi
    # Owned entries for now-unpinned names must be removed, but cannot prove
    # that the remaining matching answers came from upstream rather than us.
    awk 'FILENAME==ARGV[1] {pinned[$1]=1;next} $1 in pinned' \
        "$TMP/pins" "$TMP/present-owned" | sort -u > "$TMP/present-sorted"
    # Identical owned current rewrites mask upstream; never call that proof of
    # passthrough or remove/re-add them every other refresh.
    if [ "$matched" = "$total" ]; then
        if [ -s "$TMP/pins" ] && cmp -s "$TMP/present-sorted" "$TMP/pins"; then
            schema=managed-rewrites
            cp "$TMP/pins" "$TMP/desired"
        else
            schema=AGH-before-dns-proxy
        fi
    else
        schema=needs-rewrites
        cp "$TMP/pins" "$TMP/desired"
    fi
else
    schema=cleanup
fi
transform() {
    : > "$TMP/new-owned"; : > "$TMP/conflicts"
    awk -v ledger="$TMP/owned" -v desired="$TMP/desired" \
        -v newledger="$TMP/new-owned" -v conflictfile="$TMP/conflicts" \
        -f "$SELF_DIR/z2k-agh-rewrites.awk" "$yaml" > "$TMP/candidate" || return 1
    sort -u "$TMP/new-owned" > "$TMP/sorted-owned" && mv "$TMP/sorted-owned" "$TMP/new-owned"
}
transform || { result 'unsupported/disabled rewrites YAML; no changes'; exit 1; }
save_ledger() {
    if [ ! -f "$STATE/owned" ] || ! cmp -s "$TMP/new-owned" "$STATE/owned"; then
        cp "$TMP/new-owned" "$STATE/owned.new" && mv -f "$STATE/owned.new" "$STATE/owned" || return 1
    fi
    if [ ! -f "$STATE/config-path" ]; then printf '%s\n' "$yaml" > "$STATE/config-path"; fi
}
# Validate before stopping too: a malformed on-disk config must not leave a
# healthy running service unable to restart, or get hidden by its exit save.
if ! "$bin" --check-config -c "$TMP/candidate" -w "$work" >> "$TMP/check.log" 2>&1; then
    result 'check-config failed; no changes'; exit 1
fi
if cmp -s "$yaml" "$TMP/candidate"; then
    save_ledger || { result 'ownership save failed'; exit 1; }
    result 'unchanged'; exit 0
fi
if [ "$was_running" = 1 ]; then
    stopped=1
    if ! "$init" stop >> "$TMP/service.log" 2>&1; then result 'stop failed; no changes'; exit 1; fi
    stopped=1
    tries=0
    while running && [ "$tries" -lt 10 ]; do sleep 1; tries=$((tries+1)); done
    if running; then stopped=0; result 'AGH did not stop; no changes'; exit 1; fi
fi
# AGH saves YAML on exit. Never install a candidate built before that save.
transform || { result 'post-stop YAML unsupported; original retained'; exit 1; }
if cmp -s "$yaml" "$TMP/candidate"; then
    save_ledger || { result 'ownership save failed'; exit 1; }
    result 'unchanged after stop'; exit 0
fi
cp -p "$yaml" "$TMP/original" || { result 'backup failed'; exit 1; }
# Keep a recovery copy and both ledgers before mutation; do not forget ownership
# if power is lost between replacing YAML and committing the ledger.
if [ -e "$STATE/pending" ]; then result 'pending recovery exists; manual recovery required'; exit 1; fi
mkdir "$STATE/pending" || exit 1
cp -p "$TMP/original" "$STATE/pending/original.yaml" && \
    cp "$TMP/owned" "$STATE/pending/old-owned" && \
    cp "$TMP/new-owned" "$STATE/pending/new-owned" && \
    printf '%s\n' "$yaml" > "$STATE/pending/config-path" || exit 1
# Validate before replacement, using the real binary and original working dir.
if ! "$bin" --check-config -c "$TMP/candidate" -w "$work" >> "$TMP/check.log" 2>&1; then
    rm -rf "$STATE/pending"
    result 'check-config failed; original restored'; exit 1
fi
# Atomic same-directory replacement preserving file permissions/owner.
stage=$(mktemp "$yaml_dir/.z2k-agh.XXXXXX") || exit 1
if ! cp -p "$yaml" "$stage" || ! cat "$TMP/candidate" > "$stage" || ! mv -f "$stage" "$yaml"; then
    rm -f "$stage"; result 'config write failed'; exit 1
fi
installed=1
if [ "$was_running" = 1 ]; then
    if ! start_service || ! running; then
        result 'start failed; rolling back original YAML'
        # A failed start may still have left a process: stop before restoring.
        if running; then "$init" stop >> "$TMP/service.log" 2>&1 || exit 1; fi
        cp -p "$TMP/original" "$yaml" || exit 1
        installed=0
        rm -rf "$STATE/pending"
        exit 1
    fi
    stopped=0
fi
cp "$TMP/new-owned" "$STATE/owned.new" && mv -f "$STATE/owned.new" "$STATE/owned" && \
    printf '%s\n' "$yaml" > "$STATE/config-path" || exit 1
committed=1
rm -rf "$STATE/pending"
result 'applied'
exit 0
