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
    if [ -x "/opt/zapret2/nfq2/nfqws2" ] || [ -x "/opt/zapret2/mdig/mdig" ]; then
      echo "[ERROR] Не найдены все бинарники nfqws2/mdig" >&2
    else
      echo "[ERROR] Не найдены nfqws2/mdig и нет /opt/zapret2/install_bin.sh" >&2
    fi
    exit 1
  fi
fi

# If install_bin.sh failed due to missing binaries, try downloading release
if [ ! -x "/opt/zapret2/nfq2/nfqws2" ] || [ ! -x "/opt/zapret2/mdig/mdig" ]; then
  echo "[i] Пытаюсь загрузить prebuilt бинарники zapret2..." >&2
  api_url="https://api.github.com/repos/bol-van/zapret2/releases/latest"
  if command -v curl >/dev/null 2>&1; then
    release_data=$(curl -fsSL "$api_url" 2>/dev/null || true)
  else
    release_data=""
  fi

  openwrt_url=$(echo "$release_data" | grep -o 'https://github.com/bol-van/zapret2/releases/download/[^" ]*openwrt-embedded\.tar\.gz' | head -1)
  if [ -z "$openwrt_url" ]; then
    openwrt_url="https://github.com/bol-van/zapret2/releases/download/v0.8.3/zapret2-v0.8.3-openwrt-embedded.tar.gz"
  fi

  tmp_tar="/tmp/zapret2-openwrt-embedded.tar.gz"
  if curl -fsSL "$openwrt_url" -o "$tmp_tar"; then
    tar -xzf "$tmp_tar" -C /tmp || true
    # Find extracted dir
    rel_dir=$(find /tmp -maxdepth 2 -type d -name 'zapret2-*' | head -n 1)
    if [ -n "$rel_dir" ]; then
      mkdir -p /opt/zapret2/nfq2 /opt/zapret2/mdig
      [ -f "$rel_dir/nfq2/nfqws2" ] && cp "$rel_dir/nfq2/nfqws2" /opt/zapret2/nfq2/
      [ -f "$rel_dir/mdig/mdig" ] && cp "$rel_dir/mdig/mdig" /opt/zapret2/mdig/
      chmod +x /opt/zapret2/nfq2/nfqws2 /opt/zapret2/mdig/mdig 2>/dev/null || true
    fi
  fi
fi

# Final check
if [ ! -x "/opt/zapret2/nfq2/nfqws2" ] || [ ! -x "/opt/zapret2/mdig/mdig" ]; then
  echo "[ERROR] nfqws2/mdig не установлены. Установите вручную или через install_bin.sh" >&2
  exit 1
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
