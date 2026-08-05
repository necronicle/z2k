#!/bin/sh
# z2k-update-lists.sh - Автоматическое обновление списков доменов
# Предназначен для вызова из cron: 0 4 * * * sh /opt/zapret2/z2k-update-lists.sh
#
# При обнаружении изменений автоматически перезапускает сервис.

# Cron on Entware ships PATH=/usr/bin:/bin only — awk/grep/curl/sed/etc.
# live in /opt/bin and /opt/sbin. Without this export the entire script
# silently dies on the first `awk` call (see reference_cron_path_entware).
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

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

# VPS SNI-passthrough egress для GitHub — см. z2k.sh для полного docstring.
# RU блокирует Fastly anycast github; VPS форвардит github-хосты на реальный
# backend с сертом github → `--resolve <host>:443:<VPS>` качает по валидному TLS.
Z2K_VPS_GH_IP="${Z2K_VPS_GH_IP:-213.176.74.63}"

_z2k_vps_gh_resolve() {
    [ -n "${Z2K_VPS_GH_IP:-}" ] || return 0
    # Извлечь реальный host (между :// и первым /), чтобы жадный glob не
    # матчил github-хост В ПУТИ (напр. gh-proxy.com/https://raw.github...).
    local _h="${1#*://}"; _h="${_h%%/*}"; _h="${_h%%:*}"
    case "$_h" in
        *.githubusercontent.com|github.com|*.github.com) ;;
        *) return 0 ;;
    esac
    local h
    for h in raw.githubusercontent.com objects.githubusercontent.com \
             release-assets.githubusercontent.com gist.githubusercontent.com \
             github.com codeload.github.com api.github.com; do
        printf ' --resolve %s:443:%s' "$h" "$Z2K_VPS_GH_IP"
    done
}

# ==============================================================================
# z2k_fetch — загрузка файла с GitHub через цепочку зеркал.
# ==============================================================================
# Дублирует логику z2k.sh / lib/utils.sh для standalone cron-запуска (этот
# скрипт не source'ит utils.sh). Слои: raw.github → jsdelivr → gh-proxy →
# Keenetic DNS override через 8.8.8.8 + ndmc.
_z2k_curl_etag() {
    local url="$1" dest="$2" resolve_args="$3"
    local etag_file="${dest}.etag"
    local hdr_file="${dest}.hdr.$$"
    local tmp_body="${dest}.new.$$"
    local old_etag="" http_status curl_rc
    if [ -f "$etag_file" ] && [ -s "$dest" ]; then
        old_etag=$(cat "$etag_file" 2>/dev/null)
    fi
    # $resolve_args (unquoted word-split): пусто обычно, `--resolve ...` в Layer 0.
    if [ -n "$old_etag" ]; then
        http_status=$(curl -sSL --connect-timeout 10 --max-time 180 $resolve_args \
            -H "If-None-Match: $old_etag" -D "$hdr_file" -o "$tmp_body" \
            -w "%{http_code}" "$url" 2>/dev/null)
        curl_rc=$?
    else
        http_status=$(curl -sSL --connect-timeout 10 --max-time 180 $resolve_args \
            -D "$hdr_file" -o "$tmp_body" \
            -w "%{http_code}" "$url" 2>/dev/null)
        curl_rc=$?
    fi
    # Статус нужен вызывающему: «файла нет у апстрима» и «зеркала не отвечают» —
    # это разные события, а по коду возврата они неразличимы.
    Z2K_LAST_HTTP="$http_status"
    [ "$curl_rc" -eq 0 ] || { Z2K_LAST_HTTP="000"; rm -f "$hdr_file" "$tmp_body"; return 1; }
    case "$http_status" in
        304) rm -f "$hdr_file" "$tmp_body"; return 0 ;;
        200)
            [ ! -s "$tmp_body" ] && { rm -f "$hdr_file" "$tmp_body"; return 1; }
            local new_etag
            new_etag=$(grep -i '^etag:' "$hdr_file" 2>/dev/null | head -1 \
                       | sed 's/^[^:]*:[[:space:]]*//; s/\r$//; s/[[:space:]]*$//')
            mkdir -p "$(dirname "$dest")" 2>/dev/null
            if ! mv -f "$tmp_body" "$dest"; then
                # Failed mv would leave dest at old body but ETag below
                # would still get written, producing a body/ETag mismatch
                # next run could falsely 304 against.
                rm -f "$hdr_file" "$tmp_body" "$etag_file"
                return 1
            fi
            if [ -n "$new_etag" ]; then printf '%s\n' "$new_etag" > "$etag_file"
            else rm -f "$etag_file"; fi
            rm -f "$hdr_file"; return 0 ;;
        *) rm -f "$hdr_file" "$tmp_body"; return 1 ;;
    esac
}

