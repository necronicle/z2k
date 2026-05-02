#!/bin/sh
# z2k.sh - Bootstrap скрипт для z2k v2.0
# Модульный установщик zapret2 для роутеров Keenetic
# https://github.com/necronicle/z2k

set -e

# ==============================================================================
# КОНСТАНТЫ
# ==============================================================================

Z2K_VERSION="2.0.1"
WORK_DIR="/tmp/z2k"
LIB_DIR="${WORK_DIR}/lib"
# Default branch URL — matches the branch this z2k.sh was fetched from.
# On merge to master this line is updated to master. Overridable via
# GITHUB_RAW env var for cross-branch testing.
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}"

# Экспортировать переменные для использования в функциях
export WORK_DIR
export LIB_DIR
export GITHUB_RAW

# Список модулей для загрузки
MODULES="utils system_init install strategies config config_official webpanel menu"

# ==============================================================================
# ВСТРОЕННЫЕ FALLBACK ФУНКЦИИ
# ==============================================================================
# Минимальные функции для работы до загрузки модулей

print_info() {
    printf "[i] %s\n" "$1"
}

print_success() {
    printf "[[OK]] %s\n" "$1"
}

print_error() {
    printf "[[FAIL]] %s\n" "$1" >&2
}

die() {
    print_error "$1"
    [ -n "$2" ] && exit "$2" || exit 1
}

clear_screen() {
    if [ -t 1 ]; then
        clear 2>/dev/null || printf "\033c"
    fi
}

print_header() {
    printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "  %s\n" "$1"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
}

print_separator() {
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
}

confirm() {
    local prompt=${1:-"Продолжить?"}
    local default=${2:-"Y"}
    local answer=""

    while true; do
        if [ "$default" = "Y" ]; then
            printf "%s [Y/n]: " "$prompt"
        else
            printf "%s [y/N]: " "$prompt"
        fi

        if ! read -r answer </dev/tty; then
            return 1
        fi

        answer=$(printf '%s' "$answer" | tr -d "$(printf '\r\b\177')" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        case "$answer" in
            "")
                [ "$default" = "Y" ] && return 0
                return 1
                ;;
            *[Yy]|*[Yy][Ee][Ss]|*[Дд]|*[Дд][Аа])
                return 0
                ;;
            *[Nn]|*[Nn][Oo]|*[Нн][Ее][Тт])
                return 1
                ;;
            *)
                print_info "Введите y/n"
                ;;
        esac
    done
}

# ==============================================================================
# z2k_fetch — загрузка файла с GitHub через цепочку зеркал.
# ==============================================================================
#
# Российские провайдеры местами режут raw.githubusercontent.com (DNS
# poisoning / SNI block), из-за чего первый curl при установке падает и
# ничего дальше не работает. Обходим тремя зеркалами + DNS-override на
# Keenetic как последним шансом:
#
#   1. raw.githubusercontent.com           — прямой путь, самый свежий
#   2. cdn.jsdelivr.net/gh/<o>/<r>@<br>/<p> — CDN, 12h edge-кеш
#                                            (purge: https://purge.jsdelivr.net/gh/<o>/<r>@<br>/<p>)
#   3. gh-proxy.com/<raw-url>              — reverse-proxy без кеша
#   4. Keenetic-only: nslookup через 8.8.8.8 → `ndmc ip host`, повтор 1+2.
#
# Использование:
#   z2k_fetch "https://raw.githubusercontent.com/owner/repo/branch/path" /tmp/dest
#   z2k_fetch "relative/path"         /tmp/dest   # тогда префикс = $GITHUB_RAW
#
# Возвращает 0 при успехе (файл записан либо 304 Not Modified — кэш
# валиден), 1 — все слои не сработали.
#
# ETag-aware: каждый слой отправляет `If-None-Match: <old_etag>` если
# есть cached etag в `${dest}.etag`. На 304 тело не качается, файл
# остаётся как был — типично ~500ms вместо ~5s на unchanged контент.
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

# Layer 5: DoH (1.1.1.1) + захардкоженные edge-IP пины. Включается
# когда все 4 предыдущих слоя зафейлились — сценарий MTS/мобайл RU
# где TSPU после 31.03.2026 интермиттентно RST'ит TLS handshake'и
# по SNI И отдельно глушит DNS recursive resolver. DoH идёт TLS на
# 1.1.1.1 (Cloudflare DNS), TSPU не видит query payload. --resolve
# пинит connect address на anycast edge IP — TSPU не успевает
# enumerate все anycast endpoint'ы и часть проходит.
#
# IP'ы Fastly/GitHub Pages иногда меняются (~24h окно), поэтому
# здесь несколько IP per host: curl попробует по очереди. Если
# Fastly разом ротанул весь блок — этот слой деградирует, но
# слои 1-4 не должны зафейлиться одновременно с этим (кроме MTS),
# так что на стабильных провайдерах DoH-слой никогда и не вызовут.
#
# Curl ≥ 7.62 нужен для --doh-url. На Entware mips старый curl
# (7.60-) не имеет — graceful: проверяем поддержку при первом вызове
# и кэшируем результат.
_z2k_doh_supported=""
_z2k_doh_check() {
    [ -n "$_z2k_doh_supported" ] && return 0
    if curl --help all 2>/dev/null | grep -q -- "--doh-url"; then
        _z2k_doh_supported=1
    else
        _z2k_doh_supported=0
    fi
    return 0
}
# Resolve a hostname's A records via 1.1.1.1's DoH JSON API. Result
# cached per-host in env vars Z2K_POOL_<sanitized_host> for the rest
# of the install run, so we hit the network at most once per host.
# Returns space-separated IPs on stdout, or non-zero (with no stdout)
# if 1.1.1.1 was unreachable / response unparseable.
#
# Why this exists: hardcoded Fastly/GitHub-Pages pools used to rotate
# every ~24h, and a stale entry caused install fails when the canonical
# anycast IP moved. DoH-resolved pools always reflect current state.
# `1.1.1.1` itself is on Cloudflare-owned infrastructure and its IP
# never rotates, so this layer doesn't recurse into the same problem.
_z2k_resolve_doh_pool() {
    local host="$1"
    local cache_var
    cache_var="Z2K_POOL_$(printf '%s' "$host" | tr -c '[:alnum:]' '_')"
    eval "local cached=\${$cache_var:-}"
    if [ -n "$cached" ]; then printf '%s' "$cached"; return 0; fi
    local resp
    resp=$(curl -sS --max-time 5 \
        "https://1.1.1.1/dns-query?name=${host}&type=A" \
        -H 'accept: application/dns-json' 2>/dev/null) || return 1
    local ips
    ips=$(printf '%s' "$resp" \
          | sed 's/[{},]/\n/g' \
          | sed -n 's/.*"data":"\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)".*/\1/p' \
          | tr '\n' ' ' \
          | sed 's/ *$//')
    [ -z "$ips" ] && return 1
    eval "$cache_var=\"\$ips\"; export $cache_var"
    printf '%s' "$ips"
    return 0
}

