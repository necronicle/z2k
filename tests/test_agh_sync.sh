#!/bin/sh
# Executes the shipped orchestrator; fixtures replace router/service boundaries.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/z2k"
export ROOT SB ZAPRET2_DIR="$SB/z2k" Z2K_STUB_PATH="$SB/bin"
export Z2K_AGH_YAML="$SB/agh.yaml" Z2K_AGH_BIN="$SB/bin/AdGuardHome" Z2K_AGH_INIT="$SB/bin/service"
export CONFIG_FILE="$SB/z2k/config" Z2K_AGH_STATE_DIR="$SB/state"
cp "$ROOT/files/z2k-insta-ip-refresh.sh" "$SB/z2k/"
cat > "$SB/bin/ndmc" <<'STUB'
#!/bin/sh
case "$2" in
'show running-config') cat "$SB/pins" ;;
'no ip host '*)
    printf '%s\n' "$2" >> "$SB/ndmc.log"
    awk -v line="${2#no }" '$0!=line' "$SB/pins" > "$SB/pins.new"
    mv "$SB/pins.new" "$SB/pins" ;;
esac
STUB
cat > "$SB/bin/pidof" <<'STUB'
#!/bin/sh
[ -f "$SB/running" ] && echo 12345
STUB
cat > "$SB/bin/netstat" <<'STUB'
#!/bin/sh
printf 'udp 0 0 127.0.0.1:5300 0.0.0.0:* 12345/AdGuardHome\n'
STUB
cat > "$SB/bin/busybox" <<'STUB'
#!/bin/sh
[ "$1" = nslookup ] || exit 1
# Require the real configured port, A-only and explicit server.
case "$*" in *'-port=5300'*'-type=A'*'127.0.0.1'*) ;; *) exit 1;; esac
[ ! -f "$SB/timeout" ] || exit 1
for host do :; done
# host is penultimate argument
while [ "$#" -gt 2 ]; do shift; done
h=$1
printf 'Server: 127.0.0.1\nAddress: 127.0.0.1:5300\n\nName: %s\n' "$h"
if [ -f "$SB/match" ]; then
    awk -v h="$h" '$3==h {print "Address: " $4}' "$SB/pins"
else
    echo 'Address: 9.9.9.9'
fi
STUB
cat > "$SB/bin/service" <<'STUB'
#!/bin/sh
printf '%s\n' "$1" >> "$SB/service.log"
case "$1" in
stop) rm -f "$SB/running"
      if [ -f "$SB/exit-save" ]; then cat "$SB/exit-save" >> "$SB/agh.yaml"; fi ;;
start) if [ -f "$SB/fail-start" ]; then rm "$SB/fail-start"; exit 1; fi
       touch "$SB/running" ;;