# Z2K_FETCH_ALL_404=1 после неудачи означает, что КАЖДОЕ зеркало ответило 404,
# то есть файла у апстрима нет. Это не сбой доставки и не должно выглядеть как он.
z2k_fetch() {
    local src="$1"
    local dest="$2"
    local url
    Z2K_FETCH_ALL_404=1

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
        https://github.com/*/releases/download/*)
            gh_proxy="https://gh-proxy.com/${url}"
            ;;
    esac

    # Layer 0: VPS SNI-passthrough egress — первичный путь для github (RU
    # блокирует прямые github-IP). На сбой тихо валимся в цепочку ниже.
    local _vps_resolve; _vps_resolve=$(_z2k_vps_gh_resolve "$url")
    if [ -n "$_vps_resolve" ]; then
        _z2k_curl_etag "$url" "$dest" "$_vps_resolve" && return 0
        [ "${Z2K_LAST_HTTP:-}" = "404" ] || Z2K_FETCH_ALL_404=0
    fi

    if _z2k_curl_etag "$url" "$dest"; then return 0; fi
    [ "${Z2K_LAST_HTTP:-}" = "404" ] || Z2K_FETCH_ALL_404=0
    if [ -n "$jsdelivr" ]; then
        _z2k_curl_etag "$jsdelivr" "$dest" && return 0
        [ "${Z2K_LAST_HTTP:-}" = "404" ] || Z2K_FETCH_ALL_404=0
    fi
    if [ -n "$gh_proxy" ]; then
        _z2k_curl_etag "$gh_proxy" "$dest" && return 0
        [ "${Z2K_LAST_HTTP:-}" = "404" ] || Z2K_FETCH_ALL_404=0
    fi

    # All three normal mirrors fell through. Gate the ndmc DNS-override behind a
    # cross-call streak counter + track the records in Z2K_MANAGED_NDMC — a single
    # transient fall-through must NOT permanently pin github hosts to one IP in the
    # running-config (regression 2026-04-28). Mirrors the gated z2k_fetch in z2k.sh
    # / lib/utils.sh; this is a standalone cron copy that must not be laxer.
    Z2K_FETCH_FAIL_STREAK=$((${Z2K_FETCH_FAIL_STREAK:-0} + 1))
    export Z2K_FETCH_FAIL_STREAK
    : "${Z2K_FETCH_NDMC_THRESHOLD:=2}"
    Z2K_MANAGED_NDMC="${Z2K_MANAGED_NDMC:-/opt/zapret2/state/ndmc-managed.txt}"

    if [ "$Z2K_FETCH_FAIL_STREAK" -ge "$Z2K_FETCH_NDMC_THRESHOLD" ] && \
       command -v ndmc >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
        local resolved_any=0 host ip
        mkdir -p "$(dirname "$Z2K_MANAGED_NDMC")" 2>/dev/null
        for host in raw.githubusercontent.com cdn.jsdelivr.net gh-proxy.com api.github.com \
                    github.com objects.githubusercontent.com release-assets.githubusercontent.com; do
            ip=$(nslookup "$host" 8.8.8.8 2>/dev/null \
                 | awk '/^Name:/ {s=1; next} s && /^Address [0-9]+: [0-9]+\./ {print $3; exit}')
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "8.8.8.8" ]; then
                if LD_LIBRARY_PATH= ndmc -c "ip host $host $ip" >/dev/null 2>&1; then
                    resolved_any=1
                    printf '%s %s\n' "$host" "$ip" >> "$Z2K_MANAGED_NDMC" 2>/dev/null
                fi
            fi
        done
        if [ "$resolved_any" = "1" ]; then
            sleep 1
            if _z2k_curl_etag "$url" "$dest"; then return 0; fi
            [ -n "$jsdelivr" ] && _z2k_curl_etag "$jsdelivr" "$dest" && return 0
            [ -n "$gh_proxy" ] && _z2k_curl_etag "$gh_proxy" "$dest" && return 0
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
        # Апстрим ru-gaming-blocklist перечисляет в индексе игры, для которых
        # файла ещё нет: на 2026-08-05 таких три (Fallout76_AWS, GearsOfWar,
        # MagicTheGathering). Раньше это писалось как «all mirrors failed» и
        # всплывало в диагностике под «errors across all logs» — то есть человек
        # видел поломку там, где её нет, и шёл с ней в поддержку.
        if [ "${Z2K_FETCH_ALL_404:-0}" = "1" ]; then
            log_msg "$name: у апстрима такого файла нет (404), пропускаю"
        else
            log_msg "FAIL: download $name from $url (all mirrors failed)"
        fi
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

    # Content guard. A CDN/GitHub edge serving an error page returns HTTP 200
    # with an HTML/JSON body, which passes z2k_fetch and the non-empty check.
    # Without this, update_list would replace a live ipset source with a
    # "<html>404</html>" blob (update_cf_cidrs_v4 already guards this; update_list
    # did not, yet its callers feed --ipset matches). Reject markup/JSON,
    # an all-comment/empty result, and a sudden massive shrink vs the live file.
    if head -8 "$tmp" | grep -qiE '<!doctype|<html|<head|<body|^[[:space:]]*[{[]'; then
        log_msg "FAIL: $name looks like HTML/JSON, not a list — keeping old"
        _etag_cleanup "$tmp"
        return 1
    fi
    local _new_n
    _new_n=$(grep -cvE '^[[:space:]]*(#|$)' "$tmp" 2>/dev/null)
    : "${_new_n:=0}"
    if [ "$_new_n" -eq 0 ]; then
        log_msg "FAIL: $name has no content lines — keeping old"
        _etag_cleanup "$tmp"
        return 1
    fi
    if [ -f "$dest" ]; then
        local _old_n
        _old_n=$(grep -cvE '^[[:space:]]*(#|$)' "$dest" 2>/dev/null)
        : "${_old_n:=0}"
        if [ "$_old_n" -gt 0 ] && [ "$((_new_n * 100 / _old_n))" -lt 50 ]; then
            log_msg "FAIL: $name shrunk >50% ($_old_n → $_new_n content lines) — keeping old"
            _etag_cleanup "$tmp"
            return 1
        fi
    fi

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

