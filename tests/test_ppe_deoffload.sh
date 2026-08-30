#!/bin/sh
# tests/test_ppe_deoffload.sh - Unit tests for files/z2k-ppe-deoffload.sh.
# Verifies the per-flow PPE de-offload rule SHAPE (multiport ports + connskip
# window + -j PPE, in mangle FORWARD AND PREROUTING), the availability /
# user-disable gates, and that remove deletes what ensure added.
# POSIX sh (busybox ash). Run: sh tests/test_ppe_deoffload.sh

TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] %s\n" "$1"
    else TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] %s\n      want=[%s] got=[%s]\n" "$1" "$2" "$3"; fi
}
assert_has() {   # file CONTAINS regex
    if grep -qE "$3" "$2" 2>/dev/null; then TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] %s\n" "$1"
    else TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] %s (no match: %s)\n" "$1" "$3"; fi
}
assert_hasnt() { # file does NOT contain regex
    if grep -qE "$3" "$2" 2>/dev/null; then TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] %s (unexpected match: %s)\n" "$1" "$3"
    else TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] %s\n" "$1"; fi
}

HERE=$(cd "$(dirname "$0")/.." && pwd)
LIB="$HERE/files/z2k-ppe-deoffload.sh"
TMP=$(mktemp -d /tmp/ppe_test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls"; : > "$CALLS"
DEL="$TMP/deleted"; mkdir -p "$DEL"

# --- mock iptables/ip6tables ---
# add-phase: -C always "absent" (1) so -I fires. remove-phase (REMOVE set):
# -C "present" until a matching -D ran (tracked in $DEL).
_ipt() {
    fam="$1"; shift
    printf '%s %s\n' "$fam" "$*" >> "$CALLS"
    kid=$(printf '%s' "$fam $*" | sed 's/ -w / /g; s/ -[CDAI] / /g' | cksum | cut -d' ' -f1)
    case " $* " in
        *" -C "*)
            if [ -n "${REMOVE:-}" ]; then
                [ -f "$DEL/$kid" ] && return 1
                return 0
            fi
            return 1 ;;
        *" -D "*) : > "$DEL/$kid"; return 0 ;;
    esac
    return 0
}
iptables()  { _ipt v4 "$@"; }
ip6tables() { _ipt v6 "$@"; }

# lib config: temp config file, force the availability gates ON for shape tests
PPE_CONFIG_FILE="$TMP/config"; : > "$PPE_CONFIG_FILE"
. "$LIB"
# override the /proc-reading gates deterministically for the shape tests
z2k_ppe_available() { return 0; }
z2k_ppe_v6_ok()     { return 0; }
_Z2K_PPE_OK=1; _Z2K_PPE_V6=1

# ---- constants ----
assert_eq "ports include 443"        "1" "$(printf '%s' "$PPE_PORTS" | grep -c '443')"
assert_eq "connskip default 30"      "30"  "$PPE_CONNSKIP"
assert_eq "target is PPE"            "PPE" "$PPE_TARGET"

# ---- ensure_rules shape ----
z2k_ppe_ensure_rules >/dev/null 2>&1
# Список портов берём из самого модуля, а не переписываем сюда: он растёт
# (5222 приехал 28.08.2026 под шлюз WhatsApp), и вписанная копия делала сторожа
# красным на ровном месте — правило-то верное. Сторожим ФОРМУ правила и то, что
# в него ушёл ровно объявленный список.
assert_has "v4 FORWARD multiport+connskip -j PPE" "$CALLS" \
    "v4 .*-t mangle -I FORWARD -p tcp -m multiport --dports $PPE_PORTS -m connskip --connskip 30 -j PPE"
assert_has "v4 PREROUTING multiport+connskip -j PPE" "$CALLS" \
    'v4 .*-t mangle -I PREROUTING -p tcp -m multiport --dports .* -m connskip --connskip 30 -j PPE'
assert_has "v6 FORWARD rule too (best-effort)" "$CALLS" \
    'v6 .*-t mangle -I FORWARD -p tcp -m multiport --dports .* -j PPE'
