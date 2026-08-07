#!/bin/sh
# z2k webpanel uninstaller.
#
# Leaves no trace: stops the service (including the respawn supervisor and
# the boot-time waiter), removes init.d script, pidfiles, www content and
# webpanel/ directory — and restores the stock lighttpd init that
# install.sh disabled.

set -eu

WEBPANEL_DIR="/opt/zapret2/webpanel"
WWW_DIR="/opt/zapret2/www"
INIT_DST="/opt/etc/init.d/S96z2k-webpanel"
PIDFILE="/var/run/z2k-webpanel.pid"
SUP_PIDFILE="/var/run/z2k-webpanel-sup.pid"
WAIT_PIDFILE="/var/run/z2k-webpanel-wait.pid"

echo "[1/5] Stopping panel"
if [ -x "$INIT_DST" ]; then
    "$INIT_DST" stop 2>/dev/null || true
fi
# Осиротевшие supervisor/waiter (init уже снесён, фон остался) — по cmdline,
# иначе выживший супервизор поднимет lighttpd после удаления файлов.
pkill -f "$INIT_DST" 2>/dev/null || true
pkill -f "lighttpd.*$WEBPANEL_DIR" 2>/dev/null || true
rm -f "$PIDFILE" "$SUP_PIDFILE" "$WAIT_PIDFILE"

echo "[2/5] Removing init.d script"
rm -f "$INIT_DST"

echo "[3/5] Restoring stock lighttpd init (if we disabled one)"
# install.sh отключает конфликтующий штатный S*lighttpd переименованием в
# .<имя>.disabled-by-z2k. «Leaves no trace» обязан вернуть его обратно —
# иначе штатный lighttpd юзера остаётся выключенным навсегда.
for _d in /opt/etc/init.d/.S*lighttpd.disabled-by-z2k; do
    [ -e "$_d" ] || continue
    _b="${_d##*/}"
    _b="${_b#.}"
    _b="${_b%.disabled-by-z2k}"
    if [ -e "${_d%/*}/$_b" ]; then
        echo "  NOT restoring $_d — ${_d%/*}/$_b already exists" >&2
    elif mv "$_d" "${_d%/*}/$_b" 2>/dev/null; then
        echo "  restored ${_d%/*}/$_b"
    else
        echo "  could not restore $_d — move it back manually" >&2
    fi
done

echo "[4/5] Removing www, webpanel dirs and log artifacts"
# .new/.old — staging/backup атомарной установки, могли остаться от
# оборванного запуска install.sh.
rm -rf "$WWW_DIR" "$WEBPANEL_DIR" \
       "$WWW_DIR.new" "$WEBPANEL_DIR.new" \
       "$WWW_DIR.old" "$WEBPANEL_DIR.old"
rm -f /tmp/z2k-log/z2k-webpanel-error.log \
      /tmp/z2k-log/z2k-webpanel-startcheck.log \
      /tmp/z2k-log/z2k-webpanel-wait.log \
      /tmp/z2k-log/z2k-webpanel-sup.log

echo "[5/5] Verifying"
FAIL=0
for p in "$WEBPANEL_DIR" "$WWW_DIR" "$INIT_DST" \
         "$PIDFILE" "$SUP_PIDFILE" "$WAIT_PIDFILE"; do
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
