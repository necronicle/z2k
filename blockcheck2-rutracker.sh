#!/bin/sh
# blockcheck2-rutracker.sh - run blockcheck2 for rutracker.org/forum/index.php and save strategies

set -e

URL="https://rutracker.org/forum/index.php"
HOST="rutracker.org"
URI="/forum/index.php"

# Allow override
if [ -n "$BLOCKCHECK2" ]; then
  BC="$BLOCKCHECK2"
else
  BC=$(command -v blockcheck2 2>/dev/null || true)
  if [ -z "$BC" ]; then
    for candidate in /opt/zapret2/blockcheck2 /opt/zapret2/nfq2/blockcheck2 /opt/bin/blockcheck2; do
      if [ -x "$candidate" ]; then
        BC="$candidate"
        break
      fi
    done
  fi
fi

if [ -z "$BC" ] || [ ! -x "$BC" ]; then
  echo "[ERROR] blockcheck2 не найден. ”кажите путь через BLOCKCHECK2=/path/to/blockcheck2" >&2
  exit 1
fi

# Detect supported flags
HELP_TEXT="$($BC --help 2>/dev/null || true)"
ARGS=""
if echo "$HELP_TEXT" | grep -q "--url"; then
  ARGS="--url=$URL"
elif echo "$HELP_TEXT" | grep -q "--uri"; then
  ARGS="--host=$HOST --uri=$URI"
else
  ARGS="--host=$HOST"
fi

OUT_FILE="rutracker_blockcheck2_$(date +%Y%m%d_%H%M%S).txt"

# Use GET for HTTPS if supported by environment
CURL_HTTPS_GET=1 "$BC" --auto $ARGS 2>&1 | tee "$OUT_FILE"

echo "[OK] –езультаты сохранены в $OUT_FILE"
