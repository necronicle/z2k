#!/bin/sh
# z2k-update-lists.sh - Автоматическое обновление списков доменов
# Предназначен для вызова из cron: 0 4 * * * sh /opt/zapret2/z2k-update-lists.sh
#
# При обнаружении изменений автоматически перезапускает сервис.

ZAPRET2_DIR="/opt/zapret2"
INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
LOG_FILE="${ZAPRET2_DIR}/update-lists.log"
MAX_LOG_LINES=200

# GITHUB_RAW is resolved in this order:
#   1. Explicit env var (useful for manual overrides and testing)
#   2. Z2K_GITHUB_RAW from /opt/zapret2/config (persisted at install time)
#   3. master branch default
# This means clean installs from a non-master branch (e.g. z2k-enhanced
# during feature testing) continue pulling domain lists from the SAME
# branch via cron, instead of silently drifting back to master.
if [ -z "${GITHUB_RAW:-}" ] && [ -r "${ZAPRET2_DIR}/config" ]; then
    _persisted_raw=$(grep '^Z2K_GITHUB_RAW=' "${ZAPRET2_DIR}/config" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//')
    [ -n "$_persisted_raw" ] && GITHUB_RAW="$_persisted_raw"
fi
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}"

# ==============================================================================
# z2k_fetch — загрузка файла с GitHub через цепочку зеркал.
# ==============================================================================
# Дублирует логику z2k.sh / lib/utils.sh для standalone cron-запуска (этот
# скрипт не source'ит utils.sh). Слои: raw.github → jsdelivr → gh-proxy →
# Keenetic DNS override через 8.8.8.8 + ndmc.
_z2k_curl_etag() {
    local url="$1" dest="$2"
    local etag_file="${dest}.etag"
    local hdr_file="${dest}.hdr.$$"
    local tmp_body="${dest}.new.$$"
    local old_etag="" http_status
    if [ -f "$etag_file" ] && [ -s "$dest" ]; then
        old_etag=$(cat "$etag_file" 2>/dev/null)
    fi
    if [ -n "$old_etag" ]; then
        http_status=$(curl -sSL --connect-timeout 10 --max-time 180 \
            -H "If-None-Match: $old_etag" -D "$hdr_file" -o "$tmp_body" \
            -w "%{http_code}" "$url" 2>/dev/null)
    else
        http_status=$(curl -sSL --connect-timeout 10 --max-time 180 \
            -D "$hdr_file" -o "$tmp_body" \
            -w "%{http_code}" "$url" 2>/dev/null)
    fi
    case "$http_status" in
        304) rm -f "$hdr_file" "$tmp_body"; return 0 ;;
        200)
            [ ! -s "$tmp_body" ] && { rm -f "$hdr_file" "$tmp_body"; return 1; }
            local new_etag
            new_etag=$(grep -i '^etag:' "$hdr_file" 2>/dev/null | head -1 \
                       | sed 's/^[^:]*:[[:space:]]*//; s/\r$//; s/[[:space:]]*$//')
            mkdir -p "$(dirname "$dest")" 2>/dev/null
            mv -f "$tmp_body" "$dest"
            if [ -n "$new_etag" ]; then printf '%s\n' "$new_etag" > "$etag_file"
            else rm -f "$etag_file"; fi
            rm -f "$hdr_file"; return 0 ;;
        *) rm -f "$hdr_file" "$tmp_body"; return 1 ;;
    esac
}

