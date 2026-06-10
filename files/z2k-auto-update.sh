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

# Source utils.sh FIRST so the layered z2k_fetch() (raw → jsdelivr → gh-proxy →
# ndmc DNS-override) is in scope. auto_update.sh's fetch helpers fall back to a
# bare `curl raw.githubusercontent.com` whenever `command -v z2k_fetch` is false
# — which it always was on this cron path, because only auto_update.sh was
# sourced. Result: the nightly auto-update had NO CDN/mirror fallback and went
# silently dead whenever GitHub raw was blocked or DNS-poisoned (the exact
# RU-ISP scenario the fallback exists for). The menu [U] path already gets it
# via z2k.sh → utils.sh; this makes the unattended path match.
. "${ZAPRET2_DIR}/lib/utils.sh"

# Source the auto-update module (installed at /opt/zapret2/lib/auto_update.sh)
. "${ZAPRET2_DIR}/lib/auto_update.sh"

case "$ACTION" in
    apply)
        # Deterministic per-host jitter 0..5400 sec (90 min) — only for cron path.
        # Manual `apply` (e.g. forcing from menu) shouldn't sleep, so the jitter
        # is gated by stdin being non-tty (cron) and ACTION being unset/apply
        # without explicit "now".
        if [ ! -t 0 ] && [ "$Z2K_AU_NO_JITTER" != "1" ]; then
            HOST="$(hostname 2>/dev/null || echo unknown)"
            JITTER=$( ( echo "$HOST" | cksum | awk '{print $1 % 5400}' ) 2>/dev/null )
            [ -z "$JITTER" ] && JITTER=0
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
