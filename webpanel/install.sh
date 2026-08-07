#!/bin/sh
# z2k webpanel installer (lighttpd-based, LAN-only, no auth).
#
# Usage:
#   sh webpanel/install.sh [--port N] [--bind IP]
#
# Defaults: port 8088, bind = detected LAN IP. При переустановке без
# аргументов сохранённые port (и явно заданный ранее bind) переживают её.
# Idempotent — stops the panel, overwrites files, regenerates config,
# restarts. Замена файлов атомарная: staging-каталог + swap, обрыв в любой
# точке не оставляет роутер без ранее работавшей панели.

set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBPANEL_DIR="/opt/zapret2/webpanel"
WWW_DIR="/opt/zapret2/www"
INIT_DST="/opt/etc/init.d/S96z2k-webpanel"
CONF_DST="$WEBPANEL_DIR/lighttpd.conf"
# Staging/backup-каталоги атомарной замены (шаг [6/7]).
STAGE_WP="${WEBPANEL_DIR}.new"
STAGE_WWW="${WWW_DIR}.new"
OLD_WP="${WEBPANEL_DIR}.old"
OLD_WWW="${WWW_DIR}.old"

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

# Адрес реально назначен какому-то интерфейсу?
_ip_present() {
    ip -4 addr show 2>/dev/null | grep -q "inet $1[/ ]"
}

