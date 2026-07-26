#!/bin/sh
# tests/test_module_loading.sh
#
# load_modules() never loaded a single module on any Keenetic, and said so in a
# way that read as harmless. Reported from the field (issue #27, NC1812 / NDMS
# 5.1.2) and then reproduced on the owner's own 4.9-ndm-5 router:
#
#     modprobe: FATAL: Module xt_multiport not found in directory /opt/lib/modules/4.9-ndm-5
#
# `modprobe` on PATH is Entware's and searches /opt/lib/modules/<kver>, which does
# not exist on Keenetic. The firmware keeps its modules in /lib/modules/<kver>
# (4.9-ndm-5) or /lib/system-modules/<kver> (NDMS 5.1.2) — two layouts, and the old
# code hardcoded the first one for exactly ONE module (ip_set_bitmap_port), i.e. the
# path that is missing on the firmware where the problem was reported.
#
# WHY IT IS NOT COSMETIC. There is no on-demand autoload to fall back on. Verified
# live on the router:
#     /proc/sys/kernel/modprobe  -> empty
#     /sbin/modprobe             -> does not exist
#     iptables -m hashlimit ...  -> "No chain/target/match by that name", and the
#                                   module did NOT appear afterwards
# So a match whose module is absent means the RULE IS NEVER INSTALLED: connbytes is
# the packet-direction filter on the NFQUEUE rules, multiport gates the PPE
# de-offload. The bypass degrades silently while the log says "may be built-in".
# It stayed invisible on the owner's box only because NDM loads xt_multiport and
# xt_connbytes for its own rules first (lsmod shows them with refcounts).
#
# The three properties asserted here:
#   1. availability is decided by the KERNEL registry, not by lsmod — most of these
#      are built in on stock firmware, where lsmod lists nothing and the old code
#      printed a warning per module;
#   2. when modprobe fails, the .ko is found in the firmware tree (BOTH layouts)
#      and insmod'ed by absolute path;
#   3. a warning is printed ONLY when the capability is still missing afterwards.
#
# Offline by construction: modprobe/insmod/lsmod/find are stubs and the procfs
# registry is a fixture. POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-${Z2K_INIT_UNDER_TEST:-$HERE/files/S99zapret2.new}}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/modld.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export TMP

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

# ---------------------------------------------------------------- the driver ---
# The functions hardcode /proc/net/... and /lib/... . Only those literals are
# rewritten to fixtures; the logic — the search order, the fallbacks, the warning
# condition — is the shipped code. Each rewrite is counted so it cannot silently
# fail and leave the test asserting against the real system.
LIB="$TMP/lib.sh"
{
    grep -m1 '^Z2K_MODDIRS=' "$INIT"
    extract_fn z2k_module_dirs    "$INIT"; echo
    extract_fn z2k_insmod_fw      "$INIT"; echo
    extract_fn z2k_module_present "$INIT"; echo
    extract_fn load_modules       "$INIT"; echo
} > "$LIB"

for f in z2k_module_dirs z2k_insmod_fw z2k_module_present load_modules; do
    grep -q "^$f()" "$LIB" && ok "extracted $f()" \
                           || no "extracted $f()" "a definition" "none"
done

nproc_ref=$(grep -c '/proc/net/ip_tables_\|/proc/net/netfilter/nfnetlink_queue' "$LIB")
[ "$nproc_ref" -ge 6 ] && ok "procfs registry is consulted ($nproc_ref references)" \
                       || no "procfs registry is consulted" ">=6" "$nproc_ref"

sed -e "s#/proc/net/#$TMP/proc/net/#g" \
    -e "s#/lib/modules#$TMP/lib/modules#g" \
    -e "s#/lib/system-modules#$TMP/lib/system-modules#g" \
    -e "s#find /lib #find $TMP/lib #" "$LIB" > "$TMP/lib2.sh"
# The find fallback must have been repointed too, or it would walk the real /lib.
grep -q "find $TMP/lib " "$TMP/lib2.sh" && ok "the bounded find is repointed at the fixture" \
                                        || no "the bounded find is repointed at the fixture" "fixture path" "still /lib"

mkdir -p "$TMP/proc/net/netfilter" "$TMP/bin"
BIN="$TMP/bin"