esac
STUB
cat > "$SB/bin/AdGuardHome" <<'STUB'
#!/bin/sh
case "$*" in *--check-config*) echo check >> "$SB/check.log"; [ ! -f "$SB/bad-config" ];; *) exit 1;; esac
STUB
chmod +x "$SB/bin/"*
run() { "${Z2K_TEST_SH:-sh}" "$ROOT/files/z2k-agh-sync.sh" "${1:-sync}"; }
reset_case() {
    rm -rf "$SB/state"
    rm -f "$SB/"*.log "$SB/match" "$SB/timeout" "$SB/bad-config" "$SB/exit-save" "$SB/fail-start"
    touch "$SB/running"
    : > "$CONFIG_FILE"
    awk -F'"' '/^HOSTS=/ {n=split($2,h," "); for(i=1;i<=n;i++) print "ip host "h[i]" 1.2.3.4"}' "$SB/z2k/z2k-insta-ip-refresh.sh" > "$SB/pins"
    for h in whatsapp.com whatsapp.net g.whatsapp.net static.whatsapp.net mmg.whatsapp.net pps.whatsapp.net dit.whatsapp.net v.whatsapp.net crashlogs.whatsapp.net; do
        echo "ip host $h 85.192.60.175" >> "$SB/pins"
    done
    cat > "$SB/agh.yaml" <<'YAML'
dns:
  bind_hosts:
    - 127.0.0.1
  port: 5300
  upstream_dns_file: /user/upstreams
filtering:
  rewrites:
    - domain: user.test
      answer: 8.8.8.8
  protection_enabled: true
YAML
    cp "$SB/agh.yaml" "$SB/original"
}
assert_same() { cmp -s "$1" "$2" || { echo "FAIL: $3"; exit 1; }; }
reset_case
touch "$SB/match"
run
assert_same "$SB/original" "$SB/agh.yaml" 'passthrough changed yaml'
[ ! -e "$SB/service.log" ]
echo 'PASS: active passthrough does not write'
reset_case
run
grep -q 'domain: crashlogs.whatsapp.net' "$SB/agh.yaml"
grep -q 'domain: instagram.com' "$SB/agh.yaml"
grep -q 'domain: user.test' "$SB/agh.yaml"
[ "$(wc -l < "$SB/service.log" | tr -d ' ')" = 2 ]
cp "$SB/agh.yaml" "$SB/after"
run
assert_same "$SB/after" "$SB/agh.yaml" idempotence
[ "$(wc -l < "$SB/service.log" | tr -d ' ')" = 2 ]
# Own current answers cannot be used to infer upstream and trigger oscillation.
touch "$SB/match"
run
[ "$(wc -l < "$SB/service.log" | tr -d ' ')" = 2 ]
run remove
assert_same "$SB/original" "$SB/agh.yaml" 'uninstall lost foreign elements'
echo 'PASS: writes all pins, preserves user, idempotent, removes owned only'
reset_case
sed 's/user.test/instagram.com/' "$SB/agh.yaml" > "$SB/tmp"
mv "$SB/tmp" "$SB/agh.yaml"
run
[ "$(grep -c 'domain: instagram.com$' "$SB/agh.yaml")" = 1 ]
grep -q 'answer: 8.8.8.8' "$SB/agh.yaml"
grep -q instagram.com "$SB/state/last-result"
echo 'PASS: conflict preserved and reported'
reset_case
touch "$SB/bad-config"
run && { echo 'FAIL: check-config failure ignored'; exit 1; }
assert_same "$SB/original" "$SB/agh.yaml" rollback
[ -f "$SB/running" ]
echo 'PASS: check-config failure restores config and service'
reset_case
rm "$SB/running"
run
[ ! -f "$SB/running" ]
[ ! -e "$SB/service.log" ]
echo 'PASS: user stopped service stays stopped'
reset_case
touch "$SB/timeout"
run || :
assert_same "$SB/original" "$SB/agh.yaml" timeout
[ ! -e "$SB/service.log" ]
echo 'PASS: timeout leaves configuration untouched'
reset_case
run
cp "$SB/agh.yaml" "$SB/after"
printf 'Z2K_INSTA_DNS=0\n' > "$CONFIG_FILE"
run
assert_same "$SB/after" "$SB/agh.yaml" 'DNS flag removed actual pins'
run
assert_same "$SB/after" "$SB/agh.yaml" 'DNS flag changed rewrites'
echo 'PASS: DNS flag preserves actual pins including WA'
reset_case
printf 'user_setting: exit-saved\n' > "$SB/exit-save"
run
grep -q 'user_setting: exit-saved' "$SB/agh.yaml"
echo 'PASS: rereads config after stop'
reset_case
run
rm "$SB/running"
run remove
assert_same "$SB/original" "$SB/agh.yaml" 'stopped uninstall'
[ ! -f "$SB/running" ]
[ "$(wc -l < "$SB/service.log" | tr -d ' ')" = 2 ]
echo 'PASS: uninstall edits stopped AGH without starting it'
reset_case
run
# Outdated owned block is no longer the source of matching active answers.
sed 's/1.2.3.4/2.3.4.5/g; s/85.192.60.175/2.3.4.6/g' "$SB/pins" > "$SB/new-pins"
mv "$SB/new-pins" "$SB/pins"
touch "$SB/match"
run
assert_same "$SB/original" "$SB/agh.yaml" 'passthrough must drop obsolete owned block'
[ "$(wc -l < "$SB/service.log" | tr -d ' ')" = 4 ]
echo 'PASS: active passthrough removes old owned generation in one restart'
reset_case
sed "s/user.test/'*.whatsapp.net'/" "$SB/agh.yaml" > "$SB/tmp"; mv "$SB/tmp" "$SB/agh.yaml"
run
! grep -q 'domain: g.whatsapp.net$' "$SB/agh.yaml"
grep -q 'domain:.*\*.whatsapp.net' "$SB/agh.yaml"
echo 'PASS: wildcard conflict preserved'
reset_case
sed 's/user.test/instagram.com/;s/8.8.8.8/1.2.3.4/' "$SB/agh.yaml" > "$SB/tmp"; mv "$SB/tmp" "$SB/agh.yaml"
cp "$SB/agh.yaml" "$SB/foreign-original"
run
run remove
assert_same "$SB/foreign-original" "$SB/agh.yaml" 'pre-existing matching pair was adopted'
echo 'PASS: matching foreign pair never adopted'
reset_case
run
cp "$SB/agh.yaml" "$SB/after"
printf 'Z2K_INSTA_IP_REFRESH=0\n' > "$CONFIG_FILE"
run
assert_same "$SB/after" "$SB/agh.yaml" 'refresh flag removed actual pins'
echo 'PASS: refresh flag preserves actual pins including WA'
reset_case
# Existing empty rewrites list must round-trip.
sed '/    - domain:/d;/      answer:/d;s/rewrites:/rewrites: []/' "$SB/agh.yaml" > "$SB/tmp"; mv "$SB/tmp" "$SB/agh.yaml"
cp "$SB/agh.yaml" "$SB/empty-original"
run
run remove
assert_same "$SB/empty-original" "$SB/agh.yaml" 'empty list round trip'
echo 'PASS: empty rewrites round trip'
# Execute refresher unchanged path with the real delivered helper and shared lock.
reset_case
cp "$ROOT/files/z2k-agh-sync.sh" "$ROOT/files/z2k-agh-rewrites.awk" "$SB/z2k/"
cat > "$SB/bin/openssl" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'signature= abc123\n'
STUB
cat > "$SB/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in */resolve*) printf '{"results":{"instagram.com":["1.2.3.4"]}}';; *) printf '200';; esac
STUB
chmod +x "$SB/bin/openssl" "$SB/bin/curl"
LOG_FILE="$SB/refresh.log" Z2K_IP_PROBE=0 "${Z2K_TEST_SH:-sh}" "$SB/z2k/z2k-insta-ip-refresh.sh"
grep -q 'unchanged instagram.com' "$SB/refresh.log"
grep -q 'domain: crashlogs.whatsapp.net' "$SB/agh.yaml"
[ ! -d "$SB/state/lock" ]
cp "$SB/service.log" "$SB/service-before"
LOG_FILE="$SB/refresh.log" Z2K_IP_PROBE=0 "${Z2K_TEST_SH:-sh}" "$SB/z2k/z2k-insta-ip-refresh.sh"
assert_same "$SB/service-before" "$SB/service.log" 'unchanged refresh restarted AGH'
echo 'PASS: real unchanged refresher synchronizes AGH and shares/relinquishes lock'
# Execute the production menu clear with only UI/ndmc boundaries replaced.
awk '/^menu_instagram_dns\(\) \{/,/^\}/' "$ROOT/lib/menu.sh" > "$SB/menu-functions"
cat > "$SB/menu-run" <<'MENU'
. "$ROOT/lib/utils.sh"
clear_screen() { :; }
print_header() { :; }
print_info() { :; }
print_warning() { :; }
print_error() { :; }
print_success() { :; }
print_separator() { :; }
pause() { :; }
confirm() { return 0; }
. "$SB/menu-functions"
menu_instagram_dns
MENU
env PATH="$SB/bin:$PATH" "${Z2K_TEST_SH:-sh}" "$SB/menu-run" > /dev/null
! grep -q 'domain: instagram.com$' "$SB/agh.yaml"
grep -q 'domain: web.whatsapp.com$' "$SB/agh.yaml"
grep -q 'domain: crashlogs.whatsapp.net$' "$SB/agh.yaml"
! grep -q 'no ip host .*whatsapp' "$SB/ndmc.log"
grep -q '^ip host web.whatsapp.com ' "$SB/pins"
grep -q '^ip host whatsapp.com ' "$SB/pins"
grep -q '^Z2K_INSTA_DNS=0$' "$CONFIG_FILE"
echo 'PASS: real menu clears Instagram only and preserves all WA pins'
# Run only the pre-mutation uninstall prefix, through its real AGH cleanup.
reset_case
run
awk '/^uninstall_zapret2\(\) \{/,/    # СБОЙ ОДНОЙ КОМАНДЫ/ {if($0 !~ /    # СБОЙ ОДНОЙ КОМАНДЫ/) print}' "$ROOT/lib/install.sh" > "$SB/uninstall-functions"
printf '}\n' >> "$SB/uninstall-functions"
mkdir -p "$SB/z2k/nfq2"
: > "$SB/z2k/nfq2/nfqws2"
chmod +x "$SB/z2k/nfq2/nfqws2"
cat > "$SB/uninstall-run" <<'UNINSTALL'
. "$ROOT/lib/utils.sh"
print_header() { :; }
print_info() { :; }
print_warning() { echo "$1"; }
print_error() { :; }
confirm() { return 1; }
. "$SB/uninstall-functions"
uninstall_zapret2
UNINSTALL
cp "$SB/agh.yaml" "$SB/before-cancel"
"${Z2K_TEST_SH:-sh}" "$SB/uninstall-run" >/dev/null
assert_same "$SB/before-cancel" "$SB/agh.yaml" 'cancelled uninstall changed AGH'
Z2K_UNINSTALL_CONFIRMED=1 "${Z2K_TEST_SH:-sh}" "$SB/uninstall-run" >/dev/null
assert_same "$SB/original" "$SB/agh.yaml" 'confirmed uninstall did not remove owned'
echo 'PASS: real uninstall confirmation and owned cleanup'
reset_case
run
awk '/^# DNS-пины остальных доменов/,/^# Бинарь и его init-скрипт/ {if($0 !~ /^# Бинарь и его init-скрипт/)print}' "$ROOT/z2k_cleanup.sh" > "$SB/cleanup-block"
cat > "$SB/cleanup-run" <<'CLEANUP'
. "$ROOT/lib/utils.sh"
. "$ROOT/lib/install.sh"
log_info() { :; }
log_skip() { :; }
log_error() { :; }
log_warn() { echo "$1" >> "$SB/warnings"; }
. "$SB/cleanup-block"
CLEANUP
env PATH="$SB/bin:$PATH" "${Z2K_TEST_SH:-sh}" "$SB/cleanup-run" >/dev/null
assert_same "$SB/original" "$SB/agh.yaml" 'standalone cleanup did not remove owned'
echo 'PASS: real standalone cleanup removes only owned rewrites'

