#!/bin/sh
# tests/test_stats_collector.sh — сервер сбора статистики: границы и обещания.
#
# ЗАЧЕМ. Единственная часть проекта, которая слушает интернет и стоит на той же
# машине, что туннели телеграма и релей WhatsApp. Токен у неё — публичная
# константа из прошивки, то есть «писать сюда может только наш флот» никогда не
# было правдой. Значит всё, что её защищает, это не пропуск, а потолки: на тело,
# на строки, на соединения, на размер журнала. Потолок без проверки — обещание,
# а не защита, поэтому здесь они исполняются, а не грепаются.
#
# Проверки поднимают НАСТОЯЩИЙ коллектор на петлевом адресе и говорят с ним по
# сети. Ни одна не смотрит в исходник глазами: все пять падают на коде до
# ревью 2026-08-15, и это единственная причина им доверять.
#
# POSIX sh + python3 (он и так нужен самой службе).

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
COLLECTOR="$ROOT/vps-stats/z2k-stats-collector.py"
AGG="$ROOT/vps-stats/z2k-stats-aggregate.py"

[ -f "$COLLECTOR" ] || { printf '[FAIL] нет %s\n' "$COLLECTOR"; exit 1; }
[ -f "$AGG" ]       || { printf '[FAIL] нет %s\n' "$AGG"; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '[SKIP] нет python3\n'; exit 0; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# Порт из PID, чтобы параллельные прогоны не дрались за один и тот же.
PORT=$(( 19000 + ($$ % 900) ))

# Один python-сценарий на все сетевые проверки: поднимать службу пять раз
# дороже, чем один раз спросить её о пяти вещах. Печатает строки вида
# "KEY=значение", которые ниже разбирает sh.
python3 - "$COLLECTOR" "$WORK" "$PORT" <<'PYEOF' > "$WORK/out" 2>"$WORK/pyerr"
import json, os, socket, struct, subprocess, sys, time, urllib.error, urllib.request

collector, work, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
raw = os.path.join(work, "raw.jsonl")
url = "http://127.0.0.1:%d/stats" % port

env = dict(os.environ,
           Z2K_STATS_RAW=raw,
           Z2K_STATS_PORT=str(port),
           Z2K_STATS_BIND="127.0.0.1",
           Z2K_STATS_TOKEN="testtok",
           Z2K_STATS_MAX_CONN="8")
err = open(os.path.join(work, "stderr.log"), "w")
srv = subprocess.Popen([sys.executable, collector], env=env, stdout=subprocess.DEVNULL, stderr=err)


def post(body, token="testtok"):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"X-Z2K-Token": token})
    try:
        return urllib.request.urlopen(req, timeout=5).status
    except urllib.error.HTTPError as e:
        return e.code


