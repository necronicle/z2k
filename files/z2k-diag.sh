#!/bin/sh
# z2k-diag.sh — one-shot diagnostics snapshot for user support.
#
# Prints a compact summary of everything we usually ask a user about
# when triaging an issue: an explicit "what's wrong" verdict first, then
# version, arch, service state, iptables rule counts, platform health
# (/opt mount, disk, memory, firmware modules, ipset bitmap:port), network
# path (fastnat, offload, DNS), tunnel health, autocircular state, and
# errors found across every z2k log.
#
# The verdict header exists because this is read in a chat, often on a
# phone: "what is broken" must not require scrolling and prior knowledge
# of what to look at. It lists PROBLEMS ONLY — a healthy router gets one
# line. Every check in it is a case that has cost us a round-trip with a
# user, and whose symptom is always the same ("ничего не работает") while
# the cause sits outside z2k and is invisible in z2k's own logs.
#
# Two output sizes, because there are two ways this reaches us.
#
#   full   — pasted into a chat message, so it must fit in one (~4000 chars).
#            Log tails are short; the errors section is capped per file.
#   report — saved to a file and attached instead. No message limit applies,
#            so log tails are generous and every z2k log is included. This is
#            what the panel's «Скачать файл» button serves.
#
# Sections that can grow unbounded (e.g. a big state.tsv) are truncated in
# both modes with a trailing "... (N more lines)" marker.
#
# Usage:
#   sh /opt/zapret2/z2k-diag.sh           # full snapshot to stdout
#   sh /opt/zapret2/z2k-diag.sh --short   # compact: versions + service
#   sh /opt/zapret2/z2k-diag.sh --json    # machine-readable (for webpanel)
#   sh /opt/zapret2/z2k-diag.sh --report  # full log tails, for saving to a file
#
# Exit codes:
#   0 — diagnostics printed (even if some sub-probes failed)
#   1 — fatal: cannot even locate /opt/zapret2

set -u

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
VPS_IP="${VPS_IP:-213.176.74.63}"

MODE="full"
case "${1:-}" in
    --short)  MODE="short" ;;
    --json)   MODE="json" ;;
    --report) MODE="report" ;;
    -h|--help)
        cat <<EOF
z2k-diag.sh — diagnostics snapshot

Usage:
  z2k-diag.sh             Full snapshot to stdout
  z2k-diag.sh --short     Versions + service state only
  z2k-diag.sh --json      Machine-readable JSON (for webpanel)
  z2k-diag.sh --report    Same sections, full log tails — for saving to a file
  z2k-diag.sh --help      This help
EOF
        exit 0
        ;;
esac

# Bail early if z2k isn't installed at all.
if [ ! -d "$ZAPRET2_DIR" ]; then
    echo "z2k-diag: $ZAPRET2_DIR does not exist — z2k not installed?" >&2
    exit 1
fi

# Safe config read — no `source` (config file may have shell metacharacters).
safe_read() {
    local key="$1"
    local file="$2"
    local default="${3:-}"
    [ -r "$file" ] || { printf '%s' "$default"; return; }
    local val
    val=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | sed "s/^${key}=//" | tr -d '"')
    [ -z "$val" ] && val="$default"
    printf '%s' "$val"
}

# z2k version — read the installed RELEASE TAG (e.g. p-59.1), the SAME source
# the webpanel shows, so every surface (menu / diag / webpanel) reports one
# consistent version. Falls back to the product constant in the persistent lib
# only if the tag file isn't present yet (very old / pre-versioning install).
# The install-time /tmp/z2k dir is wiped on every reboot, so it is NOT a source
# here — reading it used to show "unknown" after every restart (pure cosmetic).
z2k_version_read() {
    local v
    v=$(head -1 "${ZAPRET2_DIR}/.z2k-installed-tag" 2>/dev/null | tr -d ' \r\n')
    [ -z "$v" ] && v=$(safe_read "Z2K_VERSION" "${ZAPRET2_DIR}/lib/utils.sh" "")
    printf '%s' "${v:-unknown}"
}

# Resolve the Entware arch (e.g. mipsel-3.4_kn) via opkg, quiet fallback to uname -m.
get_entware_arch() {
    local opkg_bin="opkg"
    [ -x /opt/bin/opkg ] && opkg_bin="/opt/bin/opkg"
    command -v "$opkg_bin" >/dev/null 2>&1 || { uname -m 2>/dev/null; return; }
    "$opkg_bin" print-architecture 2>/dev/null | awk '
        $1 == "arch" && $2 != "all" {
            prio = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
            if (prio >= max) { max = prio; arch = $2 }
        }
        END { if (arch != "") print arch; else print ""; }
    ' || uname -m 2>/dev/null
}

# Primary LAN IP (prefer RFC1918 over the public WAN default-route source).
get_lan_ip() {
    local ip
    ip=$(ip -4 addr show 2>/dev/null \
        | awk '/inet (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/ {split($2,a,"/"); print a[1]; exit}')
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    fi
    printf '%s' "${ip:-unknown}"
}

# Ping VPS (3 packets, short timeout), return "avg_rtt_ms loss_pct" or "-- --".
#
# Три пакета, а не пять: busybox ping шлёт их с интервалом в секунду и опции -i
# не поддерживает (проверено на роутере), поэтому каждый пакет — это ровно
# секунда ожидания. На пяти пакетах ping занимал 4.07 с из 4.68 с всей сводки,
# то есть 87% времени диагностики уходило сюда. Три пакета дают 2.07 с и всё
# ещё отвечают на вопрос, ради которого это здесь: жив ли путь до VPS и есть ли
# потери. Точность оценки потерь падает с шага 20% до 33% — для триажа неважно,
# там значимо только «ноль или не ноль».
ping_vps_rtt() {
    local out
    out=$(ping -c 3 -W 2 "$VPS_IP" 2>/dev/null | tail -3) || { printf -- '-- --'; return; }
    local loss rtt
    loss=$(printf '%s\n' "$out" | grep -oE '[0-9]+% packet loss' | head -1 | tr -d '% packetloss ' || true)
    rtt=$(printf '%s\n' "$out" | grep -oE 'min/avg/max[^=]*= *[0-9.]+/[0-9.]+' | head -1 | awk -F'/' '{print $(NF)}' || true)
    [ -z "$loss" ] && loss="--"
    [ -z "$rtt" ] && rtt="--"
    printf '%s %s' "$rtt" "$loss"
}

