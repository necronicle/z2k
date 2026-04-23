#!/bin/sh
# z2k-geosite.sh — fetch runetfreedom/russia-blocked-geosite release
# assets and replace z2k production hostlist files.
#
# Phase 12: real geosite migration. Replaces the earlier Phase 2 v2fly
# staging-only prototype. Pulls plain-text .txt release assets directly
# from github.com/runetfreedom/russia-blocked-geosite/releases/latest,
# which is the same source b4 ships as its "RUNET Freedom recommended"
# GeoSite provider. Lists are auto-updated every 6 hours upstream; we
# refresh daily via z2k-update-lists.sh cron and use ETag negotiation
# to avoid re-downloading unchanged files.
#
# Target production paths (overwrites /opt/zapret2/extra_strats/*):
#
#   RKN TCP  ← ru-blocked.txt or ru-blocked-all.txt (RAM-adaptive)
#   YT TCP   ← youtube.txt
#   YT UDP   ← youtube.txt (same source for TCP and QUIC profiles)
#   Discord  ← discord.txt (writes to TCP_Discord.txt and TCP/RKN/Discord.txt)
#
# On the very first replace the existing file is preserved as
# `<name>.shipped` so you can manually revert with `cp *.shipped <name>`
# and a service restart. No automated rollback UI by design.
#
# RAM-adaptive RKN selection:
#
#   ≥ 400 MB total RAM → ru-blocked-all.txt (~30 MB file, ~700k domains,
#                         maximum coverage, upstream "use with caution")
#   < 400 MB total RAM → ru-blocked.txt (~1.7 MB file, ~80k domains,
#                         curated antifilter-download-community + re:filter)
#
# Tunable via env: Z2K_GEOSITE_RKN_RAM_THRESHOLD_MB (default 400)
# Override fully via env: Z2K_GEOSITE_RKN_ASSET=ru-blocked-all.txt
#
# Usage:
#   z2k-geosite.sh fetch                fetch all, replace production lists
#   z2k-geosite.sh show <asset>         fetch one asset to stdout (no write)
#   z2k-geosite.sh status               show current production line counts
#   z2k-geosite.sh --help
#
# Exit codes:
#   0   all targets fetched and applied (or unchanged via ETag)
#   1   fatal: missing dep, unwritable dir, no previous file AND fetch failed
#   2   partial: some targets updated, others kept previous version

set -u

RELEASE_BASE="${Z2K_GEOSITE_RELEASE_BASE:-https://github.com/runetfreedom/russia-blocked-geosite/releases/latest/download}"
ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
EXTRA="${ZAPRET2_DIR}/extra_strats"
ETAG_DIR="${ZAPRET2_DIR}/extra_strats/cache/geosite-etag"
TMP_DIR="/tmp/z2k-geosite.$$"

# RAM threshold for selecting the big ru-blocked-all list. Set
# conservatively — field testing on a 489 MB router showed nfqws2
# crashing when loading the 1.2M-line ru-blocked-all list. The
# smaller ru-blocked (~80k lines) is safe on sub-gigabyte routers.
# Only routers with ≥900 MB total RAM (typically the 1-2 GB Keenetic
# Ultra/Giga-class) get the maximum-coverage variant automatically.
# Users with medium routers who want more coverage can opt in via
# Z2K_GEOSITE_RKN_RAM_THRESHOLD_MB=500 or similar.
RAM_THRESHOLD_MB="${Z2K_GEOSITE_RKN_RAM_THRESHOLD_MB:-900}"

# Hostlist in nfqws2 loads faster if entries are unique & sorted;
# runetfreedom already guarantees this for YT/Discord but ru-blocked
# has ~0.3% duplicates from source merge. We re-dedupe on write.
DEDUPE_ON_WRITE=1