z2k_fetch() {
    local src="$1"
    local dest="$2"
    local url

    case "$src" in
        http://*|https://*) url="$src" ;;
        /*) url="${GITHUB_RAW}${src}" ;;
        *)  url="${GITHUB_RAW}/${src}" ;;
    esac

    local jsdelivr="" gh_proxy=""
    case "$url" in
        https://raw.githubusercontent.com/*)
            local _rest="${url#https://raw.githubusercontent.com/}"
            local _owner="${_rest%%/*}";  _rest="${_rest#*/}"
            local _repo="${_rest%%/*}";   _rest="${_rest#*/}"
            local _branch="${_rest%%/*}"; _rest="${_rest#*/}"
            jsdelivr="https://cdn.jsdelivr.net/gh/${_owner}/${_repo}@${_branch}/${_rest}"
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
    esac

    if _z2k_curl_etag "$url" "$dest"; then return 0; fi
    [ -n "$jsdelivr" ] && _z2k_curl_etag "$jsdelivr" "$dest" && return 0
    [ -n "$gh_proxy" ] && _z2k_curl_etag "$gh_proxy" "$dest" && return 0

    if command -v ndmc >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
        local resolved_any=0 host ip
        for host in raw.githubusercontent.com cdn.jsdelivr.net api.github.com; do
            ip=$(nslookup "$host" 8.8.8.8 2>/dev/null \
                 | awk '/^Name:/ {s=1; next} s && /^Address [0-9]+: [0-9]+\./ {print $3; exit}')
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "8.8.8.8" ]; then
                ndmc -c "ip host $host $ip" >/dev/null 2>&1 && resolved_any=1
            fi
        done
        if [ "$resolved_any" = "1" ]; then
            sleep 1
            if _z2k_curl_etag "$url" "$dest"; then return 0; fi
            [ -n "$jsdelivr" ] && _z2k_curl_etag "$jsdelivr" "$dest" && return 0
        fi
    fi

    return 1
}

# ==============================================================================
# ETag preservation across cron runs
# ==============================================================================
# z2k_fetch's _z2k_curl_etag reads/writes ETag at "${dest}.etag" where dest
# is whatever path it's called with. Updaters pass a per-run mktemp path,
# so without these helpers each cron run starts with no ETag baseline and
# always issues a full GET (no 304 optimization), plus orphaned *.etag
# crumbs accumulate next to the temp files.
#
# Pattern per updater function:
#   _etag_prep "$dest" "$tmp"         # before z2k_fetch — primes 304 layer
#   ... fetch + validate ...
#   _etag_finalize "$tmp" "$dest"     # after successful mv tmp → dest
#   _etag_cleanup "$tmp"              # in place of rm -f "$tmp"
_etag_prep() {
    # Copy dest body + dest.etag into tmp so z2k_fetch can hit 304.
    # ETag is only carried over if the body copy succeeded — otherwise
    # we'd leave a valid ETag pointing at a torn/partial body, and a
    # subsequent 304 would falsely validate that broken body.
    local src="$1" tmp="$2"
    [ -f "$src" ] && [ -s "$src" ] || return 0
    cp -f "$src" "$tmp" 2>/dev/null || return 0
    [ -f "${src}.etag" ] && cp -f "${src}.etag" "${tmp}.etag" 2>/dev/null
    return 0
}
_etag_finalize() {
    # Carry the freshly-fetched ETag to the final dest so next run reuses it.
    # If the 200 response carried no ETag header, _z2k_curl_etag deletes
    # tmp.etag — in that case we must also drop the stale dest.etag, or
    # next cron sends a phantom If-None-Match that no longer matches the
    # body we just installed.
    local tmp="$1" dest="$2"
    if [ -f "${tmp}.etag" ]; then
        mv -f "${tmp}.etag" "${dest}.etag" 2>/dev/null
    else
        rm -f "${dest}.etag"
    fi
}
_etag_cleanup() {
    rm -f "$1" "${1}.etag"
}

# ==============================================================================
# ЛОГИРОВАНИЕ
# ==============================================================================

log_msg() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null

    # Ротация лога
    if [ -f "$LOG_FILE" ]; then
        local lines
        lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            local tmp
            tmp=$(mktemp "${LOG_FILE}.XXXXXX") || return
            tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "$tmp" 2>/dev/null
            mv -f "$tmp" "$LOG_FILE" 2>/dev/null || rm -f "$tmp"
        fi
    fi
}

# ==============================================================================
# ОБНОВЛЕНИЕ СПИСКОВ
# ==============================================================================

