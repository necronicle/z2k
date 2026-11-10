#!/bin/sh
# C-стенд использует исходники соседнего форка, не меняя и не собирая его целиком.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
FORK=${Z2K_FORK_DIR:-"$ROOT/../zapret2-z2k-fork"}
SRC="$FORK/nfq2"
[ -f "$SRC/ipset.c" ] || { echo 'Нет исходников форка: задайте Z2K_FORK_DIR' >&2; exit 1; }
command -v pkg-config >/dev/null 2>&1 || { echo 'Для C-стенда нужен pkg-config (Ubuntu: pkg-config)' >&2; exit 1; }
if ! lua_cflags=$(pkg-config --cflags luajit); then
    echo 'pkg-config не нашёл luajit: установите заголовки LuaJIT (Ubuntu: libluajit-5.1-dev) или настройте PKG_CONFIG_PATH' >&2
    exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
# macOS: dead_strip; Linux: gc-sections. Невызываемые части движка не линкуем.
case $(uname -s) in Darwin) gc=-Wl,-dead_strip; compat="-Dst_mtim=st_mtimespec -include sys/random.h" ;; *) gc=-Wl,--gc-sections; compat= ;; esac
${CC:-cc} -O1 -g -ffunction-sections -fdata-sections $gc $compat -include unistd.h \
    $lua_cflags -I"$SRC" \
    "$ROOT/tests/gvsub_ipset_filter.c" "$SRC/ipset.c" "$SRC/pools.c" \
    "$SRC/filter.c" "$SRC/hostlist.c" "$SRC/protocol.c" "$SRC/helpers.c" "$SRC/gzip.c" -lz -o "$TMP/filter"
# Заглушки берём из исполняемой функции init, а не из копии в тесте.
awk '$0 == "z2k_gvsub_ip_sentinels()" {p=1} p{print} p&&/^}/{exit}' \
    "$ROOT/files/S99zapret2.new" > "$TMP/sentinels.sh"
. "$TMP/sentinels.sh"
z2k_gvsub_ip_sentinels > "$TMP/ips"
"$TMP/filter" "$TMP/ips"
