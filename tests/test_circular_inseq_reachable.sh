#!/bin/sh
# tests/test_circular_inseq_reachable.sh — порог успеха обязан быть достижим.
#
# ЗАЧЕМ ОНА ПОЯВИЛАСЬ. Замер 2026-08-14 на живом конфиге:
#
#   rkn_tcp  окно --in-range=-s20000  порог inseq=26000
#   yt_tcp   окно --in-range=-s5556   порог inseq=18000
#
# Успех по входящим срабатывает СТРОГО при «начальный rseq > inseq» (проверено
# исполнением настоящего standard_success_detector: при inseq=26000 значение
# 26000 даёт false, 26001 — true). А за верхней границей `--in-range` nfqws2
# выключает Lua по потоку целиком (lua cutoff, manual «внутрипрофильные
# фильтры»). Значит успех возможен только в полосе (inseq, окно] — и у этих
# двух пулов она ПУСТА. Путь мёртв, порог не срабатывает ни разу.
#
# ПОЧЕМУ ЭТО НЕ КОСМЕТИКА. Пороги посажены за верхнюю границу тихого обрыва
# стрима (ntc.party 22516: сервер отдаёт 14-30 KB и встаёт без RST/FIN/alert).
# Когда порог мёртв, «успехом» становится голый ServerHello — ровно тот слабый
# признак, от которого ушли 21.05, подняв bytes_in_handshake_done 3072 → 16384:
# ТСПУ пропускает TLS и глушит потоки HTTP/2 внутри мультиплекса, страта
# ложно закрепляется как рабочая, а приложение наполовину мертво.
#
# КОРЕНЬ. Порог ставит наш генератор конфига, окно живёт в файле стратегий —
# два места, никто не сверял. Инвариант держим в генераторе: там же, где порог.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="$ROOT/lib/config_official.sh"
[ -f "$SRC" ] || { printf '[FAIL] нет %s\n' "$SRC"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# Функция вложена в генератор — вынимаем и ИСПОЛНЯЕМ настоящую, а не копию.
awk '/^    ensure_circular_in_range\(\)/,/^    }$/' "$SRC" | sed 's/^    //' > "$TMP/fn.sh"
grep -q 'ensure_circular_in_range()' "$TMP/fn.sh" \
    && ok "функция найдена в генераторе" \
    || { no "функция" "ensure_circular_in_range" "не найдена"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1; }
. "$TMP/fn.sh"

win() { ensure_circular_in_range "$1" | tr ' ' '\n' | grep '^--in-range=-s' | head -1; }

# --- 1. Пустая полоса расширяется ---------------------------------------------
_t="--in-range=-s20000 --lua-desync=circular:fails=3:maxseq=16384:time=60:key=rkn_tcp:nld=2:inseq=26000:retrans=2 --in-range=x"
[ "$(win "$_t")" = "--in-range=-s27500" ] \
    && ok "rkn_tcp: окно поднято выше порога 26000" \
    || no "rkn_tcp" "--in-range=-s27500" "$(win "$_t")"

_t="--in-range=-s5556 --lua-desync=circular:fails=3:key=yt_tcp:inseq=18000 --in-range=x"
[ "$(win "$_t")" = "--in-range=-s19500" ] \
    && ok "yt_tcp: окно поднято выше порога 18000" \
    || no "yt_tcp" "--in-range=-s19500" "$(win "$_t")"

# --- 2. Достаточное окно НЕ трогаем -------------------------------------------
#
# Иначе проход начнёт раздувать окно на каждом перегенерировании конфига и
# молча съест процессор там, где всё уже правильно.
_t="--in-range=-s26000 --lua-desync=circular:key=gv_tcp:inseq=24000 --in-range=x"
[ "$(win "$_t")" = "--in-range=-s26000" ] \
    && ok "gv_tcp: достаточное окно остаётся как есть" \
    || no "gv_tcp" "--in-range=-s26000" "$(win "$_t")"

_t="--in-range=-s5556 --lua-desync=circular:key=game_tls:inseq=4000 --in-range=x"
[ "$(win "$_t")" = "--in-range=-s5556" ] \
    && ok "game_tls: низкий порог не расширяет окно" \
    || no "game_tls" "--in-range=-s5556" "$(win "$_t")"

# --- 3. Без явного inseq ничего не меняется -----------------------------------
#
# Умолчание движка 4096 уже покрыто окном -s5556 — это размер от bol-van.
_t="--in-range=-s5556 --lua-desync=circular:fails=3:time=60:key=http_rkn:nld=2 --in-range=x"
[ "$(win "$_t")" = "--in-range=-s5556" ] \
    && ok "порог не задан — окно не трогаем" \
    || no "без inseq" "--in-range=-s5556" "$(win "$_t")"

# --- 4. `--in-range=x` после circular обязан уцелеть --------------------------
#
# Он выключает входящие для самих стратегий. Затереть его — значит гонять Lua
# на каждом входящем пакете во всех инстансах профиля.
_t="--in-range=-s20000 --lua-desync=circular:key=rkn_tcp:inseq=26000 --in-range=x --lua-desync=fake:strategy=1"
case "$(ensure_circular_in_range "$_t")" in
    *"--in-range=x"*) ok "выключение входящих для стратегий не затёрто" ;;
    *) no "--in-range=x уцелел" "есть" "затёрт" ;;
esac

# --- 5. Мусор не ломает проход -------------------------------------------------
_t="--in-range=-sABC --lua-desync=circular:key=k:inseq=26000 --in-range=x"
case "$(ensure_circular_in_range "$_t")" in
    *"--in-range=-sABC"*) ok "нечисловое окно оставлено как есть, без падения" ;;
    *) no "мусорное окно" "не тронуто" "$(ensure_circular_in_range "$_t")" ;;
esac
_t="--in-range=-s5556 --lua-desync=circular:key=k:inseq=abc --in-range=x"
[ "$(win "$_t")" = "--in-range=-s5556" ] \
    && ok "нечисловой порог игнорируется" \
    || no "мусорный inseq" "--in-range=-s5556" "$(win "$_t")"

# --- 6. Проход реально включён в генерацию -------------------------------------
_calls=$(grep -c '^\s*[a-z_]*=\$(ensure_circular_in_range ' "$SRC")
[ "${_calls:-0}" -ge 3 ] \
    && ok "проход применён ко всем TCP-пулам с порогом ($_calls шт.)" \
    || no "вызовы прохода" ">=3" "${_calls:-0}"

# Порядок: окно считается ПОСЛЕ того, как порог проставлен.
_ln_inseq=$(grep -n 'ensure_circular_tcp_inseq "\$rkn_tcp"' "$SRC" | head -1 | cut -d: -f1)
_ln_range=$(grep -n 'ensure_circular_in_range "\$rkn_tcp"' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$_ln_inseq" ] && [ -n "$_ln_range" ] && [ "$_ln_inseq" -lt "$_ln_range" ]; then
    ok "окно считается после установки порога"
else
    no "порядок проходов" "inseq раньше in-range" "inseq=$_ln_inseq in-range=$_ln_range"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