# Shortened file tail with "... (N more)" marker if truncated.
short_tail() {
    local file="$1"
    local lines="${2:-10}"
    # Файла может не быть штатно (компонент не запускался) — молчим, а не пишем
    # «(file missing)»: раньше отчёт открывался именно такой строкой.
    [ -r "$file" ] || return 0
    local total
    total=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        echo "(empty)"
        return
    fi
    if [ "$total" -gt "$lines" ]; then
        local extra=$((total - lines))
        echo "(... first ${extra} older lines skipped)"
    fi
    # В компактном режиме строки режутся по ширине: в auto-update и scheduler
    # логах попадаются очень длинные, и пара таких выносила сводку за лимит
    # одного сообщения. В файловом отчёте режима report обрезки нет.
    if [ "${MODE:-full}" = "report" ]; then
        # Отчёт отправляют в общий чат, а в логах туннеля лежат сырые пары
        # адресов — включая устройства из локальной сети и собственный внешний
        # адрес роутера. Чужих данных там нет, но это самораскрытие владельца,
        # поэтому в файловом режиме адреса маскируются. Для разбора они не
        # нужны: важны коды ошибок и время, а не кто с кем соединялся.
        tail -n "$lines" "$file" 2>/dev/null \
            | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g'
    else
        tail -n "$lines" "$file" 2>/dev/null | cut -c1-150
    fi
}

# =============================================================================
# SECTION: version + host
# =============================================================================
print_version_host() {
    printf '=== z2k diag / %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo now)"
    local version
    version=$(z2k_version_read)
    printf 'z2k version       : %s\n' "$version"

    local kernel
    kernel=$(uname -rsm 2>/dev/null)
    printf 'kernel            : %s\n' "$kernel"

    local sysinfo
    sysinfo=$(grep -iE 'system type|cpu model' /proc/cpuinfo 2>/dev/null | head -2 | paste -sd'; ' - 2>/dev/null || true)
    [ -n "$sysinfo" ] && printf 'cpu               : %s\n' "$sysinfo"

    local entw
    entw=$(get_entware_arch)
    printf 'entware arch      : %s\n' "${entw:-unknown}"

    local nfqws_bin="${ZAPRET2_DIR}/nfq2/nfqws2"
    local nfqws_ver
    if [ -x "$nfqws_bin" ]; then
        nfqws_ver=$("$nfqws_bin" --version 2>&1 | head -1 || true)
        [ -z "$nfqws_ver" ] && nfqws_ver="(no --version output)"
    else
        nfqws_ver="(nfqws2 binary missing at $nfqws_bin)"
    fi
    printf 'nfqws2            : %s\n' "$nfqws_ver"
    printf 'nfqws2 fork       : necronicle/zapret2-z2k (based on bol-van/zapret2)\n'

    local lan_ip
    lan_ip=$(get_lan_ip)
    printf 'LAN IP            : %s\n' "$lan_ip"
}

# Почему nfqws2 не поднялся.
#
# «nfqws2 PIDs: (not running)» — это симптом, а диагностика ради него и
# собирается. До 2026-08-13 причина не попадала в неё никогда: init печатал
# «Daemon 1 failed to start» в консоль тому, кто запускал руками, и всё. Человек
# присылал диагностику, в ней стояло «не запущен», и дальше начиналась переписка.
#
# Порядок такой же, как в init: сперва то, что демон успел сказать при последней
# попытке старта, потом — разбор параметров движком.
#
# Гоняем --dry-run ТОЛЬКО когда демон лежит. Он грузит списки, а на больших
# списках РКН это заметная разовая память; если демон работает, конфигурация
# заведомо разобралась, и платить за это нечем.
print_nfqws_start_failure() {
    local _bin="${ZAPRET2_DIR}/nfq2/nfqws2"
    local _err
    for _err in /tmp/.z2k-daemon-nfqws2-*.err; do
        [ -s "$_err" ] || continue
        printf 'причина отказа    : (от nfqws2, %s)\n' "$_err"
        tail -n 5 "$_err" 2>/dev/null | sed 's/^/  | /'
        return 0
    done

    [ -x "$_bin" ] || { printf 'причина отказа    : бинарник недоступен (%s)\n' "$_bin"; return 0; }
    "$_bin" --help 2>&1 | grep -q -- '--dry-run' || return 0

    local _opt
    _opt=$(sed -n '/^NFQWS2_OPT="/,/"[[:space:]]*$/p' "${ZAPRET2_DIR}/config" 2>/dev/null \
           | sed '1s/^NFQWS2_OPT="//; $s/"[[:space:]]*$//' | tr '\n' ' ')
    [ -n "$(printf '%s' "$_opt" | tr -d ' \t')" ] || {
        printf 'причина отказа    : NFQWS2_OPT пуст — стратегий нет вообще\n'; return 0; }

    local _out _rc
    _out=$(
        set -f
        # shellcheck disable=SC2086  # строка опций, словоделение здесь и нужно
        set -- $_opt
        "$_bin" --dry-run --qnum=299 "$@" 2>&1
    )
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        printf 'причина отказа    : конфигурация разобрана без ошибок — дело не в ней\n'
        printf 'очередь 200 занята: %s\n' \
            "$(grep -cE '^[[:space:]]*200[[:space:]]' /proc/net/netfilter/nfnetlink_queue 2>/dev/null || echo '?')"
    else
        printf 'причина отказа    : nfqws2 отверг конфигурацию (код %s)\n' "$_rc"
        printf '%s\n' "$_out" | grep -viE '^loading|^Loaded |^Running as|^github version|^$' \
            | tail -n 6 | sed 's/^/  | /'
    fi
}

# =============================================================================
# SECTION: service state + config flags
# =============================================================================
print_service() {
    printf '\n=== service ===\n'
    local nfqws_pids
    nfqws_pids=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | tr '\n' ' ')
    if [ -n "$nfqws_pids" ]; then
        printf 'nfqws2 PIDs       : %s\n' "${nfqws_pids% }"
        # Uptime of first PID
        local pid_first
        pid_first=$(echo "$nfqws_pids" | awk '{print $1}')
        if [ -r "/proc/$pid_first/stat" ]; then
            local etime
            etime=$(ps -o etime= -p "$pid_first" 2>/dev/null | tr -d ' ' || true)
            [ -n "$etime" ] && printf 'nfqws2 uptime     : %s\n' "$etime"
        fi
    else
        printf 'nfqws2 PIDs       : (not running)\n'
        print_nfqws_start_failure
    fi

    local cfg="${ZAPRET2_DIR}/config"
    if [ -r "$cfg" ]; then
        printf 'config flags      : '
        local flags=""
        for k in GAME_WARP_ENABLED RKN_SILENT_FALLBACK DROP_DPI_RST RST_FILTER GEOSITE_ENABLED; do
            local v
            v=$(safe_read "$k" "$cfg" "-")
            flags="$flags $k=$v"
        done
        printf '%s\n' "$flags"
    else
        printf 'config flags      : (config missing at %s)\n' "$cfg"
    fi
}

