# tests/test_warp_addr_and_setup.sh
#
# Two field defects from an r-66 user report ("WARP does not work"), both verified
# against that router's own output and reproduced on the owner's box.
#
# 1. WE OVERRODE THE ADDRESS WARP ASSIGNED.
#    usque logs, on start:  "Config has the following IP addresses: IPv4: 172.16.0.2"
#    the interface carried: 172.16.240.1
#    Both routers checked showed the same mismatch, so it was universal, not local.
#    usque runs with --no-iproute2 and proxies IP PACKETS: Cloudflare sees the inner
#    source address. Inventing one from $ADDR_NET was never right. The 172.16.240.x pool
#    was chosen back when the usque-keenetic PACKAGE owned the tunnel and auto-picked its
#    IFACE_IP from 172.16.1.100-200, colliding with Keenetic's SSTP/L2TP servers; that
#    package is gone (b5cf5af) and so is the collision. Fix: take "ipv4" out of
#    session.conf, and fall back to the pool only on a REAL collision, loudly.
#
# 2. setup_ndm_iface REPORTED SUCCESS WITHOUT CHECKING.
#    Every ndm call is `ndmc ... >/dev/null 2>&1`, so a refusal is invisible, and the
#    caller runs it from a background subshell that discards the status anyway. The
#    reporting router had .ndm-saved present, the link UP, and NO IPv4 on the interface:
#    the function had "worked" and lied. Worse, .ndm-saved was created on the failed
#    apply, so no later start would ever try to persist a correct config again. THIS is
#    the outage: without an address the liveness probe cannot pass, so routing never
#    comes up and the toggle reports "tunnel is not carrying traffic yet".
#
# POSIX sh. No network, no router: everything here is driven with stubs.

HERE=$(cd "$(dirname "$0")/.." && pwd)
S51=${Z2K_S51_UNDER_TEST:-"$HERE/files/init.d/S51z2k-warp"}
WARPSH="$HERE/files/z2k-warp.sh"
HOOK="$HERE/files/ndm/93-z2k-warp.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/warpat.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export TMP

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

for f in "$S51" "$WARPSH" "$HOOK"; do
    [ -f "$f" ] || { printf '[FAIL] missing %s\n' "$f"; exit 1; }
done

# Handles `f() {` and `f()` + `{` on the next line.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*\\{?[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

# =============================================================================
# 1. the address comes from session.conf
# =============================================================================
# A real WARP device config, trimmed to the shape usque writes (no secrets).
cat > "$TMP/session.conf" <<'EOF'
{
  "private_key": "REDACTED",
  "endpoint_v4": "162.159.198.2:443",
  "id": "REDACTED",
  "access_token": "REDACTED",
  "ipv4": "172.16.0.2",
  "ipv6": "2606:4700:110:8402:aec9:8597:596d:ed23"
}
EOF

run_addr() {
    # $1 = what addr_taken_by_other should answer (0 = taken, 1 = free)
    cat > "$TMP/a.sh" <<EOF
SESSION="$TMP/session.conf"
STATE_ADDR="$TMP/addr"
ADDR_NET="172.16.240"
log() { printf 'LOG %s\n' "\$*"; }
addr_taken_by_other() { return $1; }
$(extract_fn session_addr "$S51")
$(extract_fn iface_addr "$S51")
iface_addr opkgtun0
EOF
    sh "$TMP/a.sh" 2>&1
}

: > "$TMP/addr"
out=$(run_addr 1)   # nothing is taken
case "$out" in
    *172.16.0.2*) ok "uses the address WARP assigned (from session.conf)" ;;
    *)            no "uses the address WARP assigned (from session.conf)" "172.16.0.2" "$out" ;;
esac
case "$out" in
    *172.16.240*) no "does not invent an address when WARP gave one" "no 172.16.240.x" "$out" ;;
    *)            ok "does not invent an address when WARP gave one" ;;
esac
# ...and it is remembered, so a later start without a readable config still works.
case "$(cat "$TMP/addr" 2>/dev/null)" in
    172.16.0.2) ok "remembers the assigned address in the state file" ;;
    *)          no "remembers the assigned address in the state file" "172.16.0.2" "$(cat "$TMP/addr" 2>/dev/null)" ;;
esac

# A genuine collision must fall back AND warn — silence here is what makes the
# resulting "tunnel up, carries nothing" impossible to diagnose.
: > "$TMP/addr"
out=$(run_addr 0)   # everything is taken
case "$out" in
    *WARNING*) ok "a colliding assigned address is reported, not silently replaced" ;;
    *)         no "a colliding assigned address is reported, not silently replaced" "a WARNING" "$out" ;;
esac

