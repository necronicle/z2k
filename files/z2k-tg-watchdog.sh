#!/bin/sh
# Cron на Entware/busybox запускается с минимальным PATH (/sbin:/usr/sbin:/bin:/usr/bin)
# который НЕ включает /opt/bin где живут awk/pidof/pgrep/date/killall/curl/logger.
# Без этого все утилиты "command not found", flag-check на awk молча падает,
# user_disabled пустой, скрипт уходит в "process not running" и каждую минуту
# воскрешает daemon — даже когда юзер явно остановил его через menu/webpanel.
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

# z2k-tg-watchdog.sh — periodic health check + auto-restart for the
# Telegram tunnel (tg-mtproxy-client). Runs every minute via cron;
# install.sh wires it up and adds the crontab entry.
#
# Two independent failure triggers:
#   1. CONNECT_FAIL storm — legacy passive check. Scans the tunnel log
#      for CONNECT_FAIL markers; restart if ≥10 in the last 40 lines.
#      Catches the case where tg-mtproxy-client is alive but every
#      stream to Telegram DCs is refused.
#
#   2. Active end-to-end HTTPS probe — curl to core.telegram.org which,
#      by virtue of our PREROUTING REDIRECT, transits the full
#      tunnel → VPS-relay → Telegram chain. Three consecutive failures
#      (~3 min) trigger a restart. Catches the "process alive but
#      silently wedged after WS reconnect" mode that the CONNECT_FAIL
#      check misses because no new streams are being attempted.
#
# Restart path:
#   - Prefer /opt/etc/init.d/S98tg-tunnel which handles iptables and
#     pidfile bookkeeping properly.
#   - Fallback: `killall -9` + fresh background spawn. Log truncated to
#     exactly one marker line on restart so the CONNECT_FAIL tail doesn't
#     echo back and retrigger us on the next cron tick (classic flap loop).

LOG=/tmp/z2k-log/tg-tunnel.log
BIN=/opt/sbin/tg-mtproxy-client
INIT=/opt/etc/init.d/S98tg-tunnel
STATE=/tmp/tg-tunnel-watchdog.state
PROBE_URL=https://core.telegram.org/
# Pin IP в TG CIDR (149.154.160.0/20) — без --resolve curl каждую минуту
# дёргает getaddrinfo() через ndnproxy → upstream DoH юзера. У части юзеров
# DoH стоит anti-bot rate-limited (geohide и т.п.) — лог сыпет 403 на каждом
# tick'е watchdog'а. REDIRECT всё равно отправит трафик в туннель независимо
# от конкретного IP в --resolve.
PROBE_RESOLVE_IP=149.154.167.99

[ -x "$BIN" ] || exit 0

# Kill ONLY the :1443 Telegram tunnel instance. The cdnbase http-tunnel
# (S97z2k-http-tunnel on :1444) runs the SAME tg-mtproxy-client binary, so a
# bare `killall tg-mtproxy-client` would silently take out the cdnbase tunnel
# too → cdnbase blackhole (no watchdog on :1444 to bring it back). Match by
# cmdline like actions.sh tunnel_pid() does.
kill_tg_1443() {
    if pidof tg-mtproxy-client >/dev/null 2>&1; then
        for p in $(pidof tg-mtproxy-client); do
            if [ -r "/proc/$p/cmdline" ] && tr '\0' ' ' < "/proc/$p/cmdline" | grep -q -- "--listen=:1443"; then
                kill -9 "$p" 2>/dev/null
            fi
        done
    fi
}

# CWE-59: restart_tunnel (fallback) и cap_log пишут в /tmp/z2k-log как root.
# CWE-59: Безопасная проверка каталога /tmp/z2k-log (shared with z2k-insta-ip-refresh.sh)
. "${ZAPRET2_DIR}/z2k-tg-redirect.sh"
safe_tmp_log_dir

# Size-cap наших /tmp логов чтобы они не забивали tmpfs (на Keenetic /tmp
# обычно ~244M RAM). tg-tunnel.log на :1443 пишется с -v (verbose) append'ом
# без ротации — на долгоживущем роутере растёт неделями и в итоге переполняет
# tmpfs, после чего curl падает с error 23 на следующем install/update и z2k
# не переустанавливается (field incident 2026-05-28). Watchdog бежит каждую
# минуту — здесь hard-cap: при превышении лимита оставляем хвост (свежая
# диагностика сохраняется, рост остановлен). Покрывает рост по любой причине
# без удаления -v.
cap_log() {
    local f="$1" max_kb="${2:-2048}" sz_kb tmp
    # CWE-59: /tmp world-writable, watchdog бежит root'ом. symlink на чужой
    # файл здесь → `cat > "$f"` перезаписал бы цель его хвостом. Если это
    # symlink — удаляем сам линк (rm не идёт по ссылке), демон пересоздаст
    # обычный файл.
    if [ -L "$f" ]; then
        rm -f "$f" 2>/dev/null
        return 0
    fi
    [ -f "$f" ] || return 0
    sz_kb=$(du -k "$f" 2>/dev/null | awk '{print $1}')
    [ -n "$sz_kb" ] && [ "$sz_kb" -gt "$max_kb" ] || return 0
    # CWE-59: temp тоже в world-writable /tmp под root'ом. Предсказуемое
    # имя (${f}.captmp.$$) → атакующий мог подложить symlink и `tail > tmp`
    # пошёл бы по нему. mktemp создаёт файл атомарно с O_EXCL и случайным
    # именем — не подменить. Если mktemp недоступен/нет места — пропускаем
    # cap (рост остановит install-time cleanup в z2k.sh).
    tmp=$(mktemp "/tmp/.tgwd-cap.XXXXXX" 2>/dev/null) || return 0
    if tail -n 200 "$f" > "$tmp" 2>/dev/null; then
        cat "$tmp" > "$f" 2>/dev/null
        rm -f "$tmp"
        logger -t tg-watchdog "log capped: $f was ${sz_kb}KB → tail 200 lines" 2>/dev/null
    else
        rm -f "$tmp"
    fi
}
cap_log /tmp/z2k-log/tg-tunnel.log 2048
cap_log /tmp/z2k-log/z2k-http-tunnel.log 2048
cap_log /tmp/z2k-log/z2k-webpanel-error.log 1024
cap_log /tmp/z2k-log/z2k-insta-refresh.log 512

