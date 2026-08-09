#!/bin/sh
# z2k-stats-upload.sh — anonymized strategy-stats uploader (client side).
#
# Sends a privacy-preserving snapshot of which rotation strategy each pool
# landed on, so the project can see (in aggregate, across opted-in devices)
# which strategies actually hold traffic and which never play — and reorder
# rotation profiles accordingly. See vps-stats/ for the server side.
#
# WHAT LEAVES THE DEVICE (and nothing else):
#   * pool key      — e.g. yt_quic / rkn_tcp / yt_tcp  (a strategy bucket name)
#   * strategy slot — the integer rotation slot the pool currently sits on
#   * dwell         — as long as the slot has been stable, ROUNDED INTO BUCKETS
#                     (see dwell_bucket below): точная секунда не нужна для
#                     агрегата, а точный набор «пул × слот × секунда» — это
#                     довольно высокоэнтропийный отпечаток, который наблюдатель
#                     склеивает по дням при видимом source IP.
# WHAT NEVER LEAVES THE DEVICE:
#   * the host/domain column of state.tsv (the sites you visit) — dropped here;
#   * your IP / provider / region — never read, and the server discards the
#     source IP on receipt;
#   * ANY device identifier — no serial, no MAC, no install-id, not even a random
#     nonce. Per the privacy audit, a stable id would make uploads longitudinally
#     joinable and re-introduce identity. Uploads are ~1/day so no de-dup key is
#     needed; the server treats each upload as one anonymous device-day sample.
#
# Controlled by Z2K_STATS (default 1/ON). Set Z2K_STATS=0 in the config or via
# the menu / webpanel toggle to opt out. Every failure path is a silent no-op:
# this script must NEVER affect the bypass.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

ZAPRET2_DIR="/opt/zapret2"
CONFIG="${ZAPRET2_DIR}/config"
STATE_TSV="${ZAPRET2_DIR}/extra_strats/cache/autocircular/state.tsv"

# Endpoint + anti-abuse token. The token is a spam speed-bump (the payload is
# anonymized), not a secret; it can be rotated by setting Z2K_STATS_TOKEN /
# Z2K_STATS_ENDPOINT in the config without a code release.
ENDPOINT="http://213.176.74.63:8088/stats"
TOKEN="z2kstats-pub-1"

# --- read overridable settings + the on/off flag from config -----------------
Z2K_STATS=1
if [ -f "$CONFIG" ]; then
    _v=$(grep '^Z2K_STATS=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2 | tr -dc '0-9')
    [ -n "$_v" ] && Z2K_STATS="$_v"
    _e=$(grep '^Z2K_STATS_ENDPOINT=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$_e" ] && ENDPOINT="$_e"
    _t=$(grep '^Z2K_STATS_TOKEN=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$_t" ] && TOKEN="$_t"
fi

# Opt-out short-circuit.
[ "$Z2K_STATS" = "1" ] || exit 0

# --- гейт «человек узнал» ----------------------------------------------------
#
# Телеметрия включена по умолчанию — это решение владельца, и оно не
# обсуждается. Но «включено по умолчанию» и «ушло раньше, чем человек успел
# узнать» — разные вещи, и второе исправимо без отказа от первого.
#
# Первая отправка ждёт, пока экран со списком полей не увидят: меню [C] или
# карточка в разделе «Режимы» вебпанели ставят Z2K_STATS_ACK=1, как только
# показали текст. Это НЕ opt-in: выключать по умолчанию нельзя, по opt-in
# выборка не набирается. Это уведомление с отсрочкой.
#
# Потолок ожидания — трое суток. Дальше отправляем: за это время и меню, и
# панель, и README доступны, а держать роутер в тишине бесконечно значит терять
# ровно тех, кто панель не открывает.
#
# Ключа нет вовсе (установка старше этой правки) — считаем, что человек уже
# живёт с телеметрией и заново его не спрашиваем.
_ack=$(grep -m1 '^Z2K_STATS_ACK=' "$CONFIG" 2>/dev/null | cut -d= -f2 | tr -dc '0-9')
if [ "$_ack" = "0" ]; then
    _age_src="${ZAPRET2_DIR}/.z2k-installed-tag"
    [ -f "$_age_src" ] || _age_src="$CONFIG"
    _inst=$(date -r "$_age_src" +%s 2>/dev/null || echo 0)
    _now=$(date +%s 2>/dev/null || echo 0)
    if [ "$_inst" -gt 0 ] 2>/dev/null && [ "$((_now - _inst))" -lt 259200 ] 2>/dev/null; then
        exit 0
    fi
fi
[ -f "$STATE_TSV" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

NOW=$(date +%s)

# --- build anonymized rows: DROP host ($2) entirely --------------------------
# state.tsv line: pool<TAB>host<TAB>strategy<TAB>ts  (# comments skipped)
rows=$(awk -F'\t' -v now="$NOW" '
    # Границы корзин: минута, 5 минут, полчаса, 2 часа, 12 часов, сутки, больше.
    # Отдаётся НИЖНЯЯ граница корзины, чтобы значение осталось числом секунд и
    # серверу не пришлось знать про эту схему.
    function dwell_bucket(d) {
        if (d <    60) return 0
        if (d <   300) return 60
        if (d <  1800) return 300
        if (d <  7200) return 1800
        if (d < 43200) return 7200
        if (d < 86400) return 43200
        return 86400
    }
    /^#/ { next }
    NF >= 3 {
        pool=$1; strat=$3; ts=$4
        if (pool == "" || strat !~ /^[0-9]+$/) next
        if (ts !~ /^[0-9]+$/) ts=now
        dwell = now - ts; if (dwell < 0) dwell = 0
        # Округляем в корзины. Агрегату это ничего не стоит — вопрос, на который
        # он отвечает, звучит «держится ли стратегия часами или срывается через
        # минуту», а не «сколько именно секунд». Зато точный набор секунд по
        # нескольким пулам сразу образует почти уникальную подпись устройства,
        # и по ней выгрузки разных дней связываются между собой — ровно то, что
        # мы намеренно исключили, отказавшись от идентификатора.
        dwell = dwell_bucket(dwell)
        # $2 (host) is deliberately NEVER referenced.
        printf "%s{\"pool\":\"%s\",\"strategy\":%s,\"dwell\":%s}", sep, pool, strat, dwell
        sep = ","
    }
' "$STATE_TSV" 2>/dev/null)
[ -n "$rows" ] || exit 0

payload="{\"schema\":1,\"rows\":[${rows}]}"

# --- POST: short timeout, silent failure -------------------------------------
curl -s -o /dev/null -m 12 --connect-timeout 6 \
    -X POST "$ENDPOINT" \
    -H "X-Z2K-Token: ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload" >/dev/null 2>&1 || true

exit 0