update_list() {
    local name=$1
    local url=$2
    local dest=$3

    if [ -z "$url" ] || [ -z "$dest" ]; then
        return 1
    fi

    local tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    _etag_prep "$dest" "$tmp"

    if ! z2k_fetch "$url" "$tmp"; then
        log_msg "FAIL: download $name from $url (all mirrors failed)"
        _etag_cleanup "$tmp"
        return 1
    fi

    # Проверить что файл не пустой
    if [ ! -s "$tmp" ]; then
        log_msg "FAIL: $name is empty"
        _etag_cleanup "$tmp"
        return 1
    fi

    # Убрать CRLF
    sed -i 's/\r$//' "$tmp" 2>/dev/null

    # Сравнить с текущим
    if [ -f "$dest" ]; then
        local old_hash new_hash
        if command -v md5sum >/dev/null 2>&1; then
            old_hash=$(md5sum "$dest" 2>/dev/null | awk '{print $1}')
            new_hash=$(md5sum "$tmp" 2>/dev/null | awk '{print $1}')
        else
            old_hash=$(wc -c < "$dest" 2>/dev/null)
            new_hash=$(wc -c < "$tmp" 2>/dev/null)
        fi

        if [ "$old_hash" = "$new_hash" ]; then
            _etag_finalize "$tmp" "$dest"
            _etag_cleanup "$tmp"
            return 0  # Без изменений
        fi
    fi

    # Обновить
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    if ! mv -f "$tmp" "$dest"; then
        log_msg "FAIL: $name mv tmp → dest failed"
        _etag_cleanup "$tmp"
        return 1
    fi
    _etag_finalize "$tmp" "$dest"
    log_msg "OK: $name updated ($(wc -l < "$dest") lines)"
    return 2  # Код 2 = есть изменения
}

# ==============================================================================
# ОСНОВНОЙ ПРОЦЕСС
# ==============================================================================