try:
    # Ждём готовности порта, а не спим наугад.
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.05)
    else:
        print("READY=no")
        raise SystemExit

    print("READY=yes")
    print("OK_PLAIN=%d" % post({"schema": 1, "rows": [{"pool": "yt_quic", "strategy": 1, "dwell": 99}]}))
    print("OK_BADTOKEN=%d" % post({"schema": 1, "rows": [{"pool": "a", "strategy": 1, "dwell": 1}]}, token="wrong"))

    # 400 одинаковых пар в одной выгрузке: каждое значение внутри объявленных
    # границ, ни одного 422 — но агрегатор считает hit НА СТРОКУ, так что до
    # схлопывания один запрос выдавал себя за 400 сэмплов и накручивал score
    # той пары, по которому люди решают, что двигать в начало ротации.
    print("OK_DUP=%d" % post({"schema": 1,
                              "rows": [{"pool": "yt_quic", "strategy": 7,
                                        "dwell": 31536000, "count": 100000}] * 400}))

    # Обрыв соединения на середине. По умолчанию socketserver печатает адрес
    # звонящего и полную трассировку в stderr, то есть в journal — при том что
    # и шапка файла, и README обещают, что служба не логирует ничего.
    #
    # ТОКЕН ЗДЕСЬ ОБЯЗАТЕЛЕН, и это не формальность. Без него служба отвечает
    # 401 ещё до чтения тела, успевает это сделать по живому сокету и никакого
    # исключения не возникает — проверка зеленеет и на сломанном коде, охраняя
    # пустоту. Нужен именно путь «токен принят → читаем тело → тело не пришло →
    # 408 в уже мёртвый сокет»: Content-Length больше фактического тела.
    for _ in range(3):
        s = socket.create_connection(("127.0.0.1", port))
        s.sendall(b"POST /stats HTTP/1.1\r\nHost: x\r\n"
                  b"X-Z2K-Token: testtok\r\nContent-Length: 400\r\n\r\nhi")
        time.sleep(0.15)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        s.close()
        time.sleep(0.1)

    # Потолок соединений: держим ровно MAX_CONN, следующее обязано закрыться.
    held = []
    for _ in range(8):
        c = socket.create_connection(("127.0.0.1", port))
        c.sendall(b"G")
        held.append(c)
    time.sleep(0.4)
    extra = socket.create_connection(("127.0.0.1", port))
    extra.settimeout(3)
    try:
        print("OVER_CAP=%s" % ("closed" if extra.recv(64) == b"" else "served"))
    except socket.timeout:
        print("OVER_CAP=hung")
    extra.close()
    for c in held:
        c.close()
    time.sleep(0.3)

    with open(raw, encoding="utf-8") as f:
        lines = [x for x in f.read().splitlines() if x.strip()]
    print("LINES=%d" % len(lines))
    dup = json.loads(lines[-1]) if lines else {"rows": []}
    print("DUP_ROWS=%d" % len(dup.get("rows", [])))
    print("HAS_RXDATE=%s" % ("yes" if dup.get("rx_date") else "no"))
    # Ни одно поле сверх контракта попасть в журнал не должно.
    extra_keys = sorted(set(dup) - {"schema", "rows", "rx_date"})
    print("EXTRA_KEYS=%s" % (",".join(extra_keys) if extra_keys else "none"))
finally:
    srv.terminate()
    try:
        srv.wait(timeout=5)
    except Exception:
        srv.kill()
    err.close()

log = open(os.path.join(work, "stderr.log"), encoding="utf-8").read()
print("TRACEBACKS=%d" % log.count("Traceback"))
# Адрес звонящего в любом виде. Стартовая строка «listening on 127.0.0.1:PORT»
# не в счёт — это наш собственный адрес, а не чужой, поэтому ищем кортеж, каким
# его печатает socketserver: ('127.0.0.1', 51234).
print("ADDR_TUPLES=%d" % log.count("('127.0.0.1'"))
PYEOF

if [ ! -s "$WORK/out" ]; then
    printf '[FAIL] сценарий не дал вывода\n'; sed -n '1,20p' "$WORK/pyerr"; exit 1
fi

get() { sed -n "s/^$1=//p" "$WORK/out" | head -1; }

[ "$(get READY)" = "yes" ] || { printf '[FAIL] коллектор не поднялся\n'; cat "$WORK/pyerr"; exit 1; }

# --- 1. Базовый контракт ------------------------------------------------------
[ "$(get OK_PLAIN)" = "204" ] \
    && ok "штатная выгрузка принимается (204)" \
    || no "штатная выгрузка" "204" "$(get OK_PLAIN)"

[ "$(get OK_BADTOKEN)" = "401" ] \
    && ok "чужой токен отклоняется (401)" \
    || no "чужой токен" "401" "$(get OK_BADTOKEN)"

# --- 2. Одна выгрузка = один сэмпл --------------------------------------------
#
# Инвариант, на котором стоит и приватность («сэмпл device-day, поэтому ключ
# дедупликации не нужен»), и осмысленность сводки.
#
# ГДЕ ИМЕННО ОН ДОЛЖЕН ДЕРЖАТЬСЯ — не в коллекторе. Клиент шлёт по строке на
# каждый (пул, хост) из state.tsv и `count` не шлёт вовсе, поэтому пять хостов
# на одной стратегии дают пять строк с одинаковой парой и РАЗНЫМ dwell. Если
# схлопнуть их при приёме, распределение dwell — ровно то, что агрегатор и
# измеряет, — теряется у каждого здорового роутера с несколькими хостами. Так
# что коллектор обязан сохранить строки как есть, а голос «один на выгрузку»
# считает агрегатор.
[ "$(get OK_DUP)" = "204" ] \
    && ok "выгрузка с повторяющимися парами принимается" \
    || no "выгрузка с повторами" "204" "$(get OK_DUP)"

