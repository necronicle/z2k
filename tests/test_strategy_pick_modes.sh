#!/bin/sh
# tests/test_strategy_pick_modes.sh — «Подбор по домену» обязан звать замер тем,
# что человек выбрал, и класть ответ в нужный слот.
#
# ЗАЧЕМ. Режимов пять, и каждый зовёт свою команду с своими флагами. Ошибка тут
# не видна ни в одном тесте движка: инструмент отработает честно, просто не то,
# что просили, — человек получит стратегию под браузер там, где просил под
# телевизор, и не поймёт почему.
#
# Замер подменяем: проверяется ДИСПЕТЧЕР, а не сеть.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/z2k"
cat > "$SB/bin/z2k-detect" <<'STUBEOF'
#!/bin/sh
echo "$*" >> "$ARGLOG"
case "$1" in
    voice)    printf '{"verdict":"no_call","reason":"разговор не идёт"}\n' ;;
    quic)     printf '{"verdict":"clear","target":"x:443"}\n' ;;
    classify) printf '{"verdict":"prefix","target":"x:443"}\n' ;;
esac
STUBEOF
chmod +x "$SB/bin/z2k-detect"
export ZAPRET2_DIR="$SB/z2k"
export STRATEGY_PICK_OUT="$SB/out.json"
export Z2K_DETECT_BIN="$SB/bin/z2k-detect"
export ARGLOG="$SB/args.log"
eval "$(awk '/^strategy_pick_run\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[OK]   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

check() { # <режим> <домен> <ожидаемый аргумент> <ожидаемый ключ в json>
    : > "$ARGLOG"; rm -f "$STRATEGY_PICK_OUT"
    strategy_pick_run "$2" "$1" >/dev/null 2>&1
    rc=$?
    [ "$rc" = 0 ] || { bad "$1: код возврата $rc"; return; }
    grep -q -- "$3" "$ARGLOG" || { bad "$1: звали не тем: $(cat "$ARGLOG")"; return; }
    grep -q "\"mode\":\"$1\"" "$STRATEGY_PICK_OUT" || { bad "$1: в ответе нет режима"; return; }
    grep -q "$4" "$STRATEGY_PICK_OUT" || { bad "$1: не тот слот в ответе"; return; }
    ok "$1: позван «$3», ответ в нужном слоте"
}

check tcp13 example.com "-hello modern" '"tcp":{'
check tcp12 example.com "-hello legacy" '"tcp":{'
check mixed example.com "-hello both"   '"tcp":{'
check quic  example.com "quic -json"    '"quic":{'
check voice ""          "voice -json"   '"voice":{'

# Голос обязан работать без домена, остальные — требовать его.
strategy_pick_run "" tcp13 >/dev/null 2>&1 && bad "tcp13 принял пустой домен" || ok "tcp13 требует домен"
strategy_pick_run "example.com" bogus >/dev/null 2>&1 && bad "принят неизвестный режим" || ok "неизвестный режим отвергнут"

# ВНЕДРЕНИЕ КОМАНД. Строка задачи исполняется через eval, поэтому набор
# символов домена проверяется во ВСЕХ режимах. Раньше у голоса проверка
# пропускалась, и любой, кто дотянулся до панели без пароля, мог выполнить
# произвольную команду на роутере.
MARKER="$SB/pwned"
for m in tcp13 tcp12 mixed quic voice; do
    : > "$ARGLOG"
    strategy_pick_run "x; touch $MARKER" "$m" >/dev/null 2>&1
    if [ -e "$MARKER" ]; then
        bad "$m: внедрение команды сработало"
        rm -f "$MARKER"
    else
        ok "$m: мусор в домене отвергнут"
    fi
done

# Пустой домен у голоса не должен схлопываться так, чтобы режим уехал на его
# место: раньше получался TCP-подбор для домена «voice».
: > "$ARGLOG"; rm -f "$STRATEGY_PICK_OUT"
strategy_pick_run "-" voice >/dev/null 2>&1
grep -q "voice -json" "$ARGLOG" && ok "голос: прочерк понят как «домена нет»" \
    || bad "голос: позвали не голосовой замер: $(cat "$ARGLOG")"
grep -q '"mode":"voice"' "$STRATEGY_PICK_OUT" \
    && ok "голос: режим в ответе верный" || bad "голос: в ответе не тот режим"

# Домена нет только у голоса; остальным режимам он обязателен.
for m in tcp13 tcp12 mixed quic; do
    strategy_pick_run "-" "$m" >/dev/null 2>&1 && bad "$m: принял отсутствие домена" \
        || ok "$m: без домена отказано"
done

# Неиспользованные слоты обязаны быть null, иначе страница нарисует пустой блок.
: > "$ARGLOG"; strategy_pick_run "" voice >/dev/null 2>&1
grep -q '"tcp":null' "$STRATEGY_PICK_OUT" && grep -q '"quic":null' "$STRATEGY_PICK_OUT" \
    && ok "неиспользованные слоты пусты" || bad "слоты не обнулены: $(cat "$STRATEGY_PICK_OUT")"

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