# Honor explicit user disable from menu / webpanel. The "stop tunnel"
# action there sets TG_PROXY_USER_DISABLED=1 in /opt/zapret2/config so
# the watchdog stops resurrecting the daemon every 3 min.
# `re-enable` from the same UI flips it back to 0.
CONFIG_FILE="/opt/zapret2/config"
if [ -f "$CONFIG_FILE" ]; then
    user_disabled=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG_FILE")
    if [ "$user_disabled" = "1" ]; then
        # If anything survived an older autostart path, stop through the
        # init script so REDIRECT rules are removed together with the process.
        if [ -x "$INIT" ]; then
            "$INIT" stop >/dev/null 2>&1
        else
            kill_tg_1443
        fi
        exit 0
    fi
fi

restart_tunnel() {
    local reason="$1"
    logger -t tg-watchdog "restart: $reason"
    if [ -x "$INIT" ]; then
        "$INIT" stop  >/dev/null 2>&1
        sleep 1
        # belt-and-suspenders kill in case init script left a leftover
        kill_tg_1443
        sleep 1
        # Truncate log to exactly one marker line. Without this, the very
        # CONNECT_FAIL storm that triggered the restart is still sitting in
        # tail -40 when cron runs again in a minute, and the detector fires
        # a second restart before the new session has time to stabilise —
        # classic restart loop.
        echo "$(date) watchdog restart: $reason" > "$LOG"
        "$INIT" start >/dev/null 2>&1
    else
        kill_tg_1443
        sleep 1
        echo "$(date) watchdog restart: $reason" > "$LOG"
        "$BIN" --listen=:1443 -v >> "$LOG" 2>&1 &
    fi
    echo 0 > "$STATE"
}

# 1) CONNECT_FAIL storm (legacy)
if [ -f "$LOG" ] && pidof tg-mtproxy-client >/dev/null 2>&1; then
    FAILS=$(tail -40 "$LOG" 2>/dev/null | grep -c "CONNECT_FAIL")
    if [ "$FAILS" -ge 10 ]; then
        restart_tunnel "CONNECT_FAIL storm ($FAILS in last 40 lines)"
        exit 0
    fi
fi

# If the binary isn't running at all, just start it and reset state.
if ! pidof tg-mtproxy-client >/dev/null 2>&1; then
    restart_tunnel "tunnel process not running"
    exit 0
fi

# 1.5) iptables REDIRECT rules check. nfqws2 restart (S99zapret2) can
#   wipe the NAT PREROUTING/OUTPUT chains without triggering the NDM
#   netfilter hooks that re-insert our REDIRECT rules. When this
#   happens the tunnel process is alive and connected to the VPS, but
#   LAN traffic to Telegram DCs goes straight out the WAN — blocked.
#   Android Telegram is especially sensitive: it caches TCP connections
#   aggressively and won't retry through the tunnel until the app is
#   force-killed. Re-insert rules if even one is missing.
TG_REDIR_LIB="/opt/zapret2/z2k-tg-redirect.sh"
if [ -r "$TG_REDIR_LIB" ]; then
    . "$TG_REDIR_LIB"
    if ! z2k_tg_rule_present PREROUTING || ! z2k_tg_rule_present OUTPUT; then
        logger -t tg-watchdog "REDIRECT rules missing — re-inserting (ipset, -w) + flushing conntrack"
        z2k_tg_remove_legacy_rules
        z2k_tg_ensure_rules
        # Flush stale conntrack for ALL Telegram DC CIDRs. Without this,
        # Android Telegram holds dead direct-to-DC connections via the kernel
        # conntrack table and new packets follow those stale entries BYPASSING
        # the freshly restored REDIRECT — dead for minutes until conntrack
        # expires. conntrack -D is idempotent.
        z2k_tg_flush_conntrack
    fi
fi

# 2) Active end-to-end probe through the tunnel.
#    core.telegram.org resolves into 149.154.0.0/16, which our PREROUTING
#    REDIRECT bounces to 127.0.0.1:1443 → tg-mtproxy-client → VPS relay →
#    Telegram. Successful TLS + HTTP response = full path is healthy.
if curl --connect-timeout 8 --max-time 15 -sf -o /dev/null \
        --resolve "core.telegram.org:443:$PROBE_RESOLVE_IP" \
        "$PROBE_URL" 2>/dev/null; then
    echo 0 > "$STATE"
    exit 0
fi

# Probe failed — increment consecutive-failure counter.
FAIL_CNT=0
[ -f "$STATE" ] && FAIL_CNT=$(head -1 "$STATE" 2>/dev/null)
case "$FAIL_CNT" in ''|*[!0-9]*) FAIL_CNT=0 ;; esac
FAIL_CNT=$((FAIL_CNT + 1))
echo "$FAIL_CNT" > "$STATE"

# Restart only after 3 consecutive failures (~3 minutes) to avoid
# flapping when Telegram itself or the upstream relay has a brief blip.
if [ "$FAIL_CNT" -ge 3 ]; then
    restart_tunnel "active probe failed ${FAIL_CNT}x in a row"
fi
