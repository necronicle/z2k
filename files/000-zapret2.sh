#!/bin/sh
# Keenetic NDM netfilter hook для автоматического восстановления правил zapret2
# Устанавливается в: /opt/etc/ndm/netfilter.d/000-zapret2.sh
#
# Этот скрипт вызывается системой Keenetic при изменениях в netfilter (iptables).
# Когда происходит переподключение к интернету, изменение настроек сети или
# другие события - правила iptables сбрасываются, и этот хук восстанавливает их.

# Переменные окружения от NDM:
# $table - имя таблицы iptables (filter, nat, mangle, raw)
# $type  - `iptables` или `ip6tables`

# env-overridable (NDM не задаёт эти переменные → прод берёт дефолты; тесты подменяют).
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
ZAPRET_CONFIG="${ZAPRET_CONFIG:-/opt/zapret2/config}"

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
    for pidfile in /var/run/nfqws2_*.pid /var/run/nfqws2.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done

    return 1
}
is_nfqws2_running || exit 0

# --- Журнал событий NDM -------------------------------------------------------
# Одна строка на событие, в tmpfs (/tmp — RAM, не флешка). Планировщик режет
# каждый файл в /tmp/z2k-log до 1000 строк (rotate_all_logs), NDM даёт ~280
# событий в сутки — потолок ~70 КБ. До этого журнала у проекта не было ни
# одной цифры о том, как часто NDM сносит правила на реальных роутерах и
# сколько держится окно без NFQUEUE; «после флапа отвалилось» разбиралось
# по пересказу. Пустой HOOK_LOG выключает запись.
HOOK_LOG="${HOOK_LOG-/tmp/z2k-log/ndm-hook.log}"
hook_log() {
    [ -n "$HOOK_LOG" ] || return 0
    [ -d "${HOOK_LOG%/*}" ] || mkdir -p "${HOOK_LOG%/*}" 2>/dev/null || return 0
    printf '%s table=%s type=%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
        "${table:-?}" "${type:-?}" "$*" >> "$HOOK_LOG" 2>/dev/null || true
}

# --- Storm guard: mutex + отложенный повтор (GitHub issue #18) ----------------
# Keenetic дёргает этот hook ДЕСЯТКИ раз за секунду при переподключении / смене
# NAT / пересборке политик. Старый `restart_fw &` (fire-and-forget) плодил 80+
# параллельных restart_fw → load avg 44+, ndm 100% CPU, и при WireGuard в
# default route — лавину `ip link show nwg0` в D-state. Коалесцируем всплеск
# mkdir-mutex'ом: start_fw идёт максимум ОДИН за раз.
#
# До 10.10.2026 всплеск гасился ещё и debounce-окном MIN_INTERVAL=15 с: событие
# внутри окна просто выбрасывалось. Это ошибочно считало, что прошедший
# start_fw «уже покрыл» событие, — а реген NDM, пришедший ПОСЛЕ него, сносил
# правила заново, и до страховки планировщика (раз в 55–60 с) трафик шёл мимо
# очереди. На линии с дёргающимся WAN это и есть «то одно, то другое
# отвалилось». Теперь событие, пришедшее при занятом замке, ставит метку
# PENDING, а держатель замка после своего start_fw прогоняет ещё один, если
# правила действительно пропали. Окно сжимается с минуты до HOOK_SETTLE плюс
# длительность start_fw. MIN_INTERVAL остаётся только маркером для
# z2k-nfqueue-selfheal.sh (он не топчет свежий прогон хука).
LOCK_DIR="${LOCK_DIR:-/tmp/zapret2-restart-fw.lock}"
LAST_RUN="${LAST_RUN:-/tmp/zapret2-restart-fw.last}"
PENDING="${PENDING:-/tmp/zapret2-restart-fw.pending}"
HOOK_SETTLE="${HOOK_SETTLE:-2}"      # с — дать NDM достроить таблицы (тест ускоряет)
MAX_RERUNS="${MAX_RERUNS:-3}"        # потолок повторов за один захват замка;
                                     # дальше — страховка планировщика
