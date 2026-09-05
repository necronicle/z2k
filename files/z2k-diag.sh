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

# Адрес роутера в домашней сети.
#
# ИСКЛЮЧАЕМ АПЛИНК, А НЕ ПРОСТО ИЩЕМ ПРИВАТНЫЙ. Раньше бралcя ПЕРВЫЙ адрес из
# 10/8, 172.16/12 или 192.168/16 — с расчётом, что WAN публичный, а приватный
# бывает только у LAN. На IPoE это неверно: провайдер выдаёт роутеру серый
# адрес, интерфейс аплинка стоит в списке раньше моста, и в отчёте появлялось
# «LAN IP: 192.168.100.10» — адрес WAN под именем LAN. Жалоба из поля.
#
# Туннели исключаем по той же причине: у z2ktun0 адрес 172.16.0.2, и без моста
# выбрали бы его.
#
# Аплинк определяем по `ip route get`, а не по `ip route show default`: на
# Keenetic аплинк — ppp0 с маршрутом в отдельной таблице, и show default
# возвращает пусто. /proc/net/route — запасной путь, он не зависит ни от PATH,
# ни от политики маршрутизации.
get_lan_ip() {
    local wan ip
    wan=$(ip route get 1.1.1.1 2>/dev/null \
          | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit }}')
    [ -n "$wan" ] || wan=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2>/dev/null)

    # Мост предпочитаем явно: на Keenetic домашнюю сеть держит br*, и когда
    # приватных адресов несколько, нужен именно он.
    ip=$(ip -4 addr show 2>/dev/null | awk -v wan="${wan:-}" '
        /^[0-9]+:/ { dev = $2; sub(/:$/, "", dev); sub(/@.*/, "", dev); next }
        /inet (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/ {
            if (dev == "lo" || dev == wan) next
            if (dev ~ /^(z2ktun|tun|tap|wg|nwg)/) next
            split($2, a, "/")
            if (dev ~ /^br/) { print a[1]; exit }
            if (first == "") first = a[1]
        }
        END { if (first != "") print first }' | head -1)

    # Ничего не нашлось — отдаём адрес источника наружу и НАЗЫВАЕМ ЕГО ТАК ЖЕ,
    # как раньше: соврать про «LAN» второй раз хуже, чем признать неизвестность.
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null \
             | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i+1); exit }}')
        [ -n "$ip" ] && ip="$ip (адрес наружу, домашней сети не нашлось)"
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
    # Пустота определяется РАЗМЕРОМ, а не числом строк. `wc -l` считает переводы
    # строки: файл с текстом, но без завершающего \n, давал ноль и печатался как
    # «(empty)» — а именно так выглядит лог демона, убитого на середине записи,
    # то есть ровно тот случай, ради которого лог и читают.
    [ -s "$file" ] || { echo "(empty)"; return; }
    local total
    total=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    # Непустой файл без единого перевода строки — это одна строка.
    [ "$total" -eq 0 ] && total=1
    if [ "$total" -gt "$lines" ]; then
        local extra=$((total - lines))
        echo "(... first ${extra} older lines skipped)"
    fi
    # В компактном режиме строки режутся по ширине: в auto-update и scheduler
    # логах попадаются очень длинные, и пара таких выносила сводку за лимит
    # одного сообщения. В файловом отчёте режима report обрезки нет.
    if [ "${MODE:-full}" = "report" ]; then
        tail -n "$lines" "$file" 2>/dev/null | z2k_mask_addrs
    else
        tail -n "$lines" "$file" 2>/dev/null | cut -c1-150
    fi
}

# Маскировка адресов — ОДНА на все секции отчёта.
#
# Отчёт отправляют в общий чат, а в логах лежат сырые пары адресов: устройства
# локальной сети, внешний адрес роутера и адрес релея. Чужих данных там нет, но
# это самораскрытие владельца, и для разбора адреса не нужны — важны коды
# ошибок и время, а не кто с кем соединялся.
#
# Раньше sed стоял ТОЛЬКО в хвостах логов, а секция «errors across all logs»
# печатала те же самые строки сырыми. В отчёте от 2026-08-22 адрес релея уехал
# в общий чат именно оттуда, хотя двадцатью строками ниже, в хвосте того же
# файла, он был замаскирован. Пока ответ на вопрос «что мы показываем» живёт в
# двух местах, он и дальше будет расходиться — поэтому место одно.
z2k_mask_addrs() {
    if [ "${MODE:-full}" = "report" ]; then
        sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g'
    else
        cat
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

# Живая командная строка движка, по одному аргументу в строке.
#
# Читаем ЕЁ, а не config: между ними стоит генератор (create_official_config →
# generate_nfqws2_opt_from_strategies), и расхождение здесь — это и есть
# искомая поломка. Конфиг может быть полон, а в движке пусто, и наоборот.
#
# PID принимаем аргументом: вызывающие его к этому моменту уже нашли, а свой
# pgrep на каждый вопрос — это и лишний обход всего /proc, и риск описать
# РАЗНЫЕ процессы в соседних строках отчёта, если движок рестартанул посреди
# дампа. Без аргумента ищем сами — для вызова из чужого места.
nfqws_cmdline() {
    local _p _src
    # Z2K_DIAG_CMDLINE_SRC — шов ТОЛЬКО для теста: сломанный случай (движок
    # работает, стратегий нет) на живом роутере не воспроизвести, не сломав его.
    # В бою переменная не задана и путь обычный.
    _src="${Z2K_DIAG_CMDLINE_SRC:-}"
    if [ -z "$_src" ]; then
        _p="${1:-}"
        [ -n "$_p" ] || _p=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | head -1)
        [ -n "$_p" ] || return 1
        _src="/proc/${_p}/cmdline"
    fi
    [ -r "$_src" ] || return 1
    tr '\0' '\n' < "$_src" 2>/dev/null
}

