#!/bin/sh
# z2k-webpanel-install.sh — Installer for z2k web monitoring panel
# Sets up busybox httpd to serve the CGI panel on Keenetic routers
#
# Usage: sh z2k-webpanel-install.sh [--port PORT]

set -e

ZAPRET_BASE="/opt/zapret2"
WWW_DIR="${ZAPRET_BASE}/www"
CGI_DIR="${WWW_DIR}/cgi-bin"
HTTPD_CONF="${WWW_DIR}/httpd.conf"
PANEL_SCRIPT="z2k-webpanel.sh"
DEFAULT_PORT=8080

# Parse arguments
PORT="$DEFAULT_PORT"
case "${1:-}" in
    --port)
        PORT="${2:-$DEFAULT_PORT}"
        # Validate port is numeric
        case "$PORT" in
            *[!0-9]*) echo "Error: port must be numeric"; exit 1 ;;
        esac
        ;;
    --help|-h)
        echo "Usage: $0 [--port PORT]"
        echo ""
        echo "Installs z2k web panel for busybox httpd."
        echo "Default port: $DEFAULT_PORT"
        exit 0
        ;;
esac

echo "=== z2k Web Panel Installer ==="
echo ""

# 0. Ensure a web server is available
if ! command -v lighttpd >/dev/null 2>&1 && ! command -v httpd >/dev/null 2>&1 && ! command -v uhttpd >/dev/null 2>&1; then
    echo "[0/5] Веб-сервер не найден, устанавливаю..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        if opkg install lighttpd lighttpd-mod-cgi 2>/dev/null; then
            echo "  Установлен: lighttpd + CGI"
        elif opkg install busybox-httpd 2>/dev/null; then
            echo "  Установлен: busybox-httpd"
        elif opkg install uhttpd 2>/dev/null; then
            echo "  Установлен: uhttpd"
        elif opkg install uhttpd_kn 2>/dev/null; then
            echo "  Установлен: uhttpd_kn (Keenetic)"
        else
            echo "  ВНИМАНИЕ: не удалось установить веб-сервер"
            echo "  Установите вручную: opkg install lighttpd lighttpd-mod-cgi"
        fi
    else
        echo "  ВНИМАНИЕ: opkg не найден"
    fi
fi

# 1. Create directories
echo "[1/5] Creating directories..."
mkdir -p "$CGI_DIR"
echo "  Created: $WWW_DIR"
echo "  Created: $CGI_DIR"

# 2. Determine source script location (same dir as this installer or /opt/zapret2/files/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_SCRIPT=""
for candidate in \
    "${SCRIPT_DIR}/${PANEL_SCRIPT}" \
    "${ZAPRET_BASE}/${PANEL_SCRIPT}" \
    "${ZAPRET_BASE}/files/${PANEL_SCRIPT}" \
    "${ZAPRET_BASE}/www/cgi-bin/index.cgi" \
    "/tmp/z2k/files/${PANEL_SCRIPT}" \
    "/tmp/${PANEL_SCRIPT}" \
; do
    if [ -f "$candidate" ]; then
        SOURCE_SCRIPT="$candidate"
        break
    fi
done

# 3. Copy CGI script
echo "[2/5] Installing CGI script..."
if [ -n "$SOURCE_SCRIPT" ]; then
    cp -f "$SOURCE_SCRIPT" "${CGI_DIR}/${PANEL_SCRIPT}"
    echo "  Copied from: $SOURCE_SCRIPT"
else
    echo "  Warning: ${PANEL_SCRIPT} not found in expected locations."
    echo "  Please manually copy it to: ${CGI_DIR}/${PANEL_SCRIPT}"
fi
chmod 755 "${CGI_DIR}/${PANEL_SCRIPT}" 2>/dev/null || true

# 4. Create index redirect
echo "[3/5] Creating index page..."
cat > "${WWW_DIR}/index.html" <<'INDEXEOF'
<!DOCTYPE html>
<html><head>
<meta http-equiv="refresh" content="0;url=/cgi-bin/z2k-webpanel.sh">
</head><body>
<p>Redirecting to <a href="/cgi-bin/z2k-webpanel.sh">z2k panel</a>...</p>
</body></html>
INDEXEOF
echo "  Created: ${WWW_DIR}/index.html"

# 5. Create busybox httpd config
echo "[4/5] Creating httpd config..."
cat > "$HTTPD_CONF" <<'CONFEOF'
# z2k-webpanel httpd.conf for busybox httpd
# CGI directory
*.sh:/bin/sh

# Deny access to dotfiles and sensitive paths
D:.*
D:.rollback

# MIME types
.html:text/html
.css:text/css
.js:application/javascript
.png:image/png
.ico:image/x-icon
CONFEOF
echo "  Created: $HTTPD_CONF"

# 6. Summary
echo "[5/5] Done!"
echo ""
echo "============================================"
echo " z2k Web Panel installed successfully"
echo "============================================"
echo ""
echo "  Web root:   $WWW_DIR"
echo "  CGI script: ${CGI_DIR}/${PANEL_SCRIPT}"
echo "  Config:     $HTTPD_CONF"
echo ""
echo "Start the web server with:"
echo ""
echo "  busybox httpd -p ${PORT} -h ${WWW_DIR} -c ${HTTPD_CONF}"
echo ""
echo "Then open in browser:"
echo ""
echo "  http://<router-ip>:${PORT}/"
echo ""
echo "To stop:"
echo ""
echo "  kill \$(cat /var/run/z2k-httpd.pid 2>/dev/null)"
echo ""
echo "To auto-start on boot, add to /opt/etc/ndm/fs.d/ or crontab:"
echo ""
echo "  @reboot busybox httpd -p ${PORT} -h ${WWW_DIR} -c ${HTTPD_CONF}"
echo ""

# Create a convenience start/stop script
cat > "${WWW_DIR}/z2k-httpd.sh" <<CTLEOF
#!/bin/sh
# z2k-httpd.sh — Start/stop the z2k web panel httpd
PIDFILE="/var/run/z2k-httpd.pid"
case "\${1:-start}" in
    start)
        if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
            echo "httpd already running (PID \$(cat "\$PIDFILE"))"
        else
            busybox httpd -p ${PORT} -h ${WWW_DIR} -c ${HTTPD_CONF}
            # busybox httpd forks to background; find its PID
            sleep 1
            PID=\$(ps w 2>/dev/null | grep "[h]ttpd.*${WWW_DIR}" | awk '{print \$1}' | head -1)
            if [ -n "\$PID" ]; then
                echo "\$PID" > "\$PIDFILE"
                echo "httpd started on port ${PORT} (PID \$PID)"
            else
                echo "httpd started on port ${PORT}"
            fi
        fi
        ;;
    stop)
        if [ -f "\$PIDFILE" ]; then
            kill "\$(cat "\$PIDFILE")" 2>/dev/null && echo "httpd stopped" || echo "httpd not running"
            rm -f "\$PIDFILE"
        else
            echo "No PID file found; trying to kill httpd..."
            killall busybox_httpd 2>/dev/null || pkill -f "httpd.*${WWW_DIR}" 2>/dev/null || echo "Not running"
        fi
        ;;
    restart)
        "\$0" stop
        sleep 1
        "\$0" start
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart}"
        ;;
esac
CTLEOF
chmod 755 "${WWW_DIR}/z2k-httpd.sh"
echo "Convenience script created: ${WWW_DIR}/z2k-httpd.sh {start|stop|restart}"