# =============================================================================
# SECTION: iptables rules
# =============================================================================
print_iptables() {
    printf '\n=== iptables ===\n'
    # grep -c already prints a number and returns exit 1 on 0 matches —
    # wrap in `|| true` so set -u / set -e friends don't abort and so the
    # caller variable is a clean integer.
    # Считаем ИСХОДЯЩУЮ и ВХОДЯЩУЮ половины отдельно.
    #
    # Правил шесть: 2 в POSTROUTING (исходящие) и по 2 в INPUT и FORWARD
    # (входящие — из них живёт детекция неудач автоциркуляра). PREROUTING мы не
    # используем вовсе, и старая строка «NFQUEUE prerouting: 0» пугала на пустом
    # месте, зато про четыре правила, от которых зависит ротация, диагностика
    # молчала: пропади входящая половина — здесь стояло бы бодрое «postroute 2».
    local nfq_mangle nfq_in tg_redirect_pre tg_redirect_out
    nfq_mangle=$( (iptables -t mangle -L POSTROUTING -n 2>/dev/null || true) | grep -c NFQUEUE || true)
    nfq_in=$( ( (iptables -t mangle -L INPUT -n 2>/dev/null || true); \
                (iptables -t mangle -L FORWARD -n 2>/dev/null || true) ) | grep -c NFQUEUE || true)
    tg_redirect_pre=$(tg_redirect_counts | cut -d' ' -f1)
    tg_redirect_out=$(tg_redirect_counts | cut -d' ' -f2)
    : "${nfq_mangle:=0}"
    : "${nfq_in:=0}"
    : "${tg_redirect_pre:=0}"
    : "${tg_redirect_out:=0}"
    # r-50+: TG redirect is one ipset match-set rule per chain (the 10 DC
    # subnets live in ipset z2k_tg_dc), NOT 10 per-CIDR rules. So 1 per chain
    # is correct; the meaningful count is the ipset entries below.
    local tg_ipset_n
    tg_ipset_n=$( (ipset list z2k_tg_dc 2>/dev/null || true) | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    : "${tg_ipset_n:=0}"
    # v6 fast-reject: skips dead Telegram IPv6 DCs so mobile clients don't stall
    # ~8s/attempt before falling back to the v4 tunnel (see z2k-tg-redirect.sh).
    local tg_reject6_fwd tg_reject6_out tg_ipset6_n
    tg_reject6_fwd=$( (ip6tables -S FORWARD 2>/dev/null || true) | grep -c 'match-set z2k_tg_dc6 dst' || true)
    tg_reject6_out=$( (ip6tables -S OUTPUT 2>/dev/null || true) | grep -c 'match-set z2k_tg_dc6 dst' || true)
    tg_ipset6_n=$( (ipset list z2k_tg_dc6 2>/dev/null || true) | grep -cE '^[0-9a-fA-F:]+/[0-9]+' || true)
    : "${tg_reject6_fwd:=0}"
    : "${tg_reject6_out:=0}"
    : "${tg_ipset6_n:=0}"
    printf 'NFQUEUE исходящие : %s  (postrouting, ожидается 2)\n' "$nfq_mangle"
    printf 'NFQUEUE входящие  : %s  (input+forward, ожидается 4 — без них не работает автоподбор стратегий)\n' "$nfq_in"
    printf 'TG REDIR PREROUT  : %s  (expected 1 — ipset match-set, r-50+)\n' "$tg_redirect_pre"
    printf 'TG REDIR OUTPUT   : %s  (expected 1 — ipset match-set, r-50+)\n' "$tg_redirect_out"
    printf 'TG ipset z2k_tg_dc: %s DC subnets (expected 10)\n' "$tg_ipset_n"
    printf 'TG v6 REJECT FWD  : %s  (expected 1 — fast-reject dead v6 DCs)\n' "$tg_reject6_fwd"
    printf 'TG v6 REJECT OUT  : %s  (expected 1)\n' "$tg_reject6_out"

    # СКОЛЬКО трафика реально идёт через правила, а не только сколько правил.
    #
    # Отвечает на «интернет с z2k вдвое медленнее». Число правил тут не говорит
    # ничего: важно, сколько пакетов через них прошло.
    #   * NFQUEUE — пакеты, уехавшие в userspace. Отсечка connbytes держит там
    #     только начало соединения, поэтому счётчик обязан быть маленьким
    #     относительно общего трафика. Миллионы = отсечка не работает и в
    #     очередь идёт весь поток.
    #   * -j PPE — пакеты, СНЯТЫЕ с аппаратного ускорения (окно connskip).
    #     Тоже обязан быть небольшим: массовая передача должна вернуться в
    #     железо после окна. Миллионы = скорость упирается в CPU.
    # Счётчики накопительные с момента установки правил — смотреть надо ПРИРОСТ
    # за время нагрузки, а не абсолютное значение.
    local ipt_counters
    ipt_counters=$( (iptables -t mangle -vnL 2>/dev/null || true) \
        | awk '
            /NFQUEUE/ { printf "  %-8s pkts=%-12s bytes=%-12s %s\n", "NFQUEUE", $1, $2, $3; next }
            / PPE / || /-j PPE/ || $3 == "PPE" { printf "  %-8s pkts=%-12s bytes=%-12s %s\n", "PPE", $1, $2, $3 }
          ' )
    if [ -n "$ipt_counters" ]; then
        printf 'счётчики правил (прирост под нагрузкой важнее абсолюта):\n%s\n' "$ipt_counters"
    else
        printf 'счётчики правил : недоступны (iptables -vnL не отработал)\n'
    fi
    printf 'TG ipset z2k_tg_dc6: %s DC subnets (expected 4)\n' "$tg_ipset6_n"
    if [ -e /opt/etc/ndm/netfilter.d/90-z2k-tg-redirect.sh ]; then
        printf 'NDM hook          : installed\n'
    else
        printf 'NDM hook          : NOT installed (TG rules may get wiped on network events)\n'
    fi
}

# =============================================================================
# SECTION: TG tunnel
# =============================================================================
print_tunnel() {
    printf '\n=== telegram tunnel ===\n'
    local tg_bin="/opt/sbin/tg-mtproxy-client"
    if [ -x "$tg_bin" ]; then
        local md5 size tg_pid
        md5=$(md5sum "$tg_bin" 2>/dev/null | awk '{print $1}')
        size=$(wc -c < "$tg_bin" 2>/dev/null | tr -d ' ')
        printf 'binary            : %s (%s bytes, md5 %s)\n' "$tg_bin" "$size" "$md5"
        tg_pid=$(pgrep -fa tg-mtproxy-client 2>/dev/null | grep -v grep | awk '{print $1}' | head -1)
        if [ -n "$tg_pid" ]; then
            printf 'process           : PID %s\n' "$tg_pid"
        else
            printf 'process           : NOT running\n'
        fi
    else
        printf 'binary            : (not installed)\n'
    fi
    local rtt_and_loss
    rtt_and_loss=$(ping_vps_rtt)
    local vps_rtt vps_loss
    vps_rtt=$(echo "$rtt_and_loss" | awk '{print $1}')
    vps_loss=$(echo "$rtt_and_loss" | awk '{print $2}')
    printf 'VPS ping %s     : avg %s ms, loss %s%%\n' "$VPS_IP" "$vps_rtt" "$vps_loss"

    # Часы. Туннель подписывает каждое подключение меткой времени, и релей
    # отвергает её при расхождении больше ±120 с. Роутер без батарейки после
    # перезагрузки или с заблокированным NTP уезжает легко, а снаружи это
    # выглядит как «телеграм не работает» — без единого намёка на причину.
    # Сверяемся с заголовком Date самого релея: он и есть та шкала, по которой
    # нас проверяют.
    local skew
    skew=$(clock_skew_vs_relay 2>/dev/null)
    case "$skew" in
        ''|*[!0-9-]*) printf 'clock vs relay    : не удалось выяснить\n' ;;
        *)  if [ "$skew" -gt 120 ] || [ "$skew" -lt -120 ]; then
                printf 'clock vs relay    : %+d s — ВНЕ ДОПУСКА (±120), туннель не поднимется\n' "$skew"
            else
                printf 'clock vs relay    : %+d s (ок)\n' "$skew"
            fi ;;
    esac

    # Строки про личность и регистрацию — то, на чём туннель спотыкается чаще
    # всего. Раньше их приходилось просить у человека отдельной командой, хотя
    # диагностика для того и нужна, чтобы он ничего не набирал руками.
    local tg_log="/tmp/z2k-log/tg-tunnel.log"
    if [ -r "$tg_log" ]; then
        printf 'tunnel log        : %s\n' "$tg_log"
        grep -aE 'identity|registered|register attempt|занят другим|перерегистр|перевыпуск' "$tg_log" 2>/dev/null \
            | tail -8 | sed 's/^/  /'
        tail -4 "$tg_log" 2>/dev/null | sed 's/^/  /'
    else
        printf 'tunnel log        : нет (%s)\n' "$tg_log"
    fi
}

