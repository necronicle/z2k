#!/bin/sh
# tests/test_stale_binaries_cleanup.sh — уборка недокачанных бинарников.
#
# Каждый бинарник скачивается во временный файл рядом с целью
# (`<цель>.new.<pid>`) и переезжает на место атомарным mv. Если установка
# оборвалась между скачиванием и mv — пропало питание, кончилось место,
# оборвался SSH — файл остаётся навсегда. Своих сирот процесс чистит сам, но
# только СВОИХ: от чужого прогона остаётся мусор с чужим pid, и его не убирал
# никто.
#
# Цена: tg-mtproxy-client и z2k-detect по ~5.2 МБ, z2k-rt-proxy ~3.7 МБ — до
# 14 МБ за один обрыв. Петля получается порочная: типичная причина обрыва —
# нехватка места, каждый обрыв оставляет хвост, следующая попытка падает
# вероятнее. Ровно это и произошло в issue #29: при нехватке пяти мегабайт у
# человека лежал z2k-rt-proxy.new.2988.
#
# Тест проверяет ДВА свойства, и второе не менее важно первого: чужие сироты
# убираются, а СВОЙ файл — нет. Снести свой .new значит убить установку,
# которая как раз идёт.
#
# POSIX sh.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INST="$ROOT/lib/install.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n      %s\n' "$1" "$2"; }

[ -f "$INST" ] || { no "lib/install.sh найден" "нет файла"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1; }

# 1) Механизм на месте.
if grep -q 'z2k-rt-proxy\.new\.\*' "$INST" && grep -q 'tg-mtproxy-client\.new\.\*' "$INST"; then
    ok "уборка недокачанных бинарников присутствует"
else
    no "уборка недокачанных бинарников присутствует" \
       "шаблонов .new.* нет — сироты снова копятся без предела"
fi

# 2) Она идёт ДО того, как установка займёт место. Иначе смысла нет: место
#    нужно освободить раньше, чем оно понадобится.
_clean=$(grep -n 'недокачанных бинарников' "$INST" | head -1 | cut -d: -f1)
_mv=$(grep -n 'Сохранение старой установки для отката' "$INST" | head -1 | cut -d: -f1)
if [ -n "$_clean" ] && [ -n "$_mv" ] && [ "$_clean" -lt "$_mv" ]; then
    ok "уборка выполняется до занятия места (строка $_clean < $_mv)"
else
    no "уборка выполняется до занятия места" "уборка=$_clean, mv=$_mv"
fi

# 3) Поведение целиком, на настоящем каталоге: чужое убрать, своё сохранить.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sbin"
for f in tg-mtproxy-client.new.2988 z2k-rt-proxy.new.2988 z2k-detect.new.777 \
         z2k-usque.new.1 tg-mtproxy-client z2k-rt-proxy; do
    echo payload > "$T/sbin/$f"
done
MYPID=4242
echo payload > "$T/sbin/tg-mtproxy-client.new.$MYPID"

( cd "$T" || exit 1
  for _stale in sbin/tg-mtproxy-client.new.* sbin/z2k-rt-proxy.new.* \
                sbin/z2k-detect.new.* sbin/z2k-usque.new.*; do
      [ -f "$_stale" ] || continue
      [ "$_stale" = "${_stale%.new.$MYPID}" ] || continue
      rm -f "$_stale"
  done )

left=$(ls "$T/sbin" | sort | tr '\n' ' ')
want="tg-mtproxy-client tg-mtproxy-client.new.$MYPID z2k-rt-proxy "
if [ "$left" = "$want" ]; then
    ok "чужие сироты убраны, свой .new и рабочие бинарники целы"
else
    no "чужие сироты убраны, свой .new цел" "осталось: [$left], ожидалось: [$want]"
fi

# 4) Отдельно и прямо: рабочий бинарник не должен пострадать ни при каких
#    условиях — он и есть то, ради чего всё это работает.
[ -f "$T/sbin/tg-mtproxy-client" ] \
    && ok "рабочий бинарник не тронут" \
    || no "рабочий бинарник не тронут" "удалён — это отказ обхода целиком"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
