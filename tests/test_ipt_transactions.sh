#!/bin/sh
# Stateful, isolated checks for common/ipt.sh. No real firewall command is run.

HERE=$(cd "$(dirname "$0")/.." && pwd)
IPT_SH=${IPT_SH:-$HERE/common/ipt.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ipt-transactions.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

BIN="$TMP/bin"
STATE="$TMP/state"
export STATE
mkdir -p "$BIN"
cat > "$BIN/iptables-mock" <<'MOCK'
#!/bin/sh
family=${0##*/}
case "$family" in ip6tables) rules="$STATE/rules6" ;; *) rules="$STATE/rules4" ;; esac
[ -f "$rules" ] || : > "$rules"
{
    printf 'call'
    for arg do printf ' <%s>' "$arg"; done
    printf '\n'
} >> "$STATE/calls"
waited=0
op=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -w) waited=1; shift ;;
        -C|-I|-A|-D) op=$1; shift; break ;;
        *) shift ;;
    esac
done
key=$*
[ "$op" = -C ] && [ "${CHECK_ERROR:-0}" != 0 ] && exit "$CHECK_ERROR"
if [ "$op" = -C ] && [ "${CONTENTION:-0}" = 1 ] && [ "$waited" = 0 ] && grep -F -x -q -- "$key" "$rules"; then
    exit 4
fi
if [ "$op" = -C ] && [ "${BARRIER:-0}" = 1 ]; then
    : > "$STATE/check.$$"
    count=$(find "$STATE" -name 'check.*' -type f | wc -l | tr -d ' ')
    [ "$count" -ge 2 ] || sleep 1
fi
case "$op" in
    -C)
        grep -F -x -q -- "$key" "$rules"
        exit $?
        ;;
    -I|-A|-D)
        [ "${MUTATE_ERROR:-0}" = 0 ] || exit "$MUTATE_ERROR"
        while ! mkdir "$STATE/mutation.lock" 2>/dev/null; do :; done
        if [ "$op" = -I ]; then
            { printf '%s\n' "$key"; cat "$rules"; } > "$rules.$$"
            mv "$rules.$$" "$rules"
        elif [ "$op" = -A ]; then
            printf '%s\n' "$key" >> "$rules"
        else
            awk -v key="$key" '$0 == key && !done { done=1; next } { print }' "$rules" > "$rules.$$"
            mv "$rules.$$" "$rules"
        fi
        rmdir "$STATE/mutation.lock"
        exit 0
        ;;
    *) exit 2 ;;
esac
MOCK
cp "$BIN/iptables-mock" "$BIN/iptables"
cp "$BIN/iptables-mock" "$BIN/ip6tables"
chmod +x "$BIN/iptables" "$BIN/ip6tables"
PATH="$BIN:$PATH"
export PATH
Z2K_IPT_LOCK="$TMP/transaction.lock"
Z2K_IPT_LOCK_TIMEOUT=2
export Z2K_IPT_LOCK Z2K_IPT_LOCK_TIMEOUT
# shellcheck source=common/ipt.sh
. "$IPT_SH"

reset() {
    rm -rf "$STATE" "$Z2K_IPT_LOCK"
    mkdir -p "$STATE"
    : > "$STATE/rules4"
    : > "$STATE/rules6"
    : > "$STATE/calls"
    FW_EXTRA_PRE=
    FW_EXTRA_POST=
    unset CONTENTION CHECK_ERROR BARRIER MUTATE_ERROR
    Z2K_IPT_LOCK_TIMEOUT=2
    export Z2K_IPT_LOCK_TIMEOUT
}
count4() { grep -F -x -c -- "$1" "$STATE/rules4" 2>/dev/null; }
count6() { grep -F -x -c -- "$1" "$STATE/rules6" 2>/dev/null; }
wait_flag_count() { grep -c '<-w>' "$STATE/calls" 2>/dev/null; }

RULE4='INPUT -p tcp --dport 443 -j NFQUEUE'
RULE4A='POSTROUTING -p udp --dport 443 -j NFQUEUE'
RULE6='INPUT -p tcp --dport 443 -j NFQUEUE'
RULE6A='POSTROUTING -p udp --dport 443 -j NFQUEUE'

# Removing -w from any check or mutation must fail these counters.
reset
ipt INPUT -p tcp --dport 443 -j NFQUEUE
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE
ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'IPv4/IPv6 insert and append transactions always wait' 8 "$(wait_flag_count)"
reset
printf '%s\n' "$RULE4" > "$STATE/rules4"
printf '%s\n' "$RULE6" > "$STATE/rules6"
ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
ipt6_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'IPv4/IPv6 deletion checks, mutations, and final absence checks always wait' 6 "$(wait_flag_count)"

# Original bug: lock error 4 on -C is treated as absence and duplicates a rule.
reset
printf '%s\n' "$RULE4" "$RULE4A" > "$STATE/rules4"
CONTENTION=1 ipt INPUT -p tcp --dport 443 -j NFQUEUE
CONTENTION=1 ipta POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'contended ipt check cannot duplicate an existing rule' 1 "$(count4 "$RULE4")"
eq 'contended ipta check cannot duplicate an existing rule' 1 "$(count4 "$RULE4A")"
reset
printf '%s\n' "$RULE6" "$RULE6A" > "$STATE/rules6"
CONTENTION=1 ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
CONTENTION=1 ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'contended IPv6 insert cannot duplicate an existing rule' 1 "$(count6 "$RULE6")"
eq 'contended IPv6 append cannot duplicate an existing rule' 1 "$(count6 "$RULE6A")"