# =============================================================================
# SECTION: autocircular state
# =============================================================================
print_rotator() {
    printf '\n=== autocircular state ===\n'
    local state="${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv"
    if [ ! -r "$state" ]; then
        printf '(no state.tsv at %s)\n' "$state"
        return
    fi
    local total
    total=$(grep -cvE '^(#|$)' "$state" 2>/dev/null | tr -d ' ')
    printf 'tracked entries   : %s\n' "${total:-0}"
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        return
    fi
    # В компактном режиме 10 строк, в файловом отчёте 40: сводку вставляют в
    # одно сообщение, и эта секция была самой крупной в ней. Полный список всё
    # равно нужен редко — при разборе конкретного домена его смотрят в панели.
    local _rows=10
    [ "$MODE" = "report" ] && _rows=40
    printf '(first %s rows: key / host / strategy / ts)\n' "$_rows"
    grep -vE '^(#|$)' "$state" 2>/dev/null | head -"$_rows"
    if [ "$total" -gt "$_rows" ]; then
        printf '... %s more rows\n' "$((total - _rows))"
    fi
}

# Проба bitmap:port кэшируется: её дёргают и шапка, и секция platform, а это
# create+destroy реального набора — делать дважды незачем.
Z2K_BITMAP_OK=""
bitmap_port_ok() {
    if [ -z "$Z2K_BITMAP_OK" ]; then
        if ! command -v ipset >/dev/null 2>&1; then
            Z2K_BITMAP_OK="unknown"
        # Снести возможный залипший набор от прерванного прошлого прогона: иначе
        # create падает «set exists», проба врёт «нет bitmap:port», и КАЖДЫЙ
        # следующий отчёт открывается ложным «обход не работает ЦЕЛИКОМ».
        # Та же конвенция уже принята в lib/utils.sh и files/S99zapret2.new.
        elif { ipset destroy z2k_diag_probe 2>/dev/null || true
               ipset create z2k_diag_probe bitmap:port range 0-65535 2>/dev/null; }; then
            ipset destroy z2k_diag_probe 2>/dev/null
            Z2K_BITMAP_OK="yes"
        else
            Z2K_BITMAP_OK="no"
        fi
    fi
    printf '%s' "$Z2K_BITMAP_OK"
}

# =============================================================================
# SECTION: вердикт — что именно не так, первым экраном
# =============================================================================
# Сводку читают в чате, часто с телефона. Раньше, чтобы понять «а что вообще
# сломано», надо было пролистать её целиком и знать, на что смотреть. Теперь
# сверху лежат явные вердикты, и только по проблемам: если всё в порядке —
# одна строка. Детали остаются ниже, они никуда не делись.
# clock_skew_vs_relay -> расхождение часов роутера с релеем в секундах (со
# знаком), пусто если не удалось выяснить.
#
# Вынесено в функцию, потому что нужно в двух местах: в сводке «что не так»
# (расхождение больше допуска = телеграм не поднимется) и в разделе туннеля.
# Дублировать разбор нельзя — разойдётся.
#
# Считаем сами: date -d не понимает RFC-формат ни в busybox, ни в BSD, то есть
# очевидный способ здесь просто не работает.
# Сколько правил редиректа телеграма стоит сейчас: "<PREROUTING> <OUTPUT>".
#
# Вынесено в функцию по той же причине, что и clock_skew_vs_relay: нужно в двух
# местах — в разделе iptables и в сводке «что не так». Дублировать подсчёт
# нельзя, разойдётся, а разошедшись даст ровно то, из-за чего эта проверка и
# появилась: в деталях «0, ожидается 1», а в сводке «проблем не найдено».
tg_redirect_counts() {
    local _pre _out
    _pre=$( (iptables -t nat -L PREROUTING -n 2>/dev/null || true) | grep -c 'redir ports 1443' || true)
    _out=$( (iptables -t nat -L OUTPUT -n 2>/dev/null || true) | grep -c 'redir ports 1443' || true)
    printf '%s %s\n' "${_pre:-0}" "${_out:-0}"
}

clock_skew_vs_relay() {
    local srv_date srv_epoch now_epoch
    srv_date=$(curl -s -m 8 -D - -o /dev/null "https://${VPS_IP}.nip.io/" 2>/dev/null \
               | awk 'tolower($1)=="date:"{sub(/^[Dd]ate: */,""); sub(/\r$/,""); print; exit}')
    [ -n "$srv_date" ] || return 1
    srv_epoch=$(printf '%s\n' "$srv_date" | awk '
        function days_from_civil(y, m, d,   era, yoe, doy, doe) {
            if (m <= 2) y--
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return era * 146097 + doe - 719468
        }
        BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
                for (i = 1; i <= 12; i++) mon[mn[i]] = i }
        { gsub(/,/, ""); d = $2 + 0; m = mon[$3]; y = $4 + 0; split($5, t, ":")
          if (m == 0 || y == 0) { print ""; exit }
          print days_from_civil(y, m, d) * 86400 + t[1] * 3600 + t[2] * 60 + t[3] }')
    now_epoch=$(date +%s 2>/dev/null)
    [ -n "$srv_epoch" ] && [ -n "$now_epoch" ] || return 1
    printf '%s' "$((now_epoch - srv_epoch))"
}

