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
    #
    # BUT: the shrink guard must compare against the EXPECTED asset, not the
    # absolute previous size. pick_rkn_asset deliberately switches between the
    # big ru-blocked-all.txt (~30 MB) and the small ru-blocked.txt (~1.7 MB) by
    # RAM threshold, both writing this same target. A router that drops below the
    # threshold (or a user lowering Z2K_GEOSITE_RKN_RAM_THRESHOLD_MB) must be able
    # to DOWNGRADE big→small — but the small list is ~5% of the big one, so the
    # absolute-size guard would reject it forever and the safety path is dead.
    # So: record which asset produced the current target, and only enforce the
    # 80% guard when the incoming asset is the SAME class as what's on disk. An
    # intentional class change bypasses the guard.
    local asset_marker="${target}.asset"
    local prev_asset=""
    [ -f "$asset_marker" ] && prev_asset=$(cat "$asset_marker" 2>/dev/null)
    if [ -s "$target" ] && { [ -z "$prev_asset" ] || [ "$prev_asset" = "$asset" ]; }; then
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
    elif [ -s "$target" ] && [ "$prev_asset" != "$asset" ]; then
        log "  $asset: asset class change ($prev_asset → $asset) — bypassing shrink guard"
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

    # Record which asset produced this target so the shrink guard above can
    # tell an intentional big↔small class switch (bypass guard) from a genuine
    # upstream truncation regression (enforce guard).
    printf '%s\n' "$asset" > "$asset_marker" 2>/dev/null || true

    local lines
    lines=$(wc -l < "$target" 2>/dev/null || echo 0)
    log "  $asset: applied, $lines lines"
    return 0
}

# --- Subtract googlevideo entries from YT list -----------------------------
#
# runetfreedom's youtube.txt includes `googlevideo.com` apex and various
# `*.googlevideo.com` subdomains. We route googlevideo through its own
# `extra_strats/TCP/YT_GV/List.txt` profile (gv_tcp) with strategies tuned
# for bulk-video CDN traffic, NOT through yt_tcp (which is tuned for
# youtube.com itself). nfqws2 is first-match-wins, so any googlevideo
# entry left in YT/List sends GV traffic to yt_tcp before gv_tcp gets a
# chance — exactly the «много ротаций на GV» bug fixed in r-17.
# Run unconditionally after fetch (even on 304/cached) so the on-disk
# list stays clean if upstream adds googlevideo entries later.
subtract_googlevideo_from_yt() {
    local yt_target="$EXTRA/TCP/YT/List.txt"
    [ -s "$yt_target" ] || return 0

    local before after removed filtered
    before=$(wc -l < "$yt_target" 2>/dev/null || echo 0)
    filtered="$TMP_DIR/yt.filtered"

    awk '{
        d = $0
        sub(/\r$/, "", d)
        if (d == "googlevideo.com") next
        if (d ~ /\.googlevideo\.com$/) next
        print d
    }' "$yt_target" > "$filtered" || {
        log "YT subtract: awk failed, keeping original list"
        rm -f "$filtered"
        return 1
    }

    after=$(wc -l < "$filtered" 2>/dev/null || echo 0)
    removed=$((before - after))
    if [ "$removed" -gt 0 ]; then
        mv "$filtered" "$yt_target" || {
            log "YT subtract: rename failed"
            return 1
        }
        log "YT: removed $removed googlevideo overlap(s) ($before → $after lines) — gv_tcp profile gets these via YT_GV/List.txt"
    else
        rm -f "$filtered"
        log "YT: no googlevideo overlaps in upstream youtube.txt"
    fi
    return 0
}

# --- Inject sign-in endpoints upstream youtube.txt omits -------------------
#
# runetfreedom's youtube.txt does NOT carry the YouTube / Apple-TV account
# sign-in endpoints (oauth2.googleapis.com = the device-login OAuth poll,
# accounts.google.com / accounts.youtube.com = the sign-in itself). The
# set-top login rides these over BOTH TLS and HTTP/3 (QUIC). Without them in
# the YT lists the login flow gets ZERO nfqws2 treatment and sign-in hangs on
# offload routers. The shipped snapshot carries them, but fetch_asset
# overwrites the LIVE list from upstream — so we re-inject them here, into both
# the TCP and the QUIC YT lists, on every fetch (idempotent, suffix-safe dedup).
YT_LOGIN_DOMAINS="accounts.google.com accounts.youtube.com oauth2.googleapis.com"

