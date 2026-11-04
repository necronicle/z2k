#!/bin/sh
# Exercise the published updater delivering and loading the new step runner.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export ZAPRET2_DIR="$SB/zd" CONFIG_FILE="$SB/zd/config" Z2K_AU_SOURCE_ONLY=1
export Z2K_AU_LOG_FILE="$SB/log"
export Z2K_AU_INSTALLED_TAG_FILE="$SB/tag" Z2K_AU_TMP_DIR="$SB/tmp"
mkdir -p "$SB/zd/lib" "$SB/tmp"
git -C "$ROOT" show p-87.12:lib/auto_update.sh > "$SB/old-updater.sh"
. "$ROOT/lib/utils.sh"
. "$SB/old-updater.sh"
Z2K_AU_TMP_DIR="$SB/tmp"
# Delivered worker is a recorder: actual success-marker handling is covered
# against the real refresher in redirector_refresh_cases.py.
cat > "$SB/worker.sh" <<'WORKER'
#!/bin/sh
printf '%s\n' "$@" > "$ZAPRET2_DIR/worker-args"
WORKER
cp "$ROOT/lib/auto_update.sh" "$SB/new-updater.sh"
sha_auto=$(z2k_sha256_file "$SB/new-updater.sh")
sha_worker=$(z2k_sha256_file "$SB/worker.sh")
cat > "$SB/tmp/UPDATES.json" <<MANIFEST
{"current":"p-test",
"install_map": {
"files/z2k-redirector-ip-refresh.sh": ["$SB/zd/z2k-redirector-ip-refresh.sh"],
"lib/auto_update.sh": ["$SB/zd/lib/auto_update.sh"]
},
"files_sha256": {
"files/z2k-redirector-ip-refresh.sh": "$sha_worker",
"lib/auto_update.sh": "$sha_auto"
},
"history":[
{"v":"p-test","type":"patch","steps":[],"changed_files":["lib/auto_update.sh","files/z2k-redirector-ip-refresh.sh"]}
]}
MANIFEST
au_download_repo_file() {
 case "$1" in
  lib/auto_update.sh) cp "$SB/new-updater.sh" "$2" ;;
  files/z2k-redirector-ip-refresh.sh) cp "$SB/worker.sh" "$2" ;;
  *) return 1 ;;
 esac
}
au_snapshot_for_patch() { return 0; }
au_health_check() { return 0; }
printf 'p-old\n' > "$SB/tag"
au_apply_converge p-test
n=0
while [ ! -s "$SB/zd/worker-args" ] && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
printf '%s\n' --after-update p-test "$SB/tag" > "$SB/expected"
cmp "$SB/expected" "$SB/zd/worker-args"
[ "$(cat "$SB/tag")" = p-test ]
printf '[PASS] published updater delivers new refresher and launches it with success marker\n'
