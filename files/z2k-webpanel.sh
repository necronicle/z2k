#!/bin/sh
# z2k-webpanel.sh — Lightweight web monitoring panel for zapret2/z2k on Keenetic
# POSIX sh CGI script for busybox httpd
# Usage: Place in /opt/zapret2/www/cgi-bin/ and serve via busybox httpd

# ==============================================================================
# Configuration
# ==============================================================================

ZAPRET_BASE="/opt/zapret2"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
CONFIG_DIR="${ZAPRET_BASE}/config"
EXTRA_STRATS_DIR="${ZAPRET_BASE}/extra_strats"
STATE_FILE="${EXTRA_STRATS_DIR}/cache/autocircular/state.tsv"
AUTOCIRCULAR_DEBUG_LOG="${EXTRA_STRATS_DIR}/cache/autocircular/debug.log"
HEALTHCHECK_LOG="${ZAPRET_BASE}/healthcheck.log"
ROLLBACK_DIR="${ZAPRET_BASE}/.rollback"
NFQWS_PROCESS="nfqws2"

# ==============================================================================
# Helpers
# ==============================================================================

html_escape() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

# Parse QUERY_STRING for action parameter — whitelist only
get_action() {
    local qs="${QUERY_STRING:-}"
    local action=""
    # Extract action= value from query string
    case "$qs" in
        action=*) action="${qs#action=}" ;;
        *\&action=*) action="${qs#*&action=}"; action="${action%%&*}" ;;
        *) action="" ;;
    esac
    # Strip anything after & if present
    action="${action%%&*}"
    # Whitelist validation — only allow known safe values
    case "$action" in
        restart|stop|start|clearstate) printf '%s' "$action" ;;
        *) printf '' ;;
    esac
}

# Get nfqws2 PID(s)
get_nfqws_pids() {
    if command -v pidof >/dev/null 2>&1; then
        pidof "$NFQWS_PROCESS" 2>/dev/null
    else
        ps w 2>/dev/null | grep "[n]fqws2" | awk '{print $1}' | tr '\n' ' '
    fi
}

# Check if nfqws2 is running
nfqws_running() {
    [ -n "$(get_nfqws_pids)" ]
}

# Get process uptime from /proc (Linux only)
get_process_uptime() {
    local pid="$1"
    if [ -d "/proc/$pid" ] && [ -f "/proc/uptime" ]; then
        local sys_uptime proc_start elapsed
        sys_uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
        proc_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
        if [ -n "$sys_uptime" ] && [ -n "$proc_start" ]; then
            local clk_tck
            clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
            # Use awk for float arithmetic (busybox awk handles this)
            elapsed=$(awk "BEGIN { printf \"%d\", $sys_uptime - ($proc_start / $clk_tck) }")
            if [ "$elapsed" -gt 0 ] 2>/dev/null; then
                local days=$((elapsed / 86400))
                local hours=$(( (elapsed % 86400) / 3600 ))
                local mins=$(( (elapsed % 3600) / 60 ))
                if [ "$days" -gt 0 ]; then
                    printf '%dd %dh %dm' "$days" "$hours" "$mins"
                elif [ "$hours" -gt 0 ]; then
                    printf '%dh %dm' "$hours" "$mins"
                else
                    printf '%dm' "$mins"
                fi
                return
            fi
        fi
    fi
    printf 'n/a'
}

# Read strategy file content
read_strategy() {
    local path="$1"
    if [ -f "$path" ]; then
        local content
        content=$(cat "$path" 2>/dev/null)
        if [ -n "$content" ]; then
            html_escape "$content"
        else
            printf '<span class="dim">empty</span>'
        fi
    else
        printf '<span class="dim">not found</span>'
    fi
}

# ==============================================================================
# Action handler
# ==============================================================================

ACTION=$(get_action)
ACTION_RESULT=""