print_health() {
    local issues=""
    _add() { issues="${issues}  [!] $1
"; }

    mount 2>/dev/null | grep -q ' /opt ' || \
        _add "/opt не смонтирован — Entware недоступен, лечится проверкой файловой системы (e2fsck) и перезагрузкой"

    [ "$(bitmap_port_ok)" = "no" ] && \
        _add "ядро не умеет ipset bitmap:port — правила nfqws не встанут, обход не работает ЦЕЛИКОМ"

    if [ -r /proc/net/ip_tables_matches ]; then
        grep -qw multiport /proc/net/ip_tables_matches || \
            _add "нет модулей Netfilter — доустановить «Модули ядра подсистемы Netfilter» в веб-интерфейсе Keenetic"
    fi

    if [ -r /proc/sys/net/netfilter/nf_conntrack_fastnat ]; then
        [ "$(cat /proc/sys/net/netfilter/nf_conntrack_fastnat 2>/dev/null)" = "1" ] && \
            _add "fastnat=1 — трафик идёт мимо conntrack, стратегии не применяются"
    fi

    # «Не запущен» без причины — это половина ответа, за которой всегда следует
    # круг переписки. Причина уже собрана секцией service, здесь на неё ссылаемся.
    pgrep -f 'nfq2/nfqws2' >/dev/null 2>&1 || \
        _add "nfqws2 не запущен — обход не работает (причина в разделе service, строка «причина отказа»)"

    # Половина правил на месте, половины нет. Снаружи это выглядит не как поломка,
    # а как «стратегия залипла»: десинк работает, а переключать её не на чем —
    # признаки неудачи приходят входящими пакетами, которых движок не видит.
    if pgrep -f 'nfq2/nfqws2' >/dev/null 2>&1; then
        local _nfq_in
        _nfq_in=$( ( (iptables -t mangle -L INPUT -n 2>/dev/null || true); \
                     (iptables -t mangle -L FORWARD -n 2>/dev/null || true) ) | grep -c NFQUEUE || true)
        [ "${_nfq_in:-0}" -eq 0 ] && \
            _add "правила для входящих пакетов отсутствуют — обход работает, но стратегии перестанут переключаться сами"
    fi

    if command -v df >/dev/null 2>&1; then
        local freek
        freek=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
        [ -n "$freek" ] && [ "$freek" -lt 20480 ] 2>/dev/null && \
            _add "на /opt меньше 20 МБ свободно — обновление не встанет"
    fi

    # Дальше — поломки, которые сводка НЕ ловила, хотя детали ниже их показывают.
    # Все четыре стоили нам по кругу переписки за один день 2026-08-05: человек
    # читал «явных проблем не найдено» ровно в тот момент, когда у него не
    # работал обход или молчал телеграм, и шёл в поддержку с этой строкой.
    # Заголовок, который врёт умолчанием, хуже отсутствующего.

    # Список РКН. Обнулялся сам собой по ночам (чинилось в r-72.2), и в этом
    # состоянии обход блокировок мёртв целиком, а снаружи это выглядит как
    # «сайты не открываются» без единой зацепки.
    local _rkn="${ZAPRET2_DIR}/extra_strats/TCP/RKN/List.txt"
    if [ ! -s "$_rkn" ]; then
        _add "список заблокированных сайтов пуст — обход не сработает ни на одном сайте, обновите списки"
    else
        local _rn
        _rn=$(grep -cvE '^[[:space:]]*(#|$)' "$_rkn" 2>/dev/null)
        [ -n "$_rn" ] && [ "$_rn" -lt 1000 ] 2>/dev/null && \
            _add "в списке заблокированных сайтов всего $_rn строк — похоже на обрыв загрузки, обновите списки"
    fi

    # Часы. Туннель подписывает каждое подключение меткой времени, релей
    # отвергает её при расхождении больше ±120 с. Роутер без батарейки уезжает
    # легко, а снаружи это выглядит как «телеграм не работает» — и причину не
    # видно нигде, кроме этой проверки.
    local _skew
    _skew=$(clock_skew_vs_relay 2>/dev/null)
    case "$_skew" in
        ''|*[!0-9-]*) ;;
        *)  if [ "$_skew" -gt 120 ] 2>/dev/null || [ "$_skew" -lt -120 ] 2>/dev/null; then
                _add "часы роутера разошлись на ${_skew} с — телеграм-туннель не поднимется, пока время не поправить"
            fi ;;
    esac

    # Туннель телеграма: бинарник на месте, а процесса нет. Это не «медленно»,
    # это телеграм не работает вообще.
    if [ -x /opt/sbin/tg-mtproxy-client ]; then
        pgrep -f 'tg-mtproxy-client' >/dev/null 2>&1 || \
            _add "телеграм-туннель установлен, но не запущен — телеграм работать не будет"

        # А ЕЩЁ ПРАВИЛА РЕДИРЕКТА. Процесс может быть живым, слушать свой порт
        # и при этом не получать ни одного пакета: без правил в nat трафик к
        # дата-центрам телеграма уходит прямо в WAN, где его и режут. Человек
        # видит вечное «Подключение…».
        #
        # Полевой случай (issue #34, 2026-08-17): в разделе iptables честно
        # напечатано «TG REDIR PREROUT: 0 (expected 1)», а сводка «что не так»
        # сказала «явных проблем не найдено» — она про эти правила не
        # спрашивала вовсе. Человек читает первую строку и успокаивается.
        local _tgr_pre _tgr_out
        _tgr_pre=$(tg_redirect_counts | cut -d' ' -f1)
        _tgr_out=$(tg_redirect_counts | cut -d' ' -f2)
        if [ "$_tgr_pre" = "0" ] || [ "$_tgr_out" = "0" ]; then
            _add "правила редиректа телеграма отсутствуют (PREROUTING=$_tgr_pre, OUTPUT=$_tgr_out, ожидается по 1) — трафик идёт мимо туннеля, телеграм не подключится"
        fi
    fi

    # Обновление откатилось. Симптом «nfqws2 не запущен» мы называем выше, но
    # человек видит другое: версия не меняется сколько ни обновляй. Причина в
    # том, что после установки файлов сервис не поднимается, health-check это
    # видит и возвращает всё назад — и так каждый раз. Без этой строки связь
    # между «сервис не стартует» и «обновиться не могу» не видна никак.
    local _aulog="/opt/var/log/z2k-auto-update.log"
    if [ -r "$_aulog" ]; then
        # Смотрим только хвост: старый откат, после которого всё наладилось,
        # тревожить не должен.
        if tail -40 "$_aulog" 2>/dev/null | grep -q "rolling back"; then
            _why=$(tail -40 "$_aulog" 2>/dev/null | grep -oE "health-check FAILED: [^\"]*" | tail -1)
            _add "последнее обновление откатилось${_why:+ (${_why})} — версия не изменится, пока причина не устранена"
        fi
    fi

    # WARP включён, но туннеля нет. Игровые адреса при этом уедут в никуда.
    local _warp_on
    _warp_on=$(grep -m1 '^GAME_WARP_ENABLED=' "${ZAPRET2_DIR}/config" 2>/dev/null | cut -d= -f2 | tr -d '" ')
    if [ "$_warp_on" = "1" ]; then
        pgrep -f 'usque' >/dev/null 2>&1 || \
            _add "WARP включён, но туннель не поднят — игровой трафик пойдёт мимо него"
    fi

    printf '=== что не так ===\n'
    if [ -n "$issues" ]; then
        printf '%s' "$issues"
    else
        printf '  явных проблем не найдено — смотри детали ниже\n'
    fi
}

