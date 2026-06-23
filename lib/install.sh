#!/bin/sh
# lib/install.sh - Полный процесс установки zapret2 для Keenetic
# 12-шаговая установка с интеграцией списков доменов и стратегий

# ==============================================================================
# HELPER: Fix crontab spool file permissions after `crontab -` call
# ==============================================================================
# Entware's `crontab` util writes the spool file as mode 0775 owner root:1000
# (inheriting group from the parent directory which is drwxrwxr-x root:1000).
# cron daemon silently refuses to read crontabs with group/other write bits
# as a security measure. Net effect: TG watchdog and get_config cron entries
# are installed but never fire, and it looks like cron is broken.
# Fix: force 0600 root:root after every `crontab -` invocation.
z2k_fix_cron_perms() {
    local spool="/opt/var/spool/cron/crontabs/root"
    if [ -f "$spool" ]; then
        chmod 600 "$spool" 2>/dev/null
        chown root:root "$spool" 2>/dev/null
    fi
}

# ==============================================================================
# HELPER: deploy a critical file with self-healing fallback to direct GitHub fetch
# ==============================================================================
# Field debug 2026-05-23 found a MIPS user on r-25 whose install.sh delivered
# the tg-mtproxy-client binary but silently skipped S97z2k-http-tunnel
# (and several other init.d files) because their source path was missing
# from WORK_DIR — `if [ -f ... ] cp -f` quietly turns into no-op. Result:
# cdnbase tunnel daemon had no way to start. This helper closes that gap by
# falling back to z2k_fetch (raw → jsdelivr → gh-proxy → ndmc-DNS chain)
# whenever the WORK_DIR copy is absent.
#
# Usage: deploy_critical_file <repo-relative-path> <abs-destination> [chmod-mode]
deploy_critical_file() {
    local src="$1"
    local dst="$2"
    local mode="${3:-755}"
    local work_src="${WORK_DIR}/${src}"

    # Снапшот внешнего target'а перед перезаписью (для rollback). no-op
    # вне transactional-окна и для путей внутри ${ZAPRET2_DIR}. Если снапшот
    # не удался В transactional-окне (disk-full) — НЕ перезаписываем external,
    # возвращаем 1: лучше abort+rollback чем перезапись без возможности отката.
    if ! z2k_snapshot_external "$dst"; then
        print_error "  ↳ ${dst##*/}: снапшот для отката не удался — пропускаю перезапись"
        return 1
    fi

    # -s (non-empty) вместо -f: torn cache from interrupted prior fetch
    # leaves a 0-byte file in WORK_DIR which would otherwise satisfy -f
    # and silently install an empty target — same failure mode as missing
    # source, just harder to diagnose. Empty source → fall through to
    # network fallback below.
    if [ -s "$work_src" ]; then
        cp -f "$work_src" "$dst" 2>/dev/null && chmod "$mode" "$dst" 2>/dev/null && return 0
    fi
    if command -v z2k_fetch >/dev/null 2>&1; then
        if z2k_fetch "/${src}" "$dst" 2>/dev/null; then
            chmod "$mode" "$dst" 2>/dev/null
            # z2k_fetch leaves a sibling <dst>.etag with the cache-validation
            # hash. In dirs that get auto-scanned and executed by NDM (e.g.
            # /opt/etc/ndm/netfilter.d/, /opt/etc/init.d/) ndm will try to
            # exec the .etag as a shell script — it's just one line with the
            # hex digest, so bash treats the digest as a command name and
            # fails with exit 127. Field-reported 2026-05-24 on a fresh
            # install of r-26+. Strip the .etag right after fetch to avoid
            # the noise.
            rm -f "${dst}.etag" 2>/dev/null
            print_info "  ↳ ${dst##*/}: fetched from GitHub (WORK_DIR empty)" 2>/dev/null
            return 0
        fi
    fi
    print_warning "  ↳ ${dst##*/}: failed to deploy from WORK_DIR or GitHub" 2>/dev/null
    return 1
}

