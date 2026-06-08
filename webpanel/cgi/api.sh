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
                # Convert + to space then decode %XX. NB: portable hex decode via
                # an index() lookup — busybox/mawk on the router has NO strtonum()
                # (a gawk extension). The old strtonum() decoder silently failed on
                # any %XX-bearing value, which surfaced once rotation host keys grew
                # an address-family suffix ("host|6" → URLSearchParams encodes "|"
                # as %7C) and the × delete started returning "key and host required".
                printf '%s' "$raw" | awk '
                    function hx(c) { return index("0123456789abcdef", tolower(c)) - 1 }
                    {
                        gsub(/\+/, " ")
                        while (match($0, /%[0-9a-fA-F][0-9a-fA-F]/)) {
                            ch = sprintf("%c", hx(substr($0, RSTART+1, 1)) * 16 + hx(substr($0, RSTART+2, 1)))
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
        rst_filter=$(read_flag "RST_FILTER" "$CONFIG_FILE" "0")
        silent_fb=$(read_flag "RKN_SILENT_FALLBACK" "$CONFIG_FILE" "0")
        # Mirror config_official.sh:970-973 — read GAME_MODE_ENABLED first
        # (the new primary), fall back to ROBLOX_UDP_BYPASS only if the
        # new flag is absent from config. Without this fallback parity,
        # /status reports "off" when a manually-edited config has
        # GAME_MODE_ENABLED=1 but leaves the legacy ROBLOX_UDP_BYPASS at
        # 0 — UI lies vs runtime. Explicit grep here instead of relying
        # on read_flag's default (its `${3:-0}` syntax conflates "key
        # missing" with "key present, value 0").
        if grep -q '^GAME_MODE_ENABLED=' "$CONFIG_FILE" 2>/dev/null; then
            game_mode=$(read_flag "GAME_MODE_ENABLED" "$CONFIG_FILE" "0")
        else
            game_mode=$(read_flag "ROBLOX_UDP_BYPASS" "$CONFIG_FILE" "0")
        fi
        # GAME_PROFILE — flowseal (default) | legacy. Coerce unknown
        # values to flowseal, matching config_official.sh:986-991.
        game_profile=$(read_flag "GAME_PROFILE" "$CONFIG_FILE" "flowseal")
        case "$game_profile" in
            flowseal|legacy) ;;
            *) game_profile="flowseal" ;;
        esac
        disable_cd=$(read_flag "DISABLE_CUSTOM" "$CONFIG_FILE" "1")
        # UI wants positive "customd_enabled"
        if [ "$disable_cd" = "0" ]; then customd="1"; else customd="0"; fi
        dynamic_ttl=$(read_flag "Z2K_DYNAMIC_TTL" "$CONFIG_FILE" "1")
        stats=$(read_flag "Z2K_STATS" "$CONFIG_FILE" "1")
        tpws=$(read_flag "Z2K_TPWS" "$CONFIG_FILE" "1")
        ppe=$(read_flag "Z2K_PPE_DEOFFLOAD" "$CONFIG_FILE" "1")
        tpid=$(tunnel_pid 2>/dev/null)
        tunnel_running=false
        [ -n "$tpid" ] && tunnel_running=true

        json_header
        printf '{"ok":true,"installed":%s,"running":%s,"service":"%s","toggles":{"rst_filter":"%s","silent_fallback":"%s","game_mode":"%s","customd":"%s","dynamic_ttl":"%s","stats":"%s","tpws":"%s","ppe":"%s"},"game_profile":"%s","tunnel":{"running":%s}}\n' \
            "${installed:-false}" "${running:-false}" "${svc_state:-unknown}" \
            "${rst_filter:-0}" "${silent_fb:-0}" "${game_mode:-0}" "${customd:-0}" \
            "${dynamic_ttl:-1}" "${stats:-1}" "${tpws:-1}" "${ppe:-1}" \
            "${game_profile:-flowseal}" \
            "${tunnel_running:-false}"
        exit 0
        ;;

    # ---------- SERVICE CONTROL (async — returns job_id) ----------
    # Юзер получает {ok:true, job:<id>} мгновенно; UI открывает модалку
    # с live log поллингом /job?id=<id>. Без этого browser висел до
    # завершения restart (5-15s) и не понимал что происходит.
    "POST /service/start")
        require_method POST
        job_id=$(svc_action_async "Запуск сервиса nfqws2" "set_flag ENABLED 1 \"${CONFIG_FILE}\"; ${INIT_SCRIPT} start")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;
    "POST /service/stop")
        require_method POST
        job_id=$(svc_action_async "Остановка сервиса nfqws2" "set_flag ENABLED 0 \"${CONFIG_FILE}\"; ${INIT_SCRIPT} stop")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;
    "POST /service/restart")
        require_method POST
        job_id=$(svc_action_async "Перезапуск сервиса nfqws2" "set_flag ENABLED 1 \"${CONFIG_FILE}\"; ${INIT_SCRIPT} restart")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    # ---------- TOGGLES (async — returns job_id) ----------
    "POST /toggle/rst-filter"|\
    "POST /toggle/silent-fallback"|\
    "POST /toggle/game-mode"|\
    "POST /toggle/customd"|\
    "POST /toggle/dynamic-ttl"|\
    "POST /toggle/stats"|\
    "POST /toggle/tpws"|\
    "POST /toggle/ppe")
        body=$(read_body)
        val=$(form_value "$body" "value")
        [ -z "$val" ] && val=$(form_value "${QUERY_STRING:-}" "value")
        case "$val" in
            0|1) ;;
            *) json_fail "400 Bad Request" "value must be 0 or 1" ;;
        esac
        case "$path" in
            /toggle/rst-filter)      _toggle_fn=toggle_rst_filter;      _label="RST-фильтр" ;;
            /toggle/silent-fallback) _toggle_fn=toggle_silent_fallback; _label="Silent fallback" ;;
            /toggle/game-mode)       _toggle_fn=toggle_game_mode;       _label="Игровой режим" ;;
            /toggle/customd)         _toggle_fn=toggle_customd;         _label="custom.d" ;;
            /toggle/dynamic-ttl)     _toggle_fn=toggle_dynamic_ttl;     _label="Динамический TTL" ;;
            /toggle/stats)           _toggle_fn=toggle_stats;           _label="Сбор статистики" ;;
            /toggle/tpws)            _toggle_fn=toggle_tpws;            _label="YouTube tpws" ;;
            /toggle/ppe)             _toggle_fn=toggle_ppe;             _label="PPE de-offload" ;;
        esac
        _verb=$([ "$val" = "1" ] && echo "Включаю" || echo "Отключаю")
        job_id=$(svc_action_async "${_verb} ${_label}" "${_toggle_fn} ${val}")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

    # ---------- POLICY ACCESS (Keenetic ip policy filter) ----------
    "GET /policy/status")
        result=$(policy_status)
        name=$(printf '%s' "$result" | sed -n 's/.*name=\([^|]*\).*/\1/p')
        exclude=$(printf '%s' "$result" | sed -n 's/.*exclude=\([^|]*\).*/\1/p')
        exists=$(printf '%s' "$result" | sed -n 's/.*exists=\([0-9]*\).*/\1/p')
        json_header
        printf '{"ok":true,"name":'; json_string "$name"
        printf ',"exclude":"%s","exists":%s}\n' "${exclude:-0}" "${exists:-0}"
        exit 0
        ;;

    "POST /policy/save")
        body=$(read_body)
        name=$(form_value "$body" "name")
        exclude=$(form_value "$body" "exclude")
        [ -z "$exclude" ] && exclude="0"
        case "$exclude" in
            0|1) ;;
            *) json_fail "400 Bad Request" "exclude must be 0 or 1" ;;
        esac
        # Async job для visibility (есть restart сервиса под капотом).
        job_id=$(svc_action_async "Применение политики доступа" "policy_save \"${name}\" ${exclude}")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
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

    "POST /whitelist/import")
        # Body — raw multi-line TXT (one domain per line). Frontend sends
        # Content-Type: text/plain. whitelist_import парсит/валидирует/
        # дедуплицирует/append'ит и выводит counts.
        body=$(read_body)
        result=$(printf '%s' "$body" | whitelist_import) || json_fail "500 Server Error" "import failed"
        added=$(printf '%s' "$result" | sed -n 's/.*added=\([0-9]*\).*/\1/p')
        dup=$(printf '%s' "$result" | sed -n 's/.*skipped_dup=\([0-9]*\).*/\1/p')
        inv=$(printf '%s' "$result" | sed -n 's/.*skipped_invalid=\([0-9]*\).*/\1/p')
        json_header
        printf '{"ok":true,"added":%d,"skipped_duplicate":%d,"skipped_invalid":%d}\n' "${added:-0}" "${dup:-0}" "${inv:-0}"
        exit 0
        ;;

    # ---------- EXTRA DOMAINS (live hostlist для autocircular) ----------
    "GET /extra-domains")
        json_header
        printf '{"ok":true,"domains":['
        first=1
        extra_domains_list | while IFS= read -r d; do
            [ -z "$d" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$d"
        done
        printf ']}\n'
        exit 0
        ;;

    "POST /extra-domains/add"|"POST /extra-domains/delete")
        body=$(read_body)
        domain=$(form_value "$body" "domain")
        [ -z "$domain" ] && json_fail "400 Bad Request" "domain required"
        if [ "$path" = "/extra-domains/add" ]; then
            extra_domains_add "$domain" || json_fail "400 Bad Request" "invalid or add failed"
        else
            extra_domains_delete "$domain" || json_fail "400 Bad Request" "invalid or delete failed"
        fi
        json_ok
        ;;

    # ---------- TUNNEL (async — returns job_id) ----------
    "POST /tunnel/enable")
        job_id=$(svc_action_async "Запуск Telegram туннеля" "tunnel_enable")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;
    "POST /tunnel/disable")
        job_id=$(svc_action_async "Остановка Telegram туннеля" "tunnel_disable")
        json_header
        printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
        exit 0
        ;;

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
        state_read | while IFS="$(printf '\t')" read -r skey shost sstrategy sts smode; do
            [ -z "$skey" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            printf '{"key":'; json_string "$skey"
            printf ',"host":'; json_string "$shost"
            printf ',"strategy":'; json_string "${sstrategy:-0}"
            printf ',"ts":%s' "${sts:-0}"
            printf ',"mode":'; json_string "${smode:-auto}"
            printf '}'
        done
        printf ']}\n'
        exit 0
        ;;

    # Pool sizes (distinct strategies per category key) from the live nfqws2
    # cmdline — drives the per-row strategy dropdown and the Discord-voice panel.
    "GET /pools")
        json_header
        printf '{"ok":true,"pools":{'
        first=1
        pools_read | while IFS="$(printf '\t')" read -r pkey pcount; do
            [ -z "$pkey" ] && continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            json_string "$pkey"; printf ':%s' "${pcount:-0}"
        done
        printf '}}\n'
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

    # Pin / manually select a rotator row's strategy. mode=auto adopts it live and
    # keeps rotating; mode=frozen adopts it AND stops the rotator from changing it.
    "POST /state/set")
        body=$(read_body)
        s_key=$(form_value "$body" "key")
        s_host=$(form_value "$body" "host")
        s_strategy=$(form_value "$body" "strategy")
        s_mode=$(form_value "$body" "mode")
        [ -z "$s_mode" ] && s_mode="auto"
        { [ -z "$s_key" ] || [ -z "$s_host" ] || [ -z "$s_strategy" ]; } && \
            json_fail "400 Bad Request" "key, host, strategy required"
        state_set "$s_key" "$s_host" "$s_strategy" "$s_mode" || \
            json_fail "400 Bad Request" "set failed"
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

    # ---------- ACTIVE PROBE — removed in r-15 (Phase 1 cleanup) ----------
    # /probe/run replaced by the server_active_reject taxonomy and Phase 3
    # reactive z2k-detect daemon. Endpoint kept as 410 Gone so any cached
    # browser UI doesn't 404 silently.
    "POST /probe/run")
        json_fail "410 Gone" "active probe removed in r-15"
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

    # ---------- AUTO-UPDATE ----------
    "GET /update/status")
        # GET → may refresh the cache opportunistically (TTL guarded).
        update_refresh_manifest 0 2>/dev/null || true
        installed=$(update_installed_tag)
        available=$(update_manifest_current)
        behind=$(update_behind_count "$installed")
        last_check=$(update_last_check_ts)
        pending=$(update_pending_entries "$installed")
        json_header
        printf '{"ok":true,"installed":'
        json_string "$installed"
        printf ',"available":'
        json_string "$available"
        printf ',"behind":%s,"last_check":%s,"pending":%s}\n' "${behind:-0}" "${last_check:-0}" "${pending:-[]}"
        exit 0
        ;;

    "POST /update/check")
        update_refresh_manifest 1 2>/dev/null
        installed=$(update_installed_tag)
        available=$(update_manifest_current)
        behind=$(update_behind_count "$installed")
        last_check=$(update_last_check_ts)
        pending=$(update_pending_entries "$installed")
        json_header
        printf '{"ok":true,"installed":'
        json_string "$installed"
        printf ',"available":'
        json_string "$available"
        printf ',"behind":%s,"last_check":%s,"pending":%s}\n' "${behind:-0}" "${last_check:-0}" "${pending:-[]}"
        exit 0
        ;;

    "POST /update/apply")
        job_id=$(update_apply_async) || json_fail "500" "apply launch failed"
        json_header
        printf '{"ok":true,"job":'
        json_string "$job_id"
        printf '}\n'
        exit 0
        ;;

    # ---------- DEFAULT ----------
    *)
        json_fail "404 Not Found" "no such endpoint: $method $path"
        ;;
esac
