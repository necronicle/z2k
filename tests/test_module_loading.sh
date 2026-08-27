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
_real_find=$(command -v find)  # у хозяина, а не /usr/bin: на Keenetic его там нет
cat > "$BIN/find" <<EOF
#!/bin/sh
[ -f "$TMP/nofind" ] && exit 0
exec $_real_find "\$@"
EOF
# ipset: the bitmap:port capability probe. Stubbed rather than left to the host —
# without this the suite would call the REAL ipset wherever one is installed, which
# both makes the result depend on the machine and tries to create a set for real.
# $TMP/nobitmap = the firmware that has no bitmap:port type.
cat > "$BIN/ipset" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/ipset.calls"
case "\$1" in
    create)
        case "\$3" in
            bitmap:port) [ -f "$TMP/nobitmap" ] && {
                             echo "ipset v7.24: Kernel error received: set type not supported" >&2
                             exit 1
                         } ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$BIN/modprobe" "$BIN/insmod" "$BIN/lsmod" "$BIN/uname" "$BIN/find" "$BIN/ipset"

# run LAYOUT [nobytes] -> LAYOUT is the firmware module directory to populate ("" = none)
run_load() {
    rm -rf "${TMP:?}/lib" "$TMP/proc/net"; mkdir -p "$TMP/proc/net/netfilter"
    : > "$TMP/modprobe.calls"; : > "$TMP/insmod.calls"; : > "$TMP/lsmod.out"
    : > "$TMP/ipset.calls"
    : > "$TMP/proc/net/ip_tables_matches"; : > "$TMP/proc/net/ip_tables_targets"
    # nfnetlink_queue and the NFQUEUE target are always there: this suite is about
    # the OTHER modules, and load_modules returns early without them.
    echo NFQUEUE > "$TMP/proc/net/ip_tables_targets"
    : > "$TMP/proc/net/netfilter/nfnetlink_queue"
    if [ -n "$1" ]; then
        mkdir -p "$1"
        for m in xt_multiport xt_connbytes ip_set_bitmap_port; do : > "$1/$m.ko"; done
        # $2 = "nobytes": leave xt_connbytes with no .ko anywhere, so it is genuinely
        # unavailable — the shape the reported firmware has for connmark.
        [ "$2" = nobytes ] && rm -f "$1/xt_connbytes.ko"
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
# Nothing to load it from and nothing in the registry: the reported firmware's case.
out=$(run_load "$TMP/lib/modules/4.9-ndm-5" nobytes)
warned_for "$out" xt_connbytes && ok "a genuinely absent module IS warned about" \
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
# 3b. connmark modules are loaded, and ONLY because the member guard exists
# =============================================================================
# They serve one feature — Keenetic policy exclusion. Measured on a live router:
# traffic from a policy member carries the policy mark at mangle POSTROUTING on every
# packet, traffic outside any policy carries mark 0, so the mechanism works. What
# does not work is a MEMBERLESS policy in the default "only policy traffic" mode:
# the rule then puts the exclude bit on every connection and NFQUEUE processes
# nobody — the reported field failure. Making these modules loadable is therefore
# only safe while z2k_policy_connmark_start refuses to install for 0 members. Both
# halves are asserted here so neither can be removed alone.
list_line=$(grep -m1 'local modules=' "$INIT")
for m in xt_multiport xt_connbytes xt_NFQUEUE nfnetlink_queue xt_CONNMARK xt_connmark; do
    case "$list_line" in
        *"$m"*) ok "$m is in the load list" ;;
        *)      no "$m is in the load list" "in the list" "$list_line" ;;
    esac
done
guard=$(awk '/^z2k_policy_connmark_start\(\)/{f=1} f{print} f&&/^}/{exit}' "$INIT")
case "$guard" in
    *z2k_policy_members*) ok "the exclusion rule consults the member count" ;;
    *)                    no "the exclusion rule consults the member count" "z2k_policy_members" "absent" ;;
esac
case "$guard" in
    *'has no member hosts'*) ok "a memberless policy is reported and skipped" ;;
    *)                       no "a memberless policy is reported and skipped" "the skip" "absent" ;;
esac
# The skip must come BEFORE any rule is inserted, or it protects nothing.
skip_ln=$(printf '%s\n' "$guard" | grep -n 'has no member hosts' | head -1 | cut -d: -f1)
ins_ln=$(printf '%s\n' "$guard" | grep -n 'iptablesw -t mangle' | head -1 | cut -d: -f1)
if [ -n "$skip_ln" ] && [ -n "$ins_ln" ] && [ "$skip_ln" -lt "$ins_ln" ]; then
    ok "the member check runs before the rule is inserted ($skip_ln < $ins_ln)"
else
    no "the member check runs before the rule is inserted" "skip<insert" "$skip_ln/$ins_ln"
fi

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