# =============================================================================
# SECTION: platform — то, что ломает z2k целиком и снаружи не видно
# =============================================================================
# Каждая проверка здесь — отдельный случай, который стоил круга переписки в
# чате. Их объединяет то, что симптом всегда один и тот же («ничего не
# работает»), а причина лежит вне z2k и по логам самого z2k не видна.
print_platform() {
    printf '\n=== platform ===\n'

    # /opt на USB. После пропадания питания ext4 остаётся грязной, и Entware
    # просто не монтируется: z2k «пропал» целиком, при этом ни одной внятной
    # ошибки нигде нет. Отличать «не смонтирован» от «нет места» обязательно —
    # лечится это по-разному (e2fsck против чистки).
    if mount 2>/dev/null | grep -q ' /opt '; then
        printf 'opt mount         : %s\n' "$(mount 2>/dev/null | grep ' /opt ' | head -1)"
    else
        printf 'opt mount         : NOT MOUNTED (Entware недоступен — грязная ext4 после отключения питания?)\n'
    fi

    # Место. Установка распаковывает во временный каталог рядом, поэтому кончиться
    # оно может в момент обновления, а проявиться позже.
    if command -v df >/dev/null 2>&1; then
        printf 'opt space         : %s\n' \
            "$(df -h /opt 2>/dev/null | awk 'NR==2 {printf "%s свободно из %s (занято %s)", $4, $2, $5}')"
    fi

    # Память. OOM на этих роутерах убивал и планировщик задач, и SSH — после
    # чего «задачи не выполняются» без единого следа в логах z2k.
    if [ -r /proc/meminfo ]; then
        printf 'memory            : %s\n' \
            "$(awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} /^SwapFree:/{sf=$2} /^SwapTotal:/{st=$2}
                    END {printf "%d МБ свободно из %d, swap %d/%d МБ",
                         a/1024, t/1024, (st-sf)/1024, st/1024}' /proc/meminfo 2>/dev/null)"
    fi

    # Загрузка CPU. Без неё счётчики правил выше неоднозначны: «медленно»
    # из-за того, что поток идёт мимо аппаратного ускорения, и «медленно»
    # из-за того, что процессор занят чем-то посторонним, выглядят одинаково.
    if [ -r /proc/loadavg ]; then
        printf 'loadavg           : %s (ядер: %s)\n' \
            "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" \
            "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')"
    fi

    # Компоненты прошивки Keenetic. «Не стартует» чаще всего упирается сюда, и
    # это первое, что мы спрашиваем по README. Проверяем по таблицам netfilter,
    # а не поиском .ko: на Keenetic модули вкомпилены в ядро, файлов нет, и
    # поиск по файлам дал бы ложное «не установлено».
    if [ -r /proc/net/ip_tables_matches ]; then
        printf 'netfilter modules : multiport=%s conntrack=%s\n' \
            "$(grep -qw multiport /proc/net/ip_tables_matches && echo да || echo НЕТ)" \
            "$(grep -qw conntrack /proc/net/ip_tables_matches && echo да || echo НЕТ)"
    else
        printf 'netfilter modules : /proc/net/ip_tables_matches недоступен — компоненты Netfilter не установлены?\n'
    fi

    # bitmap:port. Самый тяжёлый отказ из возможных: без этого типа не создаются
    # наборы zport_*, а на них висят ВСЕ правила nfqws — обход мёртв целиком, при
    # том что сервис «запущен» и в логах чисто (issue #27).
    #
    # Проверяем СОЗДАНИЕМ пробного набора, а не наличием модуля: тип может быть
    # вкомпилен в ядро (файла .ko нет, а тип есть) либо отсутствовать при живом
    # ipset. Только create отвечает на вопрос честно.
    case "$(bitmap_port_ok)" in
        yes) printf 'ipset bitmap:port : да\n' ;;
        no)  printf 'ipset bitmap:port : НЕТ — правила nfqws не встанут, обход не работает целиком (issue #27)\n' ;;
        *)   printf 'ipset bitmap:port : не проверить (ipset не найден)\n' ;;
    esac
}

# =============================================================================
# SECTION: списки доменов
# =============================================================================
# Раздел «Geosite» в вебпанели снят 2026-08-04: он показывал одну справочную
# строку и кнопку принудительного обновления для того, что и так обновляется
# само раз в сутки через планировщик (z2k-update-lists.sh -> z2k-geosite.sh).
# Единственные полезные данные оттуда — сколько доменов реально в списках — не
# теряем, а переносим сюда: при разборе «сайт не обходится» это первое, что
# надо знать, и раньше за этим приходилось лезть в отдельную вкладку.
print_lists() {
    printf '\n=== domain lists ===\n'
    local d="${ZAPRET2_DIR}/extra_strats" f n label
    # Метки латиницей не из вредности: printf '%-18s' считает БАЙТЫ, а не
    # символы, поэтому кириллица ломает выравнивание колонок — «YouTube видео»
    # это 13 символов, но 19 байт, и padding не срабатывает. Вся остальная
    # сводка и так на английских метках, так что это ещё и единообразнее.
    for f in "TCP/RKN/List.txt:RKN blocked (TCP)" \
             "TCP/YT/List.txt:YouTube" \
             "TCP/YT_GV/List.txt:YouTube video" \
             "UDP/YT/List.txt:YouTube QUIC" \
             "TCP/RKN/Discord.txt:Discord"; do
        label="${f#*:}"; f="${f%%:*}"
        if [ -s "$d/$f" ]; then
            n=$(grep -cv '^[[:space:]]*$' "$d/$f" 2>/dev/null)
            printf '%-18s: %s domains\n' "$label" "${n:-0}"
        else
            printf '%-18s: MISSING or empty (%s)\n' "$label" "$f"
        fi
    done
    # Пользовательские списки — их правит человек, и ошибка чаще всего там.
    for f in lists/extra-domains.txt lists/whitelist.txt; do
        if [ -s "${ZAPRET2_DIR}/$f" ]; then
            n=$(grep -cvE '^[[:space:]]*(#|$)' "${ZAPRET2_DIR}/$f" 2>/dev/null)
            printf '%-18s: %s lines\n' "$(basename "$f" .txt)" "${n:-0}"
        fi
    done
}