# ==============================================================================
# Transactional install: old-tree backup + restore
# ==============================================================================
# step_build_zapret2 переименовывает (mv, не rm -rf) старое ${ZAPRET2_DIR}
# в ${ZAPRET2_DIR}.old.$$ и кладёт путь в $Z2K_OLD_TREE_BACKUP. mv мгновенен
# и не требует доп. места (rename на том же fs). Любой пост-delete failure
# (steps 6-12 или hostlist install внутри step 5) восстанавливает старое
# дерево вместо того чтобы оставить router полу-установленным. На полный
# success — z2k_commit_install удаляет backup. Codex review 2026-05-28:
# avoid die after destructive steps; restore previous install on failure.
# Snapshot внешнего (вне ${ZAPRET2_DIR}) файла перед его перезаписью, чтобы
# rollback мог вернуть прежнюю версию ИЛИ удалить новый файл если его раньше
# не было. Idempotent: первый снапшот фиксирует ИСХОДНОЕ состояние, повторные
# вызовы no-op. Без активного transactional-окна ($Z2K_OLD_TREE_BACKUP не
# задан) — no-op. Файлы ВНУТРИ дерева покрыты mv-бэкапом, их не дублируем.
z2k_snapshot_external() {
    local target="$1"
    [ -n "${Z2K_OLD_TREE_BACKUP:-}" ] || return 0
    case "$target" in
        "${ZAPRET2_DIR}"/*) return 0 ;;
    esac
    local snap_dir="${Z2K_OLD_TREE_BACKUP}.ext"
    # mandatory: на mkdir/cp/marker fail возвращаем non-zero, чтобы callsite
    # прервал перезапись external-файла ДО мутации. Иначе (Codex 2026-05-28)
    # под disk-full /opt снапшот молча не создаётся, external перезаписывается,
    # а rollback потом восстановит дерево но оставит несовместимые новые
    # init-скрипты — и отрапортует успех.
    if ! mkdir -p "$snap_dir" 2>/dev/null; then
        print_error "snapshot: не удалось создать ${snap_dir} (нет места в /opt?)"
        return 1
    fi
    local flat
    flat=$(printf '%s' "$target" | sed 's|/|__|g')
    if [ -e "${snap_dir}/${flat}" ] || [ -e "${snap_dir}/${flat}.absent" ]; then
        return 0
    fi
    if [ -e "$target" ]; then
        if ! cp -a "$target" "${snap_dir}/${flat}" 2>/dev/null; then
            print_error "snapshot: не удалось скопировать ${target} в backup (нет места?)"
            return 1
        fi
    else
        if ! : > "${snap_dir}/${flat}.absent" 2>/dev/null; then
            print_error "snapshot: не удалось создать absent-marker для ${target}"
            return 1
        fi
    fi
    return 0
}
z2k_restore_external() {
    local snap_dir="${Z2K_OLD_TREE_BACKUP:-}.ext"
    [ -n "${Z2K_OLD_TREE_BACKUP:-}" ] && [ -d "$snap_dir" ] || return 0
    local f flat target rc=0
    for f in "$snap_dir"/*; do
        [ -e "$f" ] || continue
        case "$f" in
            *.absent)
                flat=$(basename "$f" .absent)
                target=$(printf '%s' "$flat" | sed 's|__|/|g')
                rm -f "$target" 2>/dev/null || { print_warning "restore: не удалось удалить новый ${target}"; rc=1; }
                ;;
            *)
                flat=$(basename "$f")
                target=$(printf '%s' "$flat" | sed 's|__|/|g')
                cp -a "$f" "$target" 2>/dev/null || { print_warning "restore: не удалось вернуть ${target} из backup"; rc=1; }
                ;;
        esac
    done
    return $rc
}
z2k_restore_old_tree() {
    [ -n "${Z2K_OLD_TREE_BACKUP:-}" ] && [ -d "$Z2K_OLD_TREE_BACKUP" ] || return 1
    print_error "Восстановление предыдущей рабочей установки из ${Z2K_OLD_TREE_BACKUP}..."
    local _ext_ok=1
    # 1. Внешние файлы (init-скрипты, NDM-хуки) — вернуть к исходному
    #    состоянию ДО возврата дерева, чтобы restored дерево и external
    #    скрипты были консистентны.
    z2k_restore_external || _ext_ok=0
    # 2. Само дерево /opt/zapret2.
    rm -rf "$ZAPRET2_DIR" 2>/dev/null
    if mv "$Z2K_OLD_TREE_BACKUP" "$ZAPRET2_DIR" 2>/dev/null; then
        if [ "$_ext_ok" = "1" ]; then
            print_success "Предыдущая установка восстановлена полностью — сервис продолжит работать на ней."
        else
            print_error "Дерево восстановлено, но часть external-файлов (init/NDM) вернуть не удалось."
            print_error "Проверьте /opt/etc/init.d вручную — могут остаться несовместимые новые скрипты."
        fi
        # 3. Рестарт ключевых daemon'ов из восстановленного дерева, чтобы
        #    в память загрузился старый (рабочий) код, а не новый частичный.
        local _svc
        for _svc in S99zapret2 S99z2k-scheduler S98tg-tunnel S97z2k-http-tunnel S96z2k-rt-proxy S98z2k-detect; do
            [ -x "/opt/etc/init.d/${_svc}" ] && /opt/etc/init.d/${_svc} restart >/dev/null 2>&1
        done
        rm -rf "${Z2K_OLD_TREE_BACKUP}.ext" 2>/dev/null
        unset Z2K_OLD_TREE_BACKUP
        [ "$_ext_ok" = "1" ]
        return
    fi
    print_error "КРИТИЧНО: не удалось восстановить ${Z2K_OLD_TREE_BACKUP} → ${ZAPRET2_DIR}."
    print_error "Старое дерево лежит в ${Z2K_OLD_TREE_BACKUP}, восстановите вручную: mv этой папки в ${ZAPRET2_DIR}."
    return 1
}
z2k_commit_install() {
    if [ -n "${Z2K_OLD_TREE_BACKUP:-}" ]; then
        rm -rf "$Z2K_OLD_TREE_BACKUP" "${Z2K_OLD_TREE_BACKUP}.ext" 2>/dev/null
        unset Z2K_OLD_TREE_BACKUP
    fi
}

# ==============================================================================
# MIGRATION: cleanup legacy ip host записей от снесённых модулей 2026-04-27
# ==============================================================================
# Между коммитами bb3fcba..a3e9c59 (DNS→Router migration, force-push'нут revert'ом)
# install.sh пропихнул в Keenetic running-config:
#   - 5 github записей на 213.176.74.63 (Module 1 github bootstrap)
#   - до 130 записей AI/media на 213.176.74.63 (Module 2 cloak_hosts.txt)
#   - 2 cloudflare записи на 2.58.104.1 если AS25513 (Module 3 МГТС)
#
# tpws youtube layer was REMOVED as a feature (2026-06-08): with
# net.netfilter.nf_conntrack_fastnat=0 the native nfqws2 bypass works on
# offloaded flows, so the transparent proxy (split-only, TCP-only, and it broke
# some TV apps) is no longer needed. This sweeps every trace of a previous
# tpws install so an UPDATE leaves no zombie: daemon, init script, NDM hook,
# watchdog, binary, nat REDIRECT (:1446) + mangle mark (v4/v6), ipsets, the
# youtube CIDR lists and the Z2K_TPWS flag. Idempotent — noop if tpws absent.
z2k_remove_tpws() {
    [ -x /opt/etc/init.d/S95z2k-tpws ] && /opt/etc/init.d/S95z2k-tpws stop >/dev/null 2>&1
    [ -r /opt/zapret2/z2k-tpws.sh ] && ( . /opt/zapret2/z2k-tpws.sh 2>/dev/null && z2k_tpws_remove_rules ) 2>/dev/null
    while iptables -w -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446 2>/dev/null; do
        iptables -w -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws dst -j REDIRECT --to-port 1446 2>/dev/null || break
    done
    while iptables -w -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null; do
        iptables -w -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null || break
    done
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -w -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446 2>/dev/null; do
            ip6tables -w -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set z2k_tpws6 dst -j REDIRECT --to-port 1446 2>/dev/null || break
        done
        while ip6tables -w -t mangle -C OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null; do
            ip6tables -w -t mangle -D OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j MARK --set-xmark 0x40000000/0x40000000 2>/dev/null || break
        done
    fi
    ipset destroy z2k_tpws 2>/dev/null || true
    ipset destroy z2k_tpws6 2>/dev/null || true
    rm -f /opt/etc/init.d/S95z2k-tpws \
          /opt/etc/ndm/netfilter.d/93-z2k-tpws-redirect.sh \
          /opt/zapret2/z2k-tpws.sh \
          /opt/zapret2/z2k-tpws-watchdog.sh \
          /opt/zapret2/lists/youtube_ips.txt \
          /opt/zapret2/lists/youtube_ips6.txt \
          /var/run/z2k-tpws.pid \
          /tmp/z2k-log/z2k-tpws.log 2>/dev/null || true
    rm -rf /opt/zapret2/tpws 2>/dev/null || true
    killall -9 tpws 2>/dev/null || true
    [ -f /opt/zapret2/config ] && sed -i '/^Z2K_TPWS=/d' /opt/zapret2/config 2>/dev/null
}

# Force-push снёс код, но записи в running-config persistent (system save).
# Юзеры с этого окна страдают: github проксируется через VPS Frankfurt → 5-10x
# медленнее, AI-домены идут через мёртвый теперь nginx-cloak-passthrough.
#
# Этот cleanup при каждом install убирает любые ip host записи с нашими VPS-IP
# и MГТС CF alt-anycast. Idempotent: на чистом роутере noop.
#
# NB: каждый вызов ndmc в z2k префиксован `LD_LIBRARY_PATH=`. На KeenOS 4.3+/5.x,
# когда LD_LIBRARY_PATH содержит Entware-пути (/opt/lib), ndmc грузит несовместимый
# OpenSSL и падает `system failed [0xcffd0060]` / `Cli::Main: failed to initialize`
# на КАЖДОМ вызове (установка идёт через `curl|sh` в этом замусоренном окружении →
# отсюда «портянка» и не ставится). Очистка переменной для конкретного вызова
# заставляет ndmc взять системный OpenSSL. (root cause подтверждён 2026-06-22,
# forum.keenetic.ru/topic/20203)
cleanup_legacy_ip_hosts() {
    command -v ndmc >/dev/null 2>&1 || return 0
    # 213.176.74.63 / 79.137.196.7 — always-purge legacy VPS Frankfurt IPs.
    # 2.58.104.1 — also a legitimate CF alt-anycast that z2k-classify
    # recommends for МГТС L3 bypass (z2k-classify/src/main.c:115-122,
    # recipe.c:376,417). DO NOT delete entries pointing CF SLDs at it —
    # those are user-applied L3 bypasses and must survive the cleanup.
    # Heuristic: hostname containing "cloudflare" is a classifier-emitted
    # L3 bypass; everything else on 2.58.104.1 was the legacy Module-3
    # МГТС catch-all and gets purged.
    local entries
    entries=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
        | awk '
            /^ip host/ {
                host = $3; ip = $4
                if (ip == "213.176.74.63" || ip == "79.137.196.7") {
                    # z2k whatsapp/ticketmaster relay pins legitimately point at
                    # the VPS now (default-on SNI-passthrough relay) — these are
                    # current, not legacy DNS-project leftovers. Keep them.
                    if (tolower(host) ~ /whatsapp\.(com|net)$|ticketmaster\.(com|net)$|ticketm\.net$|tmol\.(io|co)$/) next
                    print; next
                }
                if (ip == "2.58.104.1") {
                    if (tolower(host) ~ /cloudflare/) next
                    print
                }
            }' || true)
    # Under z2k.sh `set -e`, `[ -z "$x" ] && return 0` aborts the script
    # when $x is non-empty (the [ exits 1 because -z is false). Use if/fi.
    if [ -z "$entries" ]; then return 0; fi

    local removed=0 line
    local IFS_orig="$IFS"
    IFS='
'
    for line in $entries; do
        IFS="$IFS_orig"
        LD_LIBRARY_PATH= ndmc -c "no $line" >/dev/null 2>&1 && removed=$((removed + 1))
        IFS='
'
    done
    IFS="$IFS_orig"

    if [ "$removed" -gt 0 ]; then
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
        print_info "Migration: очищено $removed legacy ip host записей (DNS→Router 2026-04-27)"
    fi
    return 0
}

# Refresh stale ip host records that z2k_fetch's Layer 4 wrote in past
# install runs. These are in /opt/zapret2/state/ndmc-managed.txt — one
# `host ip` per line. We compare each tracked record against current
# DNS for that host: if the IP we wrote no longer matches the canonical
# resolution, drop it (saves the user from being pinned to a stale IP
# that GitHub/Fastly has rotated away from).
#
# Records the user added manually (not in our tracking file) are never
# touched. If the tracking file is missing — nothing to do.
refresh_stale_ndmc_records() {
    command -v ndmc >/dev/null 2>&1 || return 0
    local managed="${ZAPRET2_DIR:-/opt/zapret2}/state/ndmc-managed.txt"
    [ -s "$managed" ] || return 0
    command -v nslookup >/dev/null 2>&1 || return 0

    local removed=0 line host ip current
    while IFS=' ' read -r host ip; do
        [ -z "$host" ] || [ -z "$ip" ] && continue
        # Is this exact host=ip pair still present in running-config?
        LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
            | grep -qxE "ip host $host $ip" || continue
        # Resolve current canonical IP via 8.8.8.8.
        current=$(nslookup "$host" 8.8.8.8 2>/dev/null \
            | awk '/^Name:/ {s=1; next} s && /^Address [0-9]+: [0-9]+\./ {print $3; exit}')
        # If we couldn't resolve OR canonical IP differs, drop the stale
        # record. NDM will fall through to normal DNS for that host.
        if [ -z "$current" ] || [ "$current" != "$ip" ]; then
            LD_LIBRARY_PATH= ndmc -c "no ip host $host $ip" >/dev/null 2>&1 && removed=$((removed + 1))
        fi
    done < "$managed"

    if [ "$removed" -gt 0 ]; then
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
        # Rebuild the tracking file so we don't keep retrying records that
        # we already removed.
        local tmp="${managed}.new.$$"
        : > "$tmp"
        while IFS=' ' read -r host ip; do
            [ -z "$host" ] || [ -z "$ip" ] && continue
            LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
                | grep -qxE "ip host $host $ip" \
                && printf '%s %s\n' "$host" "$ip" >> "$tmp"
        done < "$managed"
        mv -f "$tmp" "$managed" 2>/dev/null
        print_info "Refresh: убрано $removed stale ip host записей (DNS-override layer)"
    fi
    return 0
}

# Purge any `ip host` record for our 4 known Layer-4 hostnames that
# was written by a pre-2026-04-28 z2k_fetch (no tracking file existed
# then). These are *always* records WE wrote — there's no legitimate
# reason a user would manually add `ip host raw.githubusercontent.com X`
# in their Keenetic config — it's solely a z2k-fetch artifact.
#
# Idempotent: on a clean router (or one already purged) — noop.
purge_legacy_ndmc_records() {
    command -v ndmc >/dev/null 2>&1 || return 0
    local managed="${ZAPRET2_DIR:-/opt/zapret2}/state/ndmc-managed.txt"

    # Hostnames z2k_fetch Layer 4 has ever written. Add new ones here
    # when extending z2k_fetch hostlist.
    local pattern="^ip host (raw\\.githubusercontent\\.com|cdn\\.jsdelivr\\.net|gh-proxy\\.com|api\\.github\\.com) "

    local entries
    # `|| true` masks grep's exit=1 on no-match (z2k.sh runs under set -e).
    entries=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null | grep -E "$pattern" || true)
    if [ -z "$entries" ]; then return 0; fi

    local removed=0 host ip line
    local IFS_orig="$IFS"
    IFS='
'
    for line in $entries; do
        IFS="$IFS_orig"
        host=$(printf '%s' "$line" | awk '{print $3}')
        ip=$(printf '%s' "$line" | awk '{print $4}')
        # If this exact pair is in the tracking file, skip — refresh_stale
        # will handle it correctly (it knows how to compare with current DNS).
        if [ -s "$managed" ] && grep -qxF "$host $ip" "$managed" 2>/dev/null; then
            IFS='
'
            continue
        fi
        # Untracked = written by old z2k_fetch before tracking existed.
        # Always remove. NDM falls through to normal DNS for these hosts.
        LD_LIBRARY_PATH= ndmc -c "no $line" >/dev/null 2>&1 && removed=$((removed + 1))
        IFS='
'
    done
    IFS="$IFS_orig"

    if [ "$removed" -gt 0 ]; then
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
        print_info "Purge: убрано $removed legacy ip host записей (Layer-4 наследие до streak-gate fix)"
    fi
    return 0
}

# ==============================================================================
# ШАГ 0: ПРОВЕРКА ROOT ПРАВ (КРИТИЧНО)
# ==============================================================================

step_check_root() {
    print_header "Шаг 0/12: Проверка прав доступа"

    print_info "Проверка root прав..."

    if [ "$(id -u)" -ne 0 ]; then
        print_error "Требуются root права для установки zapret2"
        print_separator
        print_info "Запустите установку с правами root:"
        printf "  sudo sh z2k.sh install\n\n"
        print_warning "Без root прав невозможно:"
        print_warning "  - Установить пакеты через opkg"
        print_warning "  - Создать init скрипт в /opt/etc/init.d/"
        print_warning "  - Настроить iptables правила"
        print_warning "  - Загрузить модули ядра"
        return 1
    fi

    print_success "Root права подтверждены (UID=$(id -u))"
    return 0
}

# ==============================================================================
# ШАГ 1: ОБНОВЛЕНИЕ ПАКЕТОВ
# ==============================================================================

step_update_packages() {
    print_header "Шаг 1/12: Обновление пакетов"

    print_info "Обновление списка пакетов Entware..."

    # On Keenetic rootfs is read-only squashfs. opkg tries to create its
    # temp dir in the current working directory and fails with
    # "opkg_conf_load: Creating temp dir /opkg-XXXX failed: Read-only
    # file system" unless TMPDIR points at a writable mount. /opt/tmp is
    # always writable on Entware installs. Previously this only bit
    # webpanel/install.sh (fixed 25c0ece); fresh installs via curl|sh
    # hit the same wall here on step 1/12 (Святой отец report 2026-04-17).
    export TMPDIR=/opt/tmp
    mkdir -p /opt/tmp 2>/dev/null || true

    # Попытка обновления с полным перехватом вывода
    local opkg_output
    opkg_output=$(opkg update 2>&1)
    local exit_code=$?

    # Показать вывод opkg
    echo "$opkg_output"

    if [ "$exit_code" -eq 0 ]; then
        print_success "Список пакетов обновлен"
        return 0
    else
        print_error "Не удалось обновить список пакетов (код: $exit_code)"

        # Проверка на Illegal instruction - типичная проблема на Keenetic из-за блокировки РКН
        if echo "$opkg_output" | grep -qi "illegal instruction"; then
            print_warning "Обнаружена ошибка 'Illegal instruction'"
            print_info "Это часто связано с блокировкой РКН репозитория bin.entware.net"
            print_separator

            # Попытка переключения на альтернативное зеркало (метод от zapret4rocket)
            print_info "Попытка переключения на альтернативное зеркало Entware..."

            local current_mirror
            current_mirror=$(grep -m1 "^src" /opt/etc/opkg.conf | awk '{print $3}' | grep -o 'bin.entware.net')

            if [ -n "$current_mirror" ]; then
                print_info "Меняю bin.entware.net → entware.diversion.ch"

                # Создать backup конфига
                cp /opt/etc/opkg.conf /opt/etc/opkg.conf.backup

                # Заменить зеркало
                sed -i 's|bin.entware.net|entware.diversion.ch|g' /opt/etc/opkg.conf

                print_info "Повторная попытка обновления с новым зеркалом..."

                # Повторить opkg update
                opkg_output=$(opkg update 2>&1)
                exit_code=$?

                echo "$opkg_output"

                if [ "$exit_code" -eq 0 ]; then
                    print_success "Список пакетов обновлен через альтернативное зеркало!"
                    print_info "Backup старого конфига: /opt/etc/opkg.conf.backup"
                    return 0
                else
                    print_error "Не помогло - ошибка осталась"
                    print_info "Восстанавливаю оригинальный конфиг..."
                    mv /opt/etc/opkg.conf.backup /opt/etc/opkg.conf
                fi
            else
                print_info "Зеркало bin.entware.net не найдено в конфиге"
            fi

            printf "\n"
        fi

        # Диагностика причины ошибки
        print_info "Углубленная диагностика проблемы..."
        print_separator

        # Анализ вывода opkg для определения точного места ошибки
        if echo "$opkg_output" | grep -q "Illegal instruction"; then
            # Попробовать найти контекст
            local error_context
            error_context=$(echo "$opkg_output" | grep -B2 "Illegal instruction" | head -5)
            if [ -n "$error_context" ]; then
                print_info "Контекст ошибки:"
                echo "$error_context"
            fi
        fi
        printf "\n"

        # 1. Проверка архитектуры системы
        local sys_arch
        sys_arch=$(uname -m)
        print_info "Архитектура системы: $sys_arch"

        # 2. Проверка архитектуры Entware
        if [ -f "/opt/etc/opkg.conf" ]; then
            local entware_arch
            entware_arch=$(grep -m1 "^arch" /opt/etc/opkg.conf | awk '{print $2}')
            print_info "Архитектура Entware: ${entware_arch:-не определена}"

            local repo_url
            repo_url=$(grep -m1 "^src" /opt/etc/opkg.conf | awk '{print $3}')
            print_info "Репозиторий: $repo_url"

            # 3. Проверка доступности репозитория
            if [ -n "$repo_url" ]; then
                print_info "Проверка доступности репозитория..."
                if curl -s -m 5 --head "$repo_url/Packages.gz" >/dev/null 2>&1; then
                    print_success "[OK] Репозиторий доступен"
                else
                    print_error "[FAIL] Репозиторий недоступен"
                fi
            fi
        fi

        # 4. Проверка самого opkg
        print_info "Проверка opkg бинарника..."
        if opkg --version 2>&1 | grep -qi "illegal"; then
            print_error "[FAIL] opkg --version падает (Illegal instruction)"
            print_warning "ПРИЧИНА: opkg установлен для неправильной архитектуры CPU!"
        elif opkg --version >/dev/null 2>&1; then
            local opkg_version
            opkg_version=$(opkg --version 2>&1 | head -1)
            print_success "[OK] opkg бинарник запускается: $opkg_version"
            print_warning "Но 'opkg update' падает - возможно проблема в зависимости или скрипте"
        else
            print_error "[FAIL] opkg не работает по неизвестной причине"
        fi

        # 5. Проверка файла opkg
        if command -v file >/dev/null 2>&1; then
            if [ -f "/opt/bin/opkg" ]; then
            local opkg_file_info
            opkg_file_info=$(file /opt/bin/opkg 2>&1 | head -1)
                print_info "Бинарник opkg: $opkg_file_info"
            fi
        fi

        print_separator

        # 6. Рекомендации по дополнительной диагностике
        print_info "Для детальной диагностики попробуйте вручную:"
        printf "  opkg update --verbosity=2\n\n"

        # Определяем основную причину на основе диагностики
        if opkg --version 2>&1 | grep -qi "illegal"; then
            cat <<'EOF'
[WARN]  КРИТИЧЕСКАЯ ПРОБЛЕМА: НЕПРАВИЛЬНАЯ АРХИТЕКТУРА ENTWARE

Диагностика показала: opkg не может выполниться на этом роутере.
Это означает что Entware установлен для НЕПРАВИЛЬНОЙ архитектуры CPU.

ПРИЧИНА:
Ваш роутер имеет процессор одной архитектуры, а установлен Entware
для другой архитектуры. Это как пытаться запустить программу для
Intel на процессоре ARM.

ЧТО ДЕЛАТЬ:
1. Удалите текущий Entware:
   - Зайдите в веб-интерфейс роутера
   - Система → Компоненты → Entware → Удалить

2. Установите ПРАВИЛЬНУЮ версию Entware:
   - Скачайте installer.sh с официального сайта
   - Убедитесь что выбрана версия для ВАШЕЙ модели роутера
   - https://help.keenetic.com/hc/ru/articles/360021888880

3. После переустановки запустите z2k снова

ВАЖНО: z2k не может работать с неправильной версией Entware!
EOF
        elif echo "$opkg_output" | grep -qi "illegal instruction"; then
            cat <<'EOF'
[WARN]  СЛОЖНАЯ ПРОБЛЕМА: opkg update падает с "Illegal instruction"

Диагностика и попытки исправления:
- [OK] opkg бинарник запускается (opkg --version работает)
- [OK] Архитектура системы корректная
- [OK] Репозиторий доступен (curl тест успешен)
- [OK] Попробовали альтернативное зеркало (entware.diversion.ch)
- [FAIL] НО "opkg update" всё равно падает с "Illegal instruction"

Это редкая проблема, которая может быть связана с:
1. Поврежденной зависимой библиотекой (libcurl, libssl, и др.)
2. Несовместимостью конкретной версии пакета с вашим CPU
3. Поврежденной базой данных opkg
4. Проблемой с самой установкой Entware

РЕКОМЕНДАЦИИ ПО УСТРАНЕНИЮ:

1. Проверьте какая библиотека вызывает ошибку:
   ldd /opt/bin/opkg
   (покажет все зависимые библиотеки)

2. Попробуйте детальную диагностику:
   opkg update --verbosity=2 2>&1 | tee /tmp/opkg_debug.log
   (сохранит полный вывод в файл)

3. Очистите кэш и попробуйте снова:
   rm -rf /opt/var/opkg-lists/*
   opkg update

4. Проверьте место на диске:
   df -h /opt
   (убедитесь что есть свободное место)

5. Если ничего не помогает - переустановите Entware:
   https://help.keenetic.com/hc/ru/articles/360021888880
   Убедитесь что выбираете версию Entware для вашей архитектуры!

ПРОДОЛЖИТЬ БЕЗ ОБНОВЛЕНИЯ?
Можно попробовать продолжить установку z2k.
Если нужные пакеты (iptables, ipset, curl) уже установлены -
всё может заработать и без обновления списков пакетов.
EOF
        else
            cat <<'EOF'
[WARN]  ОШИБКА ПРИ ОБНОВЛЕНИИ ПАКЕТОВ

Проверьте результаты диагностики выше.

Если репозиторий недоступен:
- Проблемы с сетью, DNS или блокировка
- Проверьте: curl -I http://bin.entware.net/

Если другая проблема:
- Попробуйте вручную: opkg update --verbosity=2
- Проверьте логи: cat /opt/var/log/opkg.log

ПРОДОЛЖИТЬ БЕЗ ОБНОВЛЕНИЯ?
Установка продолжится с текущими пакетами.
Обычно это безопасно, если пакеты уже установлены.
EOF
        fi
        # Non-interactive: продолжаем (opkg update не критичен — пакеты
        # обычно уже установлены, а если нет, упадём ниже с понятной
        # ошибкой). Auto-install policy: не зависаем на prompt.
        if [ ! -t 0 ] || [ ! -r /dev/tty ]; then
            print_info "Non-interactive — продолжаем без opkg update (пакеты обычно закешированы)"
            answer="y"
        else
        printf "\nПродолжить без opkg update? [Y/n]: "
        read -r answer </dev/tty
        fi

        case "$answer" in
            [Nn]|[Nn][Oo])
                print_info "Установка прервана"
                print_info "Исправьте проблему и запустите снова"
                return 1
                ;;
            *)
                print_warning "Продолжаем без обновления пакетов..."
                print_info "Будет использована текущая локальная база пакетов"
                return 0
                ;;
        esac
    fi
}

# ==============================================================================
# ШАГ 2: ПРОВЕРКА DNS (ВАЖНО)
# ==============================================================================

step_check_dns() {
    print_header "Шаг 2/12: Проверка DNS"

    print_info "Проверка работы DNS и доступности интернета..."

    # Проверить несколько серверов
    local test_hosts="github.com google.com cloudflare.com"
    local dns_works=0

    for host in $test_hosts; do
        if nslookup "$host" >/dev/null 2>&1; then
            print_success "DNS работает ($host разрешён)"
            dns_works=1
            break
        fi
    done

    if [ $dns_works -eq 0 ]; then
        print_error "DNS не работает!"
        print_separator
        print_warning "Возможные причины:"
        print_warning "  1. Нет подключения к интернету"
        print_warning "  2. DNS сервер не настроен"
        print_warning "  3. Блокировка РКН (bin.entware.net, github.com)"
        print_separator

        # Non-interactive: продолжаем — z2k_fetch имеет ndmc DNS-override
        # fallback (резолв через 8.8.8.8 + `ndmc ip host`), поэтому даже без
        # системного DNS скачивание может пройти. Если всё мёртво — упадём
        # ниже на download с понятной ошибкой (для диагностики). Auto-install
        # policy: пытаемся найти путь, а не abort'имся на prompt.
        if [ ! -t 0 ] || [ ! -r /dev/tty ]; then
            print_warning "Non-interactive — продолжаем без системного DNS (надежда на z2k_fetch ndmc-fallback)"
            answer="y"
        else
        printf "Продолжить установку без работающего DNS? [y/N]: "
        read -r answer </dev/tty
        fi

        case "$answer" in
            [Yy]*)
                print_warning "Продолжаем без DNS..."
                print_info "Установка может не удаться при загрузке файлов"
                return 0
                ;;
            *)
                print_info "Установка прервана"
                print_info "Исправьте DNS и запустите снова"
                return 1
                ;;
        esac
    fi

    return 0
}

# ==============================================================================
# ШАГ 3: УСТАНОВКА ЗАВИСИМОСТЕЙ (РАСШИРЕНО)
# ==============================================================================

step_install_dependencies() {
    print_header "Шаг 3/12: Установка зависимостей"

    # Список необходимых пакетов для Entware (только runtime).
    # iptables / xtables-addons_legacy / kmod_ndms — без них NFQUEUE-таргет
    # и расширенные matches (-m connbytes / -m connmark / -m multiport) тихо
    # фейлят в нашей iptables-генерации, итог: nfqws2 крутится впустую,
    # PREROUTING/POSTROUTING пусты, обход не работает. Уже два юзера за
    # неделю наступили на грабли (@Wasley871 Viva 2026-05-1X + сегодняшний
    # отчёт): встроенный Keenetic'овский iptables есть, но без xt_NFQUEUE
    # target и xtables-addons не справляется с z2k cmdline. kmod_ndms
    # нужен для NDM netfilter.d hook'ов.
    local packages="
libmnl
libnetfilter-queue
libnfnetlink
libcap
zlib
curl
unzip
iptables
xtables-addons_legacy
kmod_ndms
"

    print_info "Установка пакетов..."

    for pkg in $packages; do
        if opkg list-installed | grep -q "^${pkg} "; then
            print_info "$pkg уже установлен"
        else
            print_info "Установка $pkg..."
            opkg install "$pkg" || print_warning "Не удалось установить $pkg"
        fi
    done

    # Создать симлинки для библиотек (нужно для линковки)
    print_info "Создание симлинков библиотек..."

    # Создание симлинков в подоболочке (не меняет рабочую директорию)
    (
        cd /opt/lib || exit 1

        # libmnl
        if [ ! -e libmnl.so ] && [ -e libmnl.so.0 ]; then
            ln -sf libmnl.so.0 libmnl.so
        fi

        # libnetfilter_queue
        if [ ! -e libnetfilter_queue.so ] && [ -e libnetfilter_queue.so.1 ]; then
            ln -sf libnetfilter_queue.so.1 libnetfilter_queue.so
        fi

        # libnfnetlink
        if [ ! -e libnfnetlink.so ] && [ -e libnfnetlink.so.0 ]; then
            ln -sf libnfnetlink.so.0 libnfnetlink.so
        fi
    ) || print_warning "Не удалось создать симлинки в /opt/lib"
    print_info "Симлинки библиотек проверены"

    # =========================================================================
    # КРИТИЧНЫЕ ПАКЕТЫ ДЛЯ ZAPRET2 (из check_prerequisites_openwrt)
    # =========================================================================

    print_separator
    print_info "Установка критичных пакетов для zapret2..."

    local critical_packages=""

    # ipset - КРИТИЧНО для фильтрации по спискам доменов
    if ! opkg list-installed | grep -q "^ipset "; then
        print_info "ipset требуется для фильтрации трафика"
        critical_packages="$critical_packages ipset"
    else
        print_success "ipset уже установлен"
    fi

    # Проверка kernel модулей (на Keenetic встроены в ядро, не требуют установки)
    # xt_NFQUEUE - КРИТИЧНО для перенаправления в NFQUEUE
    if [ -f "/lib/modules/$(uname -r)/xt_NFQUEUE.ko" ] || lsmod | grep -q "xt_NFQUEUE" || modinfo xt_NFQUEUE >/dev/null 2>&1; then
        print_success "Модуль xt_NFQUEUE доступен"
    else
        print_warning "Модуль xt_NFQUEUE не найден (может быть встроен в ядро)"
    fi

    # xt_connbytes, xt_multiport - для фильтрации пакетов
    if modinfo xt_connbytes >/dev/null 2>&1 || grep -q "xt_connbytes" /proc/modules 2>/dev/null; then
        print_success "Модуль xt_connbytes доступен"
    else
        print_warning "Модуль xt_connbytes не найден (может быть встроен в ядро)"
    fi

    if modinfo xt_multiport >/dev/null 2>&1 || grep -q "xt_multiport" /proc/modules 2>/dev/null; then
        print_success "Модуль xt_multiport доступен"
    else
        print_warning "Модуль xt_multiport не найден (может быть встроен в ядро)"
    fi

    # Установить критичные пакеты если нужно (только ipset для Keenetic)
    if [ -n "$critical_packages" ]; then
        print_info "Установка:$critical_packages"
        if opkg install $critical_packages; then
            print_success "Критичные пакеты установлены"
        else
            print_error "Не удалось установить критичные пакеты"
            print_warning "zapret2 может не работать без этих пакетов!"

            # Без TTY (webpanel apply / auto-update / SSH без -t) read падает
            # с can't open /dev/tty под `set -e` — r-39 fix добавил guard
            # чтобы install не обрывался посередине. Но "просто продолжить"
            # в non-interactive контексте оставляет router в полу-сломанном
            # состоянии (без ipset не работает обход, см. Codex review
            # 2026-05-27). Fail closed: в non-interactive без override —
            # abort до destructive step_build_zapret2. Override через env
            # Z2K_ALLOW_INCOMPLETE_DEPS=1 для случаев когда юзер явно знает
            # что делает (например, если ipset уже стоит из другого пакета).
            if [ -t 0 ] && [ -r /dev/tty ]; then
                printf "Продолжить без них? [y/N]: "
                read -r answer </dev/tty
                case "$answer" in
                    [Yy]*) print_warning "Продолжаем на свой страх и риск..." ;;
                    *) return 1 ;;
                esac
            elif [ "${Z2K_ALLOW_INCOMPLETE_DEPS:-0}" = "1" ]; then
                print_warning "Z2K_ALLOW_INCOMPLETE_DEPS=1 override — продолжаем без критичных пакетов"
            else
                print_error "Non-interactive контекст: критичные пакеты не установлены."
                print_error "Установка прервана до destructive шагов чтобы не сломать рабочий router."
                print_error "Проверьте интернет/opkg feeds и запустите снова, либо exec'ните"
                print_error "Z2K_ALLOW_INCOMPLETE_DEPS=1 sh z2k.sh install если хотите проигнорировать."
                return 1
            fi
        fi
    else
        print_success "Все критичные пакеты уже установлены"
    fi

    # openssl-util — non-critical install для VPS-refresh Instagram-IP.
    # Скрипт z2k-insta-ip-refresh.sh использует `openssl dgst -sha256 -hmac`
    # для подписи запросов к VPS /resolve endpoint. README отправляет
    # ставить только libopenssl (runtime). Без CLI z2k в целом работает,
    # только Instagram-IP не подтягиваются с VPS — юзер сидит на shipped
    # дефолтах (деградация, не отказ). Поэтому НЕ critical: tolerant
    # error handling, warning при ошибке, install продолжается.
    if ! opkg list-installed | grep -q "^openssl-util "; then
        print_info "Ставим openssl-util (для VPS-refresh Instagram-IP)..."
        opkg update >/dev/null 2>&1
        if opkg install openssl-util >/dev/null 2>&1; then
            print_success "openssl-util установлен"
        else
            print_warning "openssl-util не установился — Instagram-IP не будет обновляться с VPS"
            print_warning "(z2k работает, страдает только периодическое обновление инста-edges)"
        fi
    else
        print_success "openssl-util уже установлен"
    fi

    print_separator
    print_info "ПРИМЕЧАНИЕ: На Keenetic модули iptables (xt_NFQUEUE, xt_connbytes,"
    print_info "xt_multiport) встроены в ядро и не требуют отдельной установки."

    # =========================================================================
    # ОПЦИОНАЛЬНЫЕ ОПТИМИЗАЦИИ (GNU gzip/sort)
    # =========================================================================

    print_separator
    print_info "Проверка опциональных оптимизаций..."

    # Проверить busybox gzip
    if command -v gzip >/dev/null 2>&1; then
        if readlink "$(command -v gzip)" 2>/dev/null | grep -q busybox; then
            print_info "Обнаружен busybox gzip (медленный, ~3x медленнее GNU)"
            if [ -t 0 ] && [ -r /dev/tty ]; then
                printf "Установить GNU gzip для ускорения обработки списков? [y/N]: "
                read -r answer </dev/tty
                case "$answer" in
                    [Yy]*)
                        if opkg install --force-overwrite gzip; then
                            print_success "GNU gzip установлен"
                        else
                            print_warning "Не удалось установить GNU gzip"
                        fi
                        ;;
                    *)
                        print_info "Пропускаем установку GNU gzip"
                        ;;
                esac
            else
                # Non-interactive (webpanel apply / auto-update / SSH без -t):
                # без TTY guard `read </dev/tty` падал с can't open под `set -e`
                # и обрывал install посередине (см. r-39 fix для critical packages).
                # Optional opt-in — пропускаем без вопроса.
                print_info "Non-interactive контекст — пропускаем установку GNU gzip"
            fi
        fi
    fi

    # Проверить busybox sort
    if command -v sort >/dev/null 2>&1; then
        if readlink "$(command -v sort)" 2>/dev/null | grep -q busybox; then
            print_info "Обнаружен busybox sort (медленный, использует много RAM)"
            if [ -t 0 ] && [ -r /dev/tty ]; then
                printf "Установить GNU sort для ускорения? [y/N]: "
                read -r answer </dev/tty
                case "$answer" in
                    [Yy]*)
                        if opkg install --force-overwrite coreutils-sort; then
                            print_success "GNU sort установлен"
                        else
                            print_warning "Не удалось установить GNU sort"
                        fi
                        ;;
                    *)
                        print_info "Пропускаем установку GNU sort"
                        ;;
                esac
            else
                print_info "Non-interactive контекст — пропускаем установку GNU sort"
            fi
        fi
    fi

    print_success "Зависимости установлены"
    return 0
}

# ==============================================================================
# ШАГ 4: ЗАГРУЗКА МОДУЛЕЙ ЯДРА
# ==============================================================================

step_load_kernel_modules() {
    print_header "Шаг 4/12: Загрузка модулей ядра"

    local modules="xt_multiport xt_connbytes xt_NFQUEUE nfnetlink_queue"

    for module in $modules; do
        load_kernel_module "$module" || print_warning "Модуль $module не загружен"
    done

    # Load ip_set_bitmap_port from system modules (Entware modprobe cannot find it)
    if ! lsmod | grep -q "ip_set_bitmap_port"; then
        insmod "/lib/modules/$(uname -r)/ip_set_bitmap_port.ko" 2>/dev/null || true
    fi

    print_success "Модули ядра загружены"
    return 0
}

# ==============================================================================
# ШАГ 5: УСТАНОВКА ZAPRET2 (ИСПОЛЬЗУЯ ОФИЦИАЛЬНЫЙ install_bin.sh)
# ==============================================================================

download_openwrt_embedded_release() {
    local url="$1"
    local dest="$2"
    local proxy_url=""

    rm -f "$dest"

    print_info "Пробую скачать релиз напрямую с GitHub..."
    if curl -fsSL --connect-timeout 10 --max-time "${Z2K_RELEASE_DIRECT_TIMEOUT:-45}" \
        "$url" -o "$dest"; then
        return 0
    fi
    rm -f "$dest"

    case "$url" in
        https://github.com/*/releases/download/*)
            proxy_url="https://gh-proxy.com/${url}"
            print_warning "GitHub release недоступен — пробую зеркало gh-proxy"
            if curl -fsSL --connect-timeout 10 --max-time "${Z2K_RELEASE_PROXY_TIMEOUT:-180}" \
                "$proxy_url" -o "$dest"; then
                return 0
            fi
            rm -f "$dest"
            ;;
    esac

    if command -v z2k_fetch >/dev/null 2>&1; then
        print_warning "Обычные release-зеркала не сработали — пробую DoH/NDM fallback"
        Z2K_FETCH_PREFER_DOH=1 Z2K_FETCH_NDMC_THRESHOLD=1 \
            z2k_fetch "$url" "$dest" && return 0
        rm -f "$dest"
    fi

    return 1
}

step_build_zapret2() {
    print_header "Шаг 5/12: Установка zapret2"

    # Pre-flight hostlist availability check. Stage critical snapshots в /tmp
    # BEFORE мы трогаем ${ZAPRET2_DIR} — если ни WORK_DIR ни GitHub-fallback
    # не доступны, прерываем install ДО `rm -rf` чтобы рабочая установка
    # юзера не превратилась в полу-сломанный остаток. Codex review 2026-05-27
    # flagged предыдущую логику: deploy_critical_file → die после rm -rf
    # оставлял router в un-restorable состоянии. Эта стадия — read-only:
    # на failure ничего не модифицирует, только cleanup'ит свой /tmp dir.
    # Staging под WORK_DIR: при USB-fallback (Z2K_WORKDIR_ON_OPT=1) WORK_DIR
    # уже на /opt, значит и prefetch уйдёт на USB, а не в переполненный /tmp
    # (Codex 2026-05-28: иначе fallback неполный — большие списки всё равно
    # стейджатся в tmpfs и install падает в том самом low-/tmp сценарии).
    local _stage_base="${WORK_DIR:-/tmp/z2k}"
    mkdir -p "$_stage_base" 2>/dev/null
    local _prefetch_dir="${_stage_base}/prefetch-lists.$$"
    rm -rf "$_prefetch_dir"
    mkdir -p "$_prefetch_dir" || die "Не удалось создать staging директорию ${_prefetch_dir}"
    local _hostlist _src_work _stage_dst
    for _hostlist in \
        files/lists/extra_strats/TCP/YT/List.txt \
        files/lists/extra_strats/TCP/YT_GV/List.txt \
        files/lists/extra_strats/TCP/RKN/List.txt \
        files/lists/extra_strats/UDP/YT/List.txt; do
        _src_work="${WORK_DIR}/${_hostlist}"
        # Encode path into a flat filename: extra_strats__TCP__YT__List.txt etc.
        # Avoids nested mkdir noise в staging dir; full path хранится в map ниже.
        _stage_dst="${_prefetch_dir}/$(printf '%s' "${_hostlist#files/lists/}" | tr '/' '_')"
        if [ -s "$_src_work" ]; then
            cp -f "$_src_work" "$_stage_dst" 2>/dev/null
        fi
        if [ ! -s "$_stage_dst" ]; then
            if command -v z2k_fetch >/dev/null 2>&1; then
                z2k_fetch "/${_hostlist}" "$_stage_dst" 2>/dev/null
                rm -f "${_stage_dst}.etag" 2>/dev/null
            fi
        fi
        if [ ! -s "$_stage_dst" ]; then
            rm -rf "$_prefetch_dir"
            die "Pre-flight: критичный hostlist ${_hostlist} не доступен ни из WORK_DIR, ни через GitHub fallback (raw/jsdelivr/gh-proxy). Установка прервана БЕЗ удаления существующей копии — проверьте интернет/DNS/CDN и запустите снова. Текущая установка не тронута."
        fi
    done
    # Same for non-critical Discord.txt — staging без fail (warning later).
    local _src_discord="${WORK_DIR}/files/lists/extra_strats/TCP/RKN/Discord.txt"
    local _stage_discord="${_prefetch_dir}/extra_strats_TCP_RKN_Discord.txt"
    if [ -s "$_src_discord" ]; then
        cp -f "$_src_discord" "$_stage_discord" 2>/dev/null
    fi
    if [ ! -s "$_stage_discord" ] && command -v z2k_fetch >/dev/null 2>&1; then
        z2k_fetch "/files/lists/extra_strats/TCP/RKN/Discord.txt" "$_stage_discord" 2>/dev/null
        rm -f "${_stage_discord}.etag" 2>/dev/null
    fi
    export Z2K_PREFETCH_LISTS_DIR="$_prefetch_dir"

    # Сохранить пользовательские данные перед удалением
    local backup_tmp="/opt/z2k-upgrade-backup"
    rm -rf "$backup_tmp"
    if [ -d "$ZAPRET2_DIR" ]; then
        print_info "Сохранение пользовательских настроек..."
        if ! mkdir -p "$backup_tmp"; then
            die "Не удалось создать каталог бэкапа ${backup_tmp} — установка прервана БЕЗ удаления текущей (нет места на /opt?). Ваши настройки не тронуты."
        fi
        # Config (содержит DROP_DPI_RST, RKN_SILENT_FALLBACK и др.) — critical
        # user state. Backup идёт ДО mv старого дерева; если config есть, но
        # скопировать не удалось — abort, иначе commit (delete old) безвозвратно
        # потеряет настройки (Codex 2026-05-28). На /opt место есть почти
        # всегда, но проверяем явно.
        if [ -f "$ZAPRET2_DIR/config" ]; then
            cp -f "$ZAPRET2_DIR/config" "$backup_tmp/config" || \
                die "Не удалось сохранить config в бэкап — установка прервана до удаления текущей, чтобы не потерять ваши настройки."
        fi
        # Whitelist (пользовательские исключения) — невосстановимый user-data,
        # backup обязателен. Если есть но не скопировался — abort до mv старого
        # дерева, иначе commit его сотрёт безвозвратно (Codex 2026-05-28).
        if [ -f "$ZAPRET2_DIR/lists/whitelist.txt" ]; then
            cp -f "$ZAPRET2_DIR/lists/whitelist.txt" "$backup_tmp/whitelist.txt" || \
                die "Не удалось сохранить whitelist в бэкап — установка прервана, чтобы не потерять ваши исключения."
        fi
        # extra-domains.txt — юзерские добавки (echo >> extra-domains.txt).
        # Тоже невосстановимый user-data — backup обязателен.
        if [ -f "$ZAPRET2_DIR/lists/extra-domains.txt" ]; then
            cp -f "$ZAPRET2_DIR/lists/extra-domains.txt" "$backup_tmp/extra-domains.txt" || \
                die "Не удалось сохранить extra-domains в бэкап — установка прервана, чтобы не потерять ваши домены."
        fi
        # Autocircular state (найденные рабочие стратегии) — recoverable
        # (autocircular переподберёт стратегии заново), поэтому НЕ fatal:
        # warn и продолжаем, не блокируя установку ради cache.
        if [ -f "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv" ]; then
            cp -f "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv" "$backup_tmp/state.tsv" || \
                print_warning "Не удалось сохранить state.tsv — стратегии переподберутся автоматически после установки."
        fi
        # Per-install relay identity (Stage B): the Ed25519 keypair + install_id the
        # tunnel client minted once. Preserve across reinstall so the device keeps the
        # SAME registered identity (re-minting orphans the old registry entry and
        # forces a re-register). Recoverable (client re-mints+registers if lost) — so
        # warn, not fatal.
        if [ -f "$ZAPRET2_DIR/.z2k-relay-id" ]; then
            cp -f "$ZAPRET2_DIR/.z2k-relay-id" "$backup_tmp/z2k-relay-id" || \
                print_warning "Не удалось сохранить relay-id — будет переминчен (новая регистрация)."
        fi
        # Strategy.txt — shipped, не user-owned. Не бэкапим: при реустановке/апдейте
        # свежая shipped-версия из репо побеждает (см. feedback_z2k_user_overrides_policy).
        # Silent fallback flag
        [ -f "$ZAPRET2_DIR/extra_strats/cache/autocircular/rkn_silent_fallback.flag" ] && \
            touch "$backup_tmp/rkn_silent_fallback.flag"
        # Webpanel state — opt-in component (installed via menu [P] → 1).
        # Сохраняем port+bind (lighttpd binding) чтобы после reinstall'а
        # автоматически re-install'нуть webpanel на тех же значениях.
        # Сами файлы webpanel'и (cgi/www/lighttpd.conf) пере-копируются
        # из свежих shipped sources через webpanel/install.sh — намеренно,
        # чтобы обновления вебпанели доезжали без участия юзера. Init-
        # скрипт S96 живёт в /opt/etc/init.d/, не в /opt/zapret2/, поэтому
        # rm -rf $ZAPRET2_DIR его не сносит — но он указывает на пустой
        # после reinstall'а /opt/zapret2/webpanel и lighttpd не стартует.
        # Без этого backup'а webpanel юзера тихо ломается на любом auto-
        # update reinstall'е.
        if [ -f "$ZAPRET2_DIR/webpanel/port" ]; then
            cp -f "$ZAPRET2_DIR/webpanel/port" "$backup_tmp/webpanel-port"
            [ -f "$ZAPRET2_DIR/webpanel/bind" ] && \
                cp -f "$ZAPRET2_DIR/webpanel/bind" "$backup_tmp/webpanel-bind"
            print_success "Webpanel state сохранён (port=$(cat "$backup_tmp/webpanel-port" 2>/dev/null), bind=$(cat "$backup_tmp/webpanel-bind" 2>/dev/null || echo auto))"
        fi
        print_success "Настройки сохранены"

        # Backup legacy orchestra/ data (locked.tsv / locked.manual.tsv) на случай если
        # у пользователя были learned/manual locks от upstream'овского orchestrator'а.
        # Auto-migration не делаем (см. PLAN_orchestrator_replacement.md, A4 Legacy lock
        # migration policy). Fail-closed: при failed cp прерываем install.
        if [ -d "$ZAPRET2_DIR/extra_strats/cache/orchestra" ]; then
            if [ -n "$(ls -A "$ZAPRET2_DIR/extra_strats/cache/orchestra/" 2>/dev/null)" ]; then
                # SC2155 compliance: declare и assign separately, чтобы exit
                # code `date` не маскировался успешным `local`.
                local _orch_backup
                _orch_backup="/tmp/z2k-legacy-orchestra-$(date +%Y%m%d-%H%M%S)"
                if cp -a "$ZAPRET2_DIR/extra_strats/cache/orchestra" "$_orch_backup" 2>/dev/null; then
                    print_warning "Legacy orchestra/ saved to $_orch_backup (locks НЕ мигрируются автоматически)"
                else
                    print_error "Failed to backup $ZAPRET2_DIR/extra_strats/cache/orchestra → $_orch_backup"
                    print_error "Aborting cleanup чтобы не потерять legacy lock state."
                    print_error "Освободите место в /tmp или manually переместите orchestra/ перед повторным reinstall."
                    return 1
                fi
            fi
        fi

        # Transactional: переименовываем (не rm -rf) старое дерево в .old.$$
        # чтобы можно было откатиться если любой шаг ниже провалится. mv
        # мгновенен и не требует доп. места (rename на том же fs). На
        # success — z2k_commit_install (в run_full_install) удалит backup.
        print_info "Сохранение старой установки для отката (mv → .old)..."
        local _old_tree="${ZAPRET2_DIR}.old.$$"
        rm -rf "$_old_tree" 2>/dev/null
        if mv "$ZAPRET2_DIR" "$_old_tree" 2>/dev/null; then
            export Z2K_OLD_TREE_BACKUP="$_old_tree"
            print_success "Старая установка отложена в ${_old_tree} (откат при сбое)"
        else
            # mv не удался (cross-device? на Entware крайне редко). FAIL-CLOSED
            # (Codex 2026-05-28): НЕ удаляем рабочую установку — без неё откат
            # невозможен, и любой сбой шагов 5-12 оставил бы router вообще без
            # zapret2. Прерываем install, старое дерево остаётся на месте и
            # продолжает работать; юзер просто остаётся на текущей версии.
            print_error "Не удалось отложить старую установку (mv → .old) — прерываю установку БЕЗ удаления текущей. Ваша рабочая версия не тронута."
            unset Z2K_OLD_TREE_BACKUP
            return 1
        fi
    fi

    # Создать временную директорию для распаковки tarball. Под staging base
    # (= WORK_DIR): при USB-fallback уходит на /opt, не в переполненный /tmp.
    local build_dir="${_stage_base:-/tmp}/zapret2_build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    cd "$build_dir" || return 1

    # ===========================================================================
    # ШАГ 4.1: Скачать OpenWrt embedded релиз (содержит всё необходимое)
    # ===========================================================================

    print_info "Загрузка zapret2 OpenWrt embedded релиза..."

    # GitHub API для получения последней версии
    # ВАЖНО: z2k использует наш форк necronicle/zapret2-z2k вместо bol-van/zapret2.
    # Форк даёт те же бинарники upstream + наши packet-level патчи под ТСПУ
    # (см. z2k-enhanced PART II roadmap). Layout tarball-а идентичен upstream
    # поэтому остальная install-логика ниже работает без изменений.
    local api_url="https://api.github.com/repos/necronicle/zapret2-z2k/releases/latest"
    local fallback_url="https://github.com/necronicle/zapret2-z2k/releases/download/v1.0-z2k-r0/zapret2-v1.0-z2k-r0-openwrt-embedded.tar.gz"
    local openwrt_url=""

    # Try the API via z2k_fetch (it triggers the layer-4 ndmc DNS
    # override on api.github.com if the host is poisoned by the user's
    # ISP — common with mobile RU carriers blocking SNI on github).
    local api_tmp="/tmp/z2k-release-api.$$.json"
    if z2k_fetch "$api_url" "$api_tmp" && [ -s "$api_tmp" ]; then
        openwrt_url=$(grep -o 'https://github.com/necronicle/zapret2-z2k/releases/download/[^"]*openwrt-embedded\.tar\.gz' "$api_tmp" | head -1)
    fi
    rm -f "$api_tmp"

    if [ -z "$openwrt_url" ]; then
        print_warning "API недоступен или ответ пуст — использую fallback v1.0-z2k-r0"
        openwrt_url="$fallback_url"
    fi

    print_info "URL релиза: $openwrt_url"

    # Скачать релиз через явную цепочку зеркал. Для GitHub release assets
    # jsdelivr не подходит, поэтому порядок такой:
    #   1. github.com/releases/download
    #   2. gh-proxy.com/github.com/releases/download
    #   3. z2k_fetch heavy fallback (DoH + NDM DNS pinning)
    # Если tarball уже лежит в cwd (build_dir = /tmp/zapret2_build) — пропускаем
    # скачивание. Этот путь нужен пользователям с жёстким провайдер-блоком где
    # все 5 наших слоёв не пробивают, но юзер вручную скачал tarball через DoH
    # с другой машины / другим curl-вызовом и подложил сюда.
    if [ -s openwrt-embedded.tar.gz ]; then
        print_info "tarball уже в кэше build_dir — пропускаем скачивание"
    elif ! download_openwrt_embedded_release "$openwrt_url" "openwrt-embedded.tar.gz"; then
        print_error "Не удалось загрузить zapret2 OpenWrt embedded (все зеркала)"
        print_info "Можно скачать вручную и положить в /tmp/zapret2_build/openwrt-embedded.tar.gz, перезапустить установку"
        return 1
    fi

    print_success "Релиз загружен ($(du -h openwrt-embedded.tar.gz | cut -f1))"

    # ===========================================================================
    # ШАГ 4.2: Распаковать полную структуру релиза
    # ===========================================================================

    print_info "Распаковка релиза..."

    tar -xzf openwrt-embedded.tar.gz || {
        print_error "Ошибка распаковки архива"
        return 1
    }

    # Найти корневую директорию релиза (zapret2-vX.Y.Z)
    local release_dir
    release_dir=$(find . -maxdepth 1 -type d -name "zapret2-v*" | head -1)

    if [ -z "$release_dir" ] || [ ! -d "$release_dir" ]; then
        print_error "Не найдена директория релиза в архиве"
        ls -la
        return 1
    fi

    print_success "Релиз распакован: $release_dir"

    # ===========================================================================
    # ШАГ 4.3: Использовать install_bin.sh для установки бинарников
    # ===========================================================================

    print_info "Определение архитектуры и установка бинарников..."

    cd "$release_dir" || return 1

    # Установить переменные окружения для install_bin.sh
    export ZAPRET_BASE="$PWD"

    # Проверить наличие install_bin.sh
    if [ ! -f "install_bin.sh" ]; then
        print_error "install_bin.sh не найден в релизе"
        return 1
    fi

    # Вызвать install_bin.sh для автоматической установки бинарников
    print_info "Запуск официального install_bin.sh..."

    if sh install_bin.sh; then
        print_success "Бинарники установлены через install_bin.sh"
    else
        print_error "install_bin.sh завершился с ошибкой"
        print_info "Попытка ручной установки..."

        # Fallback: ручная установка если install_bin.sh не сработал
        local sys_arch entware_arch arch bin_arch opkg_bin
        sys_arch=$(uname -m)
        entware_arch=""
        opkg_bin="opkg"
        [ -x /opt/bin/opkg ] && opkg_bin="/opt/bin/opkg"

        if command -v "$opkg_bin" >/dev/null 2>&1; then
            entware_arch=$("$opkg_bin" print-architecture 2>/dev/null | awk '
                $1 == "arch" && $2 != "all" {
                    prio = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
                    if (prio >= max) { max = prio; arch = $2 }
                }
                END { if (arch != "") print arch }
            ')
        fi

        arch="${entware_arch:-$sys_arch}"
        bin_arch=""

        case "$arch" in
            aarch64|arm64|*aarch64*|*arm64*) bin_arch="linux-arm64" ;;
            armv7l|armv6l|arm|*armv7*|*armv6*|arm*) bin_arch="linux-arm" ;;
            x86_64|amd64|*x86_64*|*amd64*) bin_arch="linux-x86_64" ;;
            i386|i486|i586|i686|x86) bin_arch="linux-x86" ;;
            *mipsel64*|*mips64el*) bin_arch="linux-mipsel" ;;
            *mips64*) bin_arch="linux-mips64" ;;
            *mipsel*) bin_arch="linux-mipsel" ;;
            *mips*) bin_arch="linux-mips" ;;
            *lexra*) bin_arch="linux-lexra" ;;
            *ppc*) bin_arch="linux-ppc" ;;
            *riscv64*) bin_arch="linux-riscv64" ;;
            *)
                print_error "Unsupported architecture: $arch (uname=$sys_arch${entware_arch:+, opkg=$entware_arch})"
                return 1
                ;;
        esac

        print_info "Auto-detected architecture: uname=$sys_arch${entware_arch:+, opkg=$entware_arch} -> $bin_arch"

        if [ ! -d "binaries/$bin_arch" ]; then
            print_error "Бинарники для $bin_arch не найдены"
            return 1
        fi

        # Создать директории и установить бинарники вручную
        mkdir -p nfq2 ip2net mdig
        cp "binaries/$bin_arch/nfqws2" nfq2/ || return 1
        cp "binaries/$bin_arch/ip2net" ip2net/ || return 1
        cp "binaries/$bin_arch/mdig" mdig/ || return 1
        chmod +x nfq2/nfqws2 ip2net/ip2net mdig/mdig

        print_success "Бинарники установлены вручную для $bin_arch"
    fi

    # Проверить что nfqws2 исполняемый и работает
    if [ ! -x "nfq2/nfqws2" ]; then
        print_error "nfqws2 не найден или не исполняемый после установки"
        return 1
    fi

    # Проверить запуск
    if ! ./nfq2/nfqws2 --version >/dev/null 2>&1; then
        print_warning "nfqws2 не может быть запущен (возможно не та архитектура)"
        print_info "Вывод --version:"
        ./nfq2/nfqws2 --version 2>&1 | head -5 || true
    else
        local version
        version=$(./nfq2/nfqws2 --version 2>&1 | head -1)
        print_success "nfqws2 работает: $version"
    fi

    # ===========================================================================
    # ШАГ 4.4: Переместить в финальную директорию
    # ===========================================================================

    print_info "Установка в $ZAPRET2_DIR..."

    cd "$build_dir" || return 1
    cp -a "$release_dir" "$ZAPRET2_DIR" && rm -rf "$release_dir" || return 1

    # ВАЖНО: Обновить ZAPRET_BASE на финальный путь (был /tmp/zapret2_build/...)
    export ZAPRET_BASE="$ZAPRET2_DIR"

    # ===========================================================================
    # ШАГ 4.5: Добавить кастомные файлы из z2k репозитория
    # ===========================================================================

    print_info "Копирование дополнительных файлов..."

    # Скопировать strats_new2.txt если есть в z2k репозитории
    if [ -f "${WORK_DIR}/strats_new2.txt" ]; then
        cp -f "${WORK_DIR}/strats_new2.txt" "${ZAPRET2_DIR}/" || \
            print_warning "Не удалось скопировать strats_new2.txt"
    fi

    # Скопировать quic_strats.ini если есть
    if [ -f "${WORK_DIR}/quic_strats.ini" ]; then
        cp -f "${WORK_DIR}/quic_strats.ini" "${ZAPRET2_DIR}/" || \
            print_warning "Не удалось скопировать quic_strats.ini"
    fi

    # Скопировать кастомные lua-хелперы z2k (например, персистентность autocircular)
    if [ -d "${WORK_DIR}/files/lua" ]; then
        mkdir -p "${ZAPRET2_DIR}/lua"
        cp -f "${WORK_DIR}/files/lua/"*.lua "${ZAPRET2_DIR}/lua/" 2>/dev/null || true
    fi

    # Обновить fake blobs если есть более свежие в z2k
    if [ -d "${WORK_DIR}/files/fake" ]; then
        print_info "Updating fake blobs from z2k..."
        cp -f "${WORK_DIR}/files/fake/"* "${ZAPRET2_DIR}/files/fake/" 2>/dev/null || true
    fi

    # Create blob aliases: strategies use short names, files have full names
    local fakedir="${ZAPRET2_DIR}/files/fake"
    if [ -d "$fakedir" ]; then
        # tls_max_ru → tls_clienthello_max_ru.bin
        [ ! -e "$fakedir/tls_max_ru" ] && [ -f "$fakedir/tls_clienthello_max_ru.bin" ] && \
            ln -sf tls_clienthello_max_ru.bin "$fakedir/tls_max_ru"
        # quic short aliases → quic_N.bin
        [ ! -e "$fakedir/quic1" ] && [ -f "$fakedir/quic_1.bin" ] && ln -sf quic_1.bin "$fakedir/quic1"
        [ ! -e "$fakedir/quic4" ] && [ -f "$fakedir/quic_4.bin" ] && ln -sf quic_4.bin "$fakedir/quic4"
        [ ! -e "$fakedir/quic5" ] && [ -f "$fakedir/quic_5.bin" ] && ln -sf quic_5.bin "$fakedir/quic5"
        [ ! -e "$fakedir/quic6" ] && [ -f "$fakedir/quic_6.bin" ] && ln -sf quic_6.bin "$fakedir/quic6"
        # quic_google → quic_initial_www_google_com.bin
        # (shipped file uses www_ prefix; earlier link target without www_
        # never existed, so before this fix the symlink was never created and
        # `blob=quic_google` strategies fell through with nil blob → fake
        # desync was effectively no-op)
        [ ! -e "$fakedir/quic_google" ] && [ -f "$fakedir/quic_initial_www_google_com.bin" ] && \
            ln -sf quic_initial_www_google_com.bin "$fakedir/quic_google"
        # quic_rutracker → quic_initial_rutracker_org.bin
        [ ! -e "$fakedir/quic_rutracker" ] && [ -f "$fakedir/quic_initial_rutracker_org.bin" ] && \
            ln -sf quic_initial_rutracker_org.bin "$fakedir/quic_rutracker"
        # quic_dbankcloud → quic_initial_dbankcloud_ru.bin
        # (referenced by discord_udp strats 1-4 + game-mode default arm)
        [ ! -e "$fakedir/quic_dbankcloud" ] && [ -f "$fakedir/quic_initial_dbankcloud_ru.bin" ] && \
            ln -sf quic_initial_dbankcloud_ru.bin "$fakedir/quic_dbankcloud"
    fi

    # Install blocked-monitor helper (runtime diagnostics for blocked domains).
    if [ -f "${WORK_DIR}/files/z2k-blocked-monitor.sh" ]; then
        cp -f "${WORK_DIR}/files/z2k-blocked-monitor.sh" "${ZAPRET2_DIR}/z2k-blocked-monitor.sh" 2>/dev/null || true
        chmod +x "${ZAPRET2_DIR}/z2k-blocked-monitor.sh" 2>/dev/null || true
    fi

    # One-shot cleanup of r-15 Phase 1 obsolete tools. Marker-gated so it runs
    # exactly once per box; subsequent reinstalls/auto-updates are no-ops.
    # z2k-probe.sh / z2k-classify(.go|-drift.sh|-inject.sh|-* binary) — see
    # the menu_probe() / menu_classify() removal in lib/menu.sh + the
    # server_active_reject taxonomy that replaces them.
    # z2k-dynamic-strategy.lua + dynamic-slots.conf + classify-* TSVs —
    # producer was the classify CLI; slot in config_official.sh removed.
    # r-17 one-shot: чистим раскиданные googlevideo entries из YT/List и
    # выделяем GV в свой dedicated hostlist `extra_strats/TCP/YT_GV/List.txt`.
    #
    # Раньше apex `googlevideo.com` лежал в YT/List.txt и перехватывал ВЕСЬ
    # *.googlevideo.com трафик в yt_tcp профиль ДО того, как второй nfqws2
    # блок (inline `--hostlist-domains=googlevideo.com key=gv_tcp`) его
    # увидит. gv_tcp фактически мёртв, rotator yt_tcp крутит свои стратегии
    # (заточенные под youtube.com) на чужом домене — отсюда «много ротаций
    # на GV». В r-17 переходим на схему «каждый профиль — свой hostlist
    # файл»: убираем apex и manifest.googlevideo.com из YT/List, создаём
    # YT_GV/List.txt с apex (suffix-match покрывает все поддомены).
    if [ ! -f "$ZAPRET2_DIR/.gv_apex_hostlist_fix.done" ]; then
        local yt_list="$ZAPRET2_DIR/extra_strats/TCP/YT/List.txt"
        local yt_gv_list="$ZAPRET2_DIR/extra_strats/TCP/YT_GV/List.txt"
        local touched=""

        # 1. Убрать любые googlevideo entries из YT/List (apex и manifest).
        if [ -f "$yt_list" ] && grep -qE '^(googlevideo\.com|manifest\.googlevideo\.com)$' "$yt_list" 2>/dev/null; then
            sed -i -E '/^(googlevideo\.com|manifest\.googlevideo\.com)$/d' "$yt_list" 2>/dev/null
            touched="yt-list"
        fi

        # 2. Гарантировать что YT_GV/List.txt существует с apex googlevideo.com.
        # install.sh ниже скопирует shipped версию из files/lists/, но миграция
        # запускается рано — обеспечиваем минимальный валидный list прямо
        # сейчас, чтобы NFQWS2_OPT generation не пропустил gv_tcp профиль
        # из-за empty hostlist file.
        if [ ! -s "$yt_gv_list" ]; then
            mkdir -p "$(dirname "$yt_gv_list")" 2>/dev/null
            echo 'googlevideo.com' > "$yt_gv_list" 2>/dev/null
            touched="${touched:+$touched, }yt-gv-list"
        fi

        # 3. Сбросить stale yt_tcp записи для googlevideo.com (apex + manifest +
        # любые поддомены). nfqws2 рестартанётся ниже в install потоке —
        # in-memory state перечитается из state.tsv с нуля для этих хостов.
        local _state="$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv"
        if [ -f "$_state" ] && grep -qE '^yt_tcp\s+([a-zA-Z0-9_-]+\.)*googlevideo\.com\s' "$_state" 2>/dev/null; then
            awk -F'\t' '!($1=="yt_tcp" && $2 ~ /googlevideo\.com$/)' "$_state" > "$_state.gvfix" 2>/dev/null \
                && cat "$_state.gvfix" > "$_state" && rm -f "$_state.gvfix"
            touched="${touched:+$touched, }state"
        fi

        if [ -n "$touched" ]; then
            print_info "r-17 cleanup ($touched): YT/List очищен от googlevideo, gv_tcp получает свой dedicated hostlist"
        fi
        touch "$ZAPRET2_DIR/.gv_apex_hostlist_fix.done" 2>/dev/null || true
    fi

    if [ ! -f "$ZAPRET2_DIR/.classify_probe_removed.done" ]; then
        rm -f "$ZAPRET2_DIR/z2k-probe.sh" 2>/dev/null
        rm -f "$ZAPRET2_DIR/z2k-classify" 2>/dev/null
        rm -f "$ZAPRET2_DIR/z2k-classify-drift.sh" 2>/dev/null
        rm -f "$ZAPRET2_DIR/z2k-classify-inject.sh" 2>/dev/null
        rm -f "$ZAPRET2_DIR/lua/z2k-dynamic-strategy.lua" 2>/dev/null
        rm -f "$ZAPRET2_DIR/dynamic-slots.conf" 2>/dev/null
        rm -f "$ZAPRET2_DIR/lists/z2k-classify-strategies.tsv" 2>/dev/null
        rm -f "$ZAPRET2_DIR/lists/z2k-classify-domains.tsv" 2>/dev/null
        rm -f /tmp/z2k-classify-dynparams 2>/dev/null
        touch "$ZAPRET2_DIR/.classify_probe_removed.done" 2>/dev/null || true
        print_info "r-15 cleanup: removed legacy z2k-probe.sh / z2k-classify / dynamic-strategy"
    fi

    # Install z2k tools (healthcheck, config validator, list updater, diagnostics, geosite, auto-update)
    # NOTE: z2k-probe.sh / z2k-classify-* removed in r-15 (Phase 1 cleanup
    # detection stack). Replaced by the server_active_reject taxonomy in z2k-detectors.lua.
    for tool_script in z2k-healthcheck.sh z2k-config-validator.sh z2k-update-lists.sh z2k-diag.sh z2k-geosite.sh z2k-auto-update.sh z2k-stats-upload.sh; do
        if [ -f "${WORK_DIR}/files/${tool_script}" ]; then
            cp -f "${WORK_DIR}/files/${tool_script}" "${ZAPRET2_DIR}/${tool_script}" 2>/dev/null || true
            chmod +x "${ZAPRET2_DIR}/${tool_script}" 2>/dev/null || true
            print_info "Установлен: ${tool_script}"
        elif [ "$tool_script" = "z2k-auto-update.sh" ] && [ ! -f "${ZAPRET2_DIR}/${tool_script}" ]; then
            # До r-18 z2k-auto-update.sh не входил в bootstrap-список z2k.sh,
            # из-за чего на чистых установках файла не было и cron-задача
            # `0 2 * * * /opt/zapret2/z2k-auto-update.sh apply` падала молча
            # (sh: not found). Меняется номер версии в манифесте — реальной
            # обновы файлов нет. Fallback: пробуем дотянуть напрямую с GitHub.
            if command -v curl >/dev/null 2>&1 && \
               curl -fsSL --connect-timeout 10 --max-time 30 \
                    "${GITHUB_RAW:-https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced}/files/${tool_script}" \
                    -o "${ZAPRET2_DIR}/${tool_script}" 2>/dev/null && \
               [ -s "${ZAPRET2_DIR}/${tool_script}" ]; then
                chmod +x "${ZAPRET2_DIR}/${tool_script}" 2>/dev/null || true
                print_info "Установлен через fallback: ${tool_script} (auto-update теперь работает)"
            else
                rm -f "${ZAPRET2_DIR}/${tool_script}" 2>/dev/null
                print_warning "${tool_script} не удалось скачать — auto-update не будет работать до следующего reinstall"
            fi
        fi
    done

    # Install ALL lib/*.sh modules to persistent ${ZAPRET2_DIR}/lib/.
    # Background: z2k.sh sources modules from $WORK_DIR/lib (tmpfs) which
    # gets wiped on reboot or when GitHub raw CDN serves a stale copy
    # during the post-push 3-5 min cache window. A user filed 2026-05-24
    # complaint: «обновлялся, но новый пункт [M] в меню не появился» —
    # auto-update reinstall finished, but the stale-cached lib/menu.sh
    # in /tmp/z2k/lib was a copy from the GitHub-CDN-stale fetch and
    # never refreshed for interactive `z2k menu` runs. Only manual
    # reinstall (which wipes /tmp/z2k and re-fetches at a clean moment)
    # fixed it.
    # Persistent /opt/zapret2/lib/* is also the install target for the
    # patch-path mapping (lib/* → ${zd}/${repo_path}); without copying
    # here, the lib/auto_update.sh special-case made it look like patch
    # works for lib/ but historically nothing else got persisted.
    # We still source from $WORK_DIR/lib for now (separate z2k.sh
    # fix needed to make $ZAPRET2_DIR/lib the source of truth) — at
    # least keep the persistent copy fresh so au_apply_patch and any
    # future restructure operate on correct data.
    mkdir -p "${ZAPRET2_DIR}/lib"
    local _module _src _dst _copied=0
    for _module in utils system_init install strategies config config_official webpanel menu auto_update; do
        _src="${WORK_DIR}/lib/${_module}.sh"
        _dst="${ZAPRET2_DIR}/lib/${_module}.sh"
        if [ -f "$_src" ]; then
            cp -f "$_src" "$_dst" 2>/dev/null && _copied=$((_copied + 1))
        fi
    done
    print_info "Установлено: ${_copied} lib/*.sh модулей в персистентный ${ZAPRET2_DIR}/lib/"

    # Web panel is now installed on-demand via menu [P] → [1].
    # Files live in webpanel/ in the repo and are copied to /tmp/z2k/webpanel
    # by z2k.sh bootstrap; install.sh leaves the router filesystem alone.

    # Copy snapshot domain lists for local install flow (no external list repos)
    if [ -d "${WORK_DIR}/files/lists" ]; then
        print_info "Copying snapshot domain lists..."
        mkdir -p "${ZAPRET2_DIR}/files/lists"
        cp -Rf "${WORK_DIR}/files/lists/"* "${ZAPRET2_DIR}/files/lists/" 2>/dev/null || true
        # Strip CRLF from list files
        find "${ZAPRET2_DIR}" -name "*.txt" -path "*/extra_strats/*" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    fi

    # Hostlist install from prefetch staging. Pre-flight в начале
    # step_build_zapret2 (до rm -rf) уже гарантировал что 4 критичных
    # snapshot'a доступны и non-empty в ${Z2K_PREFETCH_LISTS_DIR}. Здесь
    # разворачиваем staged copies в финальную директорию И проверяем
    # каждую критичную после copy. Codex review 2026-05-27: pre-flight
    # доказывает только readability ДО reinstall'а — он не гарантирует
    # что финальный cp в /opt/zapret2 успешен (disk full, права, потеря
    # staging). Поэтому для 4 критичных: cp → verify non-empty → если
    # пусто, retry прямой z2k_fetch в финальный путь → если и это пусто,
    # die. Direct-fetch retry recoverable (восстановит если staging
    # потерялся но сеть жива); die наступает только когда staging +
    # direct fetch ОБА провалились = реально нет ни локального источника
    # ни сети, router всё равно нерабочий, лучше явная ошибка чем
    # silent --hostlist=<empty>.
    local _prefetch="${Z2K_PREFETCH_LISTS_DIR:-/tmp/z2k-prefetch-lists.$$}"
    local _hostlist _stage_src _dst _flat
    for _hostlist in \
        files/lists/extra_strats/TCP/YT/List.txt \
        files/lists/extra_strats/TCP/YT_GV/List.txt \
        files/lists/extra_strats/TCP/RKN/List.txt \
        files/lists/extra_strats/UDP/YT/List.txt; do
        _dst="${ZAPRET2_DIR}/${_hostlist}"
        if [ -s "$_dst" ]; then continue; fi
        mkdir -p "$(dirname "$_dst")" 2>/dev/null
        _flat=$(printf '%s' "${_hostlist#files/lists/}" | tr '/' '_')
        _stage_src="${_prefetch}/${_flat}"
        # 1. staging copy
        if [ -s "$_stage_src" ]; then
            cp -f "$_stage_src" "$_dst" 2>/dev/null && chmod 644 "$_dst" 2>/dev/null
        fi
        # 2. post-copy verify; на пусто — direct fetch в финальный путь
        if [ ! -s "$_dst" ] && command -v z2k_fetch >/dev/null 2>&1; then
            print_warning "Hostlist: ${_hostlist##*/} пуст после staging-copy — пробую прямой fetch..."
            z2k_fetch "/${_hostlist}" "$_dst" 2>/dev/null && rm -f "${_dst}.etag" 2>/dev/null
        fi
        # 3. финальная проверка — если всё ещё пусто, fail closed через
        # return 1. run_full_install ловит non-zero из step_build_zapret2
        # и вызывает z2k_restore_old_tree — router откатится на предыдущую
        # рабочую установку, а не останется полу-собранным.
        if [ ! -s "$_dst" ]; then
            print_error "Критичный hostlist ${_hostlist} не установлен: ни staging-copy, ни прямой fetch не дали непустой файл."
            print_error "Вероятно нет места в /opt или недоступен GitHub — откат на предыдущую установку."
            return 1
        fi
    done
    # Non-critical Discord TCP RKN leg: staging copy + direct-fetch retry,
    # но БЕЗ die — без него основной RKN-обход работает, страдает только
    # Discord-domain ветка внутри rkn_tcp профиля.
    _dst="${ZAPRET2_DIR}/files/lists/extra_strats/TCP/RKN/Discord.txt"
    if [ ! -s "$_dst" ]; then
        mkdir -p "$(dirname "$_dst")" 2>/dev/null
        _stage_src="${_prefetch}/extra_strats_TCP_RKN_Discord.txt"
        if [ -s "$_stage_src" ]; then
            cp -f "$_stage_src" "$_dst" 2>/dev/null && chmod 644 "$_dst" 2>/dev/null
        fi
        if [ ! -s "$_dst" ] && command -v z2k_fetch >/dev/null 2>&1; then
            z2k_fetch "/files/lists/extra_strats/TCP/RKN/Discord.txt" "$_dst" 2>/dev/null && rm -f "${_dst}.etag" 2>/dev/null
        fi
        [ -s "$_dst" ] || print_warning "Hostlist: Discord.txt не установлен — Discord-leg в RKN-профиле no-op (основной RKN-обход работает)."
    fi
    # Cleanup prefetch staging.
    rm -rf "$_prefetch" 2>/dev/null
    unset Z2K_PREFETCH_LISTS_DIR

    # Copy IP lists (Roblox, Telegram) + extra-domains.txt (shipped extras
    # from files/lists/ that z2k curates on top of runetfreedom RKN list).
    mkdir -p "${ZAPRET2_DIR}/lists"
    # z2k-detect daemon-managed hostlist. We touch it here — BEFORE
    # config_official.sh generates NFQWS2_OPT — so config_official's
    # `[ -e ] && add --hostlist=` guard sees the file and wires it into
    # nfqws2's command line. Otherwise on fresh install the daemon (which
    # is installed later, ~line 2204) would publish to a file that nfqws2
    # never reads, and Hot verdicts would silently fail to activate bypass.
    [ -e "${ZAPRET2_DIR}/lists/discovered-domains.txt" ] || \
        : > "${ZAPRET2_DIR}/lists/discovered-domains.txt"
    for iplist in game_ips.txt roblox_ips.txt telegram_ips.txt ipset-exclude.txt flowseal_game_ips.txt cf_extra_check_ips.txt rkn-false-positive.txt; do
        if [ -f "${WORK_DIR}/files/lists/${iplist}" ]; then
            cp -f "${WORK_DIR}/files/lists/${iplist}" "${ZAPRET2_DIR}/lists/${iplist}" 2>/dev/null || true
        fi
    done

    # extra-domains.txt: preserve user-added lines across reinstall.
    # Юзеры пишут свои домены через `echo >> extra-domains.txt`. Cтарый
    # /opt/zapret2 уже снесён выше (rm -rf "$ZAPRET2_DIR"), поэтому
    # diff'имся не против установленного файла, а против бекапа в
    # $backup_tmp/extra-domains.txt — он сделан до rm. Без этого fallback
    # на $installed логика просто не находила ничего пользовательского
    # (файл равен shipped) и тихо теряла домены.
    if [ -f "${WORK_DIR}/files/lists/extra-domains.txt" ]; then
        local shipped="${WORK_DIR}/files/lists/extra-domains.txt"
        local installed="${ZAPRET2_DIR}/lists/extra-domains.txt"
        local user_extras=""
        if [ -f "$backup_tmp/extra-domains.txt" ]; then
            # Строки которые есть в backup'е, но НЕТ в shipped — пользовательские.
            user_extras=$(grep -vxFf "$shipped" "$backup_tmp/extra-domains.txt" 2>/dev/null \
                | grep -vE '^#|^$' \
                | grep -vE '^# === user-added')
        fi
        cp -f "$shipped" "$installed" 2>/dev/null || true
        if [ -n "$user_extras" ]; then
            {
                echo ""
                echo "# === user-added (preserved across reinstall) ==="
                printf '%s\n' "$user_extras"
            } >> "$installed"
            print_info "Сохранены пользовательские записи в extra-domains.txt ($(printf '%s\n' "$user_extras" | wc -l | tr -d ' ') строк)"
        fi
    fi
    # Decompress lua.gz files (if any are shipped by embedded builds)
    if [ -d "${ZAPRET2_DIR}/lua" ]; then
        if command -v gzip >/dev/null 2>&1; then
            for f in "${ZAPRET2_DIR}/lua/"*.lua.gz; do
                [ -f "$f" ] || continue
                local out="${f%.gz}"
                print_info "Decompressing $(basename "$f")..."
                if gzip -dc "$f" > "${out}.tmp" 2>/dev/null; then
                    mv -f "${out}.tmp" "$out"
                    rm -f "$f"
                else
                    rm -f "${out}.tmp"
                    print_warning "Failed to decompress $f"
                fi
            done
        else
            print_warning "gzip not found, skipping lua.gz decompression"
        fi
    fi
    # ===========================================================================
    # ШАГ 4.6: Инициализация autocircular cache (state.tsv, telemetry.tsv)
    # ===========================================================================
    # Ранее тут качались orchestra/locked.lua + orchestra/orchestrator.sh
    # из AloofLibra/zapret4rocket. orchestrator.sh удалён upstream'ом 2026-05-07,
    # locked.lua осиротел. Discord UDP теперь использует наш `circular` с
    # `allow_nohost=1` (см. PLAN_orchestrator_replacement.md, B1).

    mkdir -p "${ZAPRET2_DIR}/lua"
    mkdir -p "${ZAPRET2_DIR}/extra_strats/cache/autocircular"
    chmod 755 "${ZAPRET2_DIR}/extra_strats/cache/autocircular" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular" 2>/dev/null || true
    : > "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
    chmod 644 "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
    : > "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv" 2>/dev/null || true
    chmod 644 "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv" 2>/dev/null || true
    # Debug is opt-in. Keep log file prepared, but do not enable verbose logging by default.
    rm -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.flag" 2>/dev/null || true
    : > "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.log" 2>/dev/null || true
    chmod 644 "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.log" 2>/dev/null || true
    chown nobody "${ZAPRET2_DIR}/extra_strats/cache/autocircular/debug.log" 2>/dev/null || true
    rm -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv.lock" \
          "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv.tmp" \
          "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv.lock" \
          "${ZAPRET2_DIR}/extra_strats/cache/autocircular/telemetry.tsv.tmp" 2>/dev/null || true
    # Fresh install/reinstall must not inherit stale fallback cache from /tmp.
    rm -f /tmp/z2k-autocircular-state.tsv \
          /tmp/z2k-autocircular-telemetry.tsv \
          /tmp/z2k-autocircular-debug.flag \
          /tmp/z2k-autocircular-debug.log 2>/dev/null || true

    # ===========================================================================
    # Восстановление пользовательских данных после переустановки
    # ===========================================================================
    if [ -d "$backup_tmp" ]; then
        print_info "Восстановление пользовательских настроек..."

        # Восстановить config.
        # Manual reinstall: целиком restore user config (legacy поведение).
        # Auto-update reinstall (Z2K_AUTO_UPDATE=1): shipped config побеждает,
        # переносим только Z2K_* feature flags (см. feedback_z2k_user_overrides_policy).
        if [ -f "$backup_tmp/config" ]; then
            if [ "$Z2K_AUTO_UPDATE" = "1" ]; then
                local _flag_backup="$backup_tmp/feature-flags.txt"
                # Preserve both Z2K_* feature flags and the non-Z2K_ user-
                # settable knobs (game mode style, RST filter, RKN silent
                # fallback, Keenetic policy integration, TG-tunnel disable
                # marker). Раньше regex был только `^Z2K_[A-Z0-9_]+=`,
                # из-за чего GAME_MODE_ENABLED/STYLE, DROP_DPI_RST,
                # POLICY_NAME/EXCLUDE и т.д. слетали при auto-update
                # reinstall'е (юзерский игровой режим тихо отключался,
                # selected NDM policy сбрасывалась на дефолт «nfqws»).
                # Список явный — shipped config_official.sh пишет эти
                # же ключи через ${saved_*}, без них create_official_config
                # вернётся к дефолтам. Если добавляешь новый non-Z2K_
                # user flag в config_official.sh — добавь его и сюда.
                grep -E '^(Z2K_[A-Z0-9_]+|GAME_MODE_ENABLED|GAME_MODE_STYLE|DROP_DPI_RST|RST_FILTER|RKN_SILENT_FALLBACK|ROBLOX_UDP_BYPASS|TG_PROXY_USER_DISABLED|POLICY_NAME|POLICY_EXCLUDE|DISABLE_IPV6|DISABLE_CUSTOM|ENABLED)=' "$backup_tmp/config" > "$_flag_backup" 2>/dev/null || true
                if [ -s "$_flag_backup" ] && [ -f "$ZAPRET2_DIR/config" ]; then
                    local _line _flag_name _escaped _applied=0
                    while IFS= read -r _line; do
                        [ -z "$_line" ] && continue
                        _flag_name="${_line%%=*}"
                        if grep -q "^${_flag_name}=" "$ZAPRET2_DIR/config"; then
                            _escaped=$(printf '%s\n' "$_line" | sed 's/[&/\\]/\\&/g')
                            sed -i "s|^${_flag_name}=.*|${_escaped}|" "$ZAPRET2_DIR/config"
                            _applied=$((_applied + 1))
                        fi
                    done < "$_flag_backup"
                    print_success "Auto-update: shipped config + ${_applied} Z2K_* flag(s) перенесено"
                fi
            else
                cp -f "$backup_tmp/config" "$ZAPRET2_DIR/config"
                print_success "Конфигурация восстановлена"
            fi
        fi

        # Восстановить whitelist
        if [ -f "$backup_tmp/whitelist.txt" ]; then
            mkdir -p "$ZAPRET2_DIR/lists"
            cp -f "$backup_tmp/whitelist.txt" "$ZAPRET2_DIR/lists/whitelist.txt"
            print_success "Whitelist восстановлен"
        fi

        # Восстановить autocircular state (рабочие стратегии).
        #
        # Wipe ТОЛЬКО при явном Z2K_RESET_STATE=1 (generic per-release flag:
        # auto-update выставляет его, когда какая-то history-entry в окне
        # installed→target имеет "reset_state": true — см. lib/auto_update.sh
        # au_decide / au_apply_reinstall). Без флага reinstall ВСЕГДА
        # восстанавливает state из backup.
        #
        # БАГ-фикс 2026-05-28: раньше была вторая wipe-ветка по маркеру
        # .silent_drop_state_reset.done (legacy one-shot для r-6). Маркер
        # писался в $ZAPRET2_DIR — дерево, которое install ЗАМЕНЯЕТ на каждом
        # reinstall'е — и НЕ бэкапился, поэтому при каждом reinstall'е он
        # «отсутствовал» → one-shot срабатывал СНОВА → state затирался на
        # КАЖДОМ обновлении, даже без reset_state. Ветка убрана (r-6 давно
        # позади; с нативной ротацией state.tsv не runtime-критичен).
        if [ -f "$backup_tmp/state.tsv" ]; then
            if [ "$Z2K_RESET_STATE" = "1" ]; then
                # state.tsv уже truncated на шаге 4.6 — просто не restore'им.
                print_info "autocircular state reset (Z2K_RESET_STATE=1 from release flag) — ротация с нуля"
            else
                cp -f "$backup_tmp/state.tsv" "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv"
                chown nobody "$ZAPRET2_DIR/extra_strats/cache/autocircular/state.tsv" 2>/dev/null || true
                print_success "Стратегии autocircular восстановлены"
            fi
        fi

        # Per-install relay identity (Stage B) — restore the device's minted keypair
        # so it keeps its registered identity (no re-mint / re-register) across reinstall.
        if [ -f "$backup_tmp/z2k-relay-id" ]; then
            cp -f "$backup_tmp/z2k-relay-id" "$ZAPRET2_DIR/.z2k-relay-id"
            chmod 600 "$ZAPRET2_DIR/.z2k-relay-id" 2>/dev/null || true
        fi

        # Strategy.txt не восстанавливаем — shipped-версия из репо имеет
        # приоритет (см. feedback_z2k_user_overrides_policy).

        # Восстановить silent fallback flag
        if [ -f "$backup_tmp/rkn_silent_fallback.flag" ]; then
            touch "$ZAPRET2_DIR/extra_strats/cache/autocircular/rkn_silent_fallback.flag"
            chown nobody "$ZAPRET2_DIR/extra_strats/cache/autocircular/rkn_silent_fallback.flag" 2>/dev/null || true
        fi

        # NB: backup_tmp НЕ удаляем здесь — step_finalize ниже использует
        # $backup_tmp/webpanel-port/bind для re-install'а webpanel. Удаление
        # на этом месте делало r-20 webpanel-fix dead code: webpanel-port
        # стирался до того как step_finalize мог его прочитать, и панель
        # после auto-update reinstall'а оставалась мёртвой. Удалит её
        # step_finalize после webpanel-restore блока.
        print_success "Все пользовательские настройки восстановлены"
    fi

    # ===========================================================================
    # ШАГ 4.7: Установить custom.d скрипты (STUN + Discord media backup)
    # ===========================================================================

    print_info "Установка custom.d скриптов для STUN/Discord media..."

    local custom_dir="${ZAPRET2_DIR}/init.d/keenetic/custom.d"
    mkdir -p "$custom_dir"

    if z2k_fetch "https://raw.githubusercontent.com/bol-van/zapret2/master/init.d/custom.d.examples.linux/50-stun4all" \
        "${custom_dir}/50-stun4all"; then
        chmod +x "${custom_dir}/50-stun4all"
        print_success "50-stun4all установлен"
    else
        print_warning "Не удалось загрузить 50-stun4all"
    fi

    if z2k_fetch "https://raw.githubusercontent.com/bol-van/zapret2/master/init.d/custom.d.examples.linux/50-discord-media" \
        "${custom_dir}/50-discord-media"; then
        chmod +x "${custom_dir}/50-discord-media"
        print_success "50-discord-media установлен"
    else
        print_warning "Не удалось загрузить 50-discord-media"
    fi

    # z2k_fetch кладёт рядом <file>.etag (хэш для кэш-валидации). Базовый
    # zapret2-keenetic init прогоняет ВСЕ файлы в custom.d/ как скрипты,
    # включая .etag → пытается выполнить hex-строку как команду → "not found"
    # шум в логе старта S99zapret2 (field-report 2026-05-28). Убираем .etag
    # (как deploy_critical_file для init/NDM-каталогов). Чистим весь каталог —
    # снимает и старые .etag, осевшие от прошлых установок.
    rm -f "${custom_dir}"/*.etag 2>/dev/null

    # ===========================================================================
    # ЗАВЕРШЕНИЕ
    # ===========================================================================

    # Очистка
    cd / || return 1
    rm -rf "$build_dir"

    print_success "zapret2 установлен"
    print_info "Структура:"
    print_info "  - Бинарники: nfq2/nfqws2, ip2net/ip2net, mdig/mdig"
    print_info "  - Lua библиотеки: lua/"
    print_info "  - Fake файлы: files/fake/"
    print_info "  - Модули: common/"
    print_info "  - Документация: docs/"

    return 0
}

# ==============================================================================
# ШАГ 6: ПРОВЕРКА УСТАНОВКИ
# ==============================================================================

step_verify_installation() {
    print_header "Шаг 6/12: Проверка установки"

    # Проверить структуру директорий
    local required_paths="
${ZAPRET2_DIR}
${ZAPRET2_DIR}/nfq2
${ZAPRET2_DIR}/nfq2/nfqws2
${ZAPRET2_DIR}/ip2net
${ZAPRET2_DIR}/mdig
${ZAPRET2_DIR}/lua
${ZAPRET2_DIR}/files
${ZAPRET2_DIR}/common
${ZAPRET2_DIR}/binaries
"

    print_info "Проверка структуры директорий..."

    local missing=0
    for path in $required_paths; do
        if [ -e "$path" ]; then
            print_info "[OK] $path"
        else
            print_warning "[FAIL] $path не найден"
            missing=$((missing + 1))
        fi
    done

    if [ $missing -gt 0 ]; then
        print_warning "Некоторые компоненты отсутствуют, но это может быть нормально"
    fi

    # Проверить все бинарники (установленные через install_bin.sh)
    print_info "Проверка бинарников..."

    # nfqws2 - основной бинарник
    if [ -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]; then
        if verify_binary "${ZAPRET2_DIR}/nfq2/nfqws2"; then
            print_success "[OK] nfqws2 работает"
        else
            print_error "[FAIL] nfqws2 не запускается"
            return 1
        fi
    else
        print_error "[FAIL] nfqws2 не найден или не исполняемый"
        return 1
    fi

    # ip2net - вспомогательный (может быть симлинком)
    if [ -e "${ZAPRET2_DIR}/ip2net/ip2net" ]; then
        print_info "[OK] ip2net установлен"
    else
        print_warning "[FAIL] ip2net не найден (необязательный)"
    fi

    # mdig - DNS утилита (может быть симлинком)
    if [ -e "${ZAPRET2_DIR}/mdig/mdig" ]; then
        print_info "[OK] mdig установлен"
    else
        print_warning "[FAIL] mdig не найден (необязательный)"
    fi

    # Посчитать компоненты
    print_info "Статистика компонентов:"

    # Lua файлы
    if [ -d "${ZAPRET2_DIR}/lua" ]; then
        local lua_count
        lua_count=$(find "${ZAPRET2_DIR}/lua" -name "*.lua" 2>/dev/null | wc -l)
        print_info "  - Lua файлов: $lua_count"
    fi

    # Fake файлы
    if [ -d "${ZAPRET2_DIR}/files/fake" ]; then
        local fake_count
        fake_count=$(find "${ZAPRET2_DIR}/files/fake" -name "*.bin" 2>/dev/null | wc -l)
        print_info "  - Fake файлов: $fake_count"
    fi

    # Модули common/
    if [ -d "${ZAPRET2_DIR}/common" ]; then
        local common_count
        common_count=$(find "${ZAPRET2_DIR}/common" -name "*.sh" 2>/dev/null | wc -l)
        print_info "  - Модули common/: $common_count"
    fi

    # install_bin.sh присутствует?
    if [ -f "${ZAPRET2_DIR}/install_bin.sh" ]; then
        print_info "  - install_bin.sh: установлен"
    fi

    print_success "Установка проверена успешно"
    return 0
}

# ==============================================================================
# ШАГ 7: ОПРЕДЕЛЕНИЕ ТИПА FIREWALL (КРИТИЧНО)
# ==============================================================================

step_check_and_select_fwtype() {
    print_header "Шаг 7/12: Определение типа firewall"

    print_info "Автоопределение типа firewall системы..."

    # ВАЖНО: Загрузить base.sh ПЕРЕД fwtype.sh, т.к. нужна функция exists()
    if [ -f "${ZAPRET2_DIR}/common/base.sh" ]; then
        . "${ZAPRET2_DIR}/common/base.sh"
    else
        print_error "Модуль base.sh не найден в ${ZAPRET2_DIR}/common/"
        return 1
    fi

    # Source модуль fwtype из zapret2
    if [ -f "${ZAPRET2_DIR}/common/fwtype.sh" ]; then
        . "${ZAPRET2_DIR}/common/fwtype.sh"
    else
        print_error "Модуль fwtype.sh не найден в ${ZAPRET2_DIR}/common/"
        return 1
    fi

    # ВАЖНО: Восстановить Z2K путь к init скрипту (он перезаписывается модулями zapret2)
    INIT_SCRIPT="$Z2K_INIT_SCRIPT"

    # Переопределить linux_ipt_avail для Keenetic (IPv4-only режим).
    # Официальная функция требует iptables И ip6tables, но Keenetic с
    # DISABLE_IPV6=1 не имеет ip6tables, поэтому проверяем только iptables.
    # Не использовать upstream `exists` — она зависит от $PATH в момент
    # установки, а на Keenetic под root часто нет /usr/sbin в PATH, и
    # iptables «не находится», хотя физически на месте. Сергей @innotcommercial
    # 2026-04-18: linux_fwtype вернул "unsupported", хотя iptables работал.
    linux_ipt_avail()
    {
        [ -x /usr/sbin/iptables ] || [ -x /sbin/iptables ] || \
        [ -x /opt/sbin/iptables ] || command -v iptables >/dev/null 2>&1
    }

    # Автоопределение через функцию из zapret2
    linux_fwtype

    # linux_fwtype может вернуть "unsupported" если ни iptables, ни nftables
    # не нашлись (как раз случай с битым PATH выше). Старая проверка ловила
    # только пустую строку — добавлено явное "unsupported".
    if [ -z "$FWTYPE" ] || [ "$FWTYPE" = "unsupported" ]; then
        print_warning "linux_fwtype вернул '$FWTYPE' — используем fallback iptables"
        FWTYPE="iptables"
    fi

    print_success "Обнаружен firewall: $FWTYPE"

    # Показать информацию
    case "$FWTYPE" in
        iptables)
            print_info "iptables - традиционный firewall Linux"
            print_info "Keenetic обычно использует iptables"
            ;;
        nftables)
            print_info "nftables - современный firewall Linux (kernel 3.13+)"
            print_info "Более эффективен чем iptables"
            ;;
        *)
            print_warning "Неизвестный тип firewall: $FWTYPE"
            ;;
    esac

    # Записать FWTYPE в config файл (если он уже существует)
    local config="${ZAPRET2_DIR}/config"
    if [ -f "$config" ]; then
        # Проверить есть ли уже FWTYPE в config
        if grep -q "^#*FWTYPE=" "$config"; then
            # Обновить существующую строку
            sed -i "s|^#*FWTYPE=.*|FWTYPE=$FWTYPE|" "$config"
            print_info "FWTYPE=$FWTYPE записан в config"
        else
            # Добавить в конец FIREWALL SETTINGS секции
            sed -i "/# FIREWALL SETTINGS/a FWTYPE=$FWTYPE" "$config"
            print_info "FWTYPE=$FWTYPE добавлен в config"
        fi
    else
        print_info "Config файл ещё не создан, FWTYPE будет установлен позже"
    fi

    # Экспортировать для использования в других функциях
    export FWTYPE

    return 0
}

# ==============================================================================
# ШАГ 8: ЗАГРУЗКА СПИСКОВ ДОМЕНОВ
# ==============================================================================

step_download_domain_lists() {
    print_header "Шаг 8/12: Загрузка списков доменов"

    # Использовать функцию из lib/config.sh
    download_domain_lists || {
        print_error "Не удалось загрузить списки доменов"
        return 1
    }

    # Phase 12: replace shipped snapshots with fresh runetfreedom
    # geosite data. shipped 125k → runetfreedom ru-blocked.txt (or
    # ru-blocked-all on 1 GB+ routers, selected by z2k-geosite.sh
    # RAM probe). Non-fatal — if fetch fails (DNS, GitHub down,
    # rate limit), keep the shipped snapshot as fallback.
    local geosite="${ZAPRET2_DIR}/z2k-geosite.sh"
    if [ -x "$geosite" ]; then
        print_info "Обновление списков из runetfreedom geosite..."
        FORCE_REFETCH=1 sh "$geosite" fetch --force 2>&1 | sed 's/^/  /' || \
            print_warning "geosite fetch partial/failed — using shipped fallback"
    else
        print_warning "z2k-geosite.sh не найден, пропускаю geosite fetch"
    fi

    # Post-copy validation критичных LIVE hostlists (production-blocking).
    # ВАЖНО: выполняется ПОСЛЕ geosite fetch — он перезаписывает те же
    # ${ZAPRET2_DIR}/extra_strats/*/List.txt (ru-blocked в RKN, subtract
    # googlevideo из YT). Codex review 2026-05-28: если validation до
    # geosite, а geosite затем нормализует список в пустой (битый upstream
    # формат / regression в subtract-логике) — nfqws2 получит пустой
    # --hostlist уже ПОСЛЕ пройденного guard'а. Проверяя финальное
    # состояние после всех list-writer'ов, ловим и copy-failure (snapshot→
    # live), и geosite-corruption. fail closed через return 1 (не die):
    # `step_download_domain_lists || return 1` → install прерывается честно,
    # run_full_install откатит на предыдущую установку (z2k_restore_old_tree),
    # сервис не стартует с пустыми списками.
    local _live_hostlist
    for _live_hostlist in \
        "${ZAPRET2_DIR}/extra_strats/TCP/YT/List.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/YT_GV/List.txt" \
        "${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt" \
        "${ZAPRET2_DIR}/extra_strats/UDP/YT/List.txt"; do
        if [ ! -s "$_live_hostlist" ]; then
            print_error "Критичный live-hostlist пуст/отсутствует после geosite: ${_live_hostlist}"
            print_error "Либо copy snapshot→live не удался (нет места/права), либо geosite перезаписал список в пустой."
            print_error "Установка прервана — сервис НЕ будет запущен с пустыми --hostlist (откат на предыдущую версию)."
            return 1
        fi
    done

    create_base_config || {
        print_error "Не удалось создать конфигурацию"
        return 1
    }

    print_success "Списки доменов и конфигурация установлены"
    return 0
}