# WARP game lists — ONE FILE PER GAME, pulled from the community-maintained
# medvedeff-true/ru-gaming-blocklist.
#
# We used to pull that repo's combined `medvedeff-game-ipset.txt` and load it
# whole. Measured on the shipped snapshot: 14297 entries covering 643 million
# addresses — 15% of all IPv4 — including 10.0.0.0/8, 127.0.0.0/8 and
# 192.168.0.0/16, i.e. private space and the user's own LAN routed into a
# Cloudflare tunnel. Switching WARP on therefore took down far more than the
# games it was meant to help, and every tunnel hiccup read as "the internet is
# down" (issue #26).
#
# The same repo already publishes per-game lists under games/, so someone who
# wants Steam gets Steam's 59 entries instead of fourteen thousand. Which ones
# are loaded is the user's choice (see .enabled in z2k-warp.sh); on a fresh
# install, none.
#
# These files are UPSTREAM data, not user data: overwritten wholesale on every
# refresh, no 3-way merge. That machinery (.base/.removed ancestor tracking)
# existed because the aggregate doubled as the user's own editable list. Per-game
# lists are read-only in the panel, and users keep their own entries in their own
# lists beside games/, which this function never touches.
#
# Top-level (not nested in main) so the unit tests can drive it against a
# stubbed update_list.
update_warp_game_list() {
    local base_url="${Z2K_WARP_BASE_URL:-https://raw.githubusercontent.com/medvedeff-true/ru-gaming-blocklist/main}"
    local wdir="${ZAPRET2_DIR}/lists/warp"
    local gdir="$wdir/games"
    local idx="$wdir/.games-index.json"
    mkdir -p "$gdir" 2>/dev/null || return 1

    # The index goes through z2k_fetch and NOT update_list: the latter rejects
    # anything starting with `{` as "HTML/JSON, not a list", which is precisely
    # what sources.json is.
    if ! z2k_fetch "$base_url/sources.json" "$idx" 2>/dev/null || [ ! -s "$idx" ]; then
        log_msg "FAIL: warp games index unavailable — keeping current lists"
        return 1
    fi

    # Names come from the index rather than a hardcoded list, so a game added
    # upstream shows up without a z2k release. game_map's values are arrays and
    # never objects, so [^}] stops exactly at the end of that map. Upstream keeps
    # spaces in some keys but underscores in the filenames.
    local names
    names=$(tr -d '\n' < "$idx" \
        | sed -n 's/.*"game_map"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
        | grep -oE '"[^"]+"[[:space:]]*:' \
        | sed 's/^"//; s/"[[:space:]]*:$//' \
        | tr ' ' '_')
    if [ -z "$names" ]; then
        log_msg "FAIL: warp games index has no game_map — keeping current lists"
        return 1
    fi

    local n rc raw san ok=0 skipped=0
    for n in $names; do
        # Deliberately not shipped: a catch-all bucket nobody asked for.
        [ "$n" = "Other_Games" ] && continue
        # Same charset the panel enforces — the name becomes a filename.
        case "$n" in
            ''|.*|-*) continue ;;
            *[!A-Za-z0-9._-]*) continue ;;
        esac

        raw="$gdir/.$n.raw"
        update_list "warp-game-$n" "$base_url/games/$n.txt" "$raw"
        rc=$?
        # 0 = unchanged, 2 = updated, 1 = failed. A game named in the index but
        # not yet published as a file 404s here — normal (upstream has three such
        # today) and must not abort the rest.
        if [ "$rc" = "1" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Sanitize even when unchanged: games/ is not preserved across a
        # reinstall, so the .txt can be missing while the raw is still cached.
        san="$gdir/.$n.san"
        if ! awk '
# --- z2k warp address filter (canonical; keep byte-identical in all 3 copies) ---
function z2k_warp_addr_ok(s,   ip, h, o) {
    if (s !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/) return 0
    ip = s
    if (split(s, h, "/") == 2) ip = h[1]
    # No width cap. There was one at /10, on the reasoning that no game lives on
    # a /8 — but the blocks it cut are 3.0.0.0/8 and 15.0.0.0/8, i.e. Amazon,
    # which is exactly what people switch WARP on for. /0 is still impossible:
    # the grammar above only accepts prefixes 1-32.
    split(ip, o, ".")
    if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return 0
    if (o[1] == 10 || o[1] == 127 || o[1] >= 224) return 0
    if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 0
    if (o[1] == 169 && o[2] == 254) return 0
    if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 0
    if (o[1] == 192 && o[2] == 168) return 0
    if (o[1] == 192 && o[2] == 0 && (o[3] == 0 || o[3] == 2)) return 0
    if (o[1] == 198 && (o[2] == 18 || o[2] == 19)) return 0
    if (o[1] == 198 && o[2] == 51 && o[3] == 100) return 0
    if (o[1] == 203 && o[2] == 0 && o[3] == 113) return 0
    return 1
}
# --- end z2k warp address filter ---
            { sub(/\r$/,""); gsub(/^[ \t]+|[ \t]+$/,"") }
            $0=="" || $0 ~ /^#/ { next }
            z2k_warp_addr_ok($0) { print }
        ' "$raw" > "$san" 2>/dev/null; then
            rm -f "$san"; skipped=$((skipped + 1)); continue
        fi
        if [ -s "$san" ]; then
            mv -f "$san" "$gdir/$n.txt" && chmod 644 "$gdir/$n.txt" 2>/dev/null
            ok=$((ok + 1))
        else
            # Everything filtered out, or upstream published an empty file: leave
            # no list rather than an empty one for the panel to show.
            rm -f "$san" "$gdir/$n.txt"
        fi
    done

    log_msg "OK: warp game lists refreshed ($ok lists, $skipped unavailable)"

    # WARP is routing-only — reload the ipset live if the mode is on.
    if [ "$(grep -m1 '^GAME_WARP_ENABLED=' "${ZAPRET2_DIR}/config" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d ' ')" = "1" ] \
       && [ -x "${ZAPRET2_DIR}/z2k-warp.sh" ]; then
        sh "${ZAPRET2_DIR}/z2k-warp.sh" ipset >>"$LOG_FILE" 2>&1
    fi
    return 0
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

    # cdn_ips fetcher удалён 2026-04-27 вместе с cdn_tls профилем.



    # Discord-voice DNS pinning REMOVED (p-57.3). The old feature wrote ~200
    # finland*.discord.media `ip host` records — 78% of Keenetic's 256 static-DNS
    # ceiling — all pointing at one CF edge, for marginal gain (the packet-level
    # desync already carries Discord voice). That bloat starved every other pin
    # (fresh Instagram IPs, the github-raw self-heal) into silent "limit exceeded".
    # One-time cleanup: strip any leftover finland pins, drop the orphaned script +
    # list. Idempotent — a no-op once a router is clean, so it's safe every run.
    if command -v ndmc >/dev/null 2>&1; then
        _dvp_old=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
            | awk '/^ip host/ && $3 ~ /^finland[0-9]+\.discord\.media$/ {print $3" "$4}')
        if [ -n "$_dvp_old" ]; then
            printf '%s\n' "$_dvp_old" | while read -r _dv_h _dv_ip; do
                [ -n "$_dv_h" ] && [ -n "$_dv_ip" ] && \
                    LD_LIBRARY_PATH= ndmc -c "no ip host $_dv_h $_dv_ip" >/dev/null 2>&1
            done
            LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
            log_msg "OK: removed $(printf '%s\n' "$_dvp_old" | grep -c .) legacy Discord-voice DNS pins (feature removed)"
            changes=$((changes + 1))
        fi
    fi
    rm -f "${ZAPRET2_DIR}/lists/flowseal_discord_voice_hosts.txt" \
          "${ZAPRET2_DIR}/z2k-discord-voice-pin.sh" 2>/dev/null

    # Cloudflare canonical IPv4 CIDR list. Source: cloudflare.com/ips-v4
    # (already used by install.sh:step_install_z2k_classify at install-time).
    # Без cron-а файл протухает за месяцы — CF добавляет/убирает диапазоны.
    # Пишем атомарно с базовыми guard'ами: список маленький (~25 строк),
    # поэтому floor=10 и shrink-guard 50% от существующего.
    update_cf_cidrs_v4() {
        local dest="${ZAPRET2_DIR}/lists/cf-cidrs-v4.txt"
        local url="https://www.cloudflare.com/ips-v4"
        local tmp
        tmp=$(mktemp "${dest}.XXXXXX") || return 1
        _etag_prep "$dest" "$tmp"

        if ! z2k_fetch "$url" "$tmp"; then
            log_msg "FAIL: cf_cidrs_v4 download (all mirrors failed)"
            _etag_cleanup "$tmp"
            return 1
        fi

        if [ ! -s "$tmp" ]; then
            log_msg "FAIL: cf_cidrs_v4 empty"
            _etag_cleanup "$tmp"
            return 1
        fi

        sed -i 's/\r$//' "$tmp" 2>/dev/null

        # CF endpoint иногда возвращает HTML-error через CDN — отсекаем.
        if head -8 "$tmp" | grep -qiE '<!doctype|<html|<head|<body|^[[:space:]]*[{[]'; then
            log_msg "FAIL: cf_cidrs_v4 looks like HTML/JSON, not CIDR list"
            _etag_cleanup "$tmp"
            return 1
        fi

        local total_lines cidr_lines
        total_lines=$(grep -cv '^[[:space:]]*$\|^[[:space:]]*#' "$tmp" 2>/dev/null)
        cidr_lines=$(grep -cE '^[[:space:]]*([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?[[:space:]]*$' "$tmp" 2>/dev/null)
        if [ -z "$total_lines" ] || [ "$total_lines" -lt 1 ]; then
            log_msg "FAIL: cf_cidrs_v4 has no content lines"
            _etag_cleanup "$tmp"
            return 1
        fi
        if [ "$((cidr_lines * 100 / total_lines))" -lt 80 ]; then
            log_msg "FAIL: cf_cidrs_v4 CIDR ratio low ($cidr_lines/$total_lines)"
            _etag_cleanup "$tmp"
            return 1
        fi
        # Floor: actual CF list ~17-25 entries; ниже 10 = upstream сломан.
        if [ "$total_lines" -lt 10 ]; then
            log_msg "FAIL: cf_cidrs_v4 too small ($total_lines lines, expected ≥10)"
            _etag_cleanup "$tmp"
            return 1
        fi

        if [ -f "$dest" ] && [ -s "$dest" ]; then
            local old_lines
            old_lines=$(grep -cv '^[[:space:]]*$\|^[[:space:]]*#' "$dest" 2>/dev/null)
            if [ -n "$old_lines" ] && [ "$old_lines" -gt 0 ]; then
                if [ "$((total_lines * 100 / old_lines))" -lt 50 ]; then
                    log_msg "FAIL: cf_cidrs_v4 shrunk >50% ($old_lines → $total_lines), keeping old"
                    _etag_cleanup "$tmp"
                    return 1
                fi
            fi
        fi

        if [ -f "$dest" ] && cmp -s "$tmp" "$dest" 2>/dev/null; then
            _etag_finalize "$tmp" "$dest"
            _etag_cleanup "$tmp"
            return 0
        fi

        mkdir -p "$(dirname "$dest")" 2>/dev/null
        if ! mv -f "$tmp" "$dest"; then
            log_msg "FAIL: cf_cidrs_v4 mv tmp → dest failed"
            _etag_cleanup "$tmp"
            return 1
        fi
        _etag_finalize "$tmp" "$dest"
        log_msg "OK: cf_cidrs_v4 updated ($total_lines lines)"
        return 2
    }
    update_cf_cidrs_v4
    [ $? -eq 2 ] && changes=$((changes + 1))

    update_warp_game_list

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

    # Refresh Instagram/cdninstagram ndmc records from a live DNS lookup on
    # the EU VPS. The script self-skips on non-Keenetic systems, when the
    # user disabled it (Z2K_INSTA_IP_REFRESH=0), or when the user already
    # cleared all insta records via menu [I].
    if [ -x "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" ]; then
        log_msg "Running insta-ip refresh..."
        sh "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" >/dev/null 2>&1 || \
            log_msg "WARN: insta-ip refresh exited non-zero"
    fi

    log_msg "--- Update lists finished ---"
}

# Source-guard: tests set Z2K_UL_SOURCE_ONLY=1 to load the functions
# (update_warp_game_list etc.) without running the full cron cycle.
#
# With no argument this is the nightly cycle, as before. `warp-games` refreshes
# ONLY the per-game WARP lists, and exists so an update can pull them straight
# away: without it a freshly updated router shows an empty WARP page until the
# next nightly run, which is up to a day of "the feature does nothing". Running
# the whole cycle there instead is not an option — it fetches the geosite and
# RKN lists and would stretch every update by minutes for the sake of a couple
# of dozen small files.
if [ -z "${Z2K_UL_SOURCE_ONLY:-}" ]; then
    case "${1:-}" in
        warp-games)
            mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
            update_warp_game_list
            ;;
        ''|all)
            main "$@"
            ;;
        *)
            echo "usage: z2k-update-lists.sh [all|warp-games]" >&2
            exit 1
            ;;
    esac
fi
