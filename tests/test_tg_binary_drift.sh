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
    # 2) Тулчейн пинится: на 1.26.x рантайм ломается на MIPS (golang/go#77730),
    #    а системный Go на машине сборщика — это лотерея.
    if grep -qE '^GO \?= .*go1\.25\.12' "$MAKEFILE"; then
        ok "тулчейн Go запинен (1.25.12)"
    else
        no "тулчейн Go запинен" "нет 'GO ?= ...go1.25.12' — сборка системным Go испортит MIPS"
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

# 6) В каждом бинарнике должен быть вшит секрет туннеля.
#
#    Секрет намеренно не лежит в исходниках — он подставляется на сборке:
#    `make all Z2K_TUNNEL_SECRET=<hex>`. Значение по умолчанию ПУСТОЕ, поэтому
#    обычный `make all` собирается без единой ошибки и выдаёт бинарник, который
#    на роутере падает сразу же: «--tunnel-secret is required in tunnel mode»,
#    супервизор крутит его в цикле, Telegram не работает вообще ни у кого.
#
#    Так и случилось при подъёме тулчейна 2026-08-08: пересборка прошла молча и
#    зелено, а туннель лёг. Ни один тест этого не видел — сторожа проверяли путь
#    сборки, набор арок и пин тулчейна, но не содержимое.
#
#    Проверяем наличием 64-символьной hex-строки: у сборки с секретом она есть
#    во всех арках, у сборки без него нет ни одной.
if [ -d "$BUILDS" ]; then
    nosecret=""; checked=0
    for f in "$BUILDS/$BIN-linux-"*; do
        [ -f "$f" ] || continue
        checked=$((checked + 1))
        if ! strings "$f" 2>/dev/null | grep -qE '^[0-9a-f]{64}$'; then
            nosecret="$nosecret $(basename "$f")"
        fi
    done
    if [ "$checked" = "0" ]; then
        no "секрет туннеля вшит в бинарники" "в $BUILDS нет ни одного бинарника"
    elif [ -z "$nosecret" ]; then
        ok "секрет туннеля вшит во все $checked бинарников"
    else
        no "секрет туннеля вшит в бинарники" \
           "собрано без Z2K_TUNNEL_SECRET —$nosecret; у этих роутеров Telegram не заработает"
    fi
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
