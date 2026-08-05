#!/bin/sh
# tests/test_tg_binary_drift.sh
#
# Бинарник туннеля доезжает до людей ровно из одного места:
#
#   mtproxy-client/builds/tg-mtproxy-client-linux-<арка>
#
# именно оттуда его качает lib/install.sh
# ("${GITHUB_RAW}/mtproxy-client/builds/${tg_bin}").
#
# До 2026-08-05 Makefile собирал в mtproxy-client/, а не в builds/, и файл надо
# было скопировать руками. Шаг ручной — значит рано или поздно пропускается: на
# момент правки в mtproxy-client/ лежал arm64 от 17 апреля, а в builds/ — от
# 5 июля, и людям доезжал второй. Ровно этот дрейф уже ловили у rt-proxy
# (tests/test_rt_proxy_binary_drift.sh), но для туннеля сторожа не было.
#
# Теперь Makefile пишет прямо в builds/, то есть копировать нечего. Этот тест
# следит, чтобы так и осталось, и чтобы ни одна арка, которую установщик умеет
# запросить, не осталась без файла — иначе роутер этой архитектуры молча
# останется на старом бинарнике.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
MAKEFILE="$HERE/mtproxy-client/Makefile"
BUILDS="$HERE/mtproxy-client/builds"
INSTALL="$HERE/lib/install.sh"
BIN=tg-mtproxy-client

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n      %s\n' "$1" "$2"; }

# 1) Makefile обязан собирать в builds/. Если кто-то вернёт вывод в текущий
#    каталог, ручной шаг копирования вернётся вместе с ним.
if [ -f "$MAKEFILE" ]; then
    bad=$(grep -cE '^\t.*\$\(GO\) build .* -o \$\(BINARY\)-linux-' "$MAKEFILE" 2>/dev/null)
    if [ "${bad:-0}" = "0" ]; then
        ok "Makefile собирает в builds/, а не в текущий каталог"
    else
        no "Makefile собирает в builds/" "$bad целей пишут мимо builds/ — вернулся ручной шаг копирования"
    fi
    # 2) Тулчейн пинится: Go 1.26+ неверно компилирует MIPS soft-float.
    if grep -qE '^GO \?= .*go1\.22\.12' "$MAKEFILE"; then
        ok "тулчейн Go запинен (1.22.12)"
    else
        no "тулчейн Go запинен" "нет 'GO ?= ...go1.22.12' — сборка системным Go испортит MIPS"
    fi
    # 3) Воспроизводимость: без этих флагов «пересобрать и сверить sha» не работает.
    miss=""
    grep -q '\-trimpath' "$MAKEFILE" || miss="$miss -trimpath"
    grep -q '\-buildvcs=false' "$MAKEFILE" || miss="$miss -buildvcs=false"
    if [ -z "$miss" ]; then
        ok "сборка воспроизводима (-trimpath, -buildvcs=false)"
    else
        no "сборка воспроизводима" "не хватает:$miss"
    fi
else
    no "Makefile найден" "нет $MAKEFILE"
fi

# 4) Каждая арка, которую установщик умеет запросить, должна существовать.
if [ -f "$INSTALL" ]; then
    arches=$(sed -n 's/.*tg_arch="\([a-z0-9_]*\)".*/\1/p' "$INSTALL" | sort -u)
    missing=""
    n=0
    for a in $arches; do
        n=$((n+1))
        [ -f "$BUILDS/$BIN-linux-$a" ] || missing="$missing $a"
    done
    if [ "$n" = "0" ]; then
        no "список арок прочитан" "в install.sh не нашлось ни одного tg_arch"
    elif [ -z "$missing" ]; then
        ok "все $n арок из install.sh есть в builds/"
    else
        no "все арки из install.sh есть в builds/" "нет файлов для:$missing"
    fi
else
    no "install.sh найден" "нет $INSTALL"
fi

# 5) Отладочная сборка не должна лежать рядом и сбивать с толку. Она в
#    .gitignore и людям не уезжает, но её присутствие раньше и было уликой
#    дрейфа — пусть о ней говорят вслух.
stale=$(ls "$HERE/mtproxy-client/$BIN-linux-"* 2>/dev/null | wc -l | tr -d ' ')
if [ "$stale" = "0" ]; then
    ok "в mtproxy-client/ нет старых сборок рядом с исходниками"
else
    no "в mtproxy-client/ нет старых сборок" "$stale шт. — остатки прежней схемы, удалить"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
