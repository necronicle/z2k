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
eval "$(awk '/^_strategy_tag_arms\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"
eval "$(awk '/^strategy_complete_line\(\)/,/^}/' "$ROOT/webpanel/cgi/actions.sh")"
ZAPRET2_DIR="$SB"
command -v strategy_complete_line >/dev/null 2>&1 \
    || { bad "нет strategy_complete_line"; printf '\nFAILED: 1\n'; exit 1; }

PRIM='--lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=1'

# --- 1. Голый приём достраивается каркасом своего пула ------------------------
out=$(printf '%s\n' "$PRIM" | strategy_complete_line rkn_tcp)
case "$out" in
    "$SKEL $PRIM:strategy=1") ok "приём достроен каркасом пула, приём в конце" ;;
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
full="$SKEL --lua-desync=fake:dir=out:strategy=1"
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

# --- 9. Каркас берётся из ТЕКУЩЕЙ строки пула, а не из заводской -------------
# Человек мог уже настроить порты или окно под себя. Если каждый раз брать
# заводской каркас, его настройка молча слетает: он менял приём, а получал
# сброс всего остального.
CUSTOM_STRAT_DIR="$SB/custom"
mkdir -p "$CUSTOM_STRAT_DIR"
MYSKEL='--filter-tcp=8443 --filter-l7=tls --payload=tls_client_hello --lua-desync=circular:fails=9:key=rkn_tcp'
printf '%s --lua-desync=fake:dir=out\n' "$MYSKEL" > "$CUSTOM_STRAT_DIR/rkn_tcp.txt"
out9=$(printf '%s\n' "$PRIM" | strategy_complete_line rkn_tcp)
case "$out9" in
    "$MYSKEL $PRIM:strategy=1") ok "каркас взят из текущей строки человека" ;;
    *) bad "своя настройка потеряна: [$out9]" ;;
esac
rm -f "$CUSTOM_STRAT_DIR/rkn_tcp.txt"

# --- 10. Пути к файлам пулов не разъехались с генератором конфига ------------
# Панель и генератор намеренно не сорсят друг друга, поэтому пути дублируются.
# Разъедутся — панель молча перестанет достраивать, и человек снова получит
# непонятную ошибку. Сверяем напрямую.
for _p in rkn_tcp yt_tcp gv_tcp yt_quic; do
    _panel=$(ZAPRET2_DIR="/opt/zapret2" _strategy_pool_source "$_p")
    _rel=${_panel#/opt/zapret2/}
    grep -q "z2k_read_pool_strategy \"\${extra_strats_dir}/${_rel#extra_strats/}\"" "$ROOT/lib/config_official.sh" \
        || bad "$_p: панель ищет $_rel, а генератор — другой файл"
done
ok "пути к файлам пулов совпадают с генератором"

# --- 11. Приёмы под ротатором обязаны иметь номер ----------------------------
# ЭТО ГЛАВНОЕ. Ротатор circular выбирает приём ПО НОМЕРУ. Приём без номера не
# принадлежит ни одному плечу, и ротатор не применяет НИЧЕГО. Строка при этом
# синтаксически верна, движок её принимает молча, панель показывает «сохранено»
# — а обхода нет.
#
# Замер на роутере 01.09.2026, bdsmx.tube, строка от «Подбора по домену»:
#   без ротатора вовсе .......... 200, 75624 байта, 3 из 3
#   ротатор + приёмы без номера .. RST на ClientHello, 0 из 4
#   ротатор + :strategy=1 ........ 200, 75624 байта, 4 из 4
# Каркас вернуть: тест 7 его снёс, а здесь нужен именно путь «подбор + каркас».
printf '%s --lua-desync=fake:payload=tls_client_hello:dir=out --lua-desync=multisplit:pos=1\n' "$SKEL" \
    > "$SB/extra_strats/TCP/RKN/Strategy.txt"
PAIR='--lua-desync=fake:payload=tls_client_hello:dir=out:blob=fake_default_tls:badsum:repeats=7 --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=681'
out11=$(printf '%s\n' "$PAIR" | strategy_complete_line rkn_tcp)
n_arm=$(printf '%s\n' "$out11" | tr ' ' '\n' | grep -c '^--lua-desync=' )
n_num=$(printf '%s\n' "$out11" | tr ' ' '\n' | grep '^--lua-desync=' | grep -vc '^--lua-desync=circular')
n_tag=$(printf '%s\n' "$out11" | tr ' ' '\n' | grep -c ':strategy=1$')
[ "$n_tag" = "$n_num" ] && [ "$n_num" -gt 0 ] \
    && ok "оба приёма получили номер ($n_tag из $n_num)" \
    || bad "приёмы без номера — ротатор не применит их: [$out11]"
circ=$(printf '%s\n' "$out11" | tr ' ' '\n' | grep '^--lua-desync=circular' | head -1)
case "$circ" in
    *strategy=*) bad "номер повешен на сам ротатор: [$circ]" ;;
    *)           ok "ротатор номером не помечен" ;;
esac
[ "$n_arm" = "3" ] || bad "приёмов в строке $n_arm, ожидалось 3 (circular + два)"

# --- 12. Чужие номера не переписываем ----------------------------------------
# Человек мог принести настоящий пул из нескольких плеч. Схлопнуть их все в
# strategy=1 значит превратить пул в одно плечо.
many_arms="$SKEL --lua-desync=fake:dir=out:strategy=1 --lua-desync=multisplit:pos=1:strategy=2"
out12=$(printf '%s\n' "$many_arms" | strategy_complete_line rkn_tcp)
[ "$out12" = "$many_arms" ] && ok "пул с номерами не тронут" \
                             || bad "номера в пуле переписаны: [$out12]"

# --- 13. Без ротатора номера не нужны ----------------------------------------
# Строка без circular применяет свои приёмы всегда; лишний номер там — шум.
no_rotator='--filter-tcp=443 --filter-l7=tls --lua-desync=fake:dir=out'
out13=$(printf '%s\n' "$no_rotator" | strategy_complete_line rkn_tcp)
[ "$out13" = "$no_rotator" ] && ok "строка без ротатора не помечается" \
                             || bad "номер повешен без ротатора: [$out13]"


printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