# modprobe: always fails, exactly like Entware's on a Keenetic.
cat > "$BIN/modprobe" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$TMP/modprobe.calls"
echo "modprobe: FATAL: Module \$1 not found in directory /opt/lib/modules/4.9-ndm-5" >&2
exit 1
EOF
# insmod: records the absolute path it was given, and "loading" a module makes the
# capability appear in the fixture registry — so the test observes the EFFECT.
cat > "$BIN/insmod" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$TMP/insmod.calls"
[ -f "\$1" ] || exit 1
case "\$1" in
    *xt_multiport.ko) echo multiport >> "$TMP/proc/net/ip_tables_matches" ;;
    *xt_connbytes.ko) echo connbytes >> "$TMP/proc/net/ip_tables_matches" ;;
    *xt_connmark.ko)  echo connmark  >> "$TMP/proc/net/ip_tables_matches" ;;
    *xt_CONNMARK.ko)  echo CONNMARK  >> "$TMP/proc/net/ip_tables_targets" ;;
esac
exit 0
EOF
cat > "$BIN/lsmod" <<EOF
#!/bin/sh
cat "$TMP/lsmod.out" 2>/dev/null
exit 0
EOF
cat > "$BIN/uname" <<'EOF'
#!/bin/sh
[ "$1" = "-r" ] && { echo 4.9-ndm-5; exit 0; }
exec /usr/bin/uname "$@"
EOF
# A find that can be switched OFF. Without this the whole directory list is dead
# weight in the tests: the fallback walk finds the .ko wherever it is, so deleting
# /lib/system-modules from the search changed no result and the NDMS 5.1.2 case
# was passing for the wrong reason (verified by mutation — it killed nothing).
cat > "$BIN/find" <<EOF
#!/bin/sh
[ -f "$TMP/nofind" ] && exit 0
exec /usr/bin/find "\$@"
EOF
chmod +x "$BIN/modprobe" "$BIN/insmod" "$BIN/lsmod" "$BIN/uname" "$BIN/find"

# run LAYOUT  -> LAYOUT is the firmware module directory to populate ("" = none)
run_load() {
    rm -rf "${TMP:?}/lib" "$TMP/proc/net"; mkdir -p "$TMP/proc/net/netfilter"
    : > "$TMP/modprobe.calls"; : > "$TMP/insmod.calls"; : > "$TMP/lsmod.out"
    : > "$TMP/proc/net/ip_tables_matches"; : > "$TMP/proc/net/ip_tables_targets"
    # nfnetlink_queue and the NFQUEUE target are always there: this suite is about
    # the OTHER modules, and load_modules returns early without them.
    echo NFQUEUE > "$TMP/proc/net/ip_tables_targets"
    : > "$TMP/proc/net/netfilter/nfnetlink_queue"
    if [ -n "$1" ]; then
        mkdir -p "$1"
        for m in xt_multiport xt_connbytes ip_set_bitmap_port; do : > "$1/$m.ko"; done
    fi
    ( . "$TMP/lib2.sh"; PATH="$BIN:$PATH"; load_modules ) 2>&1
}

warned_for() { printf '%s\n' "$1" | grep -q "Warning: $2 is not available"; }

# =============================================================================
# 1. the 4.9-ndm-5 layout: /lib/modules/<kver>
# =============================================================================
out=$(run_load "$TMP/lib/modules/4.9-ndm-5")
grep -q "$TMP/lib/modules/4.9-ndm-5/xt_multiport.ko" "$TMP/insmod.calls" \
    && ok "insmod is called with the ABSOLUTE firmware path (/lib/modules layout)" \
    || no "insmod is called with the ABSOLUTE firmware path (/lib/modules layout)" \
          "$TMP/lib/modules/4.9-ndm-5/xt_multiport.ko" "$(tr '\n' ';' < "$TMP/insmod.calls")"
warned_for "$out" xt_multiport && no "a module that loaded is not warned about" "no warning" "warned" \
                               || ok "a module that loaded is not warned about"
grep -q 'xt_multiport' "$TMP/modprobe.calls" \
    && ok "modprobe is still tried first (works where Entware has the module)" \
    || no "modprobe is still tried first" "xt_multiport" "$(tr '\n' ';' < "$TMP/modprobe.calls")"

