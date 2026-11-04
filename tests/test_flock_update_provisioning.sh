#!/bin/sh
# Old installs without the flock package get it from the update itself.
#
# common/ipt.sh serialises iptables check+insert pairs only when `flock` exists.
# The installer lists the package since p-87.13; routers installed earlier get
# it from the post-commit worker in au_run_steps, which the PUBLISHED old
# updater runs from the delivered lib/auto_update.sh. These cases run that real
# path: an old updater, the redirector DNS feature switched off (its refresher
# exits before its own flock provisioning), a host PATH with flock hidden, and
# a recording opkg stub. No package manager or network is touched.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
TOP=$(mktemp -d "${TMPDIR:-/tmp}/flock-prov.XXXXXX") || exit 1
trap 'rm -rf "$TOP"' EXIT INT TERM

# Every host tool except flock, so a CI runner's own util-linux flock does not
# make the "missing" case vacuous.
HOSTBIN="$TOP/hostbin"; mkdir -p "$HOSTBIN"
_ifs=$IFS; IFS=:
for d in $PATH; do
    [ -d "$d" ] || continue
    for t in "$d"/*; do
        n=${t##*/}
        [ "$n" = flock ] && continue
        [ -x "$t" ] && [ ! -e "$HOSTBIN/$n" ] && ln -s "$t" "$HOSTBIN/$n"
    done
done
IFS=$_ifs

# $1 old updater tag, $2 opkg behaviour (ok|fail), $3 flock initially (yes|no)
run_update() {
    SB=$(mktemp -d "$TOP/sb.XXXXXX")
    mkdir -p "$SB/zd/lib" "$SB/tmp" "$SB/stub"
    printf 'Z2K_REDIRECTOR_DNS=0\n' > "$SB/zd/config"
    cat > "$SB/stub/opkg" <<EOF
#!/bin/sh
echo "opkg \$*" >> "$SB/opkg.calls"
[ "$2" = ok ] || exit 255
printf '#!/bin/sh\nexit 0\n' > "$SB/stub/flock"; chmod +x "$SB/stub/flock"
EOF
    cat > "$SB/stub/ndmc" <<EOF
#!/bin/sh
echo "ndmc \$*" >> "$SB/ndmc.calls"
EOF
    chmod +x "$SB/stub/opkg" "$SB/stub/ndmc"
    [ "$3" = yes ] && { printf '#!/bin/sh\nexit 0\n' > "$SB/stub/flock"; chmod +x "$SB/stub/flock"; }
    git -C "$ROOT" show "$1:lib/auto_update.sh" > "$SB/old-updater.sh" || return 1
    (
        PATH="$SB/stub:$HOSTBIN"
        export PATH ZAPRET2_DIR="$SB/zd" CONFIG_FILE="$SB/zd/config" Z2K_AU_SOURCE_ONLY=1
        export Z2K_AU_LOG_FILE="$SB/log" Z2K_AU_INSTALLED_TAG_FILE="$SB/tag" Z2K_AU_TMP_DIR="$SB/tmp"
        . "$ROOT/lib/utils.sh"
        . "$SB/old-updater.sh"
        Z2K_AU_TMP_DIR="$SB/tmp"
        cp "$ROOT/lib/auto_update.sh" "$SB/new-updater.sh"
        cp "$ROOT/files/z2k-redirector-ip-refresh.sh" "$SB/refresher.sh"
        sha_auto=$(z2k_sha256_file "$SB/new-updater.sh")
        sha_ref=$(z2k_sha256_file "$SB/refresher.sh")
        cat > "$SB/tmp/UPDATES.json" <<MANIFEST
{"current":"p-test",
"install_map": {
"files/z2k-redirector-ip-refresh.sh": ["$SB/zd/z2k-redirector-ip-refresh.sh"],
"lib/auto_update.sh": ["$SB/zd/lib/auto_update.sh"]
},
"files_sha256": {
"files/z2k-redirector-ip-refresh.sh": "$sha_ref",
"lib/auto_update.sh": "$sha_auto"
},
"history":[
{"v":"p-test","type":"patch","steps":[],"changed_files":["lib/auto_update.sh","files/z2k-redirector-ip-refresh.sh"]}
]}
MANIFEST
        au_download_repo_file() {
            case "$1" in
                lib/auto_update.sh) cp "$SB/new-updater.sh" "$2" ;;
                files/z2k-redirector-ip-refresh.sh) cp "$SB/refresher.sh" "$2" ;;
                *) return 1 ;;
            esac
        }
        au_snapshot_for_patch() { return 0; }
        au_health_check() { return 0; }
        printf 'p-old\n' > "$SB/tag"
        au_apply_converge p-test >/dev/null 2>&1
        echo "$?" > "$SB/rc"
    )
    # the worker is detached; give it time to see the marker and finish
    n=0
    while [ "$n" -lt 30 ]; do
        grep -q 'flock установлен\|пакет flock не установился' "$SB/log" 2>/dev/null && break
        [ "$3" = yes ] && [ "$n" -ge 3 ] && break
        sleep 1; n=$((n + 1))
    done
    sleep 1
}
calls() { if [ -f "$SB/$1" ]; then tr '\n' '|' < "$SB/$1"; fi; }