reset_case
run
# AGH may serialize enabled:true and quote scalar fields on clean exit.
awk '{if($1=="domain:" || $1=="answer:") sub($2,"\"" $2 "\""); print}' "$SB/agh.yaml" > "$SB/serialized"
mv "$SB/serialized" "$SB/agh.yaml"
cp "$SB/agh.yaml" "$SB/serialized-before"
cp "$SB/service.log" "$SB/service-before"
run
assert_same "$SB/serialized-before" "$SB/agh.yaml" 'serialization must not cause restart'
assert_same "$SB/service-before" "$SB/service.log" 'serialization restarted AGH'
echo 'PASS: AGH serialization does not trigger repeated restart'

reset_case
# Four-space mapping indent is common in AGH's own YAML encoder.
sed 's/^  /    /;s/^      /        /' "$SB/agh.yaml" > "$SB/indented"
mv "$SB/indented" "$SB/agh.yaml"
run
# Existing sequence indentation is preserved for additions too.
awk '/- domain: user.test/ {match($0,/[^ ]/); old=RSTART}
     /- domain: instagram.com$/ {match($0,/[^ ]/); new=RSTART}
     END {exit !(old && old==new)}' "$SB/agh.yaml"
echo 'PASS: existing sequence indentation preserved'
reset_case
touch "$SB/fail-start"
if run; then echo 'FAIL: start failure ignored'; exit 1; fi
assert_same "$SB/original" "$SB/agh.yaml" 'start failure rollback'
[ -f "$SB/running" ]
echo 'PASS: failed start rolls back and restores original running service'
reset_case
printf '  rewrites_enabled: false\n' >> "$SB/agh.yaml"
cp "$SB/agh.yaml" "$SB/disabled-original"
if run; then echo 'FAIL: disabled rewrites enabled implicitly'; exit 1; fi
assert_same "$SB/disabled-original" "$SB/agh.yaml" 'disabled rewrites changed'
[ ! -e "$SB/service.log" ]
echo 'PASS: disabled rewrites remain disabled without restart'

