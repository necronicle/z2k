#!/bin/sh
# tests/test_vps_alert_rules.sh — правила тревог узла исполняются на
# синтетических событиях; curl подставной и пишет тело запроса в файл.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALERT="$ROOT/vps/observability/alert.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }
[ -f "$ALERT" ] || { bad "alert.sh существует" "нет файла"; printf '\nPASSED: 0\nFAILED: 1\n'; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2kalert.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/events" "$TMP/state" "$TMP/bin"
SENT="$TMP/sent.log"; : > "$SENT"
# Подставной curl: сохраняет аргументы; на /metrics отдаёт заготовку.
cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
case "\$*" in
  *api.telegram.org*) printf '%s\n' "\$*" >> "$SENT"; exit 0 ;;
  *127.0.0.1:9098/metrics*) cat "$TMP/metrics.txt"; exit 0 ;;
esac
exit 1
EOF
chmod 755 "$TMP/bin/curl"
PATH="$TMP/bin:$PATH"; export PATH
export Z2K_ALERT_BOT_TOKEN=test-token Z2K_ALERT_CHAT_ID=42

now=$(date -u +%s)
ts() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
today=$(date -u +%Y-%m-%d)
EV="$TMP/events/events-$today.jsonl"
printf 'relay_sessions 1800\n' > "$TMP/metrics.txt"

# 1. Тихий узел: три закрытия за минуту — тревоги нет.
: > "$EV"
for i in 1 2 3; do printf '{"ts":"%s","ev":"session_close","reason":"peer_close"}\n' "$(ts $((now-10)))" >> "$EV"; done
sh "$ALERT" "$TMP/events" "http://127.0.0.1:9098/metrics" "$TMP/state"
[ ! -s "$SENT" ] && ok "три закрытия не дают тревоги" || bad "ложная тревога" "$(cat "$SENT")"

# 2. Массовое закрытие: 200 за минуту при 1800 живых — тревога один раз.
: > "$EV"
i=0; while [ $i -lt 200 ]; do printf '{"ts":"%s","ev":"session_close","reason":"read_timeout","asn":35807}\n' "$(ts $((now-20)))" >> "$EV"; i=$((i+1)); done
sh "$ALERT" "$TMP/events" "http://127.0.0.1:9098/metrics" "$TMP/state"
grep -q 'mass_close' "$SENT" && ok "массовое закрытие даёт тревогу" || bad "нет тревоги mass_close" "$(cat "$SENT")"
grep -q '35807' "$SENT" && ok "в тревоге есть ASN когорты" || bad "в тревоге нет ASN" "$(cat "$SENT")"
sh "$ALERT" "$TMP/events" "http://127.0.0.1:9098/metrics" "$TMP/state"
[ "$(grep -c mass_close "$SENT")" = 1 ] && ok "повтор в течение 30 минут не шлётся" || bad "тревога продублирована" "$(grep -c mass_close "$SENT")"

# 3. Всплеск отказов авторизации.
: > "$EV"; : > "$SENT"; rm -f "$TMP/state"/*
i=0; while [ $i -lt 60 ]; do printf '{"ts":"%s","ev":"auth_reject","reason":"часы разошлись"}\n' "$(ts $((now-30)))" >> "$EV"; i=$((i+1)); done
sh "$ALERT" "$TMP/events" "http://127.0.0.1:9098/metrics" "$TMP/state"
grep -q 'auth_reject' "$SENT" && ok "всплеск отказов авторизации даёт тревогу" || bad "нет тревоги auth_reject" "$(cat "$SENT")"

# 4. Старые события (10 минут назад) не считаются.
: > "$EV"; : > "$SENT"; rm -f "$TMP/state"/*
i=0; while [ $i -lt 200 ]; do printf '{"ts":"%s","ev":"session_close","reason":"read_timeout"}\n' "$(ts $((now-600)))" >> "$EV"; i=$((i+1)); done
sh "$ALERT" "$TMP/events" "http://127.0.0.1:9098/metrics" "$TMP/state"
[ ! -s "$SENT" ] && ok "события старше окна не считаются" || bad "старые события дали тревогу" "$(cat "$SENT")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