NFQ_FLOOR="${NFQ_FLOOR:-2}"          # как в z2k-nfqueue-selfheal.sh

now="$(date +%s 2>/dev/null || echo 0)"

# Stale-lock guard: упавший restart_fw не должен навсегда заклинить пере-применение.
if [ -d "$LOCK_DIR" ]; then
    lock_ts="$(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0)"
    [ "$now" -gt 0 ] && [ "$lock_ts" -gt 0 ] && [ $((now - lock_ts)) -gt 60 ] && \
        rmdir "$LOCK_DIR" 2>/dev/null
fi

# Mutex: атомарный mkdir. Если занят — пересборка уже идёт; оставляем метку,
# чтобы держатель замка прогнал start_fw ещё раз ПОСЛЕ этого события.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    : > "$PENDING" 2>/dev/null
    hook_log "pending (start_fw уже идёт)"
    exit 0
fi
[ "$now" -gt 0 ] && echo "$now" > "$LAST_RUN" 2>/dev/null

# Правила на месте? Повтор нужен только если реген пришёл ПОСЛЕ нашего
# start_fw и снёс их. Иначе второй хук того же регена (NDM дёргает mangle и
# nat по отдельности) гонял бы start_fw впустую, а если NDM реагирует на наши
# же iptables -I — зациклил бы хук. Нет iptables (стенд) — считаем, что пропали.
nfq_rules_present() {
    local _n
    command -v iptables >/dev/null 2>&1 || return 1
    _n="$(iptables -w -t mangle -S 2>/dev/null | grep -c NFQUEUE)" || return 1
    case "$_n" in ''|*[!0-9]*) return 1 ;; esac
    nfq_rules_count="$_n"
    [ "$_n" -ge "$NFQ_FLOOR" ]
}

run_start_fw() {   # $1 — метка для журнала
    local _t0 _t1
    _t0="$(date +%s 2>/dev/null || echo 0)"
    "$INIT_SCRIPT" start_fw >/dev/null 2>&1
    _t1="$(date +%s 2>/dev/null || echo 0)"
    [ "$_t1" -gt 0 ] && echo "$_t1" > "$LAST_RUN" 2>/dev/null
    hook_log "$1 dur=$((_t1 - _t0))s"
}

# Пере-применение — в фон (hook у NDM синхронный, должен вернуться быстро);
# lock гарантирует ровно одно за раз. sleep — дать NDM достроить таблицы.
# ВАЖНО: используем ADD-ONLY start_fw, а НЕ restart_fw. restart_fw = stop_fw;
# sleep 1; start_fw — полный teardown, который на КАЖДЫЙ вызов (а NDM дёргает
# regen ~280x/сут) открывает >=1s окно без NFQUEUE (обход мёртв) и флипает
# ГЛОБАЛЬНЫЕ conntrack-sysctl (nf_conntrack_fastnat 0->1->0, be_liberal,
# checksum), что рвёт долгоживущие сессии на роутере (SSH :222) и флапает обход.
# start_fw идемпотентен (ipt() -C||-I) и до-создаёт ТОЛЬКО пропавшие правила —
# без teardown, без флипа sysctl, без окна; демоны (nfqws2) живут.
#
# Метка PENDING, поставленная между последней проверкой и rmdir, теряется —
# окно микросекундное, его закрывает страховка планировщика.
{
    sleep "$HOOK_SETTLE"
    run_start_fw "run"
    reruns=0
    while [ -f "$PENDING" ] && [ "$reruns" -lt "$MAX_RERUNS" ]; do
        rm -f "$PENDING" 2>/dev/null
        reruns=$((reruns + 1))
        if nfq_rules_present; then
            hook_log "rerun-skip (правила на месте: $nfq_rules_count)"
            break
        fi
        sleep "$HOOK_SETTLE"
        run_start_fw "rerun $reruns/$MAX_RERUNS"
    done
    rmdir "$LOCK_DIR" 2>/dev/null
} &

exit 0
