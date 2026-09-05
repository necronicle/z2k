#!/bin/sh
# tests/test_ppe_follows_service.sh — PPE-разгрузка живёт ровно столько же,
# сколько сам обход.
#
# Повод: 05.09.2026, находка Марка. Правила `-j PPE` в mangle ставят установщик,
# панель, меню, планировщик (раз в 55 c) и хук NDM (на каждый реген netfilter),
# а СНИМАЕТ их только удаление z2k. После `S99zapret2 stop` они оставались —
# проверено на роутере: четыре правила при полностью остановленном обходе.
#
# Плата не нулевая: разгрузка нарочно снимает начало каждого соединения с
# аппаратного ускорителя, чтобы nfqws2 его видел. Когда nfqws2 не работает,
# видеть некому, а процессор всё равно занят. Пользователь выключает обход и
# вправе ожидать штатной скорости роутера.
#
# Снять в stop мало: планировщик и хук вернули бы правила в течение минуты.
# Поэтому оба переустановщика обязаны проверять живой демон.
# POSIX sh (busybox ash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

INIT="$ROOT/files/S99zapret2.new"
SCHED="$ROOT/files/z2k-scheduler.sh"
HOOK="$ROOT/files/ndm/94-z2k-ppe-deoffload.sh"
for f in "$INIT" "$SCHED" "$HOOK"; do
    [ -f "$f" ] || { echo "нет $f"; exit 1; }
done

body() { awk -v fn="^$2\\\\(\\\\)" '$0 ~ fn {f=1} f{print} f && /^\}/{exit}' "$1"; }

if body "$INIT" stop_fw | grep -q 'z2k_ppe_remove_rules'; then
    ok "stop снимает PPE-разгрузку"
else
    bad "stop НЕ снимает PPE-разгрузку — правила переживут остановку обхода"
fi

if body "$INIT" start_fw | grep -q 'z2k_ppe_ensure_rules'; then
    ok "start возвращает PPE-разгрузку сам, не дожидаясь планировщика"
else
    bad "start НЕ возвращает PPE-разгрузку — до минуты после старта потоки в железе"
fi

# Переустановщики: планировщик раз в 55 c и хук NDM на каждый реген mangle.
# Без проверки живого демона они отменяют снятие в stop за минуту.
if grep -q 'pidof nfqws2' "$SCHED"; then
    ok "планировщик не возвращает правила при остановленном обходе"
else
    bad "планировщик вернёт PPE через минуту после stop — снятие бессмысленно"
fi

if grep -q 'pidof nfqws2' "$HOOK"; then
    ok "хук NDM не возвращает правила при остановленном обходе"
else
    bad "хук NDM вернёт PPE на первом же регене netfilter"
fi

# Порядок в хуке: проверка обязана стоять ДО вызова, иначе она ничего не решает.
_g=$(grep -n 'pidof nfqws2' "$HOOK" | head -1 | cut -d: -f1)
_e=$(grep -n 'z2k_ppe_ensure_rules' "$HOOK" | tail -1 | cut -d: -f1)
if [ -n "$_g" ] && [ -n "$_e" ] && [ "$_g" -lt "$_e" ]; then
    ok "в хуке проверка стоит перед установкой правил"
else
    bad "в хуке проверка стоит после установки правил — она ничего не решает"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