cleanup() {
    [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

die() {
    echo "z2k-geosite: $1" >&2
    exit 1
}

log() {
    echo "[geosite] $*" >&2
}

ensure_deps() {
    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v awk  >/dev/null 2>&1 || die "awk not found"
    mkdir -p "$TMP_DIR" "$ETAG_DIR" || die "cannot create tmp/etag dirs"
}

# --- RAM-based RKN asset selection ------------------------------------------

pick_rkn_asset() {
    if [ -n "${Z2K_GEOSITE_RKN_ASSET:-}" ]; then
        echo "$Z2K_GEOSITE_RKN_ASSET"
        return
    fi
    local total_kb=0
    if command -v free >/dev/null 2>&1; then
        total_kb=$(free 2>/dev/null | awk '/^Mem:/ {print $2; exit}')
    fi
    case "$total_kb" in
        ''|*[!0-9]*) total_kb=0 ;;
    esac
    local total_mb=$((total_kb / 1024))
    if [ "$total_mb" -ge "$RAM_THRESHOLD_MB" ]; then
        log "RAM ${total_mb} MB ≥ ${RAM_THRESHOLD_MB} MB threshold → ru-blocked-all"
        echo "ru-blocked-all.txt"
    else
        log "RAM ${total_mb} MB < ${RAM_THRESHOLD_MB} MB threshold → ru-blocked"
        echo "ru-blocked.txt"
    fi
}

# --- Download an asset ONCE to a canonical tmp file ------------------------
#
# Downloads $asset to $TMP_DIR/$asset and returns one of:
#   0 — fresh content in tmp file, ready for apply
#   3 — upstream unchanged (304 ETag match); tmp file not present
#   1 — fetch failed; tmp file not present
#
# Because a single asset (e.g. youtube.txt, discord.txt) serves multiple
# production targets, we MUST NOT re-download for each target and we
# MUST NOT let the ETag cache block application to later targets. The
# fetch is cached in TMP_DIR for the lifetime of this script run; apply
# is a separate step that consumes the tmp file for each target.
fetch_to_tmp() {
    local asset="$1"
    local url="$RELEASE_BASE/$asset"
    local etag_file="$ETAG_DIR/${asset}.etag"
    local tmp="$TMP_DIR/$asset"
    local hdr="$TMP_DIR/$asset.hdr"

    # Cached within this run: if we've already populated $tmp successfully,
    # reuse it.
    if [ -s "$tmp" ]; then
        return 0
    fi
    # Cached within this run as 304: marker file tells us not to re-download.
    if [ -f "$TMP_DIR/$asset.304" ]; then
        return 3
    fi

    log "fetch $asset"

    local http
    http=$(curl -sSL --connect-timeout 15 --max-time 600 \
                --etag-compare "$etag_file" \
                --etag-save "$etag_file" \
                -o "$tmp" \
                -D "$hdr" \
                -w '%{http_code}' \
                "$url" 2>/dev/null) || http="000"

    case "$http" in
        200)
            if [ ! -s "$tmp" ]; then
                log "  $asset: HTTP 200 but empty body"
                rm -f "$tmp"
                return 1
            fi
            log "  $asset: HTTP 200, $(wc -c < "$tmp") bytes"
            return 0
            ;;
        304)
            log "  $asset: unchanged (ETag match)"
            rm -f "$tmp"
            : > "$TMP_DIR/$asset.304"
            return 3
            ;;
        *)
            log "  $asset: HTTP $http"
            rm -f "$tmp"
            return 1
            ;;
    esac
}

# --- Fetch + apply to ONE target -------------------------------------------
#
# Args: asset, target
# Returns: 0 applied (new content or unchanged-targets-current), 1 failed
fetch_asset() {
    local asset="$1"
    local target="$2"

    mkdir -p "$(dirname "$target")" 2>/dev/null || true

    fetch_to_tmp "$asset"
    local rc=$?

    if [ "$rc" = "0" ]; then
        # Fresh content in TMP_DIR/$asset — apply to this target
        apply_new_list "$TMP_DIR/$asset" "$target" "$asset"
        return $?
    fi
    if [ "$rc" = "3" ]; then
        # Upstream unchanged. But our target might not yet be populated
        # (first install after cold ETag cache; or upstream ETag matches
        # but our target file was just created/copied from shipped). Two
        # sub-cases:
        #   a) target exists and non-empty → 304 is accurate for this
        #      flow, leave as-is, return 0
        #   b) target missing or empty → we have no local copy, need to
        #      force a re-download. Delete ETag + retry once.
        if [ -s "$target" ]; then
            log "  $asset → $target: unchanged, keep existing"
            return 0
        fi
        log "  $asset → $target: 304 but target empty, forcing re-download"
        rm -f "$ETAG_DIR/${asset}.etag" "$TMP_DIR/$asset.304"
        fetch_to_tmp "$asset"
        rc=$?
        if [ "$rc" = "0" ]; then
            apply_new_list "$TMP_DIR/$asset" "$target" "$asset"
            return $?
        fi
        log "  $asset → $target: retry failed"
        return 1
    fi
    # rc=1 fetch failed, keep previous file if any
    if [ -s "$target" ]; then
        log "  $asset → $target: fetch failed, keeping existing"
        return 0
    fi
    log "  $asset → $target: fetch failed, target empty/missing"
    return 1
}

