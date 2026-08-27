#!/bin/sh
# tests/test_update_survives_hup.sh — обновление переживает обрыв сессии.
#
# Из поля: человек запустил обновление из терминала, и оно встало на середине —
# «нужно обновить файлов: 0», шаги идут по кругу, версия не двигается. Причина
# не в шагах: apply шёл в ПЕРЕДНЕМ ПЛАНЕ SSH-сессии, то есть в её группе
# процессов, а обновление само перезапускает сервис и меняет бинарники, из-за
# чего SSH рвётся. Весь процесс получал SIGHUP и умирал между доставкой файлов
# и записью отметки версии.
#
# У панели защита была и подтверждена замером; у терминала — нет. Здесь
# проверяется, что она есть у ОБОИХ путей и что она реально работает.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)

assert_eq "терминал защищает apply от HUP" "1" \
    "$(grep -c "trap '' HUP; Z2K_AU_NO_JITTER=1 au_run_apply" "$ROOT/lib/menu.sh")"
if grep -q "trap '' HUP" "$ROOT/webpanel/cgi/actions.sh"; then
    ok "панель защищает свои задачи от HUP"
else
    no "панель защищает свои задачи от HUP" "есть" "нет"
fi

# Приём обязан работать, а не только присутствовать в тексте: игнорирование
# сигнала наследуется через exec, поэтому переживает и дочерние процессы.
SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
# Длительность работы задаём В СЕКУНДАХ, а не числом итераций: busybox sleep
# дробей не принимает (usage — `sleep [N]...`), и `sleep 0.1 || sleep 1`
# растягивал тридцать итераций с трёх секунд до тридцати — внешний код ждал три
# и читал пустоту.
if [ "${Z2K_TEST_FRAC_SLEEP:-0}" = 1 ]; then _iter=30; _unit=0.1; else _iter=3; _unit=1; fi
cat > "$SB/work.sh" <<INNER
( trap '' HUP
  i=0
  while [ "\$i" -lt $_iter ]; do i=\$((i + 1)); sleep $_unit; done
  echo done > "\$1/result" ) &
echo \$! > "\$1/pid"
wait
INNER
sh "$SB/work.sh" "$SB" >/dev/null 2>&1 &
_outer=$!
sleep 1
kill -HUP "$(cat "$SB/pid" 2>/dev/null)" 2>/dev/null
sleep 3
kill "$_outer" 2>/dev/null
assert_eq "работа доживает до конца после HUP" "done" "$(cat "$SB/result" 2>/dev/null)"

# ── ОБНОВЛЕНИЕ ПОД ЧУЖИМ set -e ─────────────────────────────────────────────
#
# Из поля: в вебморде обновляется, в терминале — «шаг: проверяю конфиг» и
# приглашение, без единого сообщения. Причина не в шагах.
#
# z2k.sh работает под `set -e` и сорсит lib/auto_update.sh. Приём `cmd; rc=$?`
# под errexit код возврата НЕ ловит: оболочка умирает на самой команде, до
# присваивания, молча. Валидатор конфига возвращает 1 на одних предупреждениях
# — то есть почти у всех. Панель работала, потому что запускает
# z2k-auto-update.sh отдельным процессом, а там `set -e` нет.
assert_eq "код возврата ловится безопасно для errexit" "0" \
    "$(grep -v '^ *#' "$ROOT/lib/auto_update.sh" | grep -c '; rc=$?')"
assert_eq "терминал снимает errexit на время обновления" "1" \
    "$(grep -c 'set +e' "$ROOT/lib/menu.sh")"
assert_eq "и возвращает его обратно" "1" \
    "$(awk '/set \+e/{f=1} f && /^ *set -e$/{n++} END{print n+0}' "$ROOT/lib/menu.sh")"

# Приём обязан работать, а не просто присутствовать: под set -e форма
# `cmd || rc=$?` доводит скрипт до конца, а `cmd; rc=$?` убивает молча.
cat > "$SB/errexit.sh" <<'INNER'
set -e
bad() { sh -c 'exit 1'; rc=$?; echo "поймал $rc"; }
good() { rc=0; sh -c 'exit 1' || rc=$?; echo "поймал $rc"; }
"$1"
echo "дожил"
INNER
assert_eq "старая форма убивает молча" ""          "$(sh "$SB/errexit.sh" bad 2>/dev/null)"
assert_eq "новая форма доводит до конца" "поймал 1
дожил" "$(sh "$SB/errexit.sh" good 2>/dev/null)"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
