#!/bin/sh
# Retired experiment: this historical entrypoint ONLY removes static DNS pins.
# Keep the pathname for already deployed installers, nightly jobs and updaters.
# Never resolve or add redirector.googlevideo.com addresses again. The obsolete
# Z2K_REDIRECTOR_DNS setting intentionally cannot prevent this cleanup.
export PATH="${Z2K_STUB_PATH:+$Z2K_STUB_PATH:}/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin"
ZD="${ZAPRET2_DIR:-/opt/zapret2}"
HOST=redirector.googlevideo.com
LOG="${Z2K_AU_LOG_FILE:-/opt/var/log/z2k-auto-update.log}"
log() {
    printf '%s\n' "$1"
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true
}
redirector_cleanup_fail() { log "FAIL: redirector DNS cleanup: $1" >&2; exit 1; }
# Old updaters start this worker before their health check. Do not touch DNS
# unless they committed their success marker; a rolled-back update does nothing.
if [ "${1:-}" = --after-update ]; then
    [ "$#" = 3 ] && [ -n "$2" ] || exit 1
    attempts=0
    while [ "$(cat "$3" 2>/dev/null)" != "$2" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 60 ] || exit 0
        sleep 5
    done
fi
command -v ndmc >/dev/null 2>&1 || exit 0
# Serialize with any legacy refresher still finishing its network request.
# Provisioning remains the installer's/updater's job; cleanup has no network I/O.
command -v flock >/dev/null 2>&1 || redirector_cleanup_fail 'нет flock; очистка будет повторена'
umask 077
exec 9> "$ZD/.redirector-refresh.flock" || exit 1
flock -w 30 9 || redirector_cleanup_fail 'не удалось дождаться прежнего обновления DNS'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/z2k-redirector-cleanup.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
records() {
    LD_LIBRARY_PATH= ndmc -c 'show running-config' > "$WORK/config" || return 1
    [ -s "$WORK/config" ] || return 1
    awk -v h="$HOST" '$1=="ip" && $2=="host" && $3==h {print $4}' "$WORK/config"
}
records > "$WORK/old" || redirector_cleanup_fail 'не удалось прочитать настройки Keenetic'
[ -s "$WORK/old" ] || exit 0
# Treat malformed NDM output as a read failure, never as a command argument.
awk 'NF!=1 || $0 !~ /^[0-9a-fA-F:.]+$/ {bad=1} END {exit bad}' "$WORK/old" || redirector_cleanup_fail 'некорректная запись адреса'
rollback() {
    while read -r ip; do
        LD_LIBRARY_PATH= ndmc -c "ip host $HOST $ip" >/dev/null 2>&1 || true
    done < "$WORK/old"
    LD_LIBRARY_PATH= ndmc -c 'system configuration save' >/dev/null 2>&1 || true
}
trap 'rollback; exit 1' HUP INT TERM
while read -r ip; do
    if ! LD_LIBRARY_PATH= ndmc -c "no ip host $HOST $ip" >/dev/null 2>&1; then
        rollback
        redirector_cleanup_fail "не удалось удалить $ip; выполнена попытка восстановления прежних записей"
    fi
done < "$WORK/old"
if ! records > "$WORK/current" || [ -s "$WORK/current" ]; then
    rollback
    redirector_cleanup_fail 'не удалось подтвердить удаление; выполнена попытка восстановления прежних записей'
fi
if ! LD_LIBRARY_PATH= ndmc -c 'system configuration save' >/dev/null 2>&1; then
    rollback
    redirector_cleanup_fail 'не удалось сохранить настройки; выполнена попытка восстановления прежних записей'
fi
trap 'exit 1' HUP INT TERM
log "redirector DNS cleanup: удалено записей $HOST: $(wc -l < "$WORK/old" | tr -d ' ')"