# Prefer Entware lighttpd ONLY. We cannot use the Keenetic stock lighttpd
# at /usr/sbin/lighttpd because (a) its mod_cgi lives at
# /usr/lib/lighttpd/ and opkg will not manage it, (b) Keenetic system
# paths are read-only, and (c) the stock lighttpd is already used by the
# Keenetic admin UI. We install our own Entware instance.
#
# lighttpd может быть уже установлен в SECONDARY opkg dest (USB-том):
# тогда `opkg install lighttpd` возвращает 0 («already installed»), а в
# /opt/{sbin,bin} бинаря нет — и установка падала с «still not found».
# Ищем по всем `dest` из opkg.conf; init-скрипт делает тот же поиск.
find_lighttpd() {
    local c kw dn dp rest
    for c in /opt/sbin/lighttpd /opt/bin/lighttpd; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    if [ -r /opt/etc/opkg.conf ]; then
        while read -r kw dn dp rest; do
            [ "$kw" = dest ] || continue
            case "$dp" in /*) ;; *) continue ;; esac
            for c in "${dp%/}/opt/sbin/lighttpd" "${dp%/}/opt/bin/lighttpd"; do
                [ -x "$c" ] && { printf '%s' "$c"; return 0; }
            done
        done < /opt/etc/opkg.conf
    fi
    return 1
}

# Пустые значения = «не задано аргументом». Итоговые дефолты — ниже, после
# разбора аргументов: при переустановке приоритет такой:
#   аргумент командной строки > сохранённые port/bind прошлой установки >
#   автодетект / 8088.
PORT=""
BIND=""
BIND_EXPLICIT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --bind) BIND="$2"; BIND_EXPLICIT=1; shift 2 ;;
        -h|--help)
            cat <<EOF
z2k webpanel installer (lighttpd-based, LAN-only)
Usage: install.sh [--port N] [--bind IP]
Defaults: port 8088 (or previously installed port), bind = detected LAN IP
EOF
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Переустановка (меню [P]→[1] зовёт установщик без аргументов) не должна
# молча сбрасывать кастомный порт: раньше $WEBPANEL_DIR/port уничтожался
# rm -rf до того, как его кто-либо прочитал, и панель юзера, ставившего
# --port 9090 из-за занятого 8088, после «Переустановить» лезла на 8088 →
# bind-fail. Сохранённые значения читаем ДО любого разрушения.
if [ -z "$PORT" ] && [ -s "$WEBPANEL_DIR/port" ]; then
    PORT=$(tr -dc '0-9' < "$WEBPANEL_DIR/port")
    [ -n "$PORT" ] && echo "reusing saved port $PORT (pass --port to override)"
fi
[ -n "$PORT" ] || PORT=8088

# Default BIND is the detected LAN IP, NOT 0.0.0.0. On Rostelecom routers
# 0.0.0.0 accidentally exposed the panel on the 10.4.x.x provider-side
# interconnect interface (Владислав 2026-04-15). Use --bind 0.0.0.0
# explicitly if you actually want multi-interface listening.
#
# Сохранённый bind переиспользуем ТОЛЬКО при маркере bind.explicit (юзер
# сам передавал --bind). Автодетектный bind всегда детектим заново: r-56.3
# успел записать в bind неверный LAN-сегмент, и его повтор держал бы панель
# на недостижимом адресе — по той же причине auto-update передаёт сюда
# только --port.
if [ -z "$BIND" ] && [ -f "$WEBPANEL_DIR/bind.explicit" ] && [ -s "$WEBPANEL_DIR/bind" ]; then
    SAVED_BIND=$(tr -d ' \t\r\n' < "$WEBPANEL_DIR/bind")
    if [ "$SAVED_BIND" = "0.0.0.0" ] || _ip_present "$SAVED_BIND"; then
        BIND="$SAVED_BIND"
        BIND_EXPLICIT=1
        echo "reusing saved bind $BIND (pass --bind to override)"
    elif [ -n "$SAVED_BIND" ]; then
        echo "saved bind $SAVED_BIND is not assigned to any interface — falling back to auto-detect"
    fi
fi
if [ -z "$BIND" ]; then
    BIND="$(detect_lan_ip)"
    [ -z "$BIND" ] && BIND="0.0.0.0"
fi

# Любой обрыв ниже (set -eu) не должен оставить роутер без панели: до
# swap'а достаточно убрать staging-каталоги, после начатого swap'а —
# вернуть сохранённые каталоги на место и поднять прежнюю панель (её к
# этому моменту могли остановить на шаге [3/7]).
webpanel_rollback() {
    _rc=$?
    [ "$_rc" -eq 0 ] && return 0
    _restored=0
    if [ ! -d "$WEBPANEL_DIR" ] && [ -d "$OLD_WP" ]; then
        mv "$OLD_WP" "$WEBPANEL_DIR" 2>/dev/null || true
        _restored=1
    fi
    if [ ! -d "$WWW_DIR" ] && [ -d "$OLD_WWW" ]; then
        mv "$OLD_WWW" "$WWW_DIR" 2>/dev/null || true
        _restored=1
    fi
    rm -rf "$STAGE_WP" "$STAGE_WWW" 2>/dev/null || true
    # Панель могла быть остановлена на [3/7] и без начатого swap'а — поднимаем
    # обратно в любом случае; лишний start безвреден («already running»).
    if [ -d "$WEBPANEL_DIR" ] && [ -x "$INIT_DST" ]; then
        "$INIT_DST" start >/dev/null 2>&1 || true
    fi
    if [ "$_restored" = 1 ]; then
        echo "webpanel install failed (rc=$_rc) — previous panel restored" >&2
    else
        echo "webpanel install failed (rc=$_rc) — see errors above" >&2
    fi
    return 0
}
trap webpanel_rollback EXIT

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
# Stale package list: opkg builds the .ipk URL from /opt/var/opkg-lists,
# and Entware keeps only the CURRENT version of each package in the feed
# root. A router that hasn't run `opkg update` in months asks for e.g.
# lighttpd_1.4.79-1 while the feed has 1.4.82-2 -> plain 404, surfaced as
# "wget returned 1 / Perhaps you need to run 'opkg update'". Refresh the
# list once and retry the same command instead of dead-ending the install.
opkg_list_refreshed=0
refresh_opkg_lists() {
    [ "$opkg_list_refreshed" = 1 ] && return 1
    opkg_list_refreshed=1
    echo "  package list looks stale — running opkg update..."
    local ulog=/tmp/z2k-webpanel-opkg-update.log
    opkg update >"$ulog" 2>&1 && return 0

    # entware.diversion.ch redirects 301 http->https on every file. opkg
    # shells out to wget, and on Keenetic that is usually busybox wget with
    # no SSL: it follows the redirect and dies with "not an http or ftp
    # url" -> wget returned 1. Such a router can never use that mirror.
    # bin.entware.net serves plain HTTP 200 with no redirect, so put the
    # feed back there. (Our own installer used to make this swap when
    # `opkg update` hit "Illegal instruction" — this undoes it when the
    # mirror turns out to be unusable.)
    if grep -q 'not an http or ftp url' "$ulog" &&
       grep -q 'entware\.diversion\.ch' /opt/etc/opkg.conf 2>/dev/null; then
        echo "  mirror entware.diversion.ch needs https, this wget cannot —"
        echo "  switching feed back to http://bin.entware.net"
        cp /opt/etc/opkg.conf /opt/etc/opkg.conf.z2k-bak 2>/dev/null || true
        sed -i 's|https\{0,1\}://entware\.diversion\.ch|http://bin.entware.net|g' /opt/etc/opkg.conf
        # VERIFY the rewrite. `sed -i` can no-op silently — a read-only /opt, an
        # unexpected spelling of the mirror, or a sed that wants a suffix for -i all
        # leave the file untouched while every command here still "succeeds". Without
        # this check the function went on to run a second pointless `opkg update`
        # against the same dead mirror and reported nothing useful.
        if grep -q 'entware\.diversion\.ch' /opt/etc/opkg.conf 2>/dev/null; then
            echo "  could not rewrite /opt/etc/opkg.conf — fix it by hand:"
            echo "    sed -i 's|entware.diversion.ch|bin.entware.net|g' /opt/etc/opkg.conf && opkg update"
            return 0
        fi
        opkg update >"$ulog" 2>&1 && return 0
    fi
    tail -6 "$ulog" | sed 's/^/    /'
    return 0
}

run_opkg() {
    local log=/tmp/z2k-webpanel-opkg.log
    if opkg "$@" >"$log" 2>&1; then
        tail -3 "$log"
        return 0
    fi
    # Every way an unusable package list surfaces, not just the one the first report
    # showed. A STALE list gives "Failed to download / wget returned 1" (opkg builds a
    # URL for a version the feed no longer carries). An EMPTY one — the state after a
    # failed `opkg update`, reproduced on the owner's router — gives "Unknown package"
    # / "Cannot install package" instead, and the narrower match missed it entirely:
    # the E2E run went rc=255 with no refresh attempted. Same root cause, so same
    # recovery. A false positive costs at most ONE extra `opkg update` per install,
    # because refresh_opkg_lists refuses its second call.
    if grep -qiE "Failed to download|need to run 'opkg update'|Unknown package|Cannot install package|Cannot find package" "$log" \
       && refresh_opkg_lists; then
        if opkg "$@" >"$log" 2>&1; then
            tail -3 "$log"
            return 0
        fi
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

echo "[1/7] Verifying source files"
# Раньше rm -rf установленной панели выполнялся ДО какой-либо проверки
# исходников. z2k.sh создаёт /tmp/z2k/webpanel даже при полностью
# провальном фетче (webpanel — «опциональный компонент», ошибки = warning),
# и обрыв на первом cp уничтожал рабочую панель без отката. Разрушающие
# действия — только после проверки, что ставить есть из чего. favicon.svg
# намеренно не в списке: он опционален (guard на шаге копирования).
MISSING=""
for _f in cgi/auth.sh cgi/actions.sh cgi/api.sh \
          www/index.html www/app.js www/style.css \
          lighttpd.conf init.d/S96z2k-webpanel; do
    [ -s "$SRC_DIR/$_f" ] || MISSING="$MISSING $_f"
done
if [ -n "$MISSING" ]; then
    echo "  source files missing or empty:$MISSING" >&2
    echo "  refusing to touch the installed panel — re-download z2k and retry" >&2
    exit 1
fi
echo "  all required sources present"

echo "[2/7] Checking dependencies"
LIGHTTPD_BIN=$(find_lighttpd) || LIGHTTPD_BIN=""

# Auto-install Entware lighttpd + mod_cgi if missing.
if [ -z "$LIGHTTPD_BIN" ]; then
    echo "  Entware lighttpd not found — installing via opkg..."
    run_opkg install lighttpd lighttpd-mod-cgi || {
        echo "  install manually: opkg install lighttpd lighttpd-mod-cgi" >&2
        exit 1
    }
    LIGHTTPD_BIN=$(find_lighttpd) || LIGHTTPD_BIN=""
    [ -z "$LIGHTTPD_BIN" ] && { echo "  lighttpd still not found after opkg install" >&2; exit 1; }
fi
echo "  lighttpd: $LIGHTTPD_BIN"

# Neutralize the default Entware lighttpd init script — but ONLY if it
# actually fights us for the port. `opkg install lighttpd` drops a generic
# S*lighttpd auto-starting on 0.0.0.0:8088 — наш дефолтный порт (Эд
# (@GdalSef) 2026-04-18: stock S80lighttpd at PID 723 was holding
# 0.0.0.0:8088, so bind() failed). Но у юзера штатный lighttpd может жить
# на :80/:81 и панели никак не мешать — такой не трогаем. И НИКОГДА не
# удаляем чужой init-скрипт: не переименовался — это ошибка установки,
# а не повод для rm.
_stock_lighttpd_port() {
    local f p
    for f in /opt/etc/lighttpd/lighttpd.conf /opt/etc/lighttpd/conf.d/*.conf; do
        [ -f "$f" ] || continue
        p=$(sed -n 's/^[[:space:]]*server\.port[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
        [ -n "$p" ] && { printf '%s' "$p"; return 0; }
    done
    return 1
}
for _init in /opt/etc/init.d/S*lighttpd; do
    [ -e "$_init" ] || continue
    _sport=$(_stock_lighttpd_port) || _sport=""
    # Без server.port в конфиге lighttpd слушает 80.
    [ -n "$_sport" ] || _sport=80
    if [ "$_sport" != "$PORT" ]; then
        echo "  keeping stock lighttpd init $_init (its port $_sport does not conflict with $PORT)"
        continue
    fi
    echo "  disabling conflicting lighttpd init (port $_sport): $_init"
    "$_init" stop 2>/dev/null || true
    if ! mv "$_init" "${_init%/*}/.${_init##*/}.disabled-by-z2k"; then
        echo "  cannot rename $_init out of the way — refusing to delete a foreign init script" >&2
        echo "  free port $PORT (or rerun with --port N) and retry" >&2
        exit 1
    fi