reset_case
sed '/^ip host crashlogs.whatsapp.net /d' "$SB/pins" > "$SB/tmp"
mv "$SB/tmp" "$SB/pins"
touch "$SB/match"
run
grep -q '^match=20/20$' "$SB/state/last-result"
grep -q '^schema=AGH-before-dns-proxy$' "$SB/state/last-result"
assert_same "$SB/original" "$SB/agh.yaml" 'unpinned name caused writes'
[ ! -e "$SB/service.log" ]
echo 'PASS: unpinned name does not prevent passthrough'
reset_case
run
: > "$SB/pins"
run
assert_same "$SB/original" "$SB/agh.yaml" 'absent pins kept owned rewrites'
grep -q '^match=0/0$' "$SB/state/last-result"
echo 'PASS: removing all router pins removes owned rewrites'
for missing in yaml bin init; do
    reset_case
    run
    cp "$SB/agh.yaml" "$SB/before-missing"
    case "$missing" in
        yaml) export Z2K_AGH_YAML="$SB/missing.yaml" ;;
        bin) export Z2K_AGH_BIN="$SB/missing-bin" ;;
        init) export Z2K_AGH_INIT="$SB/missing-init" ;;
    esac
    run remove
    [ ! -s "$SB/state/owned" ]
    [ ! -f "$SB/state/config-path" ]
    grep -q 'YAML untouched' "$SB/state/last-result"
    assert_same "$SB/before-missing" "$SB/agh.yaml" 'missing AGH mutated YAML'
    export Z2K_AGH_YAML="$SB/agh.yaml" Z2K_AGH_BIN="$SB/bin/AdGuardHome" Z2K_AGH_INIT="$SB/bin/service"
