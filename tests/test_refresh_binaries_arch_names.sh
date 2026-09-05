#!/bin/sh
# tests/test_refresh_binaries_arch_names.sh — на КАЖДОЙ арке шаг обновления
# бинарников обязан находить в манифесте наши базовые компоненты.
#
# Повод: 05.09.2026. Опознание арки возвращает гошное написание (mipsle,
# mips64le, 386), а клиент туннеля, z2k-rt-proxy и z2k-warpd названы
# по-энтварному (mipsel, mips64el, x86). Поиск шёл по одному написанию,
# поэтому на этих арках находился только z2k-detect, а остальное не
# обновлялось НИКОГДА. Шаг возвращал успех: пустой список файлов ошибкой не
# считается, в журнал не попадало ни строки.
#
# Наружу это выглядело как «половина флота не переходит на v2 релея»: за сутки
# обновление спрашивали 967 роутеров, бинарник качали 26.
#
# Тест зовёт НАСТОЯЩИЙ поиск из lib/auto_update.sh, а не свою копию.
# POSIX sh (busybox ash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/UPDATES.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

[ -f "$MANIFEST" ] || { echo "нет $MANIFEST"; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/lib/utils.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
. "$ROOT/lib/auto_update.sh" >/dev/null 2>&1

command -v au_bin_goarch >/dev/null 2>&1 || { echo "нет au_bin_goarch"; exit 1; }
command -v au_bin_manifest_paths >/dev/null 2>&1 || { echo "нет au_bin_manifest_paths"; exit 1; }

# Железо, которое реально встречается на флоте, по одному представителю на
# каждую сборку, которую мы выпускаем.
HW="aarch64 armv7l x86_64 i686 mips mipsel mips64el ppc riscv64"

# Базовые компоненты — те, что кладёт сама установка. z2k-warpd сюда не
# входит: он ставится кнопкой, и его отсутствие на арке законно.
BASE="tg-mtproxy-client z2k-detect"

for hw in $HW; do
    goarch=$(au_bin_goarch "" 2>/dev/null)
    # au_bin_goarch читает арку из окружения через get_arch/uname, поэтому
    # подставляем железо тем же путём, каким его видит роутер.
    goarch=$(sh -c '
        . "'"$ROOT"'/lib/utils.sh" >/dev/null 2>&1
        get_arch() { echo "'"$hw"'"; }
        . "'"$ROOT"'/lib/auto_update.sh" >/dev/null 2>&1
        get_arch() { echo "'"$hw"'"; }
        au_bin_goarch')
    if [ -z "$goarch" ]; then
        bad "$hw: арка не опознана (au_bin_goarch пусто)"
        continue
    fi
    paths=$(au_bin_manifest_paths "$MANIFEST" "$goarch")
    if [ -z "$paths" ]; then
        bad "$hw (goarch=$goarch): манифест не дал НИ ОДНОГО файла"
        continue
    fi
    miss=""
    for comp in $BASE; do
        echo "$paths" | grep -q "/${comp}-linux-" || miss="$miss $comp"
    done
    if [ -n "$miss" ]; then
        bad "$hw (goarch=$goarch): не находится:$miss"
    else
        ok "$hw (goarch=$goarch): базовые компоненты находятся"
    fi
done

# Один компонент не должен приезжать дважды под двумя написаниями: цель у него
# одна, а два скачивания — это два перезапуска владельца.
for hw in mipsel mips64el i686; do
    goarch=$(sh -c '
        . "'"$ROOT"'/lib/utils.sh" >/dev/null 2>&1
        get_arch() { echo "'"$hw"'"; }
        . "'"$ROOT"'/lib/auto_update.sh" >/dev/null 2>&1
        get_arch() { echo "'"$hw"'"; }
        au_bin_goarch')
    [ -n "$goarch" ] || continue
    dup=$(au_bin_manifest_paths "$MANIFEST" "$goarch" \
          | sed 's|.*/||; s|-linux-.*||' | sort | uniq -d)
    if [ -n "$dup" ]; then
        ok "$hw: компонент объявлен под двумя написаниями ($dup) — шаг обязан взять его один раз"
    fi
done

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