# ==============================================================================
# ШАГ 9: ОТКЛЮЧЕНИЕ HARDWARE NAT
# ==============================================================================

step_disable_hwnat_and_offload() {
    print_header "Шаг 9/12: Отключение Hardware NAT и Flow Offloading"

    # =========================================================================
    # 9.1: Hardware NAT (fastnat на Keenetic)
    # =========================================================================

    print_info "Проверка Hardware NAT (fastnat)..."

    # Проверить наличие системы управления HWNAT
    if [ -f "/sys/kernel/fastnat/mode" ]; then
        local current_mode
        current_mode=$(cat /sys/kernel/fastnat/mode 2>/dev/null || echo "unknown")

        print_info "Текущий режим fastnat: $current_mode"

        if [ "$current_mode" != "0" ] && [ "$current_mode" != "unknown" ]; then
            print_warning "Hardware NAT включен - может конфликтовать с DPI bypass"

            # Попытка отключения
            if echo 0 > /sys/kernel/fastnat/mode 2>/dev/null; then
                print_success "Hardware NAT отключен"
            else
                print_warning "Не удалось отключить Hardware NAT"
                print_info "Возможно требуются дополнительные права"
                print_info "Попробуйте вручную: echo 0 > /sys/kernel/fastnat/mode"
            fi
        else
            print_success "Hardware NAT уже отключен или недоступен"
        fi
    else
        print_info "Hardware NAT (fastnat) не обнаружен на этой системе"
    fi

    # =========================================================================
    # 9.2: Flow Offloading (критично для nfqws)
    # =========================================================================

    print_separator
    print_info "Проверка Flow Offloading..."

    # На Keenetic flow offloading управляется через другие механизмы
    # В основном через iptables/nftables правила

    # Проверка через sysctl (если доступно)
    if [ -f "/proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal" ]; then
        print_info "Проверка conntrack liberal mode..."

        # zapret2 может требовать liberal mode для обработки invalid RST пакетов
        local liberal_mode
        liberal_mode=$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal 2>/dev/null || echo "0")

        if [ "$liberal_mode" = "0" ]; then
            print_info "conntrack liberal mode выключен (будет включен при старте zapret2)"
        else
            print_info "conntrack liberal mode уже включен"
        fi
    fi

    # Записать FLOWOFFLOAD=none в config (безопасный вариант)
    print_info "Установка FLOWOFFLOAD=none в config (рекомендуется для Keenetic)"

    # Это будет использовано при создании config файла
    export FLOWOFFLOAD=none

    print_separator
    print_info "Информация о flow offloading:"
    print_info "  - Flow offloading ускоряет routing но может ломать DPI bypass"
    print_info "  - nfqws трафик ДОЛЖЕН быть исключен из offloading"
    print_info "  - На Keenetic используется FLOWOFFLOAD=none (безопасно)"
    print_info "  - Официальный init скрипт автоматически настроит exemption rules"

    print_success "Hardware NAT и Flow Offloading проверены"
    return 0
}

