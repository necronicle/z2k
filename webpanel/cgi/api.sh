#!/bin/sh
# z2k webpanel — CGI dispatcher.
#
# Routes /api/* requests to handlers in actions.sh. All reads are GET,
# all mutations are POST. Returns JSON with Content-Type header.
#
# The HTTP server invokes this with standard CGI env vars:
#   REQUEST_METHOD, PATH_INFO, QUERY_STRING, CONTENT_LENGTH, CONTENT_TYPE
#   REMOTE_USER (set after basic-auth), HTTP_HOST, HTTP_REFERER
#
# Body for POSTs is on stdin.

# lighttpd mod_cgi passes a nearly-empty environment to scripts — no PATH.
# On Entware all standard tools live in /opt/{bin,sbin,usr/bin,usr/sbin} and
# system tools in /bin:/sbin. Set an explicit PATH so cut/grep/sed/awk/cat/dd
# etc. all resolve, otherwise they silently fail with "command not found" and
# our handlers return empty JSON.
export PATH="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/usr/sbin:/bin:/usr/bin"

set -u

# $0 is usually the symlink at /opt/zapret2/www/cgi-bin/api that lighttpd
# invokes, not the real file. Resolve to the directory holding auth.sh +
# actions.sh.
if real_self=$(readlink -f "$0" 2>/dev/null); then
    SELF_DIR=$(dirname "$real_self")
else
    SELF_DIR=$(dirname "$0" 2>/dev/null)
fi
[ -d "$SELF_DIR" ] && [ -f "$SELF_DIR/auth.sh" ] || SELF_DIR="/opt/zapret2/webpanel/cgi"

# shellcheck source=auth.sh
. "$SELF_DIR/auth.sh"
# shellcheck source=actions.sh
. "$SELF_DIR/actions.sh"

# --- utility: json output ---

json_header() {
    printf 'Status: 200 OK\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
}

# Minimal JSON string escape: backslash, quote, control chars.
json_escape() {
    # shellcheck disable=SC2016
    awk 'BEGIN {
        for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    }
    {
        s = $0
        out = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\\") out = out "\\\\"
            else if (c == "\"") out = out "\\\""
            else if (c == "\n") out = out "\\n"
            else if (c == "\r") out = out "\\r"
            else if (c == "\t") out = out "\\t"
            else if (ord[c] < 32) out = out sprintf("\\u%04x", ord[c])
            else out = out c
        }
        if (NR > 1) printf "\\n"
        printf "%s", out
    }'
}

json_string() {
    # Emit a JSON string literal including surrounding quotes.
    printf '"'
    printf '%s' "$1" | json_escape
    printf '"'
}

json_ok() {
    json_header
    printf '{"ok":true'
    if [ $# -gt 0 ]; then
        printf ',%s' "$1"
    fi
    printf '}\n'
    exit 0
}

json_fail() {
    # usage: json_fail <http-status-line> <msg>
    local status="$1" msg="$2"
    printf 'Status: %s\r\n' "$status"
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
    printf '{"ok":false,"error":'
    json_string "$msg"
    printf '}\n'
    exit 0
}

require_method() {
    if [ "${REQUEST_METHOD:-GET}" != "$1" ]; then
        json_fail "405 Method Not Allowed" "method not allowed"
    fi
}

read_body() {
    local len="${CONTENT_LENGTH:-0}"
    [ "$len" -gt 0 ] 2>/dev/null || { echo ""; return 0; }
    dd bs=1 count="$len" 2>/dev/null
}

# Decode x-www-form-urlencoded body or query string into a specific key.
# Returns the decoded value on stdout. Minimal decoder — only handles %XX.
form_value() {
    local haystack="$1" key="$2"
    local pair
    local OLD_IFS="$IFS"
    IFS='&'
    for pair in $haystack; do
        case "$pair" in
            "$key="*)
                IFS="$OLD_IFS"
                local raw="${pair#$key=}"
                # Convert + to space then decode %XX.
                printf '%s' "$raw" | awk '
                    {
                        gsub(/\+/, " ")
                        while (match($0, /%[0-9a-fA-F][0-9a-fA-F]/)) {
                            hex = substr($0, RSTART+1, 2)
                            ch = sprintf("%c", strtonum("0x" hex))
                            $0 = substr($0, 1, RSTART-1) ch substr($0, RSTART+3)
                        }
                        print
                    }'
                return 0
                ;;
        esac
    done
    IFS="$OLD_IFS"
    echo ""
}

# --- route dispatch ---

auth_require

path="${PATH_INFO:-/}"
method="${REQUEST_METHOD:-GET}"

