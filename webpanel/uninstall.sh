#!/bin/sh
# z2k webpanel uninstaller.
#
# Leaves no trace: stops the service (including the respawn supervisor and
# the boot-time waiter), removes init.d script, pidfiles, www content and
# webpanel/ directory — and restores the stock lighttpd init that
# install.sh disabled, unless it would take port 80 from the router's own UI.

set -eu

WEBPANEL_DIR="/opt/zapret2/webpanel"
WWW_DIR="/opt/zapret2/www"
INIT_DST="/opt/etc/init.d/S96z2k-webpanel"
PIDFILE="/var/run/z2k-webpanel.pid"
SUP_PIDFILE="/var/run/z2k-webpanel-sup.pid"
WAIT_PIDFILE="/var/run/z2k-webpanel-wait.pid"

# z2k:shared:restore_stock_lighttpd:begin
# Вернуть имя штатному init-скрипту lighttpd, который выключила установка панели.
#
# На порту 80 он возвращается выключенным (ENABLED=no): этот порт занят веб-интерфейсом
# роутера, и включённый lighttpd при загрузке мог бы его уронить (журнал с поля 01.09.2026:
# «bind() to 192.168.1.1:80 failed», «Service: "Nginx": unexpectedly stopped»).
# Этот блок одинаков во всех путях удаления, сверяет tests/test_uninstall_restores_router.sh.
_z2k_restore_stock_lighttpd() {
    local _idir _cdir _dis _base _f _p _sport
    _idir="${Z2K_INITD_DIR:-/opt/etc/init.d}"
    _cdir="${Z2K_LIGHTTPD_CONF_DIR:-/opt/etc/lighttpd}"
    for _dis in "$_idir"/.S*lighttpd.disabled-by-z2k; do
        [ -e "$_dis" ] || continue
        _base="${_dis##*/}"; _base="${_base#.}"; _base="${_base%.disabled-by-z2k}"
        # Файл с этим именем уже есть: значит, выключенная копия больше не нужна.
        if [ -e "$_idir/$_base" ]; then
            rm -f "$_dis"
            continue
        fi
        _sport=""
        for _f in "$_cdir/lighttpd.conf" "$_cdir"/conf.d/*.conf; do
            [ -f "$_f" ] || continue
            if grep -Eq '^[[:space:]]*\$SERVER\["socket"\][^#]*:80"' "$_f"; then _sport=80; break; fi
            _p=$(sed -n 's/^[[:space:]]*server\.port[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_f" | head -1)
            if [ -n "$_p" ] && [ -z "$_sport" ]; then _sport="$_p"; fi
        done
        [ -n "$_sport" ] || _sport=80
        mv "$_dis" "$_idir/$_base" 2>/dev/null || { rm -f "$_dis"; continue; }
        if [ "$_sport" = "80" ]; then
            _p=$(sed 's/^ENABLED=yes/ENABLED=no/' "$_idir/$_base" 2>/dev/null) \
                && printf '%s\n' "$_p" > "$_idir/$_base" 2>/dev/null
            grep -q '^ENABLED=no' "$_idir/$_base" 2>/dev/null || chmod -x "$_idir/$_base" 2>/dev/null
            echo "[i] Штатный $_base возвращён выключенным: порт 80 занят веб-интерфейсом роутера"
        else
            echo "[i] Возвращён штатный init: $_base"
        fi
    done
    return 0
}
# z2k:shared:restore_stock_lighttpd:end

echo "[1/5] Stopping panel"
if [ -x "$INIT_DST" ]; then
    "$INIT_DST" stop 2>/dev/null || true
fi
# Осиротевшие supervisor/waiter (init уже снесён, фон остался) — по cmdline,
# иначе выживший супервизор поднимет lighttpd после удаления файлов.
# pkill НА РОУТЕРЕ НЕТ: Entware собирает busybox без этого апплета. Вызов под
# `|| true` не падал — он НИКОГДА НЕ СРАБАТЫВАЛ, и выживший супервизор
# поднимал lighttpd поверх (тот же класс, что od -A в issue #43). killall бьёт
# по имени и снёс бы чужой lighttpd; pgrep -f есть. $$ пропускаем: busybox
# pgrep вызывающую оболочку не исключает.
_kill_matching() {
    for _p in $(pgrep -f "$1" 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        # Процесс мог уйти между pgrep и kill, в том числе сама подоболочка с pgrep.
        # Под set -e это обрывало бы удаление панели на первом шаге.
        kill "$_p" 2>/dev/null || true
    done
    return 0
}
_kill_matching "$INIT_DST"
_kill_matching "lighttpd.*$WEBPANEL_DIR"
rm -f "$PIDFILE" "$SUP_PIDFILE" "$WAIT_PIDFILE"

echo "[2/5] Removing init.d script"
rm -f "$INIT_DST"

echo "[3/5] Restoring stock lighttpd init (if we disabled one)"
_z2k_restore_stock_lighttpd

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