inject_yt_login_domains() {
    local list d added
    for list in "$EXTRA/TCP/YT/List.txt" "$EXTRA/UDP/YT/List.txt"; do
        [ -f "$list" ] || continue
        added=0
        for d in $YT_LOGIN_DOMAINS; do
            grep -qxF "$d" "$list" 2>/dev/null || { printf '%s\n' "$d" >> "$list"; added=$((added+1)); }
        done
        [ "$added" -gt 0 ] && log "YT login: injected $added sign-in domain(s) into ${list#"$EXTRA"/}"
    done
    return 0
}

# Video-serving Google domains that ride the googlevideo profiles (gv_tcp over
# TLS, QUIC YT profile over UDP) but that upstream youtube.txt omits. Paired
# with googlevideo.com — same handling. Injected ONLY into the lists that carry
# googlevideo (TCP/YT_GV + UDP/YT), NOT TCP/YT (yt_tcp), where googlevideo is
# intentionally stripped (subtract_googlevideo_from_yt) — keeping these out of
# yt_tcp so the gv_tcp profile (first-match by its own hostlist) handles them.
# UDP/YT is overwritten by the youtube.txt fetch, so re-add post-fetch;
# TCP/YT_GV is static but injected too for durability across list-only updates
# (where a full reinstall hasn't redeployed the shipped file). Idempotent.
YT_VIDEO_DOMAINS="video.google.com"

inject_yt_video_domains() {
    local list d added
    for list in "$EXTRA/TCP/YT_GV/List.txt" "$EXTRA/UDP/YT/List.txt"; do
        [ -f "$list" ] || continue
        added=0
        for d in $YT_VIDEO_DOMAINS; do
            grep -qxF "$d" "$list" 2>/dev/null || { printf '%s\n' "$d" >> "$list"; added=$((added+1)); }
        done
        [ "$added" -gt 0 ] && log "YT video: injected $added video domain(s) into ${list#"$EXTRA"/}"
    done
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

# --- Subtract hand-curated false positives ----------------------------------
#
# В upstream `ru-blocked` / `ru-blocked-all` геосайт иногда попадают
# домены которые по факту НЕ заблокированы РКН (например play.google.com —
# free apps работают, заблокирован только paid billing со стороны Google
# санкциями). Обрабатывать их nfqws2 — лишний CPU + засорение state.tsv.
#
# Список ведётся в /opt/zapret2/lists/rkn-false-positive.txt (shipped через
# install.sh из files/lists/rkn-false-positive.txt). Match exact-line
# (НЕ suffix) — мы не хотим случайно выпилить заблокированный subdomain.
subtract_false_positive_from_rkn() {
    local rkn_target="$EXTRA/TCP/RKN/List.txt"
    local fp_list="${ZAPRET2_FALSE_POSITIVE_LIST:-/opt/zapret2/lists/rkn-false-positive.txt}"

    [ -s "$rkn_target" ] || return 0
    [ -s "$fp_list" ] || return 0

    local exclude="$TMP_DIR/rkn.false-positive.exclude"
    : > "$exclude"
    # Strip comments / empty / CRLF, normalize lowercase.
    awk '
        { sub(/\r$/, ""); sub(/[[:space:]]+$/, "") }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        { print tolower($0) }
    ' "$fp_list" > "$exclude"
    [ -s "$exclude" ] || { rm -f "$exclude"; return 0; }

    local before after removed filtered
    before=$(wc -l < "$rkn_target" 2>/dev/null || echo 0)
    filtered="$TMP_DIR/rkn.false-positive.filtered"

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
            if (d in ex) next
            print d
        }
    ' "$rkn_target" > "$filtered" || {
        log "RKN false-positive subtract: awk failed, keeping original list"
        rm -f "$filtered" "$exclude"
        return 1
    }

    after=$(wc -l < "$filtered" 2>/dev/null || echo 0)
    removed=$((before - after))
    if [ "$removed" -gt 0 ]; then
        mv "$filtered" "$rkn_target" || {
            log "RKN false-positive subtract: rename failed"
            rm -f "$exclude"
            return 1
        }
        log "RKN: removed $removed hand-curated false positives ($before → $after lines)"
    else
        rm -f "$filtered"
        log "RKN false-positive: no overlaps with curated list"
    fi
    rm -f "$exclude"
    return 0
}