_z2k_curl_doh() {
    local url="$1" dest="$2"
    _z2k_doh_check
    [ "$_z2k_doh_supported" = "1" ] || return 1

    # Anycast pools: prefer DoH-resolved (always fresh), fall through
    # to hardcoded fallback if 1.1.1.1 itself is unreachable.
    # Hardcoded pool is verified-working as of 2026-04-26 but rotates.
    local gh_pool raw_pool jsd_pool obj_pool api_pool
    gh_pool=$(_z2k_resolve_doh_pool github.com) \
        || gh_pool="140.82.112.3 140.82.113.3 140.82.114.3 140.82.121.3 140.82.116.3"
    raw_pool=$(_z2k_resolve_doh_pool raw.githubusercontent.com) \
        || raw_pool="185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133"
    jsd_pool=$(_z2k_resolve_doh_pool cdn.jsdelivr.net) \
        || jsd_pool="151.101.1.229 151.101.65.229 151.101.129.229 151.101.193.229"
    obj_pool=$(_z2k_resolve_doh_pool objects.githubusercontent.com) \
        || obj_pool="$raw_pool"
    api_pool=$(_z2k_resolve_doh_pool api.github.com) \
        || api_pool="$gh_pool"

    local resolve_args=""
    add_resolve() {
        local h=$1 ips=$2 ip
        for ip in $ips; do
            resolve_args="$resolve_args --resolve $h:443:$ip"
        done
    }

    case "$url" in
        *raw.githubusercontent.com*)
            add_resolve raw.githubusercontent.com "$raw_pool" ;;
        *cdn.jsdelivr.net*)
            add_resolve cdn.jsdelivr.net "$jsd_pool" ;;
        *gh-proxy.com*)
            : ;;  # gh-proxy.com — small self-hosted, IP-пин нестабилен
        *api.github.com*)
            add_resolve api.github.com "$api_pool" ;;
        https://github.com/*/releases/download/*)
            # Release tarballs: 302 от github.com на objects.githubusercontent.com.
            # Пиним оба домена — иначе TSPU SNI-блок на любом из них режет.
            add_resolve github.com "$gh_pool"
            add_resolve objects.githubusercontent.com "$obj_pool" ;;
    esac

    local hdr_file="${dest}.hdr.$$"
    local tmp_body="${dest}.new.$$"
    local http_status

    # Retry с jitter: TSPU sliding-window после успешных flow часто
    # начинает резaть следующие. Pause между attempt дает state-window
    # expired; чем дальше попытка тем длиннее sleep (3s, 8s, 15s).
    local attempt sleeps='0 3 8'
    for attempt in $sleeps; do
        [ "$attempt" -gt 0 ] && sleep "$attempt"
        http_status=$(curl -sSL --connect-timeout 10 --max-time 180 \
            --doh-url https://1.1.1.1/dns-query $resolve_args \
            -D "$hdr_file" -o "$tmp_body" \
            -w "%{http_code}" "$url" 2>/dev/null)
        case "$http_status" in
            200)
                [ ! -s "$tmp_body" ] && { rm -f "$hdr_file" "$tmp_body"; continue; }
                local new_etag
                new_etag=$(grep -i '^etag:' "$hdr_file" 2>/dev/null | head -1 \
                           | sed 's/^[^:]*:[[:space:]]*//; s/\r$//; s/[[:space:]]*$//')
                mkdir -p "$(dirname "$dest")" 2>/dev/null
                mv -f "$tmp_body" "$dest"
                if [ -n "$new_etag" ]; then printf '%s\n' "$new_etag" > "${dest}.etag"
                else rm -f "${dest}.etag"; fi
                rm -f "$hdr_file"
                return 0 ;;
        esac
        rm -f "$hdr_file" "$tmp_body" 2>/dev/null
    done

    # Если single-shot не пробил (самый частый случай — большой файл,
    # TSPU режет посредине long transfer), fallback на chunked range
    # download. Каждый chunk отдельный TLS handshake → TSPU sliding-
    # window не накапливает state. 500 KB на чанк подобрано так чтобы
    # большинство файлов в repo (~95% < 500 KB) уложились в один chunk
    # и для big snapshot files (RKN/List.txt 1.9 MB) получилось ровно
    # 4 чанка с разумными jitter паузами.
    _z2k_curl_doh_chunked "$url" "$dest" "$resolve_args" && return 0

    return 1
}

