#!/bin/sh
# tests/test_udp_detector_window.sh
#
# Пороги UDP-детекторов против окна перехвата.
#
# ЗАЧЕМ. Счётчик пакетов видит только то, что попало в очередь — мануал,
# «Обслуживание позиций»: «Счетчик не может и не будет считать то, что не
# перехватывается». Значит порог успеха udp_in обязан лежать НИЖЕ окна
# NFQWS2_UDP_PKT_IN, иначе успех недостижим в принципе.
#
# Что бывает иначе, замерено 2026-08-19 на боевом роутере: при udp_in=8 и окне
# в 3 пакета на 237 потоков пула видео пришёлся 1 успех и 58 провалов, из них
# все 58 — на потоках, которые ответ ОТ СЕРВЕРА получили. Сбрасывать счётчик
# нечем, и симуляция даёт 15 ротаций на полностью здоровом трафике.
#
# Ошибка молчаливая: ни в логе, ни в статусе сервиса не видна. Поэтому сторожим
# инвариант тестом, а не глазами.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DIR/lib/config_official.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

[ -f "$SRC" ] || { echo "нет $SRC"; exit 1; }

win_in=$(sed -n 's/^Z2K_UDP_PKT_IN="\([0-9]*\)"$/\1/p' "$SRC")
win_out=$(sed -n 's/^Z2K_UDP_PKT_OUT="\([0-9]*\)"$/\1/p' "$SRC")

if [ -n "$win_in" ] && [ -n "$win_out" ]; then
    ok "окно перехвата объявлено: in=$win_in out=$win_out"
else
    bad "не нашёл Z2K_UDP_PKT_IN/OUT в генераторе"
    echo; echo "PASSED: $PASS"; echo "FAILED: $FAIL"; exit 1
fi

# Сами пороги берём из строк circular, как они уедут в конфиг.
checked=0
for tok in $(grep -o 'circular:[^ "]*udp_[a-z]*=[^ "]*' "$SRC" | sort -u); do
    key=$(printf '%s' "$tok" | sed -n 's/.*:key=\([a-z0-9_]*\).*/\1/p')
    [ -n "$key" ] || key="без ключа"
    in_thr=$(printf '%s' "$tok" | sed -n 's/.*:udp_in=\([0-9]*\).*/\1/p')
    out_thr=$(printf '%s' "$tok" | sed -n 's/.*:udp_out=\([0-9]*\).*/\1/p')

    if [ -n "$in_thr" ]; then
        checked=$((checked + 1))
        # успех срабатывает на пакете udp_in+1 — окно обязано его застать
        if [ "$in_thr" -lt "$win_in" ]; then
            ok "$key: udp_in=$in_thr ниже окна $win_in — успех достижим"
        else
            bad "$key: udp_in=$in_thr не ниже окна $win_in — успех недостижим, ротация пойдёт по шуму"
        fi
    fi
    if [ -n "$out_thr" ]; then
        checked=$((checked + 1))
        if [ "$out_thr" -le "$win_out" ]; then
            ok "$key: udp_out=$out_thr в пределах окна $win_out"
        else
            bad "$key: udp_out=$out_thr выше окна $win_out — провал недостижим"
        fi
    fi
done

if [ "$checked" -gt 0 ]; then
    ok "проверено порогов: $checked"
else
    bad "ни одного udp-порога не найдено — тест ослеп, проверь формат строк circular"
fi

# Пороги обязаны отличаться так, чтобы успех и провал не спорили за один поток:
# провал требует pos_in <= udp_in, успех — pos_in > udp_in. Граница общая, это
# нормально; проверяем лишь, что udp_out не единица (иначе провал ставится
# первым же исходящим пакетом до любого ответа).
for tok in $(grep -o 'circular:[^ "]*udp_out=[0-9]*[^ "]*' "$SRC" | sort -u); do
    out_thr=$(printf '%s' "$tok" | sed -n 's/.*:udp_out=\([0-9]*\).*/\1/p')
    key=$(printf '%s' "$tok" | sed -n 's/.*:key=\([a-z0-9_]*\).*/\1/p')
    [ -n "$out_thr" ] || continue
    if [ "$out_thr" -ge 2 ]; then
        ok "${key:-пул}: udp_out=$out_thr не ставит провал на первом же пакете"
    else
        bad "${key:-пул}: udp_out=$out_thr — провал до любого ответа сервера"
    fi
done

# Сторож должен реально ловить нарушение, а не просто существовать. Вынимаем
# функцию из генератора и скармливаем ей заведомо кривой порог.
probe()
{
    # $1 - окно in, $2 - окно out, $3 - строка стратегии
    sh <<EOF 2>&1
eval "\$(awk '/^    check_udp_thresholds\(\) \{/,/^    \}/' "$SRC")"
Z2K_UDP_PKT_IN=$1
Z2K_UDP_PKT_OUT=$2
check_udp_thresholds проба "$3"
EOF
}

good=$(probe 8 8 "--lua-desync=circular:fails=3:udp_in=3:udp_out=5:key=yt_quic")
if [ -z "$good" ]; then
    ok "на здоровой конфигурации сторож молчит"
else
    bad "сторож ругается на здоровую конфигурацию: $good"
fi

# то, что стояло у нас с июня: порог выше окна
caught=$(probe 3 5 "--lua-desync=circular:fails=3:udp_in=8:udp_out=4:key=yt_quic")
case "$caught" in
    *"udp_in=8"*"недостижим"*) ok "сторож ловит udp_in выше окна (июньская конфигурация)" ;;
    *) bad "сторож пропустил udp_in=8 при окне 3, вернул: ${caught:-пусто}" ;;
esac

caught=$(probe 8 4 "--lua-desync=circular:fails=3:udp_in=3:udp_out=9:key=yt_quic")
case "$caught" in
    *"udp_out=9"*"недостижим"*) ok "сторож ловит udp_out выше окна" ;;
    *) bad "сторож пропустил udp_out=9 при окне 4, вернул: ${caught:-пусто}" ;;
esac

# И сам вызов обязан стоять в генераторе, иначе сторож мёртвый груз.
if grep -q 'check_udp_thresholds yt_quic' "$SRC"; then
    ok "сторож вызывается для пула видео"
else
    bad "вызова check_udp_thresholds для yt_quic в генераторе нет"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" = "0" ]
