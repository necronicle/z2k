#!/bin/sh
# blockcheck2-rutracker.sh - run blockcheck2 for rutracker.org/forum/index.php and save strategies

set -e

URL="https://rutracker.org/forum/index.php"
HOST="rutracker.org"
URI="/forum/index.php"

is_elf() {
  local f="$1"
  [ -f "$f" ] || return 1
  # Check ELF magic
  local magic
  magic=$(dd if="$f" bs=1 count=4 2>/dev/null | od -An -t x1 | tr -d ' \n')
  [ "$magic" = "7f454c46" ]
}

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
  echo "[ERROR] blockcheck2 �� ������. ������� ���� ����� BLOCKCHECK2=/path/to/blockcheck2" >&2
  exit 1
fi

# Ensure required binaries are present
if ! is_elf "/opt/zapret2/nfq2/nfqws2" || ! is_elf "/opt/zapret2/mdig/mdig"; then
  if [ -x "/opt/zapret2/install_bin.sh" ]; then
    echo "[i] ����������� ��������� nfqws2/mdig. �������� /opt/zapret2/install_bin.sh" >&2
    if ! /opt/zapret2/install_bin.sh; then
      echo "[WARN] install_bin.sh ���������� � �������, �������� ������� �����" >&2
    fi
  else
    echo "[WARN] ��� /opt/zapret2/install_bin.sh, �������� ������� �����" >&2
  fi
fi

# If binaries still missing, download zapret2 source release and run install_bin.sh
if ! is_elf "/opt/zapret2/nfq2/nfqws2" || ! is_elf "/opt/zapret2/mdig/mdig"; then
  echo "[i] ������� ��������� ��������� zapret2 � binaries..." >&2
  api_url="https://api.github.com/repos/bol-van/zapret2/releases/latest"
  release_data=""
  if command -v curl >/dev/null 2>&1; then
    release_data=$(curl -fsSL "$api_url" 2>/dev/null || true)
  fi

  tarball_url=$(echo "$release_data" | grep -o '"tarball_url"[^"]*"[^"]*"' | head -n 1 | cut -d'"' -f4)
  if [ -z "$tarball_url" ]; then
    tarball_url="https://api.github.com/repos/bol-van/zapret2/tarball/master"
  fi

  tmp_tar="/tmp/zapret2-src.tar.gz"
  if curl -fsSL "$tarball_url" -o "$tmp_tar"; then
    tmp_dir="/tmp/zapret2-src-$$"
    mkdir -p "$tmp_dir"
    tar -xzf "$tmp_tar" -C "$tmp_dir" || true
    src_root=$(find "$tmp_dir" -maxdepth 1 -type d -name 'bol-van-zapret2-*' | head -n 1)
    if [ -n "$src_root" ] && [ -d "$src_root/binaries" ]; then
      mkdir -p /opt/zapret2/binaries
      cp -r "$src_root/binaries/." /opt/zapret2/binaries/ 2>/dev/null || true
    fi
  fi

  if [ -x "/opt/zapret2/install_bin.sh" ]; then
    /opt/zapret2/install_bin.sh || true
  fi
fi

# Final check
if ! is_elf "/opt/zapret2/nfq2/nfqws2" || ! is_elf "/opt/zapret2/mdig/mdig"; then
  echo "[ERROR] nfqws2/mdig �� ����������� ���������. ���������� ������� ��� ����� install_bin.sh" >&2
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

echo "[OK] ���������� ��������� � $OUT_FILE"
