#!/bin/sh
# Explicit field test, not an installer. Run only with owner authorization.
# MODE HOST IPv4 URL SOURCE_PORT RESULT_DIR [STRATEGY]
set -eu
set -f
[ "$#" -ge 6 ] && [ "$#" -le 7 ] || { echo 'usage: direct|control|compact|compact-only HOST IPv4 URL SOURCE_PORT RESULT_DIR [STRATEGY]' >&2; exit 2; }
mode=$1; host=$2; ip=$3; url=$4; sport=$5; dir=$6; strategy=${7:-1}
case "$strategy" in ''|*[!0-9]*|0) exit 2 ;; esac
tlsopt=
case "${Z2K_STAND_HELLO:-default}" in
    default) ;;
    short) tlsopt='--curves X25519' ;;
    *) exit 2 ;;
esac
case "$mode" in direct|control|compact|compact-only) ;; *) exit 2 ;; esac
case "$host" in ''|*[!a-zA-Z0-9.-]*) exit 2 ;; esac
case "$ip" in ''|*[!0-9.]*) exit 2 ;; esac
case "$sport" in ''|*[!0-9]*) exit 2 ;; esac
[ "$sport" -ge 1024 ] && [ "$sport" -le 65533 ] || exit 2
case "$url" in "https://$host/"*) ;; *) echo 'URL must use the stated host' >&2; exit 2 ;; esac
case "$dir" in /tmp/z2k-tcp16-field.*) ;; *) echo 'result directory must be /tmp/z2k-tcp16-field.*' >&2; exit 2 ;; esac
[ -d "$dir" ] && [ -r "$dir/z2k-tcp16.lua" ] || exit 2
[ -r /opt/zapret2/extra_strats/TCP/RKN/Strategy.txt ] || exit 2
for f in asn.txt nets.txt sni.txt; do [ -r "$dir/$f" ] || exit 2; done
grep -qx 'DESYNC_MARK=0x40000000' /opt/zapret2/config || { echo 'unexpected production mark' >&2; exit 2; }
# Refuse busy queue/ports and an existing chain; never clean someone else's test.
awk '$1 == 399 {busy=1} END {exit !busy}' /proc/net/netfilter/nfnetlink_queue && exit 2
attempts=${Z2K_STAND_ATTEMPTS:-3}
case "$attempts" in 1|2|3) ;; *) exit 2 ;; esac
endport=$((sport + attempts - 1))
localip=$(ip -4 route get "$ip" | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')
case "$localip" in ''|*[!0-9.]*) echo 'cannot determine local source IPv4' >&2; exit 2 ;; esac
netstat -ant | awk -v lo="$sport" -v hi="$endport" '
    {n=split($4,a,":"); if (a[n]>=lo && a[n]<=hi) busy=1} END {exit !busy}' && exit 2
chain=Z2K_T16_TEST
if iptables -t mangle -S "$chain" >/dev/null 2>&1; then exit 2; fi
pid=$(pidof nfqws2 | awk '{print $1}')
[ -n "$pid" ] || exit 2
base=$(tr '\0' '\n' < "/proc/$pid/cmdline" | grep -E '^--(lua-init|blob)=' | tr '\n' ' ')
[ -n "$base" ] || exit 2
inst=
# Pool tokens, not lines; pathname expansion is disabled above.
# shellcheck disable=SC2013
for token in $(cat /opt/zapret2/extra_strats/TCP/RKN/Strategy.txt); do
    case "$token" in --lua-desync=*) inst="$inst $token" ;; esac