# =============================================================================
# 2. the NDMS 5.1.2 layout: /lib/system-modules/<kver>  — the reported one
# =============================================================================
out=$(run_load "$TMP/lib/system-modules/4.9-ndm-5")
grep -q "$TMP/lib/system-modules/4.9-ndm-5/xt_connbytes.ko" "$TMP/insmod.calls" \
    && ok "the /lib/system-modules layout is found too (NDMS 5.1.2)" \
    || no "the /lib/system-modules layout is found too (NDMS 5.1.2)" \
          "system-modules path" "$(tr '\n' ';' < "$TMP/insmod.calls")"
warned_for "$out" xt_connbytes && no "connbytes loaded from system-modules is not warned about" "no warning" "warned" \
                               || ok "connbytes loaded from system-modules is not warned about"

# ...and it must be the DIRECTORY LIST that finds it, not the fallback walk. With
# find disabled the 5.1.2 layout still has to resolve, or the list does not
# actually know about /lib/system-modules and we are relying on a filesystem
# search that is slower and can pick up a copy from another kernel.
: > "$TMP/nofind"
out=$(run_load "$TMP/lib/system-modules/4.9-ndm-5")
grep -q "$TMP/lib/system-modules/4.9-ndm-5/xt_multiport.ko" "$TMP/insmod.calls" \
    && ok "the system-modules layout resolves from the directory list, with find disabled" \
    || no "the system-modules layout resolves from the directory list, with find disabled" \
          "system-modules path" "$(tr '\n' ';' < "$TMP/insmod.calls")"
# Same for the older layout, so neither entry can be dropped unnoticed.
out=$(run_load "$TMP/lib/modules/4.9-ndm-5")
grep -q "$TMP/lib/modules/4.9-ndm-5/xt_multiport.ko" "$TMP/insmod.calls" \
    && ok "the /lib/modules layout resolves from the directory list, with find disabled" \
    || no "the /lib/modules layout resolves from the directory list, with find disabled" \
          "modules path" "$(tr '\n' ';' < "$TMP/insmod.calls")"
# And the fallback itself still works when the layout is one we do not know.
rm -f "$TMP/nofind"
out=$(run_load "$TMP/lib/weird-modules/4.9-ndm-5")
grep -q "$TMP/lib/weird-modules/4.9-ndm-5/xt_multiport.ko" "$TMP/insmod.calls" \
    && ok "an unknown layout is still reached by the bounded find" \
    || no "an unknown layout is still reached by the bounded find" \
          "weird-modules path" "$(tr '\n' ';' < "$TMP/insmod.calls")"

# =============================================================================
# 3. genuinely absent -> warn, and say it will not be installed
# =============================================================================
# xt_CONNMARK/xt_connmark exist in NO layout here, mirroring the reported firmware
# where only act_connmark.ko is present.
out=$(run_load "$TMP/lib/modules/4.9-ndm-5")
warned_for "$out" xt_CONNMARK && ok "a genuinely absent module IS warned about" \
                              || no "a genuinely absent module IS warned about" "a warning" "$out"
case "$out" in
    *"rules that need it will not be installed"*)
        ok "the warning states the consequence, not 'may be built-in'" ;;
    *)  no "the warning states the consequence, not 'may be built-in'" "consequence" "$out" ;;
esac
case "$out" in
    *"may be built-in"*) no "the misleading 'may be built-in' wording is gone" "absent" "present" ;;
    *)                   ok "the misleading 'may be built-in' wording is gone" ;;
esac

# =============================================================================
# 4. built-in modules produce NO output and NO load attempt
# =============================================================================
# This is the wall of warnings from the field report: on stock firmware these are
# built in, lsmod lists nothing, and the old code warned for every one of them.
rm -rf "${TMP:?}/lib"; mkdir -p "$TMP/proc/net/netfilter"
: > "$TMP/modprobe.calls"; : > "$TMP/insmod.calls"; : > "$TMP/lsmod.out"
printf 'multiport\nconnbytes\nconnmark\n' > "$TMP/proc/net/ip_tables_matches"
printf 'NFQUEUE\nCONNMARK\n'              > "$TMP/proc/net/ip_tables_targets"
: > "$TMP/proc/net/netfilter/nfnetlink_queue"
out=$( . "$TMP/lib2.sh"; PATH="$BIN:$PATH"; load_modules 2>&1 )
case "$out" in
    *Warning*) no "everything built in -> no warnings at all" "no Warning" "$out" ;;
    *)         ok "everything built in -> no warnings at all" ;;
esac
n=$(grep -c . "$TMP/modprobe.calls" 2>/dev/null); n=${n:-0}
[ "$n" = 0 ] && ok "everything built in -> modprobe is not called at all ($n)" \
             || no "everything built in -> modprobe is not called" 0 "$n"

