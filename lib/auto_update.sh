#!/bin/sh
# z2k auto-update module
#
# Sourced from /opt/zapret2/z2k-auto-update.sh (cron entry) and from
# lib/menu.sh (manual "Проверить обновления").
#
# Exposes:
#   au_run_apply   — main entry: fetch manifest, decide, apply, health-check
#   au_run_check   — dry-run: fetch manifest, print diff, no apply
#
# Design lives in feedback_z2k_user_overrides_policy.md (memory) and the
# auto-update RFC: shipped files (Strategy.txt / lua / lists in repo) are
# replaced from repo, Z2K_* feature flags are extracted before apply and
# reapplied after, extra-domains.txt is 3-way merged.

# ---------------------------------------------------------------- constants ---

Z2K_AU_BRANCH="${Z2K_AU_BRANCH:-z2k-enhanced}"
Z2K_AU_REPO_RAW="${Z2K_AU_REPO_RAW:-https://raw.githubusercontent.com/necronicle/z2k/${Z2K_AU_BRANCH}}"
Z2K_AU_MANIFEST_URL="${Z2K_AU_MANIFEST_URL:-${Z2K_AU_REPO_RAW}/z2k/UPDATES.json}"
Z2K_AU_REINSTALL_URL="${Z2K_AU_REINSTALL_URL:-${Z2K_AU_REPO_RAW}/z2k.sh}"

Z2K_AU_INSTALLED_TAG_FILE="${Z2K_AU_INSTALLED_TAG_FILE:-/opt/zapret2/.z2k-installed-tag}"
Z2K_AU_LOCK_FILE="${Z2K_AU_LOCK_FILE:-/opt/zapret2/.update.lock}"
Z2K_AU_LOG_FILE="${Z2K_AU_LOG_FILE:-/opt/var/log/z2k-auto-update.log}"
Z2K_AU_TMP_DIR="${Z2K_AU_TMP_DIR:-/tmp/z2k_au}"
Z2K_AU_HEALTH_TIMEOUT="${Z2K_AU_HEALTH_TIMEOUT:-60}"     # seconds to wait before health-check
Z2K_AU_HEALTH_GH_URL="${Z2K_AU_HEALTH_GH_URL:-https://github.com}"

# ----------------------------------------------------------- logger / lock ---

au_log() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$Z2K_AU_LOG_FILE")" 2>/dev/null || true
    echo "[$ts] $msg" >> "$Z2K_AU_LOG_FILE" 2>/dev/null || true
    # also stderr so manual menu invocation sees it
    echo "[au] $msg" >&2 2>/dev/null || true
    # syslog tag for journalctl-style inspection
    logger -t z2k-au "$msg" 2>/dev/null || true
}

au_lock_acquire() {
    if [ -f "$Z2K_AU_LOCK_FILE" ]; then
        local pid
        pid=$(cat "$Z2K_AU_LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            au_log "lock held by pid=$pid, skipping"
            return 1
        fi
        au_log "stale lock removed (pid=$pid not alive)"
        rm -f "$Z2K_AU_LOCK_FILE"
    fi
    echo "$$" > "$Z2K_AU_LOCK_FILE" 2>/dev/null || return 1
    return 0
}

au_lock_release() {
    rm -f "$Z2K_AU_LOCK_FILE" 2>/dev/null || true
}

# -------------------------------------------------------- manifest fetch ---

# Fetch UPDATES.json into $Z2K_AU_TMP_DIR/UPDATES.json. Uses z2k_fetch
# for layered CDN/DoH fallback if available; raw curl otherwise.
au_fetch_manifest() {
    mkdir -p "$Z2K_AU_TMP_DIR"
    local out="$Z2K_AU_TMP_DIR/UPDATES.json"
    rm -f "$out"
    if command -v z2k_fetch >/dev/null 2>&1; then
        z2k_fetch "$Z2K_AU_MANIFEST_URL" "$out" || return 1
    else
        curl -fsSL --max-time 30 "$Z2K_AU_MANIFEST_URL" -o "$out" || return 1
    fi
    [ -s "$out" ] || return 1
    return 0
}

# ------------------------------------------------- manifest parsing ---

# au_manifest_current MANIFEST_PATH -> echoes "current" tag (e.g. "p-23")
au_manifest_current() {
    sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# au_tag_num TAG -> echoes numeric part (p-23 -> 23, r-2 -> 2)
au_tag_num() {
    echo "$1" | sed 's/[^0-9]//g'
}

# au_tag_type TAG -> echoes p|r|unknown
au_tag_type() {
    case "$1" in
        p-*) echo p ;;
        r-*) echo r ;;
        *)   echo unknown ;;
    esac
}

