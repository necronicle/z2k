#!/bin/sh
# /opt/etc/ndm/netfilter.d/95-z2k-scheduler-watchdog.sh
#
# Keenetic NDM hook — reboot-independent safety net for the z2k scheduler stack.
# NDM re-runs every netfilter.d script on boot / WAN up-down / hotplug / DHCP
# renew, and that cadence is our resurrection trigger: if the scheduler's respawn
# supervisor has died, bring the whole stack back up.
#
# WHY THIS EXISTS (field 2026-07-06): the supervisor is the SOLE driver of every
# periodic z2k task (auto-update, stats upload, list/geosite refresh, get_config,
# tg-watchdog, PPE re-assert). It respawns the scheduler when the scheduler dies,
# but nothing respawned the SUPERVISOR — S99z2k-scheduler starts it only at boot.
# An OOM sweep (these boxes run swap=0) killed supervisor+scheduler together, so
# auto-update sat dead for days with no recovery until a manual reboot. The init
# now OOM-protects the supervisor, and this hook is the belt to that suspenders:
# it recovers from any death oom_score_adj can't stop (e.g. an NDM-wide SIGKILL).
#
# S99z2k-scheduler start() is idempotent (no-op when the supervisor is alive), so
# calling it whenever the supervisor is absent is safe and cheap. Runs on every
# regen regardless of table — the liveness check is a single kill -0.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

INIT="/opt/etc/init.d/S99z2k-scheduler"
SUP_PIDFILE="/var/run/z2k-scheduler-sup.pid"

[ -x "$INIT" ] || exit 0

# Supervisor alive? Nothing to do.
_sp=$(cat "$SUP_PIDFILE" 2>/dev/null)
if [ -n "$_sp" ] && kill -0 "$_sp" 2>/dev/null; then
    exit 0
fi

# Supervisor is gone — resurrect the scheduler stack (start() re-launches and
# re-OOM-protects the supervisor, which then respawns the scheduler).
"$INIT" start >/dev/null 2>&1

exit 0