# Chunked range-download через DoH+pin. Используется для files >500KB
# когда single-shot DoH через TSPU не доходит до конца.
_z2k_curl_doh_chunked() {
    local url="$1" dest="$2" resolve_args="$3"
    local tmp_body="${dest}.new.$$"
    : > "$tmp_body" || return 1

    local chunk_size=500000
    local offset=0 chunk_count=0 max_chunks=20
    local rc http_status

    while [ "$chunk_count" -lt "$max_chunks" ]; do
        local end=$((offset + chunk_size - 1))
        http_status=$(curl -sSL --connect-timeout 10 --max-time 60 \
            --doh-url https://1.1.1.1/dns-query $resolve_args \
            --range "${offset}-${end}" \
            -o "${tmp_body}.chunk" \
            -w "%{http_code}" "$url" 2>/dev/null)
        case "$http_status" in
            206|200)
                cat "${tmp_body}.chunk" >> "$tmp_body"
                local got
                got=$(wc -c < "${tmp_body}.chunk" 2>/dev/null)
                rm -f "${tmp_body}.chunk"
                [ -z "$got" ] || [ "$got" -lt 1 ] && break
                # Если меньше chunk_size получили — это последний chunk
                if [ "$got" -lt "$chunk_size" ]; then
                    rc=0
                    break
                fi
                offset=$((offset + chunk_size))
                chunk_count=$((chunk_count + 1))
                # Jitter: TSPU sliding-window не накопит state если пауза
                sleep 2
                ;;
            416)
                # Range Not Satisfiable — мы прошли конец файла, всё OK
                rc=0
                rm -f "${tmp_body}.chunk"
                break ;;
            *)
                rm -f "${tmp_body}.chunk"
                rc=1
                break ;;
        esac
    done

    if [ "${rc:-1}" = "0" ] && [ -s "$tmp_body" ]; then
        mkdir -p "$(dirname "$dest")" 2>/dev/null
        mv -f "$tmp_body" "$dest"
        rm -f "${dest}.etag"  # chunked download leaves no per-file etag
        return 0
    fi
    rm -f "$tmp_body" "${tmp_body}.chunk" 2>/dev/null
    return 1
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

    # Derive jsdelivr + gh-proxy mirror URLs. Coverage:
    #   raw.githubusercontent.com — full mirroring via jsdelivr CDN +
    #     gh-proxy reverse proxy.
    #   github.com/<o>/<r>/releases/download/<tag>/<asset> — gh-proxy
    #     handles release-asset downloads too (tarballs, binaries).
    #     jsdelivr does NOT mirror release assets, only repo files.
    #   api.github.com/* — no public mirrors; relies on layer 4 DNS
    #     override only.
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

    # Helper: any layer-1-4 success resets the DoH fail streak.
    _z2k_fetch_ok() {
        Z2K_FETCH_FAIL_STREAK=0
        export Z2K_FETCH_FAIL_STREAK
        return 0
    }

    # Auto-promote DoH: only when we've fallen through to layer 5
    # at least Z2K_FETCH_DOH_THRESHOLD times in a row (default 2).
    # A single transient layer-1 fail used to flip the install into
    # full-DoH mode for the rest of the run, even if the next file
    # would have come down fine on raw — costing ~10× per file. The
    # streak counter only promotes when DoH is the consistently-needed
    # path, not when it just happened to win once.
    : "${Z2K_FETCH_DOH_THRESHOLD:=2}"
    if [ "${Z2K_FETCH_PREFER_DOH:-0}" = "1" ]; then
        if _z2k_curl_doh "$url" "$dest"; then return 0; fi
        [ -n "$jsdelivr" ] && _z2k_curl_doh "$jsdelivr" "$dest" && return 0
        [ -n "$gh_proxy" ] && _z2k_curl_doh "$gh_proxy" "$dest" && return 0
        # DoH тоже не сработал — на всякий case ещё попробуем normal layers
    fi

    # Каждый слой идёт через _z2k_curl_etag: на unchanged-контент 304 +
    # пустое body ~10× быстрее чем полный GET. Etag sidecar ключован по
    # $dest — переключение зеркала форсирует один full re-fetch
    # (у raw.github и jsdelivr разные etag-ы), это приемлемо.
    if _z2k_curl_etag "$url" "$dest"; then _z2k_fetch_ok; return 0; fi
    [ -n "$jsdelivr" ] && _z2k_curl_etag "$jsdelivr" "$dest" && { _z2k_fetch_ok; return 0; }
    [ -n "$gh_proxy" ] && _z2k_curl_etag "$gh_proxy" "$dest" && { _z2k_fetch_ok; return 0; }

    # All three normal mirrors fell through. This is the signal the user
    # might have a poisoned/blocked channel — but ONE failure can also be
    # transient (api.github.com rate limit, sporadic TCP RST). Bump the
    # streak counter; only the heavyweight fallbacks (Layer 4 ndmc DNS
    # override, Layer 5 DoH) fire after the streak crosses a threshold.
    Z2K_FETCH_FAIL_STREAK=$((${Z2K_FETCH_FAIL_STREAK:-0} + 1))
    export Z2K_FETCH_FAIL_STREAK

    # --- Layer 4: Keenetic DNS override via 8.8.8.8 + ndmc ip host ---
    # Originally added 2026-04-25 for users (e.g. Денис, MTS) where all
    # three direct fetches failed mid-install due to ISP DNS poisoning
    # of github hosts.
    #
    # Gated by Z2K_FETCH_NDMC_THRESHOLD (default 2): a single transient
    # Layer 1-3 fall-through is NOT enough. Pre-gate, one rate-limit on
    # api.github.com would silently inject a permanent `ip host` record
    # into the user's running-config, pinning all their github traffic
    # to a single IP forever (Mark, 2026-04-28). The threshold ensures
    # only sustained inability to reach github triggers DNS override.
    #
    # Records we write are tracked in Z2K_MANAGED_NDMC so install/uninstall
    # can clean them up later, and so a future fix can refresh them when
    # they go stale.
    : "${Z2K_FETCH_NDMC_THRESHOLD:=2}"
    Z2K_MANAGED_NDMC="${Z2K_MANAGED_NDMC:-/opt/zapret2/state/ndmc-managed.txt}"
    if [ "$Z2K_FETCH_FAIL_STREAK" -ge "$Z2K_FETCH_NDMC_THRESHOLD" ] && \
       command -v ndmc >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
        local resolved_any=0 host ip
        mkdir -p "$(dirname "$Z2K_MANAGED_NDMC")" 2>/dev/null
        for host in raw.githubusercontent.com cdn.jsdelivr.net gh-proxy.com api.github.com; do
            ip=$(nslookup "$host" 8.8.8.8 2>/dev/null \
                 | awk '/^Name:/ {s=1; next} s && /^Address [0-9]+: [0-9]+\./ {print $3; exit}')
            if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "8.8.8.8" ]; then
                if ndmc -c "ip host $host $ip" >/dev/null 2>&1; then
                    resolved_any=1
                    printf '%s %s\n' "$host" "$ip" >> "$Z2K_MANAGED_NDMC" 2>/dev/null
                fi
            fi
        done
        if [ "$resolved_any" = "1" ]; then
            sleep 1
            if _z2k_curl_etag "$url" "$dest"; then _z2k_fetch_ok; return 0; fi
            [ -n "$jsdelivr" ] && _z2k_curl_etag "$jsdelivr" "$dest" && { _z2k_fetch_ok; return 0; }
            [ -n "$gh_proxy" ] && _z2k_curl_etag "$gh_proxy" "$dest" && { _z2k_fetch_ok; return 0; }
        fi
    fi

    # --- Layer 5: DoH (Cloudflare 1.1.1.1) + pinned anycast edge IPs ---
    # Last resort for MTS-style stateful TSPU (post-2026-03-31): RST'ит
    # TLS handshake по SNI + интермиттентно глушит DNS resolver.
    # DoH bypasses MTS resolver entirely; --resolve to anycast edge IP
    # pool side-steps SNI-based connect blocks. Requires curl ≥ 7.62.
    #
    # The streak counter is now bumped at the Layer 1-3 fall-through
    # site above, so by the time DoH succeeds we already know how many
    # files have completely fallen through. Promote PREFER_DOH only when
    # the threshold is met — same semantics as before, just without the
    # extra bump that double-counted DoH wins.
    _z2k_doh_won() {
        if [ "${Z2K_FETCH_FAIL_STREAK:-0}" -ge "${Z2K_FETCH_DOH_THRESHOLD:-2}" ]; then
            Z2K_FETCH_PREFER_DOH=1
            export Z2K_FETCH_PREFER_DOH
        fi
    }
    if _z2k_curl_doh "$url" "$dest"; then _z2k_doh_won; return 0; fi
    if [ -n "$jsdelivr" ] && _z2k_curl_doh "$jsdelivr" "$dest"; then _z2k_doh_won; return 0; fi
    if [ -n "$gh_proxy" ] && _z2k_curl_doh "$gh_proxy" "$dest"; then _z2k_doh_won; return 0; fi

    return 1
}