main() {
    # Убедиться что директория для логов существует
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

    log_msg "--- Update lists started ---"

    local changes=0

    # Phase 12: domain lists (RKN / Discord / YouTube TCP / YouTube QUIC)
    # are now pulled from runetfreedom/russia-blocked-geosite release
    # assets via z2k-geosite.sh. ETag-aware, RAM-adaptive RKN variant,
    # atomic rename, sub-80% size guard. The old GitHub raw fetches
    # from necronicle/z2k shipped snapshots are retired; they remain
    # as first-install fallback via lib/install.sh step_download_domain_lists.
    if [ -x "${ZAPRET2_DIR}/z2k-geosite.sh" ]; then
        log_msg "Running z2k-geosite fetch (runetfreedom)..."
        if sh "${ZAPRET2_DIR}/z2k-geosite.sh" fetch >>"$LOG_FILE" 2>&1; then
            # z2k-geosite handles atomic rename + service-safe writes;
            # count a change whenever at least one asset was applied.
            # ETag cache makes 304-only runs a no-op, so we approximate
            # "something changed" by checking log for "applied" markers.
            if tail -30 "$LOG_FILE" | grep -q ': applied,'; then
                changes=$((changes + 1))
                log_msg "geosite: applied changes detected"
            else
                log_msg "geosite: all assets unchanged (ETag match)"
            fi
        else
            log_msg "WARN: geosite fetch partial/failed"
        fi
    else
        log_msg "z2k-geosite.sh missing, skipping list refresh"
    fi

    # Roblox IPs (legacy path — kept for rollback safety, new installs use game_ips.txt)
    update_list "Roblox IPs" \
        "${GITHUB_RAW}/files/lists/roblox_ips.txt" \
        "${ZAPRET2_DIR}/lists/roblox_ips.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    # Game IPs (Roblox AS22697 — used as positive --ipset by the game UDP profile)
    update_list "Game IPs" \
        "${GITHUB_RAW}/files/lists/game_ips.txt" \
        "${ZAPRET2_DIR}/lists/game_ips.txt"
    [ $? -eq 2 ] && changes=$((changes + 1))

    # cdn_ips fetcher удалён 2026-04-27 вместе с cdn_tls профилем.

    # AWS + Oracle cloud IPs — seeds Phase 5 aws_oracle_ips.txt which the
    # merged game_udp profile (Phase 2) OR's with game_ips.txt in hybrid
    # mode. AWS: service=AMAZON, excluding CLOUDFRONT / AMAZON_CONNECT /
    # ROUTE53_HEALTHCHECKS (not gaming). Oracle: all public CIDRs with
    # tags. Source JSONs served directly by AWS/Oracle; z2k_fetch's
    # jsdelivr/gh-proxy layers don't apply to these hosts so we call
    # curl directly (layer 4 Keenetic DNS override still adds value
    # if the ISP poisons amazonaws.com/oracle.com).
    update_aws_oracle_ips() {
        local dest="${ZAPRET2_DIR}/lists/aws_oracle_ips.txt"
        local tmp aws_json oracle_json
        tmp=$(mktemp "${dest}.XXXXXX") || return 1
        local any_ok=0

        aws_json=$(mktemp) || { rm -f "$tmp"; return 1; }
        if curl -fsSL --connect-timeout 10 --max-time 180 -o "$aws_json" \
               "https://ip-ranges.amazonaws.com/ip-ranges.json" 2>/dev/null \
               && [ -s "$aws_json" ]; then
            awk 'BEGIN{RS="{"}
                 /"service":[ ]*"AMAZON"/ && !/"service":[ ]*"(CLOUDFRONT|AMAZON_CONNECT|ROUTE53_HEALTHCHECKS)"/ {
                     if (match($0, /"ip_prefix":[ ]*"[0-9.]+\/[0-9]+"/)) {
                         s = substr($0, RSTART, RLENGTH)
                         sub(/^[^"]*"[^"]+"[ ]*:[ ]*"/, "", s)
                         sub(/".*$/, "", s)
                         print s
                     }
                 }' "$aws_json" > "${tmp}.aws" 2>/dev/null
            if [ -s "${tmp}.aws" ]; then
                printf '# === aws ===\n' >> "$tmp"
                cat "${tmp}.aws" >> "$tmp"
                any_ok=1
            fi
            rm -f "${tmp}.aws"
        else
            log_msg "WARN: aws_oracle/aws fetch failed"
        fi
        rm -f "$aws_json"

        oracle_json=$(mktemp) || { rm -f "$tmp"; return 1; }
        if curl -fsSL --connect-timeout 10 --max-time 180 -o "$oracle_json" \
               "https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json" 2>/dev/null \
               && [ -s "$oracle_json" ]; then
            grep -oE '"cidr":[ ]*"[0-9./]+"' "$oracle_json" | cut -d'"' -f4 > "${tmp}.oracle"
            if [ -s "${tmp}.oracle" ]; then
                printf '# === oracle ===\n' >> "$tmp"
                cat "${tmp}.oracle" >> "$tmp"
                any_ok=1
            fi
            rm -f "${tmp}.oracle"
        else
            log_msg "WARN: aws_oracle/oracle fetch failed"
        fi
        rm -f "$oracle_json"

        if [ "$any_ok" = "0" ]; then
            log_msg "FAIL: aws_oracle both sources failed"
            rm -f "$tmp"
            return 1
        fi
        local count
        count=$(grep -c '^[0-9]' "$tmp" 2>/dev/null)
        if [ -z "$count" ] || [ "$count" -lt 50 ]; then
            log_msg "FAIL: aws_oracle ipset too small ($count entries)"
            rm -f "$tmp"
            return 1
        fi
        if [ -f "$dest" ] && cmp -s "$tmp" "$dest" 2>/dev/null; then
            rm -f "$tmp"
            return 0
        fi
        mkdir -p "$(dirname "$dest")" 2>/dev/null
        mv -f "$tmp" "$dest"
        log_msg "OK: aws_oracle ipset updated ($count entries)"
        return 2
    }
    update_aws_oracle_ips
    [ $? -eq 2 ] && changes=$((changes + 1))

    # Flowseal CDN/cloud/discord aggregate ipset — positive scope for
    # game TCP/UDP arms. Source is flowseal repo .service/ipset-service.txt
    # (the active list; lists/ipset-all.txt in the release is a stub
    # 203.0.113.113/32). Multi-tier validation guards against a corrupted
    # download silently replacing a working list:
    #   1. Not empty
    #   2. No HTML/JSON markers (CDN error pages, GitHub rate-limit JSON)
    #   3. ≥ 80% lines look like CIDR (anti-garbage)
    #   4. Line count ≥ 10000 (current ~31000; below 10K = upstream broke)
    #   5. New size ≥ 50% of existing (rare massive shrink rejected)
    # On any guard failure, the existing file is preserved.
    update_flowseal_game_ips() {
        local dest="${ZAPRET2_DIR}/lists/flowseal_game_ips.txt"
        local url="https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/ipset-service.txt"
        local tmp
        tmp=$(mktemp "${dest}.XXXXXX") || return 1
        _etag_prep "$dest" "$tmp"

        if ! z2k_fetch "$url" "$tmp"; then
            log_msg "FAIL: flowseal_game_ips download (all mirrors failed)"
            _etag_cleanup "$tmp"
            return 1
        fi

        if [ ! -s "$tmp" ]; then
            log_msg "FAIL: flowseal_game_ips empty"
            _etag_cleanup "$tmp"
            return 1
        fi

        # Strip CRLF for consistency with other lists
        sed -i 's/\r$//' "$tmp" 2>/dev/null

        # Guard 2: HTML/JSON detection — first 8 lines must not contain
        # tell-tale markers of a non-text response slipping through CDN.
        if head -8 "$tmp" | grep -qiE '<!doctype|<html|<head|<body|^[[:space:]]*[{[]'; then
            log_msg "FAIL: flowseal_game_ips looks like HTML/JSON, not CIDR list"
            _etag_cleanup "$tmp"
            return 1
        fi

        local total_lines cidr_lines
        total_lines=$(grep -cv '^[[:space:]]*$\|^[[:space:]]*#' "$tmp" 2>/dev/null)
        # Guard 3: CIDR sanity — count lines matching v4 or v6 CIDR shape.
        cidr_lines=$(grep -cE '^[[:space:]]*([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?[[:space:]]*$|^[[:space:]]*[0-9a-fA-F:]+::?[0-9a-fA-F:]*(/[0-9]{1,3})?[[:space:]]*$' "$tmp" 2>/dev/null)
        if [ -z "$total_lines" ] || [ "$total_lines" -lt 1 ]; then
            log_msg "FAIL: flowseal_game_ips has no content lines"
            _etag_cleanup "$tmp"
            return 1
        fi
        # ≥ 80% of non-empty lines must look like CIDR
        if [ "$((cidr_lines * 100 / total_lines))" -lt 80 ]; then
            log_msg "FAIL: flowseal_game_ips CIDR ratio low ($cidr_lines/$total_lines)"
            _etag_cleanup "$tmp"
            return 1
        fi

        # Guard 4: absolute floor — current upstream is ~31K, anything
        # below 10K means flowseal repo got truncated/restructured.
        if [ "$total_lines" -lt 10000 ]; then
            log_msg "FAIL: flowseal_game_ips too small ($total_lines lines, expected ≥10000)"
            _etag_cleanup "$tmp"
            return 1
        fi

        # Guard 5: ratio vs existing — protect against sudden 90% shrink.
        if [ -f "$dest" ] && [ -s "$dest" ]; then
            local old_lines
            old_lines=$(grep -cv '^[[:space:]]*$\|^[[:space:]]*#' "$dest" 2>/dev/null)
            if [ -n "$old_lines" ] && [ "$old_lines" -gt 0 ]; then
                if [ "$((total_lines * 100 / old_lines))" -lt 50 ]; then
                    log_msg "FAIL: flowseal_game_ips shrunk >50% ($old_lines → $total_lines), keeping old"
                    _etag_cleanup "$tmp"
                    return 1
                fi
            fi
        fi

        # No-op if identical (304 hit or content-equal re-fetch)
        if [ -f "$dest" ] && cmp -s "$tmp" "$dest" 2>/dev/null; then
            _etag_finalize "$tmp" "$dest"
            _etag_cleanup "$tmp"
            return 0
        fi

        mkdir -p "$(dirname "$dest")" 2>/dev/null
        if ! mv -f "$tmp" "$dest"; then
            log_msg "FAIL: flowseal_game_ips mv tmp → dest failed"
            _etag_cleanup "$tmp"
            return 1
        fi
        _etag_finalize "$tmp" "$dest"
        log_msg "OK: flowseal_game_ips updated ($total_lines lines)"
        return 2
    }
    update_flowseal_game_ips
    [ $? -eq 2 ] && changes=$((changes + 1))

    if [ "$changes" -gt 0 ]; then
        log_msg "Changes detected ($changes lists), restarting service..."
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" restart 2>/dev/null
            if [ $? -eq 0 ]; then
                log_msg "Service restarted successfully"
            else
                log_msg "FAIL: Service restart failed"
            fi
        fi
    else
        log_msg "No changes detected"
    fi

    log_msg "--- Update lists finished ---"
}

main "$@"
