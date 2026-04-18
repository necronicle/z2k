#!/bin/sh
# z2k webpanel installer (lighttpd-based, LAN-only, no auth).
#
# Usage:
#   sh webpanel/install.sh [--port N] [--bind IP]
#
# Defaults: port 8088, bind 0.0.0.0. Idempotent — stops the panel,
# overwrites files, regenerates config, restarts.

set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBPANEL_DIR="/opt/zapret2/webpanel"
WWW_DIR="/opt/zapret2/www"
INIT_DST="/opt/etc/init.d/S96z2k-webpanel"
CONF_DST="$WEBPANEL_DIR/lighttpd.conf"

# Pick the real LAN IP. Two-pass scan: first try bridge interfaces (br*)
# only — they're the LAN side on Keenetic/OpenWRT — then fall back to any
# interface. Within each pass: 192.168.* (practically never used for ISP
# interconnect) → 172.16-31.* → 10.* (most common CGNAT / Rostelecom).
# Falls back to the source IP of the default route, then to empty.
#
# Эд 2026-04-18: router with eth2.2 (192.168.0.4, WAN-side to upstream)
# and br0 (192.168.3.1, real LAN). Old single-pass logic took the first
# 192.168.* match — eth2.2 — and bound the panel to the WAN interface.
detect_lan_ip() {
    local _ip=""
    local _pat
    local _ifprefix
    for _ifprefix in 'br' ''; do
        for _pat in \
            '192\.168\.' \
            '172\.(1[6-9]|2[0-9]|3[01])\.' \
            '10\.' ; do
            _ip=$(ip -4 addr show 2>/dev/null \
                | awk -v p="$_pat" -v ifp="$_ifprefix" '
                    /^[0-9]+: / {
                        match($2, /^[^:@]+/)
                        iface = substr($2, RSTART, RLENGTH)
                        ok = (ifp == "" || index(iface, ifp) == 1)
                        next
                    }
                    ok && $0 ~ ("inet " p) {
                        split($2, a, "/")
                        print a[1]
                        exit
                    }
                ')
            [ -n "$_ip" ] && { printf '%s' "$_ip"; return 0; }
        done
    done
    _ip=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    printf '%s' "$_ip"
}

PORT=8088
# Default BIND is the detected LAN IP, NOT 0.0.0.0. On Rostelecom routers
# 0.0.0.0 accidentally exposed the panel on the 10.4.x.x provider-side
# interconnect interface (Владислав 2026-04-15). Use --bind 0.0.0.0
# explicitly if you actually want multi-interface listening.
BIND="$(detect_lan_ip)"
[ -z "$BIND" ] && BIND="0.0.0.0"

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --bind) BIND="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
z2k webpanel installer (lighttpd-based, LAN-only)
Usage: install.sh [--port N] [--bind IP]
Defaults: port 8088, bind 0.0.0.0
EOF
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# On Keenetic the rootfs is a read-only squashfs. If opkg runs without
# TMPDIR pointing at a writable dir (e.g. when invoked with cwd=/), it
# tries to create its temp dir in / and falls over with
#   "opkg_conf_load: Creating temp dir /opkg-XXXX failed: Read-only file system"
# Alexey's Keenetic Viva KN-1912 hit this on 2026-04-16. /opt is always
# writable on Entware-based installs, so pin TMPDIR there for the whole
# install script.
export TMPDIR=/opt/tmp
mkdir -p /opt/tmp 2>/dev/null || true

# Run opkg and propagate the REAL exit code. Previous version piped into
# `tail -3` which swallowed opkg's exit status (the pipeline ended in
# tail, always 0), so a failed opkg install looked like success and the
# script happily continued to lighttpd startup which then died on a
# missing module. Also surface the "Read-only file system" error with a
# concrete hint, because that specific failure mode is the one users
# hit and can't decode.
run_opkg() {
    local log=/tmp/z2k-webpanel-opkg.log
    if opkg "$@" >"$log" 2>&1; then
        tail -3 "$log"
        return 0
    fi
    echo "  opkg $1 failed. Last lines:"
    tail -10 "$log" | sed 's/^/    /'
    if grep -q 'Read-only file system' "$log"; then
        cat <<'HINT' >&2

  HINT: opkg cannot create its temp dir because the filesystem is
  read-only. Our script already exports TMPDIR=/opt/tmp, which is the
  Entware writable mount — if you still see this error, /opt/tmp is
  likely broken. Check:
      mount | grep '/opt'
      ls -ld /opt/tmp
      df -h /opt
  If /opt is full or the mount is gone, fix that first and retry.
HINT
    fi
    return 1
}

echo "[1/6] Checking dependencies"
LIGHTTPD_BIN=""
# Prefer Entware lighttpd ONLY. We cannot use the Keenetic stock lighttpd
# at /usr/sbin/lighttpd because (a) its mod_cgi lives at
# /usr/lib/lighttpd/ and opkg will not manage it, (b) Keenetic system
# paths are read-only, and (c) the stock lighttpd is already used by the
# Keenetic admin UI. We install our own Entware instance.
for c in /opt/sbin/lighttpd /opt/bin/lighttpd; do
    if [ -x "$c" ]; then
        LIGHTTPD_BIN="$c"
        break
    fi
done