# ==============================================================================
# ПРОВЕРКИ ОКРУЖЕНИЯ
# ==============================================================================

z2k_detect_entware_arch() {
    local opkg_bin="opkg"
    [ -x /opt/bin/opkg ] && opkg_bin="/opt/bin/opkg"
    command -v "$opkg_bin" >/dev/null 2>&1 || return 1

    "$opkg_bin" print-architecture 2>/dev/null | awk '
        $1 == "arch" && $2 != "all" {
            prio = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
            if (prio >= max) { max = prio; arch = $2 }
        }
        END { if (arch != "") print arch }
    '
}

# ВНИМАНИЕ: эта функция дублирует map_arch_to_bin_arch из utils.sh
# Дубликат необходим т.к. вызывается до загрузки модулей.
# При изменении — синхронизировать с lib/utils.sh:map_arch_to_bin_arch()
z2k_map_arch_to_bin_arch() {
    case "$1" in
        aarch64|arm64|*aarch64*|*arm64*) echo "linux-arm64" ;;
        armv7l|armv6l|arm|*armv7*|*armv6*|arm*) echo "linux-arm" ;;
        x86_64|amd64|*x86_64*|*amd64*) echo "linux-x86_64" ;;
        i386|i486|i586|i686|x86) echo "linux-x86" ;;
        *mipsel64*|*mips64el*) echo "linux-mipsel" ;;
        *mips64*) echo "linux-mips64" ;;
        *mipsel*) echo "linux-mipsel" ;;
        *mips*) echo "linux-mips" ;;
        *lexra*) echo "linux-lexra" ;;
        *ppc*) echo "linux-ppc" ;;
        *riscv64*) echo "linux-riscv64" ;;
        *) return 1 ;;
    esac
}

