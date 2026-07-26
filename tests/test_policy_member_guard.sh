#!/bin/sh
# tests/test_policy_member_guard.sh
#
# The Keenetic policy-exclusion feature killed bypasses in the field, and the reason
# was NOT the one recorded for two years.
#
# MEASURED on a live router (2026-07-26), policy z2ktest with one member phone:
#     mangle PREROUTING   1042 packets from the member, 0 carrying any mark
#     mangle POSTROUTING  1013 packets from the member, 1013 matching
#                         mark ffffaab/0x0fffffff  -> ALL of them
#     traffic outside any policy, measured separately: mark 0, never matched
# So the policy mark IS present where the rule matches it, on every packet, and the
# hook was right all along. The earlier conclusion "the mark does not survive to
# POSTROUTING" was measured with NOTHING in the policy and was simply wrong.
#
# The actual defect is the default. POLICY_NAME defaults to "nfqws" and
# POLICY_EXCLUDE to 0 — "process ONLY policy traffic" — which is implemented as
# "set the exclude bit on everything that is NOT in the policy". For a policy with
# no member hosts that is every connection on the router: NFQUEUE processes nobody
# and the bypass dies silently. The reported user got their bypass back by DELETING
# the policy, which is exactly this.
#
# Hence the member guard, and hence this file: a policy that has no members cannot
# express an intent either way, so no rule is installed and the reason is printed.
#
# Fixtures are verbatim in the shape the router prints, INCLUDING the trailing
# space after the colon — without it the parser passed the tests and found nothing on
# the live box, which is how the first version of this file was green and wrong (`show ip policy` puts name
# and description on one line; `show ip hotspot` prints one "policy:" per host,
# empty for hosts in no policy). POSIX sh, no router needed.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-${Z2K_INIT_UNDER_TEST:-$HERE/files/S99zapret2.new}}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/polg.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

[ -f "$INIT" ] || { printf '[FAIL] init script not found: %s\n' "$INIT"; exit 1; }

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}

FNS="$TMP/fns.sh"
{
    extract_fn z2k_ndmc_bin              "$INIT"; echo
    extract_fn z2k_policy_id             "$INIT"; echo
    extract_fn z2k_policy_members        "$INIT"; echo
    extract_fn z2k_policy_connmark_start "$INIT"; echo
} > "$FNS"
for f in z2k_ndmc_bin z2k_policy_id z2k_policy_members z2k_policy_connmark_start; do
    grep -q "^$f()" "$FNS" && ok "extracted $f()" \
                           || no "extracted $f()" "a definition" "none"
done

# --- ndmc stub, printing exactly what the box prints ------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/ndmc" <<EOF
#!/bin/sh
[ "\$1" = -c ] || exit 1
case "\$2" in
    "show ip policy")  cat "$TMP/policy.out"  2>/dev/null ;;
    "show ip hotspot") cat "$TMP/hotspot.out" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$BIN/ndmc"

cat > "$TMP/policy.out" <<'EOF'
           policy, name = Policy0, description = VPN политика: 
                 mark: ffffaaa
               table4: 4096
           policy, name = z2ktest, description = z2k-test-temp: 
                 mark: ffffaab
               table4: 4098
           policy, name = Policy7, description = "quoted desc": 
                 mark: ffffaac
               table4: 4100
EOF

# 45 hosts, one of them in z2ktest — the router's real ratio.
mk_hotspot() {   # $1 = policy name for the one bound host ("" = nobody bound)
    : > "$TMP/hotspot.out"
    i=0
    while [ "$i" -lt 44 ]; do
        i=$((i + 1))
        printf '                  mac: 00:11:22:33:44:%02d\n                   ip: 192.168.1.%d\n           registered: yes\n               policy: \n' "$i" "$i" >> "$TMP/hotspot.out"
    done
    printf '                  mac: b6:33:50:5b:50:a9\n                   ip: 192.168.1.90\n             hostname: Xiaomi-14-Ultra\n           registered: yes\n               policy: %s\n' "$1" >> "$TMP/hotspot.out"
}

pid_of() { PATH="$BIN:$PATH" sh -c ". '$FNS'; z2k_policy_id ndmc '$1'"; }
members_of() { PATH="$BIN:$PATH" sh -c ". '$FNS'; z2k_policy_members ndmc '$1'"; }