# =============================================================================
# 9. bitmap:port is checked as a CAPABILITY, not as a loaded module
# =============================================================================
# Loading the module and having the type are different questions: bitmap:port can
# be compiled into the kernel with no .ko anywhere, and it can be absent from the
# firmware entirely. Only creating a set separates the two. It matters because
# zport_tcp/zport_udp gate every nfqws rule and the engine has no --dport
# fallback, so an unavailable type means no bypass at all — and it used to appear
# only as a wall of raw "Set zport_tcp doesn't exist" from iptables (issue #27).
rm -f "$TMP/nobitmap"
out=$(run_load "$TMP/lib/system-modules/4.9-ndm-5")
case "$out" in
    *bitmap:port*) no "a working bitmap:port says nothing" "silence" "$out" ;;
    *)             ok "a working bitmap:port says nothing" ;;
esac
grep -q 'create z2k_probe_bitmap bitmap:port' "$TMP/ipset.calls" \
    && ok "the type is probed by actually creating a set" \
    || no "the type is probed by actually creating a set" "a create" "$(tr '\n' ';' < "$TMP/ipset.calls")"
grep -q 'destroy z2k_probe_bitmap' "$TMP/ipset.calls" \
    && ok "the probe set is cleaned up again" \
    || no "the probe set is cleaned up again" "a destroy" "$(tr '\n' ';' < "$TMP/ipset.calls")"

: > "$TMP/nobitmap"
out=$(run_load "$TMP/lib/system-modules/4.9-ndm-5")
case "$out" in
    *"bitmap:port is not available"*) ok "an unavailable type IS reported" ;;
    *) no "an unavailable type IS reported" "a warning" "$out" ;;
esac
case "$out" in
    *zport_tcp*|*zport_udp*) ok "the report names the sets that cannot be created" ;;
    *) no "the report names the sets that cannot be created" "zport_*" "$out" ;;
esac
case "$out" in
    *"bypass will not work"*) ok "the report states the consequence, not just the symptom" ;;
    *) no "the report states the consequence, not just the symptom" "consequence" "$out" ;;
esac
rm -f "$TMP/nobitmap"

# =============================================================================
# 10. the INSTALL-TIME loader has the same properties as the runtime one
# =============================================================================
# lib/utils.sh had the original form of this bug and kept it after the runtime was
# fixed: lsmod decided availability and the .ko path was hardcoded to
# /lib/modules/<kver>. On the reported firmware that made the installer print a
# red "Файл модуля не найден" for modules that are present, which reads as "your
# fix did not work" to anyone who just reinstalled to get the fix.
UTILS="$HERE/lib/utils.sh"
if [ ! -f "$UTILS" ]; then
    no "lib/utils.sh found" "a file" "missing"