check_environment() {
    print_info "Проверка окружения..."

    # Проверка Entware
    if [ ! -d "/opt" ] || [ ! -x "/opt/bin/opkg" ]; then
        die "Entware не установлен! Установите Entware перед запуском z2k."
    fi

    # Проверка curl
    if ! command -v curl >/dev/null 2>&1; then
        print_info "curl не найден, устанавливаю..."
        /opt/bin/opkg update || die "Не удалось обновить opkg"
        /opt/bin/opkg install curl || die "Не удалось установить curl"
    fi

    # Проверка архитектуры
    local arch entware_arch bin_arch
    entware_arch=$(z2k_detect_entware_arch)
    arch="${entware_arch:-$(uname -m)}"
    # uname -m returns "mips" for both mips and mipsel — detect endianness from ELF
    if [ "$arch" = "mips" ]; then
        local _ebin=""
        for _f in /opt/bin/opkg /opt/bin/busybox; do [ -f "$_f" ] && _ebin="$_f" && break; done
        if [ -n "$_ebin" ]; then
            local _byte
            _byte=$(dd if="$_ebin" bs=1 skip=5 count=1 2>/dev/null)
            [ "$_byte" = "$(printf '\x01')" ] && arch="mipsel"
        fi
    fi
    bin_arch=$(z2k_map_arch_to_bin_arch "$arch" 2>/dev/null || true)
    [ -n "$bin_arch" ] && print_info "Detected architecture: $arch -> $bin_arch"

    if [ -z "$bin_arch" ]; then
        print_info "ВНИМАНИЕ: z2k разработан для ARM64 Keenetic"
        print_info "Ваша архитектура: $arch"
        printf "Продолжить? [y/N]: "
        read -r answer </dev/tty
        [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "Отменено пользователем" 0
    fi

    print_success "Окружение проверено"
}

# ==============================================================================
# ЗАГРУЗКА МОДУЛЕЙ
# ==============================================================================

download_modules() {
    print_info "Загрузка модулей z2k..."

    # Создать директории
    mkdir -p "$LIB_DIR" || die "Не удалось создать $LIB_DIR"

    # Скачать каждый модуль
    for module in $MODULES; do
        local url="${GITHUB_RAW}/lib/${module}.sh"
        local output="${LIB_DIR}/${module}.sh"

        print_info "Загрузка lib/${module}.sh..."

        if z2k_fetch "$url" "$output"; then
            print_success "Загружен: ${module}.sh"
        else
            die "Ошибка загрузки модуля: ${module}.sh"
        fi
    done

    print_success "Все модули загружены"
}

source_modules() {
    print_info "Загрузка модулей в память..."

    for module in $MODULES; do
        local module_file="${LIB_DIR}/${module}.sh"

        if [ -f "$module_file" ]; then
            . "$module_file" || die "Ошибка загрузки модуля: ${module}.sh"
        else
            die "Модуль не найден: ${module}.sh"
        fi
    done

    print_success "Модули загружены"
}

# ==============================================================================
# ЗАГРУЗКА СТРАТЕГИЙ
# ==============================================================================

download_strategies_source() {
    print_info "Загрузка файла стратегий (strats_new2.txt)..."

    local url="${GITHUB_RAW}/strats_new2.txt"
    local output="${WORK_DIR}/strats_new2.txt"

    if z2k_fetch "$url" "$output"; then
        local lines
        lines=$(wc -l < "$output")
        print_success "Загружено: strats_new2.txt ($lines строк)"
    else
        die "Ошибка загрузки strats_new2.txt"
    fi

    print_info "Загрузка QUIC стратегий (quic_strats.ini)..."
    local quic_url="${GITHUB_RAW}/quic_strats.ini"
    local quic_output="${WORK_DIR}/quic_strats.ini"

    if z2k_fetch "$quic_url" "$quic_output"; then
        local lines
        lines=$(wc -l < "$quic_output")
        print_success "Загружено: quic_strats.ini ($lines строк)"
    else
        die "Ошибка загрузки quic_strats.ini"
    fi
}

download_fake_blobs() {
    print_info "Загрузка fake blobs (TLS + QUIC)..."

    local fake_dir="${WORK_DIR}/files/fake"
    mkdir -p "$fake_dir" || die "Не удалось создать $fake_dir"

    # Sync с фактическим files/fake/ — sberbank_ru и quic_initial_google_com
    # удалены в audit-cleanup 2026-05-02 (commit bb80855), список выровнен.
    local files="
tls_clienthello_max_ru.bin
tls_clienthello_14.bin
tls_clienthello_www_google_com.bin
tls_clienthello_www_onetrust_com.bin
tls_clienthello_activated.bin
tls_clienthello_4pda_to.bin
tls_clienthello_vk_com.bin
tls_clienthello_gosuslugi_ru.bin
t2.bin
syn_packet.bin
stun.bin
http_iana_org.bin
quic_initial_www_google_com.bin
quic_initial_rutracker_org.bin
quic_initial_dbankcloud_ru.bin
quic_initial_ozon_ru.bin
quic_1.bin
quic_4.bin
quic_5.bin
quic_6.bin
quic_test_00.bin
zero_256.bin
"

    while read -r file; do
        [ -z "$file" ] && continue
        local url="${GITHUB_RAW}/files/fake/${file}"
        local output="${fake_dir}/${file}"
        if z2k_fetch "$url" "$output"; then
            print_success "Загружено: files/fake/${file}"
        else
            die "Ошибка загрузки files/fake/${file}"
        fi
    done <<EOF
$files
EOF
}

download_init_script() {
    print_info "Загрузка вспомогательных файлов (init + lua helpers)..."

    local files_dir="${WORK_DIR}/files"
    mkdir -p "$files_dir" || die "Не удалось создать $files_dir"

    local url
    local output

    url="${GITHUB_RAW}/files/S99zapret2.new"
    output="${files_dir}/S99zapret2.new"

    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/S99zapret2.new"
    else
        die "Ошибка загрузки files/S99zapret2.new"
    fi

    url="${GITHUB_RAW}/files/000-zapret2.sh"
    output="${files_dir}/000-zapret2.sh"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/000-zapret2.sh"
    else
        die "Ошибка загрузки files/000-zapret2.sh"
    fi

    url="${GITHUB_RAW}/files/z2k-blocked-monitor.sh"
    output="${files_dir}/z2k-blocked-monitor.sh"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/z2k-blocked-monitor.sh"
    else
        die "Ошибка загрузки files/z2k-blocked-monitor.sh"
    fi

    # z2k tools (healthcheck, config validator, list updater, diagnostics, geosite, tg watchdog)
    for tool_name in z2k-healthcheck.sh z2k-config-validator.sh z2k-update-lists.sh z2k-fix-tg-iptables.sh z2k-diag.sh z2k-geosite.sh z2k-tg-watchdog.sh z2k-probe.sh z2k-classify-drift.sh z2k-classify-inject.sh; do
        url="${GITHUB_RAW}/files/${tool_name}"
        output="${files_dir}/${tool_name}"
        if z2k_fetch "$url" "$output"; then
            print_success "Загружено: files/${tool_name}"
        else
            print_warning "Не удалось загрузить files/${tool_name} (необязательный)"
        fi
    done

    # init scripts extracted from install.sh heredocs — tg-tunnel S98
    # autostart gets installed into /opt/etc/init.d/ later by lib/install.sh
    mkdir -p "${files_dir}/init.d"
    url="${GITHUB_RAW}/files/init.d/S98tg-tunnel"
    output="${files_dir}/init.d/S98tg-tunnel"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/init.d/S98tg-tunnel"
    else
        print_warning "Не удалось загрузить files/init.d/S98tg-tunnel (TG tunnel не будет автостартовать после ребута)"
    fi

    # Keenetic NDM netfilter.d hook for auto-restoring TG REDIRECT rules.
    mkdir -p "${files_dir}/ndm"
    url="${GITHUB_RAW}/files/ndm/90-z2k-tg-redirect.sh"
    output="${files_dir}/ndm/90-z2k-tg-redirect.sh"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/ndm/90-z2k-tg-redirect.sh"
    else
        print_warning "Не удалось загрузить ndm hook (iptables не будут авто-восстанавливаться)"
    fi

    # Web panel source tree — downloaded only if user installs via menu [P].
    # z2k.sh bootstraps files into /tmp/z2k/; install.sh copies from /tmp/z2k/webpanel.
    local webpanel_dir="${WORK_DIR}/webpanel"
    mkdir -p "$webpanel_dir/cgi" "$webpanel_dir/www" "$webpanel_dir/init.d"
    for wp_file in \
        install.sh uninstall.sh lighttpd.conf \
        init.d/S96z2k-webpanel \
        cgi/api.sh cgi/auth.sh cgi/actions.sh \
        www/index.html www/app.js www/style.css www/favicon.svg
    do
        url="${GITHUB_RAW}/webpanel/${wp_file}"
        output="${webpanel_dir}/${wp_file}"
        if z2k_fetch "$url" "$output"; then
            : # ok
        else
            print_warning "Не удалось загрузить webpanel/${wp_file} (опциональный компонент)"
        fi
    done

    # z2k Lua helpers (e.g., persistent autocircular strategy memory)
    local lua_dir="${files_dir}/lua"
    mkdir -p "$lua_dir" || die "Не удалось создать $lua_dir"

    # z2k-detectors.lua must be downloaded (and later loaded by nfqws2) BEFORE
    # z2k-autocircular.lua — the rotator resolves failure_detector= by global
    # name, and detectors live there after the Phase 4 module split.
    url="${GITHUB_RAW}/files/lua/z2k-detectors.lua"
    output="${lua_dir}/z2k-detectors.lua"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/lua/z2k-detectors.lua"
    else
        die "Ошибка загрузки files/lua/z2k-detectors.lua"
    fi

    # Phase 6: anti-ТСПУ fool extensions (z2k_dynamic_ttl and friends).
    # Strategies reference them by name via `fool=z2k_dynamic_ttl`, so the
    # file must be downloaded before strategies load — ordering mirrors
    # z2k-detectors.lua above.
    url="${GITHUB_RAW}/files/lua/z2k-fooling-ext.lua"
    output="${lua_dir}/z2k-fooling-ext.lua"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/lua/z2k-fooling-ext.lua"
    else
        die "Ошибка загрузки files/lua/z2k-fooling-ext.lua"
    fi

    # Phase 7: per-connection range randomisation for numeric strategy
    # args. Wraps fake/multisplit/fakedsplit/fakeddisorder/hostfakesplit
    # and resolves ranges like repeats=2-6 to sticky per-flow values.
    url="${GITHUB_RAW}/files/lua/z2k-range-rand.lua"
    output="${lua_dir}/z2k-range-rand.lua"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/lua/z2k-range-rand.lua"
    else
        die "Ошибка загрузки files/lua/z2k-range-rand.lua"
    fi

    url="${GITHUB_RAW}/files/lua/z2k-autocircular.lua"
    output="${lua_dir}/z2k-autocircular.lua"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/lua/z2k-autocircular.lua"
    else
        die "Ошибка загрузки files/lua/z2k-autocircular.lua"
    fi

    url="${GITHUB_RAW}/files/lua/z2k-modern-core.lua"
    output="${lua_dir}/z2k-modern-core.lua"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/lua/z2k-modern-core.lua"
    else
        die "Ошибка загрузки files/lua/z2k-modern-core.lua"
    fi

    # z2k-http-strats.lua: 33 z2k_http_* функций для http_rkn arm (strategies
    # 8..40). Без них daemon не парсит config-строку и не стартует — same
    # Без него daemon не парсит config-строку и не стартует.
    url="${GITHUB_RAW}/files/lua/z2k-http-strats.lua"
    output="${lua_dir}/z2k-http-strats.lua"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/lua/z2k-http-strats.lua"
    else
        die "Ошибка загрузки files/lua/z2k-http-strats.lua"
    fi

    # z2k-classify generator dynamic-strategy handler. Pre-installed
    # --lua-desync=z2k_dynamic_strategy:strategy=200 in rkn_tcp / google_tls
    # blocks references this global; nfqws2 fails to parse the
    # strategy table if the file is missing.
    url="${GITHUB_RAW}/files/lua/z2k-dynamic-strategy.lua"
    output="${lua_dir}/z2k-dynamic-strategy.lua"
    if z2k_fetch "$url" "$output"; then
        print_success "Загружено: files/lua/z2k-dynamic-strategy.lua"
    else
        die "Ошибка загрузки files/lua/z2k-dynamic-strategy.lua"
    fi
    # Snapshot domain lists used by local install flow (no external list repos)
    local list_file
    local lists_dir="${files_dir}/lists"
    mkdir -p "$lists_dir" || die "Не удалось создать $lists_dir"

    local list_files="
extra_strats/TCP/YT/List.txt
extra_strats/TCP/RKN/List.txt
extra_strats/TCP/RKN/Discord.txt
extra_strats/UDP/YT/List.txt
game_ips.txt
roblox_ips.txt
flowseal_game_ips.txt
extra-domains.txt
"

    while read -r list_file; do
        [ -z "$list_file" ] && continue
        local list_url="${GITHUB_RAW}/files/lists/${list_file}"
        local list_out="${lists_dir}/${list_file}"
        mkdir -p "$(dirname "$list_out")"

        if z2k_fetch "$list_url" "$list_out"; then
            print_success "Загружено: files/lists/${list_file}"
        else
            die "Ошибка загрузки files/lists/${list_file}"
        fi
    done <<EOF
$list_files
EOF
}

generate_strategies_database() {
    print_info "Генерация базы стратегий (strategies.conf)..."

    # Эта функция определена в lib/strategies.sh
    if command -v generate_strategies_conf >/dev/null 2>&1; then
        generate_strategies_conf "${WORK_DIR}/strats_new2.txt" "${WORK_DIR}/strategies.conf" || \
            die "Ошибка генерации strategies.conf"

        local count
        count=$(wc -l < "${WORK_DIR}/strategies.conf" | tr -d ' ')
        print_success "Сгенерировано стратегий: $count"
    else
        die "Функция generate_strategies_conf не найдена"
    fi

    print_info "Генерация базы QUIC стратегий (quic_strategies.conf)..."
    if command -v generate_quic_strategies_conf >/dev/null 2>&1; then
        generate_quic_strategies_conf "${WORK_DIR}/quic_strats.ini" "${WORK_DIR}/quic_strategies.conf" || \
            die "Ошибка генерации quic_strategies.conf"
    else
        die "Функция generate_quic_strategies_conf не найдена"
    fi
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ BOOTSTRAP
# ==============================================================================

show_welcome() {
    clear_screen

    cat <<EOF
+===================================================+
|          z2k - Zapret2 для Keenetic               |
|                   Версия $Z2K_VERSION                    |
+===================================================+

  GitHub: https://github.com/necronicle/z2k

EOF

    print_info "Инициализация..."
}

prompt_install_or_menu() {
    printf "\n"

    if is_zapret2_installed; then
        print_info "Открываю меню управления..."
        sleep 1
        show_main_menu
    else
        print_info "zapret2 не установлен - запускаю установку..."
        check_root || die "Требуются права root для установки"
        run_full_install
        print_info "Открываю меню управления..."
        sleep 1
        show_main_menu
    fi
}


# ==============================================================================
# ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ==============================================================================

handle_arguments() {
    local command=$1

    case "$command" in
        install|i)
            print_info "Запуск установки zapret2..."
            run_full_install
            print_info "Открываю меню управления..."
            sleep 1
            show_main_menu
            ;;
        menu|m)
            print_info "Открытие меню..."
            show_main_menu
            ;;
        uninstall|remove)
            print_info "Удаление zapret2..."
            uninstall_zapret2
            ;;
        status|s)
            show_system_info
            ;;
        update|u)
            print_info "Обновление z2k..."
            update_z2k
            ;;
        version|v)
            echo "z2k v${Z2K_VERSION}"
            echo "zapret2: $(get_nfqws2_version)"
            ;;
        cleanup)
            print_info "Очистка старых бэкапов..."
            cleanup_backups "${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}" 5
            ;;
        check|info)
            print_info "Проверка активной конфигурации..."
            show_active_processing
            ;;
        rollback)
            print_info "Откат конфигурации..."
            rollback_to_snapshot
            ;;
        snapshot)
            print_info "Создание snapshot конфигурации..."
            create_rollback_snapshot "cli"
            ;;
        healthcheck|hc)
            if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/z2k-healthcheck.sh" ]; then
                sh "${ZAPRET2_DIR:-/opt/zapret2}/z2k-healthcheck.sh" --status
            else
                print_error "Скрипт healthcheck не найден"
            fi
            ;;
        validate)
            if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/z2k-config-validator.sh" ]; then
                sh "${ZAPRET2_DIR:-/opt/zapret2}/z2k-config-validator.sh"
            else
                print_error "Скрипт валидатора не найден"
            fi
            ;;
        diag|d)
            if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/z2k-diag.sh" ]; then
                sh "${ZAPRET2_DIR:-/opt/zapret2}/z2k-diag.sh"
            else
                print_error "Скрипт диагностики не найден"
            fi
            ;;
        probe|p)
            if [ -f "${ZAPRET2_DIR:-/opt/zapret2}/z2k-probe.sh" ]; then
                shift
                sh "${ZAPRET2_DIR:-/opt/zapret2}/z2k-probe.sh" "$@"
            else
                print_error "Скрипт active probe не найден"
            fi
            ;;
        classify|c)
            # z2k classify <domain> [--apply|--dry-run|--json|--verbose]
            # Wraps the C-based block-type classifier installed by
            # step_install_z2k_classify. Logs invocation to /opt/var/log/
            # for the Phase 4 nightly drift detector to consume.
            if [ -x "${ZAPRET2_DIR:-/opt/zapret2}/z2k-classify" ]; then
                shift
                local _classify_log="/opt/var/log/z2k-classify.log"
                mkdir -p "$(dirname "$_classify_log")" 2>/dev/null || true
                printf '%s | invoke %s\n' "$(date -Iseconds 2>/dev/null || date)" "$*" \
                    >> "$_classify_log" 2>/dev/null || true
                "${ZAPRET2_DIR:-/opt/zapret2}/z2k-classify" "$@"
                local _rc=$?
                printf '%s | exit %d args=%s\n' "$(date -Iseconds 2>/dev/null || date)" "$_rc" "$*" \
                    >> "$_classify_log" 2>/dev/null || true
                exit $_rc
            else
                print_error "z2k-classify не найден (rolling release ещё не создан или install неполный)"
                exit 1
            fi
            ;;
        help|h|-h|--help)
            show_help
            ;;
        "")
            # Без аргументов - показать welcome и предложить установку
            prompt_install_or_menu
            ;;
        *)
            print_error "Неизвестная команда: $command"
            show_help
            exit 1
            ;;
    esac
}

