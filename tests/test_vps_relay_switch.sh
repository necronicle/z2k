#!/bin/sh
# tests/test_vps_relay_switch.sh — переключатель экземпляров релея
# исполняется с подставными systemctl и curl. Состояние юнитов — в файлах.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SW="$ROOT/vps/bin/relay-switch.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s (%s)\n' "$1" "$2"; }
[ -f "$SW" ] || { bad "relay-switch.sh есть" "нет"; printf '\nPASSED: 0\nFAILED: 1\n'; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2ksw.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
ST="$TMP/state"; mkdir -p "$ST"; LOG="$TMP/calls.log"; : > "$LOG"
# Подставной systemctl: is-active смотрит файл, start/stop его создают/удаляют.
cat > "$TMP/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$LOG"
case "\$1" in
  is-active) u="\$3"; [ -f "$ST/\$u" ] ;;
  start) touch "$ST/\$2" ;;
  stop) rm -f "$ST/\$2" ;;
  disable) rm -f "$ST/\$3" ;;
esac
EOF
# Подставной curl: отвечает только портам из файла healthy.
cat > "$TMP/curl" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in http://127.0.0.1:*) p=\${a#http://127.0.0.1:}; p=\${p%%/*};; esac; done
grep -qx "\$p" "$TMP/healthy" 2>/dev/null && printf 'relay_build_info{version="t",instance="x"} 1\n' && exit 0
exit 22
EOF
chmod 755 "$TMP/systemctl" "$TMP/curl"
export SYSTEMCTL="$TMP/systemctl" CURL="$TMP/curl"

# 1. С нуля: поднимается a.
rm -f "$ST"/*; echo 9098 > "$TMP/healthy"; : > "$LOG"
if sh "$SW" >/dev/null 2>&1 && [ -f "$ST/z2k-relay@a" ] && [ ! -f "$ST/z2k-relay@b" ]; then
    ok "с нуля поднимается a"
else
    bad "с нуля поднимается a" "$(cat "$LOG" | tr '\n' ';')"
fi

# 2. Активен a → поднят b, a остановлен; прежний одиночный юнит выключен.
rm -f "$ST"/*; touch "$ST/z2k-relay@a" "$ST/z2k-relay.service"; echo 9097 > "$TMP/healthy"; : > "$LOG"
if sh "$SW" >/dev/null 2>&1 && [ -f "$ST/z2k-relay@b" ] && [ ! -f "$ST/z2k-relay@a" ] && [ ! -f "$ST/z2k-relay.service" ]; then
    ok "a → b, a и прежний юнит остановлены"
else
    bad "a → b" "$(ls "$ST" | tr '\n' ' ') :: $(cat "$LOG" | tr '\n' ';')"
fi
grep -q "^start z2k-relay@b" "$LOG" && grep -q "^stop z2k-relay@a" "$LOG" \
    && [ "$(grep -n '^start z2k-relay@b' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^stop z2k-relay@a' "$LOG" | cut -d: -f1)" ] \
    && ok "сначала старт нового, потом стоп старого" || bad "порядок старт/стоп" "$(cat "$LOG" | tr '\n' ';')"

# 3. Новый не отвечает → он остановлен, старый жив, код 1.
rm -f "$ST"/*; touch "$ST/z2k-relay@b"; : > "$TMP/healthy"; : > "$LOG"
sh "$SW" >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ -f "$ST/z2k-relay@b" ] && [ ! -f "$ST/z2k-relay@a" ]; then
    ok "новый не отвечает — откат, старый жив, код 1"
else
    bad "откат при неответе" "rc=$rc состояние: $(ls "$ST" | tr '\n' ' ')"
fi

# 4. Оба активны → отказ, ничего не трогается.
rm -f "$ST"/*; touch "$ST/z2k-relay@a" "$ST/z2k-relay@b"; : > "$LOG"
sh "$SW" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ! grep -qE "^(start|stop)" "$LOG" && ok "оба активны — отказ без действий" || bad "оба активны" "rc=$rc $(cat "$LOG" | tr '\n' ';')"

# 5. dry-run ничего не делает.
rm -f "$ST"/*; touch "$ST/z2k-relay@a"; : > "$LOG"
out=$(sh "$SW" --dry-run 2>&1)
echo "$out" | grep -q "z2k-relay@b" && ! grep -qE "^(start|stop)" "$LOG" && ok "dry-run только рассказывает" || bad "dry-run" "$out"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
