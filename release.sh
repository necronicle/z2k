#!/bin/bash
# z2k release helper — appends an entry to UPDATES.json so the auto-update
# system on user routers picks it up on the next nightly cron.
#
# Usage:
#   release.sh patch     "fix detector false-positive"
#   release.sh reinstall "config schema change"
#   release.sh patch     "..." files/extra.txt   # add extra paths beyond git diff
#
# What it does:
#   1. Reads current UPDATES.json
#   2. Bumps the version: p-N → p-(N+1) for patch, p-N → r-(N+1) for reinstall
#   3. Auto-detects changed files via `git diff --name-only <last_ref>..HEAD`
#   4. Appends a new history entry with ref=<short HEAD sha>, ts=now (UTC)
#   5. Rewrites UPDATES.json with current=<new version>
#
# After running this, commit + push UPDATES.json to z2k-enhanced; user routers
# pick up the change at the next nightly cron (02:00 + jitter).

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$REPO_DIR/UPDATES.json"
TYPE="$1"
DESC="$2"
shift 2 || true
EXTRA_FILES="$*"

if [ -z "$TYPE" ] || [ -z "$DESC" ]; then
    cat <<'USAGE' >&2
usage: release.sh <patch|reinstall> <desc> [extra files...]

  patch     — single-file or small fix; auto-update applies via direct
              file replacement, no opkg / install_prereq
  reinstall — anything that needs a full curl z2k.sh | sh, e.g. config
              schema change, install.sh logic change, opkg deps update

USAGE
    exit 1
fi

case "$TYPE" in
    patch|reinstall) ;;
    *) echo "ERROR: type must be patch or reinstall (got: $TYPE)" >&2; exit 1 ;;
esac

BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "z2k-enhanced" ]; then
    echo "ERROR: must be on z2k-enhanced branch (current: $BRANCH)" >&2
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: $MANIFEST not found" >&2
    exit 1
fi

# The tree must be CLEAN, and this is not tidiness — it is the difference between
# a release that installs and one that fails closed on every router at once.
#
# scripts/gen_file_hashes.sh digests files AS THEY SIT ON DISK, while routers
# download the COMMITTED revision. Cut a release with an unrelated edit in the
# working tree and the map publishes the digest of a file nobody can obtain: the
# updater rejects the good download at every mirror and the update aborts for
# everyone, with no way to tell it apart from a hostile mirror.
#
# Only tracked files matter — untracked ones are invisible to `git ls-files` and
# therefore never enter the map.
DIRTY=$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)
if [ -n "$DIRTY" ]; then
    echo "ERROR: рабочее дерево не чистое — релиз отменён." >&2
    echo "Карта files_sha256 считается с ДИСКА, а роутеры качают закоммиченное:" >&2
    echo "любая незакоммиченная правка = дайджест, который ни один роутер не получит," >&2
    echo "и обновление падает fail-closed у всех сразу." >&2
    echo >&2
    echo "$DIRTY" >&2
    echo >&2
    echo "Закоммить нужное или убери лишнее в 'git stash' и повтори." >&2
    exit 1
fi

REF=$(git -C "$REPO_DIR" rev-parse --short HEAD)

# Find the last *real* ref in the manifest (skip baseline marker and the
# literal "HEAD" placeholder some manually-edited entries carry).
LAST_REF=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))
last = ''
for e in reversed(m['history']):
    r = e.get('ref', '')
    if r and r not in ('auto-update-baseline', 'HEAD'):
        last = r
        break
print(last)
")

# Validate the ref actually resolves to a commit in this repo — a stale or
# bogus ref (e.g. a short sha from a rebased history) would make
# `git diff REF..HEAD` error out or, worse, silently diff nothing.
AUTO_FILES=""
if [ -n "$LAST_REF" ] && git -C "$REPO_DIR" cat-file -e "${LAST_REF}^{commit}" 2>/dev/null; then
    AUTO_FILES=$(git -C "$REPO_DIR" diff --name-only "${LAST_REF}..HEAD" 2>/dev/null || true)
elif [ -n "$LAST_REF" ]; then
    echo "WARN: last manifest ref '$LAST_REF' not found in repo — pass changed files explicitly" >&2
fi

