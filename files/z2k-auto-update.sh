#!/bin/sh
# z2k-auto-update.sh — entry point for both cron and manual menu.
#
# Usage:
#   z2k-auto-update.sh [apply|check]
#     apply (default) — run from cron at 02:00 + jitter; downloads manifest,
#                       decides patch/reinstall, applies, health-checks.
#     check           — dry-run: print what would happen, no apply. Used by
#                       the "Проверить обновления" menu item.
#
# Cron line is installed by lib/install.sh into /opt/etc/crontab:
#   0 2 * * * /opt/zapret2/z2k-auto-update.sh apply >/dev/null 2>&1
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
