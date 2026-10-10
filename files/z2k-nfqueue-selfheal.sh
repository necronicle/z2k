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
# A newly connected main-table WAN can lack rules even while the primary is
# fully covered. Check the expected chain/protocol/interface tuple, not counts.
#
# Idempotent: acts ONLY when required rules are absent AND the WAN is present
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
# Где лежат pid-файлы движка. Переопределяемо ради теста: pidof и pgrep он
# подменяет в PATH, а эта ветка читала АБСОЛЮТНЫЙ /var/run и находила живой
# nfqws2 роутера — «движок выключен» превращалось в «жив», самолечение
# срабатывало, и проверка краснела на железе, оставаясь зелёной на маке.
NFQWS2_PIDFILES="${NFQWS2_PIDFILES:-/var/run/nfqws2_*.pid /var/run/nfqws2.pid}"
CONFIRM_SETTLE="${CONFIRM_SETTLE:-2}"  # с — settle+re-verify перед fire (гасит ложные падения)
# Порог ЧАСТИЧНОГО вайпа (issue #23). NDM при устойчивом реген-флапе (напр. мёртвый
# IKEv2-пир: DPD ~5с гоняет пересборку фаервола) сносит наш набор NFQUEUE не в ноль,
# а ДО 1 — и старый gate `-eq 0` этого НЕ видел, обход застревал мёртвым до ручного
# `S99zapret2 restart`. Теперь этот поллер (1/мин) лечит любой WAN-up family ниже
# порога. Активный family несёт >=3 NFQUEUE-правила (один профиль = post+input+forward),
# поэтому NFQ_FLOOR=2 стоит НИЖЕ активного минимума (не фолсит на легитимном
# минимальном одно-профильном боксе) и ВЫШЕ полевого stuck-счётчика 1 (ловит частичный
# вайп). Полное «0 правил» тоже покрыто (0 < 2), так что это надмножество старого gate.
NFQ_FLOOR="${NFQ_FLOOR:-2}"
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
    # shellcheck disable=SC2086  # список путей с шаблонами — раскрытие намеренно
    for pidfile in $NFQWS2_PIDFILES; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}
is_nfqws2_running || exit 0

# --- Софт-fastpath: держать nf_conntrack_fastnat=0 между регенами ------------
# start_fw ставит fastnat=0 сам (z2k_conntrack_tune_start), и NDM-хук зовёт его
# на каждый реген netfilter. Этот тик — страховка на случай, если прошивка
# вернёт 1 БЕЗ регена: по исходникам ядра Keenetic (nf_conntrack_core.c,
# fast_bind_reached) при fastnat=1 поток после 6 пакетов в обе стороны уходит
# мимо всех mangle-хуков, NFQUEUE его больше не видит, ротатор слепнет.
# Только чтение и запись одного sysctl, без start_fw и без замка. fastroute
# здесь не трогаем: у него гейт по железу, он остаётся за start_fw.
NF_SYSCTL_DIR="${NF_SYSCTL_DIR:-/proc/sys/net/netfilter}"
fastnat_reassert() {
    local _k _v
    for _k in nf_conntrack_fastnat nf_conntrack_fastnat_xfrm; do
        [ -w "$NF_SYSCTL_DIR/$_k" ] || continue
        _v="$(cat "$NF_SYSCTL_DIR/$_k" 2>/dev/null)"
        [ "$_v" = "0" ] && continue
        echo 0 > "$NF_SYSCTL_DIR/$_k" 2>/dev/null && log "$_k был '$_v' -> 0 (возвращён без регена)"
    done
    return 0
}
fastnat_reassert

# Use exactly the same main-table discovery as start_fw.
# shellcheck source=lib/wan.sh
. "${Z2K_WAN_LIB:-/opt/zapret2/lib/wan.sh}"
wan_iface="$(sed -n 's/^WAN_IFACE=//p' "$ZAPRET_CONFIG" 2>/dev/null | tail -n 1 | tr -d "\"'")"