# ==============================================================================
# ШАГ 9.5: НАСТРОЙКА TMPDIR ДЛЯ LOW RAM СИСТЕМ
# ==============================================================================

step_configure_tmpdir() {
    print_header "Шаг 9.5/12: Настройка TMPDIR для low RAM систем"

    # Получить объём RAM. /proc/meminfo — основной путь (есть всегда на
    # Linux и не зависит от того, что в нём определил upstream zapret).
    # Раньше первичным был get_ram_mb из common/base.sh, но в части upstream-
    # сборок этой функции нет, и установка падала с
    #   "sh: get_ram_mb: not found" + "Обнаружено RAM: MB" + "sh: bad number"
    # (Сергей @innotcommercial 2026-04-18, master).
    local ram_mb=""
    if [ -r /proc/meminfo ]; then
        ram_mb=$(awk '/^MemTotal:/ {print int($2/1024); exit}' /proc/meminfo)
    fi
    # Fallback на upstream get_ram_mb, если /proc/meminfo не дался
    if [ -z "$ram_mb" ] && [ -f "${ZAPRET2_DIR}/common/base.sh" ]; then
        _saved_linux_ipt_avail="$(type linux_ipt_avail 2>/dev/null)"
        . "${ZAPRET2_DIR}/common/base.sh"
        if [ -n "$_saved_linux_ipt_avail" ]; then
            linux_ipt_avail() { true; }
        fi
        if command -v get_ram_mb >/dev/null 2>&1; then
            ram_mb=$(get_ram_mb)
        fi
    fi
    # Если оба пути не сработали — предполагаем достаточно RAM
    [ -z "$ram_mb" ] && ram_mb=999

    print_info "Обнаружено RAM: ${ram_mb}MB"

    # АВТОМАТИЧЕСКИЙ выбор TMPDIR на основе RAM
    if [ "$ram_mb" -le 400 ]; then
        print_warning "Low RAM система - используем диск для временных файлов"

        local disk_tmpdir="/opt/zapret2/tmp"

        # Создать директорию
        mkdir -p "$disk_tmpdir" || {
            print_error "Не удалось создать $disk_tmpdir"
            return 1
        }

        export TMPDIR="$disk_tmpdir"
        print_success "TMPDIR установлен: $disk_tmpdir (защита от OOM)"

        # Проверить свободное место на диске
        if command -v df >/dev/null 2>&1; then
            local free_mb
            free_mb=$(df -m "$disk_tmpdir" | tail -1 | awk '{print $4}')
            print_info "Свободно на диске: ${free_mb}MB"

            if [ "$free_mb" -lt 200 ]; then
                print_warning "Мало свободного места (<200MB)"
            fi
        fi
    else
        print_success "Достаточно RAM (${ram_mb}MB) - используем /tmp (быстрее)"
        export TMPDIR=""
    fi

    return 0
}

