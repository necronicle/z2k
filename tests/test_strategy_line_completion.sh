#!/bin/sh
# tests/test_strategy_line_completion.sh — вставка строки из «Подбора по домену»
# в «Свои стратегии» обязана работать без правки руками.
#
# ЧТО БЫЛО. Инструмент подбора выдаёт ОДИН приём:
#   --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=1
# Движку же нужен полный набор опций профиля: фильтры портов и уровня, полезная
# нагрузка, окно и токен circular С КЛЮЧОМ ПУЛА. Человек вставлял ровно то, что
# ему дали, и получал «не удалось собрать конфиг» — виноват формат, а выглядело
# как поломка инструмента.
#
# Проверяется НАСТОЯЩАЯ strategy_complete_line из webpanel/cgi/actions.sh.
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT

mkdir -p "$SB/extra_strats/TCP/RKN" "$SB/extra_strats/TCP/YT"
SKEL='--filter-tcp=443,2053 --filter-l7=tls --payload=tls_client_hello --out-range=-s34228 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2'
printf '%s --lua-desync=fake:payload=tls_client_hello:dir=out --lua-desync=multisplit:pos=1\n' "$SKEL" \
    > "$SB/extra_strats/TCP/RKN/Strategy.txt"
printf -- '--filter-tcp=443 --filter-l7=tls --lua-desync=circular:fails=3:key=yt_tcp --lua-desync=fake:dir=out\n' \
    > "$SB/extra_strats/TCP/YT/Strategy.txt"

# Берём только нужные функции: подключать actions.sh целиком нельзя — он лезет
# в живой роутер.
eval "$(awk '/^_strategy_pool_source\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"
eval "$(awk '/^strategy_complete_line\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"
ZAPRET2_DIR="$SB"
command -v strategy_complete_line >/dev/null 2>&1 \
    || { bad "нет strategy_complete_line"; printf '\nFAILED: 1\n'; exit 1; }

PRIM='--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=1'

# --- 1. Голый приём достраивается каркасом своего пула ------------------------
out=$(printf '%s\n' "$PRIM" | strategy_complete_line rkn_tcp)
case "$out" in
    "$SKEL $PRIM") ok "приём достроен каркасом пула, приём в конце" ;;
    *) bad "достроено не так: [$out]" ;;
esac

# --- 2. Ключ берётся из каркаса ТОГО пула, куда вставляют --------------------
# Это главное: у РКН key=rkn_tcp, у ютуба yt_tcp. Ошибись здесь — приём уедет
# чужому пулу, и человек не поймёт, почему «применилось, но не работает».
out_yt=$(printf '%s\n' "$PRIM" | strategy_complete_line yt_tcp)
case "$out_yt" in
    *key=yt_tcp*) ok "для ютуба подставлен его ключ" ;;
    *) bad "ключ пула не тот: [$out_yt]" ;;
esac
case "$out_yt" in
    *key=rkn_tcp*) bad "в строку ютуба попал ключ РКН" ;;
    *) ok "чужого ключа в строке нет" ;;
esac

# --- 3. Плечи пула отрезаны, остаётся только приём человека ------------------
# Иначе к его приёму приклеились бы все полсотни поставляемых.
n=$(printf '%s\n' "$out" | grep -o -- '--lua-desync=' | wc -l | tr -d ' ')
[ "$n" = "2" ] && ok "в строке ровно два desync: circular и приём" \
               || bad "лишние плечи из пула: $n штук"

# --- 4. Полную строку не трогаем ---------------------------------------------
# Человек мог принести свой набор целиком, и дописывать ему нечего.
full="$SKEL --lua-desync=fake:dir=out"
out2=$(printf '%s\n' "$full" | strategy_complete_line rkn_tcp)
[ "$out2" = "$full" ] && ok "готовая строка остаётся как есть" \
                      || bad "готовую строку изменили: [$out2]"

# --- 5. Идемпотентность ------------------------------------------------------
# Сохранение достраивает и передаёт результат проверке, которая достраивает
# снова. Второй проход обязан ничего не менять.
out3=$(printf '%s\n' "$out" | strategy_complete_line rkn_tcp)
[ "$out3" = "$out" ] && ok "повторное достраивание ничего не меняет" \
                     || bad "второй проход исказил строку"

# --- 6. Мусор без приёма не достраиваем --------------------------------------
# Молча приклеивать каркас к ерунде значит выдать её за исправную.
out4=$(printf 'просто текст\n' | strategy_complete_line rkn_tcp)
[ "$out4" = "просто текст" ] && ok "текст без приёма не трогаем" \
                             || bad "к мусору приклеен каркас: [$out4]"

# --- 7. Нет поставляемого файла — не выдумываем ------------------------------
rm -f "$SB/extra_strats/TCP/RKN/Strategy.txt"
out5=$(printf '%s\n' "$PRIM" | strategy_complete_line rkn_tcp)
[ "$out5" = "$PRIM" ] && ok "без каркаса строка возвращается как была" \
                      || bad "каркас взят из ниоткуда: [$out5]"

# --- 8. Проверка движком идёт С НОМЕРОМ ОЧЕРЕДИ -------------------------------
# --qnum нет в NFQWS2_OPT: его подставляет init при запуске, а в конфиг он не
# пишется. Без него движок отвечает «Need queue number» на ЛЮБУЮ строку, то есть
# сохранить свою стратегию не мог никто — отвергались и поставляемые пуловые
# (проверено на роутере 31.08.2026).
#
# Проверяем исполнением: берём НАСТОЯЩУЮ строку вызова из actions.sh и
# подставляем вместо движка заглушку, которой нужен --qnum.
call=$(grep -n 'err=$("$engine" --dry-run' "$ROOT/webpanel/cgi/actions.sh" | head -1 | cut -d: -f2-)
[ -n "$call" ] || bad "не нашёл вызов движка в actions.sh"

cat > "$SB/engine" <<'STUB'
#!/bin/sh
for a in "$@"; do case "$a" in --qnum=*) exit 0 ;; esac; done
echo "Need queue number (--qnum)"; exit 1
STUB
chmod +x "$SB/engine"

engine="$SB/engine"; opt="--filter-tcp=443"
if eval "$call" >/dev/null 2>&1; then
    ok "движок вызывается с номером очереди"
else
    bad "движок вызывается без --qnum — отвергнет любую строку: $err"
fi

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
