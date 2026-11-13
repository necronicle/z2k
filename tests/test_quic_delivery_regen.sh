#!/bin/sh
# p-87.37 compatibility: use its real retirement function and delivery block.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/opt/zapret2"
git -C "$ROOT" show p-87.37:lib/config_official.sh | awk '/^z2k_retire_dns_redirect\(\)/ {on=1} on {print} on && /^}/ {exit}' > "$T/retire.sh"
cat > "$T/bin/ipset" <<'EOF'
#!/bin/sh
echo 'ipset: The set with the given name does not exist' >&2
exit 1
EOF
cat > "$T/bin/iptables" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$T/bin/"*
# Extract the actual delivery logic; redirect only its validator path to fixture.
awk '/^# The released p-87.37 generator/ {on=1} /^\. \/opt\/zapret2\/config/ {on=0} on {print}' "$ROOT/specs/quic-attribution/router-install.sh" | sed "s@/opt/zapret2/z2k-config-validator.sh@${T}/validator.sh@g" > "$T/block.sh"
cat > "$T/run.sh" <<'EOF'
set -e
. "$T/retire.sh"
create_official_config() {
    [ "${GEN_FAIL:-0}" = 0 ] || return 42
    z2k_retire_dns_redirect
    echo generated > "$T/generated"
}
. "$T/block.sh"
EOF
export T ZAPRET2_DIR="$T/opt/zapret2" Z2K_DNS_STATE_DIR="$T" PATH="$T/bin:$PATH"
for rc in 0 1; do
    printf 'exit %s\n' "$rc" > "$T/validator.sh"
    sh "$T/run.sh" > "$T/out" 2>&1
    test -s "$T/generated"
    grep -q VALIDATE_OK "$T/out"
done
printf 'exit 2\n' > "$T/validator.sh"
if sh "$T/run.sh" > "$T/out" 2>&1; then echo 'FAIL: validator error accepted'; exit 1; fi
grep -q VALIDATE_FAILED_2 "$T/out"
if GEN_FAIL=1 sh "$T/run.sh" > "$T/out" 2>&1; then echo 'FAIL: generator error accepted'; exit 1; fi
grep -q REGEN_FAILED "$T/out"
sed 's@http://192.168.1.67:8778@http://172.17.0.3:8778@' "$ROOT/specs/quic-attribution/router-install.sh" > "$T/emulator.sh"
cmp "$T/emulator.sh" "$ROOT/specs/quic-attribution/emulator-install.sh"
echo 'PASS: released cleanup under errexit; validator 0/1/2; generator veto; identical delivery scripts'
