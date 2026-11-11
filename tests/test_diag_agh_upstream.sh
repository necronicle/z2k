#!/bin/sh
# Diagnostic must use recorded ACTIVE comparison, never upstream heuristics.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/agh-sync" "$SB/bin"
for fn in insta_pinned print_insta_pins print_agh; do
    awk -v f="$fn" 'index($0,f "() {")==1,/^\}/' "$ROOT/files/z2k-diag.sh" >> "$SB/functions"
done
cat > "$SB/bin/ndmc" <<'STUB'
#!/bin/sh
cat "$PINS"
STUB
chmod +x "$SB/bin/ndmc"
cp "$ROOT/files/z2k-insta-ip-refresh.sh" "$SB/"
awk -F'"' '/^HOSTS=/ {n=split($2,h," ");for(i=1;i<=n;i++)print "ip host "h[i]" 1.2.3.4"}' "$SB/z2k-insta-ip-refresh.sh" > "$SB/pins"
for h in whatsapp.com whatsapp.net g.whatsapp.net static.whatsapp.net mmg.whatsapp.net pps.whatsapp.net dit.whatsapp.net v.whatsapp.net crashlogs.whatsapp.net; do
    echo "ip host $h 85.192.60.175" >> "$SB/pins"
done
export ZAPRET2_DIR="$SB" PATH="$SB/bin:$PATH" PINS="$SB/pins" SB
printf '\nprint_insta_pins\nprint_agh\n' >> "$SB/functions"
# Upstream file overrides local YAML list; selector is for an unrelated domain.
cat > "$SB/agh.yaml" <<'YAML'
dns:
  upstream_dns: ['[/other.test/]127.0.0.1:53']
  upstream_dns_file: /external/upstreams
YAML
export Z2K_AGH_YAML="$SB/agh.yaml"
out=$("${Z2K_TEST_SH:-sh}" "$SB/functions")
printf '%s\n' "$out" | grep -q 'веб 12/12, мобильный WA 9/9'
printf '%s\n' "$out" | grep -q 'активная проверка ещё не выполнялась'
case "$out" in *'и это норма'*|*'будет работать через раз'*|*'работать не будет'*) exit 1;; esac
cat > "$SB/agh-sync/last-result" <<'STATE'
time=2026-11-11 12:00:00 +0300
schema=AGH-before-dns-proxy
match=21/21
endpoint=127.0.0.1:5300
result=unchanged
conflicts=instagram.com
STATE
out=$("${Z2K_TEST_SH:-sh}" "$SB/functions")
for value in AGH-before-dns-proxy 21/21 instagram.com '2026-11-11 12:00:00' 127.0.0.1:5300; do
    printf '%s\n' "$out" | grep -qF "$value"
done
echo 'PASS: active result, timestamp, conflict, endpoint and 12+9 counts; no upstream guesses'
