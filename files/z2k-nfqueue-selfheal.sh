#!/bin/sh
# z2k-nfqueue-selfheal.sh — periodic NFQUEUE re-apply safety net.
#
# Invoked ~once/min by z2k-scheduler.sh (mirrors the tg-watchdog / ppe-deoffload
# pattern). Re-applies the zapret2 firewall when nfqws2 is RUNNING and the WAN is
# up but its NFQUEUE rules are GONE. This is the persistent-recovery net for two
# field failure modes that leave a live nfqws2 with 0 NFQUEUE rules (bypass dead,
# users report "после ребута/после очистки ротатора обход не работает, правил 0"):
#
#   1. Boot-race — fw_nfqws_post4/pre4 (S99zapret2.new) SKIP the NFQUEUE insert
#      when get_wan_ifaces4 is empty (WAN iface not up yet at start_fw, or a
#      late/CGNAT WAN) and NEVER retry. Rules stay 0 until something re-applies.
#   2. NDM wipe — Keenetic periodically flushes our iptables rules. The
#      netfilter.d hook (000-zapret2.sh) is the event-driven primary recovery;
#      this is the secondary net for wipes that don't fire a mangle/nat hook.
#
# Note: the CLEAR-ROTATOR webpanel button does NOT cause this (proven: it only
# truncates state.tsv, touches no iptables) — but it is what users click when
# bypass is already dead, so the two got conflated. This heals the real cause.
#
# Idempotent: acts ONLY when rules are genuinely absent AND the WAN is present
# (so restart_fw can actually apply them — no restart storm while WAN is down),
# and no-ops the moment rules exist. Coalesced with the netfilter.d hook via the
# SHARED restart-fw mutex + debounce so the two never run restart_fw at once.
#
# All paths are env-overridable so the unit test can redirect them.

# Entware cron/scheduler PATH does not include /opt/bin where iptables/pidof/ip
# live (see reference_cron_path_entware). Prepend it unless a caller/test set one.
case ":${PATH}:" in
    *:/opt/sbin:*) ;;
    *) PATH="/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin${PATH:+:}${PATH}" ;;
esac
export PATH

INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
ZAPRET_CONFIG="${ZAPRET_CONFIG:-/opt/zapret2/config}"
# Shared with the netfilter.d hook (000-zapret2.sh) — keep names/defaults in sync.
RESTART_FW_LOCK="${RESTART_FW_LOCK:-/tmp/zapret2-restart-fw.lock}"
RESTART_FW_LAST="${RESTART_FW_LAST:-/tmp/zapret2-restart-fw.last}"
MIN_INTERVAL="${MIN_INTERVAL:-15}"     # с — не топтать свежий restart_fw хука
LOCK_STALE="${LOCK_STALE:-60}"         # с — снять зависший mutex упавшего restart_fw
CONFIRM_SETTLE="${CONFIRM_SETTLE:-2}"  # с — settle+re-verify перед fire (гасит ложные падения)
SELFHEAL_LOG="${SELFHEAL_LOG:-/opt/var/log/z2k-scheduler.log}"

log() {
    # Single rare line per actual re-apply; shares the scheduler log (rotated there).
    [ -n "$SELFHEAL_LOG" ] || return 0
    printf '%s nfq-selfheal: %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" \
        >> "$SELFHEAL_LOG" 2>/dev/null || true
}

# --- Preconditions (cheapest first; every miss is a silent no-op) ------------

# init script present + runnable
[ -x "$INIT_SCRIPT" ] || exit 0

# feature enabled by the user
grep -q '^ENABLED=1' "$ZAPRET_CONFIG" 2>/dev/null || exit 0

# nfqws2 actually running — else re-applying would queue traffic to a dead
# consumer (same guard the netfilter.d hook uses).
is_nfqws2_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof nfqws2 >/dev/null 2>&1 && return 0
    fi
    command -v pgrep >/dev/null 2>&1 && pgrep -x nfqws2 >/dev/null 2>&1 && return 0
    for pidfile in /var/run/nfqws2_*.pid /var/run/nfqws2.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}
is_nfqws2_running || exit 0

# WAN_IFACE is shared by both families (get_wan_ifaces4/6 both read it).
wan_iface="$(sed -n 's/^WAN_IFACE=//p' "$ZAPRET_CONFIG" 2>/dev/null | tr -d '"' | head -1)"