# Сколько ПЛЕЧ РОТАЦИИ реально доехало до движка.
#
# Считаем плечи, а не токены. Прежний счёт (`grep -c -- '--lua-desync='`) мерил
# аргументы: на здоровом роутере он давал около 255 при примерно 113 реальных
# слотах, а управляющие circular-заголовки попадали в ОБА счётчика разом.
# Пул, обрезанный до одного заголовка — то есть ротация мёртвая, перебирать
# нечего, — печатался как «1 (из них circular: 1)»: ложный зелёный ровно на
# той форме поломки, ради которой проверка и написана.
#
# Плечо — это `strategy=N` внутри профиля (профили в командной строке разделены
# --new). Токены без strategy= действуют на весь профиль сразу: если слотов нет
# вовсе, это один статический набор, то есть одно плечо и никакой ротации.
#
# Печатает "<плеч> <пулов с circular> <пулов с circular, но без плеч>";
# возвращает 1, если процесса нет или /proc недоступен. Молчание здесь честнее
# догадки: не смогли прочитать — ничего не утверждаем.
nfqws_strategy_counts() {
    local _cmd _out
    _cmd=$(nfqws_cmdline "${1:-}") || return 1
    [ -n "$_cmd" ] || return 1
    # Ключ массива — «профиль+слот»: уникальные плечи считаются одним проходом
    # в END, и не нужен `delete arr` — на busybox awk его лучше не трогать.
    _out=$(printf '%s\n' "$_cmd" | awk '
        BEGIN { prof = 0 }
        $0 == "--new" { prof++; next }
        # Плечи профиля могут приезжать НЕ своими токенами, а импортом шаблона:
        # `--lua-desync=circular:...key=rkn_tcp... --import=z2k_rkn_arsenal`.
        # Тогда в самом профиле ни одного strategy= нет, и профиль ошибочно
        # объявлялся мёртвым. Полевой случай 2026-08-23: свежая установка r-78,
        # 117 плеч в 6 пулах — все на месте, — а сводка гнала человека
        # переустанавливать z2k, который он только что поставил с форматированием.
        /^--(import|template)=/ { imp[prof] = 1; next }
        /^--lua-desync=circular:/ { circ[prof] = 1; next }
        /^--lua-desync=/ {
            desync[prof] = 1
            if (match($0, /:strategy=[0-9]+/))
                arm[prof SUBSEP substr($0, RSTART + 10, RLENGTH - 10)] = 1
            next
        }
        END {
            for (k in arm) { split(k, kp, SUBSEP); cnt[kp[1]]++ }
            for (i = 0; i <= prof; i++) {
                n = cnt[i] + 0
                if (n == 0 && desync[i]) n = 1
                arms += n
                if (circ[i]) { pools++; if (n == 0 && !imp[i]) dead++ }
            }
            printf "%d %d %d", arms, pools, dead
        }')
    [ -n "$_out" ] || return 1
    printf '%s' "$_out"
}

# Доехал ли до движка выключатель пересборки TLS ClientHello.
#
# Флаг ставит init (files/S99zapret2.new, z2k_apply_reasm_gate), но ТОЛЬКО если
# движок его знает: незнакомая опция для движка — не деградация обхода, а
# НЕЗАПУСК демона. Патч-канал бинарники не обновляет, поэтому роутер спокойно
# живёт с новым init и старым движком — и тогда большой ClientHello по-прежнему
# виснет в браузере (curl при этом работает: его ClientHello влезает в сегмент),
# хотя в описании релиза написано, что починено. Живая командная строка —
# единственное место, где видно, чем гейт кончился.
#
# Печатает "on"/"off"; возвращает 1, если командную строку не прочитать.
nfqws_reasm_state() {
    local _cmd
    _cmd=$(nfqws_cmdline "${1:-}") || return 1
    [ -n "$_cmd" ] || return 1
    # Смотрим ВНУТРЬ токена (аргументы разложены по строкам): tls_client_hello
    # встречается ещё и в --payload=, и подстрока по всей командной строке дала
    # бы «выключено» на движке, которому мы флаг не передавали. Голый
    # --reasm-disable без аргумента у движка означает «выключить пересборку
    # целиком» — TLS ClientHello в том числе, поэтому он тоже считается.
    if printf '%s\n' "$_cmd" | grep -qE '^--reasm-disable$|^--reasm-disable=([a-z_]+,)*tls_client_hello(,|$)'; then
        printf 'on'
    else
        printf 'off'
    fi
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
    # САМЫЙ СВЕЖИЙ файл, а не первый по алфавиту. Глоб отдаёт имена
    # лексикографически, и при нескольких попытках старта диагностика брала
    # старейший — то есть причину ПРОШЛОГО отказа, а не текущего. `ls -t` есть и
    # в busybox; если он почему-то не отработал, порядок остаётся прежним.
    local _err _errs
    _errs=$(ls -t /tmp/.z2k-daemon-nfqws2-*.err 2>/dev/null) || _errs=""
    [ -n "$_errs" ] || _errs=$(printf '%s\n' /tmp/.z2k-daemon-nfqws2-*.err)
    for _err in $_errs; do
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

# Сколько плеч ротации лежит в файле пула.
#
# Раньше здесь считались СТРОКИ, и это врало по построению: пул пишется одной
# строкой (save_strategy_to_category, lib/strategies.sh:33), поэтому у каждого
# пула всегда стояло «1 строк» — что при живом пуле, что при обрезанном до
# одного circular-заголовка. Считаем то же, что и в движке, чтобы строки можно
# было сверить глазами: не доехало — расхождение видно сразу.
strategy_file_arms() {
    local _tok _n
    # circular-заголовок отбрасываем: он управляет перебором, но сам плечом не
    # является. Оставь его в выборке — и пул, обрезанный до одного заголовка,
    # снова печатался бы как непустой.
    _tok=$(tr ' ' '\n' < "$1" 2>/dev/null | grep -- '^--lua-desync=' \
           | grep -v '^--lua-desync=circular')
    _n=$(printf '%s\n' "$_tok" | sed -n 's/.*:strategy=\([0-9][0-9]*\).*/\1/p' \
         | sort -u | wc -l | tr -d ' ')
    case "${_n:-}" in ''|*[!0-9]*) _n=0 ;; esac
    # Ноль слотов, но техники есть — это один статический набор без ротации,
    # то есть одно плечо, а не пустой пул.
    [ "$_n" = "0" ] && [ -n "$_tok" ] && _n=1
    printf '%s' "$_n"
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
        # Стратегии в ЖИВОМ процессе.
        #
        # Раньше про них здесь не было ни слова: единственный разбор
        # конфигурации сидел в print_nfqws_start_failure, а та вызывается
        # ТОЛЬКО когда демон лежит. То есть в самом частом обращении в
        # поддержку — «z2k работает, а сайты блокируются» — сводка про
        # стратегии молчала, и разговор начинался с просьбы выполнить команду
        # руками. Чтение /proc бесплатно, --dry-run здесь по-прежнему не
        # запускается (он грузит списки, см. комментарий выше).
        local _sc _rest _arms _pools _dead
        if _sc=$(nfqws_strategy_counts "$pid_first"); then
            _arms=${_sc%% *}
            _rest=${_sc#* }
            _pools=${_rest%% *}
            _dead=${_rest##* }
            printf 'плеч ротации      : %s в %s пулах\n' "$_arms" "$_pools"
            # Пул с circular и без единого плеча — это не «мало стратегий», это
            # мёртвая ротация в этом пуле: перебирать нечего.
            [ "${_dead:-0}" = "0" ] || \
                printf 'пулы без плеч     : %s — circular есть, перебирать нечего\n' "$_dead"
        else
            printf 'плеч ротации      : (не прочитать /proc)\n'
        fi
        # Чем кончился гейт --reasm-disable в init: на патч-канале движок может
        # остаться старым, и тогда сайты с большим ClientHello виснут молча.
        local _rs
        if _rs=$(nfqws_reasm_state "$pid_first"); then
            if [ "$_rs" = "on" ]; then
                printf 'reasm TLS CH      : пересборка выключена (ок)\n'
            else
                printf 'reasm TLS CH      : ВКЛЮЧЕНА — движок без --reasm-disable, большой ClientHello виснет\n'
            fi
        fi
        # Источник этих стратегий — по одному файлу на пул. Пустой или
        # пропавший файл здесь и есть причина пустого движка.
        local _pool _sf _sn _note
        for _pool in TCP/RKN TCP/YT TCP/YT_GV UDP/YT; do
            _sf="${ZAPRET2_DIR}/extra_strats/${_pool}/Strategy.txt"
            if [ -s "$_sf" ]; then
                _sn=$(strategy_file_arms "$_sf")
                _note=""
                grep -q -- '--lua-desync=circular' "$_sf" 2>/dev/null || \
                    _note=", БЕЗ circular — пул не ротируется"
                [ "$_sn" = "0" ] && _note="${_note}, перебирать нечего"
                printf 'strategy %-9s: плеч %s%s\n' "$_pool" "$_sn" "$_note"
            elif [ -e "$_sf" ]; then
                printf 'strategy %-9s: ПУСТ\n' "$_pool"
            else
                printf 'strategy %-9s: НЕТ ФАЙЛА\n' "$_pool"
            fi
        done
    else
        printf 'nfqws2 PIDs       : (not running)\n'
        print_nfqws_start_failure
    fi

    local cfg="${ZAPRET2_DIR}/config"
    if [ -r "$cfg" ]; then
        printf 'config flags      : '
        local flags=""
        for k in GAME_WARP_ENABLED GEOSITE_ENABLED; do
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
    local _nfq_all
    _nfq_all=$(nfqueue_counts)
    nfq_mangle=$(printf '%s' "$_nfq_all" | cut -d' ' -f1)
    nfq_in=$(printf '%s' "$_nfq_all" | cut -d' ' -f2)
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
    # Ожидание зависит от того, включён ли туннель. Выключив телеграм руками,
    # человек штатно остаётся без этих правил — и читал про себя «expected 1»,
    # то есть отчёт о неисправности там, где всё как он и просил.
    if tg_user_disabled; then
        _tg_exp='туннель выключен вручную — правил и не должно быть'
    else
        _tg_exp='expected 1 — ipset match-set, r-50+'
    fi
    printf 'TG REDIR PREROUT  : %s  (%s)\n' "$tg_redirect_pre" "$_tg_exp"
    printf 'TG REDIR OUTPUT   : %s  (%s)\n' "$tg_redirect_out" "$_tg_exp"
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
        tg_pid=$(tg_tunnel_pid)
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
# SECTION: warp
# =============================================================================
# Код last_error движка → смысл (те же четыре, что переводит панель).
warp_status_reason() {
    local code
    code=$(sed -n 's/.*"last_error":"\([^"]*\)".*/\1/p' /tmp/z2k-warp/status.json 2>/dev/null)
    case "$code" in
        register_blocked) echo "регистрация у Cloudflare заблокирована — ни напрямую, ни через релей" ;;
        device_revoked)   echo "Cloudflare отозвал устройство, идёт перерегистрация" ;;
        no_endpoint)      echo "ни один адрес Cloudflare не отвечает — провайдер блокирует WARP целиком" ;;
        tun_failed)       echo "прошивка не даёт создать туннельный интерфейс" ;;
        no_transit)       echo "сессия встаёт, но сквозная проба не проходит — туннель не возит" ;;
        "")               echo "поднимается" ;;
        *)                echo "$code" ;;
    esac
}

