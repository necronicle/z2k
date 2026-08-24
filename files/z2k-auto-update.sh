#!/bin/sh
# z2k-auto-update.sh — entry point for both cron and manual menu.
#
# Usage:
#   z2k-auto-update.sh [apply|check]
#     apply (default) — triggered by z2k-scheduler.sh at 02:00; sleeps
#                       a per-host deterministic jitter (0..90min) so the
#                       184-router fleet doesn't hit GitHub in one second,
#                       then downloads manifest, decides patch/reinstall,
#                       applies, health-checks.
#     check           — dry-run: print what would happen, no apply. Used by
#                       the "Проверить обновления" menu item.
#
# Triggered by z2k-scheduler.sh at 02:00 daily (replacing cron, which
# is broken on Keenetic Entware — see r-26 field notes).
#
# Mark's call: only z2k-enhanced participates; master users don't get
# auto-updates.

# Cron on Entware ships a tiny PATH that misses awk/grep/curl/etc.
# (see reference_cron_path_entware.md).
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

ZAPRET2_DIR="/opt/zapret2"
ACTION="${1:-apply}"

# Branch gate — apply only for z2k-enhanced
BRANCH_FILE="${ZAPRET2_DIR}/.z2k-branch"
if [ ! -f "$BRANCH_FILE" ] || [ "$(cat "$BRANCH_FILE" 2>/dev/null)" != "z2k-enhanced" ]; then
    if [ "$ACTION" = "check" ]; then
        echo "Авто-обновление работает только на ветке z2k-enhanced."
    fi
    exit 0
fi

# User gate — Z2K_AUTO_UPDATE_ENABLED (default 1, i.e. unchanged behaviour).
#
# Stops the UNATTENDED nightly apply only. `check` stays allowed so the dashboard
# can still say "доступна p-67.9" to someone who updates by hand, and a manual
# apply stays allowed too (Z2K_AU_MANUAL=1, set by the panel and the menu) —
# otherwise flipping this off would leave a user with no way to ever update
# again, which is not what "отключить автообновление" means.
#
# NOT named Z2K_AUTO_UPDATE: that name is already an ENV marker meaning "this
# reinstall was started by the updater", read by lib/install.sh and z2k.sh to
# decide config-merge and non-interactive behaviour. A config key of the same
# name set to 0 could reach those checks and silently change how a reinstall
# merges the user's config.
AU_ENABLED=$(awk -F= '/^Z2K_AUTO_UPDATE_ENABLED=/ {gsub(/[" ]/,"",$2); print $2; exit}' \
             "${ZAPRET2_DIR}/config" 2>/dev/null)
[ -z "$AU_ENABLED" ] && AU_ENABLED=1
if [ "$AU_ENABLED" = "0" ] && [ "$ACTION" = "apply" ] && [ "${Z2K_AU_MANUAL:-0}" != "1" ]; then
    echo "Автообновление отключено в настройках — плановое обновление пропущено."
    exit 0
fi

# Source utils.sh FIRST so the layered z2k_fetch() (raw → jsdelivr → gh-proxy →
# ndmc DNS-override) is in scope. auto_update.sh's fetch helpers fall back to a
# bare `curl raw.githubusercontent.com` whenever `command -v z2k_fetch` is false
# — which it always was on this cron path, because only auto_update.sh was
# sourced. Result: the nightly auto-update had NO CDN/mirror fallback and went
# silently dead whenever GitHub raw was blocked or DNS-poisoned (the exact
# RU-ISP scenario the fallback exists for). The menu [U] path already gets it
# via z2k.sh → utils.sh; this makes the unattended path match.
#
# РАЗРЫВ, О КОТОРОМ НАДО ЗНАТЬ. «Match» здесь неточно: интерактивный путь идёт
# через z2k.sh, где z2k_fetch определён БОГАЧЕ — там есть пятый слой (DoH через
# 1.1.1.1 с пинами edge-IP), написанный под сценарий, когда ТСПУ глушит и SNI,
# и рекурсивный резолвер. Здесь z2k.sh не вызывается, поэтому в области
# видимости остаётся версия из utils.sh: четыре слоя, без DoH.
#
# Это осознанно (тянуть сюда весь z2k.sh ради одного слоя дороже, чем польза),
# но помнить надо вот что: без человека работает ИМЕННО этот путь, и отказ на
# нём некому заметить. Если появится отчёт «обновления не приходят у тех, у
# кого ручное обновление работает» — смотреть сюда первым делом.
. "${ZAPRET2_DIR}/lib/utils.sh"

# Source the auto-update module (installed at /opt/zapret2/lib/auto_update.sh)
. "${ZAPRET2_DIR}/lib/auto_update.sh"

case "$ACTION" in
    apply)
        # Разброс 0..90 мин — только для планового пути. Ручной apply (из меню
        # или панели) ждать не должен, поэтому гейт по stdin (не tty) и
        # Z2K_AU_NO_JITTER. Сам расчёт — z2k_host_jitter (lib/utils.sh): он
        # НИКОГДА не возвращает ноль всем сразу, чего не скажешь о прежнем
        # `cksum`, отсутствующем на Entware, — с ним флот обновлялся ровно
        # в 02:00:00, все вместе.
        if [ ! -t 0 ] && [ "$Z2K_AU_NO_JITTER" != "1" ]; then
            JITTER=$(z2k_host_jitter 5400)
            au_log "ночной разброс: жду ${JITTER}с"
            sleep "$JITTER"
        fi
        au_run_apply
        ;;
    check)
        au_run_check
        ;;
    *)
        echo "usage: z2k-auto-update.sh [apply|check]"
        exit 1
        ;;
esac
