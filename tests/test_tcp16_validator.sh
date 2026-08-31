#!/bin/sh
# tests/test_tcp16_validator.sh — конфиг с включённым механизмом обязан
# проходить ШТАТНЫЙ валидатор.
#
# Повод: r-81.1. Обновление раскладывает файлы, пересобирает конфиг и зовёт
# z2k-config-validator.sh; код 2 — вето на перезапуск и откат. Валидатор
# требовал файл на каждый blob=, а наш z2k_ch собирается в рантайме и файла не
# имеет — обновление откатывалось у каждого, у кого механизм включён. Правило
# «рантайм-блоб файла не имеет» стояло в тесте про идентификаторы блобов, но
# сам валидатор, который и накладывает вето, никто не проверял.
#
# Здесь проверяется именно он и именно на таком конфиге.
# POSIX sh (busybox ash).

DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$DIR/files/z2k-config-validator.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

[ -f "$VALIDATOR" ] || { echo "нет $VALIDATOR"; exit 1; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/files/fake" "$SB/ipset" "$SB/lists" "$SB/nfq2"
# Заглушка движка: валидатор в конце зовёт nfqws2 --dry-run. Нам здесь важен
# не движок, а разбор конфига нашими проверками.
printf '#!/bin/sh\nexit 0\n' > "$SB/nfq2/nfqws2"; chmod +x "$SB/nfq2/nfqws2"
: > "$SB/lists/rkn.txt"; printf 'example.com\n' > "$SB/lists/rkn.txt"
printf 'x' > "$SB/files/fake/fake_default_tls.bin"

# Конфиг ровно той формы, что генерируется при включённом механизме: наш
# инстанс готовит блоб, штатный fake его отправляет, файла у блоба нет.
cat > "$SB/config" <<CFG
ENABLED=1
NFQWS2_OPT="--filter-tcp=443 --hostlist=$SB/lists/rkn.txt --lua-desync=z2k_stall_watch:dir=in:cap=50:key=rkn_tcp:nld=2 --lua-desync=z2k_sni_pick:payload=tls_client_hello:dir=out:blob=z2k_ch:key=rkn_tcp:nld=2 --lua-desync=fake:payload=tls_client_hello:dir=out:blob=z2k_ch:optional:repeats=8:tcp_ts=-1000 --lua-desync=circular:fails=3:key=rkn_tcp:nld=2 --new"
CFG

# Валидатор берёт конфиг ПЕРВЫМ АРГУМЕНТОМ, а каталог — из ZAPRET_BASE.
OUT=$(ZAPRET_BASE="$SB" sh "$VALIDATOR" "$SB/config" 2>&1)
RC=$?

case "$OUT" in
    *"z2k_ch"*) bad "валидатор ругается на рантайм-блоб z2k_ch — обновление откатится" ;;
    *)          ok  "рантайм-блоб z2k_ch не считается ошибкой" ;;
esac

case "$OUT" in
    *"Неизвестное lua-desync действие: 'z2k_stall_watch'"*) bad "z2k_stall_watch не в списке известных действий" ;;
    *) ok "z2k_stall_watch известен валидатору" ;;
esac
case "$OUT" in
    *"Неизвестное lua-desync действие: 'z2k_sni_pick'"*) bad "z2k_sni_pick не в списке известных действий" ;;
    *) ok "z2k_sni_pick известен валидатору" ;;
esac

# Код 2 = вето на перезапуск. Ради него всё и написано.
if [ "$RC" -ge 2 ]; then
    bad "валидатор вернул $RC — это вето, обновление откатится"
else
    ok "код возврата $RC — вето нет"
fi

# Обратная сторона: ссылка на блоб, которого никто не производит и не
# регистрирует, обязана остаться ошибкой.
sed 's/blob=z2k_ch:optional/blob=z2k_nosuch:optional/' "$SB/config" > "$SB/config.bad"
OUT2=$(ZAPRET_BASE="$SB" sh "$VALIDATOR" "$SB/config.bad" 2>&1)
case "$OUT2" in
    *"z2k_nosuch"*) ok "выдуманный блоб по-прежнему ошибка" ;;
    *)              bad "валидатор пропустил блоб, которого никто не производит" ;;
esac

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