# Auto-install Entware lighttpd + mod_cgi if missing.
if [ -z "$LIGHTTPD_BIN" ]; then
    echo "  Entware lighttpd not found — installing via opkg..."
    run_opkg install lighttpd lighttpd-mod-cgi || {
        echo "  install manually: opkg install lighttpd lighttpd-mod-cgi" >&2
        exit 1
    }
    for c in /opt/sbin/lighttpd /opt/bin/lighttpd; do
        if [ -x "$c" ]; then
            LIGHTTPD_BIN="$c"
            break
        fi
    done
    [ -z "$LIGHTTPD_BIN" ] && { echo "  lighttpd still not found after opkg install" >&2; exit 1; }
fi
echo "  lighttpd: $LIGHTTPD_BIN"

# Verify mod_cgi module is physically present; auto-install if not.
# Search all Entware-standard lighttpd module locations.
MOD_CGI_PATHS="/opt/lib/lighttpd /opt/usr/lib/lighttpd /opt/libexec/lighttpd"
if ! find $MOD_CGI_PATHS -maxdepth 1 -name 'mod_cgi*' 2>/dev/null | head -1 | grep -q .; then
    echo "  mod_cgi missing — installing..."
    run_opkg install lighttpd-mod-cgi || {
        echo "  mod_cgi install failed" >&2
        exit 1
    }
    # Re-check after install so a silent opkg success with no files
    # still fails loudly here instead of in the lighttpd dlopen step.
    if ! find $MOD_CGI_PATHS -maxdepth 1 -name 'mod_cgi*' 2>/dev/null | head -1 | grep -q .; then
        echo "  mod_cgi still not installed after opkg install — aborting" >&2
        exit 1
    fi
fi

echo "[2/6] Stopping existing panel (if any)"
if [ -x "$INIT_DST" ]; then
    "$INIT_DST" stop 2>/dev/null || true
fi
pkill -f "lighttpd.*$WEBPANEL_DIR" 2>/dev/null || true
# Also stop any leftover busybox httpd bound to the same www dir from an
# earlier (pre-lighttpd) install.
pkill -f "httpd.*$WWW_DIR" 2>/dev/null || true

echo "[3/6] Installing files"
# Nuke any pre-existing panel tree to guarantee idempotency. Stale files
# from a previous install (including the old z2k-webpanel-install.sh
# monolith) must not leak through. /opt/zapret2/www is ours exclusively.
rm -rf "$WWW_DIR" "$WEBPANEL_DIR"
rm -f /opt/zapret2/z2k-webpanel-install.sh \
      /opt/zapret2/z2k-httpd.sh \
      2>/dev/null || true

mkdir -p "$WEBPANEL_DIR/cgi" "$WWW_DIR/cgi-bin" /opt/etc/init.d

cp -f "$SRC_DIR/cgi/auth.sh"    "$WEBPANEL_DIR/cgi/auth.sh"
cp -f "$SRC_DIR/cgi/actions.sh" "$WEBPANEL_DIR/cgi/actions.sh"
cp -f "$SRC_DIR/cgi/api.sh"     "$WEBPANEL_DIR/cgi/api.sh"
chmod 755 "$WEBPANEL_DIR/cgi/"*.sh

ln -sf "$WEBPANEL_DIR/cgi/api.sh" "$WWW_DIR/cgi-bin/api"

cp -f "$SRC_DIR/www/index.html"  "$WWW_DIR/index.html"
cp -f "$SRC_DIR/www/app.js"      "$WWW_DIR/app.js"
cp -f "$SRC_DIR/www/style.css"   "$WWW_DIR/style.css"
cp -f "$SRC_DIR/www/favicon.svg" "$WWW_DIR/favicon.svg"
chmod 644 "$WWW_DIR/index.html" "$WWW_DIR/app.js" "$WWW_DIR/style.css" "$WWW_DIR/favicon.svg"

echo "[4/6] Writing lighttpd config"
sed \
    -e "s|@WWW_DIR@|${WWW_DIR}|g" \
    -e "s|@PORT@|${PORT}|g" \
    -e "s|@BIND@|${BIND}|g" \
    "$SRC_DIR/lighttpd.conf" > "$CONF_DST"

printf '%s' "$PORT" > "$WEBPANEL_DIR/port"
printf '%s' "$BIND" > "$WEBPANEL_DIR/bind"

echo "[5/6] Installing init.d script"
cp -f "$SRC_DIR/init.d/S96z2k-webpanel" "$INIT_DST"
chmod 755 "$INIT_DST"

echo "[6/6] Starting webpanel"
"$INIT_DST" start || {
    echo "Start failed. Check /tmp/z2k-webpanel-error.log and /tmp/z2k-webpanel-startcheck.log" >&2
    exit 1
}

# If the user forced --bind to something other than 0.0.0.0 we print
# that as the URL. Otherwise fall back to the detect_lan_ip helper.
if [ "$BIND" = "0.0.0.0" ]; then
    IP=$(detect_lan_ip)
    [ -z "$IP" ] && IP="<router-ip>"
else
    IP="$BIND"
fi

cat <<EOF

===========================================================
z2k webpanel installed
-----------------------------------------------------------
URL:     http://$IP:$PORT/
Access:  LAN-only, no authentication
-----------------------------------------------------------
Control: $INIT_DST {start|stop|restart|status}
Config:  $CONF_DST
===========================================================
EOF