else
    sed -e "s#/proc/net/#$TMP/proc/net/#g" \
        -e "s#/lib/modules#$TMP/lib/modules#g" \
        -e "s#/lib/system-modules#$TMP/lib/system-modules#g" \
        -e "s#find /lib #find $TMP/lib #" "$UTILS" > "$TMP/utils2.sh"
    grep -q "find $TMP/lib " "$TMP/utils2.sh" \
        && ok "install-time: the bounded find is repointed at the fixture" \
        || no "install-time: the bounded find is repointed at the fixture" "fixture path" "still /lib"

    # the NDMS 5.1.2 layout, with the fallback walk switched off so the directory
    # list is what has to resolve it
    run_load "" >/dev/null
    mkdir -p "$TMP/lib/system-modules/4.9-ndm-5"
    : > "$TMP/lib/system-modules/4.9-ndm-5/xt_multiport.ko"
    : > "$TMP/insmod.calls"; : > "$TMP/nofind"
    out=$( . "$TMP/utils2.sh"; PATH="$BIN:$PATH"; load_kernel_module xt_multiport 2>&1; echo "rc=$?" )
    rm -f "$TMP/nofind"
    grep -q "$TMP/lib/system-modules/4.9-ndm-5/xt_multiport.ko" "$TMP/insmod.calls" \
        && ok "install-time: the /lib/system-modules layout is searched (NDMS 5.1.2)" \
        || no "install-time: the /lib/system-modules layout is searched" \
              "system-modules path" "$(tr '\n' ';' < "$TMP/insmod.calls")"
    case "$out" in
        *rc=0*) ok "install-time: loading from system-modules succeeds" ;;
        *)      no "install-time: loading from system-modules succeeds" "rc=0" "$out" ;;
    esac

    # built in: no complaint and no load attempt, the wall-of-red case
    rm -rf "${TMP:?}/lib"; mkdir -p "$TMP/proc/net"
    printf 'multiport\nconnbytes\n' > "$TMP/proc/net/ip_tables_matches"
    printf 'NFQUEUE\n'              > "$TMP/proc/net/ip_tables_targets"
    : > "$TMP/insmod.calls"; : > "$TMP/lsmod.out"
    out=$( . "$TMP/utils2.sh"; PATH="$BIN:$PATH"; load_kernel_module xt_multiport 2>&1; echo "rc=$?" )
    case "$out" in
        *"не найден"*|*"Ошибка загрузки"*) no "install-time: a built-in module is not reported missing" "silence" "$out" ;;
        *) ok "install-time: a built-in module is not reported missing" ;;
    esac
    case "$out" in
        *rc=0*) ok "install-time: a built-in module succeeds" ;;
        *)      no "install-time: a built-in module succeeds" "rc=0" "$out" ;;
    esac
    n=$(grep -c . "$TMP/insmod.calls" 2>/dev/null); n=${n:-0}
    [ "$n" = 0 ] && ok "install-time: a built-in module triggers no insmod ($n)" \
                 || no "install-time: a built-in module triggers no insmod" 0 "$n"

    # genuinely absent -> a failure that names the consequence
    rm -rf "${TMP:?}/lib"; : > "$TMP/proc/net/ip_tables_matches"
    out=$( . "$TMP/utils2.sh"; PATH="$BIN:$PATH"; load_kernel_module xt_connbytes 2>&1; echo "rc=$?" )
    case "$out" in
        *rc=1*) ok "install-time: a genuinely absent module fails" ;;
        *)      no "install-time: a genuinely absent module fails" "rc=1" "$out" ;;
    esac
    case "$out" in
        *"установлены не будут"*) ok "install-time: the message states the consequence" ;;
        *) no "install-time: the message states the consequence" "consequence" "$out" ;;
    esac

    # the preflight question: not "is it loaded" but "will it be loadable". It runs
    # BEFORE the load step, so a .ko on disk must already count as available.
    mkdir -p "$TMP/lib/system-modules/4.9-ndm-5"
    : > "$TMP/lib/system-modules/4.9-ndm-5/xt_connbytes.ko"
    : > "$TMP/proc/net/ip_tables_matches"
    out=$( . "$TMP/utils2.sh"; PATH="$BIN:$PATH"; z2k_module_obtainable xt_connbytes; echo "rc=$?" )
    case "$out" in
        *rc=0*) ok "install-time: an unloaded .ko on disk counts as obtainable" ;;
        *)      no "install-time: an unloaded .ko on disk counts as obtainable" "rc=0" "$out" ;;
    esac
    rm -rf "${TMP:?}/lib"
    out=$( . "$TMP/utils2.sh"; PATH="$BIN:$PATH"; z2k_module_obtainable xt_connbytes; echo "rc=$?" )
    case "$out" in
        *rc=1*) ok "install-time: nothing on disk and nothing in the kernel is NOT obtainable" ;;
        *)      no "install-time: nothing on disk and nothing in the kernel is NOT obtainable" "rc=1" "$out" ;;
    esac

    # and the capability probe, both ways
    out=$( . "$TMP/utils2.sh"; PATH="$BIN:$PATH"; z2k_bitmap_port_available; echo "rc=$?" )
    case "$out" in
        *rc=0*) ok "install-time: a working bitmap:port probes available" ;;
        *)      no "install-time: a working bitmap:port probes available" "rc=0" "$out" ;;
    esac
    : > "$TMP/nobitmap"
    out=$( . "$TMP/utils2.sh"; PATH="$BIN:$PATH"; z2k_bitmap_port_available; echo "rc=$?" )
    case "$out" in
        *rc=1*) ok "install-time: a missing bitmap:port probes unavailable" ;;
        *)      no "install-time: a missing bitmap:port probes unavailable" "rc=1" "$out" ;;
    esac
    rm -f "$TMP/nobitmap"
fi

# the two hardcoded assumptions must be gone from the installer as well
INST="$HERE/lib/install.sh"
if [ -f "$INST" ]; then
    grep -q '/lib/modules/\$(uname -r)/ip_set_bitmap_port\.ko' "$INST" \
        && no "installer: the hardcoded ip_set_bitmap_port path is gone" "absent" "still there" \
        || ok "installer: the hardcoded ip_set_bitmap_port path is gone"
    grep -q 'modinfo xt_' "$INST" \
        && no "installer: the module preflight no longer trusts Entware's modinfo" "absent" "still there" \
        || ok "installer: the module preflight no longer trusts Entware's modinfo"
fi
# lsmod may survive in exactly one place: the default branch of z2k_module_present,
# for modules with no entry in the netfilter registries. Anywhere else it is the old
# bug returning — a built-in module is never listed there.
lsmod_code=$(grep -n 'lsmod' "$UTILS" | grep -vc '^[0-9]*:[[:space:]]*#')
[ "$lsmod_code" -le 1 ] \
    && ok "install-time: lsmod decides nothing but the fallback case ($lsmod_code use)" \
    || no "install-time: lsmod decides nothing but the fallback case" "<=1 use" "$lsmod_code"
grep -A3 '^check_kernel_module()' "$UTILS" | grep -q 'lsmod' \
    && no "install-time: check_kernel_module no longer keys off lsmod" "absent" "still there" \
    || ok "install-time: check_kernel_module no longer keys off lsmod"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