# au_history_entries_after MANIFEST_PATH INSTALLED_TAG
# Echoes JSON entry lines (one per line) for every history entry whose
# numeric version is strictly greater than installed numeric version.
au_history_entries_after() {
    local manifest="$1"
    local installed_tag="$2"
    local installed_n
    installed_n=$(au_tag_num "$installed_tag")
    installed_n=${installed_n:-0}
    awk -v inst_n="$installed_n" '
        /^[[:space:]]*\{[[:space:]]*"v"[[:space:]]*:[[:space:]]*"/ {
            # extract v value
            line = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            v = line
            n = v; gsub(/[^0-9]/, "", n)
            if (n + 0 > inst_n + 0) print $0
        }
    ' "$manifest"
}

# au_entry_field ENTRY_JSON FIELD -> echoes string value or empty
au_entry_field() {
    echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# au_entry_changed_files ENTRY_JSON -> echoes file paths (one per line)
au_entry_changed_files() {
    echo "$1" | sed -n 's/.*"changed_files"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
        | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep -v '^$' || true
}

# ------------------------------------------------------------ decide ---

# au_decide INSTALLED_TAG MANIFEST_PATH
# Echoes:
#   none                                         (nothing to do)
#   patch <target_tag> [files...]                (changed_files union)
#   reinstall <target_tag> [files...]            (full reinstall)
au_decide() {
    local installed_tag="$1"
    local manifest="$2"

    local current
    current=$(au_manifest_current "$manifest")
    if [ -z "$current" ]; then
        au_log "manifest has no current field"
        echo "none"
        return 0
    fi

    local current_n installed_n
    current_n=$(au_tag_num "$current")
    installed_n=$(au_tag_num "$installed_tag")
    : "${current_n:=0}"
    : "${installed_n:=0}"

    if [ "$current_n" -le "$installed_n" ]; then
        echo "none"
        return 0
    fi

    local entries
    entries=$(au_history_entries_after "$manifest" "$installed_tag")

    # any reinstall in the diff window → reinstall to current
    local has_reinstall=0
    local files=""
    local entry etype cf
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        etype=$(au_entry_field "$entry" "type")
        [ "$etype" = "reinstall" ] && has_reinstall=1
        cf=$(au_entry_changed_files "$entry")
        [ -n "$cf" ] && files="${files}
${cf}"
    done <<EOF
$entries
EOF

    # de-duplicate files
    files=$(echo "$files" | sort -u | grep -v '^$' || true)

    if [ "$has_reinstall" = "1" ]; then
        printf 'reinstall %s\n%s\n' "$current" "$files"
    else
        printf 'patch %s\n%s\n' "$current" "$files"
    fi
}

# -------------------------------------------------- Z2K_* feature flags ---

# Extract Z2K_* feature flags from the active config to a backup file.
au_save_feature_flags() {
    local out="$1"
    local config_file="${ZAPRET2_DIR:-/opt/zapret2}/config"
    [ -f "$config_file" ] || return 0
    grep -E '^Z2K_[A-Z0-9_]+=' "$config_file" > "$out" 2>/dev/null || true
    if [ -s "$out" ]; then
        au_log "saved $(wc -l < "$out") feature flags"
    fi
    return 0
}

# Reapply Z2K_* feature flags from backup over the active config.
# Only flags that already exist in the new config are replaced; new-config
# defaults stand for absent (deprecated) flags.
au_reapply_feature_flags() {
    local backup="$1"
    local config_file="${ZAPRET2_DIR:-/opt/zapret2}/config"
    [ -f "$backup" ] && [ -s "$backup" ] || return 0
    [ -f "$config_file" ] || return 1

    local applied=0 skipped=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local flag_name="${line%%=*}"
        if grep -q "^${flag_name}=" "$config_file"; then
            # escape & and / for sed
            local escaped
            escaped=$(printf '%s\n' "$line" | sed 's/[&/\\]/\\&/g')
            sed -i "s|^${flag_name}=.*|${escaped}|" "$config_file"
            applied=$((applied + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < "$backup"
    au_log "feature flags reapplied: $applied set, $skipped skipped (deprecated)"
    return 0
}

# --------------------------------------------- repo path → install path ---

# Map a repo-relative path (e.g. "files/lua/z2k-detectors.lua") to one or
# more on-disk install paths. Echoes one path per line. Empty if the repo
# path has no runtime install target (e.g. lib/, tests/).
au_install_paths() {
    local repo_path="$1"
    local zd="${ZAPRET2_DIR:-/opt/zapret2}"
    case "$repo_path" in
        files/lua/*)
            echo "${zd}/lua/${repo_path#files/lua/}"
            ;;
        files/lists/extra-domains.txt)
            # Both shipped baseline and runtime merged copy. Caller treats
            # these as a special case for 3-way merge.
            echo "${zd}/files/lists/extra-domains.txt"
            echo "${zd}/lists/extra-domains.txt"
            ;;
        files/lists/*.txt)
            # IP/host lists that install.sh dual-copies (files/lists/ + lists/).
            echo "${zd}/files/lists/${repo_path#files/lists/}"
            echo "${zd}/lists/${repo_path#files/lists/}"
            ;;
        files/extra_strats/*/Strategy.txt)
            echo "${zd}/extra_strats/${repo_path#files/extra_strats/}"
            ;;
        files/extra_strats/*)
            echo "${zd}/extra_strats/${repo_path#files/extra_strats/}"
            ;;
        files/fake/*)
            echo "${zd}/files/fake/${repo_path#files/fake/}"
            ;;
        files/etc/*)
            echo "${zd}/etc/${repo_path#files/etc/}"
            ;;
        files/init.d/*)
            echo "${zd}/init.d/${repo_path#files/init.d/}"
            ;;
        files/S99zapret2.new)
            echo "/opt/etc/init.d/S99zapret2"
            ;;
        files/*.sh|files/*.lua)
            echo "${zd}/${repo_path#files/}"
            ;;
        *)
            : # no runtime target
            ;;
    esac
}

# Download a single repo file via z2k_fetch (or curl) into a target.
au_download_repo_file() {
    local repo_path="$1"
    local target="$2"
    local url="${Z2K_AU_REPO_RAW}/${repo_path}"
    mkdir -p "$(dirname "$target")"
    if command -v z2k_fetch >/dev/null 2>&1; then
        z2k_fetch "$url" "$target" || return 1
    else
        curl -fsSL --max-time 30 "$url" -o "$target" || return 1
    fi
    [ -s "$target" ] || [ -f "$target" ] || return 1
    return 0
}

# -------------------------------------------------- 3-way merge: extras ---

# extra-domains.txt is the only file where users append their own domains.
# Merge: new_runtime = shipped_new ∪ (current_runtime − shipped_old).
au_merge_extra_domains() {
    local zd="${ZAPRET2_DIR:-/opt/zapret2}"
    local shipped_old="${zd}/files/lists/extra-domains.txt"
    local runtime="${zd}/lists/extra-domains.txt"
    local shipped_new="$1"   # path to freshly downloaded shipped version

    if [ ! -f "$shipped_new" ]; then
        au_log "merge extra-domains: shipped_new missing, skipping"
        return 1
    fi

    local user_extras="$Z2K_AU_TMP_DIR/extra-domains.user_extras"
    if [ -f "$shipped_old" ] && [ -f "$runtime" ]; then
        grep -vxFf "$shipped_old" "$runtime" 2>/dev/null > "$user_extras" || true
    elif [ -f "$runtime" ]; then
        # no baseline known — treat all runtime lines as user extras, but
        # only those NOT already in shipped_new (avoid duplicates)
        grep -vxFf "$shipped_new" "$runtime" 2>/dev/null > "$user_extras" || true
    else
        : > "$user_extras"
    fi

    # Update shipped baseline first (shipped_old gets replaced)
    mkdir -p "$(dirname "$shipped_old")"
    cp -f "$shipped_new" "$shipped_old"

    # Build new runtime: shipped_new + user-only lines (deduped)
    {
        cat "$shipped_new"
        if [ -s "$user_extras" ]; then
            cat "$user_extras"
        fi
    } | awk '!seen[$0]++' > "$runtime.tmp"
    mv -f "$runtime.tmp" "$runtime"

    local user_n
    user_n=$(wc -l < "$user_extras" 2>/dev/null || echo 0)
    au_log "merged extra-domains: ${user_n} user-only lines preserved"
    return 0
}

# ----------------------------------------------------------- apply paths ---

# Apply patch: download every changed_file, place into install target.
# extra-domains.txt is 3-way merged, everything else is straight replace.
au_apply_patch() {
    local target_tag="$1"
    shift
    local files="$*"

    if [ -z "$files" ]; then
        au_log "patch with no files — nothing to do"
        return 0
    fi

    mkdir -p "$Z2K_AU_TMP_DIR/dl"
    local saved_flags="$Z2K_AU_TMP_DIR/feature-flags.backup"
    au_save_feature_flags "$saved_flags"

    # 1) download all files first to staging — atomic-ish: if any download
    # fails, we abort before touching live files.
    local repo_path stage
    while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        stage="$Z2K_AU_TMP_DIR/dl/$(echo "$repo_path" | tr '/' '_')"
        if ! au_download_repo_file "$repo_path" "$stage"; then
            au_log "patch: failed to download $repo_path — aborting"
            return 1
        fi
    done <<EOF
$files
EOF

    # 2) install each file
    local targets target
    while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        stage="$Z2K_AU_TMP_DIR/dl/$(echo "$repo_path" | tr '/' '_')"
        targets=$(au_install_paths "$repo_path")
        if [ -z "$targets" ]; then
            au_log "patch: no install target for $repo_path (skipped)"
            continue
        fi

        # extra-domains.txt: 3-way merge (handles both /files/lists/ and /lists/)
        if [ "$repo_path" = "files/lists/extra-domains.txt" ]; then
            au_merge_extra_domains "$stage"
            continue
        fi

        while IFS= read -r target; do
            [ -z "$target" ] && continue
            mkdir -p "$(dirname "$target")"
            cp -f "$stage" "$target"
            au_log "patch: installed $repo_path -> $target"
        done <<EOF_TARGETS
$targets
EOF_TARGETS
    done <<EOF
$files
EOF

    # 3) reapply feature flags (config might have been replaced if it was
    # in changed_files). For pure lua/list patches this is a no-op.
    au_reapply_feature_flags "$saved_flags"

    # 4) write installed tag
    echo "$target_tag" > "$Z2K_AU_INSTALLED_TAG_FILE"

    # 5) restart service so new code takes effect
    if [ -x /opt/etc/init.d/S99zapret2 ]; then
        /opt/etc/init.d/S99zapret2 restart >/dev/null 2>&1 || true
    fi

    au_log "patch applied: $target_tag"
    return 0
}

# Apply reinstall: rerun z2k.sh in non-interactive mode. install.sh handles
# all the bookkeeping. Z2K_AUTO_UPDATE=1 + Z2K_AU_TARGET_TAG=<tag> are the
# contract install.sh observes (see install.sh hooks).
au_apply_reinstall() {
    local target_tag="$1"
    local saved_flags="$Z2K_AU_TMP_DIR/feature-flags.backup"
    au_save_feature_flags "$saved_flags"

    au_log "reinstall: launching z2k.sh"
    Z2K_AUTO_UPDATE=1 Z2K_AU_TARGET_TAG="$target_tag" \
        Z2K_AU_FEATURE_FLAGS_BACKUP="$saved_flags" \
        sh -c "curl -fsSL '${Z2K_AU_REINSTALL_URL}' | sh" \
        >> "$Z2K_AU_LOG_FILE" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        au_log "reinstall failed rc=$rc"
        return 1
    fi

    # install.sh may have already written the tag, but enforce it here too.
    echo "$target_tag" > "$Z2K_AU_INSTALLED_TAG_FILE"
    au_log "reinstall applied: $target_tag"
    return 0
}

# ----------------------------------------------------------- health-check ---

au_health_check() {
    local timeout="${1:-$Z2K_AU_HEALTH_TIMEOUT}"
    au_log "health-check: waiting ${timeout}s for service to settle"
    sleep "$timeout"

    if ! pgrep -f nfqws2 >/dev/null 2>&1; then
        au_log "health-check FAILED: nfqws2 not running"
        return 1
    fi

    if ! curl -fsS --max-time 10 -o /dev/null "$Z2K_AU_HEALTH_GH_URL"; then
        au_log "health-check FAILED: github unreachable"
        return 1
    fi

    au_log "health-check OK"
    return 0
}

# Re-applied when health-check fails. We use the existing rollback infra
# from install.sh (create_rollback_snapshot creates ROLLBACK_DIR). For
# auto-update path the snapshot is created by install.sh in reinstall
# mode; for patch we make a focused snapshot of just the changed files.
au_rollback_patch() {
    local pre_dir="$Z2K_AU_TMP_DIR/pre-apply"
    [ -d "$pre_dir" ] || return 1
    au_log "rollback: restoring pre-apply files"
    cd "$pre_dir" || return 1
    find . -type f | while read -r f; do
        local target="${f#./}"
        target="/$target"
        cp -f "$f" "$target" 2>/dev/null || true
    done
    if [ -x /opt/etc/init.d/S99zapret2 ]; then
        /opt/etc/init.d/S99zapret2 restart >/dev/null 2>&1 || true
    fi
    return 0
}

# Snapshot files about to be replaced (called from au_apply_patch before
# any cp -f). Mirrors target paths under $Z2K_AU_TMP_DIR/pre-apply/.
au_snapshot_for_patch() {
    local files="$*"
    local snap="$Z2K_AU_TMP_DIR/pre-apply"
    rm -rf "$snap"
    mkdir -p "$snap"
    local repo_path targets target relpath dst
    while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        targets=$(au_install_paths "$repo_path")
        while IFS= read -r target; do
            [ -z "$target" ] && continue
            [ -f "$target" ] || continue
            relpath="${target#/}"
            dst="$snap/$relpath"
            mkdir -p "$(dirname "$dst")"
            cp -f "$target" "$dst"
        done <<EOF_T
$targets
EOF_T
    done <<EOF_F
$files
EOF_F
    return 0
}

# ------------------------------------------------------ main entry points ---

# au_run_check — dry run: show what would happen, don't apply.
au_run_check() {
    if ! au_fetch_manifest; then
        echo "Не удалось получить UPDATES.json (проверьте интернет)"
        return 1
    fi
    local manifest="$Z2K_AU_TMP_DIR/UPDATES.json"

    local installed
    if [ -f "$Z2K_AU_INSTALLED_TAG_FILE" ]; then
        installed=$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)
    else
        installed="(не установлен)"
    fi

    local current
    current=$(au_manifest_current "$manifest")

    echo "Установлено: $installed"
    echo "В репозитории: $current"

    local decision
    decision=$(au_decide "$installed" "$manifest")
    local action target_tag
    action=$(echo "$decision" | head -1 | awk '{print $1}')
    target_tag=$(echo "$decision" | head -1 | awk '{print $2}')

    case "$action" in
        none)
            echo "Обновлений нет — установлена актуальная версия."
            return 0
            ;;
        patch)
            echo "Доступно обновление (PATCH) до $target_tag:"
            ;;
        reinstall)
            echo "Доступно обновление (REINSTALL) до $target_tag:"
            ;;
    esac

    # show changelog: descriptions of new entries
    local entries entry v desc etype
    entries=$(au_history_entries_after "$manifest" "$installed")
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        v=$(au_entry_field "$entry" "v")
        desc=$(au_entry_field "$entry" "desc")
        etype=$(au_entry_field "$entry" "type")
        echo "  [$v $etype] $desc"
    done <<EOF
$entries
EOF

    return 0
}

# au_run_apply — main: fetch, decide, apply, health-check, rollback if bad.
au_run_apply() {
    if ! au_lock_acquire; then
        return 1
    fi
    # Ensure the lock is released no matter how we exit
    trap 'au_lock_release' EXIT INT TERM HUP

    if ! au_fetch_manifest; then
        au_log "manifest fetch failed"
        au_lock_release
        return 1
    fi
    local manifest="$Z2K_AU_TMP_DIR/UPDATES.json"

    local installed
    if [ -f "$Z2K_AU_INSTALLED_TAG_FILE" ]; then
        installed=$(cat "$Z2K_AU_INSTALLED_TAG_FILE" 2>/dev/null)
    else
        # Pre-versioning install. Don't apply anything; mark current as
        # installed and let the next cycle work from there.
        local current
        current=$(au_manifest_current "$manifest")
        if [ -n "$current" ]; then
            echo "$current" > "$Z2K_AU_INSTALLED_TAG_FILE"
            au_log "first run: marked installed=$current (no apply)"
        fi
        au_lock_release
        return 0
    fi

    local decision action target_tag files
    decision=$(au_decide "$installed" "$manifest")
    action=$(echo "$decision" | head -1 | awk '{print $1}')
    target_tag=$(echo "$decision" | head -1 | awk '{print $2}')
    files=$(echo "$decision" | tail -n +2)

    case "$action" in
        none)
            au_log "no update needed (installed=$installed)"
            au_lock_release
            return 0
            ;;
        patch)
            au_log "starting patch: $installed -> $target_tag"
            au_snapshot_for_patch "$files"
            if ! au_apply_patch "$target_tag" "$files"; then
                au_log "patch apply failed, rolling back"
                au_rollback_patch
                au_lock_release
                return 1
            fi
            if ! au_health_check; then
                au_log "post-patch health-check failed, rolling back"
                au_rollback_patch
                # restore the previous tag
                # shellcheck disable=SC2154
                echo "$installed" > "$Z2K_AU_INSTALLED_TAG_FILE"
                au_lock_release
                return 1
            fi
            ;;
        reinstall)
            au_log "starting reinstall: $installed -> $target_tag"
            if ! au_apply_reinstall "$target_tag"; then
                au_log "reinstall apply failed"
                # install.sh's create_rollback_snapshot + auto_rollback_timer
                # would handle in-process recovery; we just bail.
                au_lock_release
                return 1
            fi
            if ! au_health_check; then
                au_log "post-reinstall health-check failed"
                # nothing more we can do automatically — leave breadcrumb
                # for the operator. Tag stays as target_tag because the
                # reinstall did write files; manual rollback via
                # rollback_to_snapshot is available.
                au_lock_release
                return 1
            fi
            ;;
    esac

    au_log "update OK: now at $target_tag"
    au_lock_release
    trap - EXIT INT TERM HUP
    return 0
}
