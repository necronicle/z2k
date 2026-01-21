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
    for candidate in \
      /opt/zapret2/nfq2/blockcheck2 \
      /opt/zapret2/nfq2/blockcheck2.sh \
      /opt/zapret2/blockcheck2 \
      /opt/zapret2/blockcheck2.sh \
      /opt/bin/blockcheck2 \
      /opt/bin/blockcheck2.sh; do
      if [ -x "$candidate" ]; then
        BC="$candidate"
        break
      fi
    done
  fi
fi

# Try to locate with find as a last resort
if [ -z "$BC" ]; then
  FOUND=$(find /opt -maxdepth 4 -type f -name 'blockcheck2*' -perm /111 2>/dev/null | head -n 1)
  if [ -n "$FOUND" ]; then
    BC="$FOUND"
  fi
fi

if [ -z "$BC" ] || [ ! -x "$BC" ]; then
  echo "[ERROR] blockcheck2 не найден. Укажите путь через BLOCKCHECK2=/path/to/blockcheck2" >&2
  exit 1
fi

# Ensure required binaries are present
if [ ! -x "/opt/zapret2/nfq2/nfqws2" ] || [ ! -x "/opt/zapret2/mdig/mdig" ]; then
  if [ -x "/opt/zapret2/install_bin.sh" ]; then
    echo "[i] Отсутствуют бинарники nfqws2/mdig. Запускаю /opt/zapret2/install_bin.sh" >&2
    /opt/zapret2/install_bin.sh || {
      echo "[ERROR] install_bin.sh завершился с ошибкой" >&2
      exit 1
    }
  else
    echo "[ERROR] Не найдены nfqws2/mdig и нет /opt/zapret2/install_bin.sh" >&2
    exit 1
  fi
fi

# Detect supported flags (prefer --uri for rutracker)
HELP_TEXT="$($BC --help 2>/dev/null || true)"
ARGS=""
if echo "$HELP_TEXT" | grep -q -- "--uri"; then
  ARGS="--host=$HOST --uri=$URI"
elif echo "$HELP_TEXT" | grep -q -- "--url"; then
  ARGS="--url=$URL"
else
  ARGS="--host=$HOST"
fi

OUT_FILE="rutracker_blockcheck2_$(date +%Y%m%d_%H%M%S).txt"

# Use GET for HTTPS if supported by environment
CURL_HTTPS_GET=1 "$BC" --auto $ARGS 2>&1 | tee "$OUT_FILE"

echo "[OK] Результаты сохранены в $OUT_FILE"