if [ -n "$ACTION" ]; then
    case "$ACTION" in
        restart)
            if [ -x "$INIT_SCRIPT" ]; then
                ACTION_RESULT=$("$INIT_SCRIPT" restart 2>&1 | tail -5)
                ACTION_MSG="Service restart requested"
            else
                ACTION_MSG="Error: init script not found"
            fi
            ;;
        stop)
            if [ -x "$INIT_SCRIPT" ]; then
                ACTION_RESULT=$("$INIT_SCRIPT" stop 2>&1 | tail -5)
                ACTION_MSG="Service stop requested"
            else
                ACTION_MSG="Error: init script not found"
            fi
            ;;
        start)
            if [ -x "$INIT_SCRIPT" ]; then
                ACTION_RESULT=$("$INIT_SCRIPT" start 2>&1 | tail -5)
                ACTION_MSG="Service start requested"
            else
                ACTION_MSG="Error: init script not found"
            fi
            ;;
        clearstate)
            if [ -f "$STATE_FILE" ]; then
                cp "$STATE_FILE" "${STATE_FILE}.bak" 2>/dev/null
                : > "$STATE_FILE"
                ACTION_MSG="Autocircular state cleared (backup saved as state.tsv.bak)"
            else
                ACTION_MSG="No state file to clear"
            fi
            ;;
    esac
fi

# ==============================================================================
# Collect data
# ==============================================================================

# Service status
PIDS=$(get_nfqws_pids)
if [ -n "$PIDS" ]; then
    SERVICE_STATUS="running"
    SERVICE_CLASS="status-ok"
    # Get uptime from first PID
    FIRST_PID=$(echo "$PIDS" | awk '{print $1}')
    SERVICE_UPTIME=$(get_process_uptime "$FIRST_PID")
else
    SERVICE_STATUS="stopped"
    SERVICE_CLASS="status-err"
    SERVICE_UPTIME="-"
    FIRST_PID=""
fi

# Strategies
STRAT_YT_TCP=$(read_strategy "${EXTRA_STRATS_DIR}/TCP/YT/Strategy.txt")
STRAT_YT_GV_TCP=$(read_strategy "${EXTRA_STRATS_DIR}/TCP/YT_GV/Strategy.txt")
STRAT_RKN_TCP=$(read_strategy "${EXTRA_STRATS_DIR}/TCP/RKN/Strategy.txt")
STRAT_YT_UDP=$(read_strategy "${EXTRA_STRATS_DIR}/UDP/YT/Strategy.txt")

# Current strategy number
CURRENT_STRAT="n/a"
if [ -f "${CONFIG_DIR}/current_strategy" ]; then
    CURRENT_STRAT=$(cat "${CONFIG_DIR}/current_strategy" 2>/dev/null | head -1)
fi

# QUIC strategy
QUIC_STRAT="n/a"
if [ -f "${CONFIG_DIR}/quic_strategy.conf" ]; then
    QUIC_STRAT=$(cat "${CONFIG_DIR}/quic_strategy.conf" 2>/dev/null | head -1)
fi

# Autocircular state count
if [ -f "$STATE_FILE" ]; then
    STATE_COUNT=$(wc -l < "$STATE_FILE" 2>/dev/null | tr -d ' ')
    STATE_SIZE=$(ls -lh "$STATE_FILE" 2>/dev/null | awk '{print $5}')
else
    STATE_COUNT="0"
    STATE_SIZE="-"
fi

# Rollback info
if [ -d "$ROLLBACK_DIR" ] && [ -f "$ROLLBACK_DIR/metadata" ]; then
    ROLLBACK_AVAIL="yes"
    ROLLBACK_TIME=$(grep '^SNAPSHOT_TIME=' "$ROLLBACK_DIR/metadata" 2>/dev/null | cut -d= -f2-)
    [ -z "$ROLLBACK_TIME" ] && ROLLBACK_TIME="unknown"
else
    ROLLBACK_AVAIL="no"
    ROLLBACK_TIME="-"
fi

# System info
SYS_ARCH=$(uname -m 2>/dev/null || echo "unknown")
SYS_KERNEL=$(uname -r 2>/dev/null || echo "unknown")
if [ -f /proc/loadavg ]; then
    SYS_LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
else
    SYS_LOAD=$(uptime 2>/dev/null | sed 's/.*load average: //' | sed 's/,.*//' || echo "n/a")
fi
if command -v free >/dev/null 2>&1; then
    SYS_MEM=$(free 2>/dev/null | awk '/^Mem:/{printf "%dM / %dM (%.0f%%)", ($3)/1024, ($2)/1024, ($3/$2)*100}')
elif [ -f /proc/meminfo ]; then
    MEM_TOTAL=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    MEM_AVAIL=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [ -n "$MEM_TOTAL" ] && [ -n "$MEM_AVAIL" ]; then
        MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
        SYS_MEM="${MEM_USED}M / ${MEM_TOTAL}M"
    else
        SYS_MEM="n/a"
    fi
else
    SYS_MEM="n/a"