# =============================================================================
# SECTION: network path — почему стратегии могут не применяться
# =============================================================================
print_netpath() {
    printf '\n=== network path ===\n'

    # fastnat. При =1 трафик уходит мимо conntrack, и стратегии просто не
    # применяются — сервис при этом работает, правила стоят, счётчики нулевые.
    if [ -r /proc/sys/net/netfilter/nf_conntrack_fastnat ]; then
        local fn; fn=$(cat /proc/sys/net/netfilter/nf_conntrack_fastnat 2>/dev/null)
        if [ "$fn" = "1" ]; then
            printf 'fastnat           : 1 — ПЛОХО, трафик идёт мимо conntrack и стратегии пропускаются\n'
        else
            printf 'fastnat           : %s (ок)\n' "$fn"
        fi
    fi

    # Аппаратный offload. Ослепляет nfqws2: он перестаёт видеть RST и ответы,
    # поэтому «стратегия залипает» и ротация не срабатывает.
    for _hw in /proc/sys/net/netfilter/nf_conntrack_hwnat /proc/sys/net/netfilter/nf_conntrack_whnat; do
        [ -r "$_hw" ] || continue
        printf 'offload %-9s : %s\n' "$(basename "$_hw" | sed 's/nf_conntrack_//')" "$(cat "$_hw" 2>/dev/null)"
    done

    # Резолв. У людей поголовно свои DNS — AdGuard, DoH, публичные резолверы, —
    # и отказ чужого резолвера выглядит как вина роутера. Спрашиваем это в чате
    # каждый раз вручную, поэтому пусть отвечает сама сводка.
    if command -v nslookup >/dev/null 2>&1; then
        printf 'dns servers       : %s\n' \
            "$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
        # Берём именно IPv4: nslookup отдаёт оба семейства, и первым часто идёт
        # IPv6 — в v4-центричной сводке это сбивает с толку. Если v4 нет вовсе,
        # показываем что нашлось, чтобы не соврать «не резолвится».
        printf 'resolve check     : %s\n' \
            "$(nslookup example.com 2>/dev/null \
               | awk '/^Name:/{s=1; next}
                      s && /^Address/ {a=$NF; if (a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print a; found=1; exit}
                                       if (any == "") any=a}
                      END {if (!found) print (any != "" ? any " (только IPv6)" \
                                 : "НЕ РЕЗОЛВИТСЯ — проблема в DNS, а не в обходе")}')"
    fi

    print_agh
}