# =============================================================================
# 5. lsmod is NOT what decides availability
# =============================================================================
# The old code keyed off `lsmod | grep ^module`. A built-in module is never listed
# there, which is precisely why it warned about modules that were present.
rm -rf "${TMP:?}/lib"
: > "$TMP/modprobe.calls"; : > "$TMP/insmod.calls"; : > "$TMP/lsmod.out"
printf 'multiport\nconnbytes\nconnmark\n' > "$TMP/proc/net/ip_tables_matches"
printf 'NFQUEUE\nCONNMARK\n'              > "$TMP/proc/net/ip_tables_targets"
out=$( . "$TMP/lib2.sh"; PATH="$BIN:$PATH"; load_modules 2>&1 )
case "$out" in
    *Warning*) no "an empty lsmod does not make a present module 'missing'" "no Warning" "$out" ;;
    *)         ok "an empty lsmod does not make a present module 'missing'" ;;
esac

# =============================================================================
# 6. ip_set_bitmap_port uses the same search, not a hardcoded path
# =============================================================================
out=$(run_load "$TMP/lib/system-modules/4.9-ndm-5")
grep -q "$TMP/lib/system-modules/4.9-ndm-5/ip_set_bitmap_port.ko" "$TMP/insmod.calls" \
    && ok "ip_set_bitmap_port is found in the system-modules layout too" \
    || no "ip_set_bitmap_port is found in the system-modules layout too" \
          "system-modules path" "$(tr '\n' ';' < "$TMP/insmod.calls")"
grep -q '/lib/modules/\$(uname -r)/ip_set_bitmap_port\.ko' "$INIT" \
    && no "the hardcoded /lib/modules path for ip_set_bitmap_port is gone" "absent" "still there" \
    || ok "the hardcoded /lib/modules path for ip_set_bitmap_port is gone"

# =============================================================================
# 7. nfnetlink_queue gate no longer trusts Entware's modinfo
# =============================================================================
# modinfo is the same tool as modprobe and searches the same nonexistent
# directory, so on a firmware where nfnetlink_queue is BUILT IN the old gate
# returned failure and aborted a perfectly working router.
grep -q 'modinfo nfnetlink_queue' "$INIT" \
    && no "the nfnetlink_queue gate no longer depends on modinfo" "absent" "still there" \
    || ok "the nfnetlink_queue gate no longer depends on modinfo"
rm -rf "${TMP:?}/lib"
: > "$TMP/lsmod.out"
printf 'multiport\nconnbytes\nconnmark\n' > "$TMP/proc/net/ip_tables_matches"
printf 'NFQUEUE\nCONNMARK\n'              > "$TMP/proc/net/ip_tables_targets"
rm -f "$TMP/proc/net/netfilter/nfnetlink_queue"
out=$( . "$TMP/lib2.sh"; PATH="$BIN:$PATH"; load_modules >/dev/null 2>&1; echo "rc=$?" )
case "$out" in
    *rc=1*) ok "a missing nfnetlink_queue still fails load_modules (INVARIANT)" ;;
    *)      no "a missing nfnetlink_queue still fails load_modules (INVARIANT)" "rc=1" "$out" ;;
esac
: > "$TMP/proc/net/netfilter/nfnetlink_queue"
out=$( . "$TMP/lib2.sh"; PATH="$BIN:$PATH"; load_modules >/dev/null 2>&1; echo "rc=$?" )
case "$out" in
    *rc=0*) ok "present nfnetlink_queue -> load_modules succeeds" ;;
    *)      no "present nfnetlink_queue -> load_modules succeeds" "rc=0" "$out" ;;
esac

# =============================================================================
# 8. the search never reaches into /opt
# =============================================================================
# A .ko under /opt would be a leftover built for a different kernel: loading it is
# worse than not loading anything.
body=$(extract_fn z2k_insmod_fw "$INIT"; extract_fn z2k_module_dirs "$INIT")
case "$body" in
    *"/opt/"*) no "the firmware search never looks in /opt" "no /opt" "$body" ;;
    *)         ok "the firmware search never looks in /opt" ;;
esac
case "$body" in
    *"find /lib "*) ok "the fallback search is bounded to /lib" ;;
    *)              no "the fallback search is bounded to /lib" "find /lib" "$body" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