# Combine with extra files; dedupe.
#
# index.html is added unconditionally: every release bumps "current", and
# gen_file_hashes.sh derives the panel's `?v=` cache-buster from it, so the file
# ALWAYS changes — but it changes below, after this list is computed from the
# commit diff, so it could never appear here on its own. Leaving it out shipped
# a panel whose digest moved while changed_files said it had not, which
# tests/test_release_manifest_complete.sh exists to catch.
ALL_FILES=$(printf '%s\n%s\n%s\n' "$AUTO_FILES" "$EXTRA_FILES" "webpanel/www/index.html" \
    | tr ' ' '\n' | sort -u | grep -v '^$' || true)

python3 - <<EOF
import json, datetime, sys, os

manifest_path = "$MANIFEST"
m = json.load(open(manifest_path))

import re
last_v = m['history'][-1]['v']
# Version is "<letter>-<int>" with an optional ".<hotfix>" suffix (e.g. r-54.1,
# a manually-added dotted hotfix). Parse the integer core robustly so a dotted
# last version does not crash int(); a new release bumps the whole number
# (r-54 / r-54.1 -> r-55), hotfix dots are never auto-generated.
mver = re.match(r'^([a-z])-(\d+)', last_v)
if not mver:
    sys.exit(f"ERROR: cannot parse last version {last_v!r} (expected <letter>-<int>)")
prefix_old, num_str = mver.group(1), mver.group(2)
n = int(num_str) + 1
prefix = 'r' if "$TYPE" == 'reinstall' else 'p'
new_v = f"{prefix}-{n}"

files = """$ALL_FILES""".strip().splitlines()
files = [f.strip() for f in files if f.strip()]

entry = {
    "v": new_v,
    "type": "$TYPE",
    "ts": datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    "ref": "$REF",
    "desc": """$DESC""",
    "changed_files": files,
}
m['current'] = new_v
m['history'].append(entry)

# Reformat with one entry per line (single-line JSON per entry).
#
# files_sha256 is carried over verbatim. gen_file_hashes.sh rewrites it a moment
# later anyway, but this serialiser used to know only four keys and DROPPED the
# map — so any failure between here and the generator left a manifest with no
# digests at all, i.e. the exact unverified-download hole the map was added to
# close. Never emit a manifest that is missing it.
out = '{\n'
out += '  "schema": ' + str(m['schema']) + ',\n'
out += '  "branch": "' + m['branch'] + '",\n'
out += '  "current": "' + m['current'] + '",\n'
if m.get('files_sha256'):
    out += '  "files_sha256": {\n'
    pairs = [f'    "{k}": "{v}"' for k, v in m['files_sha256'].items()]
    out += ',\n'.join(pairs)
    out += '\n  },\n'
out += '  "history": [\n'
entry_lines = [json.dumps(e, ensure_ascii=False) for e in m['history']]
out += ',\n'.join(entry_lines)
out += '\n  ]\n}\n'
open(manifest_path, 'w').write(out)

print(f"Added {new_v} ({entry['type']}) with {len(files)} changed file(s)")
if files:
    for f in files:
        print(f"  - {f}")
EOF

# Refresh the digest map in the same breath. Leaving it to the operator meant a
# release could be committed with a map describing the PREVIOUS tree — CI catches
# that, but only after a push, and the two steps are one indivisible operation
# anyway: a version bump changes the panel's cache-buster, which changes a
# deliverable file, which changes the map.
echo
sh "$REPO_DIR/scripts/gen_file_hashes.sh" || {
    echo "ERROR: не удалось пересчитать files_sha256 — манифест оставлен в промежуточном виде." >&2
    echo "Проверь scripts/gen_file_hashes.sh и запусти его вручную перед коммитом." >&2
    exit 1
}

# The generator must be a fixed point after one run: it rewrites index.html and
# then hashes it, so a second run has nothing left to change. If it does, the
# ordering regressed and the map we just wrote does not describe the tree.
_probe=$(mktemp) || exit 1
cp "$MANIFEST" "$_probe"
sh "$REPO_DIR/scripts/gen_file_hashes.sh" >/dev/null 2>&1 || true
if ! cmp -s "$_probe" "$MANIFEST"; then
    rm -f "$_probe"
    echo "ERROR: files_sha256 не сошёлся за один прогон генератора." >&2
    echo "Значит кеш-бастер панели снова правится ПОСЛЕ хеширования — CI упадёт." >&2
    exit 1
fi
rm -f "$_probe"

echo
echo "Next:"
echo "  git -C $REPO_DIR add UPDATES.json webpanel/www/index.html"
echo "  git -C $REPO_DIR commit -m 'release: $TYPE — $DESC'"
echo "  git -C $REPO_DIR push origin z2k-enhanced"