reset
ipt INPUT -p tcp --dport 443 -j NFQUEUE
ipt INPUT -p tcp --dport 443 -j NFQUEUE
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE
ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
ipt6a POSTROUTING -p udp --dport 443 -j NFQUEUE
eq 'ordinary missing then existing IPv4 insert is idempotent' 1 "$(count4 "$RULE4")"
eq 'ordinary missing IPv4 append adds one' 1 "$(count4 "$RULE4A")"
eq 'ordinary missing IPv6 insert adds one' 1 "$(count6 "$RULE6")"
eq 'ordinary missing IPv6 append adds one' 1 "$(count6 "$RULE6A")"

for err in 2 4; do
    reset
    CHECK_ERROR=$err ipt INPUT -p tcp --dport 443 -j NFQUEUE
    rc=$?
    eq "IPv4 check error $err is returned" "$err" "$rc"
    eq "IPv4 check error $err cannot insert" 0 "$(count4 "$RULE4")"
    CHECK_ERROR=$err ipt6 INPUT -p tcp --dport 443 -j NFQUEUE
    rc=$?
    eq "IPv6 check error $err is returned" "$err" "$rc"
    eq "IPv6 check error $err cannot insert" 0 "$(count6 "$RULE6")"
done

# The barrier makes both original checks observe absence before either insert.
# A correct transaction lock lets the first time out, insert, and release; the
# second then observes the committed rule.
reset
BARRIER=1; export BARRIER
ipt INPUT -p tcp --dport 443 -j NFQUEUE & p1=$!
ipt INPUT -p tcp --dport 443 -j NFQUEUE & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
unset BARRIER
eq 'concurrent ipt callers both succeed' '0 0' "$r1 $r2"
eq 'concurrent ipt apply leaves exactly one rule' 1 "$(count4 "$RULE4")"
reset
BARRIER=1; export BARRIER
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE & p1=$!
ipta POSTROUTING -p udp --dport 443 -j NFQUEUE & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
unset BARRIER
eq 'concurrent ipta callers both succeed' '0 0' "$r1 $r2"
eq 'concurrent ipta apply leaves exactly one rule' 1 "$(count4 "$RULE4A")"

reset
printf '%s\n%s\n%s\n%s\n' "$RULE4" 'FORWARD -j ACCEPT' "$RULE4" "$RULE4" > "$STATE/rules4"
ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
rc=$?
eq 'explicit deletion succeeds after draining duplicates' 0 "$rc"
eq 'explicit deletion drains every exact IPv4 copy' 0 "$(count4 "$RULE4")"
eq 'explicit IPv4 deletion preserves unrelated rule' 1 "$(count4 'FORWARD -j ACCEPT')"
printf '%s\n%s\n%s\n' "$RULE6" 'FORWARD -j ACCEPT' "$RULE6" > "$STATE/rules6"
ipt6_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'explicit IPv6 deletion drains exact copies' 0 "$(count6 "$RULE6")"
eq 'explicit IPv6 deletion preserves unrelated rule' 1 "$(count6 'FORWARD -j ACCEPT')"
reset
ipt_del INPUT -p tcp --dport 443 -j NFQUEUE
eq 'deleting an already absent rule preserves missing status' 1 "$?"

reset
printf '%s\n%s\n' "$RULE4" "$RULE4" > "$STATE/rules4"
ipt INPUT -p tcp --dport 443 -j NFQUEUE
eq 'add-only apply never deletes accumulated copies implicitly' 2 "$(count4 "$RULE4")"

reset
FW_EXTRA_PRE='--pre-one --pre-two'
FW_EXTRA_POST='--post'
ipt INPUT 'argument with spaces' -j NFQUEUE
expected='call <--pre-one> <--pre-two> <-w> <-C> <INPUT> <argument with spaces> <-j> <NFQUEUE> <--post>'
eq 'extra arguments and quoted rule arguments retain their positions' 1 "$(grep -F -x -c -- "$expected" "$STATE/calls")"

for kind in ownerless live; do
    reset
    mkdir "$Z2K_IPT_LOCK"
    [ "$kind" = live ] && echo $$ > "$Z2K_IPT_LOCK/pid"
    Z2K_IPT_LOCK_TIMEOUT=0
    export Z2K_IPT_LOCK_TIMEOUT
    ipt INPUT -p tcp --dport 443 -j NFQUEUE
    rc=$?
    case "$rc" in 0) got=0 ;; *) got=nonzero ;; esac
    eq "$kind transaction lock fails closed" nonzero "$got"
    eq "$kind transaction lock prevents insertion" 0 "$(count4 "$RULE4")"
    [ -d "$Z2K_IPT_LOCK" ] && present=yes || present=no
    eq "$kind transaction lock is not stolen" yes "$present"
done
reset
mkdir "$Z2K_IPT_LOCK"
echo 99999999 > "$Z2K_IPT_LOCK/pid"
ipt INPUT -p tcp --dport 443 -j NFQUEUE
rc=$?
eq 'confirmed-dead owner lock can be reclaimed' 0 "$rc"
eq 'reclaimed transaction inserts once' 1 "$(count4 "$RULE4")"
[ ! -d "$Z2K_IPT_LOCK" ] && released=yes || released=no
eq 'reclaimed lock is released after use' yes "$released"

reset
MUTATE_ERROR=2 ipt INPUT -p tcp --dport 443 -j NFQUEUE
rc=$?
eq 'mutation error is returned' 2 "$rc"
[ ! -d "$Z2K_IPT_LOCK" ] && released=yes || released=no
eq 'mutation error releases transaction lock' yes "$released"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