[ "$(get DUP_ROWS)" = "400" ] \
    && ok "коллектор сохранил все 400 строк — dwell по каждому хосту не потерян" \
    || no "строки сохранены как есть" "400" \
          "$(get DUP_ROWS) — схлопывание при приёме уничтожает распределение dwell"

[ "$(get LINES)" = "2" ] \
    && ok "в журнале ровно две записи — по одной на выгрузку" \
    || no "записей в журнале" "2" "$(get LINES)"

# Тот же журнал через агрегатор: 400 строк одной пары обязаны дать ОДИН сэмпл.
if python3 "$AGG" --raw "$WORK/raw.jsonl" --out-json "$WORK/dup.json" \
        --out-txt "$WORK/dup.txt" >/dev/null 2>&1; then
    _n=$(sed -n 's/.*#7  *n=\([0-9]*\).*/\1/p' "$WORK/dup.txt" | head -1)
    _slots=$(sed -n 's/.*#7 .*slots=\([0-9]*\).*/\1/p' "$WORK/dup.txt" | head -1)
    if [ "$_n" = "1" ]; then
        ok "агрегатор засчитал 400 повторов как один сэмпл (slots=$_slots)"
    else
        no "голос один на выгрузку" "n=1" \
           "n=$_n — один запрос накручивает score этой пары в $_n раз"
    fi
else
    no "агрегатор на выгрузке с повторами" "штатное завершение" "падение"
fi

# И обратное: разные хосты с РАЗНЫМ dwell должны остаться разными точками,
# иначе перцентили считаются по одному значению вместо распределения.
python3 -c "
import json, sys
rows = [{'pool': 'gv_tcp', 'strategy': 3, 'dwell': d} for d in (60, 600, 6000)]
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'schema': 1, 'rx_date': '2026-08-15', 'rows': rows}) + '\n')
" "$WORK/multi.jsonl"
python3 "$AGG" --raw "$WORK/multi.jsonl" --out-json /dev/null --out-txt "$WORK/multi.txt" >/dev/null 2>&1
_p50=$(sed -n 's/.*#3 .*p50=\([0-9]*\).*/\1/p' "$WORK/multi.txt" | head -1)
_ns=$(sed -n 's/.*#3  *n=\([0-9]*\).*/\1/p' "$WORK/multi.txt" | head -1)
if [ "$_ns" = "1" ] && [ "$_p50" = "600" ]; then
    ok "три хоста с разным dwell — один голос, но перцентиль по всем трём (p50=600)"
else
    no "распределение dwell сохранено" "n=1 и p50=600" \
       "n=$_ns и p50=$_p50 — точки потеряны, перцентиль считается не по тем данным"
fi

# --- 3. Служба не логирует ничего ---------------------------------------------
#
# Обещано дословно в шапке коллектора и в README. Обрыв связи на середине —
# обычное дело на мобильных линках флота, и вызывается кем угодно по желанию.
if [ "$(get TRACEBACKS)" = "0" ]; then
    ok "обрыв связи не печатает трассировку в journal"
else
    no "трассировок в stderr" "0" "$(get TRACEBACKS)"
fi
if [ "$(get ADDR_TUPLES)" = "0" ]; then
    ok "адрес звонящего в лог не попадает"
else
    no "упоминаний адреса" "0" "$(get ADDR_TUPLES)"
fi

# --- 4. Потолок соединений ----------------------------------------------------
#
# ThreadingHTTPServer из stdlib даёт по OS-потоку на соединение и не имеет
# никакого предела. Без потолка несколько тысяч брошенных сокетов выедают
# память на машине с туннелями.
case "$(get OVER_CAP)" in
    closed) ok "соединение сверх потолка закрывается сразу" ;;
    hung)   no "потолок соединений" "закрыто" "висит — предела нет" ;;
    *)      no "потолок соединений" "закрыто" "$(get OVER_CAP) — предела нет" ;;