# A family (v4/v6) is BROKEN == its NFQUEUE rules are gone WHILE ITS WAN IS UP.
# The WAN gate is essential and per-family: a family with no WAN legitimately has
# 0 rules — e.g. v6 enabled in config but the ISP gives no v6 route, so
# get_wan_ifaces6 is empty and fw_nfqws_post6 correctly skips. Without this gate
# EVERY v6-enabled-but-v6-less Keenetic (a huge share) would restart_fw every
# minute forever. Mirrors get_wan_ifaces4/6: WAN_IFACE wins, else the family's
# main-table defaults. A failed route read is unknown state and skips the family
# for this tick. Count via -S; on Keenetic -L can trip on NDM's ndmmark rules.
#
# FALSE-DROP guard: the dump MUST use -w and its exit code MUST be honoured.
# NDM churns iptables constantly; a bare `iptables -t mangle -S` racing an NDM op
# fails on the xtables lock, and the old `2>/dev/null || true` swallowed that
# error → empty output → grep -c NFQUEUE = 0 → we "detected" 0 rules and fired a
# re-apply while the rules were actually present. That is the phantom ~280x/day
# storm. Now: -w waits for the lock instead of failing; if the dump STILL errors,
# the table state is UNKNOWN → treat as NOT missing (return 1) rather than firing.
nfq_missing() {   # $1 = iptables|ip6tables ; $2 = -4|-6
    local _wan _iface _dir
    _wan=$(z2k_wan_ifaces "$2" "$wan_iface") || return 1
    [ -n "$_wan" ] || return 1
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
    # Пропало == НИЖЕ порога активного family. Было `-eq 0`, что было слепо к
    # ЧАСТИЧНОМУ вайпу (issue #23: счётчик залипает на 1) — то самое stuck-состояние,
    # которое чинилось только ручным `S99zapret2 restart`. Теперь любой WAN-up family
    # ниже NFQ_FLOOR лечится. Storm-safe: start_fw кладёт полный набор (>=3) → на
    # следующем тике условие снято, а легитимная смена топологии (v6 down / WAN
    # failover) либо роняет WAN family (гейт выше), либо удовлетворяется одним re-apply.
    if [ "$_n" -lt "$NFQ_FLOOR" ]; then
        nfq_why="$2: NFQUEUE-правил $_n"
        return 0
    fi
    # ПОРОГА ПО ОБЩЕМУ ЧИСЛУ МАЛО. Поле 15.09.2026: из шести правил пропало одно —
    # исходящее для TCP, остались исходящее UDP и четыре входящих. Пять не ниже
    # порога, самолечение молчало, а весь исходящий HTTPS шёл мимо обхода: не
    # открывалась веб-версия WhatsApp, и не проходили даже пробы, которыми роутер
    # подбирает для неё адреса. Лечилось только ручным перезапуском сервиса.
    #
    # Поэтому сверяем каждое правило, которое start_fw ОБЯЗАН поставить по конфигу,
    # а не их сумму. Набор повторяет zapret_do_firewall_standard_nfqws_rules_ipt
    # (common/ipt.sh): для протокола с непустым списком портов исходящее правило
    # ставится при ненулевом PKT_OUT, входящие (INPUT и FORWARD) — при ненулевом
    # PKT_IN, а пустой PKT_IN берёт значение PKT_OUT (так же в S99zapret2). Чего
    # конфиг не требует, того и не ждём — иначе вечный re-apply на законно
    # урезанном наборе.
    for _iface in $_wan; do
        for _p in tcp udp; do
            for _c in $(nfq_expected_chains "$_p"); do
                case "$_c" in POSTROUTING) _dir=-o ;; *) _dir=-i ;; esac
                if printf '%s\n' "$_dump" | awk -v c="$_c" -v p="$_p" -v d="$_dir" -v iface="$_iface" '
                    $1=="-A" && $2==c {
                        proto=0; dev=0; queue=0
                        for(i=3;i<NF;i++) {
                            if($i=="-p" && $(i+1)==p) proto=1
                            if($i==d && $(i+1)==iface) dev=1
                            if($i=="-j" && $(i+1)=="NFQUEUE") queue=1
                        }
                        if(proto && dev && queue) found=1
                    }
                    END {exit !found}
                '; then continue; fi
                nfq_why="$2: нет правила $_c $_p на $_iface"
                return 0
            done
        done
    done
    return 1
}

# Значение из конфига без кавычек (последнее присваивание побеждает, как при сорсинге).
cfg_val() {
    sed -n "s/^$1=//p" "$ZAPRET_CONFIG" 2>/dev/null | tail -n 1 | tr -d "\"'"
}

# Цепочки, в которых конфиг требует NFQUEUE-правило для протокола $1.
# NFQWS2_ENABLE=0 — движок правил не ставит вовсе, ждать нечего.
nfq_expected_chains() {
    local _up _ports _out _in
    [ "$(cfg_val NFQWS2_ENABLE)" = "0" ] && return 0
    _up=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
    _ports=$(cfg_val "NFQWS2_PORTS_${_up}")
    [ -n "$_ports" ] || return 0
    _out=$(cfg_val "NFQWS2_${_up}_PKT_OUT")
    _in=$(cfg_val "NFQWS2_${_up}_PKT_IN")
    [ -n "$_in" ] || _in="$_out"
    case "$_out" in ''|0) ;; *) echo POSTROUTING ;; esac
    case "$_in" in ''|0) ;; *) echo INPUT; echo FORWARD ;; esac
}

# True iff any WAN-up family is genuinely missing its NFQUEUE rules.
# Симметричный DISABLE_IPV4/IPV6-гейт: start_fw НЕ кладёт правила отключённого
# family, поэтому опрашивать его нельзя — иначе 0 правил < FLOOR = вечная «поломка»
# → бесконечный re-apply на DISABLE_IPV4=1-боксе с живым v4-роутом (fix #1).
any_family_missing() {
    if ! grep -q '^DISABLE_IPV4=1' "$ZAPRET_CONFIG" 2>/dev/null; then
        nfq_missing iptables -4 && return 0
    fi
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
log "nfqws2 up, WAN present, ${nfq_why:-NFQUEUE-правила пропали} -> start_fw (re-apply)"
"$INIT_SCRIPT" start_fw >/dev/null 2>&1
rmdir "$RESTART_FW_LOCK" 2>/dev/null

exit 0
