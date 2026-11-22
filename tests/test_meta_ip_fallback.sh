#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
export fixture
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/lists"
cp "$root/files/lists/meta-ranges.txt" "$fixture/lists/"
cat > "$fixture/bin/curl" <<'STUB'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
        --resolve) pair=$2; shift ;;
        --data) echo "$2" > "$fixture/request"; shift ;;
        https://*/resolve) relay=yes ;;
        https://*) url=$1 ;;
    esac
    shift
done
if [ "${relay:-}" = yes ]; then
    cat "$fixture/response"; exit
fi
h=${pair%%:*}
ip=${pair##*:}
case "$url" in "https://$h/"*) ;; *) exit 1 ;; esac
echo "$pair" >> "$fixture/probes"
: > "$out"
case "$h/$ip" in
    instagram.com/57.144.10.2) printf '301 https://www.instagram.com/' ;;
    api.instagram.com/57.144.10.2)
        if [ ! -e "$fixture/api-ready" ]; then touch "$fixture/api-ready"; exit 28; fi
        printf '301 https://api.instagram.com/robots.txt/' ;;
    graph.instagram.com/57.144.10.[12]) echo '{"type":"IGApiException"}' > "$out"; printf 400 ;;
    web.whatsapp.com/57.144.10.[23]) echo 'Allow: /accept*' > "$out"; printf 200 ;;
    scontent.xx.fbcdn.net/57.144.10.2) echo 'Unsigned URL' > "$out"; printf 403 ;;
    static.xx.fbcdn.net/*) echo 'wrong file' > "$out"; printf 200 ;;
    *) printf 404 ;;
esac
STUB
cat > "$fixture/bin/ndmc" <<'STUB'
#!/bin/sh
cmd=$2
case "$cmd" in
    'show running-config') cat "$fixture/records" ;;
    'no ip host '*) awk -v entry="${cmd#no }" '$0!=entry' "$fixture/records" > "$fixture/next"
        mv "$fixture/next" "$fixture/records"; echo "$cmd" >> "$fixture/actions" ;;
    'ip host '*) [ "$cmd" != "$(cat "$fixture/reject")" ] || exit 1
        echo "$cmd" >> "$fixture/records"; echo "$cmd" >> "$fixture/actions" ;;
    *) echo "$cmd" >> "$fixture/actions" ;;
esac
STUB
printf '#!/bin/sh\ncat >/dev/null; echo signature\n' > "$fixture/bin/openssl"
cat > "$fixture/bin/conntrack" <<'STUB'
#!/bin/sh
echo "$*" >> "$fixture/flushed"
STUB
chmod +x "$fixture/bin/"*
cat > "$fixture/response" <<'JSON'
{"results":{"api.instagram.com":["57.144.10.2"],"graph.instagram.com":["57.144.10.1","57.144.10.8"],"instagram.com":["57.144.10.8"],"web.whatsapp.com":["57.144.10.2","57.144.10.2","57.144.10.3","1.1.1.1"]}}
JSON
cat > "$fixture/records" <<'PINS'
ip host instagram.com 57.144.10.8
ip host static.xx.fbcdn.net 57.144.10.9
ip host other.example 57.144.10.8
ip host graph.instagram.com 57.144.10.1
PINS
touch "$fixture/config" "$fixture/actions" "$fixture/reject"
run() {
    Z2K_STUB_PATH="$fixture/bin" ZAPRET2_DIR="$fixture" CONFIG_FILE="$fixture/config" \
        LOG_FILE="$fixture/log" sh "$root/files/z2k-insta-ip-refresh.sh"
}
has() { grep -Fxq "ip host $1 $2" "$fixture/records"; }
run
grep -q '"static.xx.fbcdn.net","scontent.xx.fbcdn.net"' "$fixture/request"
has instagram.com 57.144.10.2
[ ! -s "$fixture/flushed" ]
if has instagram.com 57.144.10.8; then exit 1; fi
has graph.instagram.com 57.144.10.1
has graph.instagram.com 57.144.10.2
has scontent.xx.fbcdn.net 57.144.10.2
has api.instagram.com 57.144.10.2
[ "$(grep -c '^api.instagram.com:443:57.144.10.2$' "$fixture/probes")" = 2 ]
has static.xx.fbcdn.net 57.144.10.9
[ "$(grep -c 'static.xx.fbcdn.net' "$fixture/records")" = 1 ]
[ "$(grep -c '^static.xx.fbcdn.net:443:57.144.10.2$' "$fixture/probes")" = 1 ]
if grep -Fq ':443:1.1.1.1' "$fixture/probes"; then exit 1; fi
if grep -Fq 'no ip host graph.instagram.com 57.144.10.1' "$fixture/actions"; then exit 1; fi
: > "$fixture/actions"
run
[ ! -s "$fixture/actions" ]
# A failed write must not remove the only existing address.
echo 'ip host instagram.com 57.144.10.2' > "$fixture/reject"
echo 'ip host instagram.com 57.144.10.8' > "$fixture/records"
run
has instagram.com 57.144.10.8
# No verified candidates anywhere: keep the existing pins.
echo '{"results":{"instagram.com":["57.144.10.8"]}}' > "$fixture/response"
: > "$fixture/actions"
run
[ ! -s "$fixture/actions" ]
echo 'PASS: cross-host replacement, partial recovery, incompatible CDN, range checks, retry and no-candidate preservation'