# A family (v4/v6) is BROKEN == its NFQUEUE rules are gone WHILE ITS WAN IS UP.
# The WAN gate is essential and per-family: a family with no WAN legitimately has
# 0 rules — e.g. v6 enabled in config but the ISP gives no v6 route, so
# get_wan_ifaces6 is empty and fw_nfqws_post6 correctly skips. Without this gate
# EVERY v6-enabled-but-v6-less Keenetic (a huge share) would restart_fw every
# minute forever. Mirrors get_wan_ifaces4/6: WAN_IFACE wins, else the family's
# own default route. Count via -S (rule dump); on Keenetic -L can trip on NDM's
# ndmmark rules, -S does not.
#
# FALSE-DROP guard: the dump MUST use -w and its exit code MUST be honoured.
# NDM churns iptables constantly; a bare `iptables -t mangle -S` racing an NDM op
# fails on the xtables lock, and the old `2>/dev/null || true` swallowed that
# error → empty output → grep -c NFQUEUE = 0 → we "detected" 0 rules and fired a
# re-apply while the rules were actually present. That is the phantom ~280x/day
# storm. Now: -w waits for the lock instead of failing; if the dump STILL errors,
# the table state is UNKNOWN → treat as NOT missing (return 1) rather than firing.
nfq_missing() {   # $1 = iptables|ip6tables ; $2 = -4|-6
    if [ -z "$wan_iface" ]; then
        ip "$2" route show default 2>/dev/null | grep -q ' dev ' || return 1  # no WAN -> not broken
    fi
    # A dump that fails even WITH -w is not lock contention (that -w waits out) —
    # it's structural (broken iptables / -w unsupported / missing kmod). Treat as
    # UNKNOWN (skip, NOT "0 rules"), but LOG it: otherwise a permanently-broken
    # read makes the poller silently stop healing with no triage trail. Only
    # broken boxes ever hit this — a healthy box's -w never errors, so no spam.
    _dump="$("$1" -w -t mangle -S 2>/dev/null)" || {
        log "WARN: $1 -w -t mangle -S failed — can't verify NFQUEUE this tick (broken iptables / -w unsupported?), skipping"
        return 1
    }
    _n="$(printf '%s\n' "$_dump" | grep -c NFQUEUE)"
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    [ "$_n" -eq 0 ]
}

# True iff any WAN-up family is genuinely missing its NFQUEUE rules.
any_family_missing() {
    nfq_missing iptables -4 && return 0
    if ! grep -q '^DISABLE_IPV6=1' "$ZAPRET_CONFIG" 2>/dev/null \
       && command -v ip6tables >/dev/null 2>&1; then
        nfq_missing ip6tables -6 && return 0
    fi
    return 1
}

# nfqws2 alive but a WAN-up family's NFQUEUE rules absent == the bug. start_fw
# rebuilds BOTH families, so one broken family is enough to trigger.
any_family_missing || exit 0

# CONFIRM: settle briefly and re-verify before committing to a re-apply. A single
# 0-read can be a transient — an NDM regen mid-flight, or a wipe the event-driven
# netfilter.d hook (000-zapret2.sh) is about to repair within a second or two.
# Firing on that transient is a phantom re-apply. After the settle, if the rules
# are back, it was a false drop → do nothing. Only a drop that PERSISTS past the
# settle is a genuine wipe worth re-applying.
sleep "$CONFIRM_SETTLE"
any_family_missing || exit 0

# --- Re-apply, coalesced with the netfilter.d hook ---------------------------

now="$(date +%s 2>/dev/null || echo 0)"

# Debounce: a restart_fw within MIN_INTERVAL (likely the hook) already covered us.
if [ "$now" -gt 0 ] 2>/dev/null && [ -f "$RESTART_FW_LAST" ]; then
    last="$(cat "$RESTART_FW_LAST" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ "$last" -gt 0 ] && [ $((now - last)) -lt "$MIN_INTERVAL" ] && exit 0
fi

# Stale-lock guard: a crashed restart_fw must not wedge recovery forever.
if [ -d "$RESTART_FW_LOCK" ]; then
    lock_ts="$(date -r "$RESTART_FW_LOCK" +%s 2>/dev/null || echo 0)"
    [ "$now" -gt 0 ] && [ "$lock_ts" -gt 0 ] && [ $((now - lock_ts)) -gt "$LOCK_STALE" ] && \
        rmdir "$RESTART_FW_LOCK" 2>/dev/null
fi

# Mutex: atomic mkdir. Busy == the hook (or a prior tick) is already re-applying.
mkdir "$RESTART_FW_LOCK" 2>/dev/null || exit 0
[ "$now" -gt 0 ] && echo "$now" > "$RESTART_FW_LAST" 2>/dev/null

# Recover with the ADD-ONLY start_fw, NOT the heavyweight restart_fw.
# restart_fw = stop_fw; sleep 1; start_fw — a full teardown that (a) opens a
# >=1s zero-NFQUEUE window (bypass dead) and (b) flips the GLOBAL conntrack
# sysctls (nf_conntrack_fastnat 0->1->0, be_liberal, checksum) on every fire.
# NDM wipes our mangle-NFQUEUE rules on hook-less regen paths ~280x/day, so this
# poller fired restart_fw ~280x/day, churning conntrack/the RTCACHE fastpath and
# dropping long-lived router-terminated sessions (SSH :222) + flapping bypass.
# start_fw is idempotent (ipt() -C||-I, private chains -N/-F+-C||-A) and re-adds
# ONLY the missing rules with NO teardown, NO conntrack-sysctl flip, NO gap —
# and still WAN-gated per-family via fw_nfqws_post4/6 (no silent bypass death).
log "nfqws2 up, WAN present, 0 NFQUEUE rules -> start_fw (re-apply)"
"$INIT_SCRIPT" start_fw >/dev/null 2>&1
rmdir "$RESTART_FW_LOCK" 2>/dev/null

exit 0