# Блокировка по объёму соединения: что проба намерила и доехало ли это до
# конфига.
#
# Раздел появился после r-81.1, где расхождение между «намерили» и «применяем»
# стоило выпуска: у людей проба отработала и карту имён записала, а инстансы в
# конфиг не попали — версия сменилась, обход молчал. Снаружи это выглядело как
# «обновилось и не работает», и по логам различить было нечем.
#
# Поэтому здесь печатается И то, и другое: ответ пробы и факт по конфигу.
# Расхождение — само по себе диагноз.
print_tcp16() {
    printf '\n=== блок по объёму (16-20КБ) ===\n'
    local flag="${ZAPRET2_DIR}/state/tcp16.flag"
    local asn="${ZAPRET2_DIR}/state/tcp16_asn.txt"
    local map="${ZAPRET2_DIR}/state/tcp16_sni.txt"
    local nets="${ZAPRET2_DIR}/lists/tcp16_nets.txt"
    local cand="${ZAPRET2_DIR}/lists/sni_wl_candidates.txt"

    local f; f=$(cat "$flag" 2>/dev/null)
    case "$f" in
        1) printf 'проба линии       : блок ЕСТЬ\n' ;;
        0) printf 'проба линии       : блока нет — механизм не нужен\n' ;;
        *) printf 'проба линии       : не измерялась (механизм выключен)\n' ;;
    esac
    # Метку времени печатаем только вместе с ответом: одна без другого
    # означает, что проба сейчас идёт, и «измерено 13 ч назад» рядом с «не
    # измерялась» читателя только запутает.
    if [ -s "$flag.ts" ] && [ -s "$flag" ]; then
        local ts age
        ts=$(cat "$flag.ts" 2>/dev/null)
        age=$(( $(date +%s) - ts ))
        if [ "$age" -lt 3600 ] 2>/dev/null; then
            printf 'измерено          : %s мин назад\n' "$((age / 60))"
        else
            printf 'измерено          : %s ч назад\n' "$((age / 3600))"
        fi
    fi

    # Считаем через awk, а НЕ `grep -vc ... || echo 0`: на пустом файле grep
    # печатает ноль И возвращает единицу, запасная ветка дописывает второй, и
    # в отчёт уезжает «0\n0». Та же ловушка уже была в подборе имени.
    _cnt() { awk '!/^#/ && NF {n++} END {print n + 0}' "$1" 2>/dev/null || echo 0; }
    printf 'сетей с блоком    : %s\n' "$(_cnt "$asn")"
    printf 'имён подобрано    : %s из %s кандидатов\n' "$(_cnt "$map")" "$(_cnt "$cand")"
    # Отличаем «файла нет» от «файл пуст»: у пользователя это разные болезни —
    # не доставлено против нечего показать.
    if [ -f "$nets" ]; then
        printf 'карта сетей       : %s записей\n' "$(_cnt "$nets")"
    else
        printf 'карта сетей       : ФАЙЛА НЕТ (%s) — обновление не доставило\n' "$nets"
    fi
    [ -f "$cand" ] || printf 'список имён       : ФАЙЛА НЕТ (%s) — обновление не доставило\n' "$cand"

    # Главное: доехало ли намеренное до конфига.
    local in_cfg=0
    grep -q -- '--lua-desync=z2k_sni_pick' "${ZAPRET2_DIR}/config" 2>/dev/null && in_cfg=1
    printf 'в конфиге         : %s\n' "$([ "$in_cfg" = 1 ] && echo 'да' || echo 'НЕТ')"
    # Примеры печатаем ВСЕГДА, когда карта есть, — в том числе при расхождении.
    # Первая редакция показывала их только когда всё сошлось, то есть скрывала
    # находки ровно в тот момент, когда они нужнее всего для разбора.
    if [ "$f" = "1" ] && [ -s "$map" ]; then
        printf 'примеры           : %s\n' \
            "$(grep -v '^#' "$map" 2>/dev/null | head -3 | awk '{printf "AS%s->%s ", $1, $2}')"
    fi
    if [ "$f" = "1" ] && [ "$in_cfg" = "0" ]; then
        printf 'вердикт           : РАСХОЖДЕНИЕ — блок найден, а механизма в конфиге нет.\n'
        printf '                    Конфиг собран раньше пробы и не пересобран. Лечится\n'
        printf '                    запуском %s/z2k-tcp16-probe.sh\n' "$ZAPRET2_DIR"
    elif [ "$f" = "1" ] && [ ! -s "$map" ]; then
        printf 'вердикт           : блок есть, но ни одного имени не подобрано —\n'
        printf '                    на этой линии не подходит ни один кандидат\n'
    fi
}