# Args: $1 new content file, $2 target path, $3 asset name (for log)
apply_new_list() {
    local newf="$1"
    local target="$2"
    local asset="$3"

    # Sanity: reject absurdly small new files that would be a regression.
    # Threshold is 80% of the previous size (if any). Protects against
    # upstream publishing a broken truncated asset.
    if [ -s "$target" ]; then
        local oldsz newsz
        oldsz=$(wc -c < "$target" 2>/dev/null || echo 0)
        newsz=$(wc -c < "$newf" 2>/dev/null || echo 0)
        # Use awk for float math (busybox lacks bc)
        local too_small
        too_small=$(awk -v o="$oldsz" -v n="$newsz" 'BEGIN {
            if (o == 0) { print 0; exit }
            print (n * 100 < o * 80) ? 1 : 0
        }')
        if [ "$too_small" = "1" ]; then
            log "  $asset: new file ${newsz}B < 80% of existing ${oldsz}B — refusing apply"
            return 1
        fi
    fi

    # Normalize + dedupe. Runetfreedom assets use v2fly domain-list
    # prefix format (`domain:`, `full:`, `regexp:`, `keyword:`, optional
    # trailing `@attr` tags). nfqws2 hostlist only understands plain
    # domain lines (suffix match). We strip `domain:`/`full:` to bare
    # domain, drop `regexp:`/`keyword:` (not expressible), clear
    # trailing `@attr`, then sort -u. Without this the daemon parses
    # literal "domain:youtube" strings and matches nothing — which is
    # how the Phase 2 prototype failed live on the test router.
    local final="$TMP_DIR/$asset.normalized"
    awk '
        /^[[:space:]]*#/ { next }
        NF == 0 { next }
        {
            d = $1
            sub(/^domain:/, "", d)
            sub(/^full:/, "", d)
            if (d ~ /^regexp:/) next
            if (d ~ /^keyword:/) next
            # Strip v2fly attribute suffix. The attribute may be
            # preceded by space or colon separator (runetfreedom
            # produces domain:ggpht.cn:@cn format). The colon MUST
            # be consumed or the domain ends up with a trailing
            # colon that nfqws2 will not match on.
            sub(/[[:space:]:]*@[a-zA-Z0-9_.-]+.*$/, "", d)
            if (length(d) > 0 && d ~ /[a-zA-Z0-9]/) print d
        }
    ' "$newf" | sort -u > "$final"

    # First-run backup: save the shipped snapshot next to the target so
    # manual rollback is a one-command cp. Only do this if we don't
    # already have a .shipped backup.
    local shipped="${target}.shipped"
    if [ ! -e "$shipped" ] && [ -s "$target" ]; then
        cp "$target" "$shipped" && log "  $asset: saved shipped backup → ${shipped##*/}"
    fi

    # Atomic rename over target. mv is atomic within same filesystem.
    # nfqws2 re-reads the file only on restart, so no concurrent
    # reader to worry about — but we still want to avoid torn writes
    # if the install script is killed mid-copy.
    local target_tmp="${target}.probe"
    cp "$final" "$target_tmp" && mv "$target_tmp" "$target" \
        || { log "  $asset: failed to write $target"; return 1; }

    local lines
    lines=$(wc -l < "$target" 2>/dev/null || echo 0)
    log "  $asset: applied, $lines lines"
    return 0
}

# --- Subtract YT + googlevideo from RKN list -------------------------------
#
# runetfreedom's ru-blocked / ru-blocked-all lists include YouTube and
# googlevideo domains. config_official.sh chains profiles as
# RKN TCP → YouTube TCP → YouTube GV → QUIC YT, and nfqws2 is first-match-
# wins, so any overlapping domain gets the generic RKN strategy instead of
# the dedicated YT/GV one. We strip YT + googlevideo entries from the RKN
# list after all assets are written so each domain reaches exactly the
# profile it was tuned for.
#
# Matching is suffix-aware: if the YT list contains "youtube.com",
# "m.youtube.com" in RKN is dropped too (nfqws2 hostlist does suffix
# matching, so leaving the child entry in RKN would also be caught by
# RKN first). googlevideo.com is hard-coded because YT GV uses
# --hostlist-domains=googlevideo.com instead of a file.
subtract_yt_from_rkn() {
    local rkn_target="$EXTRA/TCP/RKN/List.txt"
    local yt_target="$EXTRA/TCP/YT/List.txt"

    [ -s "$rkn_target" ] || return 0

    local exclude="$TMP_DIR/rkn.exclude"
    : > "$exclude"
    [ -s "$yt_target" ] && cat "$yt_target" >> "$exclude"

    local before after removed filtered
    before=$(wc -l < "$rkn_target" 2>/dev/null || echo 0)
    filtered="$TMP_DIR/rkn.filtered"

    awk -v excl="$exclude" '
        BEGIN {
            while ((getline line < excl) > 0) {
                sub(/\r$/, "", line)
                if (length(line) > 0) ex[line] = 1
            }
            close(excl)
        }
        {
            d = $0
            sub(/\r$/, "", d)
            if (d == "googlevideo.com") next
            if (d ~ /\.googlevideo\.com$/) next
            tmp = d
            if (tmp in ex) next
            while (sub(/^[^.]*\./, "", tmp)) {
                if (tmp in ex) next
            }
            print d
        }
    ' "$rkn_target" > "$filtered" || {
        log "RKN subtract: awk failed, keeping original list"
        rm -f "$filtered"
        return 1
    }

    after=$(wc -l < "$filtered" 2>/dev/null || echo 0)
    removed=$((before - after))
    if [ "$removed" -gt 0 ]; then
        mv "$filtered" "$rkn_target" || {
            log "RKN subtract: rename failed"
            return 1
        }
        log "RKN: removed $removed YT/googlevideo overlaps ($before → $after lines)"
    else
        rm -f "$filtered"
        log "RKN: no YT/googlevideo overlaps found"
    fi
    return 0
}