show_help() {
    cat <<EOF
Использование: sh z2k.sh [команда]

Команды:
  install, i       Установить zapret2
  menu, m          Открыть интерактивное меню
  uninstall        Удалить zapret2
  status, s        Показать статус системы
  check, info      Показать какие списки обрабатываются
  update, u        Обновить z2k до последней версии
  cleanup          Очистить старые бэкапы (оставить 5 последних)
  rollback         Откатить конфигурацию к последнему snapshot
  snapshot         Создать snapshot текущей конфигурации
  healthcheck, hc  Проверить работоспособность DPI bypass
  validate         Валидация текущей конфигурации
  diag, d          Сводка для траблшутинга (скопируй вывод и пришли в чат)
  probe, p <host>  Подбор стратегии под конкретный домен (полный rotator)
  classify, c <host> [--apply]
                   Определить тип DPI-блока для домена и (с --apply)
                   найти+пинить рабочую стратегию из template'a (5-30 сек)
  version, v       Показать версию
  help, h          Показать эту справку

Без аргументов:
  - Если zapret2 не установлен: предложит установку
  - Если zapret2 установлен: откроет меню

Примеры:
  curl -fsSL https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k.sh | sh
  z2k menu
  z2k diag
  z2k probe cloudflare.com
  z2k classify linkedin.com --apply
  z2k check

EOF
}