# QUIC (UDP/443) de-offload rules — default ON, same connskip window
assert_has "v4 FORWARD udp/443 connskip -j PPE" "$CALLS" \
    'v4 .*-t mangle -I FORWARD -p udp --dport 443 -m connskip --connskip 30 -j PPE'
assert_has "v4 PREROUTING udp/443 connskip -j PPE" "$CALLS" \
    'v4 .*-t mangle -I PREROUTING -p udp --dport 443 -m connskip --connskip 30 -j PPE'
assert_has "v6 udp/443 rule too (best-effort)" "$CALLS" \
    'v6 .*-t mangle -I FORWARD -p udp --dport 443 -m connskip --connskip 30 -j PPE'
# must NOT touch nat table or global ppe_enabled (per-flow only, mangle only)
assert_hasnt "no nat-table rule"            "$CALLS" '-t nat'
assert_hasnt "no REDIRECT"                  "$CALLS" 'REDIRECT'

# ---- remove_rules deletes both chains ----
: > "$CALLS"; rm -rf "$DEL"; mkdir -p "$DEL"; REMOVE=1
z2k_ppe_remove_rules >/dev/null 2>&1
assert_has "remove drops v4 FORWARD"    "$CALLS" 'v4 .*-t mangle -D FORWARD -p tcp -m multiport .* -j PPE'
assert_has "remove drops v4 PREROUTING" "$CALLS" 'v4 .*-t mangle -D PREROUTING -p tcp -m multiport .* -j PPE'
assert_has "remove drops v4 udp FORWARD"    "$CALLS" 'v4 .*-t mangle -D FORWARD -p udp --dport 443 .* -j PPE'
assert_has "remove drops v4 udp PREROUTING" "$CALLS" 'v4 .*-t mangle -D PREROUTING -p udp --dport 443 .* -j PPE'
unset REMOVE

# ---- gates: user-disable + target availability ----
# user disabled -> ensure no-ops (returns 1)
printf 'Z2K_PPE_DEOFFLOAD=0\n' > "$PPE_CONFIG_FILE"
if z2k_ppe_user_disabled; then TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] user_disabled true on flag=0\n"
else TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] user_disabled should be true on flag=0\n"; fi
: > "$CALLS"
z2k_ppe_ensure_rules >/dev/null 2>&1
assert_hasnt "no rules inserted when user-disabled" "$CALLS" '-I '

# flag absent -> default ON (not disabled)
: > "$PPE_CONFIG_FILE"
if z2k_ppe_user_disabled; then TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] default should be enabled\n"
else TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] default enabled when flag absent\n"; fi

# ---- QUIC sub-gate: Z2K_PPE_DEOFFLOAD_QUIC=0 -> TCP rules but NO udp rules ----
printf 'Z2K_PPE_DEOFFLOAD_QUIC=0\n' > "$PPE_CONFIG_FILE"
if z2k_ppe_quic_enabled; then TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] quic_enabled should be false on flag=0\n"
else TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] quic_enabled false on flag=0\n"; fi
: > "$CALLS"
z2k_ppe_ensure_rules >/dev/null 2>&1
assert_has    "tcp rules still inserted when QUIC disabled" "$CALLS" 'mangle -I FORWARD -p tcp -m multiport'
assert_hasnt  "no udp rules when QUIC disabled"             "$CALLS" 'udp --dport 443'
# QUIC default ON when flag absent
: > "$PPE_CONFIG_FILE"
if z2k_ppe_quic_enabled; then TESTS_PASSED=$((TESTS_PASSED+1)); printf "[PASS] quic default enabled when flag absent\n"
else TESTS_FAILED=$((TESTS_FAILED+1)); printf "[FAIL] quic should default enabled\n"; fi


# target unavailable -> ensure no-ops
z2k_ppe_available() { return 1; }
: > "$CALLS"
z2k_ppe_ensure_rules >/dev/null 2>&1
assert_hasnt "no rules inserted when PPE target unavailable" "$CALLS" '-I '

printf "\n%d passed, %d failed\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