# --- Fetch all targets ------------------------------------------------------

fetch_all() {
    ensure_deps

    # --force clears ETag cache before fetch. Used at install time so a
    # reinstall always re-applies the latest upstream even when the
    # router already had a stale ETag pointing to the same upstream
    # version but a different (shipped) local file.
    if [ "${FORCE_REFETCH:-0}" = "1" ]; then
        log "force: clearing ETag cache in $ETAG_DIR"
        rm -f "$ETAG_DIR"/*.etag 2>/dev/null || true
    fi

    local rkn_asset
    rkn_asset=$(pick_rkn_asset)

    local ok_count=0
    local fail_count=0
    local step_rc

    fetch_asset "$rkn_asset"   "$EXTRA/TCP/RKN/List.txt" && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    fetch_asset "youtube.txt"  "$EXTRA/TCP/YT/List.txt"  && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    fetch_asset "youtube.txt"  "$EXTRA/UDP/YT/List.txt"  && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    fetch_asset "discord.txt"  "$EXTRA/TCP/RKN/Discord.txt" && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))
    # TCP_Discord.txt mirror path used by some config_official.sh branches
    fetch_asset "discord.txt"  "$EXTRA/TCP_Discord.txt"  && ok_count=$((ok_count+1)) || fail_count=$((fail_count+1))

    log "fetch summary: $ok_count ok, $fail_count failed"

    # Strip YT + googlevideo overlaps from RKN list (enhanced branch only).
    # Runs unconditionally — even on all-304 runs an older on-disk RKN list
    # may still carry overlaps from a time before this step existed, or from
    # newly-added entries in the YT list.
    subtract_yt_from_rkn || log "RKN subtract: non-fatal failure, continuing"

    if [ "$ok_count" = "0" ]; then
        log "all targets failed"
        return 1
    fi
    if [ "$fail_count" != "0" ]; then
        return 2
    fi
    return 0
}

# --- show: single asset to stdout ------------------------------------------

show_asset() {
    local asset="${1:-}"
    [ -z "$asset" ] && die "show: asset name required (e.g. ru-blocked.txt)"
    ensure_deps
    curl -fsSL --connect-timeout 15 --max-time 600 \
         "$RELEASE_BASE/$asset" || die "fetch $asset failed"
}

# --- status: current production line counts --------------------------------

status_report() {
    local f
    for f in "$EXTRA/TCP/RKN/List.txt" \
             "$EXTRA/TCP/YT/List.txt" \
             "$EXTRA/UDP/YT/List.txt" \
             "$EXTRA/TCP/RKN/Discord.txt" \
             "$EXTRA/TCP_Discord.txt"; do
        if [ -s "$f" ]; then
            printf '%s  %s lines\n' "$f" "$(wc -l < "$f")"
        else
            printf '%s  (missing or empty)\n' "$f"
        fi
    done
    if [ -d "$ETAG_DIR" ]; then
        echo
        echo "ETag cache: $ETAG_DIR"
        for f in "$ETAG_DIR"/*; do
            [ -e "$f" ] || continue
            size=$(wc -c < "$f" 2>/dev/null || echo 0)
            printf '  %s  %sB\n' "$(basename "$f")" "$size"
        done
    fi
}

# --- dispatch ---------------------------------------------------------------

usage() {
    sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//;s/^#$//' | head -n 46
}

cmd="${1:-fetch}"
[ $# -gt 0 ] && shift
case "$cmd" in
    fetch)
        for arg in "$@"; do
            case "$arg" in
                --force|-f) FORCE_REFETCH=1 ;;
                *) die "unknown fetch arg: $arg" ;;
            esac
        done
        fetch_all
        ;;
    show)                    show_asset "$@" ;;
    status)                  status_report ;;
    -h|--help|help)          usage ;;
    *)                       die "unknown command: $cmd" ;;
esac