done
echo 'PASS: remove releases ownership without YAML changes when AGH components missing'
reset_case
run
touch "$SB/bad-config"
Z2K_UNINSTALL_CONFIRMED=1 "${Z2K_TEST_SH:-sh}" -e "$SB/uninstall-run" > "$SB/uninstall-output"
grep -q 'AGH:' "$SB/uninstall-output"
echo 'PASS: menu uninstall continues after broken AGH'
env PATH="$SB/bin:$PATH" "${Z2K_TEST_SH:-sh}" "$SB/cleanup-run" >/dev/null
grep -q 'AGH:' "$SB/warnings"
echo 'PASS: standalone cleanup continues after broken AGH'

reset_case
run
sed '/^ip host crashlogs.whatsapp.net /d' "$SB/pins" > "$SB/tmp"
mv "$SB/tmp" "$SB/pins"
touch "$SB/match"
run
! grep -q 'domain: crashlogs.whatsapp.net$' "$SB/agh.yaml"
grep -q 'domain: whatsapp.com$' "$SB/agh.yaml"
cp "$SB/service.log" "$SB/service-before"
run
assert_same "$SB/service-before" "$SB/service.log" 'one absent pin caused restart cycle'
echo 'PASS: absent pin removed without dropping remaining current owned generation'

# AGH v0.107.80 defaults a missing per-rewrite enabled field to false.
for shape in existing missing; do
    reset_case
    if [ "$shape" = missing ]; then
        sed '/  rewrites:/,/      answer:/d' "$SB/agh.yaml" > "$SB/tmp"
        mv "$SB/tmp" "$SB/agh.yaml"
    fi
    run
    awk '/- domain: instagram.com$/ {entry=1;next}
         entry && /- domain:/ {entry=0}
         entry && /enabled: true/ {active=1}
         END {exit !active}' "$SB/agh.yaml" || {
        echo "FAIL: new rewrite disabled by AGH default ($shape)"; exit 1;
    }
done
echo 'PASS: new rewrites explicitly enabled in existing and missing lists'

# Exercise the shipped transformer under BusyBox awk too (when installed).
# A dynamic printf width used to abort before any rewrite could be installed.
if Z2K_TEST_BUSYBOX=$(command -v busybox); then
    export Z2K_TEST_BUSYBOX
    reset_case
    cat > "$SB/bin/awk" <<'STUB'
#!/bin/sh
exec "$Z2K_TEST_BUSYBOX" awk "$@"
STUB
    chmod +x "$SB/bin/awk"
    run
    grep -q 'domain: crashlogs.whatsapp.net$' "$SB/agh.yaml"
    run remove
    assert_same "$SB/original" "$SB/agh.yaml" 'BusyBox rewrite round trip'
    rm "$SB/bin/awk"
    echo 'PASS: BusyBox awk installs and removes rewrites'
fi

reset_case
printf 'broken: [\n' >> "$SB/agh.yaml"
cp "$SB/agh.yaml" "$SB/malformed-original"
# Native validation rejects invalid YAML outside the bounded rewrites section.
cat > "$SB/bin/AdGuardHome" <<'STUB'
#!/bin/sh
[ "$1" = --check-config ] && [ "$2" = -c ] || exit 1
! grep -q '^broken: \[' "$3"
STUB
chmod +x "$SB/bin/AdGuardHome"
if run; then echo 'FAIL: malformed YAML accepted'; exit 1; fi
assert_same "$SB/malformed-original" "$SB/agh.yaml" 'malformed YAML changed'
[ ! -e "$SB/service.log" ] || { echo 'FAIL: malformed YAML stopped AGH before validation'; exit 1; }
echo 'PASS: malformed YAML rejected before stopping AGH'

touch "$SB/match"
if run; then echo 'FAIL: malformed passthrough YAML accepted'; exit 1; fi
assert_same "$SB/malformed-original" "$SB/agh.yaml" 'malformed passthrough YAML changed'
[ ! -e "$SB/service.log" ]
echo 'PASS: malformed passthrough YAML also rejected without restart'