# AdGuard Home. Если он стоит, 53-й порт держит он, а встроенный dns-proxy
# прошивки штатно отключается — и записи `ip host`, на которых держится обход
# Instagram и веб-WhatsApp, не спрашивает НИКТО: они целы и бесполезны, клиент
# получает подменённый провайдером адрес. Снаружи это неотличимо от «обход не
# работает», в логах z2k при этом ровно ничего. Разбор такого случая у живого
# пользователя занял час именно потому, что в сводке не было видно ни AGH, ни
# того, что наши пины перекрыты.
print_agh() {
    local y c hosts pinned inagh cmp n_pin n_hit state
    y=""
    for c in "${Z2K_AGH_YAML:-}" /opt/etc/AdGuardHome/AdGuardHome.yaml \
             /opt/AdGuardHome/AdGuardHome.yaml /opt/var/AdGuardHome/AdGuardHome.yaml \
             /opt/share/AdGuardHome/AdGuardHome.yaml; do
        [ -n "$c" ] && [ -f "$c" ] && { y="$c"; break; }
    done
    if [ -z "$y" ]; then
        printf 'AdGuardHome       : не найден (клиентам отвечает dns-proxy прошивки)\n'
        return 0
    fi
    state="не запущен"
    if pidof AdGuardHome >/dev/null 2>&1 || ps w 2>/dev/null | grep -qi '[A]dGuardHome'; then
        state="работает"
    fi
    printf 'AGH config        : %s\n' "$y"

    # Список доменов берём из самого рефрешера, а не дублируем здесь: иначе две
    # копии списка разъедутся, и сводка начнёт врать про рассинхрон.
    hosts=$(awk -F'"' '/^HOSTS=/ {print $2; exit}' "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" 2>/dev/null)
    if [ -z "$hosts" ] || ! command -v ndmc >/dev/null 2>&1; then
        printf 'AdGuardHome       : %s (сверить записи не с чем)\n' "$state"
        return 0
    fi
    pinned=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
        | awk -v hosts="$hosts" '
            BEGIN { n = split(hosts, h, " "); for (i = 1; i <= n; i++) own[h[i]] = 1 }
            /^ip host/ && ($3 in own) && $4 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $3 "\t" $4 }')
    inagh=$(awk -v hosts="$hosts" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        function unq(s) { gsub(/"/, "", s); gsub(Q, "", s); return s }
        BEGIN { Q = sprintf("%c", 39); n = split(hosts, h, " ")
                for (i = 1; i <= n; i++) own[tolower(h[i])] = 1
                KRX = "^[ \t]*[\"" Q "]?rewrites[\"" Q "]?[ \t]*:" }
        !inb && $0 ~ KRX { inb = 1; kin = match($0, /[^ \t]/) - 1; next }
        inb {
            t = trim($0)
            if (t == "" || substr(t, 1, 1) == "#") next
            cur = match($0, /[^ \t]/) - 1
            if (cur < kin || (cur == kin && substr(t, 1, 1) != "-")) { inb = 0; next }
            if (substr(t, 1, 1) == "-") { d = ""; a = ""; t = trim(substr(t, 2)) }
            if (t == "") next
            p = index(t, ":")
            if (p == 0) next
            k = unq(trim(substr(t, 1, p - 1))); v = unq(trim(substr(t, p + 1)))
            if (k == "domain") d = tolower(v)
            else if (k == "answer") a = v
            if (d != "" && a != "" && (d in own)) { print d "\t" a; d = "" }
        }' "$y" 2>/dev/null)
    cmp=$( { printf '%s\n' "$pinned" | sed 's/^/P /'
             printf '%s\n' "$inagh"  | sed 's/^/A /'; } \
           | awk '$1 == "P" && NF == 3 { p[$2 " " $3] = 1; np++ }
                  $1 == "A" && NF == 3 { a[$2 " " $3] = 1 }
                  END { for (k in p) if (k in a) h++; printf "%d %d", np + 0, h + 0 }')
    n_pin=${cmp%% *}; n_hit=${cmp##* }
    if [ "$n_pin" = 0 ]; then
        printf 'AdGuardHome       : %s, наших ip host нет — сверять нечего\n' "$state"
    elif [ "$n_hit" = "$n_pin" ]; then
        printf 'AdGuardHome       : %s, наши записи в rewrites: %s/%s — синхронизированы\n' \
            "$state" "$n_hit" "$n_pin"
    else
        printf 'AdGuardHome       : %s, наши записи в rewrites: %s/%s — НЕ синхронизированы: AGH отвечает клиентам мимо ip host, обход Instagram/WhatsApp работать не будет\n' \
            "$state" "$n_hit" "$n_pin"
    fi
}

# =============================================================================
# SECTION: recent logs
# =============================================================================
# Раньше здесь были два слепых хвоста: 15 строк одного лога и 10 другого. Чаще
# всего это просто последние строки штатной работы — по ним не видно ничего.
# Поэтому сначала ошибки по ВСЕМ логам, а хвосты остаются дополнением.
#
# Раздел «Логи» в вебпанели снят (2026-08-04): он показывал ПЕРВЫЙ найденный
# файл из трёх под общим заголовком «Сервисный лог», то есть у большинства —
# лог телеграм-туннеля под чужим именем, без выбора и без подписи. Остальные
# шесть логов из панели были недоступны вовсе. Теперь их читает эта сводка.
# Лимиты. `full` печатается на экран и вставляется в сообщение целиком, поэтому
# режется. `report` уходит файлом — там лимит сообщения не действует, и резать
# логи незачем: именно ради этого режим и добавлен.
if [ "$MODE" = "report" ]; then
    ERR_PER_FILE=40; TAIL_STARTUP=60; TAIL_TUNNEL=40; TAIL_OTHERS=25
else
    ERR_PER_FILE=6;  TAIL_STARTUP=5;  TAIL_TUNNEL=3;  TAIL_OTHERS=0
fi

# Список правился по ревью r-72: два пути (/tmp/nfqws2-startup.log,
# /tmp/zapret2.log) не пишет ни один компонент — они давали в отчёте строку
# «(file missing: ...)» первым же, что видит человек. А трёх, где как раз лежат
# ответы на «после обновления сломалось», в списке не было вовсе. Это важно
# именно сейчас: раздел «Логи» снят, и диагностика объявлена его заменой.
Z2K_DIAG_LOGS="/opt/var/log/z2k-auto-update.log /opt/var/log/z2k-scheduler.log
/opt/zapret2/update-lists.log /tmp/z2k-log/tg-tunnel.log
/tmp/z2k-log/z2k-warp.log /tmp/z2k-log/z2k-rt-proxy.log /tmp/z2k-log/z2k-http-tunnel.log
/tmp/z2k-log/z2k-insta-refresh.log /tmp/z2k-log/z2k-webpanel-error.log"

print_logs() {
    printf '\n=== errors across all logs ===\n'
    # В режиме full секция целиком проходит через бюджет: потолок был только
    # на файл (ERR_PER_FILE), а файлов девять — на роутере с несколькими
    # проблемами сводка вылезала за лимит одного сообщения. В режиме report
    # бюджета нет, там и место есть, и логи нужны целиком.
    if [ "$MODE" != "report" ]; then
        _print_errors_section | awk '
            { n += length($0) + 1
              if (n > 1400) { print "(обрезано — полный список кнопкой «Скачать файл»)"; exit }
              print }'
        _print_log_tails
        return 0
    fi
    _print_errors_section
    _print_log_tails
}

_print_errors_section() {
    local found=0 f
    for f in $Z2K_DIAG_LOGS; do
        [ -r "$f" ] || continue
        # -i, потому что регистр в наших логах не выдержан. Исключаем строки, где
        # слово стоит в составе штатного сообщения вроде "fail=0" или "0 errors",
        # иначе здоровый роутер выдаёт стену ложных срабатываний.
        #
        # Повторы схлопываются. Ретраи пишут по строке на попытку, отличающиеся
        # только счётчиком и таймштампом: пять таких строк говорят ровно то же,
        # что одна с пометкой «×5», а места занимают впятеро больше. Ключ для
        # сравнения — строка без цифр, поэтому «(1 in a row, backoff 3s)» и
        # «(5 in a row, backoff 30s)» считаются одним и тем же событием.
        local hits
        # '0 failed' — из штатного «[geosite] fetch summary: 5 ok, 0 failed».
        # cut -c1-200 — в scheduler.log целиком печатаются строки NFQWS2_OPT, где
        # «fails=3» матчится на «fail»; без обрезки одна такая строка съедает
        # весь бюджет секции.
        hits=$(grep -iE 'error|fail|fatal|panic|refused|denied|timeout|cannot|unable' "$f" 2>/dev/null \
               | grep -vE 'fail=0|failed=0|0 failed|0 errors|errors=0|error=0' \
               | grep -vE '^[[:space:]]*--|--lua-desync|--hostlist|--filter-' \
               | cut -c1-200 \
               | tail -40 \
               | awk '{ k=$0; gsub(/[0-9]+/, "#", k)
                        if (k in seen) { n[k]++ } else { seen[k]=1; n[k]=1; ord[++c]=k; txt[k]=$0 } }
                      END { for (i=1; i<=c; i++) { k=ord[i]
                              printf "%s%s\n", txt[k], (n[k] > 1 ? "  [×" n[k] "]" : "") } }' \
               | tail -"$ERR_PER_FILE")
        if [ -n "$hits" ]; then
            found=1
            printf -- '--- %s ---\n%s\n' "$f" "$hits"
        fi
    done
    [ "$found" = "0" ] && printf '(ошибок в логах не найдено)\n'
}

_print_log_tails() {
    # Хвосты урезаны с 15/10: раньше они были единственным содержимым секции, а
    # теперь ошибки вытащены отдельно выше, и хвост нужен лишь как контекст
    # «что происходило вокруг». Сводка обязана влезать в одно сообщение.
    printf '\n=== z2k-auto-update.log (last %s) ===\n' "$TAIL_STARTUP"
    short_tail /opt/var/log/z2k-auto-update.log "$TAIL_STARTUP"

    printf '\n=== tg-tunnel.log (last %s) ===\n' "$TAIL_TUNNEL"
    short_tail /tmp/z2k-log/tg-tunnel.log "$TAIL_TUNNEL"

    # В файловом отчёте добавляем и остальные логи целиком-ish. На экране их нет:
    # там они только раздули бы сводку, а ошибки из них уже показаны выше.
    if [ "$TAIL_OTHERS" -gt 0 ]; then
        for f in $Z2K_DIAG_LOGS; do
            case "$f" in /opt/var/log/z2k-auto-update.log|/tmp/z2k-log/tg-tunnel.log) continue ;; esac
            [ -r "$f" ] || continue
            printf '\n=== %s (last %s) ===\n' "$f" "$TAIL_OTHERS"
            short_tail "$f" "$TAIL_OTHERS"
        done
    fi
}

# =============================================================================
# SECTION: short form (versions + service only, ≤10 lines)
# =============================================================================
print_short() {
    local version entw nfqws_pids lan_ip svc
    version=$(z2k_version_read)
    entw=$(get_entware_arch)
    nfqws_pids=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    lan_ip=$(get_lan_ip)
    if [ -n "$nfqws_pids" ]; then
        svc="running (PID $(echo "$nfqws_pids" | awk '{print $1}'))"
    else
        svc="down"
    fi
    printf 'z2k=%s arch=%s lan=%s service=%s\n' \
        "$version" "$entw" "$lan_ip" "$svc"
}

# =============================================================================
# SECTION: JSON form (for webpanel /diag endpoint — Phase 3)
# =============================================================================
print_json() {
    # Intentionally minimal — webpanel will use sh-based sections in Phase 3.
    # This is a placeholder so the CLI --json flag doesn't 404 from the start.
    local version nfqws_pids svc
    version=$(z2k_version_read)
    nfqws_pids=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$nfqws_pids" ]; then
        svc="running"
    else
        svc="down"
    fi
    printf '{"version":"%s","service":"%s","lan_ip":"%s","arch":"%s"}\n' \
        "$version" "$svc" "$(get_lan_ip)" "$(get_entware_arch)"
}

# =============================================================================
# main
# =============================================================================
case "$MODE" in
    short) print_short ;;
    json)  print_json ;;
    full|report)
        print_health
        print_version_host
        print_service
        print_iptables
        print_platform
        print_netpath
        print_lists
        print_tunnel
        print_rotator
        print_logs
        printf '\n=== end of diag ===\n'
        ;;
esac
