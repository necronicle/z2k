#!/bin/sh
# z2k webpanel uninstaller.
#
# Leaves no trace: stops the service, removes init.d link, binaries,
# pidfile, www content, and webpanel/ directory.

set -eu

WEBPANEL_DIR="/opt/zapret2/webpanel"
WWW_DIR="/opt/zapret2/www"
INIT_DST="/opt/etc/init.d/S96z2k-webpanel"
PIDFILE="/var/run/z2k-webpanel.pid"

echo "[1/4] Stopping panel"
if [ -x "$INIT_DST" ]; then
    "$INIT_DST" stop 2>/dev/null || true
fi
pkill -f "lighttpd.*$WEBPANEL_DIR" 2>/dev/null || true
rm -f "$PIDFILE"

echo "[2/4] Removing init.d script"
rm -f "$INIT_DST"

echo "[3/4] Removing www, webpanel dirs and log artifacts"
rm -rf "$WWW_DIR"
rm -rf "$WEBPANEL_DIR"
rm -f /tmp/z2k-webpanel-error.log \
      /tmp/z2k-webpanel-startcheck.log

echo "[4/4] Verifying"
FAIL=0
for p in "$WEBPANEL_DIR" "$WWW_DIR" "$INIT_DST" "$PIDFILE"; do
    if [ -e "$p" ]; then
        echo "  STILL PRESENT: $p" >&2
        FAIL=1
    fi
done
if pgrep -f "lighttpd.*$WEBPANEL_DIR" >/dev/null 2>&1; then
    echo "  lighttpd still running" >&2
    FAIL=1
fi

if [ "$FAIL" = "0" ]; then
    echo "z2k webpanel uninstalled cleanly."
else
    echo "Uninstall left residue; inspect above." >&2
    exit 1
fi