# No session.conf at all -> must still produce an address rather than fail.
out=$(SESSION=/nonexistent sh -c "
SESSION=/nonexistent; STATE_ADDR=$TMP/addr2; ADDR_NET=172.16.240
log() { :; }
addr_taken_by_other() { return 1; }
$(extract_fn session_addr "$S51")
$(extract_fn iface_addr "$S51")
iface_addr opkgtun0" 2>&1)
case "$out" in
    172.16.240.*) ok "falls back to the scanned pool when there is no device config" ;;
    *)            no "falls back to the scanned pool when there is no device config" "172.16.240.x" "$out" ;;
esac

# =============================================================================
# 2. setup_ndm_iface verifies, and gates .ndm-saved on success
# =============================================================================
run_setup() {
    # $1 = address that `ip -o addr show` will report present ("" = none)
    mkdir -p "$TMP/wd"; rm -f "$TMP/wd/.ndm-saved"
    BIN="$TMP/bin"; mkdir -p "$BIN"
    cat > "$BIN/ip" <<EOF
#!/bin/sh
case "\$*" in
    *"-o addr show"*) [ -n "$1" ] && echo "9: opkgtun0    inet $1/32 scope global opkgtun0" ;;
    *"link show"*)    echo "9: opkgtun0: <POINTOPOINT,UP,LOWER_UP> mtu 1500" ;;
esac
exit 0
EOF
    chmod +x "$BIN/ip"
    cat > "$TMP/s.sh" <<EOF
WARP_DIR="$TMP/wd"
MTU=1280
log() { printf 'LOG %s\n' "\$*"; }
ndm() { printf 'NDM %s\n' "\$1" >> "$TMP/ndm.log"; }
ndm_name() { echo OpkgTun0; }
$(extract_fn setup_ndm_iface "$S51")
setup_ndm_iface opkgtun0 172.16.0.2
echo "rc=\$?"
EOF
    : > "$TMP/ndm.log"
    PATH="$BIN:$PATH" sh "$TMP/s.sh" 2>&1
}

out=$(run_setup "172.16.0.2")
case "$out" in
    *"rc=0"*) ok "success when NDM really applied the address" ;;
    *)        no "success when NDM really applied the address" "rc=0" "$out" ;;
esac
[ -f "$TMP/wd/.ndm-saved" ] && ok "config saved once on a successful apply" \
                            || no "config saved once on a successful apply" "marker present" "absent"
grep -q 'ip address 172.16.0.2' "$TMP/ndm.log" 2>/dev/null \
    && ok "the assigned address is what gets handed to NDM" \
    || no "the assigned address is what gets handed to NDM" "ip address 172.16.0.2" "$(tr '\n' ';' < "$TMP/ndm.log")"

out=$(run_setup "")   # NDM silently refused: no address on the interface
case "$out" in
    *"rc=0"*) no "FAILS when the address never landed" "non-zero rc" "$out" ;;
    *"rc="*)  ok "FAILS when the address never landed" ;;
    *)        no "FAILS when the address never landed" "an rc" "$out" ;;
esac
case "$out" in
    *"did not apply"*) ok "says which address NDM refused" ;;
    *)                 no "says which address NDM refused" "a log line" "$out" ;;
esac
# THE regression from the field: the marker must NOT appear on a failed apply, or no
# later start will ever persist a correct config.
[ -f "$TMP/wd/.ndm-saved" ] && no "no save marker on a FAILED apply" "absent" "present" \
                            || ok "no save marker on a FAILED apply"

# =============================================================================
# 3. WHAT IS *NOT* HERE, and why — kept as a record so nobody re-adds it
# =============================================================================
# An earlier version of this file asserted a "TTL guard": a RETURN for the WARP mark in
# Keenetic's _NDM_POSTROUTING_TTL plus `-j TTL --ttl-set 64` on the way into the tun. It
# was written off usque's log line
#     connect-ip: datagram Hop Limit too small: 1
# on the assumption that NDM was rewriting TTL down. The reporting router's own chain
# disproved it:
#     -A _NDM_POSTROUTING_TTL -o qmi_br0 -j TTL --ttl-set 64
# One rule, setting TTL to 64 (not 1), and only for its LTE modem — opkgtun0 is never
# touched. The guard would have fixed something that does not happen.
#
# The --ttl-set half was worse than useless: TTL=1 is INTENTIONAL for mDNS and SSDP, which
# is how link-local multicast is kept on the link. Rewriting it to 64 on the way into a
# tunnel would have leaked that traffic off-link.
#
# That router also showed no `fwmark 0x989` ip rule at all, i.e. nothing was being steered
# into the tunnel deliberately, so the dropped datagrams are multicast leaking into a
# MULTICAST-flagged tun device — log noise, not the outage. The outage is covered by
# sections 1 and 2 above: with no IPv4 on the interface the liveness probe cannot pass, so
# routing never comes up.