# ==============================================================================
# ШАГ 9.6: TCP тюнинг (буферы + congestion control)
# ==============================================================================

step_tcp_tuning() {
    print_header "Шаг 9.6/12: TCP тюнинг"

    # Stock Keenetic ядра отдают tcp_wmem default=16384 (16 KB).
    # При 65 ms RTT до VPS это 16KB/65ms ≈ 2 Mbit/s потолка на одну TCP
    # сессию. WS-туннель к Telegram relay = одно TCP → весь TG-трафик
    # мультиплексируется через одну сессию с этим потолком, отсюда
    # подтормаживания видео при нескольких клиентах одновременно.
    # Поднимаем write buffer default до 524 KB, max до 4 MB — дальше
    # Linux TCP auto-tuning сам выбирает нужное окно.
    print_info "Подъём TCP буферов для WS-туннеля (upload к VPS)..."
    sysctl -w net.ipv4.tcp_rmem="4096 524288 4194304" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_wmem="4096 524288 4194304" 2>/dev/null || true
    sysctl -w net.core.rmem_max=4194304 2>/dev/null || true
    sysctl -w net.core.wmem_max=4194304 2>/dev/null || true
    # BBR если ядро поддерживает; на Keenetic обычно нет — cubic сойдёт.
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null \
        && print_info "Congestion control: BBR" \
        || print_info "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

    # Персистентность между ребутами через Entware init.d.
    # S02 стартует рано — до любых сетевых демонов.
    local tune_script="/opt/etc/init.d/S02z2k-tcp-tuning"
    z2k_snapshot_external "$tune_script" || { print_error "Снапшот ${tune_script} для отката не удался — прерываю"; return 1; }
    cat > "$tune_script" <<'EOF'
#!/bin/sh
# z2k TCP tuning — applied on every boot.
# Without it tcp_wmem default stays at 16 KB and upload through the
# WS tunnel caps at ~2 Mbit/s per TCP session with 65ms RTT to VPS.
case "$1" in
    start)
        sysctl -w net.ipv4.tcp_rmem="4096 524288 4194304" 2>/dev/null
        sysctl -w net.ipv4.tcp_wmem="4096 524288 4194304" 2>/dev/null
        sysctl -w net.core.rmem_max=4194304 2>/dev/null
        sysctl -w net.core.wmem_max=4194304 2>/dev/null
        sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
        ;;
esac
EOF
    chmod +x "$tune_script" 2>/dev/null
    print_success "TCP тюнинг применён и сохранён ($tune_script)"

    return 0
}

# ==============================================================================
# ШАГ 10: СОЗДАНИЕ ОФИЦИАЛЬНОГО CONFIG И INIT СКРИПТА
# ==============================================================================

step_create_config_and_init() {
    print_header "Шаг 10/12: Создание config и init скрипта"

    # ========================================================================
    # 10.0: Создать дефолтные файлы стратегий
    # ========================================================================

    # Source функции для работы со стратегиями
    . "${LIB_DIR}/strategies.sh" || {
        print_error "Не удалось загрузить strategies.sh"
        return 1
    }

    # Создать директории и дефолтные файлы стратегий
    create_default_strategy_files || {
        print_error "Не удалось создать файлы стратегий"
        return 1
    }

    # ========================================================================
    # 10.1: Создать официальный config файл
    # ========================================================================

    print_info "Создание официального config файла..."

    local zapret_config="${ZAPRET2_DIR}/config"

    # Source функции для генерации config
    . "${LIB_DIR}/config_official.sh" || {
        print_error "Не удалось загрузить config_official.sh"
        return 1
    }

    # Создать config файл (с автогенерацией NFQWS2_OPT из стратегий)
    create_official_config "$zapret_config" || {
        print_error "Не удалось создать config файл"
        return 1
    }

    print_success "Config файл создан: $zapret_config"

    # ========================================================================
    # 8.2: Установить новый init скрипт
    # ========================================================================

    print_info "Установка init скрипта..."

    # Создать директорию если не существует
    mkdir -p "$(dirname "$INIT_SCRIPT")"

    # Скопировать init скрипт из дистрибутива
    print_info "Копирование init скрипта..."

    z2k_snapshot_external "$INIT_SCRIPT" || { print_error "Снапшот init-скрипта для отката не удался — прерываю"; return 1; }
    if [ -f "${WORK_DIR}/files/S99zapret2.new" ]; then
        cp -f "${WORK_DIR}/files/S99zapret2.new" "$INIT_SCRIPT" || {
            print_error "Не удалось скопировать init скрипт"
            return 1
        }
    else
        print_error "Init скрипт не найден: ${WORK_DIR}/files/S99zapret2.new"
        return 1
    fi

    chmod +x "$INIT_SCRIPT" || {
        print_error "Не удалось установить права на init скрипт"
        return 1
    }

    print_success "Init скрипт установлен: $INIT_SCRIPT"

    # Показать информацию о новом подходе
    print_info "Init скрипт использует:"
    print_info "  - Модули из $ZAPRET2_DIR/common/"
    print_info "  - Config файл: $zapret_config"
    print_info "  - Стратегии из config (config-driven, не hardcoded)"
    print_info "  - PID файлы для graceful shutdown"
    print_info "  - Разделение firewall/daemons"

    return 0
}

# ==============================================================================
# ШАГ 11: УСТАНОВКА NETFILTER ХУКА
# ==============================================================================

step_install_netfilter_hook() {
    print_header "Шаг 11/12: Установка netfilter хука"

    print_info "Установка хука для автоматического восстановления правил..."

    # Создать директорию для NDM хуков
    local hook_dir="/opt/etc/ndm/netfilter.d"
    mkdir -p "$hook_dir" || {
        print_error "Не удалось создать $hook_dir"
        return 1
    }

    local hook_file="${hook_dir}/000-zapret2.sh"

    z2k_snapshot_external "$hook_file" || { print_error "Снапшот netfilter-хука для отката не удался — прерываю"; return 1; }
    # Скопировать хук из files/
    if [ -f "${WORK_DIR}/files/000-zapret2.sh" ]; then
        cp "${WORK_DIR}/files/000-zapret2.sh" "$hook_file" || {
            print_error "Не удалось скопировать хук"
            return 1
        }
    else
        print_warning "Файл хука не найден в ${WORK_DIR}/files/"
        print_info "Создание хука вручную..."

        # Создать хук напрямую
        cat > "$hook_file" <<'HOOK'
#!/bin/sh
# Keenetic NDM netfilter hook для автоматического восстановления правил zapret2
# Вызывается при изменениях в netfilter (iptables)

INIT_SCRIPT="/opt/etc/init.d/S99zapret2"
ZAPRET_CONFIG="/opt/zapret2/config"

# Обрабатываем только изменения в таблицах mangle/nat.
# zapret2 использует mangle (NFQUEUE), но Keenetic при переподключении может дергать hook и на nat.
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit 0

# Проверить что init скрипт существует
[ ! -f "$INIT_SCRIPT" ] && exit 0

# Проверить что zapret2 включен (ENABLED=1 в конфиге)
if ! grep -q "^ENABLED=1" "$ZAPRET_CONFIG" 2>/dev/null; then
    exit 0
fi

# Не восстанавливать NFQUEUE-правила, если nfqws2 не запущен.
# Иначе трафик может уйти в очередь без потребителя.
is_nfqws2_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof nfqws2 >/dev/null 2>&1 && return 0
    fi

    # Fallback: check common pidfile locations (our init uses nfqws2_*.pid).
    for pidfile in /opt/var/run/nfqws2_*.pid /opt/var/run/nfqws2.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done

    return 1
}
is_nfqws2_running || exit 0

# Storm guard: lock + debounce (issue #18) — без него `restart_fw &` плодит
# 80+ параллельных пересборок при штормe NDM-событий → ndm 100% CPU.
LOCK_DIR="/tmp/zapret2-restart-fw.lock"
LAST_RUN="/tmp/zapret2-restart-fw.last"
MIN_INTERVAL=15
now="$(date +%s 2>/dev/null || echo 0)"
if [ "$now" -gt 0 ] 2>/dev/null && [ -f "$LAST_RUN" ]; then
    last="$(cat "$LAST_RUN" 2>/dev/null || echo 0)"
    [ "$last" -gt 0 ] 2>/dev/null && [ $((now - last)) -lt "$MIN_INTERVAL" ] && exit 0
fi
if [ -d "$LOCK_DIR" ]; then
    lock_ts="$(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0)"
    [ "$now" -gt 0 ] && [ "$lock_ts" -gt 0 ] && [ $((now - lock_ts)) -gt 60 ] && rmdir "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
[ "$now" -gt 0 ] && echo "$now" > "$LAST_RUN" 2>/dev/null
# restart_fw пересоздаёт только NFQUEUE правила в mangle, демоны (nfqws2) живут.
{
    sleep 2
    "$INIT_SCRIPT" restart_fw >/dev/null 2>&1
    rmdir "$LOCK_DIR" 2>/dev/null
} &

exit 0
HOOK
    fi

    # Сделать исполняемым
    chmod +x "$hook_file" || {
        print_error "Не удалось установить права на хук"
        return 1
    }

    print_success "Netfilter хук установлен: $hook_file"
    print_info "Хук будет восстанавливать правила при переподключении интернета"

    return 0
}

# ==============================================================================
# ШАГ 12: ФИНАЛИЗАЦИЯ
# ==============================================================================

# step_install_z2k_classify removed in r-15 (Phase 1 cleanup of the
# detection stack). z2k-classify was never wired into
# the live circular pipeline — its purpose (DPI block-type guess) is
# now covered by the server_active_reject taxonomy in z2k-detectors.lua
# and (Phase 3) the z2k-detect daemon's path-active/server-active matrix.
#
# CDN CIDR list fetch (Cloudflare AS13335 + Google AS15169) moved into
# step_install_extra_lists so the lists still refresh on install.

