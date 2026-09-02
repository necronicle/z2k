#!/bin/sh
# Поминутные правила тревог по событиям релея (спека v2, §6.3).
# alert.sh EVENTS_DIR METRICS_URL STATE_DIR
# Секреты: Z2K_ALERT_BOT_TOKEN, Z2K_ALERT_CHAT_ID (EnvironmentFile юнита).
# Одно сообщение на правило в 30 минут. Любая ошибка правила не мешает
# остальным: скрипт не под set -e намеренно.
set -u
EV_DIR="${1:?events dir}"; METRICS="${2:?metrics url}"; STATE="${3:?state dir}"
mkdir -p "$STATE"
now=$(date -u +%s)
today=$(date -u +%Y-%m-%d)
yday=$(date -u -d "@$((now-86400))" +%Y-%m-%d 2>/dev/null || date -u -r $((now-86400)) +%Y-%m-%d)

# События за последние N секунд: ts в RFC3339 UTC → epoch чистой
# арифметикой (days_from_civil): mktime есть только в gawk, а на узле mawk,
# на машине сборки — BWK awk.
recent() {
    # вчерашний день релей сжимает после полуночи (.jsonl.gz); сразу после
    # ротации, пока сжатие идёт, есть оба — читаем что есть
    { gzip -dc "$EV_DIR/events-$yday.jsonl.gz" 2>/dev/null
      cat "$EV_DIR/events-$yday.jsonl" "$EV_DIR/events-$today.jsonl" 2>/dev/null; } \
    | awk -v now="$now" -v win="$1" '
        function days_from_civil(y, m, d,   era, yoe, doy, doe) {
            y -= (m <= 2)
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return era * 146097 + doe - 719468
        }
        function epoch(ts,   y,m,d,H,M,S) {
            y=substr(ts,1,4)+0; m=substr(ts,6,2)+0; d=substr(ts,9,2)+0
            H=substr(ts,12,2)+0; M=substr(ts,15,2)+0; S=substr(ts,18,2)+0
            return days_from_civil(y, m, d) * 86400 + H * 3600 + M * 60 + S
        }
        {
            if (match($0, /"ts":"[^"]+"/)) {
                t=substr($0, RSTART+6, RLENGTH-7)
                if (now - epoch(t) <= win) print
            }
        }'
}
count_ev() { recent "$1" | grep -c "\"ev\":\"$2\""; }
# Релей работает одним из двух экземпляров (9098/9097), во время переключения
# — обоими: метрику суммируем по всем, кто отвечает.
metric() {
    total=0; seen=0
    for u in "$METRICS" "${METRICS_B:-http://127.0.0.1:9097/metrics}"; do
        v=$(curl -fsS --max-time 5 "$u" 2>/dev/null | awk -v n="$1" '$1==n {print $2; exit}')
        [ -n "$v" ] && { total=$((total + v)); seen=1; }
    done
    [ "$seen" = 1 ] && echo "$total"
}

send() { # send RULE TEXT
    rule="$1"; text="$2"
    last=$(cat "$STATE/$rule.sent" 2>/dev/null || echo 0)
    [ $((now - last)) -ge 1800 ] || return 0
    curl -fsS --max-time 10 "https://api.telegram.org/bot${Z2K_ALERT_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${Z2K_ALERT_CHAT_ID}" \
        --data-urlencode "text=$text" >/dev/null 2>&1 && echo "$now" > "$STATE/$rule.sent"
}

live=$(metric relay_sessions); [ -n "$live" ] || live=0
thr=$((live / 10)); [ "$thr" -ge 20 ] || thr=20

# 1. Массовое закрытие за минуту + верхние ASN когорты.
closes=$(count_ev 60 session_close)
if [ "$closes" -ge "$thr" ]; then
    asns=$(recent 60 | grep '"ev":"session_close"' | grep -oE '"asn":[0-9]+' | cut -d: -f2 | sort | uniq -c | sort -rn | head -5 | awk '{printf "AS%s×%s ", $2, $1}')
    send mass_close "z2k relay: mass_close — за минуту закрылось $closes сессий из $live живых. ASN: ${asns:-нет}"
fi

# 2. Отказы авторизации.
rej=$(count_ev 60 auth_reject)
[ "$rej" -gt 50 ] && send auth_reject "z2k relay: auth_reject — $rej отказов авторизации за минуту"

# 3. Доля неудачных дозвонов за 5 минут.
opens=$(count_ev 300 stream_open)
fails=$(recent 300 | grep '"ev":"dial_fail"' | grep -c '"reason":"dial_error"')
if [ "$opens" -ge 100 ] && [ $((fails * 100)) -gt $((opens * 5)) ]; then
    send dial_fail "z2k relay: dial_fail — $fails неудачных дозвонов на $opens открытых стримов за 5 минут"
fi
exit 0
