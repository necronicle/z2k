#!/bin/sh
# tests/test_cleanup_removes_dns_pins.sh
#
# Деинсталлятор обязан снимать ВСЕ статические DNS-записи, которые мы ставили.
#
# ЗАЧЕМ. До 19.08.2026 z2k_cleanup.sh снимал только семь rutracker-пинов,
# перечисленных руками. Instagram, WhatsApp и 4pda оставались висеть навсегда:
# человек сносит z2k, а роутер продолжает резолвить эти домены в прошитые нами
# адреса. Через недели адреса протухают, и у него ломается то, что без z2k
# работало бы нормально — причём причину найти неоткуда. Плюс у Keenetic
# потолок 256 статических записей, и его уже однажды съели пинами Discord.
#
# ГЛАВНОЕ ТРЕБОВАНИЕ — НЕ ДУБЛИРОВАТЬ СПИСОК. Он должен читаться из HOSTS
# в z2k-insta-ip-refresh.sh, то есть оттуда же, откуда берётся при установке.
# Список, набранный во втором месте руками, отстаёт: 4pda добавили 19.08, и в
# удаление он не попал бы. Этот тест сторожит именно связь, а не перечень.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP="$DIR/z2k_cleanup.sh"
REFRESH="$DIR/files/z2k-insta-ip-refresh.sh"
# Путей удаления ДВА, и забыть один — ровно то, что уже случилось: сначала
# починили аварийную дочистку, а обычное удаление из меню осталось прежним.
INSTALL="$DIR/lib/install.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

for f in "$CLEANUP" "$REFRESH" "$INSTALL"; do
    [ -f "$f" ] || { echo "нет $f"; exit 1; }
done

# --- 1. Список берётся из скрипта обновления, а не набран заново -------------
if grep -q 'z2k-insta-ip-refresh.sh' "$CLEANUP"; then
    ok "деинсталлятор читает список доменов из скрипта обновления"
else
    bad "список доменов не связан с z2k-insta-ip-refresh.sh — отстанет при добавлении нового"
fi

# --- 2. Каждый домен из HOSTS реально попадает под удаление ------------------
# Прогоняем настоящий блок удаления с подставным ndmc: он отдаёт running-config
# со всеми доменами и записывает, что у него просили удалить.
hosts=$(grep -m1 '^HOSTS=' "$REFRESH" | sed 's/HOSTS=//; s/"//g')
[ -n "$hosts" ] || { bad "не разобрал HOSTS"; echo; echo "PASSED: $PASS"; echo "FAILED: $FAIL"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/opt"
cp "$REFRESH" "$tmp/opt/z2k-insta-ip-refresh.sh"

# Подставной ndmc: на show отдаёт по две записи на домен плюс чужие,
# на "no ip host" — пишет строку в журнал и отвечает успехом.
{
    echo '#!/bin/sh'
    echo 'case "$2" in'
    echo '  "show running-config")'
    for h in $hosts; do
        echo "    echo 'ip host $h 1.2.3.4'"
        echo "    echo 'ip host $h 5.6.7.8'"
    done
    # чужие записи, которых трогать нельзя
    echo "    echo 'ip host example.com 9.9.9.9'"
    echo "    echo 'ip host not-4pda.to 9.9.9.9'"
    echo '    ;;'
    echo '  "system configuration save") ;;'
    echo '  *) echo "$2" >> "$NDMC_LOG" ;;'
    echo 'esac'
    echo 'exit 0'
} > "$tmp/bin/ndmc"
chmod +x "$tmp/bin/ndmc"

: > "$tmp/ndmc.log"
block=$(awk '/^# DNS-пины остальных доменов/,/^# Бинарь и его init-скрипт/' "$CLEANUP" \
        | sed '$d')
[ -n "$block" ] || { bad "не нашёл блок удаления пинов в деинсталляторе"; echo; echo "PASSED: $PASS"; echo "FAILED: $FAIL"; exit 1; }

PATH="$tmp/bin:$PATH" NDMC_LOG="$tmp/ndmc.log" ZAPRET2_DIR="$tmp/opt" \
    sh -c "log_info() { :; }; log_skip() { :; }; $block" >/dev/null 2>&1

missed=""
for h in $hosts; do
    grep -q "^no ip host $h " "$tmp/ndmc.log" || missed="$missed $h"
done
if [ -z "$missed" ]; then
    ok "все $(echo "$hosts" | wc -w | tr -d ' ') домена из HOSTS сняты"
else
    bad "не сняты домены:$missed"
fi

# Обе записи каждого домена, а не только первая: адреса переписывает
# ежедневное обновление, и их на домен обычно несколько.
n=$(grep -c '^no ip host' "$tmp/ndmc.log" 2>/dev/null || echo 0)
want=$(( $(echo "$hosts" | wc -w | tr -d ' ') * 2 ))
if [ "$n" = "$want" ]; then
    ok "сняты все записи каждого домена ($n)"
else
    bad "снято $n записей, ожидалось $want — часть адресов останется висеть"
fi

# --- 3. Чужое не трогаем ------------------------------------------------------
# Совпадение по имени должно быть точным: not-4pda.to содержит 4pda.to как
# подстроку, и подстрочный поиск снёс бы чужую запись.
if grep -q 'example.com\|not-4pda' "$tmp/ndmc.log"; then
    bad "деинсталлятор трогает чужие записи:"
    grep 'example.com\|not-4pda' "$tmp/ndmc.log" | head -3
else
    ok "чужие записи не тронуты (совпадение по имени точное)"
fi

# --- 4. Обычное удаление снимает то же самое ---------------------------------
# uninstall_zapret2 из lib/install.sh — путь, которым люди пользуются из меню.
# Аварийный z2k_cleanup.sh скачивается с ветки и нужен, когда установка уже
# разрушена; чинить только его недостаточно.
_un=$(awk '/^uninstall_zapret2\(\)/,/^}/' "$INSTALL")
case "$_un" in
    *z2k-insta-ip-refresh.sh*) ok "обычное удаление читает список доменов оттуда же" ;;
    *) bad "uninstall_zapret2 не снимает пины Instagram/WhatsApp/4pda" ;;
esac
case "$_un" in
    *'$3==h'*|*'$3 == h'*) ok "обычное удаление сверяет имя точно, не подстрокой" ;;
    *) bad "в обычном удалении нет точного совпадения по имени — снесёт чужое" ;;
esac

# --- 5. Rutracker-пины на месте ----------------------------------------------
# Их снимает отдельный, более ранний блок — правка не должна была его задеть.
if grep -q 'no ip host \$_d \$RTP_SENTINEL' "$CLEANUP"; then
    ok "снятие rutracker-пинов не задето"
else
    bad "пропало снятие rutracker-пинов"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ]