step_finalize() {
    print_header "Шаг 12/12: Финализация установки"

    # =====================================================================
    # FIRST: re-apply preserved user flags before anything else in this
    # step reads them. Auto-start TG tunnel below queries
    # TG_PROXY_USER_DISABLED to decide whether to start S98tg-tunnel —
    # if late preserve runs AFTER that, the flag is still default 0,
    # the daemon gets started, watchdog kills it ~25s later, and the
    # cycle repeats on every nightly auto-update reinstall. Same gap
    # would affect Z2K_DYNAMIC_TTL and other flags that gate later
    # actions in step_finalize.
    # =====================================================================
    local backup_tmp_early="/opt/z2k-upgrade-backup"
    if [ "$Z2K_AUTO_UPDATE" = "1" ] && [ -f "$backup_tmp_early/config" ] && [ -f "$ZAPRET2_DIR/config" ]; then
        local _flag_backup_early="$backup_tmp_early/feature-flags-late.txt"
        grep -E '^(Z2K_[A-Z0-9_]+|GAME_MODE_ENABLED|GAME_MODE_STYLE|DROP_DPI_RST|RST_FILTER|RKN_SILENT_FALLBACK|ROBLOX_UDP_BYPASS|TG_PROXY_USER_DISABLED|POLICY_NAME|POLICY_EXCLUDE|DISABLE_IPV6|DISABLE_CUSTOM|ENABLED)=' "$backup_tmp_early/config" > "$_flag_backup_early" 2>/dev/null || true
        if [ -s "$_flag_backup_early" ]; then
            local _line_early _flag_name_early _escaped_early _applied_early=0
            while IFS= read -r _line_early; do
                [ -z "$_line_early" ] && continue
                _flag_name_early="${_line_early%%=*}"
                if grep -q "^${_flag_name_early}=" "$ZAPRET2_DIR/config"; then
                    _escaped_early=$(printf '%s\n' "$_line_early" | sed 's/[&/\\]/\\&/g')
                    sed -i "s|^${_flag_name_early}=.*|${_escaped_early}|" "$ZAPRET2_DIR/config"
                    _applied_early=$((_applied_early + 1))
                fi
            done < "$_flag_backup_early"
            print_success "Auto-update: ${_applied_early} feature flag(s) восстановлено перед auto-start daemon'ов"
        fi
    fi

    # Проверить бинарник перед запуском
    print_info "Проверка nfqws2 перед запуском..."

    if [ ! -x "${ZAPRET2_DIR}/nfq2/nfqws2" ]; then
        print_error "nfqws2 не найден или не исполняемый"
        return 1
    fi

    # Проверить зависимости бинарника (если ldd доступен)
    if command -v ldd >/dev/null 2>&1; then
        print_info "Проверка библиотек..."
        if ldd "${ZAPRET2_DIR}/nfq2/nfqws2" 2>&1 | grep -q "not found"; then
            print_warning "Отсутствуют некоторые библиотеки:"
            ldd "${ZAPRET2_DIR}/nfq2/nfqws2" | grep "not found"
        else
            print_success "Все библиотеки найдены"
        fi
    fi

    # Попробовать запустить напрямую для диагностики
    print_info "Тест запуска nfqws2..."
    local version_output
    version_output=$("${ZAPRET2_DIR}/nfq2/nfqws2" --version 2>&1 | head -1)

    if echo "$version_output" | grep -q "github version"; then
        print_success "nfqws2 исполняется корректно: $version_output"
    else
        print_error "nfqws2 не может быть запущен"
        print_info "Вывод ошибки:"
        "${ZAPRET2_DIR}/nfq2/nfqws2" --version 2>&1 | head -10
        return 1
    fi

    # =========================================================================
    # НАСТРОЙКА АВТООБНОВЛЕНИЯ СПИСКОВ ДОМЕНОВ (КРИТИЧНО)
    # =========================================================================

    print_separator
    print_info "Настройка планировщика z2k (auto-update / lists / get_config)..."

    # Keenetic Entware ships Vixie cron V5.0, but its crontab-reload
    # mechanism is broken on this build: even with mtime updates on the
    # spool dir / /opt/etc/crontab, SIGHUP/USR1/USR2, and full daemon
    # restart, new crontab entries silently never fire (field-debugged
    # 2026-05-23). For ~2 weeks every router on the fleet ran with
    # ZERO automatic list/auto-update runs — the cron lines were dead.
    # We replace cron entirely with z2k-scheduler.sh: a long-lived
    # while-loop daemon that owns ALL z2k periodic tasks. Trivial,
    # auditable, and immune to whatever cron quirks the next firmware
    # introduces.
    # Fail-closed (Codex 2026-05-28): scheduler — критичная инфра (заменяет
    # сломанный cron, гоняет watchdog+auto-update). Провал деплоя =
    # incomplete WORK_DIR / disk-full → rollback на прежнюю установку, а не
    # commit без планировщика.
    deploy_critical_file "files/z2k-scheduler.sh" "${ZAPRET2_DIR}/z2k-scheduler.sh" || return 1
    deploy_critical_file "files/init.d/S99z2k-scheduler" "/opt/etc/init.d/S99z2k-scheduler" || return 1

    if [ -x "${ZAPRET2_DIR}/z2k-scheduler.sh" ] && [ -x /opt/etc/init.d/S99z2k-scheduler ]; then
        /opt/etc/init.d/S99z2k-scheduler restart >/dev/null 2>&1
        if pgrep -f "z2k-scheduler\.sh" >/dev/null 2>&1; then
            print_success "Планировщик z2k запущен (auto-update 02:00, lists 04:00, get_config 06:00)"
        else
            print_warning "Планировщик z2k не запустился — проверьте /opt/var/log/z2k-scheduler.log"
        fi
    else
        print_warning "Не удалось установить планировщик z2k"
    fi

    # One-shot purge of dead Vixie cron lines from previous installs.
    # Both locations: user spool (which Vixie reads but doesn't reload)
    # and /opt/etc/crontab (which Vixie ignores entirely).
    local _purged_z2k_cron=0
    if command -v crontab >/dev/null 2>&1; then
        local cron_regex='get_config\.sh|z2k-update-lists\.sh|z2k-classify-drift\.sh|z2k-auto-update\.sh|z2k-nightly-probe\.sh'
        if crontab -l 2>/dev/null | grep -qE "$cron_regex"; then
            crontab -l 2>/dev/null | grep -vE "$cron_regex" | crontab - 2>/dev/null
            _purged_z2k_cron=1
        fi
        z2k_fix_cron_perms 2>/dev/null
    fi
    if [ -f /opt/etc/crontab ]; then
        if grep -qE "get_config\.sh|z2k-update-lists\.sh|z2k-auto-update\.sh|z2k-classify-drift\.sh" /opt/etc/crontab 2>/dev/null; then
            grep -vE "get_config\.sh|z2k-update-lists\.sh|z2k-auto-update\.sh|z2k-classify-drift\.sh" /opt/etc/crontab > /opt/etc/crontab.tmp 2>/dev/null
            mv /opt/etc/crontab.tmp /opt/etc/crontab
            _purged_z2k_cron=1
        fi
    fi
    # Vixie cron на Entware (r-26 release notes) известно не reload'ит spool/
    # crontab при touch / SIGHUP — z2k entries которые удалили выше остаются
    # в in-memory копии cron daemon'а и продолжают стрелять параллельно
    # с z2k-scheduler. Дубликаты auto-update/update-lists → конкурентная
    # mutation lists/state, ровно та race-condition которую z2k-scheduler
    # призван исключить (Codex review 2026-05-27).
    # Fix: если мы реально очистили z2k entries И cron daemon бежит —
    # restart'нём его. Это перечитает clean crontab. User crontab задачи
    # сохраняются (мы не трогали non-z2k lines), executable flag тоже
    # сохраняется (S10cron уже +x на этой точке если r-37 logic уже
    # сработала ниже — мы её не отменяем).
    if [ "$_purged_z2k_cron" = "1" ] && pidof cron >/dev/null 2>&1 && [ -x /opt/etc/init.d/S10cron ]; then
        /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
        print_info "Системный cron перезапущен — устаревшие z2k-записи больше не дублируют z2k-scheduler"
    fi

    # r-26 стопал+отключал Vixie cron daemon (S10cron stop + chmod -x +
    # killall cron) на том основании что z2k полностью перешёл на свой
    # scheduler. Это поломало юзеров с собственными crontab-задачами
    # (Entware housekeeping, custom скрипты) — field-report @vlallax
    # 2026-05-26.
    #
    # Codex review 2026-05-27/28: z2k НЕ должен сам chmod+x / start cron.
    # Ни безусловно, ни по marker-absence — отсутствие marker'а доказывает
    # лишь "r-37+ тут не запускался", НЕ "именно z2k выключил cron". На
    # router'е где cron выключил САМ админ, любой auto-update тихо вернул
    # бы root crontab execution — trust-boundary regression.
    #
    # Политика: z2k трогает ТОЛЬКО свои cron-записи (purge выше), но
    # никогда не меняет executable-флаг S10cron и не стартует daemon.
    # Для legacy r-26 victims (у кого cron выключен нами в прошлом и
    # нужны свои crontab-задачи) печатаем однократную подсказку с ручной
    # командой восстановления — решение остаётся за админом.
    if [ -f /opt/etc/init.d/S10cron ] && { [ ! -x /opt/etc/init.d/S10cron ] || ! pidof cron >/dev/null 2>&1; }; then
        print_info "Системный cron сейчас отключён. z2k использует собственный планировщик и его не трогает."
        print_info "Если cron был отключён предыдущей версией z2k и вам нужны свои crontab-задачи, верните его вручную:"
        print_info "  chmod +x /opt/etc/init.d/S10cron && /opt/etc/init.d/S10cron start"
    fi

    # Instagram DNS redirect (Keenetic static DNS).
    # Fresh installs get a minimal one-IP-per-host fallback set so that
    # the system is functional even if the VPS resolver is unreachable
    # at install time. The actual maintenance happens via
    # /opt/zapret2/z2k-insta-ip-refresh.sh, which runs from
    # z2k-update-lists.sh on the daily cron and is also kicked off
    # once at the end of this install. It rewrites these records to
    # whatever the EU-egress VPS resolves today, deleting stale dups.
    if command -v ndmc >/dev/null 2>&1; then
        if ! LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null | grep -q "ip host instagram.com"; then
            print_info "Настройка DNS для Instagram..."
            LD_LIBRARY_PATH= ndmc -c "ip host instagram.com 157.240.9.174" 2>/dev/null
            LD_LIBRARY_PATH= ndmc -c "ip host www.instagram.com 157.240.9.174" 2>/dev/null
            LD_LIBRARY_PATH= ndmc -c "ip host graph.instagram.com 157.240.0.63" 2>/dev/null
            LD_LIBRARY_PATH= ndmc -c "ip host api.instagram.com 157.240.253.63" 2>/dev/null
            LD_LIBRARY_PATH= ndmc -c "ip host instagram.c10r.instagram.com 157.240.214.63" 2>/dev/null
            LD_LIBRARY_PATH= ndmc -c "ip host static.cdninstagram.com 57.144.112.192" 2>/dev/null
            LD_LIBRARY_PATH= ndmc -c "ip host scontent.cdninstagram.com 57.144.112.192" 2>/dev/null
            LD_LIBRARY_PATH= ndmc -c "system configuration save" 2>/dev/null
            print_success "DNS записи для Instagram добавлены"
        else
            print_info "DNS записи для Instagram уже настроены"
        fi
    fi

    # Install the refresh script and run it once now to replace any
    # stale shipped/fallback IPs with what Meta is actually serving today.
    # Goes through deploy_critical_file so even if z2k.sh bootstrap missed
    # this file (it wasn't in the legacy tool_name loop until p-29) it gets
    # pulled directly from GitHub.
    if deploy_critical_file "files/z2k-insta-ip-refresh.sh" "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh"; then
        sh "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" >/dev/null 2>&1 || true
    fi

    # Discord-voice pin (finland*.discord.media → one CF edge), ONE-TO-ONE with
    # Flowseal's .service/hosts. The packet desync alone can't help on ISPs that
    # block the voice edge IPs / poison discord.media DNS; pinning the 200
    # finland voice nodes to a working CF edge (mirrored from Flowseal) does, and
    # composes with the nfqws2 keepalive desync on the voice ports. The list is
    # refreshed daily by z2k-update-lists.sh; seed it now so a fresh install gets
    # the pins immediately. Default-on (Z2K_DISCORD_VOICE_PIN=0 in config off).
    if deploy_critical_file "files/z2k-discord-voice-pin.sh" "${ZAPRET2_DIR}/z2k-discord-voice-pin.sh"; then
        local _dvp_tmp
        chmod +x "${ZAPRET2_DIR}/z2k-discord-voice-pin.sh" 2>/dev/null || true
        _dvp_tmp=$(mktemp 2>/dev/null)
        if [ -n "$_dvp_tmp" ] \
           && z2k_fetch "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/hosts" "$_dvp_tmp" 2>/dev/null \
           && [ "$(grep -icE 'finland[0-9]+\.discord\.media' "$_dvp_tmp" 2>/dev/null)" -ge 50 ]; then
            grep -iE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+finland[0-9]+\.discord\.media[[:space:]]*$' \
                "$_dvp_tmp" > "${ZAPRET2_DIR}/lists/flowseal_discord_voice_hosts.txt" 2>/dev/null
        fi
        rm -f "$_dvp_tmp" 2>/dev/null
        sh "${ZAPRET2_DIR}/z2k-discord-voice-pin.sh" >/dev/null 2>&1 || true
    fi

    # WhatsApp + Ticketmaster relay (Keenetic static DNS → EU-egress VPS).
    # Their real backends are unreachable on RU ISPs: WhatsApp's servers are
    # IP-blocked (SYN black-holed — never reaches a ClientHello, so NO desync/
    # rotation can help), Ticketmaster's WAF 403s RU IPs. We pin the hostnames
    # to the VPS, which SNI-passthrough-proxies them to the real backend from a
    # clean EU IP (TLS end-to-end, certs stay valid; the VPS nginx SNI map is
    # shared infra). Fixed VPS IP → NO refresh needed (unlike rotating Meta
    # edges). cleanup_legacy_ip_hosts() exempts these hostnames so the pins
    # survive reinstalls; this block also re-asserts them idempotently and
    # upgrades any stale (e.g. facebook-edge) pins to the VPS.
    if command -v ndmc >/dev/null 2>&1; then
        local relay_vps="213.176.74.63"
        # RELAY ONLY the geo-WAF'd app endpoints. The CDN/asset hosts (ticketm.net,
        # tmol.io/.co, *.ticketmaster.com static/js/media) are Fastly and return 200
        # DIRECT from a RU IP — they are NOT geo-blocked. r-52 wrongly pinned them
        # through the 1-CPU VPS; an image-heavy TM page (~120 s1.ticketm.net + ~48
        # prismic in parallel) then CHOKED the relay → ~half the images failed. They
        # must load direct from Fastly. See project_whatsapp_ip_block (2026-06-08).
        local relay_hosts="whatsapp.com www.whatsapp.com web.whatsapp.com whatsapp.net g.whatsapp.net static.whatsapp.net mmg.whatsapp.net pps.whatsapp.net dit.whatsapp.net v.whatsapp.net crashlogs.whatsapp.net ticketmaster.com www.ticketmaster.com app.ticketmaster.com api.ticketmaster.com auth.ticketmaster.com identity.ticketmaster.com checkout.ticketmaster.com checkout.prod.ticketmaster.com secure-entry.ticketmaster.com my.ticketmaster.com pubapi.ticketmaster.com help.ticketmaster.com blog.ticketmaster.com legal.ticketmaster.com travel.ticketmaster.com privacy.ticketmaster.com business.ticketmaster.com offeradapter.ticketmaster.com rsvp.ticketmaster.com spon.ticketmaster.com fan-wallet.ticketmaster.com developer.ticketmaster.com"
        # CDN/asset hosts r-51/r-52 wrongly pinned — un-pin so they go DIRECT (Fastly).
        local relay_unpin="static.ticketmaster.com js.ticketmaster.com media.ticketmaster.com s1.ticketm.net media.ticketm.net spon.ticketmaster.net prismic-images.tmol.io mapsapi.tmol.io venue.tmol.co"
        # Run when a CDN pin still lingers (old install → migrate) OR the app isn't
        # pinned yet (fresh install). Idempotent; skips on an already-migrated box.
        if LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null | grep -qE "ip host (prismic-images.tmol.io|s1.ticketm.net) $relay_vps" \
           || ! LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null | grep -q "ip host www.ticketmaster.com $relay_vps"; then
            print_info "Настройка релея WhatsApp/Ticketmaster (app → VPS, CDN-картинки напрямую)..."
            local _u _uold _rh _rold
            for _u in $relay_unpin; do
                for _uold in $(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null | awk -v h="$_u" '/^ip host/ && $3==h {print $4}'); do
                    LD_LIBRARY_PATH= ndmc -c "no ip host $_u $_uold" >/dev/null 2>&1
                done
            done
            for _rh in $relay_hosts; do
                for _rold in $(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null | awk -v h="$_rh" '/^ip host/ && $3==h {print $4}'); do
                    LD_LIBRARY_PATH= ndmc -c "no ip host $_rh $_rold" >/dev/null 2>&1
                done
                LD_LIBRARY_PATH= ndmc -c "ip host $_rh $relay_vps" >/dev/null 2>&1
            done
            LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
            print_success "Релей WhatsApp/Ticketmaster настроен"
        else
            print_info "Релей WhatsApp/Ticketmaster уже настроен"
        fi
    fi

    # Telegram transparent proxy (tg-mtproxy-client)
    if true; then
        print_info "Установка/обновление Telegram прокси..."
        # Use same arch detection as zapret2 install (get_arch → map_arch_to_bin_arch)
        local tg_arch=""
        local hw_arch
        hw_arch=$(get_arch 2>/dev/null || uname -m)
        local tg_bin_arch
        tg_bin_arch=$(map_arch_to_bin_arch "$hw_arch" 2>/dev/null || true)
        case "$tg_bin_arch" in
            linux-arm64)  tg_arch="arm64" ;;
            linux-arm)    tg_arch="arm" ;;
            linux-mipsel)   tg_arch="mipsel" ;;
            linux-mips64el) tg_arch="mips64el" ;;
            linux-mips64)   tg_arch="mips" ;;
            linux-mips)     tg_arch="mips" ;;
            linux-x86_64) tg_arch="amd64" ;;
            linux-x86)    tg_arch="x86" ;;
            linux-riscv64) tg_arch="riscv64" ;;
            linux-ppc)    tg_arch="ppc64" ;;
        esac
        if [ -n "$tg_arch" ]; then
            local tg_bin="tg-mtproxy-client-linux-${tg_arch}"
            local tg_dest="/opt/sbin/tg-mtproxy-client"
            local tg_tmp="${tg_dest}.new.$$"
            local tg_url="${GITHUB_RAW}/mtproxy-client/builds/${tg_bin}"
            # Download-to-temp → validate → atomic mv. НЕ удаляем рабочий
            # бинарник до того как новый скачан и проверен (Codex 2026-05-28):
            # transient fetch-fail НЕ должен оставить router без tg-mtproxy-client.
            rm -f "$tg_tmp"
            # z2k_fetch — 4-layer fallback (raw → jsdelivr → gh-proxy → DoH+pin)
            z2k_fetch "$tg_url" "$tg_tmp" 2>/dev/null || true
            rm -f "${tg_tmp}.etag" 2>/dev/null
            local tg_size
            tg_size=$(wc -c < "$tg_tmp" 2>/dev/null || echo 0)
            # Validate: exists, >500KB, ELF magic, runs without crash
            local tg_valid=false
            if [ -f "$tg_tmp" ] && [ "$tg_size" -gt 500000 ] 2>/dev/null; then
                if head -c 4 "$tg_tmp" 2>/dev/null | grep -q "ELF"; then
                    chmod +x "$tg_tmp"
                    if "$tg_tmp" --help 2>/dev/null; [ $? -le 2 ]; then
                        tg_valid=true
                    fi
                fi
            fi
            if $tg_valid; then
                z2k_snapshot_external "$tg_dest"     # для rollback
                mv -f "$tg_tmp" "$tg_dest" && chmod +x "$tg_dest"
                print_success "Telegram прокси установлен ($tg_arch)"
            else
                rm -f "$tg_tmp"
                # КРИТИЧНО: оставляем существующий рабочий бинарник, НЕ удаляем.
                if [ -x "$tg_dest" ]; then
                    print_warning "Не удалось обновить tg-mtproxy-client — оставлен текущий рабочий бинарник"
                elif [ "$tg_size" -le 500000 ] 2>/dev/null; then
                    print_warning "Файл слишком маленький (${tg_size} байт) — скачивание прервалось, рабочего бинарника нет"
                else
                    print_warning "Бинарник не запускается на этой архитектуре ($tg_arch). Проверьте: opkg print-architecture"
                fi
            fi
        else
            print_warning "Неизвестная архитектура $hw_arch, пропускаем Telegram прокси"
        fi
    else
        print_info "Telegram прокси уже установлен"
    fi

    # RuTracker rt-proxy (z2k-rt-proxy) — separate binary, hosted in the SAME
    # place as tg-mtproxy-client (Mark's decision): ${GITHUB_RAW}/mtproxy-client/builds/.
    # rt-proxy ships ONLY arm64/arm/mipsel/mips/amd64 (a subset of tg's archs).
    if true; then
        print_info "Установка/обновление RuTracker rt-proxy..."
        local rtp_arch=""
        local rtp_hw_arch
        rtp_hw_arch=$(get_arch 2>/dev/null || uname -m)
        local rtp_bin_arch
        rtp_bin_arch=$(map_arch_to_bin_arch "$rtp_hw_arch" 2>/dev/null || true)
        case "$rtp_bin_arch" in
            linux-arm64)  rtp_arch="arm64" ;;
            linux-arm)    rtp_arch="arm" ;;
            linux-mipsel) rtp_arch="mipsel" ;;
            linux-mips)   rtp_arch="mips" ;;
            linux-x86_64) rtp_arch="amd64" ;;
        esac
        if [ -n "$rtp_arch" ]; then
            local rtp_bin="z2k-rt-proxy-linux-${rtp_arch}"
            local rtp_dest="/opt/sbin/z2k-rt-proxy"
            local rtp_tmp="${rtp_dest}.new.$$"
            local rtp_url="${GITHUB_RAW}/mtproxy-client/builds/${rtp_bin}"
            # Download-to-temp → validate → atomic mv. НЕ удаляем рабочий
            # бинарник до того как новый скачан и проверен: transient fetch-fail
            # НЕ должен оставить router без z2k-rt-proxy.
            rm -f "$rtp_tmp"
            z2k_fetch "$rtp_url" "$rtp_tmp" 2>/dev/null || true
            rm -f "${rtp_tmp}.etag" 2>/dev/null
            local rtp_size
            rtp_size=$(wc -c < "$rtp_tmp" 2>/dev/null || echo 0)
            local rtp_valid=false
            if [ -f "$rtp_tmp" ] && [ "$rtp_size" -gt 500000 ] 2>/dev/null; then
                if head -c 4 "$rtp_tmp" 2>/dev/null | grep -q "ELF"; then
                    chmod +x "$rtp_tmp"
                    if "$rtp_tmp" --help 2>/dev/null; [ $? -le 2 ]; then
                        rtp_valid=true
                    fi
                fi
            fi
            if $rtp_valid; then
                z2k_snapshot_external "$rtp_dest"     # для rollback
                mv -f "$rtp_tmp" "$rtp_dest" && chmod +x "$rtp_dest"
                print_success "RuTracker rt-proxy установлен ($rtp_arch)"
            else
                rm -f "$rtp_tmp"
                # КРИТИЧНО: оставляем существующий рабочий бинарник, НЕ удаляем.
                if [ -x "$rtp_dest" ]; then
                    print_warning "Не удалось обновить z2k-rt-proxy — оставлен текущий рабочий бинарник"
                elif [ "$rtp_size" -le 500000 ] 2>/dev/null; then
                    print_warning "Файл слишком маленький (${rtp_size} байт) — скачивание прервалось, рабочего бинарника нет"
                else
                    print_warning "Бинарник rt-proxy не запускается на этой архитектуре ($rtp_arch)."
                fi
            fi
        else
            print_warning "Неизвестная/неподдерживаемая rt-proxy архитектура $rtp_hw_arch, пропускаем RuTracker rt-proxy"
        fi
    fi

    # Cleanup legacy WS proxy init script (replaced by tunnel)
    if [ -x /opt/etc/init.d/S97tg-mtproxy ]; then
        /opt/etc/init.d/S97tg-mtproxy stop >/dev/null 2>&1 || true
    fi
    rm -f /opt/etc/init.d/S97tg-mtproxy 2>/dev/null

    # Install/update Telegram tunnel support files regardless of whether the
    # tunnel is currently enabled. This is important for existing installs:
    # an old S98tg-tunnel that ignores TG_PROXY_USER_DISABLED would otherwise
    # remain on disk and resurrect the tunnel on the next reboot.
    mkdir -p /opt/etc/init.d /opt/etc/ndm/netfilter.d /opt/zapret2
    # Fail-closed (Codex 2026-05-28): TG/HTTP-tunnel init-скрипты, NDM-хуки и
    # watchdog деплоятся критично. Провал (incomplete WORK_DIR / disk-full) →
    # return 1 → z2k_restore_old_tree вернёт прежнюю рабочую установку, а не
    # закоммитит router без tunnel-инфры.
    # Shared TG-redirect helper lib (ipset + -w-locked rules) — must land
    # before the init script / NDM hook / watchdog that source it.
    deploy_critical_file "files/z2k-tg-redirect.sh"              "/opt/zapret2/z2k-tg-redirect.sh" || return 1
    deploy_critical_file "files/init.d/S98tg-tunnel"             "/opt/etc/init.d/S98tg-tunnel" || return 1
    deploy_critical_file "files/ndm/90-z2k-tg-redirect.sh"        "/opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh" || return 1
    print_success "Keenetic NDM hook установлен (auto-restore iptables)"
    deploy_critical_file "files/init.d/S97z2k-http-tunnel"        "/opt/etc/init.d/S97z2k-http-tunnel" || return 1
    deploy_critical_file "files/ndm/91-z2k-http-tunnel-redirect.sh" "/opt/etc/ndm/netfilter.d/91-z2k-http-tunnel-redirect.sh" || return 1
    deploy_critical_file "files/init.d/S96z2k-rt-proxy"            "/opt/etc/init.d/S96z2k-rt-proxy" || return 1
    deploy_critical_file "files/ndm/92-z2k-rt-proxy-redirect.sh"    "/opt/etc/ndm/netfilter.d/92-z2k-rt-proxy-redirect.sh" || return 1
    deploy_critical_file "files/z2k-tg-watchdog.sh"               "/opt/zapret2/tg-tunnel-watchdog.sh" || return 1

    # tpws youtube layer REMOVED as a feature (2026-06-08): with fastnat=0 the
    # native nfqws2 bypass works on offloaded flows. Sweep any tpws left over
    # from a previous version so an update leaves no zombie (rules/files/binary).
    z2k_remove_tpws

    # Per-flow PPE de-offload layer (Keenetic MediaTek): keeps the handshake
    # window of bypass-port flows on the CPU slow-path so nfqws2 sees the CH
    # retransmits and the circular rotator can advance (paired with retrans=1,
    # set by config_official.sh when Z2K_PPE_DEOFFLOAD!=0). No-ops cleanly on
    # boxes without the firmware `-j PPE` target. Soft deploy (additive).
    deploy_critical_file "files/z2k-ppe-deoffload.sh"            "/opt/zapret2/z2k-ppe-deoffload.sh" || print_warning "ppe: shared-lib deploy failed (per-flow de-offload disabled)"
    deploy_critical_file "files/ndm/94-z2k-ppe-deoffload.sh"     "/opt/etc/ndm/netfilter.d/94-z2k-ppe-deoffload.sh" || print_warning "ppe: NDM hook deploy failed"

    # tg-tunnel-watchdog used to be triggered via `* * * * *` cron, but
    # Vixie cron on Keenetic Entware doesn't reload added entries (see
    # r-26 notes). z2k-scheduler.sh now fires the watchdog ~1×/min.
    # Strip the legacy cron entry on every reinstall so it doesn't
    # mislead diagnostics.
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -vE "tg-tunnel-watchdog|S97tg-mtproxy" | crontab - 2>/dev/null || true
        z2k_fix_cron_perms
    fi

    # Auto-start Telegram tunnel — but respect TG_PROXY_USER_DISABLED on
    # reinstalls so we don't resurrect a tunnel the user explicitly stopped.
    local _tg_disabled=0
    if [ -f "/opt/zapret2/config" ]; then
        _tg_disabled=$(awk -F= '/^TG_PROXY_USER_DISABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' /opt/zapret2/config)
    fi
    if [ -x "/opt/sbin/tg-mtproxy-client" ] && [ "$_tg_disabled" != "1" ]; then
        if [ -x /opt/etc/init.d/S98tg-tunnel ]; then
            /opt/etc/init.d/S98tg-tunnel restart >/dev/null 2>&1
        else
            # Fallback only when init.d is missing — kill any :1443 sibling
            # (not :1444 — that's S97z2k-http-tunnel, same binary), then
            # start with proper daemonization to survive on MIPS.
            for p in $(pidof tg-mtproxy-client 2>/dev/null); do
                tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--listen=:1443" && kill "$p" 2>/dev/null
            done
            sleep 1
            # CWE-59: root-owned 0700 log dir
            # CWE-59: /tmp/z2k-log должен быть чистым root-owned каталогом. symlink /
            # не-каталог / чужой владелец = возможная подмена атакующим (с planted
            # symlink'ами внутри) → снести и создать заново. busybox `stat -c` нет —
            # владельца берём из `ls -ld`.
            if [ -L /tmp/z2k-log ] || { [ -e /tmp/z2k-log ] && [ ! -d /tmp/z2k-log ]; } || \
               { [ -d /tmp/z2k-log ] && [ "$(ls -ld /tmp/z2k-log 2>/dev/null | awk '{print $3}')" != root ]; }; then
                rm -rf /tmp/z2k-log 2>/dev/null
            fi
            mkdir -p /tmp/z2k-log 2>/dev/null && chown root /tmp/z2k-log 2>/dev/null
            chmod 700 /tmp/z2k-log 2>/dev/null
            ( trap '' HUP; exec /opt/sbin/tg-mtproxy-client --listen=:1443 --timeout=15m -v </dev/null >> /tmp/z2k-log/tg-tunnel.log 2>&1 ) &
        fi
        sleep 2

        # Check for :1443 instance specifically — not just any tg-mtproxy
        # (S97 :1444 would give a false positive).
        tg_1443_alive=0
        for p in $(pidof tg-mtproxy-client 2>/dev/null); do
            tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--listen=:1443" && { tg_1443_alive=1; break; }
        done
        if [ "$tg_1443_alive" = "1" ]; then
            print_success "Telegram tunnel запущен автоматически"
        else
            print_warning "Не удалось запустить Telegram tunnel (можно включить позже через меню [T])"
        fi
    elif [ "$_tg_disabled" = "1" ]; then
        if [ -x /opt/etc/init.d/S98tg-tunnel ]; then
            /opt/etc/init.d/S98tg-tunnel stop >/dev/null 2>&1
        else
            for p in $(pidof tg-mtproxy-client 2>/dev/null); do
                tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--listen=:1443" && kill "$p" 2>/dev/null
            done
        fi
        print_info "Telegram tunnel не запущен — отключён пользователем"
    fi

    # Aux init.d daemons that ride alongside S98tg-tunnel and share the
    # same tg-mtproxy-client binary. Start unconditionally — no user-facing
    # toggle. Silent on restart so it doesn't surface in install output.
    if [ -x /opt/sbin/tg-mtproxy-client ] && [ -x /opt/etc/init.d/S97z2k-http-tunnel ]; then
        /opt/etc/init.d/S97z2k-http-tunnel restart >/dev/null 2>&1 || true
    fi

    # RuTracker rt-proxy aux daemon. Start unconditionally — no user-facing
    # toggle (same model as S97z2k-http-tunnel). Silent on restart. The init
    # script's start() sets the ndmc DNS-override + sentinel REDIRECT itself.
    if [ -x /opt/sbin/z2k-rt-proxy ] && [ -x /opt/etc/init.d/S96z2k-rt-proxy ]; then
        /opt/etc/init.d/S96z2k-rt-proxy restart >/dev/null 2>&1 || true
    fi

    # Per-flow PPE de-offload: chmod the NDM hook +x and apply the rules now
    # (the scheduler + NDM hook keep them re-asserted). Respect Z2K_PPE_DEOFFLOAD=0.
    if [ -r /opt/zapret2/z2k-ppe-deoffload.sh ]; then
        chmod +x /opt/etc/ndm/netfilter.d/94-z2k-ppe-deoffload.sh 2>/dev/null || true
        _ppe_off=$(awk -F= '/^Z2K_PPE_DEOFFLOAD=/{gsub(/[" ]/,"",$2);print $2;exit}' /opt/zapret2/config 2>/dev/null)
        # shellcheck disable=SC1091
        . /opt/zapret2/z2k-ppe-deoffload.sh
        if [ "$_ppe_off" = "0" ]; then
            z2k_ppe_remove_rules >/dev/null 2>&1 || true
            print_info "per-flow PPE de-offload отключён пользователем (Z2K_PPE_DEOFFLOAD=0)"
        elif z2k_ppe_available; then
            z2k_ppe_ensure_rules >/dev/null 2>&1 && print_success "per-flow PPE de-offload активирован (nfqws2 видит ретрансмиты → ротация)" || print_info "per-flow PPE de-offload: правила будут доставлены планировщиком"
        else
            print_info "per-flow PPE de-offload: firmware PPE target недоступен (не Keenetic MediaTek) — пропуск"
        fi
    fi

    # z2k-detect — reactive DPI-discovery daemon.
    # See z2k-detect/README. Replacement for the broken Active Probe /
    # Classify pair that was deleted in r-15.
    if true; then
        print_info "Установка/обновление z2k-detect (anti-DPI engine)..."
        local zd_arch=""
        local zd_hw
        zd_hw=$(get_arch 2>/dev/null || uname -m)
        local zd_bin_arch
        zd_bin_arch=$(map_arch_to_bin_arch "$zd_hw" 2>/dev/null || true)
        case "$zd_bin_arch" in
            linux-arm64)    zd_arch="arm64" ;;
            linux-arm)      zd_arch="arm" ;;
            linux-mipsel)   zd_arch="mipsle" ;;
            linux-mips64el) zd_arch="mips64le" ;;
            linux-mips64)   zd_arch="mips64le" ;;
            linux-mips)     zd_arch="mips" ;;
            linux-x86_64)   zd_arch="amd64" ;;
            linux-x86)      zd_arch="386" ;;
            linux-riscv64)  zd_arch="riscv64" ;;
            linux-ppc)      zd_arch="ppc64" ;;
        esac
        if [ -n "$zd_arch" ]; then
            local zd_bin="z2k-detect-linux-${zd_arch}"
            local zd_dest="/opt/sbin/z2k-detect"
            local zd_tmp="${zd_dest}.new.$$"
            local zd_url="${GITHUB_RAW}/z2k-detect/builds/${zd_bin}"
            # Download-to-temp → validate → atomic mv. НЕ удаляем рабочий
            # бинарник до проверки нового (Codex 2026-05-28): transient
            # fetch-fail не должен оставить router без z2k-detect.
            rm -f "$zd_tmp"
            z2k_fetch "$zd_url" "$zd_tmp" 2>/dev/null || true
            rm -f "${zd_tmp}.etag" 2>/dev/null
            local zd_size
            zd_size=$(wc -c < "$zd_tmp" 2>/dev/null || echo 0)
            local zd_valid=false
            if [ -f "$zd_tmp" ] && [ "$zd_size" -gt 500000 ] 2>/dev/null; then
                if head -c 4 "$zd_tmp" 2>/dev/null | grep -q "ELF"; then
                    chmod +x "$zd_tmp"
                    zd_valid=true
                fi
            fi
            if $zd_valid; then
                z2k_snapshot_external "$zd_dest"     # для rollback
                mv -f "$zd_tmp" "$zd_dest" && chmod +x "$zd_dest"
                print_success "z2k-detect установлен ($zd_arch)"
                # Демон stateless — никаких отдельных state-файлов на диске.
                # init.d: per [[reference_cron_path_entware]] PATH must
                # be exported inside the script — already done. Install
                # the canonical S98z2k-detect alongside S98tg-tunnel.
                # detect daemon non-critical: если снапшот для отката не
                # удался (disk-full) — НЕ перезаписываем, warn и пропускаем
                # (vs abort всего finalize ради необязательного демона).
                if [ -f "${WORK_DIR}/files/init.d/S98z2k-detect" ]; then
                    if z2k_snapshot_external /opt/etc/init.d/S98z2k-detect; then
                        cp -f "${WORK_DIR}/files/init.d/S98z2k-detect" \
                              /opt/etc/init.d/S98z2k-detect
                        chmod +x /opt/etc/init.d/S98z2k-detect
                    else
                        print_warning "Снапшот S98z2k-detect не удался — пропускаю обновление detect-демона (необязательный)"
                    fi
                fi
                # Feature flag: Z2K_DISCOVER default OFF — автодетекция
                # выключена пока не обкатана. Юзер включает руками в
                # меню [Y] когда хочет попробовать. Config file —
                # /opt/zapret2/config (плоский файл, не директория).
                if ! grep -q "^Z2K_DISCOVER=" /opt/zapret2/config 2>/dev/null; then
                    echo "Z2K_DISCOVER=0" >> /opt/zapret2/config
                fi
                # Stateless daemon: no init-db, no deny-list generation.
                # Skip-list paths are baked into the binary's defaults
                # (engine.Defaults() reads RKN/extra/whitelist on
                # startup + every 5min). Restart picks up new binary.
                /opt/etc/init.d/S98z2k-detect restart >/dev/null 2>&1 || true
            else
                # Невалидная загрузка — удаляем ТОЛЬКО temp, рабочий бинарник
                # НЕ трогаем (Codex 2026-05-28: transient CDN-fail удалял
                # рабочий /opt/sbin/z2k-detect, а установка продолжалась →
                # discovery ломался у юзеров на ровном месте).
                rm -f "$zd_tmp"
                if [ "$zd_size" -le 500000 ] 2>/dev/null; then
                    print_warning "z2k-detect: загрузка не удалась / файл слишком маленький (${zd_size} байт)"
                else
                    print_warning "z2k-detect: бинарник не подходит для $zd_arch"
                fi
                [ -x "$zd_dest" ] && print_warning "Оставлен текущий рабочий z2k-detect" \
                    || print_warning "z2k-detect не установлен (необязательный)"
            fi
        else
            print_warning "Неизвестная архитектура $zd_hw, пропускаем z2k-detect"
        fi
    fi

    # Показать итоговую информацию
    print_separator
    print_success "Установка zapret2 завершена!"
    print_separator

    printf "Установлено:\n"
    printf "  %-25s: %s\n" "Директория" "$ZAPRET2_DIR"
    printf "  %-25s: %s\n" "Бинарник" "${ZAPRET2_DIR}/nfq2/nfqws2"
    printf "  %-25s: %s\n" "Init скрипт" "$INIT_SCRIPT"
    printf "  %-25s: %s\n" "Конфигурация" "$CONFIG_DIR"
    printf "  %-25s: %s\n" "Списки доменов" "$LISTS_DIR"
    printf "  %-25s: %s\n" "Стратегии" "$STRATEGIES_CONF"
    printf "  %-25s: %s\n" "Tools" "${ZAPRET2_DIR}/ip2net, ${ZAPRET2_DIR}/mdig"

    # Save local z2k entrypoint for future runs without curl. Use
    # z2k_fetch so the install final step also benefits from the
    # raw → jsdelivr → gh-proxy → ndmc-DNS fallback chain.
    local local_z2k_script="${ZAPRET2_DIR}/z2k.sh"
    local local_z2k_url="${GITHUB_RAW}/z2k.sh"
    if z2k_fetch "$local_z2k_url" "$local_z2k_script"; then
        chmod +x "$local_z2k_script" 2>/dev/null || true
        printf "  %-25s: %s\n" "z2k script" "$local_z2k_script"
        # Expose a short `z2k` command in /opt/bin/ so users can just type
        # `z2k menu`, `z2k diag` etc. without remembering the full path.
        # Symlink (not copy) so re-installs that refresh z2k.sh are picked
        # up automatically. /opt/bin/ is on PATH in Entware by default.
        if [ -d /opt/bin ] && ln -sf "$local_z2k_script" /opt/bin/z2k 2>/dev/null; then
            print_info "Команда 'z2k <args>' доступна из любого места (${local_z2k_script})"
        else
            print_info "Открыть меню позже: sh ${local_z2k_script} menu"
        fi
    else
        print_warning "Не удалось сохранить z2k.sh в ${local_z2k_script}"
        print_info "Для повторного запуска используйте curl-команду из README"
    fi

    # Webpanel re-install — opt-in component, восстанавливаем только если
    # юзер уже имел установленную панель (есть backup port-файла). Re-run
    # shipped webpanel/install.sh с сохранёнными port/bind — это пере-копирует
    # cgi/www/lighttpd.conf свежие, регенерирует /opt/etc/init.d/S96 и
    # перезапустит lighttpd. Без этого блока auto-update reinstall тихо
    # ломает webpanel: /opt/zapret2/webpanel/ снесён вместе с
    # rm -rf $ZAPRET2_DIR, S96 живёт в /opt/etc/init.d/ и продолжает
    # пытаться поднять lighttpd без конфига → серая страница / 502 /
    # ничего на :8088 (репортилось юзерами 2026-05-21).
    # backup_tmp — literal path, not the local-scoped variable from
    # download_openwrt_embedded_release (which is out of scope here).
    # r-20 referenced $backup_tmp directly: it was empty → check became
    # `[ -f /webpanel-port ]` and webpanel restore never fired. Fixed
    # in r-22.
    local backup_tmp="/opt/z2k-upgrade-backup"

    # =====================================================================
    # Auto-update: re-apply preserved Z2K_* / non-Z2K_ user flags AFTER
    # step_create_config_and_init wrote the shipped default config.
    #
    # The early restore in download_openwrt_embedded_release runs BEFORE
    # step 10 creates $ZAPRET2_DIR/config, so its `[ -f $ZAPRET2_DIR/config ]`
    # guard always failed silently and the user's Z2K_DYNAMIC_TTL=0 (and
    # any other Z2K_* toggle) reverted to defaults on every nightly cron.
    # Manual reinstall path was unaffected because line 1326 copies the
    # whole backup config back, so step 10 reads user values via saved_*.
    # Auto-update path skipped that cp and we lost the values.
    #
    # Fix: apply the flag-level overrides here, after step 10. Idempotent
    # — re-running is a no-op when nothing changed.
    if [ "$Z2K_AUTO_UPDATE" = "1" ] && [ -f "$backup_tmp/config" ] && [ -f "$ZAPRET2_DIR/config" ]; then
        local _flag_backup="$backup_tmp/feature-flags-late.txt"
        grep -E '^(Z2K_[A-Z0-9_]+|GAME_MODE_ENABLED|GAME_MODE_STYLE|DROP_DPI_RST|RST_FILTER|RKN_SILENT_FALLBACK|ROBLOX_UDP_BYPASS|TG_PROXY_USER_DISABLED|POLICY_NAME|POLICY_EXCLUDE|DISABLE_IPV6|DISABLE_CUSTOM|ENABLED)=' "$backup_tmp/config" > "$_flag_backup" 2>/dev/null || true
        if [ -s "$_flag_backup" ]; then
            local _line _flag_name _escaped _applied=0
            while IFS= read -r _line; do
                [ -z "$_line" ] && continue
                _flag_name="${_line%%=*}"
                if grep -q "^${_flag_name}=" "$ZAPRET2_DIR/config"; then
                    _escaped=$(printf '%s\n' "$_line" | sed 's/[&/\\]/\\&/g')
                    sed -i "s|^${_flag_name}=.*|${_escaped}|" "$ZAPRET2_DIR/config"
                    _applied=$((_applied + 1))
                fi
            done < "$_flag_backup"
            print_success "Auto-update: ${_applied} feature flag(s) перенесено в финальный config"
            # Re-generate NFQWS2_OPT from the restored config — config_official.sh
            # reads saved_* from $ZAPRET2_DIR/config so the regenerate now reflects
            # user flags (e.g. Z2K_DYNAMIC_TTL=0 means no NDM TTL injection in
            # NFQWS2_OPT).
            if [ -f "${ZAPRET2_DIR}/lib/config_official.sh" ]; then
                # shellcheck disable=SC1090
                . "${ZAPRET2_DIR}/lib/config_official.sh" 2>/dev/null
                create_official_config "${ZAPRET2_DIR}/config" >/dev/null 2>&1 || true
            fi
        fi
    fi

    if [ -f "$backup_tmp/webpanel-port" ]; then
        local _wp_port _wp_args _wp_src
        _wp_port=$(cat "$backup_tmp/webpanel-port" 2>/dev/null | tr -dc '0-9')
        # Do NOT replay the saved bind: r-56.3 could have persisted the wrong
        # LAN segment (e.g. a guest bridge) into webpanel/bind, and replaying
        # it would keep the panel on the unreachable address. Let
        # webpanel/install.sh auto-detect the LAN IP fresh on every restore
        # (single-IP detect_lan_ip, 192.168 > 172.16-31 > 10 priority).
        _wp_args=""
        [ -n "$_wp_port" ] && _wp_args="--port $_wp_port"
        _wp_src="${WORK_DIR}/webpanel/install.sh"
        if [ -f "$_wp_src" ]; then
            print_info "Восстановление веб-панели (port=${_wp_port:-default}, bind=auto)..."
            # shellcheck disable=SC2086
            if sh "$_wp_src" $_wp_args >/dev/null 2>&1; then
                print_success "Веб-панель восстановлена и запущена"
            else
                print_warning "Установщик webpanel вернул ошибку — установите вручную через меню [P] → 1"
            fi
        else
            print_warning "$_wp_src отсутствует — webpanel надо переустановить вручную через меню [P]"
        fi
    fi

    # Final cleanup of user-data backup — нужен был на протяжении всей
    # установки (step_install_zapret2 → step_finalize) для webpanel-restore
    # и flag-merge'а; сейчас все потребители отработали, дальше держать
    # незачем.
    rm -rf "$backup_tmp" 2>/dev/null || true

    print_separator

    return 0
}