# ==============================================================================
# ФУНКЦИЯ ОБНОВЛЕНИЯ Z2K
# ==============================================================================

update_z2k() {
    print_header "Обновление z2k"

    local latest_url="${GITHUB_RAW}/z2k.sh"
    local current_script
    current_script=$(readlink -f "$0")

    case "$current_script" in
        */sh|*/bash|*/ash|*/dash)
            print_error "Cannot self-update: script was run via pipe. Please download and run directly."
            return 1
            ;;
    esac

    print_info "Текущая версия: $Z2K_VERSION"
    print_info "Загрузка последней версии..."

    # Скачать новую версию во временный файл
    local temp_file
    temp_file=$(mktemp)

    if z2k_fetch "$latest_url" "$temp_file"; then
        # Получить версию из нового файла
        local new_version
        new_version=$(grep '^Z2K_VERSION=' "$temp_file" | cut -d'"' -f2)

        if [ "$new_version" = "$Z2K_VERSION" ]; then
            print_success "У вас уже последняя версия: $Z2K_VERSION"
            rm -f "$temp_file"
            return 0
        fi

        print_info "Новая версия: $new_version"

        # Создать backup текущего скрипта
        if [ -f "$current_script" ]; then
            cp "$current_script" "${current_script}.backup" || {
                print_error "Не удалось создать backup"
                rm -f "$temp_file"
                return 1
            }
        fi

        # Заменить скрипт
        mv "$temp_file" "$current_script" && chmod +x "$current_script"

        print_success "z2k обновлен: $Z2K_VERSION → $new_version"
        print_info "Backup сохранен: ${current_script}.backup"

        # Update Telegram tunnel support files even when the tunnel is
        # currently disabled. Old installed S98tg-tunnel scripts ignored
        # TG_PROXY_USER_DISABLED and could resurrect the tunnel on reboot.
        mkdir -p /opt/etc/init.d /opt/etc/ndm/netfilter.d /opt/zapret2
        local tg_support_tmp
        tg_support_tmp=$(mktemp)
        if z2k_fetch "${GITHUB_RAW}/files/init.d/S98tg-tunnel" "$tg_support_tmp"; then
            cp "$tg_support_tmp" /opt/etc/init.d/S98tg-tunnel
            chmod +x /opt/etc/init.d/S98tg-tunnel
            print_success "S98tg-tunnel обновлён"
        else
            print_warning "Не удалось обновить S98tg-tunnel"
        fi
        rm -f "$tg_support_tmp"

        tg_support_tmp=$(mktemp)
        if z2k_fetch "${GITHUB_RAW}/files/z2k-tg-watchdog.sh" "$tg_support_tmp"; then
            cp "$tg_support_tmp" /opt/zapret2/tg-tunnel-watchdog.sh
            chmod +x /opt/zapret2/tg-tunnel-watchdog.sh
            crontab -l 2>/dev/null | grep -q "tg-tunnel-watchdog" || \
                { crontab -l 2>/dev/null || true; echo '* * * * * /opt/zapret2/tg-tunnel-watchdog.sh'; } | crontab -
            print_success "Watchdog обновлён"
        else
            print_warning "Не удалось обновить watchdog"
        fi
        rm -f "$tg_support_tmp"

        tg_support_tmp=$(mktemp)
        if z2k_fetch "${GITHUB_RAW}/files/ndm/90-z2k-tg-redirect.sh" "$tg_support_tmp"; then
            cp "$tg_support_tmp" /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh
            chmod +x /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh
            print_success "NDM hook обновлён"
        else
            print_warning "Не удалось обновить NDM hook"
        fi
        rm -f "$tg_support_tmp"

        local _tg_disabled_update=0
        if [ -f "/opt/zapret2/config" ]; then
            _tg_disabled_update=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' /opt/zapret2/config)
        fi
        if [ "$_tg_disabled_update" = "1" ]; then
            if [ -x /opt/etc/init.d/S98tg-tunnel ]; then
                /opt/etc/init.d/S98tg-tunnel stop >/dev/null 2>&1
            else
                killall tg-mtproxy-client 2>/dev/null || true
            fi
        fi
        if [ -x /opt/etc/init.d/S97tg-mtproxy ]; then
            /opt/etc/init.d/S97tg-mtproxy stop >/dev/null 2>&1 || true
        fi
        rm -f /opt/etc/init.d/S97tg-mtproxy 2>/dev/null
        crontab -l 2>/dev/null | grep -v "S97tg-mtproxy" | crontab - 2>/dev/null || true

        # Update Telegram tunnel binary
        if [ -x "/opt/sbin/tg-mtproxy-client" ]; then
            print_info "Обновление Telegram tunnel..."
            local tg_arch=""
            local _arch _earch _barch
            _earch=$(z2k_detect_entware_arch)
            _arch="${_earch:-$(uname -m)}"
            _barch=$(z2k_map_arch_to_bin_arch "$_arch" 2>/dev/null || true)
            case "$_barch" in
                linux-arm64)    tg_arch="arm64" ;;
                linux-arm)      tg_arch="arm" ;;
                linux-mipsel)   tg_arch="mipsel" ;;
                linux-mips64el) tg_arch="mips64el" ;;
                linux-mips64)   tg_arch="mips" ;;
                linux-mips)     tg_arch="mips" ;;
                linux-x86_64)   tg_arch="amd64" ;;
                linux-x86)      tg_arch="x86" ;;
                linux-riscv64)  tg_arch="riscv64" ;;
                linux-ppc)      tg_arch="ppc64" ;;
            esac
            if [ -n "$tg_arch" ]; then
                local tg_url="${GITHUB_RAW}/mtproxy-client/builds/tg-mtproxy-client-linux-${tg_arch}"
                local tg_tmp
                tg_tmp=$(mktemp)
                if z2k_fetch "$tg_url" "$tg_tmp" && \
                   [ "$(wc -c < "$tg_tmp")" -gt 500000 ] && \
                   head -c 4 "$tg_tmp" 2>/dev/null | grep -q "ELF"; then
                    killall tg-mtproxy-client 2>/dev/null || true
                    sleep 1
                    cp "$tg_tmp" /opt/sbin/tg-mtproxy-client
                    chmod +x /opt/sbin/tg-mtproxy-client
                    # Respect TG_PROXY_USER_DISABLED — if user explicitly stopped
                    # the tunnel via menu/webpanel, don't resurrect it on update.
                    local _tg_disabled=0
                    if [ -f "/opt/zapret2/config" ]; then
                        _tg_disabled=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' /opt/zapret2/config)
                    fi
                    if [ "$_tg_disabled" = "1" ]; then
                        print_success "Telegram tunnel обновлён (не запущен — отключён пользователем)"
                    else
                        if [ -x /opt/etc/init.d/S98tg-tunnel ]; then
                            /opt/etc/init.d/S98tg-tunnel restart >/dev/null 2>&1
                        else
                            /opt/sbin/tg-mtproxy-client --listen=:1443 --timeout=15m -v >> /tmp/tg-tunnel.log 2>&1 &
                        fi
                        sleep 2
                        if pgrep -f "tg-mtproxy-client" >/dev/null 2>&1; then
                            print_success "Telegram tunnel обновлён и перезапущен"
                        else
                            print_warning "Telegram tunnel обновлён, но не запустился"
                        fi
                    fi
                else
                    print_warning "Не удалось обновить Telegram tunnel"
                fi
                rm -f "$tg_tmp"
            fi
        fi

        print_info "Перезапустите z2k для применения изменений"

    else
        print_error "Не удалось загрузить обновление"
        rm -f "$temp_file"
        return 1
    fi
}