done

# Verify mod_cgi module is physically present; auto-install if not.
# Search all Entware-standard lighttpd module locations — включая
# secondary opkg dest'ы (split-opkg на USB-томе), иначе живой mod_cgi
# считался бы отсутствующим и install падал после no-op'ного opkg install.
MOD_CGI_PATHS="/opt/lib/lighttpd /opt/usr/lib/lighttpd /opt/libexec/lighttpd"
if [ -r /opt/etc/opkg.conf ]; then
    while read -r _kw _dn _dp _rest; do
        [ "$_kw" = dest ] || continue
        case "$_dp" in
            /*) MOD_CGI_PATHS="$MOD_CGI_PATHS ${_dp%/}/opt/lib/lighttpd ${_dp%/}/opt/usr/lib/lighttpd" ;;
        esac
    done < /opt/etc/opkg.conf
fi
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

echo "[3/7] Stopping existing panel (if any)"
if [ -x "$INIT_DST" ]; then
    "$INIT_DST" stop 2>/dev/null || true
fi
# Осиротевшие supervisor/waiter (init снесён, фон остался) — по cmdline,
# иначе выживший супервизор поднимет lighttpd поверх нашего нового.
pkill -f "$INIT_DST" 2>/dev/null || true
pkill -f "lighttpd.*$WEBPANEL_DIR" 2>/dev/null || true
# Also stop any leftover busybox httpd bound to the same www dir from an
# earlier (pre-lighttpd) install.
pkill -f "httpd.*$WWW_DIR" 2>/dev/null || true
rm -f /var/run/z2k-webpanel-sup.pid /var/run/z2k-webpanel-wait.pid

echo "[4/7] Staging new panel files"
# Новое дерево собирается ЦЕЛИКОМ в соседних каталогах; установленная
# панель не трогается, пока staging не готов. Stale staging от прошлого
# оборванного запуска просто перезаписываем.
rm -rf "$STAGE_WP" "$STAGE_WWW"
mkdir -p "$STAGE_WP/cgi" "$STAGE_WWW/cgi-bin" /opt/etc/init.d

cp -f "$SRC_DIR/cgi/auth.sh"    "$STAGE_WP/cgi/auth.sh"
cp -f "$SRC_DIR/cgi/actions.sh" "$STAGE_WP/cgi/actions.sh"
cp -f "$SRC_DIR/cgi/api.sh"     "$STAGE_WP/cgi/api.sh"
chmod 755 "$STAGE_WP/cgi/"*.sh

# Симлинк указывает на ФИНАЛЬНЫЙ путь: staging-каталог переедет туда целиком.
ln -sf "$WEBPANEL_DIR/cgi/api.sh" "$STAGE_WWW/cgi-bin/api"

cp -f "$SRC_DIR/www/index.html"  "$STAGE_WWW/index.html"
cp -f "$SRC_DIR/www/app.js"      "$STAGE_WWW/app.js"
cp -f "$SRC_DIR/www/style.css"   "$STAGE_WWW/style.css"
# Favicon is decorative — guard against missing file so a partial download
# (e.g. CDN miss on the SVG) doesn't fail the entire webpanel install and
# leave the panel dead after auto-update reinstall.
if [ -f "$SRC_DIR/www/favicon.svg" ]; then
    cp -f "$SRC_DIR/www/favicon.svg" "$STAGE_WWW/favicon.svg"
fi
chmod 644 "$STAGE_WWW/index.html" "$STAGE_WWW/app.js" "$STAGE_WWW/style.css" \
          "$STAGE_WWW/favicon.svg" 2>/dev/null || true

echo "[5/7] Writing lighttpd config"
sed \
    -e "s|@WWW_DIR@|${WWW_DIR}|g" \
    -e "s|@PORT@|${PORT}|g" \
    -e "s|@BIND@|${BIND}|g" \
    "$SRC_DIR/lighttpd.conf" > "$STAGE_WP/lighttpd.conf"

printf '%s' "$PORT" > "$STAGE_WP/port"
printf '%s' "$BIND" > "$STAGE_WP/bind"
# Маркер «bind задан юзером»: только такой bind переигрывается при
# переустановке (см. комментарий у разбора сохранённых значений выше).
if [ "$BIND_EXPLICIT" = 1 ]; then
    : > "$STAGE_WP/bind.explicit"
fi

echo "[6/7] Installing files (atomic swap)"
# Старая панель уходит только теперь, когда новая полностью собрана. Окно
# между mv — миллисекунды; обрыв в нём откатывается trap'ом (webpanel_rollback).
rm -rf "$OLD_WP" "$OLD_WWW"
[ -d "$WEBPANEL_DIR" ] && mv "$WEBPANEL_DIR" "$OLD_WP"
[ -d "$WWW_DIR" ] && mv "$WWW_DIR" "$OLD_WWW"
mv "$STAGE_WP" "$WEBPANEL_DIR"
mv "$STAGE_WWW" "$WWW_DIR"
rm -rf "$OLD_WP" "$OLD_WWW"
# Stale files from the old z2k-webpanel-install.sh monolith must not leak.
rm -f /opt/zapret2/z2k-webpanel-install.sh \
      /opt/zapret2/z2k-httpd.sh \
      2>/dev/null || true

cp -f "$SRC_DIR/init.d/S96z2k-webpanel" "$INIT_DST"
chmod 755 "$INIT_DST"

echo "[7/7] Starting webpanel"
"$INIT_DST" start || {
    echo "Start failed. Check /tmp/z2k-log/z2k-webpanel-error.log and /tmp/z2k-log/z2k-webpanel-startcheck.log" >&2
    exit 1
}

# init start возвращает 0 и в ветке фонового ожидания (том с либами ещё не
# смонтирован / адрес не поднялся). Не врать «installed and running» —
# проверяем факт запуска.
PANEL_UP=0
_pid=$(cat /var/run/z2k-webpanel.pid 2>/dev/null) || _pid=""
if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    PANEL_UP=1
fi

# If the user forced --bind to something other than 0.0.0.0 we print
# that as the URL. Otherwise fall back to the detect_lan_ip helper.
if [ "$BIND" = "0.0.0.0" ]; then
    IP=$(detect_lan_ip)
    [ -z "$IP" ] && IP="<router-ip>"
else
    IP="$BIND"
fi

if [ "$PANEL_UP" = 1 ]; then
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
else
    cat <<EOF

===========================================================
z2k webpanel installed — lighttpd is NOT running yet
-----------------------------------------------------------
The panel will start automatically once the /opt volume with
lighttpd libraries (or the listen address $BIND) becomes
available. Background retry: every 5s, up to 5 minutes.
Log:     /tmp/z2k-log/z2k-webpanel-wait.log
URL (once up): http://$IP:$PORT/
-----------------------------------------------------------
Control: $INIT_DST {start|stop|restart|status}
Config:  $CONF_DST
===========================================================
EOF
fi