# =============================================================================
# 1. description -> NDM name
# =============================================================================
# POLICY_NAME is matched against the DESCRIPTION, but membership is reported by
# NAME, so this mapping is what makes the member count possible at all.
eqv() { [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }
eqv "description 'z2k-test-temp' resolves to name z2ktest" "z2ktest" "$(pid_of z2k-test-temp)"
eqv "a cyrillic description resolves too"                  "Policy0" "$(pid_of 'VPN политика')"
eqv "a QUOTED description resolves unquoted"               "Policy7" "$(pid_of 'quoted desc')"
eqv "matching is case-insensitive"                          "z2ktest" "$(pid_of Z2K-TEST-TEMP)"
eqv "an unknown description resolves to nothing"            ""        "$(pid_of nosuchpolicy)"
# A PREFIX must not resolve: "z2k" is not "z2k-test-temp", and silently picking the
# wrong policy would scope the bypass to strangers' devices.
eqv "a prefix of a description does not resolve"            ""        "$(pid_of z2k)"

# =============================================================================
# 2. member counting
# =============================================================================
mk_hotspot z2ktest
eqv "counts the single bound host"          "1" "$(members_of z2ktest)"
eqv "counts 0 for a policy nobody is in"    "0" "$(members_of Policy0)"
# Exact match only: "z2k" must not count the host bound to "z2ktest".
eqv "a prefix does not count as membership" "0" "$(members_of z2k)"
mk_hotspot ""
eqv "nobody bound -> 0"                     "0" "$(members_of z2ktest)"
# An empty policy field must never be counted as membership in "" either.
eqv "empty policy fields are not counted"   "0" "$(members_of '')"

# =============================================================================
# 3. the guard: what actually gets installed
# =============================================================================
run_start() {   # $1 = bound policy ("" = memberless), $2 = POLICY_EXCLUDE
    mk_hotspot "$1"
    : > "$TMP/ipt.log"
    cat > "$TMP/s.sh" <<EOF
FWTYPE=iptables
Z2K_CONNMARK_OK4=1
Z2K_CONNMARK_EXCLUDE="0x20000000/0x20000000"
POLICY_NAME="z2k-test-temp"
POLICY_EXCLUDE="$2"
Z2K_POLICY_MARK="ffffaab/0x0fffffff"
z2k_detect_policy_mark() { return 0; }
get_wan_ifaces4() { echo ppp0; }
iptablesw() { printf '%s\n' "\$*" >> "$TMP/ipt.log"; return 1; }
. "$FNS"
z2k_policy_connmark_start
EOF
    PATH="$BIN:$PATH" sh "$TMP/s.sh" 2>&1
}

out=$(run_start "" 0)
case "$out" in
    *"has no member hosts"*) ok "memberless policy: says why nothing was installed" ;;
    *) no "memberless policy: says why nothing was installed" "the reason" "$out" ;;
esac
n=$(grep -c 'set-xmark' "$TMP/ipt.log" 2>/dev/null); n=${n:-0}
[ "$n" = 0 ] && ok "memberless policy: NO rule is inserted (this is the bypass killer)" \
             || no "memberless policy: NO rule is inserted" 0 "$n"
case "$out" in
    *"bypass would stop working"*) ok "memberless policy: tells the user what to do" ;;
    *) no "memberless policy: tells the user what to do" "a hint" "$out" ;;
esac

out=$(run_start z2ktest 0)
n=$(grep -c 'set-xmark' "$TMP/ipt.log" 2>/dev/null); n=${n:-0}
[ "$n" -ge 1 ] && ok "policy WITH a member: the rule is inserted ($n)" \
               || no "policy WITH a member: the rule is inserted" ">=1" "$n"
case "$out" in
    *"1 member host"*) ok "policy WITH a member: reports the count" ;;
    *) no "policy WITH a member: reports the count" "the count" "$out" ;;
esac
# include mode (POLICY_EXCLUDE=0) means "only policy traffic is processed", so the
# exclude bit goes on everything that is NOT the policy mark.
grep -q 'mark ! --mark' "$TMP/ipt.log" \
    && ok "include mode negates the mark match" \
    || no "include mode negates the mark match" "! --mark" "$(tr '\n' ';' < "$TMP/ipt.log")"

out=$(run_start z2ktest 1)
grep -q 'mark ! --mark' "$TMP/ipt.log" \
    && no "exclude mode does NOT negate the mark match" "--mark" "$(tr '\n' ';' < "$TMP/ipt.log")" \
    || ok "exclude mode does NOT negate the mark match"
grep -q -- '-m mark --mark' "$TMP/ipt.log" \
    && ok "exclude mode marks the policy traffic itself" \
    || no "exclude mode marks the policy traffic itself" "-m mark --mark" "$(tr '\n' ';' < "$TMP/ipt.log")"

# A policy whose NDM name cannot be read is also not something to guess at.
out=$(mk_hotspot z2ktest; : > "$TMP/policy.out"; run_start z2ktest 0)
case "$out" in
    *"cannot read its NDM name"*) ok "unreadable policy name: skipped and reported" ;;
    *) no "unreadable policy name: skipped and reported" "the reason" "$out" ;;
esac
n=$(grep -c 'set-xmark' "$TMP/ipt.log" 2>/dev/null); n=${n:-0}
[ "$n" = 0 ] && ok "unreadable policy name: NO rule is inserted" 0 \
             || no "unreadable policy name: NO rule is inserted" 0 "$n"

# =============================================================================
# 4. ROUTER-ONLY, recorded rather than faked
# =============================================================================
# Verified by hand on 192.168.1.1 while writing this, and not reproducible offline:
#   [x] a policy member's packets carry the policy mark at mangle POSTROUTING
#       (1013/1013), and carry NO mark at PREROUTING (0/1042)
#   [x] traffic outside any policy carries mark 0 at both hooks
#   [x] Entware iptables 1.4.21 cannot express -m ndmmark / -m connndmmark
#       ("unknown option --mark"), and no firmware iptables or libxt plugin exists,
#       so an ndmmark-based implementation is impossible, not merely unattractive
#   [x] there is no on-demand module autoload: /proc/sys/kernel/modprobe is empty
#       and /sbin/modprobe absent

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