# ==============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# ==============================================================================

main() {
    # Early-exit for help/version — no downloads needed
    case "$1" in
        help|h|-h|--help)
            show_help
            exit 0
            ;;
        version|v|--version)
            echo "z2k v${Z2K_VERSION}"
            exit 0
            ;;
    esac

    # Показать приветствие
    show_welcome

    # Проверить окружение
    check_environment

    # Warm-cache fast-path: для non-install/update команд (menu, status,
    # probe, diag, healthcheck, rollback, snapshot, etc.) кэш в /tmp/z2k
    # переиспользуется между run'ами. ETag-свежесть все равно проверится
    # z2k_fetch'ем на download_* если _need_fetch=1, но для интерактивных
    # команд пропускаем fetch'и целиком — typical menu open ~1s вместо
    # ~13s. Install/update/uninstall всегда режут /tmp/z2k для чистоты.
    local _need_fetch=1
    case "${1:-}" in
        install|i|update|u|uninstall|remove)
            # Чистая установка/обновление — обязательно свежие файлы.
            rm -rf "$WORK_DIR"
            ;;
        *)
            # Для интерактивных команд: кэш валиден если ключевые модули
            # и strats в наличии. Если нет — первый run (или после reboot
            # /tmp очищен), качаем всё.
            if [ -f "$LIB_DIR/utils.sh" ] \
               && [ -f "$LIB_DIR/config_official.sh" ] \
               && [ -f "$LIB_DIR/menu.sh" ] \
               && [ -s "$WORK_DIR/strats_new2.txt" ]; then
                _need_fetch=0
            fi
            ;;
    esac
    mkdir -p "$WORK_DIR" "$LIB_DIR"

    # Установить обработчики сигналов (будет переопределено после загрузки utils.sh)
    # Note: trap раньше чистил $WORK_DIR при Ctrl+C, теперь оставляем
    # кэш целым даже при прерывании — если install прервался, следующий
    # `z2k install` сам пересоздаст чистую директорию.
    trap 'echo ""; print_error "Прервано пользователем"; rm -rf /tmp/zapret2_build; exit 130' INT TERM
    trap 'rm -rf /tmp/zapret2_build' EXIT

    # Скачать модули (если нужно — иначе используем кэшированные)
    if [ "$_need_fetch" = "1" ]; then
        download_modules
    fi

    # Загрузить модули в память
    source_modules

    # Теперь доступны все функции из модулей
    # Переустановить обработчики сигналов с правильными функциями
    setup_signal_handlers

    # Инициализировать системные переменные (SYSTEM, UNAME, INIT)
    init_system_vars || die "Ошибка определения типа системы"

    # Инициализация (создание рабочей директории с проверками из utils.sh)
    init_work_dir || die "Ошибка инициализации"

    # Проверить права root (нужно для установки)
    if [ "$1" = "install" ] || [ "$1" = "i" ]; then
        check_root || die "Требуются права root для установки"
    fi

    # Скачать artifacts (strats / fake blobs / init script) — пропускаем
    # на warm cache, kin keeps cached copies intact.
    if [ "$_need_fetch" = "1" ]; then
        download_strategies_source
        download_fake_blobs
        download_init_script
        generate_strategies_database
    fi

    # Обработать аргументы командной строки
    handle_arguments "$@"

    # Очистка при выходе (если не удаляется автоматически)
    # cleanup_work_dir
}

# ==============================================================================
# ЗАПУСК
# ==============================================================================

main "$@"