# lighttpd sets PATH_INFO to the portion after the CGI script path —
# e.g. for request /cgi-bin/api/toggle/rst-filter the PATH_INFO is
# /toggle/rst-filter. No rewriting needed.

case "$method $path" in

    # ---------- STATUS ----------
    "GET /status"|"GET /")
        installed=$(is_installed && echo true || echo false)
        running=$(is_running   && echo true || echo false)
        svc_state=$(service_status_string)
        rst_filter=$(read_flag "DROP_DPI_RST" "$CONFIG_FILE" "0")
        game_mode=$(read_flag "ROBLOX_UDP_BYPASS" "$CONFIG_FILE" "0")
        disable_cd=$(read_flag "DISABLE_CUSTOM" "$CONFIG_FILE" "1")
        # UI wants positive "customd_enabled"
        if [ "$disable_cd" = "0" ]; then customd="1"; else customd="0"; fi
        tpid=$(tunnel_pid 2>/dev/null)
        tunnel_running=false
        [ -n "$tpid" ] && tunnel_running=true

        # Belt-and-suspenders defaults: even if read_flag ever returns
        # an empty value again, %s expansion with ${var:-0} keeps the
        # JSON syntactically valid instead of producing `"key":,`.
        json_header
        printf '{"ok":true,"installed":%s,"running":%s,"service":"%s","toggles":{"rst_filter":%s,"game_mode":%s,"customd":%s},"tunnel":{"running":%s}}\n' \
            "${installed:-false}" "${running:-false}" "${svc_state:-unknown}" \
            "${rst_filter:-0}" "${game_mode:-0}" "${customd:-0}" \
            "${tunnel_running:-false}"
        exit 0
        ;;

    # ---------- SERVICE CONTROL ----------
    "POST /service/start")   require_method POST; svc_start   && json_ok || json_fail "500" "start failed" ;;
    "POST /service/stop")    require_method POST; svc_stop    && json_ok || json_fail "500" "stop failed"  ;;
    "POST /service/restart") require_method POST; svc_restart && json_ok || json_fail "500" "restart failed" ;;

    # ---------- TOGGLES ----------
    "POST /toggle/rst-filter"|\
    "POST /toggle/game-mode"|\
    "POST /toggle/customd")
        body=$(read_body)
        val=$(form_value "$body" "value")
        [ -z "$val" ] && val=$(form_value "${QUERY_STRING:-}" "value")
        case "$val" in
            0|1) ;;
            *) json_fail "400 Bad Request" "value must be 0 or 1" ;;
        esac
        case "$path" in
            /toggle/rst-filter)      toggle_rst_filter      "$val" || json_fail "500" "toggle failed" ;;
            /toggle/game-mode)       toggle_game_mode       "$val" || json_fail "500" "toggle failed" ;;
            /toggle/customd)         toggle_customd         "$val" || json_fail "500" "toggle failed" ;;
        esac
        json_ok
        ;;

    # ---------- WHITELIST ----------
    "GET /whitelist")
        json_header
        printf '{"ok":true,"domains":['
        first=1
        whitelist_list | while IFS= read -r d; do
            [ -z "$d" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$d"
        done
        printf ']}\n'
        exit 0
        ;;

    "POST /whitelist/add"|"POST /whitelist/delete")
        body=$(read_body)
        domain=$(form_value "$body" "domain")
        [ -z "$domain" ] && json_fail "400 Bad Request" "domain required"
        if [ "$path" = "/whitelist/add" ]; then
            whitelist_add "$domain" || json_fail "400 Bad Request" "invalid or add failed"
        else
            whitelist_delete "$domain" || json_fail "400 Bad Request" "invalid or delete failed"
        fi
        json_ok
        ;;

    # ---------- TUNNEL ----------
    "POST /tunnel/enable")  tunnel_enable  || json_fail "500" "tunnel enable failed"; json_ok ;;
    "POST /tunnel/disable") tunnel_disable; json_ok ;;

    # ---------- LOGS ----------
    "GET /logs/service")
        n=$(form_value "${QUERY_STRING:-}" "n")
        [ -z "$n" ] && n=200
        log_content=$(tail_service_log "$n")
        json_header
        printf '{"ok":true,"log":'
        json_string "$log_content"
        printf '}\n'
        exit 0
        ;;

    # ---------- HEALTHCHECK ----------
    "POST /healthcheck/run")
        job_id=$(healthcheck_run_async) || json_fail "500" "failed to start"
        json_header
        printf '{"ok":true,"job":'
        json_string "$job_id"
        printf '}\n'
        exit 0
        ;;

    "GET /healthcheck/log")
        json_header
        printf '{"ok":true,"log":'
        log_content=$(tail_healthcheck_log 200)
        json_string "$log_content"
        printf '}\n'
        exit 0
        ;;

    "GET /job")
        id=$(form_value "${QUERY_STRING:-}" "id")
        [ -z "$id" ] && json_fail "400 Bad Request" "id required"
        # Sanitize id: must be digits only
        case "$id" in
            *[!0-9]*) json_fail "400 Bad Request" "bad id" ;;
        esac
        st=$(job_status "$id")
        log_content=$(job_log "$id")
        exit_code=$(job_exit_code "$id")
        done_flag=false
        [ "$st" = "done" ] && done_flag=true
        json_header
        printf '{"ok":true,"status":"%s","done":%s,"exit":%s,"log":' \
            "$st" "$done_flag" "${exit_code:-null}"
        json_string "$log_content"
        printf '}\n'
        exit 0
        ;;

    # ---------- DIAG (Phase 3) ----------
    "GET /diag")
        diag_content=$(diag_run)
        json_header
        printf '{"ok":true,"diag":'
        json_string "$diag_content"
        printf '}\n'
        exit 0
        ;;

    # ---------- ROTATOR STATE (Phase 3) ----------
    "GET /state")
        json_header
        printf '{"ok":true,"entries":['
        first=1
        state_read | while IFS="$(printf '\t')" read -r skey shost sstrategy sts; do
            [ -z "$skey" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            printf '{"key":'; json_string "$skey"
            printf ',"host":'; json_string "$shost"
            printf ',"strategy":'; json_string "${sstrategy:-0}"
            printf ',"ts":%s}' "${sts:-0}"
        done
        printf ']}\n'
        exit 0
        ;;

    "POST /state/delete")
        body=$(read_body)
        s_key=$(form_value "$body" "key")
        s_host=$(form_value "$body" "host")
        [ -z "$s_key" ] || [ -z "$s_host" ] && json_fail "400 Bad Request" "key and host required"
        state_delete "$s_key" "$s_host" || json_fail "400 Bad Request" "delete failed"
        json_ok
        ;;

    # ---------- GEOSITE (Phase 12: always-on) ----------
    "POST /geosite/update")
        job_id=$(geosite_run_async) || json_fail "500" "failed to start"
        json_header
        printf '{"ok":true,"job":'
        json_string "$job_id"
        printf '}\n'
        exit 0
        ;;

    "GET /geosite/status")
        # Phase 12: geosite is always-on — no user toggle. Report
        # enabled:"1" unconditionally. Staging dir is legacy (Phase 2
        # v2fly prototype path); we now count production List.txt
        # files after geosite replacement.
        extra_dir="$ZAPRET2_DIR/extra_strats"
        lists_present=0
        for f in "$extra_dir/TCP/RKN/List.txt" \
                 "$extra_dir/TCP/YT/List.txt" \
                 "$extra_dir/UDP/YT/List.txt" \
                 "$extra_dir/TCP/RKN/Discord.txt"; do
            [ -s "$f" ] && lists_present=$((lists_present + 1))
        done
        json_header
        printf '{"ok":true,"enabled":"1","staging_count":%s}\n' "$lists_present"
        exit 0
        ;;

    # ---------- ACTIVE PROBE (Phase 10) ----------
    "POST /probe/run")
        body=$(read_body)
        p_host=$(form_value "$body" "host")
        p_profile=$(form_value "$body" "profile")
        p_apply=$(form_value "$body" "apply")
        [ -z "$p_host" ] && json_fail "400 Bad Request" "host required"
        [ -z "$p_apply" ] && p_apply="0"
        job_id=$(probe_run_async "$p_host" "$p_profile" "$p_apply") \
            || json_fail "400 Bad Request" "probe rejected (invalid host/profile)"
        json_header
        printf '{"ok":true,"job":'
        json_string "$job_id"
        printf '}\n'
        exit 0
        ;;

    # ---------- DEBUG FLAG (Phase 3) ----------
    "GET /debug")
        json_header
        printf '{"ok":true,"enabled":"%s"}\n' "$(debug_flag_state)"
        exit 0
        ;;

    "POST /debug")
        body=$(read_body)
        val=$(form_value "$body" "value")
        [ -z "$val" ] && val=$(form_value "${QUERY_STRING:-}" "value")
        case "$val" in
            0|1) ;;
            *) json_fail "400 Bad Request" "value must be 0 or 1" ;;
        esac
        debug_flag_set "$val" || json_fail "500" "debug set failed"
        json_ok
        ;;

    # ---------- DEFAULT ----------
    *)
        json_fail "404 Not Found" "no such endpoint: $method $path"
        ;;
esac