fi
if [ -d "$ZAPRET_BASE" ]; then
    SYS_DISK=$(df -h "$ZAPRET_BASE" 2>/dev/null | awk 'NR==2{printf "%s used / %s total (%s)", $3, $2, $5}')
else
    SYS_DISK="n/a"
fi

# ==============================================================================
# Output HTML
# ==============================================================================

printf 'Content-Type: text/html; charset=utf-8\r\n'
printf '\r\n'

cat <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>z2k Panel</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5;padding:12px;max-width:960px;margin:0 auto}
h1{color:#58a6ff;font-size:1.4em;margin-bottom:4px}
.subtitle{color:#8b949e;font-size:0.85em;margin-bottom:16px}
.card{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:14px;margin-bottom:12px}
.card h2{color:#58a6ff;font-size:1em;margin-bottom:10px;border-bottom:1px solid #21262d;padding-bottom:6px}
.row{display:flex;flex-wrap:wrap;gap:12px}
.row .card{flex:1;min-width:260px}
table{width:100%;border-collapse:collapse}
td,th{text-align:left;padding:4px 8px;border-bottom:1px solid #21262d}
th{color:#8b949e;font-weight:normal;font-size:0.85em;white-space:nowrap}
td{word-break:break-all}
.status-ok{color:#3fb950;font-weight:bold}
.status-warn{color:#d29922;font-weight:bold}
.status-err{color:#f85149;font-weight:bold}
.dim{color:#484f58}
.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:0.8em;font-weight:bold}
.badge-green{background:#0d4429;color:#3fb950;border:1px solid #238636}
.badge-red{background:#3d1214;color:#f85149;border:1px solid #da3633}
.badge-yellow{background:#2e2a0e;color:#d29922;border:1px solid #9e6a03}
pre{background:#0d1117;border:1px solid #30363d;border-radius:4px;padding:10px;overflow-x:auto;font-size:0.82em;color:#8b949e;max-height:320px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
.btn{display:inline-block;padding:6px 16px;border-radius:6px;text-decoration:none;font-size:0.85em;font-weight:600;border:1px solid #30363d;cursor:pointer;transition:background 0.15s}
.btn-green{background:#238636;color:#fff;border-color:#238636}.btn-green:hover{background:#2ea043}
.btn-red{background:#da3633;color:#fff;border-color:#da3633}.btn-red:hover{background:#f85149}
.btn-blue{background:#1f6feb;color:#fff;border-color:#1f6feb}.btn-blue:hover{background:#388bfd}
.btn-yellow{background:#9e6a03;color:#fff;border-color:#9e6a03}.btn-yellow:hover{background:#d29922}
.alert{padding:10px 14px;border-radius:6px;margin-bottom:12px;font-size:0.9em}
.alert-info{background:#0c2d6b;color:#58a6ff;border:1px solid #1f6feb}
.alert-ok{background:#0d4429;color:#3fb950;border:1px solid #238636}
.alert-err{background:#3d1214;color:#f85149;border:1px solid #da3633}
.strat-val{font-family:SFMono-Regular,Consolas,"Liberation Mono",Menlo,monospace;font-size:0.82em;color:#c9d1d9}
footer{text-align:center;color:#484f58;font-size:0.78em;margin-top:16px;padding-top:12px;border-top:1px solid #21262d}
@media(max-width:600px){.row{flex-direction:column}.row .card{min-width:auto}body{font-size:13px;padding:8px}}
</style>
</head>
<body>
<h1>z2k Web Panel</h1>
<div class="subtitle">zapret2 for Keenetic &mdash; monitoring dashboard</div>
HTMLHEAD

# Action result banner
if [ -n "$ACTION" ]; then
    alert_class="alert-info"
    case "$ACTION" in
        stop) alert_class="alert-err" ;;
        start|restart) alert_class="alert-ok" ;;
        clearstate) alert_class="alert-info" ;;
    esac
    escaped_msg=$(html_escape "${ACTION_MSG:-Action executed}")
    printf '<div class="alert %s">Action: <strong>%s</strong> &mdash; %s</div>\n' \
        "$alert_class" "$ACTION" "$escaped_msg"
    if [ -n "$ACTION_RESULT" ]; then
        printf '<pre>%s</pre>\n' "$(html_escape "$ACTION_RESULT")"
    fi
fi

# Service status + Actions
cat <<SERVICEHTML
<div class="row">
<div class="card">
<h2>Service Status</h2>
<table>
<tr><th>nfqws2</th><td><span class="badge badge-$([ "$SERVICE_STATUS" = "running" ] && echo "green" || echo "red")">$SERVICE_STATUS</span></td></tr>
<tr><th>PID</th><td>${PIDS:-<span class="dim">-</span>}</td></tr>
<tr><th>Uptime</th><td>${SERVICE_UPTIME}</td></tr>
<tr><th>Init script</th><td>$([ -x "$INIT_SCRIPT" ] && echo '<span class="status-ok">OK</span>' || echo '<span class="status-err">missing</span>')</td></tr>
</table>
<div class="actions">
<a class="btn btn-green" href="?action=start">Start</a>
<a class="btn btn-blue" href="?action=restart">Restart</a>
<a class="btn btn-red" href="?action=stop">Stop</a>
</div>
</div>

<div class="card">
<h2>System Info</h2>
<table>
<tr><th>Arch</th><td>${SYS_ARCH}</td></tr>
<tr><th>Kernel</th><td>${SYS_KERNEL}</td></tr>
<tr><th>Load</th><td>${SYS_LOAD}</td></tr>
<tr><th>Memory</th><td>${SYS_MEM}</td></tr>
<tr><th>Disk (opt)</th><td>${SYS_DISK}</td></tr>
</table>
</div>
</div>
SERVICEHTML

# Strategies
cat <<STRATHTML
<div class="card">
<h2>Strategies</h2>
<table>
<tr><th style="width:140px">Category</th><th>Strategy params</th></tr>
<tr><td>YouTube TCP</td><td class="strat-val">${STRAT_YT_TCP}</td></tr>
<tr><td>YouTube GV TCP</td><td class="strat-val">${STRAT_YT_GV_TCP}</td></tr>
<tr><td>RKN TCP</td><td class="strat-val">${STRAT_RKN_TCP}</td></tr>
<tr><td>YouTube QUIC/UDP</td><td class="strat-val">${STRAT_YT_UDP}</td></tr>
<tr><td>Current strategy #</td><td class="strat-val">${CURRENT_STRAT}</td></tr>
<tr><td>QUIC config</td><td class="strat-val">${QUIC_STRAT}</td></tr>
</table>
</div>
STRATHTML

# Autocircular + Rollback row
cat <<AUTOHTML
<div class="row">
<div class="card">
<h2>Autocircular State</h2>
<table>
<tr><th>Persisted domains</th><td><strong>${STATE_COUNT}</strong></td></tr>
<tr><th>State file size</th><td>${STATE_SIZE}</td></tr>
<tr><th>State file</th><td class="dim" style="font-size:0.8em">${STATE_FILE}</td></tr>
</table>
<div class="actions">
<a class="btn btn-yellow" href="?action=clearstate" onclick="return confirm('Clear autocircular state?')">Clear State</a>
</div>
</div>

<div class="card">
<h2>Rollback</h2>
<table>
<tr><th>Snapshot available</th><td><span class="badge badge-$([ "$ROLLBACK_AVAIL" = "yes" ] && echo "green" || echo "red")">${ROLLBACK_AVAIL}</span></td></tr>
<tr><th>Snapshot time</th><td>${ROLLBACK_TIME}</td></tr>
</table>
</div>
</div>
AUTOHTML

# Healthcheck log
printf '<div class="card">\n<h2>Healthcheck Log (last 20 lines)</h2>\n<pre>'
if [ -f "$HEALTHCHECK_LOG" ]; then
    tail -20 "$HEALTHCHECK_LOG" 2>/dev/null | while IFS= read -r line; do
        html_escape "$line"
        printf '\n'
    done
else
    printf '<span class="dim">No healthcheck log found at %s</span>' "$HEALTHCHECK_LOG"
fi
printf '</pre>\n</div>\n'

# Autocircular debug log
printf '<div class="card">\n<h2>Autocircular Debug Log (last 10 lines)</h2>\n<pre>'
if [ -f "$AUTOCIRCULAR_DEBUG_LOG" ]; then
    tail -10 "$AUTOCIRCULAR_DEBUG_LOG" 2>/dev/null | while IFS= read -r line; do
        html_escape "$line"
        printf '\n'
    done
else
    printf '<span class="dim">No debug log found at %s</span>' "$AUTOCIRCULAR_DEBUG_LOG"
fi
printf '</pre>\n</div>\n'

# Footer
cat <<'HTMLFOOT'
<footer>
z2k Web Panel &mdash; auto-refresh 30s &mdash; busybox httpd CGI
</footer>
</body>
</html>
HTMLFOOT