esac

# --- 5. Потолок размера журнала -----------------------------------------------
#
# Ретеншн держит журнал в норме раз в неделю; между прогонами потолок — это то,
# что не даёт флуду забить диск под релеями.
CAPDIR="$WORK/cap"; mkdir -p "$CAPDIR"
printf '%*s' 3000 '' | tr ' ' 'x' > "$CAPDIR/raw.jsonl"
CAPPORT=$((PORT + 1))
CAPCODE=$(Z2K_STATS_RAW="$CAPDIR/raw.jsonl" Z2K_STATS_PORT="$CAPPORT" Z2K_STATS_TOKEN= \
          Z2K_STATS_MAX_RAW=1000 python3 - "$COLLECTOR" "$CAPPORT" <<'PYEOF'
import json, os, socket, subprocess, sys, time, urllib.error, urllib.request
collector, port = sys.argv[1], int(sys.argv[2])
srv = subprocess.Popen([sys.executable, collector], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close(); break
        except OSError:
            time.sleep(0.05)
    req = urllib.request.Request("http://127.0.0.1:%d/stats" % port,
        data=json.dumps({"schema": 1, "rows": [{"pool": "a", "strategy": 1, "dwell": 1}]}).encode())
    try:
        print(urllib.request.urlopen(req, timeout=5).status)
    except urllib.error.HTTPError as e:
        print(e.code)
finally:
    srv.terminate()
    try: srv.wait(timeout=5)
    except Exception: srv.kill()
PYEOF
)
[ "$CAPCODE" = "503" ] \
    && ok "переполненный журнал перестаёт принимать (503), а не растёт" \
    || no "потолок журнала" "503" "$CAPCODE — журнал растёт без предела"

# --- 6. Агрегатор переживает порченую строку ----------------------------------
#
# Одна строка с глубоко вложенным JSON роняла ежедневный таймер: json.loads
# бросает RecursionError, а это RuntimeError, и `except ValueError` его не
# видит. Сводка молча переставала обновляться.
python3 -c "
import json, sys
good = json.dumps({'schema': 1, 'rx_date': '2026-08-15',
                   'rows': [{'pool': 'yt_quic', 'strategy': 1, 'dwell': 600, 'count': 1}]})
with open(sys.argv[1], 'w') as f:
    f.write(good + '\n' + '[' * 200000 + ']' * 200000 + '\n' + good + '\n')
" "$WORK/agg.jsonl"
if python3 "$AGG" --raw "$WORK/agg.jsonl" --out-json "$WORK/s.json" --out-txt "$WORK/s.txt" >/dev/null 2>&1; then
    if grep -q "n=2" "$WORK/s.txt"; then
        ok "агрегатор пропускает порченую строку и считает обе целых"
    else
        no "агрегатор на порченом журнале" "обе целые записи учтены" "учтено не то"
    fi
else
    no "агрегатор на порченом журнале" "штатное завершение" \
       "падение — ежедневный таймер встаёт, сводка тихо перестаёт обновляться"
fi

# --- 7. Ретеншн доезжает до сервера -------------------------------------------
#
# Скрипт подрезки полгода жил только на живой машине и не был ни в одном файле
# репозитория: любой пересоздание VPS давало службу вообще без ретеншна.
TRIM="$ROOT/vps-stats/z2k-stats-trim.sh"
DEPLOY="$ROOT/vps-stats/deploy-vps.sh"
if [ -f "$TRIM" ] && [ -f "$ROOT/vps-stats/z2k-stats-trim.timer" ]; then
    ok "ретеншн и его таймер лежат в репозитории"
else
    no "ретеншн в репозитории" "z2k-stats-trim.sh + .timer" "нет — живёт только на одной машине"
fi
if grep -q 'z2k-stats-trim.sh' "$DEPLOY" && grep -q 'z2k-stats-trim.timer' "$DEPLOY"; then
    ok "установщик ставит ретеншн и включает таймер"
else
    no "установщик ставит ретеншн" "install + enable" "нет — свежий VPS без подрезки"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