# =============================================================================
# 4. stale NDM interfaces left by the usque package are reaped - and nothing else is
# =============================================================================
# Field state on the owner's router: OpkgTun0 (ours, description z2k-warp, live) AND
# OpkgTun1 (description "usque", no netdev, state error, holding 172.16.240.2 - the
# address p-64.1 had written into the package's config). NDM restores the dead object
# from startup-config on every boot, and because it owns an address out of our own
# fallback range it can make NDM refuse to raise ours. The reaper must remove exactly
# that shape and nothing else: an OpkgTun object can just as easily belong to a tunnel
# the user runs themselves, and deleting one of those would tear down their interface
# and persist the damage.
RBIN="$TMP/rbin"; mkdir -p "$RBIN"
# ndmc stub: serves a fixture running-config and per-interface descriptions, and records
# every command it was given.
# It EXITS 0 EVEN ON REFUSAL, like the real one: `no interface OpkgTun9` on the router
# prints "Command::Base error[7405602]: argument parse error." and still returns 0. A stub
# that failed honestly would let a status check pass that cannot work in the field.
# `no interface` really removes from the fixture, so the caller's re-read sees the effect —
# unless $TMP/stubborn exists, which models a refusal.
cat > "$RBIN/ndmc" <<EOF
#!/bin/sh
[ "\$1" = -c ] || exit 1
printf '%s\n' "\$2" >> "$TMP/ndmc.calls"
case "\$2" in
    "show running-config") cat "$TMP/runcfg" 2>/dev/null ;;
    "show interface "*)
        _i=\${2##* }
        if grep -q "^\$_i=" "$TMP/descs" 2>/dev/null; then
            printf '               id: %s\n' "\$_i"
            printf '      description: %s\n' "\$(sed -n "s/^\$_i=//p" "$TMP/descs" | head -1)"
            printf '             type: OpkgTun\n'
        else
            printf 'Command::Base error[7405602]: argument parse error.\n'
        fi ;;
    "no interface "*)
        _i=\${2##* }
        [ -f "$TMP/stubborn" ] || {
            grep -v "^\$_i=" "$TMP/descs" > "$TMP/descs.n" 2>/dev/null && mv "$TMP/descs.n" "$TMP/descs"
            grep -v "^interface \$_i\$" "$TMP/runcfg" > "$TMP/runcfg.n" 2>/dev/null && mv "$TMP/runcfg.n" "$TMP/runcfg"
        } ;;
esac
exit 0
EOF
# ip stub: `ip link show DEV` succeeds only for devices named in the fixture.
cat > "$RBIN/ip" <<EOF
#!/bin/sh
[ "\$1" = link ] && [ "\$2" = show ] || exit 0
printf '%s\n' "\$3" >> "$TMP/ip.calls"
grep -qx "\$3" "$TMP/netdevs" 2>/dev/null && exit 0
exit 1
EOF
chmod +x "$RBIN/ndmc" "$RBIN/ip"

# run_reap OURS  -> runs reap_pkg_ifaces against the current fixtures
run_reap() {
    : > "$TMP/ndmc.calls"; : > "$TMP/ip.calls"
    cat > "$TMP/r.sh" <<EOF
log() { :; }
ndm() { LD_LIBRARY_PATH= ndmc -c "\$1" >/dev/null 2>&1; }
ndm_name() { echo "\$1" | sed 's/^opkg/Opkg/; s/tun/Tun/'; }
$(grep -m1 '^dev_name()' "$S51")
$(extract_fn ndm_iface_exists "$S51")
$(extract_fn reap_pkg_ifaces "$S51")
reap_pkg_ifaces "$1"
EOF
    PATH="$RBIN:$PATH" sh "$TMP/r.sh" >/dev/null 2>&1
}
reaped()  { grep -qx "no interface $1" "$TMP/ndmc.calls"; }
saved()   { grep -qx "system configuration save" "$TMP/ndmc.calls"; }

# --- the field case: ours is live, the package's is a phantom ----------------
printf 'interface OpkgTun0\ninterface OpkgTun1\n' > "$TMP/runcfg"
printf 'OpkgTun0=z2k-warp\nOpkgTun1=usque\n'      > "$TMP/descs"
printf 'opkgtun0\n'                                > "$TMP/netdevs"
run_reap opkgtun0
# Harness guards FIRST. The driver is assembled by text extraction, and when dev_name()
# silently failed to land, the netdev check compared an empty device name, never matched,
# and five of the six cases below still "passed" - reaping everything for the wrong reason.
for f in dev_name ndm_iface_exists reap_pkg_ifaces; do
    grep -q "^$f()" "$TMP/r.sh" && ok "harness: $f() made it into the driver" \
                                || no "harness: $f() made it into the driver" "a definition" "missing"
done
grep -qx opkgtun1 "$TMP/ip.calls" \
    && ok "harness: the netdev check really asks ip about the right device" \
    || no "harness: the netdev check really asks ip about the right device" "opkgtun1" "$(tr '\n' ';' < "$TMP/ip.calls")"
reaped OpkgTun1 && ok "the package's leftover interface is removed" \
                || no "the package's leftover interface is removed" "no interface OpkgTun1" "$(tr '\n' ';' < "$TMP/ndmc.calls")"
reaped OpkgTun0 && no "OUR interface is never removed" "untouched" "deleted" \
                || ok "OUR interface is never removed"
saved && ok "a removal is persisted (else NDM restores it next boot)" \
      || no "a removal is persisted" "system configuration save" "not called"

# --- a leftover that still HAS a netdev is in use: leave it alone ------------
printf 'interface OpkgTun0\ninterface OpkgTun1\n' > "$TMP/runcfg"
printf 'OpkgTun0=z2k-warp\nOpkgTun1=usque\n'      > "$TMP/descs"
printf 'opkgtun0\nopkgtun1\n'                      > "$TMP/netdevs"
run_reap opkgtun0
reaped OpkgTun1 && no "an interface with a live netdev is left alone" "untouched" "deleted" \
                || ok "an interface with a live netdev is left alone"

# --- someone else's tunnel: same shape, different description ---------------
# sing-box / xray / AmneziaWG also register OpkgTun objects. A user-typed description
# is stored QUOTED by NDM, so it can never collide with the bare package signature.
for d in sing-box xray '"VPN"' '' 'usque-2'; do
    printf 'interface OpkgTun0\ninterface OpkgTun2\n'  > "$TMP/runcfg"
    printf 'OpkgTun0=z2k-warp\nOpkgTun2=%s\n' "$d"     > "$TMP/descs"
    printf 'opkgtun0\n'                                > "$TMP/netdevs"
    run_reap opkgtun0
    reaped OpkgTun2 && no "description [$d] is not the package signature -> untouched" "untouched" "deleted" \
                    || ok "description [$d] is not the package signature -> untouched"
done

# --- nothing to reap must not write flash -----------------------------------
# `system configuration save` runs on every start otherwise, and it writes flash.
printf 'interface OpkgTun0\n' > "$TMP/runcfg"
printf 'OpkgTun0=z2k-warp\n'  > "$TMP/descs"
printf 'opkgtun0\n'           > "$TMP/netdevs"
run_reap opkgtun0
saved && no "no removal -> no configuration save (flash guard)" "not called" "called" \
      || ok "no removal -> no configuration save (flash guard)"

# --- several leftovers: all reaped, saved ONCE ------------------------------
printf 'interface OpkgTun0\ninterface OpkgTun1\ninterface OpkgTun3\n' > "$TMP/runcfg"
printf 'OpkgTun0=z2k-warp\nOpkgTun1=usque\nOpkgTun3=usque\n'          > "$TMP/descs"
printf 'opkgtun0\n'                                                    > "$TMP/netdevs"
run_reap opkgtun0
if reaped OpkgTun1 && reaped OpkgTun3; then ok "every leftover is reaped, not just the first"
else no "every leftover is reaped, not just the first" "both" "$(tr '\n' ';' < "$TMP/ndmc.calls")"; fi
n=$(grep -cx "system configuration save" "$TMP/ndmc.calls"); n=${n:-0}
[ "$n" = 1 ] && ok "the config is saved once, not once per removal ($n)" \
             || no "the config is saved once, not once per removal" 1 "$n"

# --- a removal that NDM refused must not be reported as done ----------------
# ndmc exits 0 even when it refuses, so the only way to know is to re-read. Claiming
# success here would also burn a flash write on a config that never changed.
printf 'interface OpkgTun0\ninterface OpkgTun1\n' > "$TMP/runcfg"
printf 'OpkgTun0=z2k-warp\nOpkgTun1=usque\n'      > "$TMP/descs"
printf 'opkgtun0\n'                                > "$TMP/netdevs"
: > "$TMP/stubborn"
run_reap opkgtun0
reaped OpkgTun1 && ok "a refused removal is still attempted" \
                || no "a refused removal is still attempted" "no interface OpkgTun1" "not tried"
saved && no "a refused removal does NOT write flash" "no save" "saved" \
      || ok "a refused removal does NOT write flash"
rm -f "$TMP/stubborn"

# --- we must not reap when WE are the one on that index ---------------------
# If our own state ever points at opkgtun1, that object is ours no matter what the
# description says, and it must survive.
printf 'interface OpkgTun1\n' > "$TMP/runcfg"
printf 'OpkgTun1=usque\n'     > "$TMP/descs"
: > "$TMP/netdevs"
run_reap opkgtun1
reaped OpkgTun1 && no "the interface we chose is never reaped, whatever its description" "untouched" "deleted" \
                || ok "the interface we chose is never reaped, whatever its description"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