for old in p-87.12 p-87.15; do
    run_update "$old" ok no
    eq "$old updater: update commits" '0 p-test' "$(cat "$SB/rc") $(cat "$SB/tag")"
    eq "$old updater, redirector DNS off, no flock: package is installed" 'opkg install flock|' "$(calls opkg.calls)"
    [ -x "$SB/stub/flock" ] && have=yes || have=no
    eq "$old updater: flock is available afterwards" yes "$have"
    grep -q 'flock установлен' "$SB/log" && logged=yes || logged=no
    eq "$old updater: installation is logged" yes "$logged"
    eq "$old updater: redirector DNS stays untouched when switched off" '' "$(calls ndmc.calls)"

    run_update "$old" fail no
    eq "$old updater, opkg fails: update still commits (no rollback)" '0 p-test' "$(cat "$SB/rc") $(cat "$SB/tag")"
    [ -s "$SB/zd/lib/auto_update.sh" ] && kept=yes || kept=no
    eq "$old updater, opkg fails: delivered files stay in place" yes "$kept"
    grep -q 'ВНИМАНИЕ: пакет flock не установился' "$SB/log" && warned=yes || warned=no
    eq "$old updater, opkg fails: degraded protection is logged explicitly" yes "$warned"

    run_update "$old" ok yes
    eq "$old updater, flock present: no package operation" '' "$(calls opkg.calls)"
done

# Not committed (rollback or failed health check): the marker never reaches the
# target, so nothing is installed. sleep is shortened to keep the case fast.
SB=$(mktemp -d "$TOP/sb.XXXXXX"); mkdir -p "$SB/stub"
cat > "$SB/stub/opkg" <<EOF
#!/bin/sh
echo "opkg \$*" >> "$SB/opkg.calls"
EOF
chmod +x "$SB/stub/opkg"
printf 'p-old\n' > "$SB/tag"
out=$(
    PATH="$SB/stub:$HOSTBIN"
    Z2K_AU_SOURCE_ONLY=1 Z2K_AU_LOG_FILE="$SB/log" ZAPRET2_DIR="$SB/zd"
    export PATH Z2K_AU_SOURCE_ONLY Z2K_AU_LOG_FILE ZAPRET2_DIR
    . "$ROOT/lib/utils.sh"
    . "$ROOT/lib/auto_update.sh"
    sleep() { :; }
    au_provision_flock p-test "$SB/tag"; echo "rc=$?"
)
eq 'rolled-back update: worker gives up' rc=1 "$out"
eq 'rolled-back update: no package operation' '' "$(calls opkg.calls)"

# The refresher only starts after provisioning, inside the same worker, so two
# opkg never race for the package lock.
body=$(awk '/^au_run_steps\(\)/{f=1} f{print} f&&/^}/{exit}' "$ROOT/lib/auto_update.sh")
p_ln=$(printf '%s\n' "$body" | grep -n 'au_provision_flock' | head -1 | cut -d: -f1)
r_ln=$(printf '%s\n' "$body" | grep -n 'sh "$redirector_refresh" --after-update' | head -1 | cut -d: -f1)
if [ -n "$p_ln" ] && [ -n "$r_ln" ] && [ "$p_ln" -lt "$r_ln" ]; then
    ok "provisioning precedes the refresher in one worker (line $p_ln < $r_ln)"
else
    no 'provisioning precedes the refresher in one worker' 'provision first' "$p_ln/$r_ln"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
