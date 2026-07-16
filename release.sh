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

# Combine with extra files; dedupe
ALL_FILES=$(printf '%s\n%s\n' "$AUTO_FILES" "$EXTRA_FILES" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

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
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "ref": "$REF",
    "desc": """$DESC""",
    "changed_files": files,
}
m['current'] = new_v
m['history'].append(entry)

# Reformat with one entry per line (single-line JSON per entry)
out = '{\n'
out += '  "schema": ' + str(m['schema']) + ',\n'
out += '  "branch": "' + m['branch'] + '",\n'
out += '  "current": "' + m['current'] + '",\n'
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

echo
echo "Next:"
echo "  git -C $REPO_DIR add UPDATES.json"
echo "  git -C $REPO_DIR commit -m 'release: $TYPE — $DESC'"
echo "  git -C $REPO_DIR push origin z2k-enhanced"