# --- One-shot state cleanup ------------------------------------------------
#
# 2026-05-24 false-positive subtract убрал play.google.com и
# snap-storage-cdn.l.google.com из RKN. autocircular использует nld=2 SLD
# ключ — оба домена раньше писались в state.tsv под ключом `google.com`.
# Эта запись больше не валидна (заблокированные subdomains используют свои
# ключи), но autocircular не удаляет stale entries сам. One-shot purge с
# marker-файлом — выполнится один раз при следующем после patch refresh.
purge_stale_google_state() {
    local state="$EXTRA/cache/autocircular/state.tsv"
    local marker="$EXTRA/cache/autocircular/.google_purge_2026_05_24.done"
    [ -f "$marker" ] && return 0
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    if [ -f "$state" ]; then
        local tmp="$state.purge.tmp"
        awk -F'\t' '!($1=="rkn_tcp" && $2=="google.com")' "$state" > "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        cat "$tmp" > "$state" && rm -f "$tmp"
        log "purged stale 'rkn_tcp google.com' state entry (one-shot)"
    fi
    touch "$marker"
}

purge_stale_instagram_state() {
    local state="$EXTRA/cache/autocircular/state.tsv"
    # КРИТИЧНО: marker в /opt/etc (persistent Entware root), НЕ в $EXTRA/cache.
    # Это был корень бага p-38: прежний marker жил в
    # $EXTRA/cache/autocircular/ который сносится rm/mv "$ZAPRET2_DIR" при
    # каждом auto-update reinstall → purge срабатывал на КАЖДОМ update,
    # стирая рабочую instagram-страту (жалоба @jet_sk_ya). Persistent
    # marker в /opt/etc переживает reinstall → purge действительно one-shot.
    # Цель purge — однократно сбросить застрявшую (до p-34) instagram.com
    # страту, залипшую на 40+ из-за browser-cancel false-positive в
    # silent_drop_detector. После сброса autocircular переподберёт рабочую.
    local marker="/opt/etc/.z2k-instagram-purge-2026-05-28.done"
    [ -f "$marker" ] && return 0
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    if [ -f "$state" ]; then
        local tmp="$state.purge.tmp"
        awk -F'\t' '!($1=="rkn_tcp" && $2=="instagram.com")' "$state" > "$tmp" || {
            rm -f "$tmp"
            return 1
        }
        cat "$tmp" > "$state" && rm -f "$tmp"
        log "purged stale 'rkn_tcp instagram.com' state entry (one-shot, persistent marker)"
    fi
    touch "$marker"
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

    # Strip googlevideo entries from YT list FIRST (so RKN subtract below
    # uses the cleaned YT list, not the upstream version that carries
    # googlevideo entries).
    subtract_googlevideo_from_yt || log "YT subtract: non-fatal failure, continuing"

    # Re-add the sign-in endpoints upstream youtube.txt omits (set-top login
    # over TLS + QUIC). Before the RKN subtract so they reach the YT profile,
    # not RKN. Idempotent.
    inject_yt_login_domains || log "YT login inject: non-fatal failure, continuing"

    # Re-add video.google.com to the googlevideo-carrying lists (TCP/YT_GV +
    # UDP/YT) — survives the youtube.txt overwrite. Before the RKN subtract so
    # it lands in the YT/GV profiles, not RKN. Idempotent.
    inject_yt_video_domains || log "YT video inject: non-fatal failure, continuing"

    # Strip YT + googlevideo overlaps from RKN list (enhanced branch only).
    # Runs unconditionally — even on all-304 runs an older on-disk RKN list
    # may still carry overlaps from a time before this step existed, or from
    # newly-added entries in the YT list.
    subtract_yt_from_rkn || log "RKN subtract: non-fatal failure, continuing"

    # Strip hand-curated false positives (domains в upstream RKN, но НЕ
    # заблокированные по факту). Перепроверено через web search 2026-05-24.
    subtract_false_positive_from_rkn || log "RKN false-positive subtract: non-fatal failure, continuing"

    # One-shot cleanup: убрать stale `rkn_tcp google.com` запись из state.tsv.
    # autocircular использует nld=2 SLD ключ, поэтому play.google.com / snap-
    # storage-cdn.l.google.com (теперь убраны из RKN) ранее писались в state
    # под ключом google.com. Marker гарантирует one-shot — повторно не запустится.
    purge_stale_google_state || log "google state purge: non-fatal failure, continuing"

    # One-shot (persistent marker в /opt/etc) сброс застрявшей до-p-34
    # instagram.com страты. Marker переживает reinstall — в отличие от
    # удалённого в p-38 варианта, который purg'ил каждый update. Targeted:
    # трогает только запись rkn_tcp/instagram.com, остальной state цел.
    purge_stale_instagram_state || log "instagram state purge: non-fatal failure, continuing"

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
