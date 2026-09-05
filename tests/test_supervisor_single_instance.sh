#!/bin/sh
# tests/test_supervisor_single_instance.sh — init-скрипт с надзирателем обязан
# проверять ЖИВОГО НАДЗИРАТЕЛЯ, а не только демона.
#
# Повод: 05.09.2026, роутер Марка. S98tg-tunnel проверял «уже работает» по
# демону через pidof + cmdline. Между перезапусками надзиратель спит до 30 с,
# и в этот момент демона нет вовсе — любой параллельный start (сторож раз в
# минуту, автообновление, хук NDM, кнопка в панели) проверку проходил и
# поднимал ВТОРОГО надзирателя. Дальше два цикла дерутся за :1443: один держит
# порт, второй каждые 30 с рожает демона, тот падает с
# «bind: address already in use». В логе было 182 таких круга, и туннель при
# этом работал — поэтому симптом не всплывал.
#
# У S96z2k-rt-proxy, S97z2k-http-tunnel и S99z2k-scheduler проверка была с
# самого начала. Тест держит инвариант для всех.
# POSIX sh (busybox ash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/files/init.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

[ -d "$DIR" ] || { echo "нет $DIR"; exit 1; }

# start() до строки запуска подоболочки.
start_body() {
    awk '/^start\(\) \{/{f=1} f{print} f && /^}/{exit}' "$1"
}

for f in "$DIR"/*; do
    grep -q 'supervisor' "$f" 2>/dev/null || continue
    name=$(basename "$f")
    body=$(start_body "$f")
    if [ -z "$body" ]; then
        bad "$name: не нашёл start()"
        continue
    fi
    # Признак проверки надзирателя: kill -0 по содержимому pidfile, либо
    # выделенный помощник sup_alive.
    if echo "$body" | grep -q 'sup_alive' || \
       echo "$body" | grep -q 'kill -0'; then
        ok "$name: start проверяет живого надзирателя"
    else
        bad "$name: start проверяет только демона — параллельный запуск поднимет второго надзирателя"
    fi
done

# Дубликат обязан уметь уйти сам: иначе уже возникший лишний цикл живёт до
# перезагрузки, а перезагружать роутер ради этого никто не станет.
f="$DIR/S98tg-tunnel"
if [ -f "$f" ]; then
    if grep -q 'GENFILE' "$f" && grep -q 'поколение' "$f"; then
        ok "S98tg-tunnel: дубликат уходит сам по смене поколения"
    else
        bad "S98tg-tunnel: нет самовыключения дубликата"
    fi
    if awk '/^stop\(\) \{/{f=1} f{print} f && /^}/{exit}' "$f" | grep -q 'PPid'; then
        ok "S98tg-tunnel: stop добивает осиротевших надзирателей"
    else
        bad "S98tg-tunnel: stop не добивает осиротевших надзирателей"
    fi
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