# ==============================================================================
# ПОЛНАЯ УСТАНОВКА (9 ШАГОВ)
# ==============================================================================

run_full_install() {
    print_header "Установка zapret2 для Keenetic"
    print_info "Процесс установки: 12 шагов (расширенная проверка)"
    print_separator

    # Belt-and-suspenders: pin TMPDIR=/opt/tmp at the whole-install level
    # so every opkg invocation (update, install, --force-overwrite, etc.)
    # across all 12 steps has a writable temp dir. Keenetic rootfs is
    # read-only squashfs and opkg defaults to cwd for its temp.
    export TMPDIR=/opt/tmp
    mkdir -p /opt/tmp 2>/dev/null || true

    # Выполнить все шаги последовательно
    step_check_root || return 1                    # ← НОВОЕ (0/12)

    # Migration: вычистить legacy ip host записи от модулей DNS→Router (снесены
    # 2026-04-27 force-push'ем). Без этого юзеры с этого окна установки имеют
    # 130+ записей на VPS-IP в Keenetic config, github проксируется через
    # Frankfurt → x5-10 медленнее. Idempotent — на чистом роутере ничего не делает.
    cleanup_legacy_ip_hosts

    # Purge legacy Layer-4 records (pre-tracking-file era) — these were
    # written by old z2k_fetch on a single transient fail and got stuck.
    # Then refresh tracked records (post-fix era) against current DNS.
    purge_legacy_ndmc_records
    refresh_stale_ndmc_records

    # Pin raw.githubusercontent.com to a GitHub Fastly anycast IP so this and
    # future installs/updates survive ISP DNS-poisoning of githubusercontent —
    # independent of 8.8.8.8 (which the Layer-4 fallback relies on and which is
    # itself often blocked). The README has a standalone one-liner for a router
    # that can't install yet. Idempotent; LD_LIBRARY_PATH= per the ndmc 0xcffd0060 fix.
    # ONE IP only: 185.199.108-111.133 are equivalent anycast, and Keenetic caps
    # static DNS at 256 records — a loaded router (insta/discord pins) hits
    # "server list limit exceeded" on extras. One record does the job (verified
    # on KeenOS 5.0.12: 1 pin → raw resolves to Fastly, real fetch succeeds).
    if command -v ndmc >/dev/null 2>&1 \
       && ! LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null | grep -q "ip host raw.githubusercontent.com"; then
        LD_LIBRARY_PATH= ndmc -c "ip host raw.githubusercontent.com 185.199.108.133" >/dev/null 2>&1
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1
    fi

    step_update_packages || return 1               # 1/12
    step_check_dns || return 1                     # ← НОВОЕ (2/12)
    step_install_dependencies || return 1          # 3/12 (расширено)
    step_load_kernel_modules || return 1           # 4/12

    # Transactional window: steps 5-12. step_build_zapret2 переименовывает
    # старое дерево в .old.$$ (mv, не rm -rf) и ставит $Z2K_OLD_TREE_BACKUP.
    # Любой fail в этом окне → z2k_restore_old_tree откатывает на прежнюю
    # рабочую установку вместо того чтобы оставить router полу-собранным
    # (Codex review 2026-05-28). На полный success — z2k_commit_install
    # удаляет backup. Steps 0-4 (deps/modules) до mv — old tree цел,
    # отдельный откат не нужен.
    # apply_autocircular_strategies --auto ВНУТРИ окна (Codex 2026-05-28): он
    # переписывает config (NFQWS2_OPT) и рестартит S99zapret2. Если config-gen
    # или рестарт падает, мы ещё ДО commit'а → z2k_restore_old_tree вернёт
    # прежнюю рабочую установку, а не оставит router со сломанным config'ом и
    # без точки отката. (apply_autocircular_strategies теперь пропускает rc.)
    if ! { step_build_zapret2 && \
           step_verify_installation && \
           step_check_and_select_fwtype && \
           step_download_domain_lists && \
           step_disable_hwnat_and_offload && \
           step_configure_tmpdir && \
           step_tcp_tuning && \
           step_create_config_and_init && \
           step_install_netfilter_hook && \
           step_finalize && \
           apply_autocircular_strategies --auto; }; then
        print_error "Установка прервана на одном из шагов 5-12 или применении стратегий."
        z2k_restore_old_tree || true
        return 1
    fi
    # Все шаги + применение стратегий прошли, сервис поднялся — commit point:
    # удаляем backup старого дерева.
    z2k_commit_install

    # Final belt-and-suspenders re-assert — runs AFTER every step (config regen,
    # S99 restart, NDM hook install, strategy apply), some of which rebuild the
    # mangle/nat tables and can drop the PPE de-offload rules added earlier in
    # the chain. Re-apply them LAST so the box ends in the correct state
    # immediately, without waiting for the scheduler watchdog tick.
    if [ -r /opt/zapret2/z2k-ppe-deoffload.sh ]; then
        # shellcheck disable=SC1091
        . /opt/zapret2/z2k-ppe-deoffload.sh
        z2k_ppe_user_disabled || z2k_ppe_ensure_rules >/dev/null 2>&1 || true
    fi

    print_separator
    print_info "Установка завершена успешно!"
    print_separator

    # Auto-update system markers: branch + currently installed tag.
    # Tag comes from Z2K_AU_TARGET_TAG (when triggered by auto-update path),
    # otherwise we fetch UPDATES.json and use the manifest's current field;
    # final fallback is "p-0" baseline.
    local _au_tag="$Z2K_AU_TARGET_TAG"
    if [ -z "$_au_tag" ]; then
        local _au_manifest="/tmp/z2k_install_manifest.json"
        rm -f "$_au_manifest"
        if z2k_fetch "${GITHUB_RAW}/UPDATES.json" "$_au_manifest" 2>/dev/null \
            && [ -s "$_au_manifest" ]; then
            _au_tag=$(sed -n 's/.*"current":[[:space:]]*"\([^"]*\)".*/\1/p' "$_au_manifest" | head -1)
        fi
        rm -f "$_au_manifest"
        [ -z "$_au_tag" ] && _au_tag="p-0"
    fi
    echo "$_au_tag" > "${ZAPRET2_DIR}/.z2k-installed-tag"
    echo "z2k-enhanced" > "${ZAPRET2_DIR}/.z2k-branch"
    print_info "Установленная версия: $_au_tag (ветка z2k-enhanced)"

    return 0
}

# ==============================================================================
# ROLLBACK МЕХАНИЗМ
# ==============================================================================

ROLLBACK_DIR="/opt/zapret2/.rollback"

