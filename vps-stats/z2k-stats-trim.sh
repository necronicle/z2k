#!/bin/sh
# z2k-stats-trim.sh — retention for the anonymized stats log.
#
# WHY THIS FILE EXISTS IN THE REPOSITORY. It did not, for a long time. A working
# copy of this script lived only on the live VPS, installed by hand, driven by a
# cron.monthly entry that no file here mentions. Everything looked fine from the
# server: the log sat at a steady ~90 MB and the daily aggregation ran. But
# deploy-vps.sh — which calls itself idempotent and is the documented way to
# stand this service up — installed a collector that appends forever and nothing
# at all that prunes. Rebuild the VPS, or deploy to a second one, and the service
# comes up with no retention whatsoever: the log grows without a ceiling on a box
# that also carries the Telegram tunnels and the WhatsApp relay.
#
# A safeguard that exists on exactly one machine and in no version control is not
# a safeguard, it is a thing that is about to be lost. So it lives here now, the
# installer wires it up, and the schedule moved from monthly to weekly — monthly
# let the window drift to 90 days between runs, half again the retention the
# aggregator needs.
#
# WHAT IT DOES. Lines older than KEEP_DAYS move into a per-month gzip archive
# beside the live file. KEEP_DAYS must stay comfortably above the aggregator's
# --window-days (14 by default); 60 is deliberate slack, not a tuned number.
#
# WHY IT STOPS THE COLLECTOR. The rewrite is read-all, write-temp, atomic
# replace. An upload landing between the read and the replace would be dropped on
# the floor, silently. Stopping for the few seconds of the rewrite makes that
# impossible; a refused upload is already a silent no-op on the router by design,
# and the next one comes the following night.
#
# POSIX sh. Runs as root (it drives systemctl).
set -eu

RAW="${Z2K_STATS_RAW:-/var/lib/z2k-stats/raw.jsonl}"
KEEP_DAYS="${Z2K_STATS_KEEP_DAYS:-60}"

[ -f "$RAW" ] || exit 0

CUTOFF=$(date -u -d "-${KEEP_DAYS} days" +%F)
ARCH="$(dirname "$RAW")/raw-archive-$(date -u +%Y%m).jsonl.gz"

# Restart the collector whatever happens below — including a parse failure that
# aborts the rewrite. Leaving the endpoint down until someone notices would cost
# the whole fleet its uploads.
if systemctl is-active --quiet z2k-stats-collector 2>/dev/null; then
	systemctl stop z2k-stats-collector
	# shellcheck disable=SC2064  # $RAW must expand now, not when the trap fires
	trap "systemctl start z2k-stats-collector; rm -f '$RAW.tmp'" EXIT INT TERM
else
	# shellcheck disable=SC2064
	trap "rm -f '$RAW.tmp'" EXIT INT TERM
fi

python3 - "$RAW" "$CUTOFF" "$ARCH" <<'PYEOF'
import gzip
import json
import os
import sys

raw, cutoff, arch = sys.argv[1], sys.argv[2], sys.argv[3]
tmp = raw + ".tmp"
kept = archived = dropped = 0

with open(raw, encoding="utf-8") as src, \
     open(tmp, "w", encoding="utf-8") as keep, \
     gzip.open(arch, "at", encoding="utf-8") as old:
    for line in src:
        s = line.strip()
        if not s:
            continue
        try:
            # RecursionError is a RuntimeError, not a ValueError, and a
            # deeply-nested line can raise it here. Losing one corrupt line is
            # fine; aborting the rewrite and leaving retention permanently
            # broken is not.
            d = json.loads(s).get("rx_date", "")
        except (ValueError, RecursionError, AttributeError):
            # Unparseable or not an object: keep it rather than silently
            # destroy data we do not understand. It costs a few bytes and the
            # aggregator already skips what it cannot read.
            keep.write(s + "\n")
            dropped += 1
            continue
        if d and d < cutoff:
            old.write(s + "\n")
            archived += 1
        else:
            keep.write(s + "\n")
            kept += 1

os.replace(tmp, raw)
print("kept=%d archived=%d unparsed_kept=%d" % (kept, archived, dropped))
PYEOF

chown z2kstats:z2kstats "$RAW" "$ARCH" 2>/dev/null || true