done
printf '%s\n' "$inst" | grep -q ":strategy=$strategy\( \|$\)" || exit 2
prelude=
case "$mode" in compact|compact-only) prelude='--lua-desync=z2k_sni_fake:payload=tls_client_hello:dir=out:repeats=8:tcp_ts=-1000:tcp_md5' ;; esac
case "$mode" in direct|compact-only) inst='--lua-desync=pass' ;; esac
run="$dir/$mode-$strategy"
mkdir "$run" # refuse overwriting evidence
mkdir "$run/state" "$run/fallback"
hostkey=$(printf '%s' "$host" | awk -F. '{print $(NF-1) "." $NF}')
printf 'rkn_tcp\t%s|4\t%s\t%s\tfrozen\n' "$hostkey" "$strategy" "$(date +%s)" > "$run/state/state.tsv"
printf '%s\n' "$inst" > "$run/instances.txt"
date > "$run/before.time"
iptables-save -t mangle > "$run/before.rules"
netstat -ant > "$run/before.connections"
printf '%s\n' "$pid" > "$run/production.pid"
cat "/proc/$pid/stat" > "$run/production.stat"
engpid=; cappid=; linked=0; inlinked=0; made=0
cleanup() {
    result=$?
    cleanup_failed=0
    if [ "$inlinked" = 1 ]; then
        iptables -t mangle -D PREROUTING -p tcp -d "$localip" -s "$ip" --sport 443 --dport "$sport:$endport" -j "$chain" || cleanup_failed=1
    fi
    if [ "$linked" = 1 ]; then
        iptables -t mangle -D OUTPUT -p tcp -s "$localip" -d "$ip" --sport "$sport:$endport" --dport 443 -m mark ! --mark 0x10000000/0x10000000 -j "$chain" || cleanup_failed=1
    fi
    if [ "$made" = 1 ]; then
        iptables -t mangle -F "$chain" || cleanup_failed=1
        iptables -t mangle -X "$chain" || cleanup_failed=1
    fi
    [ -z "$engpid" ] || { kill "$engpid" 2>/dev/null || true; wait "$engpid" 2>/dev/null || true; }
    [ -z "$cappid" ] || { kill "$cappid" 2>/dev/null || true; wait "$cappid" 2>/dev/null || true; }
    iptables-save -t mangle > "$run/after.rules"
    date > "$run/after.time"
    netstat -ant > "$run/after.connections"
    cat "/proc/$pid/stat" > "$run/production.after.stat" 2>/dev/null || cleanup_failed=1
    [ "$(awk '{print $22}' "$run/production.stat")" = "$(awk '{print $22}' "$run/production.after.stat")" ] || cleanup_failed=1
    # iptables-save includes built-in chain counters even without -c.
    sed '/^#/d; /^:/s/ \[[0-9]*:[0-9]*\]$/ [0:0]/' "$run/before.rules" > "$run/before.rules.normalized"
    sed '/^#/d; /^:/s/ \[[0-9]*:[0-9]*\]$/ [0:0]/' "$run/after.rules" > "$run/after.rules.normalized"
    cmp -s "$run/before.rules.normalized" "$run/after.rules.normalized" || cleanup_failed=1
    if [ "$cleanup_failed" = 1 ]; then
        echo 'CLEANUP OR RULE COMPARISON FAILED: inspect saved evidence' >&2
        exit 1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Only the new engine sees this Lua/state; the working service stays untouched.
# shellcheck disable=SC2086
Z2K_STATE_DIR_OVERRIDE="$run/state" Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$run/fallback" \
Z2K_TCP16_ASN="$dir/asn.txt" Z2K_TCP16_NETS="$dir/nets.txt" \
Z2K_TCP16_SNI="$dir/sni.txt" \
/opt/zapret2/nfq2/nfqws2 --qnum=399 --fwmark=0x10000000 --debug=1 $base \
    --lua-init=@"$dir/z2k-tcp16.lua" --filter-tcp=443 --filter-l7=tls \
    --payload=tls_client_hello --out-range=-s34228 --in-range=-s5556 $prelude $inst > "$run/engine.log" 2>&1 &
engpid=$!
i=0
until awk '$1 == 399 {ready=1} END {exit !ready}' /proc/net/netfilter/nfnetlink_queue; do
    kill -0 "$engpid" 2>/dev/null || exit 1
    i=$((i+1)); [ "$i" -le 100 ] || exit 1
    usleep 100000
done
tcpdump --immediate-mode -i any -s 0 -U -w "$run/traffic.pcap" "host $ip and tcp port 443 and portrange $sport-$endport" > "$run/capture.log" 2>&1 &
cappid=$!
i=0
until grep -q 'listening on' "$run/capture.log" 2>/dev/null; do
    kill -0 "$cappid" 2>/dev/null || exit 1
    i=$((i+1)); [ "$i" -le 100 ] || exit 1
    usleep 100000
done
iptables -t mangle -N "$chain"; made=1
iptables -t mangle -A "$chain" -j MARK --set-xmark 0x40000000/0x40000000
iptables -t mangle -A "$chain" -j NFQUEUE --queue-num 399 --queue-bypass
iptables -t mangle -A "$chain" -j ACCEPT
iptables -t mangle -I OUTPUT 1 -p tcp -s "$localip" -d "$ip" --sport "$sport:$endport" --dport 443 -m mark ! --mark 0x10000000/0x10000000 -j "$chain"
linked=1
iptables -t mangle -I PREROUTING 1 -p tcp -d "$localip" -s "$ip" --sport 443 --dport "$sport:$endport" -j "$chain"
inlinked=1
p=$sport
while [ "$p" -le "$endport" ]; do
    # No -k: real host, normal certificate validation; no redirect/reconnect
    # hidden in a nominally successful volume result.
    rc=0
    # shellcheck disable=SC2086
    curl -q --noproxy '*' -4 -sS $tlsopt --local-port "$p" --resolve "$host:443:$ip" --max-time 8 \
        -o "$run/body.$p" -w '%{http_code}\t%{size_download}\t%{time_total}\n' "$url" \
        > "$run/result.$p" 2> "$run/curl.$p.log" || rc=$?
    printf '%s\n' "$rc" > "$run/exit.$p"
    p=$((p+1))
done

if grep -q 'LUA ERROR' "$run/engine.log"; then
    echo 'engine Lua error: run is invalid' >&2
    exit 1
fi