# Создать snapshot перед изменениями
create_rollback_snapshot() {
    local reason=${1:-"manual"}

    print_info "Создание rollback-snapshot..."

    # Очистить предыдущий snapshot (хранится только последний)
    rm -rf "$ROLLBACK_DIR"
    mkdir -p "$ROLLBACK_DIR" || {
        print_warning "Не удалось создать директорию rollback"
        return 1
    }

    # Сохранить config
    [ -f "${ZAPRET2_DIR}/config" ] && cp -f "${ZAPRET2_DIR}/config" "$ROLLBACK_DIR/config"

    # Сохранить init script
    [ -f "$INIT_SCRIPT" ] && cp -f "$INIT_SCRIPT" "$ROLLBACK_DIR/S99zapret2"

    # Сохранить стратегии
    for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        local sfile="${ZAPRET2_DIR}/extra_strats/$cat_dir/Strategy.txt"
        if [ -f "$sfile" ]; then
            mkdir -p "$ROLLBACK_DIR/strats/$cat_dir"
            cp -f "$sfile" "$ROLLBACK_DIR/strats/$cat_dir/Strategy.txt"
        fi
    done

    # Сохранить whitelist
    [ -f "${ZAPRET2_DIR}/lists/whitelist.txt" ] && \
        cp -f "${ZAPRET2_DIR}/lists/whitelist.txt" "$ROLLBACK_DIR/whitelist.txt"

    # Сохранить autocircular state
    [ -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" ] && \
        cp -f "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv" "$ROLLBACK_DIR/state.tsv"

    # Записать метаданные
    cat > "$ROLLBACK_DIR/metadata" <<ROLLBACK_META
SNAPSHOT_TIME=$(date +%Y%m%d_%H%M%S)
REASON=$reason
Z2K_VERSION=${Z2K_VERSION:-unknown}
NFQWS2_VERSION=$(get_nfqws2_version 2>/dev/null || echo unknown)
ROLLBACK_META

    print_success "Rollback snapshot создан: $ROLLBACK_DIR"
    return 0
}

# Восстановить из rollback snapshot
rollback_to_snapshot() {
    if [ ! -d "$ROLLBACK_DIR" ] || [ ! -f "$ROLLBACK_DIR/metadata" ]; then
        print_error "Rollback snapshot не найден"
        return 1
    fi

    print_header "Восстановление из rollback snapshot"

    # Показать информацию о snapshot (без source — безопасный парсинг)
    local SNAPSHOT_TIME REASON SNAP_Z2K_VERSION SNAP_NFQWS2_VERSION
    SNAPSHOT_TIME=$(safe_config_read "SNAPSHOT_TIME" "$ROLLBACK_DIR/metadata" "unknown")
    REASON=$(safe_config_read "REASON" "$ROLLBACK_DIR/metadata" "unknown")
    SNAP_Z2K_VERSION=$(safe_config_read "Z2K_VERSION" "$ROLLBACK_DIR/metadata" "unknown")
    SNAP_NFQWS2_VERSION=$(safe_config_read "NFQWS2_VERSION" "$ROLLBACK_DIR/metadata" "unknown")
    print_info "Snapshot от: ${SNAPSHOT_TIME}"
    print_info "Причина: ${REASON}"
    print_info "Версия: z2k ${SNAP_Z2K_VERSION}, nfqws2 ${SNAP_NFQWS2_VERSION}"

    if ! confirm "Восстановить эту конфигурацию?" "N"; then
        print_info "Rollback отменён"
        return 0
    fi

    # Остановить сервис
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop 2>/dev/null || true
    fi

    # Восстановить config
    [ -f "$ROLLBACK_DIR/config" ] && cp -f "$ROLLBACK_DIR/config" "${ZAPRET2_DIR}/config"

    # Восстановить init script
    [ -f "$ROLLBACK_DIR/S99zapret2" ] && cp -f "$ROLLBACK_DIR/S99zapret2" "$INIT_SCRIPT" && chmod +x "$INIT_SCRIPT"

    # Восстановить стратегии
    for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        local sfile="$ROLLBACK_DIR/strats/$cat_dir/Strategy.txt"
        if [ -f "$sfile" ]; then
            mkdir -p "${ZAPRET2_DIR}/extra_strats/$cat_dir"
            cp -f "$sfile" "${ZAPRET2_DIR}/extra_strats/$cat_dir/Strategy.txt"
        fi
    done

    # Восстановить whitelist
    [ -f "$ROLLBACK_DIR/whitelist.txt" ] && \
        cp -f "$ROLLBACK_DIR/whitelist.txt" "${ZAPRET2_DIR}/lists/whitelist.txt"

    # Восстановить autocircular state
    [ -f "$ROLLBACK_DIR/state.tsv" ] && \
        cp -f "$ROLLBACK_DIR/state.tsv" "${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv"

    # Перезапустить сервис
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" start 2>/dev/null || true
    fi

    print_success "Конфигурация восстановлена из rollback snapshot"
    return 0
}

# Автоматический rollback по таймеру
# Вызывается после применения новой конфигурации
auto_rollback_timer() {
    local timeout=${1:-300}  # 5 минут по умолчанию

    if [ ! -d "$ROLLBACK_DIR" ]; then
        return 0
    fi

    print_warning "Авто-rollback активен: $timeout секунд"
    print_info "Если сервис работает — подтвердите в меню"
    print_info "Иначе конфигурация будет автоматически восстановлена"

    # Создать таймер-файл
    local timer_file="${ROLLBACK_DIR}/auto_timer"
    echo "$(($(date +%s) + timeout))" > "$timer_file"

    return 0
}

# Проверить истёк ли таймер авто-rollback (вызывается из cron)
check_auto_rollback() {
    local timer_file="${ROLLBACK_DIR}/auto_timer"
    [ -f "$timer_file" ] || return 0

    local deadline
    deadline=$(cat "$timer_file" 2>/dev/null)
    [ -z "$deadline" ] && return 0

    local now
    now=$(date +%s)

    if [ "$now" -ge "$deadline" ]; then
        print_warning "Авто-rollback: таймер истёк, восстанавливаю конфигурацию..."
        rm -f "$timer_file"
        # Не-интерактивный rollback
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" stop 2>/dev/null || true
        fi
        [ -f "$ROLLBACK_DIR/config" ] && cp -f "$ROLLBACK_DIR/config" "${ZAPRET2_DIR}/config"
        [ -f "$ROLLBACK_DIR/S99zapret2" ] && cp -f "$ROLLBACK_DIR/S99zapret2" "$INIT_SCRIPT"
        for cat_dir in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
            local sfile="$ROLLBACK_DIR/strats/$cat_dir/Strategy.txt"
            [ -f "$sfile" ] && cp -f "$sfile" "${ZAPRET2_DIR}/extra_strats/$cat_dir/Strategy.txt"
        done
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" start 2>/dev/null || true
        fi
        logger -t z2k "Auto-rollback executed: timer expired"
    fi

    return 0
}

# Подтвердить новую конфигурацию (отменяет авто-rollback)
confirm_config() {
    local timer_file="${ROLLBACK_DIR}/auto_timer"
    if [ -f "$timer_file" ]; then
        rm -f "$timer_file"
        print_success "Конфигурация подтверждена, авто-rollback отключён"
    else
        print_info "Авто-rollback не активен"
    fi
    return 0
}

# ==============================================================================
# УДАЛЕНИЕ ZAPRET2
# ==============================================================================

uninstall_zapret2() {
    print_header "Удаление zapret2"

    # Проверить наличие хоть чего-то от zapret2
    if ! is_zapret2_installed && [ ! -d "$ZAPRET2_DIR" ] && [ ! -d "$CONFIG_DIR" ] && [ ! -f "$INIT_SCRIPT" ]; then
        print_info "zapret2 не установлен"
        return 0
    fi

    print_warning "Это удалит:"
    print_warning "  - Все файлы zapret2 ($ZAPRET2_DIR)"
    print_warning "  - Конфигурацию ($CONFIG_DIR)"
    print_warning "  - Init скрипт ($INIT_SCRIPT)"
    print_warning "  - Правила iptables и netfilter хуки"

    printf "\n"
    if ! confirm "Вы уверены? Это действие необратимо!" "N"; then
        print_info "Удаление отменено"
        return 0
    fi

    # Остановить сервис через init-скрипт (мягкая попытка)
    if [ -x "$INIT_SCRIPT" ]; then
        print_info "Остановка сервиса..."
        "$INIT_SCRIPT" stop 2>/dev/null || true
    fi

    # ROOT-CAUSE FIX «rm: Directory not empty»: погасить ВСЕ фоновые писатели
    # в $ZAPRET2_DIR ДО kill nfqws2 и rm. Главный виновник — S99z2k-scheduler:
    # его healthcheck-watchdog перезапускает nfqws2 сразу после kill ниже,
    # перезапущенный демон пишет state.tsv в кэш → финальный rm упирается в
    # непустую директорию. Вебпанель (lighttpd) и z2k-detect тоже пишут в
    # $ZAPRET2_DIR на ходу. Планировщик гасим ПЕРВЫМ.
    local _svc _spids _pat
    for _svc in S99z2k-scheduler S96z2k-webpanel S98z2k-detect; do
        [ -x "/opt/etc/init.d/$_svc" ] && "/opt/etc/init.d/$_svc" stop >/dev/null 2>&1 || true
    done
    for _pat in 'z2k-scheduler\.sh' 'z2k-detect' 'lighttpd.*zapret2'; do
        _spids=$(ps w 2>/dev/null | grep -E "$_pat" | grep -v grep | awk '{print $1}')
        [ -n "$_spids" ] && kill -9 $_spids 2>/dev/null || true
    done

    # Принудительно убить оставшиеся процессы nfqws2 И nfqws (legacy от
    # старых установок zapret до миграции на z2k).
    local pids proc_name
    for proc_name in nfqws2 nfqws; do
        pids=$(pidof "$proc_name" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            print_info "Завершение зависших процессов ${proc_name} (pidof)..."
            kill -9 $pids 2>/dev/null || true
        fi
        # ps-fallback на случай если pidof не находит (бывает на busybox)
        local ps_pids
        ps_pids=$(ps w 2>/dev/null | awk -v name="$proc_name" '$0 ~ "/"name"( |$)" || $0 ~ " "name"( |$)" {print $1}' || true)
        if [ -n "$ps_pids" ]; then
            print_info "Завершение зависших процессов ${proc_name} (ps)..."
            kill -9 $ps_pids 2>/dev/null || true
        fi
    done
    sleep 1

    # Очистка iptables цепочек zapret2
    # Все команды с || true — скрипт запущен под set -e
    print_info "Очистка правил iptables..."
    local chain parent
    for chain in ZAPRET ZAPRET2 z2k_connmark z2k_dpi_rst; do
        for parent in POSTROUTING PREROUTING FORWARD; do
            while iptables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
                iptables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            done
            while ip6tables -t mangle -C "$parent" -j "$chain" 2>/dev/null; do
                ip6tables -t mangle -D "$parent" -j "$chain" 2>/dev/null || break
            done
        done
        iptables -t mangle -F "$chain" 2>/dev/null || true
        iptables -t mangle -X "$chain" 2>/dev/null || true
        ip6tables -t mangle -F "$chain" 2>/dev/null || true
        ip6tables -t mangle -X "$chain" 2>/dev/null || true
    done
    # raw table (RST filter)
    while iptables -t raw -C PREROUTING -j z2k_dpi_rst 2>/dev/null; do
        iptables -t raw -D PREROUTING -j z2k_dpi_rst 2>/dev/null || break
    done
    iptables -t raw -F z2k_dpi_rst 2>/dev/null || true
    iptables -t raw -X z2k_dpi_rst 2>/dev/null || true
    # nat table (masquerade fix)
    while iptables -t nat -C POSTROUTING -j z2k_masq_fix 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j z2k_masq_fix 2>/dev/null || break
    done
    iptables -t nat -F z2k_masq_fix 2>/dev/null || true
    iptables -t nat -X z2k_masq_fix 2>/dev/null || true

    # Удалить init скрипт + legacy init-скрипты от старых установок
    # zapret/nfqws (если миграция шла с предыдущих версий и они остались).
    local _init
    for _init in "$INIT_SCRIPT" \
                 /opt/etc/init.d/S99z2k-scheduler \
                 /opt/etc/init.d/S96z2k-webpanel \
                 /opt/etc/init.d/S98z2k-detect \
                 /opt/etc/init.d/S99zapret \
                 /opt/etc/init.d/S99nfqws \
                 /opt/etc/init.d/S99nfqws2; do
        if [ -f "$_init" ]; then
            rm -f "$_init"
            print_info "Удален init скрипт: $_init"
        fi
    done

    # Tear down the aux HTTP-tunnel (S97) before touching the TG tunnel so
    # that the upcoming `killall -9 tg-mtproxy-client` doesn't race with a
    # still-listening sibling on :1444. S97's own stop kills by PID; the
    # rule sweep below catches anything left behind.
    if [ -x /opt/etc/init.d/S97z2k-http-tunnel ]; then
        /opt/etc/init.d/S97z2k-http-tunnel stop >/dev/null 2>&1 || true
    fi
    local http_cidr
    # shellcheck disable=SC2043  # single-CIDR loop kept as a list for future extension (mirrors S98tg-tunnel CIDRS)
    for http_cidr in 168.119.95.238/32; do
        while iptables -t nat -C PREROUTING -d "$http_cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null; do
            iptables -t nat -D PREROUTING -d "$http_cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null || break
        done
        while iptables -t nat -C OUTPUT -d "$http_cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null; do
            iptables -t nat -D OUTPUT -d "$http_cidr" -p tcp --dport 80 -j REDIRECT --to-port 1444 2>/dev/null || break
        done
        conntrack -D -d "${http_cidr%/*}" 2>/dev/null || true
    done
    rm -f /opt/etc/init.d/S97z2k-http-tunnel \
          /opt/etc/ndm/netfilter.d/91-z2k-http-tunnel-redirect.sh \
          /var/run/z2k-http-tunnel.pid \
          /tmp/z2k-log/z2k-http-tunnel.log 2>/dev/null || true

    # Tear down the RuTracker rt-proxy (S96). Distinct binary (z2k-rt-proxy)
    # and port (1445) — no killall race with the TG block below. Its stop()
    # clears the ndmc DNS-override + sentinel REDIRECT, but we also sweep both
    # explicitly in case the binary was already removed (stop() bails early at
    # `[ -x "$BIN" ] || exit 0`, leaving rutracker pinned to 10.171.171.171).
    if [ -x /opt/etc/init.d/S96z2k-rt-proxy ]; then
        /opt/etc/init.d/S96z2k-rt-proxy stop >/dev/null 2>&1 || true
    fi
    while iptables -t nat -C PREROUTING -d 10.171.171.171 -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null; do
        iptables -t nat -D PREROUTING -d 10.171.171.171 -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null || break
    done
    while iptables -t nat -C OUTPUT -d 10.171.171.171 -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null; do
        iptables -t nat -D OUTPUT -d 10.171.171.171 -p tcp --dport 443 -j REDIRECT --to-port 1445 2>/dev/null || break
    done
    conntrack -D -d 10.171.171.171 2>/dev/null || true
    # Clear the rutracker ndmc DNS-override → sentinel even if stop() never ran
    # (binary already gone). Mirrors S96 dns_override_clear().
    if command -v ndmc >/dev/null 2>&1; then
        for _rtp_dom in rutracker.org www.rutracker.org rutracker.cc static.rutracker.cc api.rutracker.cc rep.rutracker.cc rutracker.wiki; do
            LD_LIBRARY_PATH= ndmc -c "no ip host $_rtp_dom 10.171.171.171" >/dev/null 2>&1 || true
        done
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
    fi
    # Clear the WhatsApp/Ticketmaster relay ndmc pins (→ VPS) so those domains
    # resolve normally again after uninstall.
    if command -v ndmc >/dev/null 2>&1; then
        for _rel_dom in whatsapp.com www.whatsapp.com web.whatsapp.com whatsapp.net g.whatsapp.net static.whatsapp.net mmg.whatsapp.net pps.whatsapp.net dit.whatsapp.net v.whatsapp.net crashlogs.whatsapp.net ticketmaster.com www.ticketmaster.com app.ticketmaster.com api.ticketmaster.com auth.ticketmaster.com identity.ticketmaster.com checkout.ticketmaster.com checkout.prod.ticketmaster.com secure-entry.ticketmaster.com my.ticketmaster.com pubapi.ticketmaster.com help.ticketmaster.com blog.ticketmaster.com legal.ticketmaster.com travel.ticketmaster.com privacy.ticketmaster.com business.ticketmaster.com offeradapter.ticketmaster.com rsvp.ticketmaster.com spon.ticketmaster.com fan-wallet.ticketmaster.com developer.ticketmaster.com static.ticketmaster.com js.ticketmaster.com media.ticketmaster.com s1.ticketm.net media.ticketm.net spon.ticketmaster.net prismic-images.tmol.io mapsapi.tmol.io venue.tmol.co; do
            LD_LIBRARY_PATH= ndmc -c "no ip host $_rel_dom 213.176.74.63" >/dev/null 2>&1 || true
        done
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
    fi
    # Clear the Discord-voice pins (finland*.discord.media → CF edge) so those
    # hostnames resolve normally again after uninstall.
    if command -v ndmc >/dev/null 2>&1; then
        LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
            | awk '/^ip host/ && $3 ~ /^finland[0-9]+\.discord\.media$/ {print $3" "$4}' \
            | while read -r _dv_h _dv_ip; do
                [ -n "$_dv_h" ] && [ -n "$_dv_ip" ] && LD_LIBRARY_PATH= ndmc -c "no ip host $_dv_h $_dv_ip" >/dev/null 2>&1
            done
        LD_LIBRARY_PATH= ndmc -c "system configuration save" >/dev/null 2>&1 || true
    fi
    rm -f "${ZAPRET2_DIR:-/opt/zapret2}/lists/flowseal_discord_voice_hosts.txt" 2>/dev/null || true
    rm -f /opt/etc/init.d/S96z2k-rt-proxy \
          /opt/etc/ndm/netfilter.d/92-z2k-rt-proxy-redirect.sh \
          /opt/sbin/z2k-rt-proxy \
          /var/run/z2k-rt-proxy.pid \
          /tmp/z2k-log/z2k-rt-proxy.log 2>/dev/null || true
    killall -9 z2k-rt-proxy 2>/dev/null || true

    # Tear down the tpws youtube layer (removed as a feature). Same sweep as
    # install/update — destroys the ipsets BEFORE the generic z2k-ipset destroy
    # further down can hit "set in use".
    z2k_remove_tpws

    # Tear down the per-flow PPE de-offload layer: remove its mangle FORWARD/
    # PREROUTING rules (via the lib, then an explicit sweep in case the lib is
    # already gone) and remove the files.
    if [ -r /opt/zapret2/z2k-ppe-deoffload.sh ]; then
        ( . /opt/zapret2/z2k-ppe-deoffload.sh 2>/dev/null && z2k_ppe_remove_rules ) 2>/dev/null || true
    fi
    _ppe_args="-p tcp -m multiport --dports 80,443,2053,2083,2087,2096,8443 -m connskip --connskip 30 -j PPE"
    for _c in FORWARD PREROUTING; do
        while iptables -w -t mangle -C "$_c" $_ppe_args 2>/dev/null; do
            iptables -w -t mangle -D "$_c" $_ppe_args 2>/dev/null || break
        done
        if command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -w -t mangle -C "$_c" $_ppe_args 2>/dev/null; do
                ip6tables -w -t mangle -D "$_c" $_ppe_args 2>/dev/null || break
            done
        fi
    done
    rm -f /opt/zapret2/z2k-ppe-deoffload.sh \
          /opt/etc/ndm/netfilter.d/94-z2k-ppe-deoffload.sh 2>/dev/null || true

    # Tear down the Telegram tunnel: stop the daemon, kill stragglers, drop
    # its REDIRECT rules, remove the init script and the NDM hook that
    # re-inserts those rules. Reported by Сергей 2026-04-16: after
    # uninstall z2k, Telegram kept working because S98tg-tunnel + the
    # 90-z2k-tg-redirect NDM hook stayed on the system and watchdog cron
    # kept the daemon alive.
    if [ -x /opt/etc/init.d/S98tg-tunnel ]; then
        print_info "Остановка Telegram tunnel..."
        /opt/etc/init.d/S98tg-tunnel stop >/dev/null 2>&1 || true
    fi
    killall -9 tg-mtproxy-client 2>/dev/null || true
    # Drop the current ipset-based REDIRECT rules FIRST so the `ipset destroy`
    # further down (it matches names containing "z2k" → catches z2k_tg_dc)
    # doesn't fail with "set in use".
    local tg_chain
    for tg_chain in PREROUTING OUTPUT; do
        while iptables -w -t nat -C "$tg_chain" -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -w -t nat -D "$tg_chain" -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443 2>/dev/null || break
        done
    done
    # Drop legacy per-CIDR REDIRECT rules (pre-ipset builds) in case the init
    # script stop path missed some or was already gone.
    local tg_cidr
    for tg_cidr in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 \
                   91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 \
                   95.161.64.0/20 185.76.151.0/24; do
        while iptables -t nat -C PREROUTING -d "$tg_cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -t nat -D PREROUTING -d "$tg_cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
        done
        while iptables -t nat -C OUTPUT -d "$tg_cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null; do
            iptables -t nat -D OUTPUT -d "$tg_cidr" -p tcp --dport 443 -j REDIRECT --to-port 1443 2>/dev/null || break
        done
    done
    # Flush stale conntrack so nothing lingers through dead REDIRECT path.
    for tg_cidr in 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 \
                   91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 \
                   95.161.64.0/20 185.76.151.0/24; do
        conntrack -D -d "$tg_cidr" 2>/dev/null || true
    done
    # Init script, watchdog binary, PID file, log.
    rm -f /opt/etc/init.d/S98tg-tunnel \
          /opt/etc/init.d/S02z2k-tcp-tuning \
          /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh \
          /opt/sbin/tg-mtproxy-client \
          /var/run/tg-tunnel.pid \
          /tmp/z2k-log/tg-tunnel.log \
          /tmp/tg-tunnel-watchdog.state \
          /tmp/tg-crash.log 2>/dev/null || true
    # Drop watchdog cron entry if present.
    if crontab -l 2>/dev/null | grep -q "tg-tunnel-watchdog\|tg.tunnel"; then
        crontab -l 2>/dev/null | grep -v "tg-tunnel-watchdog\|tg.tunnel" | crontab - 2>/dev/null || true
        print_info "Удалена cron-запись watchdog TG tunnel"
    fi
    print_info "Удалены компоненты Telegram tunnel"

    # Удалить netfilter хуки (все связанные с zapret/z2k)
    local hook
    for hook in /opt/etc/ndm/netfilter.d/*zapret* \
                /opt/etc/ndm/netfilter.d/*z2k*; do
        if [ -f "$hook" ]; then
            rm -f "$hook"
            print_info "Удален netfilter хук: $(basename "$hook")"
        fi
    done

    # Удалить zapret2 и legacy zapret (от старых установок)
    local _dir
    for _dir in "$ZAPRET2_DIR" /opt/zapret; do
        if [ -d "$_dir" ]; then
            rm -rf "$_dir" 2>/dev/null || true
            # Подстраховка: если процесс держал открытый файл/CWD или успел
            # пересоздать что-то между обходом и rmdir — добить держателей
            # (fuser, если есть) и повторить удаление.
            if [ -d "$_dir" ]; then
                command -v fuser >/dev/null 2>&1 && fuser -k -m "$_dir" 2>/dev/null || true
                sleep 1
                rm -rf "$_dir" 2>/dev/null || true
            fi
            if [ -d "$_dir" ]; then
                print_warning "Не удалось полностью удалить $_dir — остались файлы. Проверьте: ps w | grep -E 'zapret2|z2k'"
            else
                print_info "Удалена директория: $_dir"
            fi
        fi
    done

    # Удалить конфигурацию
    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        print_info "Удалена конфигурация"
    fi

    # Очистить временные файлы (включая legacy /tmp/zapret)
    rm -rf /tmp/z2k /tmp/zapret /tmp/zapret2 /tmp/blockcheck* 2>/dev/null

    # Remove the /opt/bin/z2k shortcut if it points at our install.
    if [ -L /opt/bin/z2k ]; then
        rm -f /opt/bin/z2k 2>/dev/null
        print_info "Удалена команда /opt/bin/z2k"
    fi

    # Очистить ipset
    local setname ipset_names
    ipset_names=$(ipset list -n 2>/dev/null | grep -i "zapret\|z2k" || true)
    for setname in $ipset_names; do
        ipset destroy "$setname" 2>/dev/null || true
    done

    # Подметание оставшихся NFQUEUE/zapret/z2k правил во всех таблицах,
    # на случай если specific-цепочки выше что-то пропустили (старые
    # инсталлы, нестандартные правила, и т.п.).
    local _table _num _rule_nums
    for _table in mangle nat raw filter; do
        for _parent in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
            _rule_nums=$(iptables -t "$_table" -L "$_parent" --line-numbers -n 2>/dev/null \
                | grep -iE "NFQUEUE|zapret|nfqws|z2k" | awk '{print $1}' | sort -rn || true)
            for _num in $_rule_nums; do
                iptables -t "$_table" -D "$_parent" "$_num" 2>/dev/null || true
            done
        done
    done

    # Финальная проверка: что-то осталось?
    local _leftover=0
    for _proc in nfqws2 nfqws; do
        if pidof "$_proc" >/dev/null 2>&1; then
            print_warning "Остались процессы $_proc — попробуй снова с правами root"
            _leftover=$((_leftover + 1))
        fi
    done
    for _dir in /opt/zapret2 /opt/zapret; do
        if [ -d "$_dir" ]; then
            print_warning "Осталась директория: $_dir"
            _leftover=$((_leftover + 1))
        fi
    done
    if [ "$_leftover" -gt 0 ]; then
        print_warning "Осталось ${_leftover} артефакт(ов). Если переустановка падает,"
        print_warning "запусти добивающую зачистку: sh -c 'tmp=/tmp/z2k_cleanup.sh; rm -f \"\$tmp\"; for url in \"https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh\" \"https://cdn.jsdelivr.net/gh/necronicle/z2k@z2k-enhanced/z2k_cleanup.sh\" \"https://gh-proxy.com/https://raw.githubusercontent.com/necronicle/z2k/z2k-enhanced/z2k_cleanup.sh\"; do echo \"[i] Пробую: \$url\" >&2; if curl -fsSL --connect-timeout 10 --max-time 180 \"\$url\" -o \"\$tmp\"; then exec sh \"\$tmp\"; fi; done; echo \"[FAIL] Не удалось скачать z2k_cleanup.sh ни с одного зеркала\" >&2; exit 1'"
    else
        print_success "zapret2 полностью удален"
    fi

    return 0
}

# ==============================================================================
# ЭКСПОРТ ФУНКЦИЙ
# ==============================================================================

# Все функции доступны после source этого файла