print_warp() {
    printf '\n=== warp ===\n'
    local on bin=/opt/sbin/z2k-warpd st=/tmp/z2k-warp/status.json dev=/opt/etc/z2k-warp/device.json
    on=$(grep -m1 '^GAME_WARP_ENABLED=' "${ZAPRET2_DIR}/config" 2>/dev/null | cut -d= -f2 | tr -d '" ')
    printf 'mode              : %s\n' "$([ "$on" = "1" ] && echo on || echo off)"
    if [ -x "$bin" ]; then
        # СБОРКУ ОПОЗНАЁМ ПО СУММЕ, А НЕ ПО САМОНАЗВАНИЮ.
        #
        # `z2k-warpd version` отвечает "dev" у всех: в Makefile движка версия не
        # вшивается, в отличие от клиента туннеля. Вшить её флагом нельзя —
        # побайтовая сверка бинарников (и здесь, и в ci.yml) пересобирает с
        # фиксированным -ldflags="-s -w", и любой лишний -X сделает отгруженный
        # файл невоспроизводимым, то есть уронит CI.
        #
        # Сумма решает ту же задачу и лучше: её не надо помнить проставить, она
        # не может разойтись с содержимым, и по ней сборка опознаётся задним
        # числом — даже у роутеров, которые обновлялись год назад. Ровно этой
        # приметы не хватало, когда три архитектуры месяцами не получали новых
        # бинарников: диагностика показывала «dev» и выглядела нормально.
        printf 'engine            : %s (%s bytes, md5 %s, self "%s")\n' \
            "$bin" \
            "$(wc -c < "$bin" 2>/dev/null | tr -d ' ')" \
            "$(md5sum "$bin" 2>/dev/null | awk '{print $1}')" \
            "$("$bin" version 2>/dev/null || echo '?')"
    else
        printf 'engine            : not installed\n'
    fi
    if [ -s "$dev" ]; then
        # Ключ не печатаем; id, эндпоинт и тип активного ключа — достаточно для триажа.
        # client_id печатаем намеренно: он не секрет — эти три байта уезжают в
        # заголовке КАЖДОГО WG-пакета. Зато без них Cloudflare маршрутизирует
        # сессию мимо consumer-WARP, и симптом ровно тот, что мы ловим: handshake
        # проходит, TCP не идёт.
        printf 'device            : id=%s tunnel=%s endpoint=%s ports=%s iface=%s client_id=%s\n' \
            "$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' "$dev" | head -1)" \
            "$(sed -n 's/.*"tunnel": *"\([^"]*\)".*/\1/p' "$dev" | head -1)" \
            "$(sed -n 's/.*"v4": *"\([^"]*\)".*/\1/p' "$dev" | head -1)" \
            "$(tr -d ' \n' < "$dev" | sed -n 's/^[^[]*"ports":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | grep -c .)" \
            "$(sed -n 's/.*"iface": *"\([^"]*\)".*/\1/p' "$dev" | head -1)" \
            "$(sed -n 's/.*"client_id": *"\([^"]*\)".*/\1/p' "$dev" | head -1)"
    else
        printf 'device            : not registered\n'
    fi
    if [ -f "$st" ]; then
        printf 'status            : %s\n' "$(cat "$st")"
        printf 'memory            : %s kB RSS (движок; растёт с трафиком, не со списком)\n' \
            "$(sed -n 's/.*"mem_kb": *\([0-9]*\).*/\1/p' "$st" | head -1)"
        printf 'verdict           : %s\n' "$(grep -q '"ready":true' "$st" && echo 'ready' || echo "not ready — $(warp_status_reason)")"
    else
        printf 'status            : no status.json (daemon not running)\n'
    fi
    local ifc
    ifc=$(sed -n 's/.*"iface": *"\([^"]*\)".*/\1/p' "$dev" 2>/dev/null | head -1)
    if [ -n "$ifc" ]; then
        printf 'netdev            : %s\n' "$(ip -o link show "$ifc" 2>/dev/null | sed 's/\\.*//' | cut -c1-80 || echo absent)"
        printf 'routing           : rule=%s route=%s mark=%s nat=%s fwd=%s\n' \
            "$(ip rule show 2>/dev/null | grep -c 'fwmark 0x989')" \
            "$(ip route show table 989 2>/dev/null | grep -c "$ifc")" \
            "$(iptables -w -t mangle -S PREROUTING 2>/dev/null | grep -c 'z2k_warp')" \
            "$(iptables -w -t nat -S POSTROUTING 2>/dev/null | grep -c "$ifc")" \
            "$(iptables -w -t filter -S FORWARD 2>/dev/null | grep -c "$ifc")"
    fi
    printf 'ipset             : z2k_warp=%s z2k_warp_src=%s\n' \
        "$(ipset list z2k_warp 2>/dev/null | awk '/^Members:/{m=1;next} m&&NF{n++} END{print n+0}')" \
        "$(ipset list z2k_warp_src 2>/dev/null | awk '/^Members:/{m=1;next} m&&NF{n++} END{print n+0}')"
    if [ -f /tmp/z2k-warp/warpd.log ]; then
        printf 'warpd.log (last 15):\n'
        tail -15 /tmp/z2k-warp/warpd.log 2>/dev/null | sed 's/^/  /'
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

# Проба bitmap:port: create+destroy реального набора. Её дёргают и шапка, и
# секция platform.
#
# КЭШ В ФАЙЛЕ, А НЕ В ПЕРЕМЕННОЙ. Обоих потребителей зовут через $( ), то есть в
# ПОДОБОЛОЧКЕ: присваивание Z2K_BITMAP_OK там и умирало, родитель оставался
# пустым, и проба выполнялась заново каждый раз. Переменная-кэш, которую
# невозможно записать, — это не кэш, а комментарий о намерениях.
#
# ИМЯ НАБОРА УНИКАЛЬНО НА ПРОГОН. Оно было фиксированным, а панель разрешает
# автозагрузку, «Обновить» и «Скачать файл» одновременно. Два отчёта внахлёст
# дрались за один набор: чужой destroy сносил наш до create, create падал
# «set exists» — и отчёт открывался строкой «обход не работает ЦЕЛИКОМ» на
# полностью здоровом ядре. Хуже ложной тревоги только ложная тревога,
# приходящая через раз.
Z2K_BITMAP_CACHE="${TMPDIR:-/tmp}/.z2k-diag-bitmap.$$"
# Единственный trap в файле. Кэш живёт в tmpfs и переживёт разве что аварийный
# kill -9, но оставлять мусор в /tmp роутера незачем: отчёт дёргают и панель, и
# бот, и планировщик.
trap 'rm -f "$Z2K_BITMAP_CACHE" 2>/dev/null' EXIT INT TERM
bitmap_port_ok() {
    if [ -s "$Z2K_BITMAP_CACHE" ]; then
        cat "$Z2K_BITMAP_CACHE"
        return 0
    fi
    local _verdict _set
    _set="z2k_diag_probe_$$"
    if ! command -v ipset >/dev/null 2>&1; then
        _verdict="unknown"
    # Свой набор всё равно сносим перед create: прошлый прогон с ТЕМ ЖЕ pid мог
    # оборваться между create и destroy. Та же конвенция принята в lib/utils.sh
    # и files/S99zapret2.new.
    elif { ipset destroy "$_set" 2>/dev/null || true
           ipset create "$_set" bitmap:port range 0-65535 2>/dev/null; }; then
        ipset destroy "$_set" 2>/dev/null
        _verdict="yes"
    else
        _verdict="no"
    fi
    printf '%s' "$_verdict" > "$Z2K_BITMAP_CACHE" 2>/dev/null
    printf '%s' "$_verdict"
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
# PID ИМЕННО ТЕЛЕГРАМ-ТУННЕЛЯ, а не любого экземпляра бинарника.
#
# Тот же бинарник поднимается ДВАЖДЫ: телеграм слушает :1443, а cdnbase-туннель
# (S97z2k-http-tunnel) — :1444. Голый `pgrep -f tg-mtproxy-client` ловит оба,
# поэтому живой http-туннель маскировал смерть телеграмного: процесс есть,
# сводка молчит, у человека телеграм не работает. В webpanel/cgi/actions.sh:1775
# этот полевой баг уже закрыт фильтром по порту — диагностика от него отстала.
tg_tunnel_pid() {
    pgrep -f "tg-mtproxy-client .*--listen=:1443" 2>/dev/null | head -1
}

# Выключен ли туннель самим человеком. Намеренно выключенное — не поломка, и
# кричать о нём в сводке значит приучать читать её по диагонали.
tg_user_disabled() {
    # Читаем так же, как соседние флаги в этом файле (строка про
    # GAME_WARP_ENABLED): отдельного помощника здесь нет, и заводить его ради
    # одного значения — лишняя сущность.
    [ "$(grep -m1 '^TG_PROXY_USER_DISABLED=' "${ZAPRET2_DIR}/config" 2>/dev/null \
         | cut -d= -f2 | tr -d '"'"'"'" ')" = "1" ]
}

# nfqueue_counts -> "<исходящих> <входящих> <читалось_ли>"
#
# ОДИН источник чисел для деталей и для вердикта. Раньше каждый считал сам, и
# это ровно тот класс, из-за которого сводка сегодня разошлась с деталями по
# телеграму: одно место говорило «правил нет», другое — «есть».
#
# Три вещи, которых не было:
#   1. -w. Без него занятый xtables-lock (NDM правит правила постоянно) роняет
#      iptables с пустым выводом, и «нет правил» печатается на исправном роутере.
#   2. Отличие ОШИБКИ ЧТЕНИЯ от НУЛЯ. Раньше `2>/dev/null || true` превращал
#      любой сбой в ноль, то есть в тревогу. Не смогли прочитать — молчим:
#      молчание честнее выдумки.
#   3. Фильтр по НОМЕРУ очереди. Считался любой NFQUEUE, включая чужие правила.
#      Если фильтр по номеру дал ноль, а без фильтра правила есть — значит формат
#      вывода iptables другой; тогда берём общий счёт, чтобы не выдумать поломку.
nfqueue_counts() {
    local _q _out _in _raw_out _raw_in _ok=1
    _q="${QNUM:-200}"
    case "$_q" in ''|*[!0-9]*) _q=200 ;; esac

    # Каждое чтение — отдельным присваиванием в РОДИТЕЛЕ. Собрать обе цепочки
    # одним $( { ...; } ) нельзя: `_ok=0` внутри подстановки останется в
    # подоболочке и наружу не выйдет — ровно тот дефект, из-за которого рядом
    # не работал кэш пробы bitmap.
    local _in_a _in_b
    _raw_out=$(iptables -w -t mangle -L POSTROUTING -n 2>/dev/null) || _ok=0
    _in_a=$(iptables -w -t mangle -L INPUT -n 2>/dev/null) || _ok=0
    _in_b=$(iptables -w -t mangle -L FORWARD -n 2>/dev/null) || _ok=0
    _raw_in="$_in_a
$_in_b"

    _out=$(printf '%s\n' "$_raw_out" | grep -c "NFQUEUE num $_q" || true)
    _in=$(printf '%s\n' "$_raw_in"  | grep -c "NFQUEUE num $_q" || true)
    if [ "${_out:-0}" -eq 0 ] && [ "${_in:-0}" -eq 0 ]; then
        _out=$(printf '%s\n' "$_raw_out" | grep -c NFQUEUE || true)
        _in=$(printf '%s\n' "$_raw_in"  | grep -c NFQUEUE || true)
    fi
    printf '%s %s %s\n' "${_out:-0}" "${_in:-0}" "$_ok"
}

tg_redirect_counts() {
    local _pre _out
    # -w ОБЯЗАТЕЛЕН. Без него занятый xtables-lock (NDM правит правила постоянно)
    # роняет iptables с пустым выводом, grep -c даёт 0 — и сводка объявляет
    # правила пропавшими на исправном роутере. Полевой случай 2026-08-23: в
    # сводке «редирект телеграма отсутствует, PREROUTING=0», а пятью строками
    # ниже в том же файле «TG REDIR PREROUT: 1» и CONNECT_OK в логе туннеля.
    _pre=$( (iptables -w -t nat -L PREROUTING -n 2>/dev/null || true) | grep -c 'redir ports 1443' || true)
    _out=$( (iptables -w -t nat -L OUTPUT -n 2>/dev/null || true) | grep -c 'redir ports 1443' || true)
    printf '%s %s\n' "${_pre:-0}" "${_out:-0}"
}

clock_skew_vs_relay() {
    local srv_date srv_epoch now_epoch
    # --resolve: адрес уже записан в имени (nip.io), незачем зависеть от
    # резолвера — на роутере с мёртвым DNS диагностика обязана работать именно
    # тогда, когда она нужнее всего. TLS-имя не меняется.
    srv_date=$(curl -s -m 8 --resolve "${VPS_IP}.nip.io:443:${VPS_IP}" \
               -D - -o /dev/null "https://${VPS_IP}.nip.io/" 2>/dev/null \
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

    # Обновление прошло, но какой-то его шаг работу не сделал.
    #
    # ЗАЧЕМ ЭТО ЗДЕСЬ. Строка «cleanup-ip-hosts: функция недоступна, пропускаю»
    # лежала в журнале обновления с апреля и всплыла случайно — человек прислал
    # диагностику по другому поводу. Журнал печатается ниже, но целиком его никто
    # не читает; читают этот блок. Шаг, который не сделал работу, обязан быть
    # здесь, иначе тихий пропуск живёт месяцами.
    #
    # Смотрим только ПОСЛЕДНИЙ прогон: строки старых обновлений уже неактуальны,
    # а сводка обязана говорить про сейчас.
    local _aul="/opt/var/log/z2k-auto-update.log"
    if [ -r "$_aul" ]; then
        local _from _skips _s
        _from=$(awk '/обновление .* -> |no update needed/ {n=NR} END {print n+0}' "$_aul" 2>/dev/null)
        if [ "${_from:-0}" -gt 0 ] 2>/dev/null; then
            _skips=$(tail -n "+$_from" "$_aul" 2>/dev/null \
                | grep -E "пропускаю|недоступн|не удалось|отложен" \
                | sed 's/^\[[^]]*\][[:space:]]*//' | sort -u)
            # Через переменную, а не конвейером: _add меняет $issues, а в
            # подоболочке конвейера изменение пропало бы — и сводка снова
            # молчала бы ровно про то, ради чего эта проверка написана.
            if [ -n "$_skips" ]; then
                set -f
                IFS='
'
                for _s in $_skips; do
                    [ -n "$_s" ] && _add "обновление: $_s"
                done
                unset IFS
                set +f
            fi
        fi
    fi

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

    # PID движка ищем ОДИН раз на всю сводку: ниже он нужен четырежды, а pgrep —
    # это обход всего /proc. И, что важнее, все строки отчёта будут про ОДИН
    # процесс, а не про разные, если движок рестартанул посреди дампа.
    local _nfq_pid
    _nfq_pid=$(pgrep -f 'nfq2/nfqws2' 2>/dev/null | head -1)

    # «Не запущен» без причины — это половина ответа, за которой всегда следует
    # круг переписки. Причина уже собрана секцией service, здесь на неё ссылаемся.
    [ -n "$_nfq_pid" ] || \
        _add "nfqws2 не запущен — обход не работает (причина в разделе service, строка «причина отказа»)"

    # Половина правил на месте, половины нет. Снаружи это выглядит не как поломка,
    # а как «стратегия залипла»: десинк работает, а переключать её не на чем —
    # признаки неудачи приходят входящими пакетами, которых движок не видит.
    if [ -n "$_nfq_pid" ]; then
        local _nfq_c _nfq_out _nfq_in _nfq_ok
        _nfq_c=$(nfqueue_counts)
        _nfq_out=$(printf '%s' "$_nfq_c" | cut -d' ' -f1)
        _nfq_in=$(printf '%s' "$_nfq_c" | cut -d' ' -f2)
        _nfq_ok=$(printf '%s' "$_nfq_c" | cut -d' ' -f3)
        # Читать не смогли — не судим вовсе. Иначе занятый xtables-lock печатает
        # человеку «обход не работает» на исправном роутере.
        if [ "$_nfq_ok" = "1" ]; then
            # ИСХОДЯЩИЕ. Вердикт про них не спрашивал вообще: демон живой,
            # правил в POSTROUTING нет — и сводка молчала, хотя десинк не
            # применяется ни к одному пакету.
            [ "${_nfq_out:-0}" -eq 0 ] && \
                _add "правила для исходящих пакетов отсутствуют — движок запущен, но десинк не применяется ни к чему"
            [ "${_nfq_in:-0}" -eq 0 ] && \
                _add "правила для входящих пакетов отсутствуют — обход работает, но стратегии перестанут переключаться сами"
            # ПОЛОВИНА правил. Тревожил только точный ноль, поэтому «1 из 4»
            # проходило молча — а это, например, пропавший FORWARD целиком, то
            # есть ротация не работает для клиентов сети, только для роутера.
            [ "${_nfq_in:-0}" -gt 0 ] && [ "${_nfq_in:-0}" -lt 4 ] && \
                _add "правил для входящих пакетов меньше, чем нужно (${_nfq_in} из 4) — ротация работает не для всех клиентов сети"
            [ "${_nfq_out:-0}" -gt 0 ] && [ "${_nfq_out:-0}" -lt 2 ] && \
                _add "правил для исходящих пакетов меньше, чем нужно (${_nfq_out} из 2) — часть трафика идёт мимо обхода"
        fi
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

    # Стратегии доехали до движка?
    #
    # Демон работает, правила стоят, счётчики растут — и при этом в командной
    # строке ни одного плеча. Снаружи это выглядит как «z2k включён, а всё
    # блокируется», и по логам самого z2k не видно ничего.
    #
    # Проверка именно здесь, а не только в service: сводка «что не так» —
    # единственное, что человек читает целиком.
    #
    # Считаем ПО ПУЛАМ. Прежнее условие «в движке ноль circular» не могло
    # сработать никогда: lib/config_official.sh:254 безусловно добавляет
    # discord_udp с зашитым circular, поэтому при непустой командной строке
    # circular всегда хотя бы один, а пустая ловится первой веткой. Состояние
    # «ротация потеряна» не рапортовалось вовсе. Пул, приехавший одним
    # circular-заголовком без единого плеча, — это ровно оно, и оно бывает.
    if [ -n "$_nfq_pid" ]; then
        local _scv _srest _sarms _spools _sdead
        if _scv=$(nfqws_strategy_counts "$_nfq_pid"); then
            _sarms=${_scv%% *}
            _srest=${_scv#* }
            _spools=${_srest%% *}
            _sdead=${_srest##* }
            if [ "${_sarms:-0}" = "0" ]; then
                _add "движок работает, но НИ ОДНОГО плеча десинка в нём нет — обход не применяется ни к чему; проверьте extra_strats/*/Strategy.txt и переустановите z2k"
            elif [ "${_sdead:-0}" != "0" ]; then
                _add "пулов с мёртвой ротацией: ${_sdead} — в движок приехал circular без единого плеча, перебирать нечего; проверьте extra_strats/*/Strategy.txt и переустановите z2k"
            elif [ "${_spools:-0}" = "0" ]; then
                _add "в движке нет ни одного circular — автоподбор рабочей настройки выключен, при блокировке страта не сменится"
            fi
        fi

        # Гейт --reasm-disable в init мог отказать: движок старее init'а.
        # Патч-канал бинарники не обновляет, а описание релиза при этом обещает,
        # что «сайты с большим ClientHello перестали виснуть». Симптом ровно
        # такой: curl открывает, браузер молчит — и до этой строки его причину
        # не было видно нигде.
        local _rsv
        if _rsv=$(nfqws_reasm_state "$_nfq_pid"); then
            if [ "$_rsv" != "on" ]; then
                _add "движок не выключает пересборку TLS ClientHello — сайты с большим ClientHello (reg.ru и подобные) виснут в браузере, хотя curl их открывает; нужно полное обновление z2k, патч бинарник не меняет"
            fi
        fi
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
    # ВЫКЛЮЧЕННЫЙ РУКАМИ ТУННЕЛЬ — НЕ ПОЛОМКА, И МОЛЧАТЬ ПРО НЕГО ОБЯЗАНЫ ВСЕ
    # ПРОВЕРКИ РАЗОМ. Раньше защита стояла только на «процесса нет», а проверка
    # правил редиректа висела ниже, вне этой ветки. Человек выключал телеграм
    # сам, правила при этом снимаются штатно — и диагностика писала ему
    # «правила редиректа телеграма отсутствуют, телеграм не подключится», то
    # есть выдавала его же осознанное действие за неисправность.
    if [ -x /opt/sbin/tg-mtproxy-client ] && ! tg_user_disabled; then
        if [ -z "$(tg_tunnel_pid)" ]; then
            _add "телеграм-туннель установлен, но не запущен — телеграм работать не будет"
        else
            # Процесс живой и правила стоят, а список подсетей дата-центров пуст:
            # правило ссылается на ipset, в котором нечему совпасть, и трафик
            # идёт мимо туннеля. В деталях это видно строкой «TG ipset
            # z2k_tg_dc: 0», в вердикте не было ничего.
            local _tgset
            _tgset=$( (ipset list z2k_tg_dc 2>/dev/null || true) | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
            [ "${_tgset:-0}" -eq 0 ] && \
                _add "список подсетей телеграма пуст — правила редиректа ссылаются на пустой ipset, трафик идёт мимо туннеля"
        fi

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
        # ЯКОРЬ — СТРОКА, КОТОРУЮ ПИШЕТ ЛЮБОЙ ОТКАТ.
        #
        # Здесь искалось «rolling back», а эту фразу пишет ТОЛЬКО патч-путь
        # (au_apply_patch). Все обновляются сходимостью с r-79.7, и она пишет
        # по-русски: «доставка не удалась — откат», «шаги провалились — откат».
        # То есть с момента перехода на сходимость откат стал НЕВИДИМ для
        # диагностики. Поле 2026-08-27: роутер два раза подряд ночью откатился
        # с p-79.12, стоял на ней двое суток, а сводка отвечала «явных проблем
        # не найдено».
        #
        # Якорим на «rollback: restoring pre-apply files» — её пишет
        # au_rollback_patch, общий для всех путей отката; «rolling back»
        # оставлено для роутеров со старым апдейтером.
        #
        # Смотрим только хвост: старый откат, после которого всё наладилось,
        # тревожить не должен.
        # ОТКАТ АКТУАЛЕН, ТОЛЬКО ЕСЛИ ПОСЛЕ НЕГО НЕ БЫЛО УДАЧНОГО ЗАВЕРШЕНИЯ.
        #
        # Хвоста мало: в него попадает и ночной откат, и дневное успешное
        # обновление следом. Поле 2026-08-28: откат в 02:10 (jsdelivr отдал
        # протухший warp.js), успешное p-80.4 в 12:47 — а сводка всё равно
        # писала «версия не изменится, пока причина не устранена». Намерение
        # «старый откат, после которого всё наладилось, не тревожит» стояло в
        # комментарии выше, но в коде его не было: grep не знает порядка строк.
        if tail -40 "$_aulog" 2>/dev/null | awk '
            BEGIN { rb = 0; ok = 0 }
            /rollback: restoring pre-apply files|rolling back/ { rb = NR }
            /обновление завершено:|update OK:/                 { ok = NR }
            END { exit !(rb > 0 && rb > ok) }
        '; then
            # Причина — последняя КОНКРЕТНАЯ строка отказа. «шаги провалились —
            # откат» сюда не входит намеренно: это не причина, а пересказ факта
            # отката, и стоя последней она вытесняла бы настоящую («вето
            # валидатора», «не скачался такой-то файл»).
            _why=$(tail -40 "$_aulog" 2>/dev/null \
                | grep -oE "сходимость: [^\"]*|validate-config: [^\"]*|проверка не пройдена: [^\"]*|health-check FAILED: [^\"]*|снимок не снялся[^\"]*" \
                | tail -1)
            _add "последнее обновление откатилось${_why:+ (${_why})} — версия не изменится, пока причина не устранена"
        fi
    fi

    # WARP включён, но туннель не несёт трафик. Источник правды — status.json
    # движка z2k-warpd (ready + код причины); игровые адреса при этом идут
    # напрямую (fail open), то есть обход для них не работает.
    local _warp_on
    _warp_on=$(grep -m1 '^GAME_WARP_ENABLED=' "${ZAPRET2_DIR}/config" 2>/dev/null | cut -d= -f2 | tr -d '" ')
    if [ "$_warp_on" = "1" ]; then
        if [ ! -x /opt/sbin/z2k-warpd ]; then
            _add "WARP включён, но движок не установлен — нажмите «Установить WARP» в панели"
        elif [ ! -s /opt/etc/z2k-warp/device.json ]; then
            # Отдельная ветка, а не «движок не запущен»: без ключа устройства
            # движок падает на старте всегда, и обещать, что selfheal поднимет
            # его «в течение минуты», было прямой неправдой — он и поднимал,
            # каждые 25 с, сутки подряд. Причина одна и лечится регистрацией.
            _add "WARP включён, но устройство не зарегистрировано у Cloudflare — движок падает на старте; selfheal повторяет регистрацию раз в 10 минут, ускорить можно кнопкой «Установить WARP» в панели"
        elif [ ! -f /tmp/z2k-warp/status.json ]; then
            _add "WARP включён, но движок не запущен (нет status.json) — selfheal поднимет его в течение минуты"
        elif ! grep -q '"ready":true' /tmp/z2k-warp/status.json 2>/dev/null; then
            _add "WARP включён, но туннель не несёт трафик ($(warp_status_reason)) — игровой трафик идёт напрямую"
            # Карусель перезапусков. Симптом «поднимается» выглядит одинаково и
            # когда движок терпеливо идёт по лестнице, и когда его каждые
            # пятнадцать секунд перезапускают снаружи (поле 2026-08-27 —
            # подбор плеча десинка рвал лестницу пятьдесят раз подряд). Разница
            # видна только по числу «starting» в хвосте лога.
            if [ "$(tail -40 /tmp/z2k-warp/warpd.log 2>/dev/null | grep -c 'starting')" -ge 3 ]; then
                _add "движок WARP перезапускается по кругу — лестница адресов не успевает пройти ни разу (/tmp/z2k-warp/warpd.log)"
            fi
        else
            # Туннель поднят — а заворачивать в него нечего. Без этой строки
            # диагностика молчит: «проблем не найдено» при полностью
            # бесполезном WARP.
            _warp_n=$(ipset list z2k_warp 2>/dev/null | awk '/^Members:/{m=1;next} m&&NF{n++} END{print n+0}')
            if [ "${_warp_n:-0}" = "0" ]; then
                _add "WARP поднят, но ни один список адресов не выбран — в туннель не заворачивается ничего (панель → WARP → списки игр)"
            fi
        fi
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

    # ПОРТ ВЕБМОРДЫ РОУТЕРА. Панель проверяет пароль не сама — она спрашивает
    # веб-интерфейс роутера, и если тот перенесён на другой порт (`ip http port`)
    # или вовсе лежит, вход не работает, а выглядит это как «неверный пароль».
    # Поле 01.09.2026: разбирали такую жалобу вслепую, потому что диагностика
    # про порт молчала, и пришлось спрашивать человека отдельным заходом.
    # Держателя ищем на ТОМ порту, который только что прочитали.
    #
    # В первой версии порт читался в переменную, а держатель — по зашитому :80,
    # и две соседние строки противоречили друг другу ровно у той аудитории, ради
    # которой они и добавлены: у перенёсшего порт выходило «порт вебморды: 8080»
    # и тут же «кто держит :80: никто — вебморда не поднялась», хотя она жива.
    # А если на освободившийся 80-й вставала наша же панель, отчёт клеветал на
    # неё диагнозом «отнимает вебморду роутера».
    local _hp _hpn _h80
    _hp=$(LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
          | sed -n 's/^[[:space:]]*ip http port[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' | head -1)
    if [ -n "$_hp" ]; then _hpn="$_hp"; else _hpn=80; _hp="80 (умолчание)"; fi
    printf 'порт вебморды     : %s\n' "$_hp"
    # Печатаем токен целиком, pid и имя: у ndm имя процесса в netstat буквально
    # "null", и одно имя читалось бы как ошибка вывода. А вот lighttpd здесь —
    # это диагноз: пакетный экземпляр отнял порт у вебморды роутера.
    _h80=$(netstat -lntp 2>/dev/null | awk -v p=":$_hpn\$" '$4 ~ p {print $NF; exit}')
    case "$_h80" in
        '')         printf 'кто держит порт   : никто — вебморда роутера не поднялась\n' ;;
        *lighttpd*) printf 'кто держит порт   : %s — ПЛОХО, это отнимает вебморду роутера\n' "$_h80" ;;
        *)          printf 'кто держит порт   : %s\n' "$_h80" ;;
    esac

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

    print_insta_pins
    print_agh
}

# Наши записи `ip host` — те самые пины Instagram/WhatsApp.
#
# ПЕЧАТАЕТСЯ ВСЕГДА, А НЕ ТОЛЬКО ПРИ ADGUARD HOME. Счёт этих записей жил внутри
# print_agh и выводился лишь на роутерах с AGH — то есть у меньшинства. У всех
# остальных диагностика про пины не говорила НИЧЕГО: в журнале рефрешера стоит
# «6 host(s) updated, ndmc config saved», а есть ли записи на роутере сейчас —
# по отчёту не установить. Ровно этот вопрос и пришёл из поля.
#
# Ноль записей поломкой НЕ называем: их штатно вычищает пункт меню [I], и
# выдавать осознанное действие человека за неисправность мы уже научены.
insta_pinned() {
    local hosts
    hosts=$(awk -F'"' '/^HOSTS=/ {print $2; exit}' "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" 2>/dev/null)
    [ -n "$hosts" ] || return 0
    command -v ndmc >/dev/null 2>&1 || return 0
    LD_LIBRARY_PATH= ndmc -c "show running-config" 2>/dev/null \
        | awk -v hosts="$hosts" '
            BEGIN { n = split(hosts, h, " "); for (i = 1; i <= n; i++) own[h[i]] = 1 }
            /^ip host/ && ($3 in own) && $4 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $3 "\t" $4 }'
}

print_insta_pins() {
    local hosts n_hosts n_rec n_names
    hosts=$(awk -F'"' '/^HOSTS=/ {print $2; exit}' "${ZAPRET2_DIR}/z2k-insta-ip-refresh.sh" 2>/dev/null)
    if [ -z "$hosts" ] || ! command -v ndmc >/dev/null 2>&1; then
        printf 'ip host insta/wa  : сверить не с чем (нет ndmc или списка доменов)\n'
        return 0
    fi
    n_hosts=$(printf '%s\n' $hosts | awk 'END {print NR}')
    Z2K_PINNED=$(insta_pinned)
    n_rec=$(printf '%s' "$Z2K_PINNED" | grep -c . || true)
    n_names=$(printf '%s' "$Z2K_PINNED" | awk 'NF {print $1}' | sort -u | grep -c . || true)
    if [ "${n_rec:-0}" -eq 0 ]; then
        printf 'ip host insta/wa  : записей нет — адресный обход Instagram/WhatsApp выключен (его чистит пункт меню [I])\n'
    else
        printf 'ip host insta/wa  : %s записей на %s из %s доменов\n' \
            "$n_rec" "$n_names" "$n_hosts"
    fi
}

# AdGuard Home. Он перехватывает DNS у клиентов, а записи `ip host`, на которых
# держится обход Instagram и веб-WhatsApp, применяет dns-proxy прошивки. Что из
# этого выйдет — зависит от того, где именно стоит AGH:
#
#   1. AGH забрал 53-й порт, dns-proxy прошивки штатно отключён, наружу AGH
#      ходит сам. Тогда `ip host` не спрашивает НИКТО: записи целы и бесполезны,
#      клиент получает подменённый провайдером адрес. Снаружи это неотличимо от
#      «обход не работает», в логах z2k при этом ровно ничего. Разбор такого
#      случая у живого пользователя занял час именно потому, что в сводке не
#      было видно ни AGH, ни того, что наши пины перекрыты.
#
#   2. AGH стоит ПЕРЕД прошивочным прокси: слушает свой порт (обычно 5300, а
#      клиентов заворачивает REDIRECT в firewall), а `upstream_dns` у него —
#      127.0.0.1:53, то есть тот самый dns-proxy. Пины применяются ниже по
#      цепочке и доезжают до клиента ровно так же, как без AGH.
#
# ЧТО БЫЛО. Считались только записи в `rewrites:`, и во второй схеме сводка
# объявляла рабочему роутеру «обход Instagram/WhatsApp работать не будет».
# Рефрешер в rewrites ничего не пишет и не должен (см. шапку
# z2k-insta-ip-refresh.sh — он правит `ip host`), поэтому счёт `0/N` и крик
# получал КАЖДЫЙ пользователь с такой схемой, независимо от того, работает у
# него обход или нет. Проверено пакетом на живом роутере: ответ AGH на
# www.instagram.com равен записи `ip host`, а TTL в нём на несколько секунд
# меньше — это его кэш ответа прошивочного прокси.
#
# Ложная тревога в диагностике дороже отсутствующей строки: по ней идут чинить
# то, что не сломано, и добавляют в AGH статические rewrites, которые назавтра
# протухнут и начнут перебивать свежие `ip host`. Поэтому приговор зависит и от
# того, остался ли прошивочный прокси в цепочке, — это видно по `upstream_dns`
# в том же yaml, который уже открыт. А сама та починка — протухшие rewrites поверх
# свежих `ip host` — теперь ловится отдельной строкой: см. счёт расхождений ниже.

# Ведёт ли апстрим AGH обратно в dns-proxy прошивки. Петля на 53-й порт здесь
# не ошибка конфигурации, а штатная схема: именно через неё доезжает `ip host`.
# Разобрать надо все формы, которыми это записывают: 127.0.0.1, 127.0.0.1:53,
# [::1]:53, udp://127.0.0.1:53 и доменный селектор AGH `[/domain/]127.0.0.1:53`.
agh_upstream_is_local() {
    local u="$1" host port
    case "$u" in
        \[/*\]*) u="${u#*\]}" ;;
    esac
    case "$u" in
        udp://*|tcp://*) u="${u#*://}" ;;
        *://*) return 1 ;;
    esac
    case "$u" in
        \[*\]:*) host="${u%%\]*}"; host="${host#\[}"; port="${u##*\]:}" ;;
        \[*\])   host="${u#\[}"; host="${host%\]}"; port=53 ;;
        *:*:*)   host="$u"; port=53 ;;
        *:*)     host="${u%:*}"; port="${u##*:}" ;;
        *)       host="$u"; port=53 ;;
    esac
    [ "$port" = 53 ] || return 1
    case "$host" in
        127.*|::1|0:0:0:0:0:0:0:1|localhost) return 0 ;;
    esac
    return 1
}

print_agh() {
    local y c hosts pinned inagh cmp n_pin n_hit n_bad state ups upf u n_up n_uploc uploc
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
    # Список уже собран print_insta_pins — второй раз ndmc не дёргаем: два
    # обращения к одному источнику разъезжаются, и отчёт начинает спорить сам
    # с собой.
    pinned="${Z2K_PINNED:-$(insta_pinned)}"
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
    # Апстримы — из того же файла, который уже открыт. Ни одного сетевого
    # запроса: сводку гоняют и на роутере без интернета, и она обязана
    # оставаться быстрой и одинаковой.
    ups=$(awk '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        function unq(s) { gsub(/"/, "", s); gsub(Q, "", s); return s }
        BEGIN { Q = sprintf("%c", 39)
                KRX = "^[ \t]*[\"" Q "]?upstream_dns[\"" Q "]?[ \t]*:" }
        !inb && $0 ~ KRX { inb = 1; kin = match($0, /[^ \t]/) - 1; next }
        inb {
            t = trim($0)
            if (t == "" || substr(t, 1, 1) == "#") next
            cur = match($0, /[^ \t]/) - 1
            if (cur < kin || (cur == kin && substr(t, 1, 1) != "-")) { inb = 0; next }
            if (substr(t, 1, 1) != "-") next
            v = unq(trim(substr(t, 2)))
            if (v != "") print v
        }' "$y" 2>/dev/null)
    # upstream_dns_file: у части людей список апстримов вынесен в отдельный
    # файл, и без него схема с прошивочным прокси выглядела бы как «апстримов
    # нет» — то есть снова ложная тревога.
    upf=$(sed -n 's/^[[:space:]]*upstream_dns_file[[:space:]]*:[[:space:]]*//p' "$y" 2>/dev/null \
          | head -1 | tr -d "\"' 	")
    if [ -n "$upf" ] && [ -r "$upf" ]; then
        ups="$ups
$(sed 's/#.*//' "$upf" 2>/dev/null)"
    fi
    n_up=0; n_uploc=0; uploc=""
    for u in $ups; do
        n_up=$((n_up + 1))
        if agh_upstream_is_local "$u"; then
            n_uploc=$((n_uploc + 1))
            [ -n "$uploc" ] || uploc="$u"
        fi
    done
    # Расхождение считаем отдельно: rewrites СИЛЬНЕЕ апстрима — AGH отвечает из
    # них, никого не спрашивая. Поэтому запись по нашему домену с чужим адресом
    # опаснее пустых rewrites: пины рефрешер обновляет каждую ночь, а вбитая
    # руками копия остаётся с адресами прошлой недели и перебивает свежий
    # `ip host`. Именно так «чинят» по старой формулировке этой же строки —
    # случай не гипотетический.
    cmp=$( { printf '%s\n' "$pinned" | sed 's/^/P /'
             printf '%s\n' "$inagh"  | sed 's/^/A /'; } \
           | awk '$1 == "P" && NF == 3 { p[$2 " " $3] = 1; np++ }
                  $1 == "A" && NF == 3 { a[$2 " " $3] = 1 }
                  END { for (k in p) if (k in a) h++
                        for (k in a) if (!(k in p)) x++
                        printf "%d %d %d", np + 0, h + 0, x + 0 }')
    n_pin=${cmp%% *}; n_hit=${cmp#* }; n_bad=${n_hit#* }; n_hit=${n_hit%% *}
    if [ "$n_pin" = 0 ]; then
        printf 'AdGuardHome       : %s, наших ip host нет — сверять нечего\n' "$state"
    elif [ "$n_bad" -gt 0 ]; then
        printf 'AdGuardHome       : %s, в rewrites %s записей по нашим доменам расходятся с ip host: rewrites сильнее апстрима, клиент получит их адреса — обход Instagram/WhatsApp сломается\n' \
            "$state" "$n_bad"
    elif [ "$n_hit" = "$n_pin" ]; then
        printf 'AdGuardHome       : %s, наши записи в rewrites: %s/%s — синхронизированы\n' \
            "$state" "$n_hit" "$n_pin"
    elif [ "$n_up" -gt 0 ] && [ "$n_uploc" = "$n_up" ]; then
        printf 'AdGuardHome       : %s, в rewrites %s/%s — и это норма: апстрим %s ведёт в dns-proxy прошивки, ip host применяется там\n' \
            "$state" "$n_hit" "$n_pin" "$uploc"
    elif [ "$n_uploc" -gt 0 ]; then
        printf 'AdGuardHome       : %s, в rewrites %s/%s, а в dns-proxy прошивки ведут %s апстрима из %s: на остальных запросах ip host не применяется — обход Instagram/WhatsApp будет работать через раз\n' \
            "$state" "$n_hit" "$n_pin" "$n_uploc" "$n_up"
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
# Секция обещает «ошибки из ВСЕХ логов». Пять файлов в списке не значились, и
# ровно в них лежит причина двух самых частых обращений: «панель не открывается»
# и «детектор молчит». Отсутствующие файлы пропускаются сами ([ -r ]), так что
# лишних строк на роутере без этих подсистем не будет.
Z2K_DIAG_LOGS="/opt/var/log/z2k-auto-update.log /opt/var/log/z2k-scheduler.log
/opt/zapret2/update-lists.log /tmp/z2k-log/tg-tunnel.log
/tmp/z2k-warp/warpd.log /tmp/z2k-log/z2k-rt-proxy.log /tmp/z2k-log/z2k-http-tunnel.log
/tmp/z2k-log/z2k-insta-refresh.log /tmp/z2k-log/z2k-webpanel-error.log
/var/log/z2k-detect.log /opt/var/log/z2k-detect-watchdog.log
/tmp/z2k-log/z2k-webpanel-sup.log /tmp/z2k-log/z2k-webpanel-startcheck.log
/tmp/z2k-log/z2k-webpanel-wait.log"

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

# z2k_recent_lines <файл> — строки за последние Z2K_ERR_DAYS суток.
#
# ОКНО ОБЯЗАНО БЫТЬ ПО ВРЕМЕНИ, А НЕ ПО ЧИСЛУ СТРОК. Раздел «errors across all
# logs» брал `tail -40` СОВПАВШИХ строк за всю историю файла. В тихом журнале
# сорок ошибок набираются за месяцы: в отчёте 2026-08-27 первой строкой стояла
# «manifest fetch failed» от 28 ИЮНЯ — рядом со свежими и неотличимо от них.
# Человек читает это как «вот что у меня сломано сейчас» и уходит чинить то,
# что починилось два месяца назад.
#
# Дата берётся из строки (наши журналы пишут ISO), сравнение строковое — для
# YYYY-MM-DD это корректно и не требует арифметики. Строка без даты наследует
# дату последней датированной: ретраи и стектрейсы печатаются без штампа, но
# принадлежат тому же событию. До первой даты в окне — не показываем.
#
# Хвост в 4000 строк — потолок работы: на журнале в сотни тысяч строк полный
# проход стоил бы секунды на каждый из девяти файлов.
Z2K_ERR_DAYS="${Z2K_ERR_DAYS:-7}"
z2k_recent_lines() {
    [ -r "$1" ] || return 0
    _zrl_cut=$(( $(date +%s) - Z2K_ERR_DAYS * 86400 ))
    # `-d @эпоха` — GNU и busybox; `-r эпоха` — BSD. У busybox `-r` берёт ФАЙЛ,
    # поэтому он обязан быть вторым.
    _zrl_cut=$(date -d "@$_zrl_cut" '+%Y-%m-%d' 2>/dev/null \
               || date -r "$_zrl_cut" '+%Y-%m-%d' 2>/dev/null)
    [ -n "$_zrl_cut" ] || { tail -4000 "$1"; return 0; }
    # ДВА РАЗДЕЛИТЕЛЯ, И ЭТО НЕ ПЕДАНТИЗМ. Наши журналы пишут «2026-08-27», а
    # туннель на Go — «2026/08/27». Регулярка на один дефис молча выбросила бы
    # tg-tunnel.log целиком: раздел ошибок перестал бы видеть самый частый
    # источник жалоб. Слэши приводим к дефисам перед сравнением.
    tail -4000 "$1" 2>/dev/null | awk -v cut="$_zrl_cut" '
        {
            if (match($0, /[0-9][0-9][0-9][0-9][-\/][0-9][0-9][-\/][0-9][0-9]/)) {
                cur = substr($0, RSTART, 10)
                gsub(/\//, "-", cur)
            }
            if (cur != "" && cur >= cut) print
        }'
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
        # ВКЛЮЧАЮЩИЙ фильтр был только английским, а половина наших сообщений —
        # русские: «не удалось», «ОТКАЗ», «туннель НЕ поднялся» не попадали в
        # секцию вовсе, хотя именно их человек и присылает.
        #
        # ИСКЛЮЧАЮЩИЙ: '0 failed' стоял без границы слева, поэтому выбрасывал и
        # «10 failed», и «100 failed» — то есть глушил ровно те строки, ради
        # которых секция существует. Прижимаем к началу строки или к неразрядной
        # позиции слева.
        hits=$(z2k_recent_lines "$f" \
               | grep -iE 'error|fail|fatal|panic|refused|denied|timeout|cannot|unable|не удалось|отказ|не поднялся|не запустил|ошибка|таймаут' 2>/dev/null \
               | grep -vE 'fail=0|failed=0|(^|[^0-9])0 failed|(^|[^0-9])0 errors|errors=0|error=0' \
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
            printf -- '--- %s ---\n%s\n' "$f" "$hits" | z2k_mask_addrs
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
        print_warp
        print_tcp16
        print_rotator
        print_logs
        printf '\n=== end of diag ===\n'
        ;;
esac
