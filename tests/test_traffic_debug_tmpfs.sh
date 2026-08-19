#!/bin/sh
# tests/test_traffic_debug_tmpfs.sh
#
# Отладочный лог nfqws2 пишется в tmpfs, а не на флешку.
#
# ЗАЧЕМ. Раньше он лежал в extra_strats/cache/traffic, то есть в /opt на USB.
# Замер 2026-08-19: за 17 часов включённой отладки файл вырос до 475 МБ
# непрерывных мелких дописываний — единственный источник такой нагрузки на
# носитель, и создаём её мы сами, ради данных, нужных на десять минут.
#
# Флаг включения при этом обязан остаться на флешке: его ставит человек руками,
# и он должен переживать перезагрузку. Разъехаться эти два пути не должны —
# лог в память, флаг на диск.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DIR/files/S99zapret2.new"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

[ -f "$SRC" ] || { echo "нет $SRC"; exit 1; }

tmpdir=$(sed -n 's/^Z2K_TRAFFIC_DEBUG_TMPDIR="\([^"]*\)"$/\1/p' "$SRC")
flagdir=$(sed -n 's/^Z2K_TRAFFIC_DEBUG_FLAGDIR="\(.*\)"$/\1/p' "$SRC")

case "$tmpdir" in
    /tmp/*) ok "лог пишется в tmpfs: $tmpdir" ;;
    "")     bad "Z2K_TRAFFIC_DEBUG_TMPDIR не объявлен" ;;
    *)      bad "лог пишется мимо tmpfs: $tmpdir" ;;
esac

case "$flagdir" in
    *extra_strats*) ok "флаг включения остаётся на диске: переживёт перезагрузку" ;;
    "")             bad "Z2K_TRAFFIC_DEBUG_FLAGDIR не объявлен" ;;
    *)              bad "флаг уехал не туда: $flagdir" ;;
esac

# Ни один путь лога не должен указывать на носитель.
if grep -n 'nfqws2\.debug\.log\|tcpdump\.err\.log\|tcpdump\.pid' "$SRC" \
   | grep -v 'TMPDIR' | grep -q 'extra_strats'; then
    bad "какой-то файл отладки всё ещё адресуется в extra_strats:"
    grep -n 'nfqws2\.debug\.log\|tcpdump\.err\.log\|tcpdump\.pid' "$SRC" \
        | grep -v 'TMPDIR' | grep 'extra_strats' | head -3
else
    ok "ни лог, ни pcap-хвосты не адресуются на флешку"
fi

# Потолок размера: /tmp это RAM, забытый на ночь флаг не должен её съесть.
maxmb=$(sed -n 's/^Z2K_TRAFFIC_DEBUG_MAXMB="\${Z2K_TRAFFIC_DEBUG_MAXMB:-\([0-9]*\)}"$/\1/p' "$SRC")
if [ -n "$maxmb" ] && [ "$maxmb" -gt 0 ] 2>/dev/null && [ "$maxmb" -le 128 ]; then
    ok "потолок лога задан и разумен для 500 МБ RAM: ${maxmb}МБ"
else
    bad "потолок лога не задан или великоват: ${maxmb:-нет}"
fi

if grep -q '^traffic_debug_rotate()' "$SRC"; then
    ok "функция обрезки объявлена"
else
    bad "traffic_debug_rotate не объявлена"
fi

# Обрезать надо на месте, а не удалять: nfqws2 держит файл открытым, и rm
# оставил бы его писать в отвязанный инод — место не освободится, данные уйдут.
rot=$(awk '/^traffic_debug_rotate\(\)/,/^}/' "$SRC")
case "$rot" in
    *"rm "*) bad "обрезка удаляет файл — nfqws2 продолжит писать в отвязанный инод" ;;
    *": >"*) ok "обрезка идёт на месте, дескриптор демона не рвётся" ;;
    *)       bad "не вижу, чем обрезается лог" ;;
esac

if printf '%s' "$rot" | grep -q 'Z2K_TRAFFIC_DEBUG_MAXMB'; then
    ok "обрезка сверяется с потолком"
else
    bad "обрезка не смотрит на потолок"
fi

# И она обязана вызываться на старте, иначе мёртвый груз.
if grep -q '^\s*traffic_debug_rotate$' "$SRC"; then
    ok "обрезка вызывается при запуске"
else
    bad "вызова traffic_debug_rotate нет"
fi

# Поведение функции на живых данных.
probe()
{
    # $1 - размер файла в МБ, $2 - потолок
    d=$(mktemp -d) || return 1
    sh <<EOF 2>&1
eval "\$(awk '/^traffic_debug_rotate\(\)/,/^}/' "$SRC")"
Z2K_TRAFFIC_DEBUG=1
Z2K_TRAFFIC_DEBUG_TMPDIR="$d"
Z2K_TRAFFIC_DEBUG_MAXMB=$2
dd if=/dev/zero of="$d/nfqws2.debug.log" bs=1048576 count=$1 2>/dev/null
traffic_debug_rotate
du -k "$d/nfqws2.debug.log" | awk '{print \$1}'
EOF
    rm -rf "$d"
}

small=$(probe 2 64 | tail -1)
if [ -n "$small" ] && [ "$small" -ge 2000 ] 2>/dev/null; then
    ok "лог ниже потолка не трогается"
else
    bad "лог ниже потолка обрезали зря (осталось ${small:-?}КБ)"
fi

big=$(probe 8 4 | tail -1)
if [ -n "$big" ] && [ "$big" -lt 1000 ] 2>/dev/null; then
    ok "лог выше потолка обрезается"
else
    bad "лог выше потолка не обрезан (осталось ${big:-?}КБ)"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ]
