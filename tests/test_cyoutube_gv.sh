#!/bin/sh
# Execute generator, geosite postprocessing and init DNS rules without router writes.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
ZAPRET2_DIR="$TMP/router"; EXTRA="$ZAPRET2_DIR/extra_strats"; TMP_DIR="$TMP/work"
export ZAPRET2_DIR
mkdir -p "$EXTRA/TCP/YT" "$EXTRA/TCP/YT_GV" "$EXTRA/UDP/YT" "$TMP_DIR" "$ZAPRET2_DIR/lua" "$ZAPRET2_DIR/lists"
cp "$ROOT/files/lua/z2k-preflight.lua" "$ZAPRET2_DIR/lua/"
# Stale GV list and polluted YT are intentional: generator must cover upgrades.
printf 'googlevideo.com\n' > "$EXTRA/TCP/YT_GV/List.txt"
printf 'youtube.com\nrr1---sn-test.c.youtube.com\n' > "$EXTRA/TCP/YT/List.txt"
printf 'youtube.com\ngooglevideo.com\n' > "$EXTRA/UDP/YT/List.txt"
# shellcheck disable=SC1091
. "$ROOT/lib/utils.sh" 2>/dev/null
# shellcheck disable=SC1091
. "$ROOT/lib/config_official.sh"
Z2K_GVSUB_IPS="$TMP/ips"; export Z2K_GVSUB_IPS
printf 'ENABLED=1\nZ2K_GV_SERVER_REPLY2=1\nZ2K_REFACTOR_PHASE3=0\n' > "$ZAPRET2_DIR/config"
create_official_config "$ZAPRET2_DIR/config" > "$TMP/generate.log" 2>&1
# Inspect actual generated profiles and apply domain suffix rules in order.
cat > "$TMP/check_profiles.py" <<'PY'
import pathlib, re, shlex, sys
s=pathlib.Path(sys.argv[1]).read_text()
s=re.search(r'NFQWS2_OPT="(.*?)"',s,re.S).group(1)
profiles=[shlex.split(p) for p in s.split('--new')]
def covers(host, domain):
    return host==domain or host.endswith('.'+domain)
def matches(p,host):
    includes=[];excludes=[]
    for t in p:
        if t.startswith('--hostlist=') or t.startswith('--hostlist-exclude='):
            path=t.split('=',1)[1]
            entries=pathlib.Path(path).read_text().splitlines() if pathlib.Path(path).exists() else []
            (excludes if t.startswith('--hostlist-exclude=') else includes).extend(entries)
        elif t.startswith('--hostlist-domains='): includes.extend(t.split('=',1)[1].split(','))
    return any(covers(host,d) for d in includes) and not any(covers(host,d) for d in excludes)
for host in ['rr1---sn-test.c.youtube.com','rr17.sn-test.c.youtube.com','c.youtube.com','rr1---sn-test.googlevideo.com','www.youtube.com']:
    tcp=[p for p in profiles if any(t.startswith('--filter-tcp=') for t in p) and matches(p,host)]
    assert tcp,host
    p=tcp[0];video=host!='www.youtube.com'
    assert any(('key=gv_tcp' if video else 'key=yt_tcp') in t for t in p),(host,p)
    assert any('z2k_preflight:' in t for t in p)==video,host
    if video:
        assert not any('key=yt_tcp' in t for t in p),host
        gvpath=next(t.split('=',1)[1] for t in p if t.startswith('--hostlist=') and '/YT_GV/' in t)
        if 'c.youtube.com' in pathlib.Path(gvpath).read_text().splitlines():
            assert not any(any('key=yt_tcp' in t for t in x) for x in tcp),host
udp=[p for p in profiles if '--filter-udp=443' in p]
assert any(matches(p,'rr1---sn-test.c.youtube.com') and any('key=quic' in t for t in p) for p in udp),udp
print('PASS: actual generator routes stale-list c.youtube.com to GV before YT; UDP/YT still covers it')
PY
python3 "$TMP/check_profiles.py" "$ZAPRET2_DIR/config"
# Real update-lists delegate, no network required. Preserve unrelated local GV entries.
log() { printf '%s\n' "$*" >> "$TMP/log"; }
for fn in subtract_googlevideo_from_yt subtract_yt_from_rkn; do
    eval "$(awk -v fn="$fn" '$0==fn "() {"{p=1} p{print} p&&/^}/{exit}' "$ROOT/files/z2k-geosite.sh")"
done
printf 'custom.example\n' >> "$EXTRA/TCP/YT_GV/List.txt"
printf 'youtube.com\nwww.youtube.com\ngooglevideo.com\nrr1---sn-x.googlevideo.com\nc.youtube.com\nrr1.sn-x.c.youtube.com\nRR2---SN-X.C.YOUTUBE.COM.\nevilc.youtube.com\nc.youtube.com.evil\n' > "$EXTRA/TCP/YT/List.txt"
cp "$EXTRA/TCP/YT/List.txt" "$EXTRA/UDP/YT/List.txt"
cp "$EXTRA/UDP/YT/List.txt" "$TMP/udp"
subtract_googlevideo_from_yt
printf 'youtube.com\nwww.youtube.com\nevilc.youtube.com\nc.youtube.com.evil\n' > "$TMP/want"
cmp "$TMP/want" "$EXTRA/TCP/YT/List.txt"
grep -qx c.youtube.com "$EXTRA/TCP/YT_GV/List.txt"
grep -qx custom.example "$EXTRA/TCP/YT_GV/List.txt"
grep -q ': applied,' "$TMP/log"
cmp "$TMP/udp" "$EXTRA/UDP/YT/List.txt"
cp "$EXTRA/TCP/YT_GV/List.txt" "$TMP/gv"
: > "$TMP/log"
subtract_googlevideo_from_yt
cmp "$TMP/gv" "$EXTRA/TCP/YT_GV/List.txt"
if grep -q ': applied,' "$TMP/log"; then echo 'FAIL: non-idempotent GV repair'; exit 1; fi
mkdir -p "$EXTRA/TCP/RKN"
printf 'c.youtube.com\nrr1---sn-x.c.youtube.com\nwww.youtube.com\nother.example\nother2.example\nother3.example\n' > "$EXTRA/TCP/RKN/List.txt"
subtract_yt_from_rkn
printf 'other.example\nother2.example\nother3.example\n' > "$TMP/want"
cmp "$TMP/want" "$EXTRA/TCP/RKN/List.txt"
create_official_config "$ZAPRET2_DIR/config" > "$TMP/generate.log" 2>&1
python3 "$TMP/check_profiles.py" "$ZAPRET2_DIR/config"
echo 'PASS: recurring list cleanup, suffix boundaries, GV upgrade, local additions, idempotence, UDP unchanged and RKN overlap'
# Init rule uses exact DNS wire suffix, in both families, with bypass and lo exclusion.
eval "$(awk '$0=="z2k_gvsub_dns_rule()"{p=1} p{print} p&&/^}/{exit}' "$ROOT/files/S99zapret2.new")"
Z2K_GVSUB_QUEUE=210
capture() { printf '%s\n' "$*"; }
for op in -C -I -D; do
    got=$(z2k_gvsub_dns_rule capture "$op" cache)
    case "$got" in *'! -o lo -p udp --sport 53 -m string --algo bm --icase --hex-string |016307796f757475626503636f6d00| -j NFQUEUE --queue-num 210 --queue-bypass') :;; *) echo "FAIL: $got"; exit 1;; esac
done
echo 'PASS: init DNS cache rule check/insert/delete'
